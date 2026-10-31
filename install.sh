#!/usr/bin/env bash
# ==============================================================================================================
# Halcyon installer: ONE script that sets everything up on Arch Linux and Arch-based systems (CachyOS, EndeavourOS,
# Manjaro, Garuda, Artix ...), the reference. Also: Debian testing / sid and Ubuntu 26.10+ (apt, docs/install-debian.md),
# Fedora 44+ (dnf, docs/install-fedora.md). NixOS uses the flake instead (docs/install-nix.md). Run it from the folder you downloaded:
#
#     ./install.sh               asks before the important things (sudo password when needed)
#     ./install.sh --yes         no questions: fresh machine, scripts, and what update.sh uses
#     ./install.sh --dry-run     show what it WOULD do and change nothing
#
# Run it as your normal user. (As root it also works: it installs for the user you name with --user, never for root.)
# Safe to run again any time: it only changes what is missing or old. Everything it does is also written to a log file.
#
# What it does, in order
#    1  checks the machine, the user and sudo
#    2  package manager: AUR helper only if one is really needed
#    3  graphics drivers + CPU microcode: NVIDIA (open / legacy, by GPU generation), Intel, AMD, hybrid laptops (detected)
#    4  audio (+ firmware), Bluetooth, network, power services, input / video groups
#    5  Hyprland, Quickshell and the desktop packages + YOUR apps: you pick the web browser, the file manager (Thunar, Yazi,
#       Dolphin, ...), the code editor (VSCodium, Zed, ...) and whether to install sysmode and the safety check; plus foot, Discord and the music player(s) you pick (Spotify, spotify-player, ncspot)
#    6  Rust toolchain (for the helpers below)
#    7  copies the rice to ~/.config/Halcyon (an older copy is backed up; your hypr-user.lua, scheme/current.lua and
#       gamemode.conf are kept)
#    8  builds the Rust helpers (hx, hal, hgl, power-manager, touchpad-gestures, birthday-sync)
#    9  makes Hyprland load Halcyon (~/.config/hypr/hyprland.lua) + a "Halcyon" login-screen session. NO login manager on
#       this machine? Then the Halcyon LOCK SCREEN becomes the login screen (tty1 logs you in, Halcyon starts locked)
#   10  user services (gestures, auto power) + the boot service that saves RAM details for the performance page
#   11  root helpers: halcyon-tune (Gaming mode CPU/GPU boost, power-manager switch, Wi-Fi power saving: ONE narrow sudo
#       rule) + gaming tools, sysmode (hardening CLI + every tool it uses, honeypot / IDS at boot), the optional safety check
#       (root-owned /usr/local/bin/safety-check, started from Settings), backlight udev rule and
#       the keyboard-light driver for your laptop (ASUS, ThinkPad, Dell, HP, MSI, Tuxedo, System76 ...)
#   12  wallpaper -> colours of the island AND your terminals
#   13  checks everything (also that Hyprland accepts the config) and prints a report
#
# Options
#   -y, --yes              no questions                       --dry-run        show the steps, change nothing
#   --no-packages          skip pacman / AUR (also drivers)   --no-drivers      skip GPU driver + microcode detection
#   --build-from-source    compile the Rust helpers here instead of downloading the release binaries (HALCYON_PREBUILT=0 does the same)
#   --no-aur               never install from the AUR         --upgrade        run a full system upgrade (pacman -Syu) first
#   --no-sysmode           skip the hardening CLI + services  --no-tune        skip halcyon-tune and its sudo rule
#   --link                 symlink ~/.config/Halcyon to this folder instead of copying it (for development)
#   --user NAME            (when run as root) install for this user
#   --tty-autostart        start Halcyon automatically when you log in on tty1
#   --lock-login           use the lock screen as login screen even if a login manager exists
#   --no-lock-login        never set that up (you log in on the text console and start Halcyon by hand)
#   --remove-lock-login    undo it: no more auto-login on tty1, tty1 is an ordinary text login again
#   --greeter              a real login manager: greetd with Halcyon's own login screen (scripts/halcyon-greeter.sh), instead of the
#                          tty1 auto-login. Your old display manager is only switched off and can be put back
#   --remove-greeter       undo it: the old login manager (or the text console) comes back
#   --login-mode MODE      what happens at BOOT: greeter (Halcyon login manager, no widgets) | lock (auto-login + the lock screen, widgets allowed) | keep
#   --lock-mode MODE       what the screen is after SLEEP / when you lock: login (the login-screen look, no widgets) | lock (the lock screen, widgets allowed) | keep
#                          (both are asked once on a first install, and again with --choose; Settings > Login screen / Lock screen change them later)
#   --no-apps              do not install foot / Discord / a music player (and no file manager unless you ask for one)
#   --browser ID           firefox | zen | librewolf | floorp | chromium | brave | vivaldi | chrome | qutebrowser | keep
#   --files ID[,ID]        thunar | yazi | dolphin | nautilus | nemo | pcmanfm | none   (the first one opens folders: SUPER+E)
#   --editor ID[,ID]       codium | zeditor | neovim | none                              (the first one is SUPER+C)
#   --music ID[,ID]        spotify | spotify-player | ncspot | none                              (the first one is SUPER+M; several are fine)
#   --sysmode              install sysmode without asking (--no-sysmode: skip it)
#   --safety-check         install the safety check (system update, malware / rootkit scan, firewall, audit, backup) without asking
#                          (--no-safety-check: skip it; its entry in Settings > Security is then greyed out and disabled)
#   --llm[=MODEL]          install Ollama & local AI performance advisor (auto-detects hardware tier or specifies model)
#   --no-llm               skip Ollama & local AI performance advisor
#   --whisper[=MODEL]      install speech-to-text for voice notes: whisper.cpp + a model (tiny | base | small; default base). Without this option
#                          you are ASKED in a terminal; with --yes and nothing saved, no model is downloaded
#   --no-whisper           skip the speech-to-text model (voice notes are then saved as audio without a transcript)
#   --vlm[=MODEL]          install the picture-describing vision model for Notes (Ollama; default qwen2.5vl:3b, a download of about 3 GB) and switch
#                          Settings > Notes > "Describe pictures" on. Without this option you are ASKED in a terminal; with --yes and nothing saved,
#                          nothing is downloaded
#   --no-vlm               skip the vision model (the Describe button stays off; you can add it later: ./install.sh --vlm)
#   --resources MODE       how much of the machine Halcyon may use: low | medium | high | adaptive (Settings > Performance > Resource use).
#                          The menu shows an estimate of the RAM / CPU each one needs; adaptive = medium now, limits learned from your use
#   --resource-offset N    headroom in percent (0-100) above that estimate before Settings > Performance > Health warns (default 15)
#   --prompt ID            your shell prompt (Starship): keep | colours | halcyon
#   --plymouth             the boot splash: the login splash's stars and sparkle while Arch boots and shuts down (Plymouth;
#                          scripts/halcyon-plymouth.sh). Edits mkinitcpio and the kernel command line (backed up). Once on, every
#                          install / update redoes it in your current colours. Without this option you are ASKED in a terminal;
#                          with --yes and nothing saved it is only updated where it is already installed. Arch (mkinitcpio) only
#   --no-plymouth          leave the boot splash alone (takes nothing out; scripts/halcyon-plymouth.sh remove does that)
#   --firewall MODE        which firewall guards this machine: ai | ufw | none
#                            ai    Halcyon's ai-firewall: a self-healing eBPF/XDP firewall that bans scanners by itself, with
#                                  a page in the island and a dashboard (needs rustup nightly + bpf-linker to build; if it can't
#                                  be built, ufw is set up instead so the machine is never left open)
#                            ufw   the classic: deny incoming, allow outgoing
#                            none  leave the firewall alone (nothing is installed or removed)
#                          Asked on the first install and with --choose (default ai), then remembered. The source is
#                          AIFW_REPO / AIFW_REV below, or a local checkout: AIFW_SRC=~/Projects/ai-firewall ./install.sh
#   --luna / --no-luna     the extra: LUNA, a local AI assistant in Rust (https://github.com/X-netrunner/LUNA-AI), built from the
#                          commit pinned below (LUNA_REV) into ~/.local/bin/luna. Asked on the first install and with --choose
#                          (default no), then remembered. The program is installed and the Ollama models her tiers use are pulled
#                          (qwen3:8b, phi4-mini, nomic-embed-text, qwen2.5vl:3b and the two abliterated coder/security models, about 26 GB;
#                          LUNA_MODELS="a b" picks others, LUNA_MODELS=none skips). Her daemon is never switched on for you.
#   --luna-voice / --no-luna-voice  with LUNA: also give her a voice (scripts/luna-voice-setup.sh: the Kokoro model, about 330 MB from the
#                          kokoro-onnx GitHub release, a small Python environment, her [voice] config). Asked after the LUNA question, default no.
#   --firewall ID          ai | ufw | none (default ufw). ai = ai-firewall (eBPF, replaces ufw, page in the Security center), built
#                          from AIFW_SRC (default ~/.local/src/ai-firewall) or AIFW_REPO at AIFW_REV; needs nightly Rust + bpf-linker.
#                          If it cannot be built, ufw stays and an installed copy is kept. Switching away from ai removes it.
#                          Asked on the first install and with --choose, then remembered.
#   --antivirus / --no-antivirus  the extra: ai-antivirus (alert-only by default, page in the Security center), built as a
#                          pacman package from AV_SRC (default ~/.local/src/ai-antivirus) or AV_REPO at AV_REV. Default no,
#                          asked once, then remembered; --no-antivirus after it was installed removes the package (its config is kept).
#                          The firewall and the antivirus are independent: either one can be on without the other.
#                          (--synapse / --no-synapse still work: Synapse was its old name.)
#   --no-av-exception      do not add the ai-antivirus exception for this installer. By default, with ai-antivirus installed, the
#                          installer adds two program exceptions (~/.config/Halcyon/install.sh, ~/.cache/halcyon-update/install.sh)
#                          so the systemd units it writes on every update are not reported. Why and how to undo: docs/antivirus.md
#   SECURITY_MODEL=NAME   the local model the firewall and antivirus assistants use. Default: the best qwen3.5 size for this laptop
#                          (0.8b / 2b / 4b / 9b by GPU memory or RAM), suggested on a first install with a menu to change it, remembered,
#                          pulled when Ollama is installed and either module is on; SECURITY_MODEL=none skips the download.
#   --renderer MODE       how the island draws: auto | opengl | vulkan (default auto = picked for this machine each time Halcyon
#                          starts; OpenGL on integrated graphics, where it measured ~500 MB less RAM than Vulkan at the same power)
#                            keep     your prompt is not touched at all (Halcyon does not start Starship, and does not edit your starship.toml)
#                            colours  your own layout stays, only the colours follow the wallpaper
#                            halcyon  Halcyon's prompt (your old starship.toml is saved as starship.toml.before-halcyon)
#                          Asked once when another prompt setup is found on the machine (CachyOS, your own starship.toml ...), then remembered.
#   --choose               ask the questions above again (they are asked once, then remembered for update.sh)
#                          The FIRST install of Halcyon on a machine does this by itself: no --choose needed, you are asked everything once.
#                          Without these options and in a terminal you get a short menu; with --yes the saved / default choice is used.
#   -v, --verbose          show the output of every command (this is the default)
#   -q, --quiet            only the steps, the output goes to the log file          -h, --help      this text
# ==============================================================================================================
set -Eeo pipefail
umask 022

# ---------------------------------------------------------------------------------------------- colours
BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" WHITE=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
    RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"; MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"; WHITE="$(tput setaf 7)"
fi

# ---------------------------------------------------------------------------------------------- settings
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/hyprland.lua" ]]; then RICE_SOURCE="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/Halcyon/hyprland.lua" ]]; then RICE_SOURCE="$SCRIPT_DIR/Halcyon"
else RICE_SOURCE="$SCRIPT_DIR"; fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
AUTO_CONFIRM=false; DRY_RUN=false; VERBOSE=true        # verbose by default: you see every command's output (-q hides it)
INSTALL_APPS=true
PREBUILT=true                                  # use the helper binaries from the GitHub release of this tag when there is one (--build-from-source: compile them)
PACKAGES=true; SKIP_DRIVERS=false; SKIP_AUR=false; UPGRADE=auto; SKIP_TUNE=false
SYSMODE=true; SYSMODE_ASKED=false; [[ "${SKIP_SYSMODE:-0}" = 1 ]] && { SYSMODE=false; SYSMODE_ASKED=true; }
SAFETY=true; SAFETY_ASKED=false             # the safety check is on by default (answer n, or --no-safety-check, to skip it)
INSTALL_LLM=false; PICK_LLM_MODEL=""; LLM_ASKED=false # local AI performance advisor with Ollama
INSTALL_WHISPER=false; PICK_WHISPER_MODEL=""; WHISPER_ASKED=false   # speech-to-text for voice notes (whisper.cpp + a ggml model)
INSTALL_VLM=false; PICK_VLM_MODEL=""; VLM_ASKED=false                # picture descriptions for Notes (a vision model in Ollama)
VLM_DEFAULT_MODEL="qwen2.5vl:3b"                                       # the model Notes was tested with (scripts/halcyon-notes.py VLM_DEFAULT)
PICK_RENDERER=""      # auto | opengl | vulkan (see choose_renderer)
INSTALL_PLYMOUTH=""; PLYMOUTH_ASKED=false      # the boot splash (see choose_plymouth); "" = not decided yet
INSTALL_LUNA=false; LUNA_ASKED=false           # the LUNA extra (see choose_extras)
INSTALL_LUNA_VOICE=false; LUNA_VOICE_ASKED=false   # her voice: Kokoro model (~330 MB) and a Python environment (scripts/luna-voice-setup.sh)
PICK_FIREWALL=""                               # ai | ufw | none (see choose_apps); "" = not decided yet
# ai-firewall source: a local checkout wins (AIFW_SRC), else this repository at AIFW_REV ("" = its default branch)
AIFW_REPO="${AIFW_REPO:-https://github.com/X-netrunner/ai-firewall.git}"
AIFW_REV="${AIFW_REV:-}"
AIFW_SRC="${AIFW_SRC:-}"
# LUNA is built from this exact commit, never from whatever is on main: move the pin when a LUNA version is ready for everyone
LUNA_REPO="https://github.com/X-netrunner/LUNA-AI.git"
LUNA_REV="d4abadb0522ac0158cab64b5bbfee5fd46cc6241"       # has --stdio (the >luna window), Auto routing, voice requests
# the Security center's two modules (see choose_security): each one on or off on its own
FIREWALL=ufw; FIREWALL_ASKED=false             # ai | ufw | none
INSTALL_AV=false; AV_ASKED=false                # the ai-antivirus extra
AV_EXCEPTION=true                               # ai-antivirus: except this installer's own unit writes (docs/antivirus.md)
AIFW_SRC="${AIFW_SRC:-}"; AIFW_REPO="${AIFW_REPO:-}"; AIFW_REV="${AIFW_REV:-}"                  # where ai-firewall is built from
AV_SRC="${AV_SRC:-${SYNAPSE_SRC:-}}"; AV_REPO="${AV_REPO:-${SYNAPSE_REPO:-}}"; AV_REV="${AV_REV:-${SYNAPSE_REV:-}}" # where ai-antivirus is built from
[[ -n "$AV_SRC" || -n "$AV_REPO" ]] || AV_REPO="https://github.com/X-netrunner/ai-antivirus"   # nothing given: clone it into ~/.local/src/ai-antivirus
SECURITY_MODEL="${SECURITY_MODEL:-}"   # the assistants' local model: empty = the one that fits this laptop (security_model_for_hardware), asked on a first install
RES_MODE=""; RES_OFFSET=""; RES_PRESET=""; RES_LIMMODE=manual; RES_LIM_RAM=""; RES_LIM_CPU=""; RES_APPLY=false      # resource use (see choose_resources)
PICK_BROWSER=""; PICK_FILES=""; PICK_EDITOR=""; PICK_MUSIC=""; CHOOSE=false; APPLY_PICKS=()      # your app choices (see choose_apps)
PICK_PROMPT=""; FIRST_INSTALL=false        # your shell prompt: keep | colours | halcyon (see choose_prompt); FIRST_INSTALL: nothing was chosen on this machine yet
LINK_CONFIG=false; REQUESTED_USER=""; TTY_AUTOSTART=false; LOCK_LOGIN=auto; REMOVE_LOGIN=false; GREETER=false; REMOVE_GREETER=false; LOGIN_MODE=""; LOCK_MODE=""

WARNINGS=()          # non-fatal problems, listed again at the end
FAILED_PKGS=()       # packages that could not be installed
SUDOERS_TMP=""       # temporary sudo rule for AUR builds when run as root (removed on exit)
BUILD_DIR=""
SUDO_KEEPALIVE_PID=""
CURRENT_STEP="startup"
AUR_HELPER=""
NEED_RELOGIN=false

# ---------------------------------------------------------------------------------------------- logging
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/halcyon-install.XXXXXX")"     # unpredictable name, mode 700: nobody can pre-create it
LOG_FILE="$LOG_DIR/install.log"; : > "$LOG_FILE"

log_raw()     { printf '%b\n' "$1" >> "$LOG_FILE"; }
log_info()    { echo -e "${CYAN}${BOLD}[ INFO ]${RESET} $1"; log_raw "[INFO] $(date +%H:%M:%S) - $1"; }
log_success() { echo -e "${GREEN}${BOLD}[  OK  ]${RESET} $1"; log_raw "[OK]   $(date +%H:%M:%S) - $1"; }
log_warn()    { echo -e "${YELLOW}${BOLD}[ WARN ]${RESET} $1"; log_raw "[WARN] $(date +%H:%M:%S) - $1"; }
log_error()   { echo -e "${RED}${BOLD}[ FAIL ]${RESET} $1" >&2; log_raw "[FAIL] $(date +%H:%M:%S) - $1"; }
log_task()    { echo -e "  ${BLUE}${BOLD}•${RESET} $1"; log_raw "  • $1"; }
log_step() {
    CURRENT_STEP="$1"
    echo -e "\n${MAGENTA}${BOLD}==>${RESET} ${BOLD}${WHITE}$1${RESET}"
    echo -e "${DIM}------------------------------------------------------------${RESET}"
    log_raw "\n=== STEP: $1 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
}
warn_later() { log_warn "$1"; WARNINGS+=("$1"); }
die()        { log_error "$1"; exit 1; }

# ---------------------------------------------------------------------------------------------- cleanup + traps
cleanup() {
    local rc=$?
    trap - EXIT
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    [[ -n "$SUDOERS_TMP" ]] && as_root rm -f "$SUDOERS_TMP" 2>/dev/null || true
    [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR" 2>/dev/null || true
    if [[ $rc -ne 0 && $rc -ne 130 && $rc -ne 143 ]]; then
        echo ""
        log_error "Installation stopped during: ${CURRENT_STEP} (exit code ${rc})"
        echo -e "${YELLOW}The log is kept at: ${BOLD}${LOG_FILE}${RESET}"
        echo -e "${DIM}It is safe to run the installer again; finished steps are skipped.${RESET}\n"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'echo; log_error "Interrupted."; exit 130' INT
trap 'log_error "Terminated."; exit 143' TERM
trap 'log_raw "[ERR]  line ${LINENO}: ${BASH_COMMAND} (exit $?)"' ERR

# ---------------------------------------------------------------------------------------------- options
show_help() { sed -n '2,/^# =\{20,\}$/p' "${BASH_SOURCE[0]}" | sed '1d;$d;s/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)           AUTO_CONFIRM=true ;;
        --dry-run)          DRY_RUN=true ;;
        --no-packages)      PACKAGES=false ;;
        --build-from-source) PREBUILT=false ;;
        --no-drivers)       SKIP_DRIVERS=true ;;
        --no-aur)           SKIP_AUR=true ;;
        --upgrade)          UPGRADE=yes ;;
        --sysmode)          SYSMODE=true; SYSMODE_ASKED=true ;;
        --no-sysmode)       SYSMODE=false; SYSMODE_ASKED=true ;;
        --safety-check)     SAFETY=true; SAFETY_ASKED=true ;;
        --no-safety-check)  SAFETY=false; SAFETY_ASKED=true ;;
        --llm)              INSTALL_LLM=true; LLM_ASKED=true ;;
        --llm=*)            INSTALL_LLM=true; PICK_LLM_MODEL="${1#--llm=}"; LLM_ASKED=true ;;
        --no-llm)           INSTALL_LLM=false; LLM_ASKED=true ;;
        --whisper)          INSTALL_WHISPER=true; WHISPER_ASKED=true ;;
        --whisper=*)        INSTALL_WHISPER=true; PICK_WHISPER_MODEL="${1#--whisper=}"; WHISPER_ASKED=true
                            [[ "$PICK_WHISPER_MODEL" =~ ^(tiny|base|small)$ ]] || die "--whisper=MODEL needs tiny, base or small (see --help)" ;;
        --no-whisper)       INSTALL_WHISPER=false; WHISPER_ASKED=true ;;
        --vlm)              INSTALL_VLM=true; VLM_ASKED=true ;;
        --vlm=*)            INSTALL_VLM=true; PICK_VLM_MODEL="${1#--vlm=}"; VLM_ASKED=true
                            [[ "$PICK_VLM_MODEL" =~ ^[A-Za-z0-9._:/@+-]{1,100}$ ]] || die "--vlm=MODEL needs an Ollama model name such as qwen2.5vl:3b (see --help)" ;;
        --no-vlm)           INSTALL_VLM=false; VLM_ASKED=true ;;
        --browser)          shift; PICK_BROWSER="${1:-}"; [[ -n "$PICK_BROWSER" ]] || die "--browser needs a name (see --help)" ;;
        --browser=*)        PICK_BROWSER="${1#--browser=}" ;;
        --files|--file-manager) shift; PICK_FILES="${1:-}"; [[ -n "$PICK_FILES" ]] || die "--files needs a name (see --help)" ;;
        --files=*)          PICK_FILES="${1#--files=}" ;;
        --editor)           shift; PICK_EDITOR="${1:-}"; [[ -n "$PICK_EDITOR" ]] || die "--editor needs a name (see --help)" ;;
        --editor=*)         PICK_EDITOR="${1#--editor=}" ;;
        --music)            shift; PICK_MUSIC="${1:-}"; [[ -n "$PICK_MUSIC" ]] || die "--music needs a name (see --help)" ;;
        --music=*)          PICK_MUSIC="${1#--music=}" ;;
        --resources)        shift; RES_MODE="${1:-}"; [[ "$RES_MODE" =~ ^(low|medium|high|adaptive)$ ]] || die "--resources needs low, medium, high or adaptive" ;;
        --resources=*)      RES_MODE="${1#--resources=}"; [[ "$RES_MODE" =~ ^(low|medium|high|adaptive)$ ]] || die "--resources needs low, medium, high or adaptive" ;;
        --resource-offset)  shift; RES_OFFSET="${1:-}"; [[ "$RES_OFFSET" =~ ^[0-9]+$ && "$RES_OFFSET" -le 100 ]] || die "--resource-offset needs a number from 0 to 100" ;;
        --resource-offset=*) RES_OFFSET="${1#--resource-offset=}"; [[ "$RES_OFFSET" =~ ^[0-9]+$ && "$RES_OFFSET" -le 100 ]] || die "--resource-offset needs a number from 0 to 100" ;;
        --prompt)           shift; PICK_PROMPT="${1:-}"; [[ "$PICK_PROMPT" == colors ]] && PICK_PROMPT=colours
                            [[ "$PICK_PROMPT" =~ ^(keep|colours|halcyon)$ ]] || die "--prompt needs keep, colours or halcyon (see --help)" ;;
        --prompt=*)         PICK_PROMPT="${1#--prompt=}"; [[ "$PICK_PROMPT" == colors ]] && PICK_PROMPT=colours
                            [[ "$PICK_PROMPT" =~ ^(keep|colours|halcyon)$ ]] || die "--prompt needs keep, colours or halcyon (see --help)" ;;
        --renderer)         shift; PICK_RENDERER="${1:-}"; [[ "$PICK_RENDERER" =~ ^(auto|opengl|vulkan)$ ]] || die "--renderer needs auto, opengl or vulkan" ;;
        --renderer=*)       PICK_RENDERER="${1#--renderer=}"; [[ "$PICK_RENDERER" =~ ^(auto|opengl|vulkan)$ ]] || die "--renderer needs auto, opengl or vulkan" ;;
        --plymouth)         INSTALL_PLYMOUTH=true; PLYMOUTH_ASKED=true ;;
        --no-plymouth)      INSTALL_PLYMOUTH=false; PLYMOUTH_ASKED=true ;;
        --firewall)         shift; PICK_FIREWALL="${1:-}"; [[ "$PICK_FIREWALL" =~ ^(ai|ufw|none)$ ]] || die "--firewall needs ai, ufw or none (see --help)" ;;
        --firewall=*)       PICK_FIREWALL="${1#--firewall=}"; [[ "$PICK_FIREWALL" =~ ^(ai|ufw|none)$ ]] || die "--firewall needs ai, ufw or none (see --help)" ;;
        --luna)             INSTALL_LUNA=true; LUNA_ASKED=true ;;
        --no-luna)          INSTALL_LUNA=false; LUNA_ASKED=true ;;
        --luna-voice)       INSTALL_LUNA_VOICE=true; LUNA_VOICE_ASKED=true ;;
        --no-luna-voice)    INSTALL_LUNA_VOICE=false; LUNA_VOICE_ASKED=true ;;
        --firewall)         shift; FIREWALL="${1:-}"; FIREWALL_ASKED=true; [[ "$FIREWALL" =~ ^(ai|ufw|none)$ ]] || die "--firewall needs ai, ufw or none" ;;
        --firewall=*)       FIREWALL="${1#--firewall=}"; FIREWALL_ASKED=true; [[ "$FIREWALL" =~ ^(ai|ufw|none)$ ]] || die "--firewall needs ai, ufw or none" ;;
        --antivirus|--synapse)       INSTALL_AV=true; AV_ASKED=true ;;
        --no-antivirus|--no-synapse) INSTALL_AV=false; AV_ASKED=true ;;
        --no-av-exception)  AV_EXCEPTION=false ;;
        --choose)           CHOOSE=true ;;
        --no-tune)          SKIP_TUNE=true ;;
        --link)             LINK_CONFIG=true ;;
        --copy-config)      LINK_CONFIG=false ;;                  # the default; kept so old command lines still work
        --user)             shift; REQUESTED_USER="${1:-}"; [[ -n "$REQUESTED_USER" ]] || die "--user needs a user name" ;;
        --user=*)           REQUESTED_USER="${1#--user=}" ;;
        --tty-autostart)    TTY_AUTOSTART=true ;;
        --lock-login)       LOCK_LOGIN=1 ;;
        --no-lock-login)    LOCK_LOGIN=0 ;;
        --remove-lock-login) REMOVE_LOGIN=true ;;
        --greeter)          GREETER=true ;;
        --login-mode)       shift; LOGIN_MODE="${1:-}"; [[ "$LOGIN_MODE" =~ ^(greeter|lock|keep)$ ]] || die "--login-mode needs greeter, lock or keep" ;;
        --login-mode=*)     LOGIN_MODE="${1#--login-mode=}"; [[ "$LOGIN_MODE" =~ ^(greeter|lock|keep)$ ]] || die "--login-mode needs greeter, lock or keep" ;;
        --lock-mode)        shift; LOCK_MODE="${1:-}"; [[ "$LOCK_MODE" =~ ^(login|lock|keep)$ ]] || die "--lock-mode needs login, lock or keep" ;;
        --lock-mode=*)      LOCK_MODE="${1#--lock-mode=}"; [[ "$LOCK_MODE" =~ ^(login|lock|keep)$ ]] || die "--lock-mode needs login, lock or keep" ;;
        --remove-greeter)   REMOVE_GREETER=true ;;
        -v|--verbose)       VERBOSE=true ;;
        -q|--quiet)         VERBOSE=false ;;
        --no-apps)          INSTALL_APPS=false ;;
        -h|--help)          show_help; exit 0 ;;
        *) log_error "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

[[ "$REMOVE_LOGIN" == "true" ]] && PACKAGES=false      # undoing the login setup touches no packages

# ---------------------------------------------------------------------------------------------- helpers
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

run_as_user() {
    local env_args=( "HOME=$TARGET_HOME" "USER=$TARGET_USER" "LOGNAME=$TARGET_USER"
                     "PATH=$TARGET_HOME/.cargo/bin:$PATH" "XDG_RUNTIME_DIR=/run/user/$TARGET_UID"
                     "HALCYON_DIR=$TARGET_RICE" "HALCYON_STAMP=$TIMESTAMP" "HALCYON_PROMPT=${PICK_PROMPT:-}" )
    if [[ $EUID -eq $TARGET_UID ]]; then
        env "${env_args[@]}" "$@"
    elif [[ $EUID -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- env "${env_args[@]}" "$@"
    else
        sudo -u "$TARGET_USER" env "${env_args[@]}" "$@"
    fi
}

_exec_logged() {
    local desc="$1" rc=0; shift
    set +e
    if [[ "$VERBOSE" == "true" ]]; then "$@" 2>&1 | tee -a "$LOG_FILE"; rc=${PIPESTATUS[0]}
    else "$@" >> "$LOG_FILE" 2>&1; rc=$?; fi
    set -e
    if [[ $rc -ne 0 ]]; then
        log_error "'${desc}' failed (exit code ${rc}). Last lines of its output:"
        tail -n 12 "$LOG_FILE" | sed 's/^/      | /' >&2
    fi
    return $rc
}

run_cmd() {
    local desc="$1"; shift
    log_task "$desc"
    if [[ "$DRY_RUN" == "true" ]]; then echo -e "    ${DIM}[DRY-RUN] $*${RESET}"; return 0; fi
    _exec_logged "$desc" "$@"
}

run_as_user_cmd() {
    local desc="$1"; shift
    log_task "$desc"
    if [[ "$DRY_RUN" == "true" ]]; then echo -e "    ${DIM}[DRY-RUN] (as $TARGET_USER) $*${RESET}"; return 0; fi
    _exec_logged "$desc" run_as_user "$@"
}

# a step that may fail without stopping the installer (it is remembered and shown at the end)
try() {
    local desc="$2"
    if ! "$@"; then WARNINGS+=("$desc"); log_warn "Not fatal: '${desc}' failed; carrying on."; fi
    return 0
}

# write_root_file PATH MODE [CHECK-COMMAND...]  (content on stdin)
# The content goes to a root-owned temporary file in the SAME directory (mode 0600, so nobody else can touch it), is checked
# with CHECK-COMMAND when one is given (e.g. visudo -cf), and only then renamed over the real file in one step.
write_root_file() {
    local path="$1" mode="$2" tmp dir; shift 2
    dir="$(dirname "$path")"
    log_task "Writing $path"
    if [[ "$DRY_RUN" == "true" ]]; then cat >/dev/null; echo -e "    ${DIM}[DRY-RUN] write $path (mode $mode)${RESET}"; return 0; fi
    as_root mkdir -p "$dir" || { cat >/dev/null; return 1; }
    tmp="$(as_root mktemp "$dir/.halcyon.XXXXXX")" || { cat >/dev/null; return 1; }
    if as_root tee "$tmp" >/dev/null \
       && as_root chmod "$mode" "$tmp" && as_root chown root:root "$tmp" \
       && { [[ $# -eq 0 ]] || as_root "$@" "$tmp" >>"$LOG_FILE" 2>&1; } \
       && as_root mv -f "$tmp" "$path"; then
        return 0
    fi
    as_root rm -f "$tmp" 2>/dev/null || true
    log_error "Could not write $path"
    return 1
}

have_systemd()   { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }
user_bus_ready() { [[ -S "/run/user/${TARGET_UID}/bus" ]]; }
user_systemctl() { run_as_user env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${TARGET_UID}/bus" systemctl --user "$@"; }
unit_active()    { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled()   { systemctl is-enabled --quiet "$1" 2>/dev/null; }

enable_service() {   # enable_service UNIT [--now]
    local unit="$1" now="${2:-}"
    if have_systemd || [[ "$DRY_RUN" == "true" ]]; then
        try run_cmd "Enabling ${unit}" as_root systemctl enable "$unit"
        [[ "$now" == "--now" ]] && try run_cmd "Starting ${unit}" as_root systemctl start "$unit"
    else
        warn_later "No systemd found. Enable ${unit} in your init system by hand."
    fi
}

confirm() {   # default YES (Enter = yes). No terminal to ask on = no, so a piped install never goes ahead by itself
    [[ "$AUTO_CONFIRM" == "true" ]] && return 0
    [[ -t 0 ]] || return 1
    local ans; read -rp "$1 [Y/n]: " ans || return 1
    [[ ! "$ans" =~ ^[Nn]$ ]]
}
confirm_no() {   # default NO: only for the one thing that must never happen by pressing Enter (the lock-screen login)
    [[ "$AUTO_CONFIRM" == "true" ]] && return 1          # --yes means "no questions", never "yes to the risky one" (it used to return 0 here)
    [[ -t 0 ]] || return 1
    local ans; read -rp "$1 [y/N]: " ans || return 1
    [[ "$ans" =~ ^[Yy]$ ]]
}
ask() {       # default YES: for the normal steps
    [[ "$AUTO_CONFIRM" == "true" ]] && return 0
    [[ -t 0 ]] || return 0
    local ans; read -rp "$1 [Y/n]: " ans || return 0
    [[ ! "$ans" =~ ^[Nn]$ ]]
}

# ---------------------------------------------------------------------------------------------- banner
echo -e "${CYAN}${BOLD}"
cat <<"BANNER"
  _    _       _
 | |  | |     | |
 | |__| | __ _| | ___ _   _  ___  _ __
 |  __  |/ _` | |/ __| | | |/ _ \| '_ \
 | |  | | (_| | | (__| |_| | (_) | | | |
 |_|  |_|\__,_|_|\___|\__, |\___/|_| |_|
                       __/ |
                      |___/
BANNER
echo -e "${RESET}${BOLD}Halcyon installer${RESET}   ${DIM}log: ${LOG_FILE}${RESET}"
[[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}${BOLD}DRY RUN: nothing will be changed.${RESET}"

# ---------------------------------------------------------------------------------------------- step 1
log_step "Step 1: Checking the machine, the user and sudo"

[[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Linux."
ARCH_CPU="$(uname -m)"
case "$ARCH_CPU" in x86_64|aarch64) ;; *) warn_later "Untested CPU architecture: ${ARCH_CPU}" ;; esac

DISTRO_NAME="Linux"; DISTRO_ID="unknown"; DISTRO_LIKE=""
if [[ -f /etc/os-release ]]; then
    DISTRO_NAME="$(. /etc/os-release; echo "${NAME:-Linux}")"
    DISTRO_ID="$(. /etc/os-release; echo "${ID:-unknown}")"
    DISTRO_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
fi
PKG_MGR=""
DISTRO_FAMILY=""
if command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
    DISTRO_FAMILY="arch"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    DISTRO_FAMILY="debian"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    DISTRO_FAMILY="fedora"
fi
log_info "System: ${BOLD}${DISTRO_NAME}${RESET} (${DISTRO_ID}), ${ARCH_CPU}${PKG_MGR:+ [package manager: ${PKG_MGR}]}"

# The install command to show in a message, for this machine's package manager. Takes Arch names (the reference) and maps
# them once the name maps below are defined; pkg_hint is also used before that, with names that are the same everywhere.
pkg_hint() {
    local names=() p m
    for p in "$@"; do
        case "$PKG_MGR" in
            apt) if declare -F map_pkg_for_apt >/dev/null; then for m in $(map_pkg_for_apt "$p"); do names+=("$m"); done; else names+=("$p"); fi ;;
            dnf) if declare -F map_pkg_for_dnf >/dev/null; then for m in $(map_pkg_for_dnf "$p"); do names+=("$m"); done; else names+=("$p"); fi ;;
            *)   names+=("$p") ;;
        esac
    done
    [[ ${#names[@]} -gt 0 ]] || { echo "install ${*} with your package manager"; return 0; }
    case "$PKG_MGR" in
        apt) echo "sudo apt install ${names[*]}" ;;
        dnf) echo "sudo dnf install ${names[*]}" ;;
        *)   echo "sudo pacman -S ${names[*]}" ;;
    esac
}
upgrade_hint() {
    case "$PKG_MGR" in
        apt) echo "sudo apt update && sudo apt upgrade" ;;
        dnf) echo "sudo dnf upgrade --refresh" ;;
        *)   echo "sudo pacman -Syu" ;;
    esac
}

# NixOS is set up declaratively: the flake in this folder has a NixOS and a Home Manager module (docs/install-nix.md)
if [[ "$DISTRO_ID" == "nixos" || -e /etc/NIXOS ]]; then
    die "This is NixOS: install Halcyon with the flake in this folder (NixOS + Home Manager modules), not with install.sh. See docs/install-nix.md."
fi
if [[ "$PACKAGES" == "true" ]]; then
    [[ -n "$PKG_MGR" ]] || die "No supported package manager found (pacman, apt or dnf). Install the packages from README.md by hand, then run again with --no-packages."
    case " $DISTRO_ID $DISTRO_LIKE " in
        *" arch "*|*" cachyos "*|*" endeavouros "*|*" manjaro "*|*" garuda "*|*" artix "*|*" arcolinux "*) ;;
        *" ubuntu "*|*" pop "*|*" debian "*|*" linuxmint "*|*" elementary "*|*" zorin "*|*" kali "*) ;;
        *" fedora "*)
            # Quickshell is in Fedora from 44 on; Hyprland comes from the sdegler/hyprland COPR (asked below)
            FEDORA_VER="$(. /etc/os-release; echo "${VERSION_ID:-0}")"
            if [[ "$FEDORA_VER" =~ ^[0-9]+$ && "$FEDORA_VER" -lt 44 ]]; then
                log_warn "Fedora ${FEDORA_VER}: Quickshell is only in Fedora 44 and newer. Upgrade Fedora first (docs/install-fedora.md)."
                confirm "Go on anyway?" || exit 1
            fi ;;
        *) log_warn "${DISTRO_NAME} is not a directly tested distribution, but ${PKG_MGR} is available."
           confirm "Go on anyway?" || exit 1 ;;
    esac
fi

if [[ "$REMOVE_LOGIN" != "true" ]]; then
    [[ -f "$RICE_SOURCE/hyprland.lua" ]] || die "The Halcyon files were not found next to this script (${RICE_SOURCE}). Run install.sh from inside the Halcyon folder."
    for d in power-manager touchpad-gestures hx hal hgl recon-deceiver log-analyst attacker-dossier setStaticMac safety-check birthday-sync; do
        [[ -f "$RICE_SOURCE/src/$d/Cargo.toml" ]] || die "Missing Rust crate: ${RICE_SOURCE}/src/$d"
    done
    log_info "Halcyon files: ${RICE_SOURCE}"
fi

# ---- who is this for?
if [[ -n "$REQUESTED_USER" ]]; then
    TARGET_USER="$REQUESTED_USER"
    [[ $EUID -eq 0 || "$TARGET_USER" == "$(id -un)" ]] || die "--user can only name another user when the installer runs as root."
elif [[ $EUID -ne 0 ]]; then
    TARGET_USER="$(id -un)"
elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
else
    mapfile -t CANDIDATES < <(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /(nologin|false)$/ {print $1}')
    if [[ ${#CANDIDATES[@]} -eq 1 ]]; then TARGET_USER="${CANDIDATES[0]}"
    elif [[ "$AUTO_CONFIRM" == "true" || ! -t 0 ]]; then die "Running as root with ${#CANDIDATES[@]} possible users (${CANDIDATES[*]:-none}): say which one with --user NAME."
    else read -rp "Install Halcyon for which user? (${CANDIDATES[*]}): " TARGET_USER; fi
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "A normal (non-root) user is needed: Halcyon lives in that user's home, and AUR builds refuse to run as root."
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"
TARGET_RICE="$TARGET_HOME/.config/Halcyon"
[[ -d "$TARGET_HOME" ]] || die "Home folder '$TARGET_HOME' does not exist."
log_info "For: ${BOLD}${TARGET_USER}${RESET} (home ${TARGET_HOME}); Halcyon goes to ${BOLD}${TARGET_RICE}${RESET}"

# ---- sudo, kept alive for the whole run so a long build cannot make it ask again halfway
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required (as root: $(pkg_hint sudo | sed 's/^sudo //')), or run this as root with --user NAME."
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Checking sudo..."
        sudo -v || die "sudo did not accept the password: administrator rights are needed."
        ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
        SUDO_KEEPALIVE_PID=$!
    fi
fi

# ---- a crash, kill -9 or power cut during an AUR build can leave the temporary installer sudo rule behind (passwordless
# pacman, see ensure_aur_helper). The exit trap normally removes it; this catches the cases where the trap never ran.
STALE_SUDOERS=/etc/sudoers.d/99-halcyon-installer-tmp
if [[ "$DRY_RUN" != "true" ]] && as_root test -e "$STALE_SUDOERS" 2>/dev/null; then
    if as_root rm -f "$STALE_SUDOERS"; then log_info "Removed a leftover temporary sudo rule from an interrupted install ($STALE_SUDOERS)"
    else warn_later "A temporary sudo rule from an interrupted install is still there: remove it with  sudo rm $STALE_SUDOERS"; fi
fi

USER_SETUP="$TARGET_RICE/scripts/user-setup.sh"; [[ -f "$USER_SETUP" ]] || USER_SETUP="$RICE_SOURCE/scripts/user-setup.sh"
user_setup() {   # the per-user steps run as the user, so nothing in their home is ever owned by root
    if [[ "$DRY_RUN" == "true" ]]; then log_task "[DRY-RUN] (as $TARGET_USER) user-setup.sh $*"; return 0; fi
    run_as_user bash "$USER_SETUP" "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# ---- --remove-lock-login: undo the tty1 auto-login and stop
GETTY_DROPIN=/etc/systemd/system/getty@tty1.service.d/halcyon-autologin.conf
if [[ "$REMOVE_LOGIN" == "true" ]]; then
    log_step "Removing the lock-screen login"
    as_root rm -f "$GETTY_DROPIN"
    as_root rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
    have_systemd && as_root systemctl daemon-reload || true
    user_setup login-remove || true
    log_success "tty1 auto-login and the start-on-login lines are removed; from the next boot tty1 asks for a user name and password again."
    exit 0
fi

# ---- --remove-greeter: the old login manager (or the text console) comes back
if [[ "$REMOVE_GREETER" == "true" ]]; then
    log_step "Removing the Halcyon login screen"
    run_as_user bash "$TARGET_RICE/scripts/halcyon-greeter.sh" remove || log_warn "Could not remove it: run  $TARGET_RICE/scripts/halcyon-greeter.sh remove  yourself."
    exit 0
fi

# ---- pre-flight
if [[ "$PACKAGES" == "true" ]]; then
    if [[ "$PKG_MGR" == "pacman" ]]; then
        if [[ -e /var/lib/pacman/db.lck ]] && ! pgrep -x pacman >/dev/null 2>&1; then
            die "Stale pacman lock at /var/lib/pacman/db.lck. Remove it (sudo rm /var/lib/pacman/db.lck) and run again."
        fi
        if [[ "$DRY_RUN" != "true" ]] && command -v curl >/dev/null 2>&1 \
           && ! curl -fsS --max-time 15 -o /dev/null https://archlinux.org 2>>"$LOG_FILE"; then
            warn_later "archlinux.org is not reachable: installing missing packages will probably fail."
        fi
    elif [[ "$PKG_MGR" == "apt" ]]; then
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            die "apt / dpkg is currently locked by another process. Wait for it to finish and run again."
        fi
    fi
fi
# a leftover temporary sudo rule from a run that was killed halfway
[[ -e /etc/sudoers.d/99-halcyon-installer-tmp ]] && as_root rm -f /etc/sudoers.d/99-halcyon-installer-tmp

# your saved answers (see "your choices" below); defined here so the summary shows them instead of the defaults
CHOICES_FILE="$TARGET_HOME/.local/state/island/install-choices.env"
saved_choice() { [[ -f "$CHOICES_FILE" ]] && sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$CHOICES_FILE" | tail -n1 || true; }
# what the summary should say for a yes/no extra: yes | no | ask (the menu below decides)
planned_choice() {    # $1 = value now, $2 = decided on the command line, $3 = saved key
    local saved
    [[ "$2" == "true" || "$PACKAGES" != "true" ]] && { echo "$1"; return; }    # --no-packages: the menu and saved answers are skipped
    saved=$(saved_choice "$3")
    if [[ "$CHOOSE" == "true" || -z "$saved" ]]; then
        [[ "$PACKAGES" == "true" && "$AUTO_CONFIRM" != "true" && -t 0 ]] && echo ask || echo "$1"
    else [[ "$saved" == yes ]] && echo true || echo false; fi
}

if [[ "$DRY_RUN" != "true" ]]; then
    plan_sysmode=$(planned_choice "$SYSMODE" "$SYSMODE_ASKED" SYSMODE)
    plan_safety=$(planned_choice "$SAFETY" "$SAFETY_ASKED" SAFETY_CHECK)
    plan_firewall="$PICK_FIREWALL"
    [[ -z "$plan_firewall" && "$CHOOSE" != "true" && "$PACKAGES" == "true" ]] && plan_firewall=$(saved_choice FIREWALL)
    [[ -z "$plan_firewall" && "$PACKAGES" == "true" && "$AUTO_CONFIRM" != "true" && -t 0 ]] && plan_firewall=ask
    echo
    echo -e "${BOLD}This will:${RESET}"
    [[ "$PACKAGES" == "true" ]] && echo "  - install missing packages with ${PKG_MGR:-package manager}$([[ "$PKG_MGR" == "pacman" ]] && echo " (and a few optional ones from the AUR)")"
    echo "  - copy Halcyon to ${TARGET_RICE} (an older copy is saved in ~/.config/Halcyon-backups)"
    echo "  - build the Rust helpers, set up the Hyprland entry, the login-screen session and the user services"
    [[ "$SKIP_TUNE" != "true" ]] && echo "  - install halcyon-tune and ONE sudo rule so Gaming mode / power manager / Wi-Fi power saving work without a password prompt"
    case "$plan_sysmode" in
        true) echo "  - install the sysmode hardening CLI and its boot service" ;;
        ask)  echo "  - ask whether to install sysmode (the hardening CLI and its boot service)" ;;
    esac
    case "$plan_safety" in
        true) echo "  - install the safety check (ClamAV, rkhunter, lynis, AIDE, rsync) and add it to Settings > Security" ;;
        ask)  echo "  - ask whether to add the safety check (ClamAV, rkhunter, lynis, AIDE, rsync)" ;;
    esac
    case "$plan_firewall" in
        ufw)  echo "  - set up ufw as the firewall (deny incoming, allow outgoing)" ;;
        ask)  echo "  - ask which firewall to use (ai-firewall, ufw or none)" ;;
        none) ;;
        *)    echo "  - build and start ai-firewall (Halcyon's firewall) and add it to the island and Settings > Firewall" ;;
    esac
    confirm "Go ahead?" || { echo "Nothing was changed."; exit 0; }
fi

# ---------------------------------------------------------------------------------------------- step 2
log_step "Step 2: Package manager"

pkg_missing() {
    if [[ "$PKG_MGR" == "apt" ]]; then
        dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed" && return 1 || return 0
    elif [[ "$PKG_MGR" == "dnf" ]]; then
        rpm -q "$1" >/dev/null 2>&1 && return 1 || return 0
    else
        [[ -n "$(pacman -T "$1" 2>/dev/null)" ]]
    fi
}

# Translate Arch package names into Debian / Ubuntu / Pop!_OS package names
map_pkg_for_apt() {
    local p="$1"
    case "$p" in
        base-devel)             echo "build-essential" ;;
        pkgconf)                echo "pkg-config" ;;
        pciutils)               echo "pciutils" ;;
        git)                    echo "git" ;;
        curl)                   echo "curl" ;;
        linux-firmware)         echo "linux-firmware" ;;
        amd-ucode)              echo "amd64-microcode" ;;
        intel-ucode)            echo "intel-microcode" ;;
        mesa)                   echo "libgl1-mesa-dri mesa-vulkan-drivers libglx-mesa0" ;;
        vulkan-radeon|vulkan-intel|vulkan-virtio|vulkan-swrast) echo "mesa-vulkan-drivers" ;;
        intel-media-driver)     echo "intel-media-va-driver" ;;
        intel-gpu-tools)        echo "intel-gpu-tools" ;;
        libva-mesa-driver)      echo "mesa-va-drivers" ;;
        libva-intel-driver)     echo "i965-va-driver" ;;
        mesa-vdpau)             echo "mesa-vdpau-drivers" ;;
        vulkan-tools)           echo "vulkan-tools" ;;
        mesa-utils)             echo "mesa-utils" ;;
        libva-utils)            echo "vainfo" ;;
        vulkan-icd-loader)      echo "libvulkan1" ;;
        pipewire)               echo "pipewire" ;;
        pipewire-pulse)         echo "pipewire-pulse" ;;
        pipewire-alsa)          echo "pipewire-alsa" ;;
        wireplumber)            echo "wireplumber" ;;
        libpulse)               echo "libpulse0" ;;
        pavucontrol)            echo "pavucontrol" ;;
        sof-firmware)           echo "firmware-sof-signed" ;;
        alsa-firmware)          echo "alsa-firmware-loaders" ;;
        alsa-ucm-conf)          echo "alsa-ucm-conf" ;;
        bluez)                  echo "bluez" ;;
        bluez-utils)            echo "bluez-tools" ;;
        blueman)                echo "blueman" ;;
        networkmanager)         echo "network-manager" ;;
        network-manager-applet) echo "network-manager-gnome" ;;
        power-profiles-daemon)  echo "power-profiles-daemon" ;;
        brightnessctl)          echo "brightnessctl" ;;
        playerctl)              echo "playerctl" ;;
        upower)                 echo "upower" ;;
        iw)                     echo "iw" ;;
        polkit)                 echo "polkitd pkexec" ;;
        dbus)                   echo "dbus" ;;
        libnotify)              echo "libnotify-bin" ;;
        python-gobject)         echo "python3-gi gir1.2-atspi-2.0" ;;
        at-spi2-core)           echo "at-spi2-core" ;;
        wtype)                  echo "wtype" ;;
        qrencode)               echo "qrencode" ;;
        hyprpicker)             echo "" ;;     # not in Debian: the colour picker falls back to slurp + grim
        pacman-contrib)         echo "" ;;     # checkupdates is Arch only
        xdg-utils)              echo "xdg-utils" ;;
        xdg-user-dirs)          echo "xdg-user-dirs" ;;
        dmidecode)              echo "dmidecode" ;;
        xdg-desktop-portal-hyprland) echo "xdg-desktop-portal-hyprland" ;;
        xdg-desktop-portal-gtk)      echo "xdg-desktop-portal-gtk" ;;
        polkit-kde-agent)       echo "polkit-kde-agent-1" ;;
        hypridle)               echo "hypridle" ;;
        hyprlock)               echo "hyprlock" ;;
        hyprsunset)             echo "hyprsunset" ;;
        hyprutils)              echo "libhyprutils-dev" ;;
        qt6-base)               echo "qt6-base-dev libqt6gui6 libqt6widgets6" ;;
        qt6-declarative)        echo "qml6-module-qtquick qml6-module-qtqml qml6-module-qtquick-layouts qml6-module-qtquick-controls qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qt-labs-folderlistmodel qml6-module-qtquick-effects qml6-module-qtqml-workerscript" ;;
        qt6-svg)                echo "libqt6svg6 qml6-module-qtquick-shapes" ;;
        qt6-shadertools)        echo "qt6-shader-baker" ;;
        qt6-wayland)            echo "qt6-wayland" ;;
        qt6-5compat)            echo "qml6-module-qt5compat-graphicaleffects" ;;
        qt6-multimedia)         echo "qml6-module-qtmultimedia" ;;
        qt5-wayland)            echo "qtwayland5" ;;
        qt6ct)                  echo "qt6ct" ;;
        kvantum)                echo "qt6-style-kvantum" ;;
        kservice)               echo "libkf6service-bin libkf6service-data" ;;
        imagemagick)            echo "imagemagick" ;;
        cava)                   echo "cava" ;;
        btop)                   echo "btop" ;;
        fish)                   echo "fish" ;;
        starship)               echo "starship" ;;
        poppler)                echo "poppler-utils" ;;
        fd)                     echo "fd-find" ;;
        ripgrep)                echo "ripgrep" ;;
        fzf)                    echo "fzf" ;;
        grim)                   echo "grim" ;;
        slurp)                  echo "slurp" ;;
        wl-clipboard)           echo "wl-clipboard" ;;
        tesseract)              echo "tesseract-ocr" ;;
        tesseract-data-eng)     echo "tesseract-ocr-eng" ;;
        cliphist)               echo "cliphist" ;;
        fuzzel)                 echo "fuzzel" ;;
        util-linux)             echo "util-linux" ;;
        lsof)                   echo "lsof" ;;
        jq)                     echo "jq" ;;
        zenity)                 echo "zenity" ;;
        gamemode)               echo "gamemode" ;;
        python)                 echo "python3 python3-pip" ;;
        python-pillow)          echo "python3-pil" ;;
        inter-font)             echo "fonts-inter" ;;
        ttf-jetbrains-mono-nerd) echo "fonts-jetbrains-mono" ;;
        noto-fonts)             echo "fonts-noto-core" ;;
        noto-fonts-emoji)       echo "fonts-noto-color-emoji" ;;
        adwaita-icon-theme)     echo "adwaita-icon-theme" ;;
        gamescope)              echo "gamescope" ;;
        mangohud)               echo "mangohud" ;;
        foot)                   echo "foot" ;;
        rust)                   echo "rustc cargo" ;;
        nmap)                   echo "nmap" ;;
        tcpdump)                echo "tcpdump" ;;
        ufw)                    echo "ufw" ;;
        audit)                  echo "auditd" ;;
        docker)                 echo "docker.io" ;;
        dnscrypt-proxy)         echo "dnscrypt-proxy" ;;
        lynis)                  echo "lynis" ;;
        acct)                   echo "acct" ;;
        clamav)                 echo "clamav" ;;
        rkhunter)               echo "rkhunter" ;;
        aide)                   echo "aide" ;;
        rsync)                  echo "rsync" ;;
        nvidia-prime)           echo "nvidia-prime" ;;
        nvidia-settings)        echo "nvidia-settings" ;;
        nvtop)                  echo "nvtop" ;;
        egl-wayland)            echo "libnvidia-egl-wayland1" ;;
        libva-nvidia-driver)    echo "nvidia-vaapi-driver" ;;
        thunar-archive-plugin)  echo "thunar-archive-plugin" ;;
        thunar-volman)          echo "thunar-volman" ;;
        gvfs|gvfs-mtp)          echo "gvfs gvfs-backends" ;;
        tumbler)                echo "tumbler" ;;
        ffmpegthumbnailer)      echo "ffmpegthumbnailer" ;;
        file-roller)            echo "file-roller" ;;
        papirus-icon-theme)     echo "papirus-icon-theme" ;;
        zoxide)                 echo "zoxide" ;;
        kio-extras)             echo "kio-extras" ;;
        kde-cli-tools)          echo "kde-cli-tools" ;;
        nemo-fileroller)        echo "nemo-fileroller" ;;
        pcmanfm-gtk3)           echo "pcmanfm" ;;
        zen-browser-bin)        echo "zen-browser" ;;
        librewolf-bin)          echo "librewolf" ;;
        floorp-bin)             echo "floorp" ;;
        brave-bin)              echo "brave-browser" ;;
        google-chrome)          echo "google-chrome-stable" ;;
        vscodium-bin)           echo "codium" ;;
        spotify|spotify-launcher) echo "spotify-client" ;;
        sweet-cursors-git)      echo "sweet-cursor-theme" ;;
        lib32-*)                echo "" ;;
        *)                      echo "$p" ;;
    esac
}

# Translate Arch package names into Fedora package names ("" = not in Fedora's own repositories: skipped, see docs/install-fedora.md)
map_pkg_for_dnf() {
    local p="$1"
    case "$p" in
        base-devel)             echo "gcc gcc-c++ make patch" ;;
        pkgconf)                echo "pkgconf-pkg-config" ;;
        amd-ucode)              echo "amd-ucode-firmware" ;;
        intel-ucode)            echo "microcode_ctl" ;;
        mesa)                   echo "mesa-dri-drivers mesa-vulkan-drivers mesa-libGL mesa-libEGL" ;;
        vulkan-radeon|vulkan-intel|vulkan-virtio|vulkan-swrast) echo "mesa-vulkan-drivers" ;;
        intel-media-driver)     echo "libva-intel-media-driver" ;;
        intel-gpu-tools)        echo "igt-gpu-tools" ;;
        libva-mesa-driver)      echo "mesa-va-drivers" ;;
        libva-intel-driver)     echo "libva-intel-driver" ;;
        mesa-vdpau)             echo "mesa-vdpau-drivers" ;;
        mesa-utils)             echo "glx-utils" ;;
        vulkan-icd-loader)      echo "vulkan-loader" ;;
        pipewire-pulse)         echo "pipewire-pulseaudio" ;;
        libpulse)               echo "pulseaudio-libs" ;;
        sof-firmware)           echo "alsa-sof-firmware" ;;
        alsa-ucm-conf)          echo "alsa-ucm" ;;
        bluez-utils)            echo "bluez" ;;
        networkmanager)         echo "NetworkManager" ;;
        python-gobject)         echo "python3-gobject" ;;
        pacman-contrib)         echo "" ;;     # checkupdates is Arch only
        polkit-kde-agent)       echo "polkit-kde" ;;
        qt6-base)               echo "qt6-qtbase qt6-qtbase-gui" ;;
        qt6-declarative)        echo "qt6-qtdeclarative" ;;
        qt6-svg)                echo "qt6-qtsvg" ;;
        qt6-shadertools)        echo "qt6-qtshadertools" ;;
        qt6-wayland)            echo "qt6-qtwayland" ;;
        qt6-5compat)            echo "qt6-qt5compat" ;;
        qt6-multimedia)         echo "qt6-qtmultimedia" ;;
        qt5-wayland)            echo "qt5-qtwayland" ;;
        kservice)               echo "kf6-kservice" ;;
        imagemagick)            echo "ImageMagick" ;;
        poppler)                echo "poppler-utils" ;;
        fd)                     echo "fd-find" ;;
        tesseract-data-eng)     echo "tesseract-langpack-eng" ;;
        python)                 echo "python3 python3-pip" ;;
        python-pillow)          echo "python3-pillow" ;;
        inter-font)             echo "rsms-inter-fonts" ;;
        ttf-jetbrains-mono-nerd) echo "jetbrains-mono-fonts" ;;
        noto-fonts)             echo "google-noto-sans-fonts" ;;
        noto-fonts-emoji)       echo "google-noto-color-emoji-fonts" ;;
        rust)                   echo "rust cargo" ;;
        docker)                 echo "moby-engine" ;;
        acct)                   echo "psacct" ;;
        clamav)                 echo "clamav clamav-freshclam" ;;
        egl-wayland)            echo "egl-wayland" ;;
        thunar)                 echo "Thunar" ;;
        gvfs|gvfs-mtp)          echo "gvfs gvfs-mtp" ;;
        ffmpegthumbs)           echo "ffmpegthumbs" ;;
        pcmanfm-gtk3)           echo "pcmanfm" ;;
        whisper-cpp|whisper.cpp) echo "whisper-cpp" ;;
        sqlite)                 echo "sqlite" ;;
        libarchive)             echo "libarchive" ;;
        # not in Fedora's own repositories (RPM Fusion, COPR or the vendor's repo): skipped, see docs/install-fedora.md
        nvidia-utils|nvidia-settings|libva-nvidia-driver|nvidia-prime|nvidia-driver|nvidia-driver-550|libnvidia-egl-wayland1) echo "" ;;
        zen-browser-bin|librewolf-bin|floorp-bin|brave-bin|google-chrome|vivaldi|vscodium-bin|zed) echo "" ;;
        spotify|spotify-launcher|spicetify-cli|discord|vesktop|sweet-cursors-git|wayfreeze|bemoji|asusctl) echo "" ;;
        *-dkms)                 echo "" ;;     # Arch DKMS packages; Fedora ships these drivers in the kernel or through akmods
        lib32-*)                echo "" ;;
        *)                      echo "$p" ;;
    esac
}

ensure_aur_helper() {   # called only when an AUR package is really needed; installs yay-bin if no helper exists
    [[ "$PKG_MGR" != "pacman" ]] && return 1
    [[ -n "$AUR_HELPER" ]] && return 0
    command -v yay  >/dev/null 2>&1 && { AUR_HELPER=yay;  return 0; }
    command -v paru >/dev/null 2>&1 && { AUR_HELPER=paru; return 0; }
    [[ "$SKIP_AUR" == "true" ]] && return 1
    log_info "No AUR helper found: building 'yay-bin' from the AUR..."
    if [[ "$DRY_RUN" == "true" ]]; then log_task "[DRY-RUN] would build yay-bin"; AUR_HELPER=yay; return 0; fi
    if [[ $EUID -eq 0 && -z "$SUDOERS_TMP" ]]; then
        # makepkg refuses to run as root, and yay / makepkg call `sudo pacman`: allow exactly that, for this run only
        SUDOERS_TMP=/etc/sudoers.d/99-halcyon-installer-tmp
        if ! printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$TARGET_USER" | write_root_file "$SUDOERS_TMP" 440 visudo -cf; then
            SUDOERS_TMP=""; warn_later "Could not set up the temporary sudo rule for AUR builds."; return 1
        fi
    fi
    BUILD_DIR="$(mktemp -d /tmp/yay-build-XXXXXX)"; chown "$TARGET_UID:$TARGET_GID" "$BUILD_DIR"
    if run_as_user_cmd "Cloning yay-bin" git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$BUILD_DIR/yay-bin" \
       && run_as_user_cmd "Building and installing yay-bin" bash -c "cd '$BUILD_DIR/yay-bin' && makepkg -si --noconfirm"; then
        command -v yay >/dev/null 2>&1 && AUR_HELPER=yay
    fi
    rm -rf "$BUILD_DIR"; BUILD_DIR=""
    [[ -n "$AUR_HELPER" ]] && { log_success "yay installed"; return 0; }
    warn_later "Could not set up an AUR helper: optional AUR packages are skipped."
    return 1
}

install_pkgs_apt() {
    local critical=false repo_only=false
    while [[ "${1:-}" == --* ]]; do
        case "$1" in --critical) critical=true ;; --repo-only) repo_only=true ;; *) break ;; esac
        shift
    done
    local to_install=() p mapped m
    for p in "$@"; do
        [[ -z "$p" ]] && continue
        mapped=($(map_pkg_for_apt "$p"))
        [[ ${#mapped[@]} -eq 0 ]] && continue
        for m in "${mapped[@]}"; do
            [[ -z "$m" ]] && continue
            if pkg_missing "$m"; then
                if apt-cache show "$m" >/dev/null 2>&1; then
                    to_install+=("$m")
                else
                    if [[ "$repo_only" == "true" ]]; then
                        log_info "Not in apt repositories, skipped: $m"
                    elif [[ "$p" == "quickshell" || "$p" == "hyprland" ]]; then
                        if command -v "$p" >/dev/null 2>&1; then
                            log_info "$p is already available in PATH."
                        else
                            # (there is no maintained PPA: the one this used to offer, ppa:cpp-spence/hyprland, does not exist)
                            log_warn "$p is not in this release's apt repositories. Halcyon needs Hyprland 0.55+ and Quickshell from the distribution: Debian testing / sid or Ubuntu 26.10 and newer have both. See docs/install-debian.md."
                        fi
                    fi
                fi
            fi
        done
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        mapfile -t to_install < <(printf '%s\n' "${to_install[@]}" | sort -u)
        if ! run_cmd "Installing (apt): ${to_install[*]}" as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${to_install[@]}"; then
            log_warn "The apt batch failed: trying one package at a time..."
            for m in "${to_install[@]}"; do
                run_cmd "Installing (apt) $m" as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$m" || FAILED_PKGS+=("$m")
            done
        fi
    fi

    # Post-install symlinks for Debian/Ubuntu binary name differences
    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        try run_cmd "Linking fd to fdfind (Debian's name)" as_root ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    fi
    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
        try run_cmd "Linking bat to batcat (Debian's name)" as_root ln -sf "$(command -v batcat)" /usr/local/bin/bat
    fi

    if [[ "$critical" == "true" && "$DRY_RUN" != "true" ]]; then
        for p in "$@"; do
            command -v "$p" >/dev/null 2>&1 && continue
            mapped=($(map_pkg_for_apt "$p"))
            for m in "${mapped[@]}"; do
                pkg_missing "$m" && ! command -v "$p" >/dev/null 2>&1 && die "Required package '$m' ('$p') could not be installed. See ${LOG_FILE}"
            done
        done
    fi
    return 0
}

install_pkgs_pacman() {
    local critical=false repo_only=false
    while [[ "${1:-}" == --* ]]; do
        case "$1" in --critical) critical=true ;; --repo-only) repo_only=true ;; *) break ;; esac
        shift
    done
    local repo_pkgs=() aur_pkgs=() p
    for p in "$@"; do
        [[ -z "$p" ]] && continue
        pkg_missing "$p" || continue
        if pacman -Si "$p" >/dev/null 2>&1; then repo_pkgs+=("$p")
        elif [[ "$repo_only" == "true" ]]; then log_info "Not in the official repositories, skipped: $p"
        else aur_pkgs+=("$p"); fi
    done

    if [[ ${#repo_pkgs[@]} -gt 0 ]]; then
        if ! run_cmd "Installing: ${repo_pkgs[*]}" as_root pacman -S --needed --noconfirm "${repo_pkgs[@]}"; then
            log_warn "The batch failed: trying one package at a time..."
            for p in "${repo_pkgs[@]}"; do
                run_cmd "Installing $p" as_root pacman -S --needed --noconfirm "$p" || FAILED_PKGS+=("$p")
            done
        fi
    fi

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        if [[ "$SKIP_AUR" == "true" ]]; then
            log_info "AUR skipped (--no-aur): ${aur_pkgs[*]}"; FAILED_PKGS+=("${aur_pkgs[@]}")
        elif ! ask "Install from the AUR: ${aur_pkgs[*]}  (community PKGBUILDs, not reviewed by this installer)?"; then
            FAILED_PKGS+=("${aur_pkgs[@]}")
        elif ensure_aur_helper; then
            local flags=(-S --needed --noconfirm)
            [[ "$AUR_HELPER" == "yay"  ]] && flags+=(--answerclean None --answerdiff None --answeredit None --answerupgrade None)
            [[ "$AUR_HELPER" == "paru" ]] && flags+=(--skipreview)
            for p in "${aur_pkgs[@]}"; do
                local p_flags=("${flags[@]}")
                if [[ "$p" == "acct" ]]; then
                    p_flags+=(--mflags "CFLAGS=-Wno-error=incompatible-pointer-types")
                fi
                run_as_user_cmd "Installing $p (AUR)" "$AUR_HELPER" "${p_flags[@]}" "$p" || FAILED_PKGS+=("$p")
            done
        else FAILED_PKGS+=("${aur_pkgs[@]}"); fi
    fi

    if [[ "$critical" == "true" && "$DRY_RUN" != "true" ]]; then
        for p in "$@"; do pkg_missing "$p" && die "Required package '$p' could not be installed. See ${LOG_FILE}"; done
    fi
    return 0
}

# Fedora: Hyprland and its tools are not in Fedora's own repositories. They come from the sdegler/hyprland COPR (the
# maintained successor of solopasha/hyprland: Hyprland 0.56 for Fedora 43-45), enabled only after asking.
HYPR_COPR="sdegler/hyprland"
COPR_ASKED=false
enable_hypr_copr() {
    [[ "$COPR_ASKED" == "true" ]] && return 1
    COPR_ASKED=true
    if dnf copr list 2>/dev/null | grep -q "$HYPR_COPR"; then return 1; fi
    ask "Hyprland is not in Fedora's repositories. Enable the COPR ${HYPR_COPR} (community builds of Hyprland and its tools)?" || return 1
    run_cmd "Installing the dnf COPR plugin" as_root dnf install -y dnf-plugins-core || true
    run_cmd "Enabling the COPR ${HYPR_COPR}" as_root dnf copr enable -y "$HYPR_COPR"
}

install_pkgs_dnf() {
    local critical=false repo_only=false
    while [[ "${1:-}" == --* ]]; do
        case "$1" in --critical) critical=true ;; --repo-only) repo_only=true ;; *) break ;; esac
        shift
    done
    local wanted=() avail to_install=() p m
    for p in "$@"; do
        [[ -z "$p" ]] && continue
        for m in $(map_pkg_for_dnf "$p"); do pkg_missing "$m" && wanted+=("$m"); done
    done
    [[ ${#wanted[@]} -eq 0 ]] && return 0
    mapfile -t wanted < <(printf '%s\n' "${wanted[@]}" | sort -u)
    # one query for all of them: which names do the enabled repositories have?
    avail="$(dnf repoquery --available --qf '%{name}\n' "${wanted[@]}" 2>/dev/null | sort -u)"
    if ! grep -qx hyprland <<<"$avail" && printf '%s\n' "${wanted[@]}" | grep -qx hyprland && enable_hypr_copr; then
        avail="$(dnf repoquery --available --qf '%{name}\n' "${wanted[@]}" 2>/dev/null | sort -u)"
    fi
    for m in "${wanted[@]}"; do
        if grep -qx "$m" <<<"$avail" || [[ "$DRY_RUN" == "true" ]]; then to_install+=("$m")
        else log_info "Not in the enabled dnf repositories, skipped: $m"; [[ "$repo_only" == "true" ]] || FAILED_PKGS+=("$m"); fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        if ! run_cmd "Installing (dnf): ${to_install[*]}" as_root dnf install -y --setopt=install_weak_deps=False "${to_install[@]}"; then
            log_warn "The dnf batch failed: trying one package at a time..."
            for m in "${to_install[@]}"; do
                run_cmd "Installing (dnf) $m" as_root dnf install -y --setopt=install_weak_deps=False "$m" || FAILED_PKGS+=("$m")
            done
        fi
    fi
    if [[ "$critical" == "true" && "$DRY_RUN" != "true" ]]; then
        for p in "$@"; do
            command -v "$p" >/dev/null 2>&1 && continue
            for m in $(map_pkg_for_dnf "$p"); do
                pkg_missing "$m" && die "Required package '$m' ('$p') could not be installed. See ${LOG_FILE} and docs/install-fedora.md"
            done
        done
    fi
    return 0
}

install_pkgs() {
    if [[ "$PKG_MGR" == "apt" ]]; then
        install_pkgs_apt "$@"
    elif [[ "$PKG_MGR" == "dnf" ]]; then
        install_pkgs_dnf "$@"
    else
        install_pkgs_pacman "$@"
    fi
}

MULTILIB_ENABLED=false
if [[ "$PACKAGES" == "true" ]]; then
    if [[ "$PKG_MGR" == "apt" ]]; then
        dpkg --print-foreign-architectures 2>/dev/null | grep -q 'i386' && MULTILIB_ENABLED=true
        if [[ "$MULTILIB_ENABLED" != "true" ]]; then
            if ask "Enable i386 multiarch (32-bit architecture for Steam/Wine)?"; then
                run_cmd "Enabling i386 multiarch" as_root bash -c 'dpkg --add-architecture i386 && apt-get update -qq' && MULTILIB_ENABLED=true || true
            fi
        fi
    elif [[ "$PKG_MGR" == "dnf" ]]; then
        MULTILIB_ENABLED=true          # Fedora ships the 32-bit (i686) packages in the same repositories
    else
        grep -qE '^\s*\[multilib\]' /etc/pacman.conf 2>/dev/null && MULTILIB_ENABLED=true
    fi
    log_info "multilib (32-bit libraries): $([[ "$MULTILIB_ENABLED" == "true" ]] && echo enabled || echo "not enabled: 32-bit packages are skipped")"

    # Arch does not support installing packages on top of an old system ("partial upgrade": a new Hyprland / Mesa next to old
    # libraries is how a machine ends up not booting into its desktop). So: a machine that has no Hyprland yet, or whose
    # package databases are old, gets a full upgrade (asked first; with --yes it is done on the fresh machine). A machine
    # that already runs Hyprland and was synced recently (update.sh runs this installer often) is left alone, because an
    # upgrade can replace the kernel under a running desktop; --upgrade forces one.
    if [[ "$UPGRADE" == "auto" ]]; then
        DB_AGE_DAYS=999
        if [[ "$PKG_MGR" == "apt" ]]; then
            if DBF="$(ls -t /var/lib/apt/lists/*Packages 2>/dev/null | head -n1)" && [[ -n "$DBF" ]]; then
                DB_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$DBF") ) / 86400 ))
            fi
        elif [[ "$PKG_MGR" == "dnf" ]]; then
            if DBF="$(ls -td /var/cache/libdnf5/*/ /var/cache/dnf/*/ 2>/dev/null | head -n1)" && [[ -n "$DBF" ]]; then
                DB_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$DBF") ) / 86400 ))
            fi
        else
            if DBF="$(ls -t /var/lib/pacman/sync/*.db 2>/dev/null | head -n1)" && [[ -n "$DBF" ]]; then
                DB_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$DBF") ) / 86400 ))
            fi
        fi
        if ! command -v Hyprland >/dev/null 2>&1 || [[ "$DB_AGE_DAYS" -gt 7 ]]; then
            if [[ "$AUTO_CONFIRM" == "true" ]]; then
                command -v Hyprland >/dev/null 2>&1 && UPGRADE=no || UPGRADE=yes
            elif [[ -t 0 ]] && ask "Full system upgrade first ($(upgrade_hint))? Recommended: Hyprland is not installed yet or package caches are ${DB_AGE_DAYS} days old."; then
                UPGRADE=yes
            else UPGRADE=no; fi
        else UPGRADE=no; fi
    fi
    if [[ "$UPGRADE" == "yes" ]]; then
        if [[ "$PKG_MGR" == "apt" ]]; then
            run_cmd "Full system upgrade (apt update && upgrade)" as_root env DEBIAN_FRONTEND=noninteractive bash -c "apt-get update && apt-get upgrade -y" \
                || die "The system upgrade failed. Fix apt repositories and run again."
        elif [[ "$PKG_MGR" == "dnf" ]]; then
            run_cmd "Full system upgrade (dnf upgrade)" as_root dnf upgrade --refresh -y \
                || die "The system upgrade failed. Fix the dnf repositories and run again."
        else
            run_cmd "Full system upgrade (pacman -Syu)" as_root pacman -Syu --noconfirm \
                || die "The system upgrade failed. Fix pacman (mirrors / keyring) and run again."
        fi
    else
        log_info "No system upgrade (add --upgrade for one). If installs fail with 404 errors or missing libraries, run: $(upgrade_hint)"
    fi
    install_pkgs --critical base-devel git curl pkgconf pciutils
else
    log_info "Skipping packages (--no-packages)."
fi

# ---------------------------------------------------------------------------------------------- step 3
log_step "Step 3: Graphics drivers and CPU microcode"

kernel_headers() {
    if [[ "$PKG_MGR" == "dnf" ]]; then
        echo "kernel-devel"
        return 0
    fi
    if [[ "$PKG_MGR" == "apt" ]]; then
        local kver
        kver="$(uname -r)"
        if apt-cache show "linux-headers-$kver" >/dev/null 2>&1; then
            echo "linux-headers-$kver"
        else
            echo "linux-headers-generic"
        fi
        return 0
    fi
    local base f out=()
    for f in /usr/lib/modules/*/pkgbase; do
        [[ -f "$f" ]] || continue
        base="$(<"$f")"
        pacman -Si "${base}-headers" >/dev/null 2>&1 && out+=("${base}-headers")
    done
    [[ ${#out[@]} -eq 0 ]] && out=(linux-headers)
    printf '%s\n' "${out[@]}" | sort -u
}
installed_kernels() {   # the pkgbase of every installed kernel
    if [[ "$PKG_MGR" == "apt" || "$PKG_MGR" == "dnf" ]]; then
        uname -r
        return 0
    fi
    local f; for f in /usr/lib/modules/*/pkgbase; do [[ -f "$f" ]] && cat "$f"; done | sort -u
}

# NVIDIA generation from the lspci text of the card. The chip name decides what driver can run it:
#   TU / GA / AD / GB / GH  (Turing 2018 and newer)  -> open kernel modules, the current driver
#   GM / GP / GV            (Maxwell, Pascal, Volta) -> legacy 580xx branch (AUR); the current driver dropped them
#   GK                      (Kepler)                 -> no proprietary driver that can run Wayland: stay on nouveau
#   anything older                                   -> nouveau
nvidia_generation() {
    local t="$1"
    if   grep -qE '\b(GB|GH|AD|GA|TU)[0-9]{2,3}[A-Z]?\b|GeForce RTX|RTX [0-9A]|GTX 16[0-9]{2}' <<<"$t"; then echo open
    elif grep -qE '\b(GV|GP|GM)[0-9]{2,3}[A-Z]?\b|GTX (7[5-9]|9[0-9]|10[0-9])[0-9]?|TITAN (X|V)|GeForce MX[123][0-9]{2}' <<<"$t"; then echo maxwell-pascal
    elif grep -qE '\bGK[0-9]{2,3}[A-Z]?\b|GTX (6[0-9]{2}|7[0-4][0-9])\b' <<<"$t"; then echo kepler
    elif grep -qE '\b(GF|GT|G)[0-9]{2,3}' <<<"$t"; then echo fermi
    else echo open; fi
}

HAS_NVIDIA=false; HAS_AMD_GPU=false; HAS_INTEL_GPU=false; HYBRID_GPU=false; NEED_REBOOT=false
NVIDIA_GEN=""; GPU_ENV_MODE=none; INTEL_OLD=false; IS_VM=false

if [[ "$PACKAGES" != "true" || "$SKIP_DRIVERS" == "true" ]]; then
    log_info "Skipped ($([[ "$PACKAGES" != "true" ]] && echo "--no-packages" || echo "--no-drivers"))."
else
    command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null && IS_VM=true

    CPU_VENDOR="$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}' || true)"
    log_info "CPU: ${BOLD}${CPU_VENDOR:-unknown}${RESET}$([[ "$IS_VM" == "true" ]] && echo "  (virtual machine)")"
    install_pkgs --repo-only linux-firmware
    if [[ "$IS_VM" != "true" ]]; then
        case "$CPU_VENDOR" in
            AuthenticAMD) install_pkgs --repo-only amd-ucode ;;
            GenuineIntel) install_pkgs --repo-only intel-ucode ;;
        esac
    fi

    GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
    if [[ -z "$GPU_INFO" ]]; then log_warn "No graphics device found with lspci (virtual machine or container?)."
    else log_info "Graphics:"; echo -e "${DIM}${GPU_INFO}${RESET}"; fi

    NV_LINES="$(grep -i 'nvidia' <<<"$GPU_INFO" || true)"
    [[ -n "$NV_LINES" ]] && HAS_NVIDIA=true
    # \b matters: a bare "ati" also matches "Corporation", which put AMD packages on every machine
    grep -qiE '\b(amd|ati)\b|advanced micro devices|radeon' <<<"$(grep -vi 'nvidia' <<<"$GPU_INFO")" && HAS_AMD_GPU=true
    INTEL_LINES="$(grep -i 'intel' <<<"$GPU_INFO" || true)"
    [[ -n "$INTEL_LINES" ]] && HAS_INTEL_GPU=true
    [[ "$HAS_NVIDIA" == "true" && ( "$HAS_INTEL_GPU" == "true" || "$HAS_AMD_GPU" == "true" ) ]] && HYBRID_GPU=true
    # an Intel GPU generation the modern media driver (iHD) does not cover: it needs the old i965 VA-API driver as well
    grep -qiE 'Sandy Bridge|Ivy Bridge|Haswell|Ironlake|Westmere|Arrandale|Clarkdale|Bay Trail|Core Processor Integrated|Atom Processor' <<<"$INTEL_LINES" && INTEL_OLD=true

    # ---- NVIDIA
    if [[ "$HAS_NVIDIA" == "true" ]]; then
        NVIDIA_GEN="$(nvidia_generation "$NV_LINES")"
        log_info "NVIDIA graphics (generation: ${BOLD}${NVIDIA_GEN}${RESET})$([[ "$HYBRID_GPU" == "true" ]] && echo ", hybrid laptop: the other GPU draws the desktop, NVIDIA is for games (prime-run)")"
        NV_PRESENT=false
        if [[ "$PKG_MGR" == "apt" ]]; then
            dpkg -l 2>/dev/null | grep -qE '^ii\s+(nvidia-driver|nvidia-kernel|linux-modules-nvidia)' && NV_PRESENT=true
        elif [[ "$PKG_MGR" == "dnf" ]]; then
            { rpm -q akmod-nvidia >/dev/null 2>&1 || rpm -q kmod-nvidia >/dev/null 2>&1; } && NV_PRESENT=true
        else
            for q in nvidia nvidia-open nvidia-dkms nvidia-open-dkms nvidia-lts nvidia-580xx-dkms nvidia-470xx-dkms; do pacman -Qq "$q" >/dev/null 2>&1 && NV_PRESENT=true; done
            pacman -Qq linux-cachyos-nvidia-open >/dev/null 2>&1 && NV_PRESENT=true
        fi

        if [[ "$PKG_MGR" == "apt" ]]; then
            if [[ "$NV_PRESENT" == "true" ]]; then
                log_info "An NVIDIA kernel driver is already installed: leaving it alone."
            else
                log_info "Installing NVIDIA driver via apt..."
                if command -v ubuntu-drivers >/dev/null 2>&1; then
                    try run_cmd "Installing the recommended NVIDIA driver (ubuntu-drivers)" as_root ubuntu-drivers install
                elif apt-cache show nvidia-driver-550 >/dev/null 2>&1; then
                    install_pkgs nvidia-driver-550 libnvidia-egl-wayland1 nvidia-settings nvtop
                elif apt-cache show nvidia-driver >/dev/null 2>&1; then
                    install_pkgs nvidia-driver libnvidia-egl-wayland1 nvidia-settings nvtop
                fi
            fi
            install_pkgs --repo-only egl-wayland nvidia-settings nvtop
        elif [[ "$PKG_MGR" == "dnf" ]]; then
            # Fedora: the NVIDIA driver is in RPM Fusion (akmod-nvidia), which this installer does not add by itself
            if [[ "$NV_PRESENT" == "true" ]]; then
                log_info "An NVIDIA kernel driver is already installed: leaving it alone."
            elif dnf repoquery --available --qf '%{name}\n' akmod-nvidia 2>/dev/null | grep -qx akmod-nvidia; then
                install_pkgs --repo-only kernel-devel akmod-nvidia xorg-x11-drv-nvidia-cuda
            else
                warn_later "NVIDIA on Fedora: enable RPM Fusion (https://rpmfusion.org/Configuration), then sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda and reboot. See docs/install-fedora.md."
            fi
            install_pkgs --repo-only egl-wayland nvtop
        else
            case "$NVIDIA_GEN" in
            open)
                NVIDIA_PKGS=(nvidia-utils egl-wayland libva-nvidia-driver nvidia-settings nvtop)
                [[ "$MULTILIB_ENABLED" == "true" ]] && NVIDIA_PKGS+=(lib32-nvidia-utils)
                mapfile -t KERNELS < <(installed_kernels)
                if [[ "$NV_PRESENT" == "true" ]]; then
                    log_info "An NVIDIA kernel driver is already installed: leaving it alone."
                elif [[ "$DISTRO_ID" == "cachyos" ]] && pacman -Qq linux-cachyos >/dev/null 2>&1 && pacman -Si linux-cachyos-nvidia-open >/dev/null 2>&1; then
                    NVIDIA_PKGS+=(linux-cachyos-nvidia-open)
                elif [[ ${#KERNELS[@]} -eq 1 && "${KERNELS[0]}" == "linux" ]] && pacman -Si nvidia-open >/dev/null 2>&1; then
                    NVIDIA_PKGS+=(nvidia-open)          # built for the stock kernel: nothing to compile, nothing that can fail to build
                    log_info "Stock kernel: using the prebuilt open NVIDIA modules (nvidia-open)."
                else
                    mapfile -t HDRS < <(kernel_headers)
                    NVIDIA_PKGS+=("${HDRS[@]}")
                    if pacman -Si nvidia-open-dkms >/dev/null 2>&1; then NVIDIA_PKGS+=(nvidia-open-dkms); else NVIDIA_PKGS+=(nvidia-dkms); fi
                    log_info "Kernel(s): ${KERNELS[*]:-unknown}: using the DKMS NVIDIA driver (it is compiled for each kernel; headers are installed)."
                fi
                install_pkgs --repo-only "${NVIDIA_PKGS[@]}"
                ;;
            maxwell-pascal)
                log_warn "This NVIDIA GPU (Maxwell / Pascal / Volta) is not supported by the current NVIDIA driver any more."
                if [[ "$NV_PRESENT" == "true" ]]; then log_info "An NVIDIA kernel driver is already installed: leaving it alone."
                else
                    log_info "Using the legacy 580xx branch from the AUR (it has to be installed BEFORE the other NVIDIA packages, so nothing pulls in the new driver)."
                    mapfile -t HDRS < <(kernel_headers)
                    install_pkgs "${HDRS[@]}"
                    LEG=(nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings); [[ "$MULTILIB_ENABLED" == "true" ]] && LEG+=(lib32-nvidia-580xx-utils)
                    install_pkgs "${LEG[@]}"
                    pkg_missing nvidia-580xx-utils || install_pkgs --repo-only egl-wayland libva-nvidia-driver nvtop
                fi
                ;;
            kepler|fermi)
                warn_later "This NVIDIA GPU (${NVIDIA_GEN}) has no proprietary driver that can run a Wayland desktop. It stays on the open nouveau driver (Mesa): Halcyon works, games are slow."
                install_pkgs --repo-only mesa
                ;;
            esac
        fi

        if [[ "$NVIDIA_GEN" == "open" || "$NVIDIA_GEN" == "maxwell-pascal" ]]; then
            printf 'options nvidia_drm modeset=1 fbdev=1\n' | write_root_file /etc/modprobe.d/halcyon-nvidia.conf 644 \
                || warn_later "Could not write /etc/modprobe.d/halcyon-nvidia.conf"
            # suspend / resume with the NVIDIA driver needs these three (they only run when the machine sleeps)
            for u in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
                if [[ "$DRY_RUN" == "true" ]] || systemctl cat "$u" >/dev/null 2>&1; then try run_cmd "Enabling $u" as_root systemctl enable "$u"; fi
            done
            [[ "$NV_PRESENT" == "true" ]] || NEED_REBOOT=true
            # hybrid laptop: prime-run starts a program on the NVIDIA GPU (games: `prime-run steam`, or in Steam: prime-run %command%)
            [[ "$HYBRID_GPU" == "true" ]] && install_pkgs --repo-only nvidia-prime
            [[ "$HYBRID_GPU" == "true" ]] && GPU_ENV_MODE=hybrid || GPU_ENV_MODE=nvidia
        fi
    fi

    # ---- AMD
    if [[ "$HAS_AMD_GPU" == "true" ]]; then
        log_info "AMD graphics: Mesa + Vulkan + video acceleration..."
        AMD_PKGS=(mesa vulkan-radeon libva-mesa-driver mesa-vdpau)
        [[ "$MULTILIB_ENABLED" == "true" ]] && AMD_PKGS+=(lib32-mesa lib32-vulkan-radeon)
        install_pkgs --repo-only "${AMD_PKGS[@]}"
    fi

    # ---- Intel
    if [[ "$HAS_INTEL_GPU" == "true" ]]; then
        log_info "Intel graphics: Mesa + Vulkan + media driver$([[ "$INTEL_OLD" == "true" ]] && echo " (+ the old i965 driver for this older GPU)")..."
        INTEL_PKGS=(mesa vulkan-intel intel-media-driver intel-gpu-tools)
        [[ "$INTEL_OLD" == "true" ]] && INTEL_PKGS+=(libva-intel-driver)
        [[ "$MULTILIB_ENABLED" == "true" ]] && INTEL_PKGS+=(lib32-mesa lib32-vulkan-intel)
        install_pkgs --repo-only "${INTEL_PKGS[@]}"
    fi

    # ---- tools that tell you whether the drivers work (vainfo, vulkaninfo, glxinfo / eglinfo)
    [[ -n "$GPU_INFO" ]] && install_pkgs --repo-only libva-utils vulkan-tools mesa-utils vulkan-icd-loader
    [[ "$IS_VM" == "true" ]] && install_pkgs --repo-only mesa vulkan-virtio vulkan-swrast
fi

# ---------------------------------------------------------------------------------------------- step 4
log_step "Step 4: Audio, Bluetooth, network, power"

if [[ "$PACKAGES" == "true" ]]; then
    install_pkgs pipewire pipewire-pulse pipewire-alsa wireplumber libpulse pavucontrol
    # sound firmware: without sof-firmware / alsa-ucm-conf many new Intel and AMD laptops have NO sound device at all
    install_pkgs --repo-only sof-firmware alsa-firmware alsa-ucm-conf
    install_pkgs bluez bluez-utils blueman
    unit_enabled bluetooth.service || enable_service bluetooth.service --now

    install_pkgs networkmanager network-manager-applet
    OTHER_NET=""
    for u in systemd-networkd.service iwd.service connman.service dhcpcd.service; do unit_enabled "$u" && OTHER_NET+=" $u"; done
    if unit_enabled NetworkManager.service; then :
    elif [[ -n "$OTHER_NET" ]]; then
        warn_later "NetworkManager was NOT enabled: another network service is already enabled (${OTHER_NET# }). Halcyon's network menu needs NetworkManager: switch over by hand when you are ready."
    else enable_service NetworkManager.service --now; fi

    # power: Halcyon Auto drives power-profiles-daemon; TLP / auto-cpufreq / tuned fight it for the CPU, so one at a time
    install_pkgs power-profiles-daemon brightnessctl playerctl upower iw
    OTHER_PM=""
    for u in tlp.service auto-cpufreq.service tuned.service; do unit_enabled "$u" && OTHER_PM+=" ${u%.service}"; done
    if [[ -n "$OTHER_PM" ]]; then
        log_info "Another power manager is enabled (${OTHER_PM# }): power-profiles-daemon is left off. Settings > Power manager switches between them."
    elif ! unit_enabled power-profiles-daemon.service; then
        enable_service power-profiles-daemon.service --now
    fi

    install_pkgs polkit dbus libnotify xdg-utils xdg-user-dirs
else
    log_info "Skipped (--no-packages)."
fi

# input (touchpad gestures, idle detection) and video (brightness) groups
NEED_GROUPS=(); HAVE_GROUPS=()
for g in input video; do
    getent group "$g" >/dev/null 2>&1 || { warn_later "Group '$g' does not exist: skipped."; continue; }
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$g"; then HAVE_GROUPS+=("$g"); else NEED_GROUPS+=("$g"); fi
done
if [[ ${#NEED_GROUPS[@]} -gt 0 ]]; then
    try run_cmd "Adding $TARGET_USER to: ${NEED_GROUPS[*]}" as_root usermod -aG "$(IFS=,; echo "${NEED_GROUPS[*]}")" "$TARGET_USER"
    NEED_RELOGIN=true
elif [[ ${#HAVE_GROUPS[@]} -gt 0 ]]; then log_success "$TARGET_USER is already in: ${HAVE_GROUPS[*]}"; fi

# ---------------------------------------------------------------------------------------------- your choices
# Browser, file manager, code editor and sysmode are YOUR choice: a short menu (once), then remembered per user in
# ~/.local/state/island/install-choices.env so update.sh installs the same things again without asking.
# Order of precedence: option on the command line > the menu (terminal, no --yes) > what was saved > the default.
have_any() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && return 0; done; return 1; }

# menu_pick OUTVAR "Title" "default ids" MULTI(0|1) "id|Label|note" ...   -> OUTVAR = the chosen ids (space separated)
menu_pick() {
    local out=$1 title=$2 def=$3 multi=$4; shift 4
    local ids=() labels=() notes=() line a b c i ans tok toks=() mark picked=() defnames=""
    for line in "$@"; do IFS='|' read -r a b c <<<"$line"; ids+=("$a"); labels+=("$b"); notes+=("$c"); done
    echo -e "\n  ${CYAN}${BOLD}${title}${RESET}"
    for i in "${!ids[@]}"; do
        mark=" "; [[ " $def " == *" ${ids[$i]} "* ]] && { mark="${GREEN}*${RESET}"; defnames+="${defnames:+, }${labels[$i]}"; }
        printf '   %b %s%2d%s  %-18s %s%s%s\n' "$mark" "$BOLD" "$((i + 1))" "$RESET" "${labels[$i]}" "$DIM" "${notes[$i]}" "$RESET"
    done
    if [[ "$multi" == "1" ]]; then echo -e "   ${DIM}several are fine: 1,2  (the first one is the default)${RESET}"; fi
    read -rp "  Your choice [Enter = ${defnames}]: " ans || ans=""
    ans="${ans//,/ }"
    if [[ -z "${ans// /}" ]]; then read -ra picked <<<"$def"
    else
        read -ra toks <<<"$ans"
        for tok in "${toks[@]}"; do
            if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#ids[@]} )); then picked+=("${ids[$((tok - 1))]}")
            else
                for i in "${!ids[@]}"; do [[ "${ids[$i]}" == "$tok" ]] && picked+=("$tok"); done
            fi
        done
        [[ ${#picked[@]} -gt 0 ]] || { echo -e "  ${YELLOW}Not understood: using ${defnames}${RESET}"; read -ra picked <<<"$def"; }
    fi
    # "keep" / "none" stand alone; a single-choice menu takes the first answer only
    for tok in "${picked[@]}"; do [[ "$tok" == keep || "$tok" == none ]] && { picked=("$tok"); break; }; done
    [[ "$multi" == "1" ]] || picked=("${picked[0]}")
    printf -v "$out" '%s' "${picked[*]}"
}

browser_pkgs() { case "$1" in firefox) echo firefox ;; zen) echo zen-browser-bin ;; librewolf) echo librewolf-bin ;; floorp) echo floorp-bin ;;
                  chromium) echo chromium ;; brave) echo brave-bin ;; vivaldi) echo vivaldi ;; chrome) echo google-chrome ;; qutebrowser) echo qutebrowser ;; esac; }
files_pkgs()   { case "$1" in thunar) echo thunar thunar-archive-plugin thunar-volman gvfs gvfs-mtp tumbler ffmpegthumbnailer file-roller papirus-icon-theme ;;
                  yazi) echo yazi ffmpegthumbnailer zoxide ;; dolphin) echo dolphin ffmpegthumbs kio-extras kde-cli-tools gvfs gvfs-mtp ;;
                  nautilus) echo nautilus gvfs gvfs-mtp file-roller ;; nemo) echo nemo nemo-fileroller gvfs gvfs-mtp ;; pcmanfm) echo pcmanfm-gtk3 gvfs gvfs-mtp ;; esac; }
editor_pkgs()  { case "$1" in codium) echo vscodium-bin ;; zeditor) echo zed ;; neovim) echo neovim ;; esac; }
# Spotify: the official client through spotify-launcher (AUR 'spotify' only when that package does not exist), + spicetify to theme it.
# spotify-player / ncspot: Spotify in the terminal (both need Premium), themed by scripts/app-themes.sh. ncspot's queue shows in the
# island's Queue tab (scripts/halcyon-music.py reads what ncspot shares).
music_pkgs()   { case "$1" in
                  spotify) if ! pkg_missing spotify || ! pkg_missing spotify-launcher; then echo spicetify-cli
                           elif [[ "$PKG_MGR" == "pacman" ]] && pacman -Si spotify-launcher >/dev/null 2>&1; then echo spotify-launcher spicetify-cli; else echo spotify spicetify-cli; fi ;;
                  spotify-player) echo spotify-player ;; ncspot) echo ncspot ;; esac; }
choice_bin()   { case "$1:$2" in
                  browser:zen) echo zen-browser ;; browser:chrome) echo google-chrome-stable ;; browser:vivaldi) echo vivaldi-stable ;;
                  files:pcmanfm) echo pcmanfm ;; editor:neovim) echo nvim ;; music:spotify-player) echo spotify_player ;; music:spotify) echo spotify-launcher ;; *) echo "$2" ;; esac; }
choice_valid() { local kind=$1 id=$2 fn; case "$kind" in browser) fn=browser_pkgs ;; files) fn=files_pkgs ;; editor) fn=editor_pkgs ;; music) fn=music_pkgs ;; esac
                 [[ "$id" == keep || "$id" == none || -n "$($fn "$id")" ]]; }
apps_id()      { [[ "$1:$2" == editor:neovim ]] && echo nvim || echo "$2"; }      # the id Settings > Default apps (apps.sh) uses

detect_hardware_tier() {
    local ram_gb=0 cpus=0 gpu_desc="Integrated Graphics" vram_mb=0 tier_name="Tier 2: Mid-Range / Standard" rec_model="qwen2.5:1.5b" tier_reason=""
    ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
    cpus=$(nproc 2>/dev/null || echo 4)

    local nv_awake=true
    for _d in /sys/bus/pci/devices/*; do
        if [[ "$(cat "$_d/vendor" 2>/dev/null)" == "0x10de" ]] && [[ "$(cat "$_d/class" 2>/dev/null)" == 0x03* ]]; then
            [[ "$(cat "$_d/power/runtime_status" 2>/dev/null)" == "suspended" ]] && nv_awake=false
            break
        fi
    done
    if [[ "$nv_awake" == "true" ]] && command -v nvidia-smi >/dev/null 2>&1; then
        local nv_info
        nv_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)
        if [[ -n "$nv_info" ]]; then
            gpu_desc=$(echo "$nv_info" | awk -F',' '{print $1}' | sed 's/^[ \t]*//')
            vram_mb=$(echo "$nv_info" | awk -F',' '{print $2}' | tr -dc '0-9')
        fi
    elif lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi 'nvidia'; then
        gpu_desc="NVIDIA Dedicated Graphics (dGPU asleep)"
        vram_mb=4096
    elif lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi 'amd'; then
        gpu_desc="AMD Radeon Graphics"
    elif lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi 'intel'; then
        gpu_desc="Intel Graphics"
    fi

    # Categorize hardware tiers:
    # Tier 1: Minimal / Low-end (< 8 GB RAM, or <= 2 CPU cores)
    # Tier 2: Mid-Range / Standard (8 - 15 GB RAM, or integrated graphics / < 4 GB VRAM)
    # Tier 3: High-Performance / Dedicated GPU (>= 16 GB RAM OR dedicated GPU with >= 4 GB VRAM, 8+ CPU threads)
    if [[ "$ram_gb" -lt 8 ]] || [[ "$cpus" -le 2 ]]; then
        tier_name="Tier 1: Minimal / Low-end"
        rec_model="qwen2.5:0.5b"
        tier_reason="Low RAM/CPU detected. qwen2.5:0.5b (~390 MB) provides instant response with virtually zero RAM footprint. (The Notes AI overview is better on qwen2.5:3b-instruct, ~1.9 GB, if you have room.)"
    elif [[ "$vram_mb" -ge 4000 ]] || ([[ "$ram_gb" -ge 16 ]] && [[ "$cpus" -ge 8 ]]); then
        tier_name="Tier 3: High-Performance / Dedicated GPU"
        rec_model="qwen2.5:3b-instruct"
        tier_reason="Strong hardware detected (${cpus} threads, ~${ram_gb} GB RAM, ${gpu_desc}). qwen2.5:3b-instruct (~1.9 GB) follows rules and keeps facts straight, which the Notes AI overview needs (it gave the best, most consistent overviews in our tests, 3-6 s a note), and it is let go from memory 10 s after use. For long chats a bigger model is better: advisor model 8b"
    else
        tier_name="Tier 2: Mid-Range / Standard"
        rec_model="qwen2.5:1.5b"
        tier_reason="Standard hardware detected. qwen2.5:1.5b (~1.0 GB) delivers ideal balance of speed, low memory usage, and structured advice. (The Notes AI overview is better on qwen2.5:3b-instruct, ~1.9 GB: pick it below if you want that.)"
    fi

    echo "$ram_gb|$cpus|$gpu_desc|$vram_mb|$tier_name|$rec_model|$tier_reason"
}

choose_apps() {
    local interactive=false have_b have_e s_b s_f s_e s_m s_s s_c s_l s_lm s_w s_wm s_v s_vm s_fw ask_b=false ask_f=false ask_e=false ask_m=false ask_s=false ask_c=false ask_l=false ask_w=false ask_v=false ask_fw=false id kind
    local flag_b="$PICK_BROWSER" flag_f="$PICK_FILES" flag_e="$PICK_EDITOR" flag_m="$PICK_MUSIC"      # given on the command line
    [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && interactive=true
    s_b=$(saved_choice BROWSER); s_f=$(saved_choice FILES); s_e=$(saved_choice EDITOR); s_m=$(saved_choice MUSIC); s_s=$(saved_choice SYSMODE); s_c=$(saved_choice SAFETY_CHECK)
    s_l=$(saved_choice LLM); s_lm=$(saved_choice LLM_MODEL)
    s_w=$(saved_choice WHISPER); s_wm=$(saved_choice WHISPER_MODEL)
    s_v=$(saved_choice VLM); s_vm=$(saved_choice VLM_MODEL)
    s_fw=$(saved_choice FIREWALL)
    have_any firefox chromium google-chrome-stable brave vivaldi-stable zen-browser librewolf floorp qutebrowser && have_b=true || have_b=false
    have_any codium code code-oss cursor zeditor zed subl kate nvim && have_e=true || have_e=false
    # saved sysmode answer (only when nothing on the command line decided it)
    [[ "$SYSMODE_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_s" ]] && { [[ "$s_s" == yes ]] && SYSMODE=true || SYSMODE=false; SYSMODE_ASKED=true; }
    # saved safety-check answer (same rule: the command line wins, --choose asks again)
    [[ "$SAFETY_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_c" ]] && { [[ "$s_c" == yes ]] && SAFETY=true || SAFETY=false; SAFETY_ASKED=true; }
    # saved firewall answer (the command line wins, --choose asks again)
    [[ -z "$PICK_FIREWALL" && "$CHOOSE" != "true" && -n "$s_fw" ]] && PICK_FIREWALL="$s_fw"
    # saved LLM answer
    [[ "$LLM_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_l" ]] && { [[ "$s_l" == yes ]] && INSTALL_LLM=true || INSTALL_LLM=false; PICK_LLM_MODEL="${s_lm:-$(detect_hardware_tier | cut -d'|' -f6)}"; LLM_ASKED=true; }

    # saved speech-to-text answer (the command line wins, --choose asks again)
    [[ "$WHISPER_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_w" ]] && { [[ "$s_w" == yes ]] && INSTALL_WHISPER=true || INSTALL_WHISPER=false; PICK_WHISPER_MODEL="${s_wm:-base}"; WHISPER_ASKED=true; }
    # saved picture-model answer (same rule)
    [[ "$VLM_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_v" ]] && { [[ "$s_v" == yes ]] && INSTALL_VLM=true || INSTALL_VLM=false; PICK_VLM_MODEL="${s_vm:-$VLM_DEFAULT_MODEL}"; VLM_ASKED=true; }

    if [[ "$interactive" == "true" ]]; then
        [[ -z "$PICK_BROWSER" && ( "$CHOOSE" == "true" || -z "$s_b" ) ]] && ask_b=true
        [[ -z "$PICK_FILES"   && ( "$CHOOSE" == "true" || -z "$s_f" ) && "$INSTALL_APPS" == "true" ]] && ask_f=true
        [[ -z "$PICK_EDITOR"  && ( "$CHOOSE" == "true" || -z "$s_e" ) ]] && ask_e=true
        [[ -z "$PICK_MUSIC"   && ( "$CHOOSE" == "true" || -z "$s_m" ) && "$INSTALL_APPS" == "true" ]] && ask_m=true
        [[ "$SYSMODE_ASKED" != "true" ]] && ask_s=true
        [[ "$SAFETY_ASKED" != "true" ]] && ask_c=true
        [[ -z "$PICK_FIREWALL" ]] && ask_fw=true
        [[ "$LLM_ASKED" != "true" ]] && ask_l=true
        [[ "$WHISPER_ASKED" != "true" ]] && ask_w=true
        [[ "$VLM_ASKED" != "true" ]] && ask_v=true
        if [[ "$ask_b$ask_f$ask_e$ask_m$ask_s$ask_c$ask_fw$ask_l$ask_w$ask_v" == *true* ]]; then
            echo -e "\n${BOLD}Make it yours${RESET} ${DIM}(Enter takes the marked choice; ./install.sh --choose asks again later)${RESET}"
        fi
    fi
    # ---- web browser
    local bopts=()
    [[ "$have_b" == "true" ]] && bopts+=("keep|Keep what I have|a browser is already installed")
    bopts+=("firefox|Firefox|fast, mainstream" "zen|Zen|Firefox-based, minimal, vertical tabs (AUR)" "librewolf|LibreWolf|privacy-hardened Firefox (AUR)"
            "floorp|Floorp|Firefox-based, very customisable (AUR)" "chromium|Chromium|open-source Chrome" "brave|Brave|Chromium with built-in blocking (AUR)"
            "vivaldi|Vivaldi|Chromium, many features" "chrome|Google Chrome|(AUR)" "qutebrowser|qutebrowser|keyboard-driven")
    if [[ "$ask_b" == "true" ]]; then menu_pick PICK_BROWSER "Web browser" "$([[ "$have_b" == true ]] && echo keep || echo firefox)" 0 "${bopts[@]}"
    elif [[ -z "$PICK_BROWSER" ]]; then PICK_BROWSER="${s_b:-$([[ "$have_b" == true ]] && echo keep || echo firefox)}"; fi
    # ---- file manager
    if [[ "$ask_f" == "true" ]]; then
        menu_pick PICK_FILES "File manager" "thunar" 1 "thunar|Thunar|GUI, light, themed by Halcyon" "yazi|Yazi|terminal, very fast, image previews" \
            "dolphin|Dolphin|KDE's, feature-rich" "nautilus|Files (Nautilus)|GNOME's" "nemo|Nemo|Cinnamon's" "pcmanfm|PCManFM|tiny and quick" "none|None|I have one / skip"
    elif [[ -z "$PICK_FILES" ]]; then PICK_FILES="${s_f:-$([[ "$INSTALL_APPS" == true ]] && echo thunar || echo none)}"; fi
    # ---- code editor
    if [[ "$ask_e" == "true" ]]; then
        menu_pick PICK_EDITOR "Code editor" "$([[ "$have_e" == true ]] && echo none || echo codium)" 1 "codium|VSCodium|VS Code without Microsoft's telemetry (AUR)" \
            "zeditor|Zed|fast native editor (Rust)" "neovim|Neovim|terminal editor" "none|None|I have one / skip"
    elif [[ -z "$PICK_EDITOR" ]]; then PICK_EDITOR="${s_e:-none}"; fi
    # ---- music player(s): several are fine (the first one is what SUPER+M opens)
    if [[ "$ask_m" == "true" ]]; then
        menu_pick PICK_MUSIC "Music player" "spotify" 1 "spotify|Spotify|the official client (spotify-launcher), themed with spicetify" \
            "spotify-player|spotify-player|Spotify in the terminal, themed by Halcyon (needs Premium)" \
            "ncspot|ncspot|light and fast Spotify in the terminal, themed by Halcyon, its queue in the island (needs Premium)" "none|None|I have one / skip"
    elif [[ -z "$PICK_MUSIC" ]]; then PICK_MUSIC="${s_m:-$([[ "$INSTALL_APPS" == true ]] && echo spotify || echo none)}"; fi
    # ---- sysmode
    if [[ "$ask_s" == "true" ]]; then
        echo -e "\n  ${CYAN}${BOLD}sysmode${RESET}  ${DIM}hardening profiles + a honeypot / IDS lab: secure | relaxed | stealth | lockdown${RESET}"
        echo -e "   ${DIM}installs ~10 security tools (nmap, ufw, audit, docker, lynis ...) and a boot service; skip it if you only want the desktop${RESET}"
        if ask "  Install sysmode?"; then SYSMODE=true; else SYSMODE=false; fi
        SYSMODE_ASKED=true
    fi
    # ---- safety check (default YES; say no and it is not installed, and its Settings entry is greyed out)
    if [[ "$ask_c" == "true" ]]; then
        echo -e "\n  ${CYAN}${BOLD}Safety check${RESET}  ${DIM}one command that updates the system, scans for malware and rootkits, checks the firewall, audits and can back up to a disk${RESET}"
        echo -e "   ${DIM}installs clamav, rkhunter, lynis, aide and rsync, and adds \"Safety check\" to Settings > Security. Enter = yes. Say no and that entry stays greyed out and disabled.${RESET}"
        if confirm "  Add the safety check?"; then SAFETY=true; else SAFETY=false; fi
        SAFETY_ASKED=true
    fi
    # ---- firewall (default: Halcyon's ai-firewall; say none and Settings > Firewall stays greyed out)
    if [[ "$ask_fw" == "true" ]]; then
        menu_pick PICK_FIREWALL "Firewall" "ai" 0 \
            "ai|ai-firewall|Halcyon's: self-healing, bans scanners by itself, island page + dashboard (builds a few minutes)" \
            "ufw|ufw|the classic: deny incoming, allow outgoing" \
            "none|None|leave the firewall alone"
    elif [[ -z "$PICK_FIREWALL" ]]; then PICK_FIREWALL="${s_fw:-ai}"; fi
    # ---- local AI advisor (Ollama)
    if [[ "$ask_l" == "true" ]]; then
        local hw_data IFS='|'
        hw_data=($(detect_hardware_tier))
        unset IFS
        local h_ram="${hw_data[0]}" h_cpus="${hw_data[1]}" h_gpu="${hw_data[2]}" h_vram="${hw_data[3]}"
        local h_tier="${hw_data[4]}" h_rec="${hw_data[5]}" h_reason="${hw_data[6]}"

        echo -e "\n  ${CYAN}${BOLD}Local AI Advisor (Ollama)${RESET}  ${DIM}offline intelligent performance & system tuning advisor${RESET}"
        echo -e "   ${DIM}Hardware:       ${h_cpus} CPUs, ~${h_ram} GB RAM, ${h_gpu}$([[ -n "$h_vram" && "$h_vram" -gt 0 ]] && echo " (${h_vram} MB VRAM)")${RESET}"
        echo -e "   ${DIM}Hardware Tier:  ${BOLD}${h_tier}${RESET}"
        echo -e "   ${DIM}Recommendation: ${BOLD}${h_rec}${RESET} (${h_reason})"

        if confirm "  Install local AI advisor with Ollama?"; then
            INSTALL_LLM=true
            menu_pick PICK_LLM_MODEL "AI Advisor Model" "$h_rec" 0 \
                "qwen2.5:3b-instruct|Qwen 2.5 3B Instruct|~1.9 GB, best Notes AI overview in our tests, follows rules well (Tier 3 Pick)" \
                "qwen2.5:1.5b|Qwen 2.5 1.5B|~1.0 GB, ultra-compact, good structured output (Tier 2 Pick)" \
                "qwen2.5:0.5b|Qwen 2.5 0.5B|~390 MB, absolute minimal memory footprint (Tier 1 Pick)" \
                "llama3.2:1b|Llama 3.2 1B|~1.3 GB, fast, fine for short answers (the Notes overview may copy text)" \
                "llama3.2:3b|Llama 3.2 3B|~2.0 GB, balanced deeper analysis (needs >=3GB free VRAM/RAM)" \
                "keep|Keep existing / custom|use existing local model without pulling another"
            if [[ "$PICK_LLM_MODEL" == "keep" ]]; then
                PICK_LLM_MODEL="${s_lm:-$h_rec}"
            fi
        else
            INSTALL_LLM=false
            PICK_LLM_MODEL="none"
        fi
        LLM_ASKED=true
    elif [[ "$INSTALL_LLM" == "true" && -z "$PICK_LLM_MODEL" ]]; then
        local hw_data IFS='|'
        hw_data=($(detect_hardware_tier))
        unset IFS
        PICK_LLM_MODEL="${hw_data[5]:-qwen2.5:1.5b}"
    fi
    # ---- speech-to-text for voice notes (Whisper): ONLY installed when you say yes (nothing is downloaded on a bare Enter-less run)
    if [[ "$ask_w" == "true" ]]; then
        echo -e "\n  ${CYAN}${BOLD}Voice notes: speech-to-text (Whisper)${RESET}  ${DIM}turns a recorded voice note into text, fully offline${RESET}"
        echo -e "   ${DIM}installs whisper.cpp (the engine) and downloads ONE model (75-470 MB) from huggingface.co into ~/.local/share/whisper.cpp/models.${RESET}"
        echo -e "   ${DIM}Say no and voice notes are still recorded, just without a transcript. You can add it later: ./install.sh --whisper${RESET}"
        if confirm "  Install speech-to-text for voice notes?"; then
            INSTALL_WHISPER=true
            menu_pick PICK_WHISPER_MODEL "Whisper model" "${s_wm:-base}" 0 \
                "tiny|Tiny|~75 MB, fastest, fine for clear speech in a quiet room" \
                "base|Base|~142 MB, a good balance on a laptop (recommended)" \
                "small|Small|~466 MB, noticeably better with accents and noise, slower"
        else
            INSTALL_WHISPER=false
            PICK_WHISPER_MODEL=""
        fi
        WHISPER_ASKED=true
    fi
    [[ "$INSTALL_WHISPER" == "true" && ! "$PICK_WHISPER_MODEL" =~ ^(tiny|base|small)$ ]] && PICK_WHISPER_MODEL=base

    # ---- picture descriptions for Notes (a vision model in Ollama): ONLY installed when you say yes (it is a download of about 3 GB)
    if [[ "$ask_v" == "true" ]]; then
        echo -e "\n  ${CYAN}${BOLD}Notes: describe pictures (vision model)${RESET}  ${DIM}adds a Describe button to picture notes; a local model writes one or two sentences about the picture${RESET}"
        echo -e "   ${DIM}installs Ollama (if it is not there yet) and downloads the vision model ${VLM_DEFAULT_MODEL} (about 3 GB, needs roughly 4 GB of free RAM while it runs),${RESET}"
        echo -e "   ${DIM}then switches Settings > Notes > \"Describe pictures\" on. It only runs when you press Describe and is unloaded right after.${RESET}"
        echo -e "   ${DIM}Say no and nothing is downloaded. You can add it later: ./install.sh --vlm${RESET}"
        if confirm "  Install the vision model for picture notes?"; then
            INSTALL_VLM=true; PICK_VLM_MODEL="$VLM_DEFAULT_MODEL"
        else
            INSTALL_VLM=false; PICK_VLM_MODEL=""
        fi
        VLM_ASKED=true
    fi
    [[ "$INSTALL_VLM" == "true" && -z "$PICK_VLM_MODEL" ]] && PICK_VLM_MODEL="$VLM_DEFAULT_MODEL"

    # ---- check the names (a typo in --browser must not silently install nothing)
    local lst
    for kind in browser files editor music; do
        case "$kind" in browser) lst="$PICK_BROWSER" ;; files) lst="$PICK_FILES" ;; editor) lst="$PICK_EDITOR" ;; music) lst="$PICK_MUSIC" ;; esac
        lst="${lst//,/ }"
        for id in $lst; do choice_valid "$kind" "$id" || die "Unknown $kind '$id' (see ./install.sh --help for the names)"; done
        case "$kind" in browser) PICK_BROWSER="$lst" ;; files) PICK_FILES="$lst" ;; editor) PICK_EDITOR="$lst" ;; music) PICK_MUSIC="$lst" ;; esac
    done
    PICK_BROWSER="${PICK_BROWSER%% *}"                                  # one browser
    [[ "$PICK_BROWSER" == keep && "$have_b" != "true" ]] && PICK_BROWSER=firefox   # "keep" with nothing installed: never leave the desktop without one
    # what is new this run (command line or menu) becomes the system default; a saved choice does not override a later change in Settings
    # (only an explicit pick: a default or a saved one must never override what you chose later in Settings > Default apps)
    APPLY_PICKS=()
    [[ ( -n "$flag_b" || "$ask_b" == true ) && "$PICK_BROWSER" != keep ]] && APPLY_PICKS+=("browser=$PICK_BROWSER")
    id="${PICK_FILES%% *}";  [[ ( -n "$flag_f" || "$ask_f" == true ) && -n "$id" && "$id" != none ]] && APPLY_PICKS+=("files=$id")
    # SUPER+M opens the first music player you picked; spotify itself is left to the automatic choice (spotify or spotify-launcher, whichever got installed)
    [[ ( -n "$flag_m" || "$ask_m" == true ) && ( "${PICK_MUSIC%% *}" == spotify-player || "${PICK_MUSIC%% *}" == ncspot ) ]] && APPLY_PICKS+=("music=${PICK_MUSIC%% *}")
    id="${PICK_EDITOR%% *}"; [[ ( -n "$flag_e" || "$ask_e" == true ) && -n "$id" && "$id" != none ]] && APPLY_PICKS+=("editor=$(apps_id editor "$id")")
    log_info "Your choices: browser=${PICK_BROWSER:-keep}  files=${PICK_FILES:-none}  editor=${PICK_EDITOR:-none}  music=${PICK_MUSIC:-none}  sysmode=$([[ "$SYSMODE" == true ]] && echo yes || echo no)  safety-check=$([[ "$SAFETY" == true ]] && echo yes || echo no)  firewall=${PICK_FIREWALL:-ai}  ai-advisor=$([[ "$INSTALL_LLM" == true ]] && echo "$PICK_LLM_MODEL" || echo no)  whisper=$([[ "$INSTALL_WHISPER" == true ]] && echo "$PICK_WHISPER_MODEL" || echo no)  vision-model=$([[ "$INSTALL_VLM" == true ]] && echo "$PICK_VLM_MODEL" || echo no)"
}
if [[ "$PACKAGES" == "true" && "$REMOVE_LOGIN" != "true" ]]; then choose_apps
else PICK_BROWSER="${PICK_BROWSER:-keep}"; PICK_FILES="${PICK_FILES:-none}"; PICK_EDITOR="${PICK_EDITOR:-none}"; PICK_MUSIC="${PICK_MUSIC:-none}"; INSTALL_LLM="${INSTALL_LLM:-false}"; PICK_LLM_MODEL="${PICK_LLM_MODEL:-none}"; [[ "$INSTALL_WHISPER" == "true" && -z "$PICK_WHISPER_MODEL" ]] && PICK_WHISPER_MODEL=base; [[ "$INSTALL_VLM" == "true" && -z "$PICK_VLM_MODEL" ]] && PICK_VLM_MODEL="$VLM_DEFAULT_MODEL"; fi

# ---- your shell prompt (Starship): keep yours, keep your layout with Halcyon's colours, or switch to Halcyon's
# Asked once when ANOTHER prompt setup is found (your own starship.toml, a prompt started from your shell config, the CachyOS fish config,
# oh-my-posh, powerlevel10k ...), and on --choose. On a machine with no prompt of its own there is nothing to ask: Halcyon's is used.
# The answer is remembered (PROMPT in install-choices.env), so update.sh and the next install.sh keep it without asking again.
# Order of precedence: --prompt > the menu > what was saved > keep (another prompt found) / halcyon (nothing found).
foreign_prompt() {   # prints a short description of another prompt setup on this machine, or nothing
    local h="$TARGET_HOME" f rc
    f="$h/.config/starship.toml"
    if [[ -f "$f" ]] && ! grep -q "HALCYON STARSHIP PALETTE" "$f" 2>/dev/null; then echo "your own ~/.config/starship.toml"; return 0; fi
    if [[ -f "$f.before-halcyon" ]]; then echo "your old starship.toml (starship.toml.before-halcyon)"; return 0; fi
    for rc in "$h/.bashrc" "$h/.zshrc" "$h/.config/fish/config.fish"; do
        [[ -r "$rc" ]] || continue
        if grep -qE 'oh-my-posh|powerlevel10k|p10k' "$rc" 2>/dev/null; then echo "another prompt (oh-my-posh / powerlevel10k) in $(basename "$rc")"; return 0; fi
        if grep -qE 'STARSHIP_CONFIG|starship init' "$rc" 2>/dev/null; then echo "a Starship prompt started from your $(basename "$rc")"; return 0; fi
    done
    if compgen -G "$h/.config/fish/conf.d/*.fish" >/dev/null 2>&1; then
        for rc in "$h"/.config/fish/conf.d/*.fish; do
            [[ "$(basename "$rc")" == halcyon.fish ]] && continue
            if grep -qE 'starship init' "$rc" 2>/dev/null; then echo "a Starship prompt started from fish/conf.d/$(basename "$rc")"; return 0; fi
        done
    fi
    if [[ -d /usr/share/cachyos-fish-config ]] && grep -rqs 'starship' /usr/share/cachyos-fish-config 2>/dev/null; then echo "the CachyOS fish prompt (Starship)"; return 0; fi
    return 0
}
choose_prompt() {
    local interactive=false saved found def="" asked=false
    [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && interactive=true
    [[ -f "$CHOICES_FILE" ]] || FIRST_INSTALL=true
    saved=$(saved_choice PROMPT); found=$(foreign_prompt)
    if [[ -n "$PICK_PROMPT" ]]; then :                                                  # --prompt on the command line
    elif [[ "$interactive" == "true" && ( "$CHOOSE" == "true" || ( -z "$saved" && -n "$found" ) ) ]]; then
        def="${saved:-$([[ -n "$found" ]] && echo keep || echo halcyon)}"
        [[ "$FIRST_INSTALL" == "true" && "$CHOOSE" != "true" ]] && echo -e "\n${BOLD}Make it yours${RESET} ${DIM}(first install: you are asked once, ./install.sh --choose asks again later)${RESET}"
        [[ -n "$found" ]] && echo -e "\n  ${YELLOW}Found:${RESET} $found"
        menu_pick PICK_PROMPT "Shell prompt (Starship)" "$def" 0 \
            "keep|Keep mine|Halcyon does not touch your prompt or your starship.toml" \
            "colours|My layout, Halcyon colours|your prompt stays as it is, only its colours follow the wallpaper" \
            "halcyon|Halcyon's prompt|the rice's own prompt (your old starship.toml is saved as starship.toml.before-halcyon)"
        asked=true
    elif [[ -n "$saved" ]]; then PICK_PROMPT="$saved"
    elif [[ -f "$CHOICES_FILE" ]]; then PICK_PROMPT=""                                 # installed before this question existed: its prompt stays as it is
    else PICK_PROMPT="$([[ -n "$found" ]] && echo keep || echo halcyon)"
    fi
    [[ "$PICK_PROMPT" =~ ^(keep|colours|halcyon|)$ ]] || PICK_PROMPT=""
    log_info "Your prompt: ${PICK_PROMPT:-unchanged}$([[ -n "$found" ]] && echo "  (found: $found)")"
}
[[ "$REMOVE_LOGIN" != "true" ]] && choose_prompt

# ---------------------------------------------------------------------------------------------- resource use
# How much of the machine may Halcyon use? One question, answered with a rough estimate you can see before you pick.
# The answer becomes the DEFAULT of Settings > Performance > Resource use (the preset) and of the RAM / CPU limits that
# Startup & processes > Health compares against. It is only a starting point: change it any time in Settings.
# ESTIMATES: planning figures for ALL of Halcyon together (Hyprland, the island and its helpers) at idle / light use, NOT measured on
# your machine. The offset is the headroom: the limit is set that many percent above the estimate. See the real numbers with
# Settings > Performance > Memory ("Show what uses my RAM") or scripts/halcyon-mem.sh.
res_estimate() { case "$1" in low) echo "320 3" ;; high) echo "520 7" ;; *) echo "420 5" ;; esac; }   # RAM MB, CPU %
res_limits() {   # MODE OFFSET -> RES_LIM_RAM (MB, rounded up to 10) and RES_LIM_CPU (%, at least 3)
    local est ram cpu; est=$(res_estimate "$1"); ram=${est% *}; cpu=${est#* }
    RES_LIM_RAM=$(( ( (ram * (100 + $2) / 100 + 9) / 10 ) * 10 ))      # rounded up to 10 MB; the Settings slider runs 300 .. 1500
    (( RES_LIM_RAM < 300 )) && RES_LIM_RAM=300
    (( RES_LIM_RAM > 1500 )) && RES_LIM_RAM=1500
    RES_LIM_CPU=$(( (cpu * (100 + $2) + 99) / 100 ))
    (( RES_LIM_CPU < 3 )) && RES_LIM_CPU=3
    return 0
}
res_note() {     # MODE OFFSET -> "~420 MB RAM, ~5% CPU (±15%: 357-483 MB)"
    local est ram cpu; est=$(res_estimate "$1"); ram=${est% *}; cpu=${est#* }
    echo "~${ram} MB RAM, ~${cpu}% CPU  (±$2%: $(( ram * (100 - $2) / 100 ))-$(( ram * (100 + $2) / 100 )) MB)"
}
choose_resources() {
    local interactive=false s_m s_o rec h_tier h_ram h_cpus hw_data IFS='|' asked=false flagged=false fresh=false
    [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && interactive=true
    [[ -s "$TARGET_HOME/.local/state/island/settings.json" ]] || fresh=true
    s_m=$(saved_choice RESOURCE_MODE); s_o=$(saved_choice RESOURCE_OFFSET)
    hw_data=($(detect_hardware_tier)); unset IFS
    h_ram="${hw_data[0]:-8}"; h_cpus="${hw_data[1]:-4}"; h_tier="${hw_data[4]:-}"
    case "$h_tier" in "Tier 1"*) rec=low ;; "Tier 3"*) rec=high ;; *) rec=medium ;; esac
    [[ -n "$RES_MODE" || -n "$RES_OFFSET" ]] && flagged=true

    # precedence: command line > the menu (terminal, no --yes) > what was saved > the choice that fits this hardware
    if [[ -z "$RES_MODE" ]]; then
        if [[ "$interactive" == "true" && ( "$CHOOSE" == "true" || -z "$s_m" ) ]]; then
            echo -e "\n  ${CYAN}${BOLD}How much of this computer may Halcyon use?${RESET}  ${DIM}(${h_cpus} CPU threads, ~${h_ram} GB RAM: ${h_tier:-unknown tier})${RESET}"
            echo -e "   ${DIM}Estimates are for all of Halcyon together at idle / light use: rough planning numbers, not measured here.${RESET}"
            menu_pick RES_MODE "Resource use" "$rec" 0 \
                "low|Low|$(res_note low 15) · no blur, shadows or window animations, 30 fps, still stars" \
                "medium|Medium|$(res_note medium 15) · light blur, no shadows, 60 fps" \
                "high|High|$(res_note high 15) · everything on, as designed" \
                "adaptive|Adaptive|starts as Medium, then learns the limits from your own use (3 days)"
            asked=true
        else
            RES_MODE="${s_m:-$rec}"
            [[ "$RES_MODE" =~ ^(low|medium|high|adaptive)$ ]] || RES_MODE="$rec"
        fi
    fi
    if [[ -z "$RES_OFFSET" ]]; then
        if [[ "$interactive" == "true" && "$asked" == "true" && "$RES_MODE" != "adaptive" ]]; then
            menu_pick RES_OFFSET "Headroom above that estimate before Halcyon warns you" "15" 0 \
                "10|Tight|warn above $( res_limits "$RES_MODE" 10; echo "${RES_LIM_RAM} MB RAM / ${RES_LIM_CPU}% CPU")" \
                "15|Balanced|warn above $(res_limits "$RES_MODE" 15; echo "${RES_LIM_RAM} MB RAM / ${RES_LIM_CPU}% CPU")" \
                "25|Relaxed|warn above $(res_limits "$RES_MODE" 25; echo "${RES_LIM_RAM} MB RAM / ${RES_LIM_CPU}% CPU")"
        else
            RES_OFFSET="${s_o:-15}"
        fi
    fi
    [[ "$RES_OFFSET" =~ ^[0-9]+$ && "$RES_OFFSET" -le 100 ]] || RES_OFFSET=15

    RES_PRESET="$RES_MODE"; RES_LIMMODE=manual
    [[ "$RES_MODE" == adaptive ]] && { RES_PRESET=medium; RES_LIMMODE=auto; }
    res_limits "$RES_PRESET" "$RES_OFFSET"
    # applied on the next start of Halcyon when YOU decided it now (command line / menu), or when there are no settings yet;
    # a saved or default choice never overrides what you changed later in Settings > Performance
    [[ "$flagged" == "true" || "$asked" == "true" || "$fresh" == "true" ]] && RES_APPLY=true
    log_info "Resource use: ${RES_MODE}  $(res_note "$RES_PRESET" "$RES_OFFSET")  ->  Health warns above ${RES_LIM_RAM} MB RAM / ${RES_LIM_CPU}% CPU$([[ "$RES_LIMMODE" == auto ]] && echo " (adaptive: learned limits take over after 3 days)")$([[ "$RES_APPLY" == true ]] || echo "  [kept as it is: nothing changes on this machine]")"
}
[[ "$REMOVE_LOGIN" != "true" ]] && choose_resources

# ---- how the island draws (written to ~/.config/Halcyon/renderer, read by scripts/start-shell.sh on every start)
# auto is decided at start, not here, so it follows the GPU mode (scripts/gpu-mode.sh) and a driver installed later.
renderer_advice() {      # one line: what auto will pick on this machine, and why
    local c v igpu=false nv=false vk=false
    for c in /sys/class/drm/card[0-9]*; do
        [[ "$c" == */card[0-9]*-* ]] && continue
        v="$(cat "$c/device/vendor" 2>/dev/null)"
        case "$v" in 0x10de) nv=true ;; 0x8086|0x1002) igpu=true ;; esac
    done
    compgen -G "/usr/share/vulkan/icd.d/*.json" >/dev/null && vk=true
    if [[ "$igpu" == true && "$nv" == true ]]; then echo "hybrid laptop: OpenGL on the integrated GPU (NVIDIA stays asleep; GPU buffers are system RAM there)"
    elif [[ "$igpu" == true ]]; then echo "integrated graphics: OpenGL (its GPU buffers are system RAM; Vulkan measured ~500 MB more)"
    elif [[ "$nv" == true ]]; then echo "NVIDIA: OpenGL (the tested path; Vulkan saves nothing at idle)"
    else echo "OpenGL$([[ "$vk" == true ]] && echo ", or Vulkan when no OpenGL driver is found")"; fi
}
choose_renderer() {
    local interactive=false s_r
    [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && interactive=true
    s_r=$(saved_choice RENDERER)
    # precedence: command line > the menu (terminal, no --yes; asked with --choose or when nothing is saved) > saved > auto
    if [[ -z "$PICK_RENDERER" ]]; then
        if [[ "$interactive" == "true" && ( "$CHOOSE" == "true" || -z "$s_r" ) ]]; then
            echo -e "\n  ${CYAN}${BOLD}How should the island draw?${RESET}  ${DIM}(auto on this machine: $(renderer_advice))${RESET}"
            echo -e "   ${DIM}Same look either way. Idle power is about the same; the difference is RAM, most of all on integrated graphics.${RESET}"
            menu_pick PICK_RENDERER "Renderer" "auto" 0 \
                "auto|Auto|picked for this machine every time Halcyon starts (recommended)" \
                "opengl|OpenGL|least RAM: shares the driver Hyprland already has loaded" \
                "vulkan|Vulkan|skips Mesa's LLVM pages, but keeps far more GPU buffers per window (more RAM on integrated graphics)"
        else
            PICK_RENDERER="${s_r:-auto}"
        fi
    fi
    [[ "$PICK_RENDERER" =~ ^(auto|opengl|vulkan)$ ]] || PICK_RENDERER=auto
    log_info "Island renderer: ${PICK_RENDERER}$([[ "$PICK_RENDERER" == auto ]] && echo " -> $(renderer_advice)")"
}
[[ "$REMOVE_LOGIN" != "true" ]] && choose_renderer

# ---- the boot splash (Plymouth): asked once, then remembered; where it is already installed it is kept up to date
PLYMOUTH_THEME_DIR=/usr/share/plymouth/themes/halcyon
choose_plymouth() {
    local s_p have=false
    [[ -f "$PLYMOUTH_THEME_DIR/halcyon.script" ]] && have=true
    if ! command -v mkinitcpio >/dev/null 2>&1; then
        INSTALL_PLYMOUTH=false
        [[ "$PLYMOUTH_ASKED" == "true" ]] && log_warn "The boot splash needs mkinitcpio (Arch): skipped."
        return 0
    fi
    s_p=$(saved_choice PLYMOUTH)
    # precedence: command line > the question (terminal, no --yes; first time or --choose) > saved > already installed here
    if [[ "$PLYMOUTH_ASKED" != "true" ]]; then
        if [[ "$AUTO_CONFIRM" != "true" && -t 0 && ( "$CHOOSE" == "true" || -z "$s_p" ) ]]; then
            echo -e "\n  ${CYAN}${BOLD}Boot splash (Plymouth)${RESET}  ${DIM}the login splash's moving stars and sparkle while the computer boots, played backwards on shutdown${RESET}"
            echo -e "   ${DIM}installs plymouth, adds it to mkinitcpio and 'quiet splash' to the boot entry (each file is backed up first), rebuilds the initramfs.${RESET}"
            echo -e "   ${DIM}Redone in your colours on every update. Take it out any time: ~/.config/Halcyon/scripts/halcyon-plymouth.sh remove${RESET}"
            if confirm "  Set up the boot splash?"; then INSTALL_PLYMOUTH=true; else INSTALL_PLYMOUTH=false; fi
        elif [[ -n "$s_p" ]]; then
            [[ "$s_p" == yes ]] && INSTALL_PLYMOUTH=true || INSTALL_PLYMOUTH=false
        else
            INSTALL_PLYMOUTH=$have
        fi
        PLYMOUTH_ASKED=true
    fi
    log_info "Boot splash: $([[ "$INSTALL_PLYMOUTH" == true ]] && { [[ "$have" == true ]] && echo "on (updated in step 12)" || echo "set up in step 12"; } || echo "not set up")"
}
[[ "$REMOVE_LOGIN" != "true" ]] && choose_plymouth

# ---- extras: other projects by Halcyon's author, offered once (first install, or --choose), default no, then remembered.
# Only LUNA for now; a project joins this list when it installs cleanly on someone else's machine.
choose_extras() {
    local s_l
    s_l=$(saved_choice LUNA)
    if [[ "$LUNA_ASKED" != "true" ]]; then
        if [[ "$AUTO_CONFIRM" != "true" && -t 0 && ( "$CHOOSE" == "true" || -z "$s_l" ) ]]; then
            echo -e "\n  ${CYAN}${BOLD}Extra: LUNA${RESET}  ${DIM}a local AI assistant (Rust, runs on Ollama): tools, memory, reminders, voice (github.com/X-netrunner/LUNA-AI)${RESET}"
            echo -e "   ${DIM}builds it from a pinned version into ~/.local/bin/luna (a few minutes of compiling; the build folder, a few GB, is removed afterwards).${RESET}"
            echo -e "   ${DIM}Its background daemon is NOT switched on: read its README first (it can back up to /dev/sda1 and run updates).${RESET}"
            if confirm_no "  Install LUNA?"; then INSTALL_LUNA=true; else INSTALL_LUNA=false; fi
        elif [[ -n "$s_l" ]]; then
            [[ "$s_l" == yes ]] && INSTALL_LUNA=true || INSTALL_LUNA=false
        fi
        LUNA_ASKED=true
    fi
    if [[ "$INSTALL_LUNA" == "true" && "$LUNA_VOICE_ASKED" != "true" ]]; then
        local s_v; s_v=$(saved_choice LUNA_VOICE)
        if [[ "$AUTO_CONFIRM" != "true" && -t 0 && ( "$CHOOSE" == "true" || -z "$s_v" ) ]]; then
            echo -e "\n  ${CYAN}${BOLD}Extra: LUNA's voice${RESET}  ${DIM}she reads her answers aloud (Kokoro, runs on this computer)${RESET}"
            echo -e "   ${DIM}downloads about 330 MB from the kokoro-onnx GitHub release and makes a small Python environment in ~/.local/share/luna.${RESET}"
            if confirm_no "  Give LUNA a voice?"; then INSTALL_LUNA_VOICE=true; else INSTALL_LUNA_VOICE=false; fi
        elif [[ -n "$s_v" ]]; then
            [[ "$s_v" == yes ]] && INSTALL_LUNA_VOICE=true || INSTALL_LUNA_VOICE=false
        fi
        LUNA_VOICE_ASKED=true
    fi
    [[ "$INSTALL_LUNA" != "true" ]] && INSTALL_LUNA_VOICE=false
    log_info "Extras: LUNA $([[ "$INSTALL_LUNA" == true ]] && echo "yes (built in step 12)" || echo no)"
}
[[ "$REMOVE_LOGIN" != "true" ]] && choose_extras

# The qwen3.5 size the security assistants should use here: the GPU's memory when it has a big enough NVIDIA card, else RAM and threads.
# qwen3.5 download sizes: 0.8b 1.2 GB, 2b 2.7 GB, 4b 3.3 GB, 9b 6.6 GB.
security_model_for_hardware() {
    local hw=() IFS='|'; hw=($(detect_hardware_tier)); unset IFS
    local ram=${hw[0]:-8} cpus=${hw[1]:-4} vram=${hw[3]:-0}
    [[ "$vram" =~ ^[0-9]+$ ]] || vram=0
    if   [[ "$ram" -lt 8 || "$cpus" -le 2 ]]; then echo qwen3.5:0.8b
    elif [[ "$vram" -ge 8000 ]]; then echo qwen3.5:9b
    elif [[ "$vram" -ge 4000 || ( "$ram" -ge 16 && "$cpus" -ge 8 ) ]]; then echo qwen3.5:4b
    else echo qwen3.5:2b; fi
}
SECURITY_MODEL_PICKED=false   # true when you chose it now (then it also replaces the model in ai-antivirus.toml)

# ---- the Security center: which firewall, and ai-antivirus. Same rules as the other choices: the command line wins,
# --choose asks again, otherwise the saved answer is used. Each module is independent of the other.
choose_security() {
    local s_f s_s interactive=false have_fw=ufw have_syn=false
    s_f=$(saved_choice FIREWALL); s_s=$(saved_choice ANTIVIRUS); [[ -n "$s_s" ]] || s_s=$(saved_choice SYNAPSE)   # SYNAPSE: the old name
    [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && interactive=true
    # nothing saved yet: what is already on the machine is the default, so an install made by hand is never removed
    [[ -e /usr/local/bin/ai-firewall ]] || pacman -Q ai-firewall >/dev/null 2>&1 && have_fw=ai
    pacman -Q ai-antivirus >/dev/null 2>&1 || pacman -Q synapse-edr >/dev/null 2>&1 && have_syn=true
    if [[ "$FIREWALL_ASKED" != "true" && -z "$s_f" && ( "$interactive" != "true" ) ]]; then
        FIREWALL=$have_fw          # not asked: nothing gets removed (FIREWALL_ASKED stays false)
    elif [[ "$FIREWALL_ASKED" != "true" ]]; then
        if [[ "$interactive" == "true" && ( "$CHOOSE" == "true" || -z "$s_f" ) ]]; then
            menu_pick FIREWALL "Firewall" "${s_f:-$have_fw}" 0 "ufw|ufw|the classic, what Halcyon used so far" \
                "ai|ai-firewall|eBPF firewall with auto-bans, live tests and a local assistant (built from source: nightly Rust + bpf-linker)" \
                "none|None|Halcyon sets no firewall up"
        elif [[ -n "$s_f" ]]; then
            FIREWALL="$s_f"
        fi
        FIREWALL_ASKED=true
    fi
    if [[ "$AV_ASKED" != "true" && -z "$s_s" && "$interactive" != "true" ]]; then
        INSTALL_AV=$have_syn  # not asked: an installed package is kept, nothing new is built
    elif [[ "$AV_ASKED" != "true" ]]; then
        if [[ "$interactive" == "true" && ( "$CHOOSE" == "true" || -z "$s_s" ) ]]; then
            echo -e "\n  ${CYAN}${BOLD}Extra: ai-antivirus${RESET}  ${DIM}AI antivirus / EDR: eBPF + fanotify sensor, YARA and behaviour rules, alert-only until you change it${RESET}"
            echo -e "   ${DIM}built as a pacman package from source (needs bpf-linker for its eBPF part); shows up in the Security center.${RESET}"
            if [[ "$have_syn" == "true" ]]; then
                if confirm "  Keep ai-antivirus?"; then INSTALL_AV=true; else INSTALL_AV=false; fi
            elif confirm_no "  Install ai-antivirus?"; then INSTALL_AV=true; else INSTALL_AV=false; fi
        elif [[ -n "$s_s" ]]; then
            [[ "$s_s" == yes ]] && INSTALL_AV=true || INSTALL_AV=false
        fi
        AV_ASKED=true
    fi
    log_info "Security: firewall $FIREWALL, antivirus $([[ "$INSTALL_AV" == true ]] && echo "yes (built in step 12)" || echo no)"
    # the assistants' model: SECURITY_MODEL wins, then the saved one, else what fits this laptop (a menu on a first install or --choose)
    if [[ "$FIREWALL" == ai || "$INSTALL_AV" == "true" ]] && [[ "$SECURITY_MODEL" != none ]]; then
        local s_m rec; s_m=$(saved_choice SECURITY_MODEL); rec=$(security_model_for_hardware)
        if [[ -n "$SECURITY_MODEL" ]]; then SECURITY_MODEL_PICKED=true
        elif [[ -n "$s_m" && "$CHOOSE" != "true" ]]; then SECURITY_MODEL="$s_m"
        elif [[ "$interactive" == "true" ]]; then
            menu_pick SECURITY_MODEL "Security assistants' model (Ollama)" "$rec" 0 \
                "qwen3.5:0.8b|Qwen 3.5 0.8B|~1.2 GB, for weak laptops (under 8 GB RAM): short answers only" \
                "qwen3.5:2b|Qwen 3.5 2B|~2.7 GB, light: 8 GB RAM, no big GPU" \
                "qwen3.5:4b|Qwen 3.5 4B|~3.3 GB, the balance: 16 GB RAM or a 4 GB GPU" \
                "qwen3.5:9b|Qwen 3.5 9B|~6.6 GB, the best analysis: an 8 GB+ GPU" \
                "none|None|no model: the assistants answer from the doctor and status"
            [[ "$SECURITY_MODEL" == "$rec" ]] || SECURITY_MODEL_PICKED=true
        else SECURITY_MODEL="$rec"; fi
        log_info "Security assistants' model: $SECURITY_MODEL (suggested for this laptop: $rec)"
    fi
}
[[ "$REMOVE_LOGIN" != "true" ]] && choose_security

# ---------------------------------------------------------------------------------------------- step 5
log_step "Step 5: Hyprland and the desktop"

if [[ "$PACKAGES" == "true" ]]; then
    install_pkgs --critical hyprland quickshell mesa vulkan-icd-loader
    CORE=(xdg-desktop-portal-hyprland xdg-desktop-portal-gtk polkit-kde-agent
          hypridle hyprlock hyprsunset hyprutils
          qt6-base qt6-declarative qt6-svg qt6-shadertools qt6-wayland qt6-5compat qt6-multimedia qt5-wayland qt6ct kvantum kservice
          imagemagick cava btop fish starship poppler fd ripgrep fzf grim slurp wl-clipboard cliphist fuzzel tesseract tesseract-data-eng
          dmidecode util-linux lsof jq zenity gamemode python python-pillow libnotify
          hyprpicker qrencode pacman-contrib libpulse wtype
          inter-font ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji adwaita-icon-theme)
    # (the browser, file manager and editor you chose are installed below)
    install_pkgs "${CORE[@]}"
    # AUR: the cursor theme Halcyon is configured for, the log-out menu, emoji picker, frozen screenshots
    install_pkgs sweet-cursors-git wlogout bemoji wayfreeze
    # On Debian/Ubuntu, ensure JetBrainsMono Nerd Font is installed in ~/.local/share/fonts if not present
    if [[ ( "$PKG_MGR" == "apt" || "$PKG_MGR" == "dnf" ) && "$DRY_RUN" != "true" ]] && ! run_as_user bash -c 'fc-list 2>/dev/null | grep -qi "JetBrainsMono Nerd"'; then
        log_info "Installing JetBrainsMono Nerd Font to $TARGET_HOME/.local/share/fonts..."
        try run_as_user_cmd "Downloading JetBrainsMono Nerd Font" bash -c '
            fdir="$HOME/.local/share/fonts/JetBrainsMonoNerd"
            mkdir -p "$fdir"
            tmp="$(mktemp -d)"
            # pinned release and checksum (bump both together)
            url="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz"
            sum="04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf"
            if curl -fsSL -o "$tmp/jb.tar.xz" "$url" && echo "$sum  $tmp/jb.tar.xz" | sha256sum -c --status; then
                tar -xJf "$tmp/jb.tar.xz" -C "$fdir" && fc-cache -f "$fdir"
            else
                echo "JetBrainsMono Nerd Font: download failed or the checksum did not match; skipped" >&2
            fi
            rm -rf "$tmp"'
    fi

    # ---- the apps YOU chose (choose_apps above): web browser, file manager(s), code editor(s)
    CH_PKGS=()
    for id in $PICK_BROWSER; do [[ "$id" == keep ]] || CH_PKGS+=($(browser_pkgs "$id")); done
    for id in $PICK_FILES;   do [[ "$id" == none ]] || CH_PKGS+=($(files_pkgs "$id")); done
    for id in $PICK_EDITOR;  do [[ "$id" == none ]] || CH_PKGS+=($(editor_pkgs "$id")); done
    for id in $PICK_MUSIC;   do [[ "$id" == none ]] || CH_PKGS+=($(music_pkgs "$id")); done
    if [[ ${#CH_PKGS[@]} -gt 0 ]]; then
        log_info "Your apps: browser ${PICK_BROWSER:-keep}, files ${PICK_FILES:-none}, editor ${PICK_EDITOR:-none}, music ${PICK_MUSIC:-none}"
        install_pkgs "${CH_PKGS[@]}"
    fi
    # ---- terminal, music, chat: installed unless --no-apps
    if [[ "$INSTALL_APPS" == "true" ]]; then
        log_info "Apps: foot (terminal), Discord (+ Vesktop so it can wear the rice colours); music is your choice (--music, ./install.sh --choose)"
        install_pkgs foot
        install_pkgs discord
        # themes: stock Discord cannot be themed, Vesktop (AUR) is a themeable Discord client
        install_pkgs vesktop
    else
        log_info "Apps skipped (--no-apps): foot, Discord."
    fi
    # ---- Ollama itself (used by the Local AI Advisor and by the picture model for Notes): installed and started once per run
    # Debian / Ubuntu do not package it: the official release archive, pinned to one version and checked against its SHA-256
    # (from that release's sha256sum.txt; bump the version and both sums together). No remote script is run.
    OLLAMA_VERSION="v0.40.11"
    OLLAMA_SHA256_amd64="7bedab90dd122661be78798e9f0edf37fccf0cccf2699d2c58ea1a3afdc04b6d"
    OLLAMA_SHA256_arm64="77b278837b9e62c172f77d703675be4c52c8054e9075639031a9a6d5a53f1924"
    install_ollama_release() {
        local arch sum url tmp
        case "$ARCH_CPU" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) warn_later "Ollama: no release for ${ARCH_CPU}"; return 1 ;; esac
        sum="OLLAMA_SHA256_${arch}"; sum="${!sum}"
        url="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/ollama-linux-${arch}.tar.zst"
        install_pkgs zstd
        if [[ "$DRY_RUN" == "true" ]]; then
            run_cmd "Ollama ${OLLAMA_VERSION}: download and check the SHA-256" curl -fsSL -o "<tmp>/ollama.tar.zst" "$url"
            run_cmd "Ollama ${OLLAMA_VERSION}: unpack into /usr/local" as_root tar --zstd -xf "<tmp>/ollama.tar.zst" -C /usr/local
            return 0
        fi
        tmp="$(mktemp -d)" || return 1
        if ! curl -fsSL -o "$tmp/ollama.tar.zst" "$url" 2>>"$LOG_FILE" || ! echo "$sum  $tmp/ollama.tar.zst" | sha256sum -c --status; then
            rm -rf "$tmp"
            warn_later "Ollama ${OLLAMA_VERSION}: the download failed or its checksum did not match, so it was not installed."
            return 1
        fi
        run_cmd "Ollama ${OLLAMA_VERSION}: unpacking into /usr/local (checksum ok)" as_root tar --zstd -xf "$tmp/ollama.tar.zst" -C /usr/local
        local rc=$?
        rm -rf "$tmp"
        return $rc
    }
    OLLAMA_READY=false
    setup_ollama() {
        [[ "$OLLAMA_READY" == "true" ]] && return 0
        ollama_bin="$(run_as_user which ollama 2>/dev/null || which ollama 2>/dev/null || echo "")"
        if [[ -z "$ollama_bin" ]]; then
            if [[ "$DISTRO_FAMILY" == "arch" || "$DISTRO_FAMILY" == "fedora" ]]; then
                install_pkgs ollama
            else
                install_ollama_release || true
            fi
            ollama_bin="$(run_as_user which ollama 2>/dev/null || which ollama 2>/dev/null || echo "")"
        fi
        if have_systemd; then
            if systemctl cat ollama.service >/dev/null 2>&1; then
                try as_root systemctl enable --now ollama
            else
                run_as_user mkdir -p "$TARGET_HOME/.config/systemd/user"
                cat <<EOF | run_as_user tee "$TARGET_HOME/.config/systemd/user/ollama.service" >/dev/null
[Unit]
Description=Ollama Service (User)
After=network.target

[Service]
ExecStart=${ollama_bin:-ollama} serve
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=127.0.0.1:11434"

[Install]
WantedBy=default.target
EOF
                user_systemctl daemon-reload 2>/dev/null || true
                user_systemctl enable --now ollama.service 2>/dev/null || true
            fi
        fi
        OLLAMA_READY=true
    }
    # ---- Local AI Advisor (Ollama)
    if [[ "$INSTALL_LLM" == "true" && -n "$PICK_LLM_MODEL" && "$PICK_LLM_MODEL" != "none" ]]; then
        log_info "Local AI Advisor: setting up Ollama + model ${PICK_LLM_MODEL}"
        setup_ollama
        if [[ "$DRY_RUN" != "true" ]]; then
            sleep 2
            try run_as_user_cmd "Pulling Ollama model (${PICK_LLM_MODEL})" ollama pull "$PICK_LLM_MODEL"
        fi
        run_as_user bash -c "mkdir -p '$TARGET_RICE' && echo 'MODEL=\"$PICK_LLM_MODEL\"' > '$TARGET_RICE/ai-advisor.conf'" || true
    fi
    # ---- Notes: the picture-describing vision model, only because you said yes above. The model is downloaded here; Settings >
    # Notes > "Describe pictures" is switched on in step 12 (once the Halcyon files are in place), and only when the download worked.
    VLM_PULLED=false
    if [[ "$INSTALL_VLM" == "true" && -n "$PICK_VLM_MODEL" ]]; then
        log_info "Notes: setting up Ollama + the picture model ${PICK_VLM_MODEL}"
        setup_ollama
        if [[ "$DRY_RUN" == "true" ]]; then
            log_task "[DRY-RUN] ollama pull ${PICK_VLM_MODEL}, then notes set NOTES_VLM 1"
        else
            # the service needs a moment before it answers: wait up to 20 s
            for _i in $(seq 1 20); do
                curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:11434/api/tags 2>/dev/null && break
                sleep 1
            done
            if run_as_user_cmd "Pulling the picture model (${PICK_VLM_MODEL}, about 3 GB)" ollama pull "$PICK_VLM_MODEL"; then
                VLM_PULLED=true
                log_success "Picture model installed: ${PICK_VLM_MODEL}"
            else
                warn_later "The picture model ${PICK_VLM_MODEL} was not downloaded (is Ollama running?). Retry: ./install.sh --vlm   or:  ollama pull ${PICK_VLM_MODEL}"
            fi
        fi
    fi
    # ---- Speech-to-text for voice notes (Whisper): the engine, then ONE model, only because you said yes above
    if [[ "$INSTALL_WHISPER" == "true" ]]; then
        log_info "Voice notes: setting up whisper.cpp + the '${PICK_WHISPER_MODEL}' model"
        if ! have_any whisper-cli whisper-cpp whisper.cpp; then
            if [[ "$PKG_MGR" == "pacman" ]]; then
                install_pkgs whisper-cpp            # Arch's own package (extra repo, provides whisper-cli)
                have_any whisper-cli whisper-cpp whisper.cpp || install_pkgs whisper.cpp    # older name, AUR
            elif [[ "$PKG_MGR" == "dnf" ]]; then
                install_pkgs whisper-cpp            # Fedora's package
            else
                warn_later "whisper.cpp has no apt package: build it from https://github.com/ggml-org/whisper.cpp (cmake) so that 'whisper-cli' is on your PATH, or pip install faster-whisper. The model below is downloaded anyway."
            fi
        fi
        have_any whisper-cli whisper-cpp whisper.cpp || [[ "$DRY_RUN" == "true" ]] \
            || warn_later "whisper.cpp is not installed (the AUR build may have failed): voice notes will not be transcribed until 'whisper-cli' is on your PATH."
        WH_DIR="$TARGET_HOME/.local/share/whisper.cpp/models"
        WH_FILE="$WH_DIR/ggml-${PICK_WHISPER_MODEL}.bin"
        case "$PICK_WHISPER_MODEL" in tiny) WH_MIN=70000000 ;; small) WH_MIN=450000000 ;; *) WH_MIN=140000000 ;; esac   # a model is never smaller than this: a cut-off download is not kept
        if [[ "$DRY_RUN" != "true" ]] && [[ -f "$WH_FILE" && "$(stat -c %s "$WH_FILE" 2>/dev/null || echo 0)" -ge "$WH_MIN" ]]; then
            log_success "Whisper model already there: $WH_FILE"
        elif command -v curl >/dev/null 2>&1 || [[ "$DRY_RUN" == "true" ]]; then
            # downloaded next to its final name and renamed only when complete, so an interrupted download never leaves a half model behind
            try run_as_user_cmd "Downloading the Whisper '${PICK_WHISPER_MODEL}' model (ggml-${PICK_WHISPER_MODEL}.bin)" bash -c '
                set -e
                mkdir -p "$1"
                curl -fL --proto "=https" --tlsv1.2 --retry 3 --connect-timeout 20 -o "$2.part" \
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$3.bin"
                [ "$(stat -c %s "$2.part")" -ge "$4" ] || { echo "the download is too small, not keeping it"; rm -f "$2.part"; exit 1; }
                mv -f "$2.part" "$2"' _ "$WH_DIR" "$WH_FILE" "$PICK_WHISPER_MODEL" "$WH_MIN"
            [[ "$DRY_RUN" == "true" || -f "$WH_FILE" ]] && log_success "Whisper model installed: $WH_FILE" \
                || warn_later "The Whisper model was not downloaded. Retry: ./install.sh --whisper=${PICK_WHISPER_MODEL}"
        else
            warn_later "curl is missing: the Whisper model was not downloaded."
        fi
    fi
    try run_as_user_cmd "Creating the standard user folders" xdg-user-dirs-update
else
    log_info "Skipped (--no-packages)."
fi

if command -v Hyprland >/dev/null 2>&1; then
    HL_VER="$(Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    log_info "Hyprland ${HL_VER:-installed}"
    if [[ -n "$HL_VER" && "$(printf '%s\n0.55\n' "$HL_VER" | sort -V | head -n1)" != "0.55" ]]; then
        warn_later "Hyprland ${HL_VER} is older than 0.55: Halcyon's config is written in Lua, which needs 0.55 or newer ($(upgrade_hint), then $(pkg_hint hyprland); on Debian or Ubuntu see docs/install-debian.md)."
    fi
else warn_later "Hyprland is not installed."; fi

# ---------------------------------------------------------------------------------------------- step 6
log_step "Step 6: Rust toolchain"

[[ -d "$TARGET_HOME/.cargo/bin" ]] && export PATH="$TARGET_HOME/.cargo/bin:$PATH"
rust_ok() { run_as_user cargo --version >/dev/null 2>&1 && run_as_user rustc --version >/dev/null 2>&1; }

# Prebuilt helpers: possible when this checkout is exactly a release tag (so the binaries match the source), on x86_64, with curl and
# sha256sum, and the user did not ask to compile. Then no Rust toolchain is needed unless a download fails (step 8 installs one then).
prebuilt_possible() {
    [[ "$PREBUILT" == "true" && "${HALCYON_PREBUILT:-1}" != "0" ]] || return 1
    [[ "$(uname -m)" == "x86_64" ]] || return 1
    command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || return 1
    git -C "$RICE_SOURCE" describe --tags --exact-match >/dev/null 2>&1
}

ensure_rust() {
    if rust_ok; then log_success "Rust: $(run_as_user rustc --version)"; return 0; fi
    if command -v rustup >/dev/null 2>&1; then
        run_as_user_cmd "Setting up the stable Rust toolchain (rustup)" rustup default stable || warn_later "rustup could not set up a toolchain."
    elif [[ "$PACKAGES" == "true" ]]; then
        install_pkgs rust                           # the plain package: nothing is removed, nothing conflicts with rustup
    fi
    rust_ok && log_success "Rust: $(run_as_user rustc --version)" \
            || warn_later "No working Rust toolchain: the helpers (hx, hal, power-manager, touchpad-gestures, recon-deceiver, log-analyst, attacker-dossier, setStaticMac) cannot be built ($(pkg_hint rust))."
}

if [[ "$DRY_RUN" == "true" ]]; then
    log_task "[DRY-RUN] would check for cargo / rustc and install one if missing"
elif prebuilt_possible; then
    log_info "This is a release checkout: the helpers are downloaded prebuilt (checksum-verified), so no Rust toolchain is needed now."
else
    ensure_rust
fi

# ---------------------------------------------------------------------------------------------- step 7
log_step "Step 7: Copying Halcyon to ~/.config/Halcyon"

run_as_user_cmd "Creating the config, state and cache folders" mkdir -p \
    "$TARGET_HOME/.config" "$TARGET_HOME/.config/systemd/user" "$TARGET_HOME/.local/state/island" \
    "$TARGET_HOME/.cache/island" "$TARGET_HOME/Pictures/Wallpapers" "$TARGET_HOME/Pictures/Screenshots" \
    || die "Could not create folders in $TARGET_HOME"

KEEP_FILES=(hypr-user.lua scheme/current.lua gamemode.conf gpu.lua special.conf apps.custom gpu-mode autostart.conf greeting.conf greeting-custom.txt ai-advisor.conf focus.conf focus-apps.conf remind.conf notes.conf backup-exclude.conf birthdays.txt holidays.txt renderer)     # yours: never overwritten by the copy
if [[ "$(readlink -f "$TARGET_RICE" 2>/dev/null)" == "$(readlink -f "$RICE_SOURCE")" ]]; then
    log_success "Halcyon is already in ${TARGET_RICE}"
else
    if [[ "$DRY_RUN" != "true" ]] && ! run_as_user test -r "$RICE_SOURCE/hyprland.lua"; then
        die "'$TARGET_USER' cannot read ${RICE_SOURCE}. Put the Halcyon folder somewhere that user can read (not /root), then run again."
    fi
    # an older copy is saved first (without the big Rust build folders)
    if [[ -L "$TARGET_RICE" ]]; then
        run_as_user_cmd "Replacing the old symlink $TARGET_RICE" rm -f "$TARGET_RICE"
    elif [[ -d "$TARGET_RICE" && -n "$(ls -A "$TARGET_RICE" 2>/dev/null)" ]]; then
        BACKUP="$TARGET_HOME/.config/Halcyon-backups/Halcyon-$TIMESTAMP"
        run_as_user_cmd "Saving the old copy in ~/.config/Halcyon-backups/Halcyon-$TIMESTAMP" bash -c \
            'mkdir -p "$2" && tar -C "$1" --exclude="./src/*/target" -cf - . | tar -C "$2" -xf -' _ "$TARGET_RICE" "$BACKUP" \
            || die "Could not back up the old copy: nothing was changed."
    fi
    if [[ "$LINK_CONFIG" == "true" ]]; then
        # the old folder was saved above (the script stopped otherwise): it has to go, or `ln -s` would link INSIDE it
        [[ -d "$TARGET_RICE" && ! -L "$TARGET_RICE" ]] && { run_as_user_cmd "Removing the old folder (its backup is saved)" rm -rf "$TARGET_RICE" || die "Could not remove the old $TARGET_RICE"; }
        run_as_user_cmd "Linking $TARGET_RICE -> $RICE_SOURCE" ln -s "$RICE_SOURCE" "$TARGET_RICE" || die "Could not create the symlink."
    else
        EXCL=()
        for f in "${KEEP_FILES[@]}"; do [[ -e "$TARGET_RICE/$f" ]] && EXCL+=("--exclude=./$f"); done
        run_as_user_cmd "Copying Halcyon to $TARGET_RICE" bash -c \
            'mkdir -p "$2" && tar -C "$1" --exclude="./src/*/target" --exclude=./bin --exclude=./.git "${@:3}" -cf - . | tar -C "$2" -xf -' \
            _ "$RICE_SOURCE" "$TARGET_RICE" "${EXCL[@]}" || die "Could not copy Halcyon to $TARGET_RICE"
        [[ ${#EXCL[@]} -gt 0 ]] && log_info "Kept your own files: ${KEEP_FILES[*]}"
    fi
fi
[[ -n "$PICK_RENDERER" ]] && { run_as_user_cmd "Island renderer: $PICK_RENDERER" bash -c 'printf "%s\n" "$2" > "$1/renderer"' _ "$TARGET_RICE" "$PICK_RENDERER" || true; }
[[ -f "$TARGET_RICE/scripts/user-setup.sh" ]] && USER_SETUP="$TARGET_RICE/scripts/user-setup.sh"

try run_as_user_cmd "Making the scripts executable" bash -c '
    cd "$1" || exit 0
    for f in install.sh update.sh scripts/*.sh scripts/*.py scripts/halcyon-tune bin/* launch/*.sh quickshell/island/scripts/*.sh plymouth/*.py \
             sysmode/sysmode sysmode/*.py sysmode/*.py.bak; do
        [ -f "$f" ] && chmod +x "$f"
    done
    exit 0' _ "$TARGET_RICE"

# The login splash (Splash.qml, played by Lock.qml; SplashPreview.qml for `halcyon splash`) needs no package and no build step:
# it is plain QML in the island folder. Check that the copy really has all of it, so a half-copied update is told right away.
for _f in Splash.qml SplashPreview.qml Lock.qml WeeklySky.qml TimeOfDay.js; do
    [[ -f "$TARGET_RICE/quickshell/island/$_f" ]] || warn_later "quickshell/island/$_f is missing from the installed copy: the login splash will not work. Run ./install.sh again."
done
unset _f

# ---------------------------------------------------------------------------------------------- step 8
log_step "Step 8: Building the Rust helpers"

BIN_DIR="$TARGET_RICE/bin"
BUILD_ROOT="$TARGET_HOME/.cache/halcyon-build"           # outside the rice: the copy stays clean and rebuilds are quick; all crates share ONE target dir (build/shared), so regex / chrono / libc ... compile once
run_as_user_cmd "Creating $BIN_DIR" mkdir -p "$BIN_DIR" "$BUILD_ROOT" \
    || die "Cannot create $BIN_DIR$([[ "$LINK_CONFIG" == "true" ]] && echo " (with --link the Halcyon folder itself must be writable by $TARGET_USER)")"
BUILD_FAILED=()
CRATES=(hx hal hgl power-manager touchpad-gestures birthday-sync)    # hgl: game launcher core (library, Proton runtimes, doctor, scoped runs; no dependencies, installed to ~/.config/Halcyon/bin, no root). hal: Rust ports of input-conf / ws-nav / brightness / backlight (no dependencies, installed to ~/.config/Halcyon/bin). birthday-sync: Calendar > "Sync Google Birthdays" (installed to ~/.config/Halcyon/bin, no root)
SYSMODE_CRATES=(recon-deceiver log-analyst attacker-dossier setStaticMac)       # only sysmode uses these four: no sysmode, no build
[[ "$SYSMODE" == "true" ]] && CRATES+=("${SYSMODE_CRATES[@]}")
[[ "$SAFETY" == "true" ]] && CRATES+=(safety-check)


link_sysmode() {     # keep the sysmode symlinks in sync
    case "$1" in
        recon-deceiver|log-analyst|attacker-dossier|setStaticMac)
            [[ -d "$TARGET_RICE/sysmode" ]] && ln -sf "$BIN_DIR/$1" "$TARGET_RICE/sysmode/$1" 2>/dev/null || true
            ;;
    esac
}

# ---- prebuilt binaries from the GitHub release of this exact tag (see .github/workflows/release.yml) ----
# The release carries <crate>-x86_64-linux files and a SHA256SUMS list. Each download is checked against that list and with ldd
# (no missing libraries) before it replaces anything. The checksum list comes from the same release, so it guards against a broken or
# truncated download, not against a compromised release: if you want to trust only your own compiler, use --build-from-source.
PREBUILT_TAG=""; PREBUILT_URL=""; PREBUILT_DIR="$BUILD_ROOT/prebuilt"
prebuilt_setup() {
    prebuilt_possible || return 1
    local url
    PREBUILT_TAG="$(git -C "$RICE_SOURCE" describe --tags --exact-match 2>/dev/null)" || return 1
    [[ "$PREBUILT_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    url="$(git -C "$RICE_SOURCE" remote get-url origin 2>/dev/null)" || return 1
    url="${url%.git}"
    [[ "$url" =~ ^git@github\.com:(.+)$ ]] && url="https://github.com/${BASH_REMATCH[1]}"
    [[ "$url" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
    PREBUILT_URL="$url"
    run_as_user mkdir -p "$PREBUILT_DIR" || return 1
    run_as_user curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 \
        -o "$PREBUILT_DIR/SHA256SUMS" "$PREBUILT_URL/releases/download/$PREBUILT_TAG/SHA256SUMS" 2>>"$LOG_FILE" || {
        log_info "No prebuilt release for $PREBUILT_TAG: compiling the helpers instead."; PREBUILT_TAG=""; return 1; }
    return 0
}
fetch_prebuilt() {
    local crate="$1" file="$PREBUILT_DIR/$1" want got
    want="$(awk -v n="$crate-x86_64-linux" '$2==n {print $1}' "$PREBUILT_DIR/SHA256SUMS")"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || return 1
    run_as_user curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 \
        -o "$file" "$PREBUILT_URL/releases/download/$PREBUILT_TAG/$crate-x86_64-linux" 2>>"$LOG_FILE" || return 1
    got="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then log_warn "$crate: checksum does not match the release list; not using the download."; rm -f "$file"; return 1; fi
    if command -v ldd >/dev/null 2>&1 && ldd "$file" 2>&1 | grep -q 'not found'; then
        log_warn "$crate: the prebuilt binary needs a library this system lacks; compiling it instead."; rm -f "$file"; return 1
    fi
    run_as_user bash -c 'install -m755 "$1" "$2.new" && mv -f "$2.new" "$2"' _ "$file" "$BIN_DIR/$crate"
}

if [[ "$DRY_RUN" != "true" ]]; then
    user_bus_ready && user_systemctl stop power-manager.service touchpad-gestures.service >/dev/null 2>&1 || true
    pkill -u "$TARGET_UID" -x touchpad-gestures 2>/dev/null || true
fi

NEED_BUILD=("${CRATES[@]}")
if [[ "$DRY_RUN" != "true" ]] && prebuilt_setup; then
    NEED_BUILD=()
    for crate in "${CRATES[@]}"; do
        if fetch_prebuilt "$crate"; then
            log_success "Installed ${BIN_DIR}/${crate} (prebuilt $PREBUILT_TAG)"; link_sysmode "$crate"
        else
            NEED_BUILD+=("$crate")
        fi
    done
    [[ ${#NEED_BUILD[@]} -eq 0 ]] || log_info "Compiling what could not be downloaded: ${NEED_BUILD[*]}"
fi

if [[ ${#NEED_BUILD[@]} -gt 0 && "$DRY_RUN" != "true" ]] && ! rust_ok; then
    ensure_rust       # only reached when no prebuilt binaries were available (or a download failed)
fi
if [[ ${#NEED_BUILD[@]} -gt 0 && "$DRY_RUN" != "true" ]] && ! rust_ok; then
    warn_later "No Rust toolchain: skipped building the helpers. Install it ($(pkg_hint rust)), then run install.sh again."
    BUILD_FAILED=("${NEED_BUILD[@]}")
else
    for crate in "${NEED_BUILD[@]}"; do
        MANIFEST="$TARGET_RICE/src/$crate/Cargo.toml"; [[ -f "$MANIFEST" ]] || MANIFEST="$RICE_SOURCE/src/$crate/Cargo.toml"
        log_info "Building ${BOLD}${crate}${RESET} (the first time takes a few minutes)..."
        if run_as_user_cmd "cargo build --release: $crate" env "CARGO_TARGET_DIR=$BUILD_ROOT/shared" cargo build --release --manifest-path "$MANIFEST" \
           && { [[ "$DRY_RUN" == "true" ]] || [[ -f "$BUILD_ROOT/shared/release/$crate" ]]; } \
           && run_as_user_cmd "Installing $crate" bash -c 'install -m755 "$1" "$2.new" && mv -f "$2.new" "$2"' _ "$BUILD_ROOT/shared/release/$crate" "$BIN_DIR/$crate"; then
            [[ "$DRY_RUN" == "true" ]] || log_success "Installed ${BIN_DIR}/${crate}"
            link_sysmode "$crate"
        else
            BUILD_FAILED+=("$crate")
            warn_later "$crate did not build. Retry: cargo build --release --manifest-path $TARGET_RICE/src/$crate/Cargo.toml"
        fi
    done
fi

# ---------------------------------------------------------------------------------------------- step 9
log_step "Step 9: Hyprland entry and login"

user_setup hypr-entry || warn_later "Could not set up ~/.config/hypr/hyprland.lua"

# Ask Hyprland itself whether it accepts the config (`Hyprland --verify-config` loads it without starting a session).
# Result: yes / no / unknown. A config Hyprland rejects never gets an automatic login (see below).
HYPR_CONFIG_OK=unknown
verify_hypr_config() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    command -v Hyprland >/dev/null 2>&1 || { log_warn "Hyprland is not installed: the config could not be checked."; return 0; }
    log_task "Checking the config with Hyprland (--verify-config)"
    local out
    out="$(run_as_user timeout 40 env HYPRLAND_CONFIG="$TARGET_RICE/hyprland.lua" Hyprland --verify-config -c "$TARGET_RICE/hyprland.lua" 2>&1)" || true
    printf '%s\n' "$out" >> "$LOG_FILE"
    if grep -q 'config ok' <<<"$out"; then
        HYPR_CONFIG_OK=yes; log_success "Hyprland accepts the Halcyon config"
    elif grep -q 'Config parsing result' <<<"$out"; then
        HYPR_CONFIG_OK=no
        warn_later "Hyprland reports errors in the Halcyon config (see below). Halcyon will start with a red error bar and missing parts."
        sed -n '/Config parsing result/,$p' <<<"$out" | sed '1,2d' | head -n 20 | sed 's/^/      | /'
    else
        log_warn "Hyprland could not check the config here (it printed no result): this is not an error by itself."
        printf '%s\n' "$out" | tail -n 5 | sed 's/^/      | /'
    fi
}
verify_hypr_config

# `start-halcyon`: one command that works for every user (also what the login-screen session runs)
write_root_file /usr/local/bin/start-halcyon 755 <<'EOF' || warn_later "Could not write /usr/local/bin/start-halcyon"
#!/usr/bin/env bash
# Starts Halcyon (Hyprland with the Halcyon config) for the user who runs it. Written by install.sh.
exec "$HOME/.config/Halcyon/launch/halcyon.sh" "$@"
EOF
write_root_file /usr/share/wayland-sessions/halcyon.desktop 644 <<'EOF' || warn_later "Could not add the Halcyon login-screen session"
[Desktop Entry]
Name=Halcyon
Comment=Hyprland with the Halcyon island
Exec=/usr/local/bin/start-halcyon
Type=Application
DesktopNames=Hyprland
EOF

[[ "$TTY_AUTOSTART" == "true" ]] && { user_setup tty-autostart || true; }

# ---- the lock screen as the login screen, when nothing else is the login screen
have_dm() {
    local s
    unit_enabled display-manager.service && return 0
    for s in sddm gdm gdm3 lightdm greetd ly lxdm slim xdm emptty cosmic-greeter plasmalogin; do unit_enabled "$s.service" && return 0; done
    return 1
}
dm_name() { basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null; }

# ---- the two login questions: how do you log in at BOOT, and what do you see after SLEEP / when you lock
#   boot:   Halcyon login manager (greetd + greeter/shell.qml, no widgets)   |  auto-login + the lock screen (widgets allowed)
#   sleep:  the login-screen look (no widgets)                               |  the lock screen (widgets allowed)
# Asked once (answers are remembered); ./install.sh --choose asks again. A flag skips the question.
SAVED_LM="$(saved_choice LOGIN_MODE)"; SAVED_SM="$(saved_choice LOCK_MODE)"
if [[ -z "$LOGIN_MODE" ]]; then
    if [[ "$GREETER" == "true" ]]; then LOGIN_MODE=greeter
    elif [[ "$LOCK_LOGIN" == "1" ]]; then LOGIN_MODE=lock
    elif [[ "$AUTO_CONFIRM" != "true" && -t 0 && ( "$CHOOSE" == "true" || -z "$SAVED_LM" ) ]]; then
        menu_pick LOGIN_MODE "At boot: how do you log in?" "${SAVED_LM:-keep}" 0 \
            "greeter|Halcyon login manager|greetd + Halcyon's own login screen, pretty and locked down (no widgets)" \
            "lock|Auto-login + lock screen|tty1 logs you in, Halcyon starts locked; the lock screen can show widgets" \
            "keep|Leave it as it is|nothing changes"
        LOGIN_MODE="${LOGIN_MODE%% *}"
    fi
fi
[[ "$LOGIN_MODE" == "greeter" ]] && GREETER=true
[[ "$LOGIN_MODE" == "lock" && "$LOCK_LOGIN" == "auto" ]] && LOCK_LOGIN=1
if [[ -z "$LOCK_MODE" ]]; then
    if [[ "$AUTO_CONFIRM" != "true" && -t 0 && ( "$CHOOSE" == "true" || -z "$SAVED_SM" ) ]]; then
        menu_pick LOCK_MODE "After sleep / when you lock: what do you see?" "${SAVED_SM:-keep}" 0 \
            "login|Login-screen look|the same screen as the login manager, no widgets" \
            "lock|Lock screen|the full lock screen: your own widgets, media card, Wi-Fi and battery" \
            "keep|Leave it as it is|nothing changes"
        LOCK_MODE="${LOCK_MODE%% *}"
    fi
fi
SAVE_MODES=()
[[ -n "$LOGIN_MODE" && "$LOGIN_MODE" != "keep" ]] && SAVE_MODES+=("LOGIN_MODE=$LOGIN_MODE")
[[ -n "$LOCK_MODE" && "$LOCK_MODE" != "keep" ]] && SAVE_MODES+=("LOCK_MODE=$LOCK_MODE")
if [[ ${#SAVE_MODES[@]} -gt 0 && "$DRY_RUN" != "true" ]]; then user_setup save-choices "${SAVE_MODES[@]}" || true; fi
if [[ -n "$LOCK_MODE" && "$LOCK_MODE" != "keep" ]]; then
    try run_as_user_cmd "Lock screen after sleep: $LOCK_MODE" bash "$TARGET_RICE/scripts/halcyon-greeter.sh" lockmode "$LOCK_MODE"
fi
[[ "$GREETER" == "true" ]] && LOCK_LOGIN=0      # greetd is the login screen: no tty1 auto-login next to it
WANT_LOCK_LOGIN=false
LOCK_LOGIN_SAVE=""      # yes | no: your answer, remembered in install-choices.env (LOCK_LOGIN) so it is asked once
if have_dm; then
    log_success "Login manager found ($(dm_name)): pick the \"Halcyon\" session on its login screen. Halcyon's own lock screen is used when you lock."
    [[ "$LOCK_LOGIN" == "1" ]] && WANT_LOCK_LOGIN=true
else
    log_info "No login manager (sddm, gdm, ...): at boot you get a text console; start Halcyon with: start-halcyon"
    if [[ "$LOCK_LOGIN" == "0" ]]; then log_info "Lock-screen login skipped (--no-lock-login)."
    elif [[ "$LOCK_LOGIN" == "1" ]]; then WANT_LOCK_LOGIN=true; LOCK_LOGIN_SAVE=yes
    elif [[ -f "$GETTY_DROPIN" ]]; then
        # already the login screen: keep it, do not ask again (an outdated drop-in is refreshed just below)
        log_info "Lock-screen login: on (undo with ./install.sh --remove-lock-login)."; LOCK_LOGIN_SAVE=yes
    elif [[ "$CHOOSE" != "true" && "$(saved_choice LOCK_LOGIN)" == "no" ]]; then
        log_info "Lock-screen login: not set up (your earlier answer; ./install.sh --choose or --lock-login asks again)."; LOCK_LOGIN_SAVE=no
    else
        # Opt-in only. It used to be "yes" by default (and --yes always said yes), so a machine whose Halcyon did not start
        # right booted straight into a broken desktop with no text console in sight. Now it is only set up when you ask for it.
        echo "   Optional: Halcyon can use its own lock screen as the login screen: tty1 logs you in by itself, Halcyon starts ALREADY"
        echo "   LOCKED (with a short splash of moving stars and the Halcyon sparkle first; Settings > Lock screen > Splash turns it off),"
        echo "   and you type your password on the lock screen. Other consoles (Ctrl+Alt+F2) stay normal text logins."
        echo "   Undo any time: ./install.sh --remove-lock-login"
        if [[ "$AUTO_CONFIRM" != "true" && -t 0 ]]; then
            if confirm_no "   Set that up? (Enter = no; start-halcyon works from any text console)"; then WANT_LOCK_LOGIN=true; LOCK_LOGIN_SAVE=yes
            else LOCK_LOGIN_SAVE=no; log_info "Not set up (remembered). ./install.sh --choose or --lock-login asks again."; fi
        else log_info "Not set up. Add --lock-login to enable it later."; fi
    fi
fi
if [[ "$WANT_LOCK_LOGIN" == "true" && "$HYPR_CONFIG_OK" == "no" ]]; then
    warn_later "The lock-screen login was NOT set up: Hyprland reports errors in the config, and an automatic login would put you in a broken desktop at every boot. Fix the errors, then run ./install.sh --lock-login."
    WANT_LOCK_LOGIN=false
fi
getty_dropin() {   # the tty1 auto-login drop-in for $TARGET_USER (\\u in the file reaches agetty as \u, which it expands to the name)
    sed "s|@USER@|$TARGET_USER|g" <<'GETTY'
# Written by Halcyon's install.sh: tty1 logs @USER@ in by itself; the profile then starts Halcyon with the lock screen on.
# The auto-login only reaches a shell that immediately starts the locked desktop (launch/halcyon-login.sh).
# Quiet on purpose, so the boot splash stays on screen until Hyprland draws: no /etc/issue, no login line, and the console is
# neither reset to text mode nor cleared (TTYReset / TTYVTDisallocate), which is what showed the bare tty for a moment.
# Remove with ./install.sh --remove-lock-login
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --noissue --nohints --skip-login --nonewline --autologin @USER@ - $TERM
TTYReset=no
TTYVTDisallocate=no
GETTY
}
# Already set up: bring an older drop-in (it printed the tty1 banner over the boot splash) up to date
if [[ "$WANT_LOCK_LOGIN" != "true" && -f "$GETTY_DROPIN" ]] && ! getty_dropin | cmp -s - "$GETTY_DROPIN"; then
    if getty_dropin | write_root_file "$GETTY_DROPIN" 644; then
        have_systemd && try run_cmd "Reloading systemd" as_root systemctl daemon-reload
        user_setup hushlogin || true
        log_success "Lock-screen login updated: tty1 no longer shows text between the boot splash and the lock screen."
    fi
fi
if [[ "$WANT_LOCK_LOGIN" == "true" ]]; then
    if user_setup login-add; then
        if getty_dropin | write_root_file "$GETTY_DROPIN" 644; then
            have_systemd && try run_cmd "Reloading systemd" as_root systemctl daemon-reload
            log_success "Lock screen is now the login screen: from the next boot tty1 logs in $TARGET_USER and Halcyon starts locked."
            log_success "Other consoles (Ctrl+Alt+F2) stay normal text logins: your way back in if something goes wrong."
        else
            warn_later "Could not write $GETTY_DROPIN: the lock-screen login is NOT active (nothing was changed on tty1)."
        fi
    else
        warn_later "Your login shell is not bash, zsh or fish, so the lock-screen login was NOT set up (auto-login without it would leave an open shell). Start Halcyon with: start-halcyon"
    fi
fi

# ---- --greeter: greetd + Halcyon's own login screen
# What it needs: greetd (the login service), cage (a one-window compositor the login screen runs in) and seatd (a fallback seat
# service: without logind or seatd the session dies with "[libseat] could not connect to socket /run/seatd.sock").
# halcyon-greeter.sh install then writes /etc/greetd/config.toml, adds pam_systemd to greetd's PAM file when it is missing,
# starts seatd, puts you and the greeter in the 'seat' group, and enables greetd for the next boot.
if [[ "$GREETER" == "true" ]]; then
    if [[ "$HYPR_CONFIG_OK" == "no" ]]; then
        warn_later "The Halcyon login screen was NOT set up: Hyprland reports errors in the config, and logging in would put you in a broken desktop. Fix them, then run ./install.sh --greeter."
    else
        [[ "$PACKAGES" == "true" ]] && install_pkgs greetd cage seatd
        if [[ $EUID -eq 0 ]]; then
            try run_cmd "Setting up the Halcyon login screen (greetd, cage, seatd)" env HALCYON_GREETER_OWNER="$TARGET_USER" HALCYON_DIR="$TARGET_RICE" \
                bash "$TARGET_RICE/scripts/halcyon-greeter.sh" install
        else
            try run_as_user_cmd "Setting up the Halcyon login screen (greetd, cage, seatd)" bash "$TARGET_RICE/scripts/halcyon-greeter.sh" install
        fi
        if [[ "$DRY_RUN" != "true" ]]; then
            unit_enabled greetd.service && log_success "Login manager: greetd is enabled for the next boot." \
                || warn_later "greetd is not enabled: run  $TARGET_RICE/scripts/halcyon-greeter.sh install  as $TARGET_USER and read what it says."
            [[ -S /run/seatd.sock ]] || systemctl is-active --quiet systemd-logind.service \
                || warn_later "Neither seatd nor systemd-logind is running: the session may not start. Run  $TARGET_RICE/scripts/halcyon-greeter.sh doctor"
        fi
    fi
fi
# the login screen already installed earlier (greetd with Halcyon's config): it runs the root-owned copy in /usr/local/share/halcyon-greeter,
# so every update has to copy the new files there, or the boot login screen keeps running the old ones
if [[ "$GREETER" != "true" && "$DRY_RUN" != "true" && -f /usr/local/share/halcyon-greeter/shell.qml ]] && grep -q "# halcyon-greeter" /etc/greetd/config.toml 2>/dev/null; then
    if [[ $EUID -eq 0 ]]; then
        try run_cmd "Updating the Halcyon login screen files" env HALCYON_DIR="$TARGET_RICE" bash "$TARGET_RICE/scripts/halcyon-greeter.sh" refresh
    else
        try run_as_user_cmd "Updating the Halcyon login screen files" bash "$TARGET_RICE/scripts/halcyon-greeter.sh" refresh
    fi
fi

# ---------------------------------------------------------------------------------------------- step 10
log_step "Step 10: Services"

UNITS="$TARGET_HOME/.config/systemd/user"
try run_as_user_cmd "Installing the user services (gestures start with the desktop, Auto power from the island)" \
    install -m644 "$TARGET_RICE/systemd/power-manager.service" "$TARGET_RICE/systemd/touchpad-gestures.service" \
        "$TARGET_RICE/systemd/halcyon-remind.service" "$TARGET_RICE/systemd/halcyon-remind.timer" \
        "$TARGET_RICE/systemd/halcyon-notes-due.service" "$TARGET_RICE/systemd/halcyon-notes-due.timer" \
        "$TARGET_RICE/systemd/halcyon-updates.service" "$TARGET_RICE/systemd/halcyon-updates.timer" \
        "$TARGET_RICE/systemd/halcyon-explain@.service" "$UNITS/"
if [[ "$DRY_RUN" != "true" ]] && have_systemd && user_bus_ready; then
    try run_cmd "Reloading the user systemd" user_systemctl daemon-reload
    # only inside a running desktop (the gestures need it); otherwise they start with the next login via execs.lua
    if [[ -x "$BIN_DIR/touchpad-gestures" && -n "${WAYLAND_DISPLAY:-}" ]]; then
        try run_cmd "Starting touchpad gestures" user_systemctl start touchpad-gestures.service
    fi
    [[ "$PACKAGES" == "true" ]] && try run_cmd "Enabling PipeWire for the user" user_systemctl enable --now pipewire pipewire-pulse wireplumber
else
    log_info "No user session running here: the user services start at the next login."
fi

# RAM type / speed for the performance page: dmidecode needs root, so a boot service saves it
if command -v dmidecode >/dev/null 2>&1; then
    if run_cmd "Installing the RAM details service" as_root install -Dm644 "$TARGET_RICE/systemd/halcyon-ram.service" /etc/systemd/system/halcyon-ram.service; then
        have_systemd && try run_cmd "Reloading systemd" as_root systemctl daemon-reload
        enable_service halcyon-ram.service --now
        [[ "$DRY_RUN" == "true" || -s /var/lib/halcyon/dmi-memory.txt ]] || warn_later "dmidecode returned no memory details (virtual machine?): the RAM card shows the size only."
    fi
else warn_later "dmidecode is missing: the RAM card shows the size only ($(pkg_hint dmidecode), then run this again)."; fi

# ---------------------------------------------------------------------------------------------- step 11
log_step "Step 11: Root helpers (halcyon-tune, sysmode, safety check, backlight)"

# ---- halcyon-tune: the ONE thing allowed to run as root without a password
# /usr/local/bin/halcyon-tune is a root-owned copy (you cannot edit what runs as root) and takes no free-form arguments
# (read scripts/halcyon-tune: it is short). The rule below names exactly that file, nothing else.
if [[ "$SKIP_TUNE" == "true" ]]; then
    log_info "Skipped (--no-tune): Gaming mode only changes the visuals, and the power manager / Wi-Fi switches need a password prompt you cannot answer."
elif ! command -v sudo >/dev/null 2>&1 && [[ "$DRY_RUN" != "true" ]]; then
    warn_later "sudo is not installed, so halcyon-tune cannot be used: Gaming mode only changes the visuals."
elif ! command -v visudo >/dev/null 2>&1 && [[ "$DRY_RUN" != "true" ]]; then
    warn_later "visudo not found: the sudo rule for halcyon-tune was NOT installed (it is never installed without being checked first)."
else
    TUNE_SRC="$RICE_SOURCE/scripts/halcyon-tune"; [[ -f "$TUNE_SRC" ]] || TUNE_SRC="$TARGET_RICE/scripts/halcyon-tune"
    if run_cmd "Installing /usr/local/bin/halcyon-tune (root-owned)" as_root install -Dm755 -o root -g root "$TUNE_SRC" /usr/local/bin/halcyon-tune \
       && printf '# Written by Halcyon install.sh: lets %s run the Halcyon tuning helper (and only that) without a password\n%s ALL=(root) NOPASSWD: /usr/local/bin/halcyon-tune\n' "$TARGET_USER" "$TARGET_USER" \
          | write_root_file /etc/sudoers.d/halcyon-tune 440 visudo -cf; then
        if [[ "$DRY_RUN" != "true" ]] && ! as_root grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
            warn_later "/etc/sudoers does not include /etc/sudoers.d: add the line '@includedir /etc/sudoers.d' (with visudo) or the halcyon-tune rule is ignored."
        fi
    else
        warn_later "Could not install halcyon-tune: Gaming mode will only change visuals; the power manager and Wi-Fi switches will not work."
    fi
fi

# ---- gaming mode: the tools it works with
# Gaming mode (halcyon-tune above + scripts/gamemode.sh) sets CPU / GPU speed and starts GameMode. GameMode only renices a game
# for members of the 'gamemode' group; gamescope and MangoHud are the usual companions (a frame limiter / overlay in Steam:
# `gamemoderun mangohud %command%`). The GPU side (NVIDIA / Intel / AMD drivers) was handled in Step 3.
if [[ "$PACKAGES" == "true" && "$SKIP_DRIVERS" != "true" ]]; then
    log_info "Gaming mode tools: GameMode, gamescope, MangoHud$([[ "$MULTILIB_ENABLED" == "true" ]] && echo " (+ their 32-bit libraries)")"
    GAME_PKGS=(gamemode gamescope mangohud)
    [[ "$MULTILIB_ENABLED" == "true" ]] && GAME_PKGS+=(lib32-gamemode lib32-mangohud)
    install_pkgs --repo-only "${GAME_PKGS[@]}"
fi
if getent group gamemode >/dev/null 2>&1 && ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx gamemode; then
    try run_cmd "Adding $TARGET_USER to the gamemode group (GameMode can then renice games)" as_root usermod -aG gamemode "$TARGET_USER"
    NEED_RELOGIN=true
fi

# ---- sysmode (hardening CLI, honeypot / IDS at boot) and every tool it uses
if [[ "$SYSMODE" == "true" ]]; then
    if [[ "$PACKAGES" == "true" ]]; then
        # exactly what `sysmode doctor` checks: honeypot runtime (docker), counter-recon (nmap), packet capture (tcpdump), firewall (ufw),
        # kernel audit (audit), encrypted DNS (dnscrypt-proxy), process accounting (acct), security audit (lynis), desktop
        # notifications (libnotify), Bluetooth alias (bluez-utils), the honeypot script's runtime (python)
        log_info "sysmode needs: python nmap tcpdump ufw audit docker dnscrypt-proxy lynis acct libnotify bluez-utils"
        install_pkgs python nmap tcpdump ufw audit docker dnscrypt-proxy lynis acct libnotify bluez-utils
    fi
    # the root-run scripts live in a root-owned folder: sysmode runs them as root, so they must not be files your own user
    # (or any program running as you) can change
    {
        echo "# Written by Halcyon install.sh"
        printf 'SYS_USER=%q\n' "$TARGET_USER"
        printf 'SYS_HOME=%q\n' "$TARGET_HOME"
        echo "SCRIPTS_DIR=/usr/local/lib/halcyon/sysmode"
    } | write_root_file /etc/sysmode.conf 644 || warn_later "Could not write /etc/sysmode.conf"
    for f in "$TARGET_RICE"/sysmode/*.py "$TARGET_RICE"/sysmode/*.py.bak; do
        [[ -f "$f" ]] || continue
        try run_cmd "Installing $(basename "$f") (root-owned)" as_root install -Dm755 -o root -g root "$f" "/usr/local/lib/halcyon/sysmode/$(basename "$f")"
    done
    for bin_helper in recon-deceiver log-analyst attacker-dossier setStaticMac; do
        if [[ -x "$BIN_DIR/$bin_helper" || "$DRY_RUN" == "true" ]]; then
            try run_cmd "Installing $bin_helper to /usr/local/bin" as_root install -Dm755 "$BIN_DIR/$bin_helper" "/usr/local/bin/$bin_helper"
            try run_cmd "Installing $bin_helper (root-owned) to /usr/local/lib/halcyon/sysmode" as_root install -Dm755 -o root -g root "$BIN_DIR/$bin_helper" "/usr/local/lib/halcyon/sysmode/$bin_helper"
        fi
    done
    run_cmd "Installing the sysmode command" as_root install -Dm755 "$TARGET_RICE/sysmode/sysmode" /usr/local/bin/sysmode || die "Could not install /usr/local/bin/sysmode"
    if [[ -x "$BIN_DIR/hx" || "$DRY_RUN" == "true" ]]; then try run_cmd "Installing hx to /usr/local/bin" as_root install -Dm755 "$BIN_DIR/hx" /usr/local/bin/hx
    else warn_later "hx was not built: sysmode falls back to its standalone helper tools."; fi
    try run_cmd "Installing the sysmode manual" as_root install -Dm644 "$TARGET_RICE/sysmode/sysmode.8" /usr/local/share/man/man8/sysmode.8
    try run_cmd "Installing the sysmode bash completion" as_root install -Dm644 "$TARGET_RICE/sysmode/sysmode.bash-completion" /usr/share/bash-completion/completions/sysmode
    if have_systemd || [[ "$DRY_RUN" == "true" ]]; then
        try run_cmd "Installing the sysmode boot service" as_root install -Dm644 "$TARGET_RICE/sysmode/sysmode-daemons.service" /etc/systemd/system/sysmode-daemons.service
        try run_cmd "Reloading systemd" as_root systemctl daemon-reload
        try run_cmd "Enabling sysmode-daemons.service (the honeypot and IDS come back at boot when the mode is stealth)" as_root systemctl enable sysmode-daemons.service
        # the Cowrie honeypot runs in Docker. docker.socket starts the daemon the moment `sysmode stealth` asks for it, so it does not
        # sit in memory (~150 MB with containerd) all day for a mode that is mostly off
        if command -v docker >/dev/null 2>&1 && ! unit_enabled docker.service && ! unit_enabled docker.socket; then try run_cmd "Enabling docker on demand (docker.socket, for the Cowrie honeypot)" as_root systemctl enable docker.socket; fi
    else warn_later "No systemd: sysmode-daemons.service was not enabled."; fi
    # no mode is switched here on purpose: `secure` makes gcc / clang / rustc root-only, `lockdown` disables SSH. You choose.
    if [[ "$DRY_RUN" != "true" ]] && command -v sysmode >/dev/null 2>&1; then
        log_info "sysmode doctor:"
        as_root /usr/local/bin/sysmode doctor 2>&1 | sed 's/^/   /' | tee -a "$LOG_FILE" || true
    fi
    log_info "Switch modes (as you need them):  sudo sysmode secure | relaxed | stealth | lockdown    status:  sysmode status"
else
    log_info "sysmode skipped (--no-sysmode)."
fi

# ---- screen + keyboard backlight
# Keyboard light: the DEVICE (/sys/class/leds/*kbd_backlight) is created by a kernel driver that depends on the laptop's maker
# (asus-wmi, thinkpad_acpi, dell-laptop, hp-wmi, ideapad-laptop, applesmc, msi-ec, tuxedo-drivers, system76 ...). Look at what
# the machine says it is, load / install the driver that makes the light show up, and keep it loaded at every boot.
is_laptop() {
    case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" in 8|9|10|11|14|30|31|32) return 0 ;; esac
    compgen -G "/sys/class/power_supply/BAT*" >/dev/null
}
kbd_led_present() { compgen -G "/sys/class/leds/*kbd?backlight*" >/dev/null || compgen -G "/sys/class/leds/*keyboard*backlight*" >/dev/null; }
setup_kbd_backlight() {
    if [[ "$DRY_RUN" == "true" ]]; then log_task "[DRY-RUN] keyboard backlight: detect the laptop and load / install its driver"; return 0; fi
    if kbd_led_present; then log_success "Keyboard backlight driver found: $(basename "$(ls -d /sys/class/leds/*kbd?backlight* /sys/class/leds/*keyboard*backlight* 2>/dev/null | head -n1)")"; return 0; fi
    if ! is_laptop; then log_info "Keyboard light: this is not a laptop, so there is no keyboard-light driver to load (an RGB keyboard: $(pkg_hint openrgb))."; return 0; fi
    local vendor prod ver id mods=() pkgs=() note="" m loaded=()
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"; prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"; ver="$(cat /sys/class/dmi/id/product_version 2>/dev/null)"
    id="$(tr 'A-Z' 'a-z' <<<"$vendor $prod $ver")"
    log_info "Keyboard light: no device yet. Laptop: ${vendor:-?} ${prod:-?}"
    case "$id" in
        *thinkpad*)                    mods=(thinkpad_acpi) ;;
        *legion*|*loq*)                mods=(ideapad_laptop legion_laptop); note="Legion RGB keyboards: the 4-zone light needs the lenovo-legion driver from the AUR (lenovo-legion-dkms)" ;;
        *lenovo*|*ideapad*|*yoga*)     mods=(ideapad_laptop thinkpad_acpi) ;;
        *alienware*)                   mods=(alienware_wmi dell_laptop); note="Alienware per-zone lighting: AUR package alienfx / OpenRGB" ;;
        *dell*)                        mods=(dell_laptop dell_wmi dell_smm_hwmon) ;;
        *tuxedo*|*clevo*|*schenker*|*xmg*|*eluktronics*|*nexoc*|*"system76"*|*pangolin*|*lemur*|*oryx*|*gazelle*|*darter*|*galago*|*kudu*|*serval*)
            if [[ "$id" == *system76* || "$id" == *pangolin* || "$id" == *lemur* || "$id" == *oryx* || "$id" == *gazelle* || "$id" == *darter* || "$id" == *galago* || "$id" == *kudu* || "$id" == *serval* ]]; then
                mods=(system76_acpi system76); pkgs=(system76-acpi-dkms)
            else mods=(tuxedo_keyboard clevo_wmi); pkgs=(tuxedo-drivers-dkms); fi ;;
        *asus*|*"rog "*|*tuf*|*zenbook*|*vivobook*|*zephyrus*)
            mods=(asus_nb_wmi asus_wmi)
            [[ "$id" == *rog* || "$id" == *tuf* || "$id" == *zephyrus* || "$id" == *strix* || "$id" == *scar* || "$id" == *flow* ]] && pkgs=(asusctl) ;;
        *hewlett*|*"hp "*|*omen*|*victus*|*pavilion*|*elitebook*|*probook*|*envy*|*spectre*) mods=(hp_wmi) ;;
        *msi*|*micro-star*)            mods=(msi_wmi_platform msi_ec); pkgs=(msi-ec-dkms) ;;
        *samsung*)                     mods=(samsung_laptop) ;;
        *apple*|*macbook*)             mods=(applesmc) ;;
        *framework*)                   mods=(cros_kbd_led_backlight framework_laptop) ;;
        *acer*)                        mods=(acer_wmi); note="Acer Predator / Nitro 4-zone RGB: AUR package linuwu-sense-dkms" ;;
        *huawei*|*honor*)              mods=(huawei_wmi) ;;
        *razer*)                       note="Razer keyboards are not a standard keyboard light: install openrazer (https://openrazer.github.io has the steps for each distribution) and polychromatic" ;;
        *)                             mods=(asus_nb_wmi thinkpad_acpi ideapad_laptop dell_laptop hp_wmi samsung_laptop) ;;
    esac
    for m in "${mods[@]}"; do
        modinfo "$m" >/dev/null 2>&1 || continue
        if as_root modprobe "$m" >>"$LOG_FILE" 2>&1; then loaded+=("$m"); fi
    done
    sleep 1
    if ! kbd_led_present && [[ ${#pkgs[@]} -gt 0 && "$PACKAGES" == "true" ]]; then
        log_info "The kernel's own driver does not create the light: installing ${pkgs[*]}"
        for q in "${pkgs[@]}"; do
            [[ "$q" == *-dkms ]] && { mapfile -t HDRS < <(kernel_headers); install_pkgs "${HDRS[@]}"; break; }
        done
        install_pkgs "${pkgs[@]}"
        if systemctl cat asusd.service >/dev/null 2>&1; then try run_cmd "Starting asusd" as_root systemctl start asusd.service; fi   # static unit: no "enable"
        for m in "${mods[@]}"; do modinfo "$m" >/dev/null 2>&1 && as_root modprobe "$m" >>"$LOG_FILE" 2>&1 && loaded+=("$m"); done
        sleep 1
    fi
    if kbd_led_present; then
        log_success "Keyboard light is working now ($(basename "$(ls -d /sys/class/leds/*kbd?backlight* /sys/class/leds/*keyboard*backlight* 2>/dev/null | head -n1)"))"
        if [[ ${#loaded[@]} -gt 0 ]]; then
            printf '# Written by Halcyon install.sh: drivers that make the keyboard light show up\n%s\n' "$(printf '%s\n' "${loaded[@]}" | sort -u)" \
                | write_root_file /etc/modules-load.d/halcyon-kbd.conf 644 || true
        fi
    else
        [[ " ${pkgs[*]} " == *-dkms* ]] && NEED_REBOOT=true
        log_info "No keyboard light yet. $([[ -n "$note" ]] && echo "$note. ")It may need a reboot (a driver was just installed), or this model has none / a hardware-only (Fn key) light."
        log_info "Check later:  ~/.config/Halcyon/scripts/kbd-backlight.sh doctor"
    fi
}
if [[ "$SKIP_DRIVERS" != "true" ]]; then setup_kbd_backlight; else log_info "Keyboard light driver check skipped (--no-drivers)."; fi

# ASUS laptops (Vivobook, Zenbook, TUF, ROG, ...): the kernel's asus-wmi driver already creates asus::kbd_backlight, but the Fn
# key for it is handled inside the kernel (no key event reaches Hyprland) and its own copy of the level can go stale, so the
# key may need two presses. asusd (asusctl) takes over those keys and keeps the level in sync. The extra SUPER+F3 / SUPER+F4
# keys (hyprland/keybinds.lua, only when asus::kbd_backlight exists) always work, with or without asusd.
setup_asus_extras() {
    local id
    # cat, not `tr < file`: a machine with no DMI table (Raspberry Pi, some VMs and containers) has no sys_vendor file, the failed
    # redirect printed an error and (set -e) ENDED THE WHOLE INSTALL here, in the middle of step 11
    id="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr 'A-Z' 'a-z' || true)"
    [[ "$id" == *asus* ]] || return 0
    is_laptop || return 0
    if [[ "$DRY_RUN" == "true" ]]; then log_task "[DRY-RUN] ASUS laptop: install asusctl and start asusd (Fn keyboard-light key)"; return 0; fi
    log_info "ASUS laptop: setting up asusd (keyboard light Fn keys)"
    if [[ "$PACKAGES" == "true" ]]; then install_pkgs asusctl; fi
    if systemctl cat asusd.service >/dev/null 2>&1; then
        # a static unit (udev / D-Bus start it at boot): "systemctl enable" would only complain
        systemctl is-active --quiet asusd.service || try run_cmd "Starting asusd" as_root systemctl start asusd.service
        log_success "asusd is running: Fn keyboard-light keys and 'asusctl leds next|prev' work. SUPER+F3 / SUPER+F4 also step the light."
        log_info "asusd also manages the ASUS power profile; if it fights Halcyon's power manager, stop it with: sudo systemctl mask asusd"
    else
        log_info "asusctl is not installed (AUR build failed or --no-packages). SUPER+F3 / SUPER+F4 still step the keyboard light."
    fi

    # Fix ASUS Vivobook/Zenbook keyboard backlight OOBE bug (unlocks asus::kbd_backlight)
    if [[ -f "$TARGET_RICE/scripts/asus-kbd-fix.sh" ]]; then
        try run_cmd "Installing ASUS keyboard backlight fix helper" \
            as_root install -Dm755 "$TARGET_RICE/scripts/asus-kbd-fix.sh" /usr/local/bin/halcyon-asus-kbd-fix
        if [[ -f "$TARGET_RICE/systemd/halcyon-asus-kbd.service" ]]; then
            try run_cmd "Installing ASUS keyboard backlight systemd service" \
                as_root install -Dm644 "$TARGET_RICE/systemd/halcyon-asus-kbd.service" /etc/systemd/system/halcyon-asus-kbd.service
            try run_cmd "Enabling and running ASUS keyboard backlight service" \
                as_root systemctl enable --now halcyon-asus-kbd.service
        fi
        try run_cmd "Clearing ASUS keyboard backlight OOBE flag" \
            as_root /usr/local/bin/halcyon-asus-kbd-fix || true
    fi
}
if [[ "$SKIP_DRIVERS" != "true" ]]; then setup_asus_extras; fi

# a udev rule so your user may write the screen backlight (group video) and the keyboard light (group input) without root
if [[ -f "$TARGET_RICE/udev/90-halcyon-backlight.rules" ]]; then
    if run_cmd "Installing the backlight udev rule (screen: group video, keyboard light: group input)" \
         as_root install -Dm644 "$TARGET_RICE/udev/90-halcyon-backlight.rules" /etc/udev/rules.d/90-halcyon-backlight.rules; then
        try run_cmd "Reloading udev" as_root udevadm control --reload
        try run_cmd "Applying the rule to the backlight devices" as_root udevadm trigger -s leds -s backlight
    fi
fi
# the same for the battery charge limit (the 80 % / full charge chip in the utilities box); only batteries that have a limit are touched
if [[ -f "$TARGET_RICE/udev/90-halcyon-battery.rules" ]]; then
    if run_cmd "Installing the battery charge-limit udev rule (group video)" \
         as_root install -Dm644 "$TARGET_RICE/udev/90-halcyon-battery.rules" /etc/udev/rules.d/90-halcyon-battery.rules; then
        try run_cmd "Reloading udev" as_root udevadm control --reload
        try run_cmd "Applying the rule to the battery" as_root udevadm trigger -s power_supply
    fi
fi
if [[ "$DRY_RUN" != "true" ]] && ! kbd_led_present && is_laptop; then
    run_as_user bash "$TARGET_RICE/scripts/kbd-backlight.sh" doctor 2>&1 | sed 's/^/   /' | head -n 8 || true
fi

# ---- safety check (optional): the program Settings > Security > "Safety check" starts
# Like sysmode it runs as root (system update, scans, firewall, backup), so the installed copy is root-owned: nothing running
# as you can change what you later start with sudo. Settings greys the entry out when /usr/local/bin/safety-check is missing.
if [[ "$SAFETY" == "true" ]]; then
    if [[ "$PACKAGES" == "true" ]]; then
        log_info "The safety check uses: clamav rkhunter lynis aide rsync libnotify (and checks whichever firewall you picked)"
        install_pkgs clamav rkhunter lynis aide rsync libnotify
    fi
    if [[ "$DRY_RUN" == "true" ]] || [[ -f "$BIN_DIR/safety-check" ]]; then
        try run_cmd "Installing /usr/local/bin/safety-check (root-owned)" as_root install -Dm755 -o root -g root "$BIN_DIR/safety-check" /usr/local/bin/safety-check
        log_info "Run it from Settings > Security > Safety check, or in a terminal:  sudo safety-check   (logs: /var/log/halcyon/safety_check/)"
    else
        warn_later "safety-check was not built, so it is not installed (its Settings entry stays greyed out). Retry: ./install.sh --safety-check"
    fi
elif [[ "$SAFETY_ASKED" == "true" && "$PACKAGES" == "true" && "$DRY_RUN" != "true" && -e /usr/local/bin/safety-check ]]; then
    try run_cmd "Removing /usr/local/bin/safety-check (you chose no safety check)" as_root rm -f /usr/local/bin/safety-check
else
    log_info "Safety check skipped: its entry in Settings > Security stays greyed out (add it later: ./install.sh --safety-check)."
fi

# ---- firewall: ai-firewall (Halcyon's), ufw, or leave it alone
# Exactly one of the two runs: ai-firewall's service conflicts with ufw's, and each branch switches the other one off.
aifw_build() {
    local src="$AIFW_SRC" tgt="$TARGET_HOME/.cache/halcyon-build/ai-firewall"
    if [[ -z "$src" ]]; then
        src="$TARGET_HOME/.local/src/ai-firewall"
        command -v git >/dev/null 2>&1 || install_pkgs git
        if [[ -d "$src/.git" ]]; then
            run_as_user_cmd "ai-firewall: fetching" git -C "$src" fetch --quiet origin || return 1
        else
            run_as_user_cmd "ai-firewall: downloading" git clone --quiet "$AIFW_REPO" "$src" || return 1
        fi
        if [[ -n "$AIFW_REV" ]]; then
            run_as_user_cmd "ai-firewall: version ${AIFW_REV:0:7}" git -C "$src" -c advice.detachedHead=false checkout --quiet --force "$AIFW_REV" || return 1
        else
            run_as_user_cmd "ai-firewall: latest version" git -C "$src" pull --quiet --ff-only || return 1
        fi
    fi
    [[ -f "$src/Cargo.toml" ]] || return 1
    # the eBPF half needs nightly with rust-src, and bpf-linker
    if ! run_as_user rustup toolchain list 2>/dev/null | grep -q '^nightly'; then
        run_as_user bash -c 'command -v rustup' >/dev/null 2>&1 || return 1
        run_as_user_cmd "ai-firewall: Rust nightly (for the eBPF half)" rustup toolchain install nightly --component rust-src --profile minimal || return 1
    fi
    if ! run_as_user bash -c 'PATH="$HOME/.local/bin:$PATH"; command -v bpf-linker' >/dev/null 2>&1; then
        run_as_user_cmd "ai-firewall: bpf-linker (a few minutes)" cargo install --locked bpf-linker || return 1
    fi
    run_as_user_cmd "ai-firewall: building (a few minutes)" env PATH="$TARGET_HOME/.cargo/bin:$TARGET_HOME/.local/bin:$PATH" CARGO_TARGET_DIR="$tgt" \
        cargo +nightly build --release --locked --manifest-path "$src/Cargo.toml" -p ai-firewall || return 1
    AIFW_BUILT="$tgt/release/ai-firewall"; AIFW_UNIT="$src/packaging/ai-firewall.service"
    [[ -x "$AIFW_BUILT" && -f "$AIFW_UNIT" ]]
}
aifw_install() {
    if [[ -x /usr/bin/ai-firewall ]]; then          # installed as a package (packaging/arch/PKGBUILD): pacman keeps it updated
        if command -v ufw >/dev/null 2>&1; then as_root ufw --force disable >/dev/null 2>&1 || true; fi
        as_root systemctl disable --now ufw.service firewalld.service >/dev/null 2>&1 || true
        try run_cmd "ai-firewall (package): starting" as_root systemctl enable --now ai-firewall.service
        log_success "ai-firewall (installed as a package) is guarding this machine: >firewall in the launcher"
        return 0
    fi
    if ! aifw_build; then
        if [[ -x /usr/local/bin/ai-firewall ]]; then
            warn_later "ai-firewall could not be updated (see the log), so the installed version stays in charge. Retry: ./install.sh --firewall ai"
            as_root systemctl enable --now ai-firewall.service >/dev/null 2>&1 || true
            return 0
        fi
        warn_later "ai-firewall could not be built (it needs rustup with nightly + rust-src, and bpf-linker; see the log). ufw was set up instead. Retry: ./install.sh --firewall ai"
        ufw_install
        return 0
    fi
    run_cmd "ai-firewall: installing /usr/local/bin/ai-firewall" as_root install -Dm755 -o root -g root "$AIFW_BUILT" /usr/local/bin/ai-firewall || { warn_later "ai-firewall: could not install the program"; return 0; }
    run_cmd "ai-firewall: installing its service" as_root install -Dm644 "$AIFW_UNIT" /etc/systemd/system/ai-firewall.service || true
    if [[ "$DRY_RUN" != "true" && ! -f /etc/ai-firewall/config.toml ]]; then
        /usr/local/bin/ai-firewall default-config | as_root install -Dm644 /dev/stdin /etc/ai-firewall/config.toml || true
    fi
    if command -v ufw >/dev/null 2>&1; then as_root ufw --force disable >/dev/null 2>&1 || true; fi
    as_root systemctl disable --now ufw.service firewalld.service >/dev/null 2>&1 || true
    as_root systemctl daemon-reload || true
    try run_cmd "ai-firewall: starting (it replaces ufw)" as_root systemctl enable --now ai-firewall.service
    as_root systemctl restart ai-firewall.service >/dev/null 2>&1 || true      # pick up a new build; filtering never stops (pinned links)
    log_success "ai-firewall is guarding this machine: the island page (>firewall in the launcher), Settings > Firewall, or  sudo ai-firewall top"
}
ufw_install() {
    [[ "$PACKAGES" == "true" ]] && install_pkgs ufw
    command -v ufw >/dev/null 2>&1 || { warn_later "ufw is not installed, so no firewall was set up"; return 0; }
    if command -v ai-firewall >/dev/null 2>&1; then
        as_root ai-firewall off >/dev/null 2>&1 || true
        as_root systemctl disable ai-firewall.service >/dev/null 2>&1 || true
    fi
    as_root ufw default deny incoming >/dev/null || true
    as_root ufw default allow outgoing >/dev/null || true
    try run_cmd "ufw: switching on" as_root ufw --force enable
    as_root systemctl enable ufw.service >/dev/null 2>&1 || true
    log_success "ufw is the firewall (deny incoming, allow outgoing)"
}
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Firewall: ${PICK_FIREWALL:-ai} (dry run: nothing changed)"
else
    case "${PICK_FIREWALL:-ai}" in
        ai)   aifw_install ;;
        ufw)  ufw_install ;;
        none) log_info "Firewall: left alone (Settings > Firewall stays greyed out; add one later: ./install.sh --firewall ai)" ;;
    esac
fi

# ---------------------------------------------------------------------------------------------- step 12
log_step "Step 12: Wallpaper and colours"
user_setup wallpaper  || warn_later "Wallpaper / colours: something did not work (is ImageMagick installed?)"
user_setup terminals  || warn_later "Terminal colour files could not be written."
user_setup app-themes || warn_later "App themes (Starship, fish, btop, yazi, Spotify, spotify-player, Discord, Thunar) could not all be set up: run ~/.config/Halcyon/scripts/user-setup.sh app-themes"
user_setup fish-commands || warn_later "The fish commands (halcyon, bar-builder, notification-builder ...) could not be installed: run ~/.config/Halcyon/scripts/user-setup.sh fish-commands"
if [[ "${VLM_PULLED:-false}" == "true" ]]; then
    # notes.conf is one of the files an update never overwrites; `notes set` validates the value and keeps the other lines
    run_as_user python3 "$TARGET_RICE/scripts/halcyon-notes.py" set NOTES_VLM 1 >>"$LOG_FILE" 2>&1 \
        && log_success "Settings > Notes > Describe pictures is on" \
        || warn_later "Could not switch on Settings > Notes > Describe pictures: do it by hand in Settings."
    if [[ "$PICK_VLM_MODEL" != "$VLM_DEFAULT_MODEL" ]]; then
        run_as_user python3 "$TARGET_RICE/scripts/halcyon-notes.py" set NOTES_VLM_MODEL "$PICK_VLM_MODEL" >>"$LOG_FILE" 2>&1 \
            || warn_later "Could not set the picture model name: run  notes set NOTES_VLM_MODEL $PICK_VLM_MODEL"
    fi
fi
# the `ai` / `advisor` commands (copies scripts, links them into ~/.local/bin, adds the PATH line): a side effect, so it is
# only shown with --dry-run
if [[ -f "$TARGET_RICE/scripts/install-ai.sh" ]]; then
    try run_as_user_cmd "Installing the ai and advisor commands" bash "$TARGET_RICE/scripts/install-ai.sh"
elif [[ -f "$RICE_SOURCE/scripts/install-ai.sh" ]]; then
    try run_as_user_cmd "Installing the ai and advisor commands" bash "$RICE_SOURCE/scripts/install-ai.sh"
fi
if [[ "$PACKAGES" == "true" ]]; then
    if [[ "$INSTALL_APPS" == "true" || ${#APPLY_PICKS[@]} -gt 0 ]]; then user_setup default-apps ${APPLY_PICKS[@]+"${APPLY_PICKS[@]}"} || true; fi
    # remember what you chose, so update.sh (and the next install.sh) install the same things without asking
    [[ "$RES_APPLY" == "true" && -n "$RES_PRESET" ]] && { user_setup resource-seed "$RES_PRESET" "$RES_LIMMODE" "$RES_LIM_RAM" "$RES_LIM_CPU" || true; }
    user_setup save-choices "RESOURCE_MODE=$RES_MODE" "RESOURCE_OFFSET=$RES_OFFSET" "BROWSER=$PICK_BROWSER" "FILES=$PICK_FILES" "EDITOR=$PICK_EDITOR" "MUSIC=$PICK_MUSIC" "SYSMODE=$([[ "$SYSMODE" == true ]] && echo yes || echo no)" "SAFETY_CHECK=$([[ "$SAFETY" == true ]] && echo yes || echo no)" "LLM=$([[ "$INSTALL_LLM" == true ]] && echo yes || echo no)" "LLM_MODEL=$PICK_LLM_MODEL" "WHISPER=$([[ "$INSTALL_WHISPER" == true ]] && echo yes || echo no)" "WHISPER_MODEL=$PICK_WHISPER_MODEL" "VLM=$([[ "$INSTALL_VLM" == true ]] && echo yes || echo no)" "VLM_MODEL=$PICK_VLM_MODEL" "PROMPT=$PICK_PROMPT" "RENDERER=$PICK_RENDERER" "PLYMOUTH=$([[ "$INSTALL_PLYMOUTH" == true ]] && echo yes || echo no)" "LUNA=$([[ "$INSTALL_LUNA" == true ]] && echo yes || echo no)" "LUNA_VOICE=$([[ "$INSTALL_LUNA_VOICE" == true ]] && echo yes || echo no)" "FIREWALL=$FIREWALL" "ANTIVIRUS=$([[ "$INSTALL_AV" == true ]] && echo yes || echo no)" "SECURITY_MODEL=$SECURITY_MODEL" || true
elif [[ -n "$PICK_PROMPT" ]]; then
    user_setup save-choices "PROMPT=$PICK_PROMPT" ${PICK_RENDERER:+"RENDERER=$PICK_RENDERER"} ${LOCK_LOGIN_SAVE:+"LOCK_LOGIN=$LOCK_LOGIN_SAVE"} || true
elif [[ -n "$PICK_RENDERER" ]]; then
    user_setup save-choices "RENDERER=$PICK_RENDERER" ${LOCK_LOGIN_SAVE:+"LOCK_LOGIN=$LOCK_LOGIN_SAVE"} || true     # --no-packages: the prompt choice is still remembered
fi
[[ "$PACKAGES" == "true" && "$SKIP_DRIVERS" != "true" ]] && { user_setup gpu-env "$GPU_ENV_MODE" || true; }

if [[ "$DRY_RUN" != "true" && $EUID -eq 0 ]]; then      # run as root: make sure nothing of the user's ended up owned by root
    chown -R "$TARGET_UID:$TARGET_GID" "$TARGET_HOME/.local/state/island" "$TARGET_HOME/.cache/island" "$TARGET_HOME/.cache/halcyon-build" \
        "$TARGET_HOME/.config/systemd" "$TARGET_HOME/Pictures/Wallpapers" "$TARGET_HOME/Pictures/Screenshots" 2>/dev/null || true
fi

# ---- the LUNA extra: the pinned commit, built as you (outside the rice, like the helpers), the program copied to ~/.local/bin.
# Skipped when that exact version is already installed. The build directory is removed afterwards (it grows to gigabytes).
install_luna() {
    local src="$TARGET_HOME/.local/src/LUNA-AI" stamp="$TARGET_HOME/.local/state/island/luna-rev" tgt="$TARGET_HOME/.cache/halcyon-build/luna"
    if [[ -x "$TARGET_HOME/.local/bin/luna" && "$(cat "$stamp" 2>/dev/null)" == "$LUNA_REV" ]]; then
        log_success "LUNA: this version is already installed (~/.local/bin/luna)"; return 0
    fi
    rust_ok || { warn_later "LUNA was not installed: it needs Rust ($(pkg_hint rust)), then ./install.sh --luna"; return 0; }
    command -v git >/dev/null 2>&1 || install_pkgs git
    if [[ -d "$src/.git" ]]; then
        run_as_user_cmd "LUNA: fetching" git -C "$src" fetch --quiet origin || { warn_later "LUNA: could not fetch $LUNA_REPO"; return 0; }
    else
        run_as_user_cmd "LUNA: downloading" git clone --quiet "$LUNA_REPO" "$src" || { warn_later "LUNA: could not clone $LUNA_REPO"; return 0; }
    fi
    run_as_user_cmd "LUNA: version ${LUNA_REV:0:7}" git -C "$src" -c advice.detachedHead=false checkout --quiet --force "$LUNA_REV" \
        || { warn_later "LUNA: the pinned version ${LUNA_REV:0:7} is not in $LUNA_REPO"; return 0; }
    run_as_user_cmd "LUNA: building (a few minutes)" env CARGO_TARGET_DIR="$tgt" cargo build --release --locked --manifest-path "$src/Cargo.toml" \
        || { warn_later "LUNA did not build (see the log). Try by hand: cd $src && cargo build --release"; return 0; }
    run_as_user_cmd "LUNA: installing ~/.local/bin/luna" install -Dm755 "$tgt/release/luna" "$TARGET_HOME/.local/bin/luna" || { warn_later "LUNA: could not install the program"; return 0; }
    if [[ "$DRY_RUN" != "true" ]]; then
        run_as_user bash -c 'mkdir -p "$(dirname "$1")" && printf "%s\n" "$2" > "$1"' _ "$stamp" "$LUNA_REV" || true
        run_as_user rm -rf "$tgt" || true
    fi
    log_success "LUNA installed: run 'luna' (its README: $src/README.md; the daemon: $src/deploy/luna-daemon.service, off until you enable it)"
}
# her voice: the packages that are heavy to build come from the distro (Arch only; elsewhere the script's venv takes them from PyPI),
# then scripts/luna-voice-setup.sh downloads the model and sets up the Python environment as you (no sudo inside it: LUNA_VOICE_NO_SUDO)
install_luna_voice() {
    local vs="$RICE_SOURCE/scripts/luna-voice-setup.sh"
    [[ -f "$vs" ]] || { warn_later "LUNA voice: $vs is missing"; return 0; }
    [[ "$DISTRO_FAMILY" == "arch" ]] && install_pkgs python-numpy python-onnxruntime-cpu python-soundfile
    run_as_user_cmd "LUNA voice: the Kokoro model (about 330 MB) and her Python environment" env LUNA_VOICE_NO_SUDO=1 bash "$vs" \
        || { warn_later "LUNA's voice was not set up. Try by hand: bash $vs"; return 0; }
    log_success "LUNA voice ready: turn on \"Read her answers aloud\" under Voice & Audio in her settings"
}
# ---- LUNA's models: she is only useful once the Ollama models her tiers point at are on this machine, so they are pulled here.
# The list is the stack in luna.toml (main / fast / deep / security / embeddings / vision) plus any model named in an existing
# ~/.config/luna/luna.toml, so a config you edited is followed. Already-present models are skipped. About 26 GB in total: override
# with LUNA_MODELS="name name ..." (replaces the list) or LUNA_MODELS=none (skip). Retry later: ./install.sh --luna
LUNA_MODELS_DEFAULT="qwen3:8b phi4-mini nomic-embed-text qwen2.5vl:3b richardyoung/qwen2.5-coder-14b-instruct-abliterated richardyoung/qwythos-9b-abliterated"
install_luna_models() {
    local cfg="$TARGET_HOME/.config/luna/luna.toml" want="" m have="" pulled=0 failed=0 present
    if [[ "${LUNA_MODELS:-}" == "none" ]]; then log_info "LUNA models: skipped (LUNA_MODELS=none)"; return 0; fi
    if [[ -n "${LUNA_MODELS:-}" ]]; then want="$LUNA_MODELS"
    else
        want="$LUNA_MODELS_DEFAULT"
        if [[ -f "$cfg" ]]; then
            # model names from the config: model, fast_model, deep_model, security_model, *_abliterated, *_unrestricted, embedding_model, [vision] model
            want+=" $(grep -E '^[[:space:]]*(model|fast_model|deep_model|security_model|security_model_abliterated|deep_model_unrestricted|embedding_model)[[:space:]]*=' "$cfg" 2>/dev/null \
                | sed -E 's/^[^=]*=[[:space:]]*"([^"]+)".*$/\1/' | tr '\n' ' ')"
        else
            want+=" qwen2.5:7b-instruct"     # the model LUNA's built-in default config uses, until a luna.toml exists
        fi
    fi
    # one name each: ":latest" and the bare name are the same model in Ollama
    local -a list=(); local seen=" "
    for m in $want; do
        m="${m%:latest}"
        [[ "$m" =~ ^[A-Za-z0-9._:/@+-]{1,100}$ ]] || { warn_later "LUNA models: '$m' is not a valid Ollama model name, skipped"; continue; }
        [[ "$seen" == *" $m "* ]] && continue
        seen+="$m "; list+=("$m")
    done
    [[ ${#list[@]} -gt 0 ]] || return 0
    log_info "LUNA models (${#list[@]}): ${list[*]}"
    if [[ "$DRY_RUN" == "true" ]]; then
        for m in "${list[@]}"; do run_as_user_cmd "LUNA: ollama pull $m" ollama pull "$m"; done
        return 0
    fi
    if declare -F setup_ollama >/dev/null 2>&1; then setup_ollama || true; fi    # defined in step 5; not there with --no-packages
    if ! run_as_user which ollama >/dev/null 2>&1 && ! command -v ollama >/dev/null 2>&1; then
        warn_later "LUNA models were not pulled: Ollama is not installed. Install it ($(pkg_hint ollama)), then run ./install.sh --luna"; return 0
    fi
    local _i
    for _i in $(seq 1 30); do     # the service needs a moment before it answers
        curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:11434/api/tags 2>/dev/null && break
        sleep 1
    done
    if ! curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:11434/api/tags 2>/dev/null; then
        warn_later "LUNA models were not pulled: Ollama is not answering on 127.0.0.1:11434. Start it (systemctl enable --now ollama), then run ./install.sh --luna"; return 0
    fi
    have=" $(run_as_user ollama list 2>/dev/null | awk 'NR>1{print $1}' | sed 's/:latest$//' | tr '\n' ' ') "
    for m in "${list[@]}"; do
        present=false; [[ "$have" == *" $m "* ]] && present=true
        if [[ "$present" == "true" ]]; then log_success "LUNA model already there: $m"; continue; fi
        if run_as_user_cmd "LUNA: pulling $m (this can take a while)" ollama pull "$m"; then
            pulled=$((pulled+1)); log_success "LUNA model installed: $m"
        else
            failed=$((failed+1)); warn_later "LUNA model $m was not downloaded. Retry: ollama pull $m"
        fi
    done
    log_info "LUNA models: $pulled pulled, $failed failed, the rest were already installed"
    return 0
}
[[ "$INSTALL_LUNA" == "true" ]] && install_luna
[[ "$INSTALL_LUNA" == "true" ]] && install_luna_models
[[ "$INSTALL_LUNA" == "true" && "$INSTALL_LUNA_VOICE" == "true" ]] && install_luna_voice

# ---- the Security center's modules: ai-firewall and ai-antivirus. Each is built as you from a source folder (or a
# pinned git revision), installed as root, and removed again when you switch it off. Neither needs the other.
# security_src NAME DIR REPO REV -> prints the source folder, cloning / updating REPO at REV into DIR when it is set
security_src() {
    local name=$1 dir=$2 repo=$3 rev=$4
    if [[ -n "$repo" ]]; then
        command -v git >/dev/null 2>&1 || install_pkgs git >&2
        # progress goes to stderr: stdout is the folder name the caller captures
        if [[ -d "$dir/.git" ]]; then
            run_as_user_cmd "$name: fetching" git -C "$dir" fetch --quiet origin >&2 || return 1
            [[ -n "$rev" ]] || run_as_user_cmd "$name: updating" git -C "$dir" merge --quiet --ff-only '@{upstream}' >&2 || return 1
        else
            run_as_user_cmd "$name: downloading" git clone --quiet "$repo" "$dir" >&2 || return 1
        fi
        [[ -n "$rev" ]] && { run_as_user_cmd "$name: version ${rev:0:7}" git -C "$dir" -c advice.detachedHead=false checkout --quiet --force "$rev" >&2 || return 1; }
    fi
    [[ -f "$dir/Cargo.toml" ]] || return 1
    echo "$dir"
}

# what a source folder looks like now: the git revision (+ a hash of uncommitted changes), else the newest file time.
# Saved after a good build, so an unchanged source is not rebuilt on every update.
src_stamp() {
    local dir=$1
    if git -C "$dir" rev-parse HEAD >/dev/null 2>&1; then
        echo "$(git -C "$dir" rev-parse HEAD)-$(git -C "$dir" status --porcelain 2>/dev/null | sha256sum | cut -c1-12)"
    else
        find "$dir" -path "$dir/target" -prune -o -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1
    fi
}
save_stamp() { [[ "$DRY_RUN" == "true" ]] || run_as_user bash -c 'mkdir -p "$(dirname "$1")" && printf "%s\n" "$2" > "$1"' _ "$1" "$2" || true; }

remove_ai_firewall() {
    [[ -e /usr/local/bin/ai-firewall ]] || return 0
    try run_cmd "ai-firewall: stopping the filter" as_root /usr/local/bin/ai-firewall off
    try run_cmd "ai-firewall: removing the service" as_root systemctl disable --now ai-firewall.service
    try run_cmd "ai-firewall: removing the program" as_root rm -f /usr/local/bin/ai-firewall /etc/systemd/system/ai-firewall.service
    try run_cmd "systemd: reloading units" as_root systemctl daemon-reload
    log_info "ai-firewall removed (its config stays in /etc/ai-firewall)"
}

install_ai_firewall() {
    local src tgt="$TARGET_HOME/.cache/halcyon-build/ai-firewall" keep=""
    if pacman -Q ai-firewall >/dev/null 2>&1; then
        log_success "ai-firewall: installed as a pacman package (/usr/bin/ai-firewall), left as it is"; return 0
    fi
    [[ -e /usr/local/bin/ai-firewall ]] && keep=" (the installed copy keeps running)"
    src=$(security_src ai-firewall "${AIFW_SRC:-$TARGET_HOME/.local/src/ai-firewall}" "$AIFW_REPO" "$AIFW_REV") \
        || { warn_later "ai-firewall: no source found (set AIFW_SRC to its folder, or AIFW_REPO / AIFW_REV); ufw stays$keep"; return 1; }
    local stamp="$TARGET_HOME/.local/state/island/aifw-src" now
    now=$(src_stamp "$src")
    if [[ -x /usr/local/bin/ai-firewall && "$(cat "$stamp" 2>/dev/null)" == "$now" ]]; then
        log_success "ai-firewall: this version is already installed"; return 0
    fi
    rust_ok || { warn_later "ai-firewall needs Rust ($(pkg_hint rustup)) to build$keep"; return 1; }
    run_as_user rustup toolchain list 2>/dev/null | grep -q '^nightly' \
        || { warn_later "ai-firewall needs the nightly toolchain: rustup toolchain install nightly --component rust-src$keep"; return 1; }
    run_as_user bash -c 'command -v bpf-linker' >/dev/null 2>&1 \
        || { warn_later "ai-firewall needs bpf-linker: cargo install bpf-linker$keep"; return 1; }
    run_as_user_cmd "ai-firewall: building (a few minutes)" env CARGO_TARGET_DIR="$tgt" cargo build --release --locked -p ai-firewall \
        --manifest-path "$src/Cargo.toml" || { warn_later "ai-firewall did not build (see the log)$keep"; return 1; }
    run_cmd "ai-firewall: installing /usr/local/bin/ai-firewall" as_root install -Dm755 "$tgt/release/ai-firewall" /usr/local/bin/ai-firewall || return 1
    run_cmd "ai-firewall: installing the service" as_root install -Dm644 "$src/packaging/ai-firewall.service" /etc/systemd/system/ai-firewall.service || return 1
    if [[ "$DRY_RUN" != "true" && ! -f /etc/ai-firewall/config.toml ]]; then
        /usr/local/bin/ai-firewall default-config | as_root install -Dm644 /dev/stdin /etc/ai-firewall/config.toml
    fi
    [[ "$DRY_RUN" == "true" ]] || as_root /usr/local/bin/ai-firewall check || { warn_later "ai-firewall: /etc/ai-firewall/config.toml does not check out"; return 1; }
    # it replaces ufw / firewalld: two filters at once fight over the same traffic
    local fw
    for fw in ufw firewalld; do
        if systemctl is-enabled "$fw.service" >/dev/null 2>&1; then
            [[ $fw == ufw ]] && try run_cmd "ufw: switching it off" as_root ufw --force disable
            try run_cmd "$fw: disabling the service" as_root systemctl disable --now "$fw.service"
        fi
    done
    try run_cmd "systemd: reloading units" as_root systemctl daemon-reload
    run_cmd "ai-firewall: starting" as_root systemctl enable --now ai-firewall.service || return 1
    [[ "$DRY_RUN" != "true" ]] && run_as_user rm -rf "$tgt" || true
    save_stamp "$stamp" "$now"
    log_success "ai-firewall installed: Security center (>security), or sudo ai-firewall top"
}

# Synapse was ai-antivirus's old name: its package is replaced, its settings carried over by the new package
AV_UNITS=(ai-antivirus-sensord.service ai-antivirus-engined.service ai-antivirus-responderd.service ai-antivirus-analyzer.service)
remove_old_synapse() {
    # -Q also matches `provides`, and ai-antivirus provides synapse-edr: only the real old package counts
    pacman -Qi synapse-edr 2>/dev/null | grep -q '^Name *: synapse-edr$' || return 0
    try run_cmd "Synapse (old name): stopping its services" as_root systemctl disable --now synapse-sensord.service synapse-engined.service synapse-responderd.service synapse-ai.service
    try run_as_user_cmd "Synapse (old name): desktop notifications off" systemctl --user disable --now synapse-notify.service
    try run_cmd "Synapse (old name): removing the package (its config is kept as .pacsave)" as_root pacman -R --noconfirm synapse-edr
}

remove_antivirus() {
    remove_old_synapse
    pacman -Q ai-antivirus >/dev/null 2>&1 || return 0
    try run_cmd "ai-antivirus: stopping its services" as_root systemctl disable --now "${AV_UNITS[@]}"
    try run_as_user_cmd "ai-antivirus: desktop notifications off" systemctl --user disable --now ai-antivirus-notify.service
    try run_cmd "ai-antivirus: removing the package (its config is kept as .pacsave)" as_root pacman -R --noconfirm ai-antivirus
}

install_antivirus() {
    local src pkg
    if [[ "$PKG_MGR" != "pacman" ]]; then
        warn_later "ai-antivirus is packaged for Arch only (makepkg): skipped on ${DISTRO_NAME}. ClamAV works here: Security center > ClamAV."
        return 1
    fi
    src=$(security_src ai-antivirus "${AV_SRC:-$TARGET_HOME/.local/src/ai-antivirus}" "$AV_REPO" "$AV_REV") \
        || { warn_later "ai-antivirus: no source found (set AV_SRC to its folder, or AV_REPO / AV_REV)"; return 1; }
    local stamp="$TARGET_HOME/.local/state/island/ai-antivirus-src" now
    now=$(src_stamp "$src")
    if pacman -Q ai-antivirus >/dev/null 2>&1 && [[ "$(cat "$stamp" 2>/dev/null)" == "$now" ]]; then
        log_success "ai-antivirus: this version is already installed"; return 0
    fi
    rust_ok || { warn_later "ai-antivirus needs Rust (sudo pacman -S rustup) to build"; return 1; }
    install_pkgs base-devel clang sqlite libarchive
    if [[ ! -f "$src/target/bpf/ai-antivirus-ebpf.o" ]] && ! run_as_user bash -c 'command -v bpf-linker' >/dev/null 2>&1; then
        warn_later "ai-antivirus needs bpf-linker for its eBPF sensor: cargo install bpf-linker (and rustup toolchain install nightly --component rust-src)"
        return 1
    fi
    if [[ ! -f "$src/target/bpf/ai-antivirus-ebpf.o" ]] && ! run_as_user rustup toolchain list 2>/dev/null | grep -q '^nightly'; then
        warn_later "ai-antivirus needs the nightly toolchain for its eBPF sensor: rustup toolchain install nightly --component rust-src"
        return 1
    fi
    run_as_user_cmd "ai-antivirus: building the package (a few minutes)" bash -c 'cd "$1/packaging/arch" && makepkg -f --noconfirm' _ "$src" \
        || { warn_later "ai-antivirus did not build (see the log). By hand: cd $src/packaging/arch && makepkg -f"; return 1; }
    # [0-9]: the package itself, not makepkg's ai-antivirus-debug-* next to it
    if [[ "$DRY_RUN" == "true" ]]; then pkg="$src/packaging/arch/ai-antivirus-[0-9]*.pkg.tar.zst"
    else pkg=$(ls -t "$src"/packaging/arch/ai-antivirus-[0-9]*.pkg.tar.zst 2>/dev/null | head -1); fi
    [[ -n "$pkg" ]] || { warn_later "ai-antivirus: the package file is missing after the build"; return 1; }
    remove_old_synapse
    run_cmd "ai-antivirus: installing the package" as_root pacman -U --noconfirm "$pkg" || return 1
    # alert-only by default: the sensor, the engine and the responder run; the AI analyzer stays off until you set it up
    run_cmd "ai-antivirus: starting (alert-only)" as_root systemctl enable --now "${AV_UNITS[@]:0:3}" || return 1
    # the Security center reads `ai-antivirus status` (group ai-antivirus: the database and the event log); desktop
    # notifications need group ai-antivirus-notify. Both apply from the next login.
    try run_cmd "ai-antivirus: adding $TARGET_USER to its groups" as_root usermod -aG ai-antivirus,ai-antivirus-notify "$TARGET_USER"
    try run_as_user_cmd "ai-antivirus: desktop notifications" systemctl --user enable --now ai-antivirus-notify.service
    save_stamp "$stamp" "$now"
    log_success "ai-antivirus installed (alert-only): Security center (>security), or ai-antivirus status"
}

# ai-antivirus reports every systemd unit a program other than pacman / systemctl writes (rule AV-B-0005), and this installer
# writes Halcyon's units again each time update.sh runs it. Two narrow program exceptions: the two absolute paths the installer
# is run from (get.sh and update.sh run it as  bash <path>/install.sh). Everything else stays watched; malware found in a file
# is still reported. docs/antivirus.md explains it and how to remove them (sudo ai-antivirus exceptions remove ...).
av_installer_exceptions() {
    [[ "$AV_EXCEPTION" == "true" ]] || { log_info "ai-antivirus: no exception for the installer (--no-av-exception)"; return 0; }
    [[ "$DRY_RUN" == "true" ]] || command -v ai-antivirus >/dev/null 2>&1 || return 0
    local p
    for p in '~/.config/Halcyon/install.sh' '~/.cache/halcyon-update/install.sh'; do
        try run_cmd "ai-antivirus: exception for the Halcyon installer ($p)" \
            as_root ai-antivirus exceptions add program "$p" --name "Halcyon installer"
    done
}

# the assistants' model (firewall Ask, antivirus Ask): pulled once when Ollama is there; both pick it up by themselves
pull_security_model() {
    [[ -n "$SECURITY_MODEL" && "$SECURITY_MODEL" != none ]] || return 0
    command -v ollama >/dev/null 2>&1 || { log_info "Security assistants: no Ollama, so they answer from the doctor and status instead"; return 0; }
    run_as_user ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -e "$SECURITY_MODEL" -e "$SECURITY_MODEL:latest" && return 0
    try run_as_user_cmd "Security assistants: downloading $SECURITY_MODEL (one time)" ollama pull "$SECURITY_MODEL"
}

# ai-antivirus.toml [ai] model: the placeholder is replaced; a model you set by hand stays unless you picked one in this run.
# `enabled` is not touched: the analyzer stays off until you switch it on (alert-only).
set_antivirus_model() {
    local conf=/etc/ai-antivirus/ai-antivirus.toml cur
    [[ -n "$SECURITY_MODEL" && "$SECURITY_MODEL" != none && "$DRY_RUN" != "true" && -f "$conf" ]] || return 0
    cur=$(sed -n "/^\[ai\]/,/^\[/ s/^model *= *['\"]\(.*\)['\"].*/\1/p" "$conf" | head -1)
    [[ "$cur" == "$SECURITY_MODEL" ]] && return 0
    [[ "$cur" == "set-your-local-model" || "$SECURITY_MODEL_PICKED" == "true" ]] || return 0
    try run_cmd "ai-antivirus: its analyzer model is $SECURITY_MODEL" as_root sed -i "/^\[ai\]/,/^\[/ s|^model *=.*|model = '$SECURITY_MODEL'|" "$conf"
}

if [[ "$PACKAGES" == "true" ]]; then
    case "$FIREWALL" in
        ai)   install_ai_firewall || true ;;
        ufw)  # back to ufw from ai-firewall: remove it, then switch ufw on again when it is installed (the safety check installs it)
              if [[ "$FIREWALL_ASKED" == "true" && -e /usr/local/bin/ai-firewall ]]; then
                  remove_ai_firewall
                  if command -v ufw >/dev/null 2>&1; then
                      try run_cmd "ufw: switching it on again" as_root systemctl enable --now ufw.service
                      try run_cmd "ufw: enabling the rules" as_root ufw --force enable
                  fi
              fi ;;
        none) [[ "$FIREWALL_ASKED" == "true" ]] && remove_ai_firewall ;;
    esac
    if [[ "$INSTALL_AV" == "true" ]]; then install_antivirus || true; av_installer_exceptions
    elif [[ "$AV_ASKED" == "true" ]]; then remove_antivirus; fi
    [[ "$FIREWALL" == ai || "$INSTALL_AV" == "true" ]] && pull_security_model
    [[ "$INSTALL_AV" == "true" ]] && set_antivirus_model
fi

# the boot splash, now that the colours are made (scheme/current.lua): rendered in them, then the initramfs is rebuilt
if [[ "$INSTALL_PLYMOUTH" == "true" ]]; then
    if [[ -f "$TARGET_RICE/scripts/halcyon-plymouth.sh" ]]; then
        run_cmd "Boot splash (Plymouth): theme in your colours, initramfs rebuilt" as_root env HALCYON_DIR="$TARGET_RICE" bash "$TARGET_RICE/scripts/halcyon-plymouth.sh" install \
            || warn_later "The boot splash was not set up (see the log). Try it by hand: $TARGET_RICE/scripts/halcyon-plymouth.sh install"
    else
        warn_later "scripts/halcyon-plymouth.sh is missing from $TARGET_RICE: the boot splash was not set up."
    fi
fi

# ---------------------------------------------------------------------------------------------- step 13
log_step "Step 13: Checking the result"

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "\n${GREEN}${BOLD}Dry run finished: nothing was changed.${RESET}  ${DIM}Log: ${LOG_FILE}${RESET}"
    exit 0
fi

MISSING_CRITICAL=()
check_cmd() {   # check_cmd LABEL COMMAND-OR-PATH [critical]
    if [[ -x "$2" ]] || command -v "$2" >/dev/null 2>&1; then echo -e "  ${GREEN}✔${RESET} $1"
    else echo -e "  ${YELLOW}⚠${RESET} $1 (missing)"; [[ "${3:-}" == "critical" ]] && MISSING_CRITICAL+=("$1"); fi
    return 0
}
check_cmd Hyprland Hyprland critical
check_cmd quickshell quickshell critical
check_cmd start-shell.sh "$TARGET_RICE/scripts/start-shell.sh" critical
check_cmd hx "$BIN_DIR/hx" critical
check_cmd power-manager "$BIN_DIR/power-manager" critical
check_cmd hgl "$BIN_DIR/hgl"
check_cmd touchpad-gestures "$BIN_DIR/touchpad-gestures" critical
if [[ "$SYSMODE" == "true" ]]; then
    for h in "${SYSMODE_CRATES[@]}"; do check_cmd "$h" "$BIN_DIR/$h" critical; done
fi
if [[ "$PACKAGES" == "true" ]]; then
    for id in $PICK_BROWSER; do [[ "$id" == keep ]] || check_cmd "$id" "$(choice_bin browser "$id")"; done
    for id in $PICK_FILES;   do [[ "$id" == none ]] || check_cmd "$id" "$(choice_bin files "$id")"; done
    for id in $PICK_EDITOR;  do [[ "$id" == none ]] || check_cmd "$id" "$(choice_bin editor "$id")"; done
fi
if [[ "$INSTALL_APPS" == "true" && "$PACKAGES" == "true" ]]; then
    check_cmd discord discord
fi
if [[ "$PACKAGES" == "true" ]]; then
    for id in $PICK_MUSIC; do
        case "$id" in
            none) ;;
            spotify) command -v spotify >/dev/null 2>&1 && check_cmd spotify spotify || check_cmd spotify-launcher spotify-launcher ;;
            *) check_cmd "$id" "$(choice_bin music "$id")" ;;
        esac
    done
fi
for c in foot fuzzel brightnessctl playerctl wpctl nmcli bluetoothctl powerprofilesctl cava grim slurp wl-copy cliphist \
         hypridle hyprlock hyprsunset pkexec lspci nm-applet blueman-applet kbuildsycoca6 wayfreeze bemoji wlogout iw; do
    check_cmd "$c" "$c"
done
check_polkit() {
    for p in /usr/lib/polkit-kde-authentication-agent-1 \
             /usr/libexec/polkit-kde-authentication-agent-1 \
             /usr/lib/*-linux-gnu/libexec/polkit-kde-authentication-agent-1 \
             /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
             /usr/libexec/polkit-gnome/polkit-gnome-authentication-agent-1 \
             /usr/lib/*-linux-gnu/polkit-gnome-authentication-agent-1 \
             /usr/lib/hyprpolkitagent/hyprpolkitagent \
             /usr/libexec/hyprpolkitagent; do
        [[ -x "$p" ]] && { echo -e "  ${GREEN}✔${RESET} polkit agent ($(basename "$p"))"; return 0; }
    done
    echo -e "  ${YELLOW}⚠${RESET} polkit agent (missing)"
    return 0
}
check_polkit

check_portal() {
    for p in /usr/lib/xdg-desktop-portal-hyprland \
             /usr/lib/hyprland/xdg-desktop-portal-hyprland \
             /usr/libexec/xdg-desktop-portal-hyprland \
             /usr/lib/*-linux-gnu/xdg-desktop-portal-hyprland; do
        [[ -x "$p" ]] && { echo -e "  ${GREEN}✔${RESET} xdg-desktop-portal-hyprland"; return 0; }
    done
    echo -e "  ${YELLOW}⚠${RESET} xdg-desktop-portal-hyprland (missing)"
    return 0
}
check_portal
case "$HYPR_CONFIG_OK" in
    yes) echo -e "  ${GREEN}✔${RESET} Hyprland accepts the Halcyon config" ;;
    no)  echo -e "  ${RED}✘${RESET} Hyprland reports errors in the Halcyon config (listed above)" ;;
    *)   echo -e "  ${DIM}•${RESET} Halcyon config: not checked by Hyprland here" ;;
esac

if [[ -e "$TARGET_RICE/hyprland.lua" ]]; then echo -e "  ${GREEN}✔${RESET} Halcyon files in $TARGET_RICE"
else echo -e "  ${RED}✘${RESET} Halcyon files missing in $TARGET_RICE"; MISSING_CRITICAL+=("config"); fi

if [[ "$SKIP_TUNE" != "true" ]]; then
    # exit code 2 = sudo let it in and halcyon-tune answered "usage"; 1 = sudo wanted a password
    TUNE_RC=0; run_as_user sudo -n /usr/local/bin/halcyon-tune >/dev/null 2>&1 || TUNE_RC=$?
    if [[ "$TUNE_RC" -eq 2 ]]; then echo -e "  ${GREEN}✔${RESET} halcyon-tune works without a password (Gaming mode boost, power manager, Wi-Fi power saving)"
    else echo -e "  ${YELLOW}⚠${RESET} halcyon-tune is not usable without a password yet"; WARNINGS+=("halcyon-tune: sudo still asks for a password (see Step 11)"); fi
fi

if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then echo; log_warn "Not installed (name changed, not in the repos, or skipped): ${FAILED_PKGS[*]}"; fi
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo; log_warn "Finished with ${#WARNINGS[@]} note(s):"
    for w in "${WARNINGS[@]}"; do echo -e "    - $w"; done
fi

echo
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════${RESET}"
if [[ ${#MISSING_CRITICAL[@]} -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}  Halcyon is installed, but these parts are missing: ${MISSING_CRITICAL[*]}${RESET}"
else
    echo -e "${GREEN}${BOLD}  Halcyon is installed.${RESET}"
fi
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════${RESET}"
echo
echo -e "${BOLD}Start it${RESET}"
[[ "$NEED_REBOOT" == "true" ]] && echo -e "  ${CYAN}•${RESET} ${YELLOW}Reboot first${RESET}: a new graphics / keyboard driver was installed and loads at boot."
echo -e "  ${CYAN}•${RESET} Login screen: pick the ${BOLD}Halcyon${RESET} session (or ${BOLD}Hyprland${RESET}: it loads Halcyon too)."
echo -e "  ${CYAN}•${RESET} From a text console: run ${BOLD}start-halcyon${RESET}"
[[ "$GREETER" == "true" ]] && echo -e "  ${CYAN}•${RESET} Halcyon login screen: set up for the next boot. Try it now: ${BOLD}scripts/halcyon-greeter.sh preview${RESET} (password: preview). Undo: ./install.sh --remove-greeter"
[[ "$WANT_LOCK_LOGIN" == "true" ]] && echo -e "  ${CYAN}•${RESET} Lock-screen login is on: just reboot, Halcyon starts locked. (undo: ./install.sh --remove-lock-login; skip it once: touch ~/.cache/island/no-autostart)"
echo -e "  ${CYAN}•${RESET} Login splash (moving stars and the Halcyon sparkle): on by default, once per login; it also plays on unlock and (folding shut) on shutdown. See it now: ${BOLD}halcyon splash${RESET}  (turn it off: Settings > Power & lock)"
echo -e "  ${CYAN}•${RESET} Weekly sky (your week as stars, savable as a picture): ${BOLD}halcyon weekly-sky${RESET}.  Wallpaper that follows the sun: Settings > Splash, sky & time of day"
[[ "$NEED_RELOGIN" == "true" ]] && echo -e "  ${CYAN}•${RESET} ${YELLOW}Log out and in again first${RESET}: you were added to the input / video groups (touchpad gestures, brightness)."
echo -e "  ${CYAN}•${RESET} Already inside Halcyon? Restart the island:  pkill quickshell; $TARGET_RICE/scripts/start-shell.sh island &"
echo -e "  ${CYAN}•${RESET} Something not working (no bar, no keybinds)?  ${BOLD}$TARGET_RICE/scripts/halcyon-doctor.sh${RESET}   (island log: ~/.cache/island/quickshell-island.log)"
echo
echo -e "${BOLD}First keys${RESET}"
echo -e "  ${MAGENTA}Super (tap)${RESET}       Launcher          ${MAGENTA}Super + T${RESET}         Terminal"
echo -e "  ${MAGENTA}Super + Q${RESET}         Close window      ${MAGENTA}Super + Tab${RESET}       Workspace tree"
echo -e "  ${MAGENTA}Super + /${RESET}         All shortcuts     ${MAGENTA}Super + L${RESET}         Lock screen"
echo -e "  ${MAGENTA}Super + Ctrl + ←/→${RESET}  Previous / next workspace (a new one after the last)"
[[ "$SAFETY" == "true" ]] && echo -e "  ${MAGENTA}Settings > Security${RESET} Safety check (update, malware / rootkit scan, firewall, backup)"
command -v ai-firewall >/dev/null 2>&1 && [[ "${PICK_FIREWALL:-ai}" == "ai" ]] && echo -e "  ${MAGENTA}>firewall${RESET}           ai-firewall: the Firewall Center (launcher), or in a terminal:  sudo ai-firewall top"
echo
echo -e "${DIM}Update later: ~/.config/Halcyon/update.sh     ·     Settings: from the island     ·     Log of this run: ${LOG_FILE}${RESET}"
echo
[[ ${#MISSING_CRITICAL[@]} -gt 0 ]] && exit 1
exit 0
