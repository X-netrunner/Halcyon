# Installing on Fedora

Halcyon is developed on Arch. The Fedora path uses dnf and is tested with `install.sh --dry-run` in a Fedora 44 container, not yet
on real hardware. Back to the [README](../README.md).

## Which releases work

**Fedora 44 and newer.** Quickshell (the island) is in Fedora from 44 on; on 43 the installer warns and asks before going on.

Hyprland is **not** in Fedora's own repositories. The installer asks to enable the COPR **sdegler/hyprland**. That COPR has
community builds of Hyprland 0.56 and its tools (hypridle, hyprlock, hyprsunset, hyprpicker, xdg-desktop-portal-hyprland,
cliphist) for Fedora 43-45. It is the maintained successor of solopasha/hyprland, which now only builds for rawhide. If you say no, the install stops at Hyprland.

## Install

```bash
sudo dnf install git curl
curl -fsSLO https://github.com/X-netrunner/Halcyon/releases/latest/download/get.sh && bash get.sh
```

or from a checkout: `./install.sh` (`./install.sh --dry-run` first).

## What is different from Arch

- **Package names** are translated (`map_pkg_for_dnf` in `install.sh`; every name was checked against Fedora 43 and 44). The installer
  asks dnf once which of them the enabled repositories have; the rest are skipped and listed at the end.
- **No AUR.** These are skipped: the Sweet cursor theme, bemoji, wayfreeze, Vesktop, Discord, Spotify, and the browsers and editors
  that come from their vendors (Zen, LibreWolf, Floorp, Brave, Chrome, Vivaldi, VSCodium, Zed).
- **NVIDIA** is in RPM Fusion. If RPM Fusion is enabled, the installer installs `akmod-nvidia` and `xorg-x11-drv-nvidia-cuda`;
  otherwise it tells you how to enable it (https://rpmfusion.org/Configuration). It does not add RPM Fusion by itself.
- **Ollama** and **whisper.cpp** come from Fedora (`dnf install ollama whisper-cpp`).
- **Firewall:** Fedora uses firewalld. sysmode and the safety check expect ufw (installed from Fedora); do not run both at once.
- **ai-antivirus** is built as an Arch package and is skipped. The Security center's ClamAV page works (`clamav clamav-freshclam`).
- **JetBrainsMono Nerd Font:** downloaded into `~/.local/share/fonts` at a fixed version with a checked SHA-256.
- 32-bit libraries (Steam, Wine) are in Fedora's own repositories, so there is nothing like Arch's multilib to switch on.

## If something is missing

`./install.sh` again is safe. It only installs what is missing. Check the summary at the end and `~/.config/Halcyon/scripts/halcyon-doctor.sh`.
