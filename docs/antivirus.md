# Halcyon and the antivirus

Why ai-antivirus (and other behaviour-based antivirus tools) can report Halcyon's installer, and the exception Halcyon adds for it.
Back to the [README](../README.md).

## What gets reported, and why

None of Halcyon's files match a malware signature. Halcyon's files were checked against ai-antivirus's shipped YARA rules
(`rules/yara/*.yar`) and nothing matches. One string in `src/recon-deceiver` (a fake PHP page the honeypot serves to scanners)
looks like a web shell, but the rule only fires on a file that *starts* with `<?php`, so neither the source nor the binary
matches. The reports come from **behaviour rules**: they look at what a program does, not at what the file contains.

| Rule | What it watches | What Halcyon does that matches | Fix |
|---|---|---|---|
| **AV-B-0002** "Download piped into a shell" (high, freeze) | `curl ... \| bash` | The old one-line install, `curl -fsSL .../get.sh \| bash` | The documented command now downloads first, then runs: `curl -fsSLO .../get.sh && bash get.sh`. Nothing to except. |
| **AV-B-0005** "Service, timer or autostart entry written by a non-package process" (medium, notify) | Files written to `/etc/systemd/system/`, `~/.config/systemd/user/` ... by anything except pacman / systemctl | `install.sh` installs Halcyon's units (gestures, power manager, reminders, notes, updates, the RAM-info and sysmode boot services, the tty1 login drop-in). `update.sh` runs `install.sh` again on every update, so the reports come back each time. | A program exception for the installer (below). |
| **AV-B-0013** "Program executed from a temporary folder" (medium, notify) | Programs started from `/tmp`, `/dev/shm`, `/var/tmp` | Nothing in Halcyon itself. Third-party installers can do this, for example an AUR build under `/tmp`. | None needed. If you see it, read the alert's path first. |

The first install does not trigger AV-B-0005, because the antivirus is installed near the end of `install.sh`, after the units are
written. The reports start with the first `update.sh`.

## The exception

With ai-antivirus installed, `install.sh` adds two **program** exceptions (step 12, after the antivirus is installed and started):

```
sudo ai-antivirus exceptions add program '~/.config/Halcyon/install.sh'      --name "Halcyon installer"
sudo ai-antivirus exceptions add program '~/.cache/halcyon-update/install.sh' --name "Halcyon installer"
```

These are the two absolute paths the installer is run from: `get.sh` and `update.sh` run `bash <path>/install.sh`.

What the exceptions do:
- Behaviour alerts about the installer and everything it starts are dropped. The engine counts them as `excepted` and still logs them.
- Malware found in a file by hash or YARA is still reported, as a notification. Writes to `/etc/ld.so.preload` and to
  ai-antivirus's own files are never excepted.
- The exceptions only match these two exact script paths. They do not match `bash`, `sudo` or any folder.
  ai-antivirus refuses broader exceptions anyway.

What they do **not** cover: running the installer from your own checkout as `./install.sh` or `bash install.sh`. The antivirus
only matches absolute script paths, so a relative path never matches. You then see the AV-B-0005 notifications, which is
harmless. To except your checkout as well, add its absolute path the same way, for example
`sudo ai-antivirus exceptions add program '~/Halcyon/install.sh' --name "Halcyon installer (checkout)"`.

The trade-off: an exception trusts what runs under the script. Malware that already runs as you could edit
`~/.config/Halcyon/install.sh` and run it, and its systemd writes would then not be reported. If that matters more to you
than the notifications, skip the exceptions:

- at install time: `./install.sh --no-av-exception`
- afterwards: `sudo ai-antivirus exceptions remove '~/.config/Halcyon/install.sh'` (and the same for `~/.cache/halcyon-update/install.sh`)
- or from the Security center: Exceptions page, "Halcyon installer", remove

## ClamAV

ClamAV is signature-based only and does not watch behaviour, so the rules above do not apply to it. If ClamAV reports a Halcyon
file, run `clamscan --infected <file>` to see the signature name and open an issue with it. A signature hit on a Halcyon file is
a false positive the ClamAV project can fix, so it should not be excepted locally.
