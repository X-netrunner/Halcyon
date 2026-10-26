# Installing on Debian and Ubuntu

Halcyon is developed on Arch. The Debian / Ubuntu path uses apt and is tested with `install.sh --dry-run` in containers, not yet on
real hardware. Back to the [README](../README.md).

## Which releases work

Halcyon needs **Hyprland 0.55 or newer**, because its config is written in Lua, and **Quickshell** (the island). Both have to come
from the distribution.

| Release | Hyprland | Quickshell | Works? |
|---|---|---|---|
| Debian testing (forky) / sid | 0.56.2 | 0.3.2 | yes |
| Debian 13 trixie (stable) | not packaged | not packaged | no: use testing, or wait for the next stable |
| Ubuntu 26.10 and newer | 0.56.2 | 0.3.0 | yes |
| Ubuntu 26.04 LTS | 0.53.3 (too old) | not packaged | no |
| Ubuntu 25.10 and older | 0.41 | not packaged | no |

Package versions as of October 2026 (packages.debian.org and Launchpad). On a release without them the installer stops and says
so. It used to offer a Hyprland PPA, but that PPA does not exist.

## Install

```bash
sudo apt update && sudo apt install git curl
curl -fsSLO https://github.com/X-netrunner/Halcyon/releases/latest/download/get.sh && bash get.sh
```

or from a checkout: `./install.sh` (`./install.sh --dry-run` first shows what it would do).

## What is different from Arch

- **Package names** are translated (`map_pkg_for_apt` in `install.sh`). Packages Debian does not have are skipped and listed at the end.
- **No AUR.** These are skipped: the Sweet cursor theme, bemoji, wayfreeze, Vesktop, and the browsers and editors that are
  AUR-only on Arch (Zen, LibreWolf, Floorp, Brave, VSCodium). Install the ones you want from their own repositories. (wlogout,
  AUR on Arch, is in Debian and is installed.)
- **NVIDIA:** `ubuntu-drivers install` on Ubuntu, `nvidia-driver` on Debian (non-free must be enabled).
- **Ollama** (`--llm`): Debian and Ubuntu do not package it. The installer downloads the official release archive at a fixed version,
  checks its SHA-256, and unpacks it into `/usr/local`. It does not run ollama.com's install script.
- **JetBrainsMono Nerd Font:** downloaded into `~/.local/share/fonts` at a fixed version with a checked SHA-256 (Debian has no Nerd Font package).
- **whisper.cpp** (voice notes) has no apt package: build it from https://github.com/ggml-org/whisper.cpp, or skip it.
- **ai-antivirus** is built as an Arch package and is skipped. The Security center's ClamAV page works (`sudo apt install clamav clamav-freshclam`).
- `fd` and `bat` are called `fdfind` and `batcat` on Debian; the installer links the usual names in `/usr/local/bin`.

## If something is missing

`./install.sh` again is safe. It only installs what is missing. Check the summary at the end and `~/.config/Halcyon/scripts/halcyon-doctor.sh`.
