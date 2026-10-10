#!/usr/bin/env bash
# ==============================================================================================================
# Halcyon installer: ONE script that sets everything up on Arch Linux and Arch-based systems (CachyOS, EndeavourOS,
# Manjaro, Garuda, Artix ...). Run it from the folder you downloaded:
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
#       Dolphin, ...), the code editor (VSCodium, Zed, ...) and whether to install sysmode and the safety check; plus foot, Spotify, Discord
#    6  Rust toolchain (for the helpers below)
#    7  copies the rice to ~/.config/Halcyon (an older copy is backed up; your hypr-user.lua, scheme/current.lua and
#       gamemode.conf are kept)
#    8  builds the Rust helpers (hx, power-manager, touchpad-gestures)
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
#   --no-aur               never install from the AUR         --upgrade        run a full system upgrade (pacman -Syu) first
#   --no-sysmode           skip the hardening CLI + services  --no-tune        skip halcyon-tune and its sudo rule
#   --link                 symlink ~/.config/Halcyon to this folder instead of copying it (for development)
#   --user NAME            (when run as root) install for this user
#   --tty-autostart        start Halcyon automatically when you log in on tty1
#   --lock-login           use the lock screen as login screen even if a login manager exists
#   --no-lock-login        never set that up (you log in on the text console and start Halcyon by hand)
#   --remove-lock-login    undo it: no more auto-login on tty1, tty1 is an ordinary text login again
#   --no-apps              do not install foot / Spotify / Discord (and no file manager unless you ask for one)
#   --browser ID           firefox | zen | librewolf | floorp | chromium | brave | vivaldi | chrome | qutebrowser | keep
#   --files ID[,ID]        thunar | yazi | dolphin | nautilus | nemo | pcmanfm | none   (the first one opens folders: SUPER+E)
#   --editor ID[,ID]       codium | zeditor | neovim | none                              (the first one is SUPER+C)
#   --sysmode              install sysmode without asking (--no-sysmode: skip it)
#   --safety-check         install the safety check (system update, malware / rootkit scan, firewall, audit, backup) without asking
#                          (--no-safety-check: skip it; its entry in Settings > Backup is then greyed out and disabled)
#   --choose               ask the questions above again (they are asked once, then remembered for update.sh)
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
PACKAGES=true; SKIP_DRIVERS=false; SKIP_AUR=false; UPGRADE=auto; SKIP_TUNE=false
SYSMODE=true; SYSMODE_ASKED=false; [[ "${SKIP_SYSMODE:-0}" = 1 ]] && { SYSMODE=false; SYSMODE_ASKED=true; }
SAFETY=false; SAFETY_ASKED=false            # the safety check is opt-in: it updates the system, scans and can back up to a disk
PICK_BROWSER=""; PICK_FILES=""; PICK_EDITOR=""; CHOOSE=false; APPLY_PICKS=()      # your app choices (see choose_apps)
LINK_CONFIG=false; REQUESTED_USER=""; TTY_AUTOSTART=false; LOCK_LOGIN=auto; REMOVE_LOGIN=false

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
    [[ -n "$SUDOERS_TMP" ]] && rm -f "$SUDOERS_TMP" 2>/dev/null || true
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
        --no-drivers)       SKIP_DRIVERS=true ;;
        --no-aur)           SKIP_AUR=true ;;
        --upgrade)          UPGRADE=yes ;;
        --sysmode)          SYSMODE=true; SYSMODE_ASKED=true ;;
        --no-sysmode)       SYSMODE=false; SYSMODE_ASKED=true ;;
        --safety-check)     SAFETY=true; SAFETY_ASKED=true ;;
        --no-safety-check)  SAFETY=false; SAFETY_ASKED=true ;;
        --browser)          shift; PICK_BROWSER="${1:-}"; [[ -n "$PICK_BROWSER" ]] || die "--browser needs a name (see --help)" ;;
        --browser=*)        PICK_BROWSER="${1#--browser=}" ;;
        --files|--file-manager) shift; PICK_FILES="${1:-}"; [[ -n "$PICK_FILES" ]] || die "--files needs a name (see --help)" ;;
        --files=*)          PICK_FILES="${1#--files=}" ;;
        --editor)           shift; PICK_EDITOR="${1:-}"; [[ -n "$PICK_EDITOR" ]] || die "--editor needs a name (see --help)" ;;
        --editor=*)         PICK_EDITOR="${1#--editor=}" ;;
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
                     "HALCYON_DIR=$TARGET_RICE" "HALCYON_STAMP=$TIMESTAMP" )
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

confirm() {   # default NO: for anything that changes a lot
    [[ "$AUTO_CONFIRM" == "true" ]] && return 0
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
log_info "System: ${BOLD}${DISTRO_NAME}${RESET} (${DISTRO_ID}), ${ARCH_CPU}"

if [[ "$PACKAGES" == "true" ]]; then
    command -v pacman >/dev/null 2>&1 || die "pacman not found: this installer is for Arch and Arch-based systems. Install the packages from README.md by hand, then run again with --no-packages."
    case " $DISTRO_ID $DISTRO_LIKE " in
        *" arch "*|*" cachyos "*|*" endeavouros "*|*" manjaro "*|*" garuda "*|*" artix "*|*" arcolinux "*) ;;
        *) log_warn "${DISTRO_NAME} is not a known Arch derivative, but pacman is available."
           confirm "Go on anyway?" || exit 1 ;;
    esac
fi

if [[ "$REMOVE_LOGIN" != "true" ]]; then
    [[ -f "$RICE_SOURCE/hyprland.lua" ]] || die "The Halcyon files were not found next to this script (${RICE_SOURCE}). Run install.sh from inside the Halcyon folder."
    for d in power-manager touchpad-gestures hx recon-deceiver log-analyst attacker-dossier setStaticMac; do
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
    command -v sudo >/dev/null 2>&1 || die "sudo is required (pacman -S sudo), or run this as root with --user NAME."
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Checking sudo..."
        sudo -v || die "sudo did not accept the password: administrator rights are needed."
        ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
        SUDO_KEEPALIVE_PID=$!
    fi
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

# ---- pre-flight
if [[ "$PACKAGES" == "true" ]]; then
    if [[ -e /var/lib/pacman/db.lck ]] && ! pgrep -x pacman >/dev/null 2>&1; then
        die "Stale pacman lock at /var/lib/pacman/db.lck. Remove it (sudo rm /var/lib/pacman/db.lck) and run again."
    fi
    if [[ "$DRY_RUN" != "true" ]] && command -v curl >/dev/null 2>&1 \
       && ! curl -fsS --max-time 15 -o /dev/null https://archlinux.org 2>>"$LOG_FILE"; then
        warn_later "archlinux.org is not reachable: installing missing packages will probably fail."
    fi
fi
# a leftover temporary sudo rule from a run that was killed halfway
[[ -e /etc/sudoers.d/99-halcyon-installer-tmp ]] && as_root rm -f /etc/sudoers.d/99-halcyon-installer-tmp

if [[ "$DRY_RUN" != "true" ]]; then
    echo
    echo -e "${BOLD}This will:${RESET}"
    [[ "$PACKAGES" == "true" ]] && echo "  - install missing packages with pacman (and a few optional ones from the AUR)"
    echo "  - copy Halcyon to ${TARGET_RICE} (an older copy is saved in ~/.config/Halcyon-backups)"
    echo "  - build the Rust helpers, set up the Hyprland entry, the login-screen session and the user services"
    [[ "$SKIP_TUNE" != "true" ]] && echo "  - install halcyon-tune and ONE sudo rule so Gaming mode / power manager / Wi-Fi power saving work without a password prompt"
    [[ "$SYSMODE" == "true" ]]   && echo "  - install the sysmode hardening CLI and its boot service"
    [[ "$SAFETY" == "true" ]]    && echo "  - install the safety check (ClamAV, rkhunter, lynis, AIDE, ufw, rsync) and add it to Settings > Backup"
    confirm "Go ahead?" || { echo "Nothing was changed."; exit 0; }
fi

# ---------------------------------------------------------------------------------------------- step 2
log_step "Step 2: Package manager"

pkg_missing() { [[ -n "$(pacman -T "$1" 2>/dev/null)" ]]; }       # honours "provides", unlike pacman -Q

ensure_aur_helper() {   # called only when an AUR package is really needed; installs yay-bin if no helper exists
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

# install_pkgs [--critical] [--repo-only] NAME...   official repos first, AUR for the rest; one bad name never stops the others
#   --critical    the installer stops when one of them cannot be installed
#   --repo-only   never offer the AUR for these (driver / firmware packages: a name that is not in the repos is skipped quietly)
# pacman always runs with --noconfirm: you already said "Go ahead" above, and a question printed inside a logged command
# is how an installer looks frozen.
install_pkgs() {
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

MULTILIB_ENABLED=false
if [[ "$PACKAGES" == "true" ]]; then
    grep -qE '^\s*\[multilib\]' /etc/pacman.conf && MULTILIB_ENABLED=true
    log_info "multilib (32-bit libraries): $([[ "$MULTILIB_ENABLED" == "true" ]] && echo enabled || echo "not enabled: 32-bit packages are skipped")"

    # Arch does not support installing packages on top of an old system ("partial upgrade": a new Hyprland / Mesa next to old
    # libraries is how a machine ends up not booting into its desktop). So: a machine that has no Hyprland yet, or whose
    # package databases are old, gets a full upgrade (asked first; with --yes it is done on the fresh machine). A machine
    # that already runs Hyprland and was synced recently (update.sh runs this installer often) is left alone, because an
    # upgrade can replace the kernel under a running desktop; --upgrade forces one.
    if [[ "$UPGRADE" == "auto" ]]; then
        DB_AGE_DAYS=999
        if DBF="$(ls -t /var/lib/pacman/sync/*.db 2>/dev/null | head -n1)" && [[ -n "$DBF" ]]; then
            DB_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$DBF") ) / 86400 ))
        fi
        if ! command -v Hyprland >/dev/null 2>&1 || [[ "$DB_AGE_DAYS" -gt 7 ]]; then
            if [[ "$AUTO_CONFIRM" == "true" ]]; then
                command -v Hyprland >/dev/null 2>&1 && UPGRADE=no || UPGRADE=yes
            elif [[ -t 0 ]] && ask "Full system upgrade first (pacman -Syu)? Recommended: Hyprland is not installed yet or the package databases are ${DB_AGE_DAYS} days old, and installing on top of an old system can break it."; then
                UPGRADE=yes
            else UPGRADE=no; fi
        else UPGRADE=no; fi
    fi
    if [[ "$UPGRADE" == "yes" ]]; then
        run_cmd "Full system upgrade (pacman -Syu)" as_root pacman -Syu --noconfirm \
            || die "The system upgrade failed. Fix pacman (mirrors / keyring) and run again."
    else
        log_info "No system upgrade (add --upgrade for one). If installs fail with 404 errors or missing libraries, run: sudo pacman -Syu"
    fi
    install_pkgs --critical base-devel git curl pkgconf pciutils
else
    log_info "Skipping packages (--no-packages)."
fi

# ---------------------------------------------------------------------------------------------- step 3
log_step "Step 3: Graphics drivers and CPU microcode"

kernel_headers() {
    local base f out=()
    for f in /usr/lib/modules/*/pkgbase; do
        [[ -f "$f" ]] || continue
        base="$(<"$f")"
        pacman -Si "${base}-headers" >/dev/null 2>&1 && out+=("${base}-headers")
    done
    [[ ${#out[@]} -eq 0 ]] && out=(linux-headers)
    printf '%s\n' "${out[@]}" | sort -u
}
installed_kernels() {   # the pkgbase of every installed kernel: linux, linux-lts, linux-zen, linux-cachyos ...
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
        for q in nvidia nvidia-open nvidia-dkms nvidia-open-dkms nvidia-lts nvidia-580xx-dkms nvidia-470xx-dkms; do pacman -Qq "$q" >/dev/null 2>&1 && NV_PRESENT=true; done
        pacman -Qq linux-cachyos-nvidia-open >/dev/null 2>&1 && NV_PRESENT=true

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
CHOICES_FILE="$TARGET_HOME/.local/state/island/install-choices.env"
have_any() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && return 0; done; return 1; }
saved_choice() { [[ -f "$CHOICES_FILE" ]] && sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$CHOICES_FILE" | tail -n1 || true; }

# menu_pick OUTVAR "Title" "default ids" MULTI(0|1) "id|Label|note" ...   -> OUTVAR = the chosen ids (space separated)
menu_pick() {
    local out=$1 title=$2 def=$3 multi=$4; shift 4
    local ids=() labels=() notes=() line a b c i ans tok mark picked=() defnames=""
    for line in "$@"; do IFS='|' read -r a b c <<<"$line"; ids+=("$a"); labels+=("$b"); notes+=("$c"); done
    echo -e "\n  ${CYAN}${BOLD}${title}${RESET}"
    for i in "${!ids[@]}"; do
        mark=" "; [[ " $def " == *" ${ids[$i]} "* ]] && { mark="${GREEN}*${RESET}"; defnames+="${defnames:+, }${labels[$i]}"; }
        printf '   %b %s%2d%s  %-18s %s%s%s\n' "$mark" "$BOLD" "$((i + 1))" "$RESET" "${labels[$i]}" "$DIM" "${notes[$i]}" "$RESET"
    done
    if [[ "$multi" == "1" ]]; then echo -e "   ${DIM}several are fine: 1,2  (the first one is the default)${RESET}"; fi
    read -rp "  Your choice [Enter = ${defnames}]: " ans || ans=""
    ans="${ans//,/ }"
    if [[ -z "${ans// /}" ]]; then picked=($def)
    else
        for tok in $ans; do
            if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#ids[@]} )); then picked+=("${ids[$((tok - 1))]}")
            else
                for i in "${!ids[@]}"; do [[ "${ids[$i]}" == "$tok" ]] && picked+=("$tok"); done
            fi
        done
        [[ ${#picked[@]} -gt 0 ]] || { echo -e "  ${YELLOW}Not understood: using ${defnames}${RESET}"; picked=($def); }
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
choice_bin()   { case "$1:$2" in
                  browser:zen) echo zen-browser ;; browser:chrome) echo google-chrome-stable ;; browser:vivaldi) echo vivaldi-stable ;;
                  files:pcmanfm) echo pcmanfm ;; editor:neovim) echo nvim ;; *) echo "$2" ;; esac; }
choice_valid() { local kind=$1 id=$2 fn; case "$kind" in browser) fn=browser_pkgs ;; files) fn=files_pkgs ;; editor) fn=editor_pkgs ;; esac
                 [[ "$id" == keep || "$id" == none || -n "$($fn "$id")" ]]; }
apps_id()      { [[ "$1:$2" == editor:neovim ]] && echo nvim || echo "$2"; }      # the id Settings > Default apps (apps.sh) uses

choose_apps() {
    local interactive=false have_b have_e s_b s_f s_e s_s s_c ask_b=false ask_f=false ask_e=false ask_s=false ask_c=false id kind
    local flag_b="$PICK_BROWSER" flag_f="$PICK_FILES" flag_e="$PICK_EDITOR"      # given on the command line
    [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && interactive=true
    s_b=$(saved_choice BROWSER); s_f=$(saved_choice FILES); s_e=$(saved_choice EDITOR); s_s=$(saved_choice SYSMODE); s_c=$(saved_choice SAFETY_CHECK)
    have_any firefox chromium google-chrome-stable brave vivaldi-stable zen-browser librewolf floorp qutebrowser && have_b=true || have_b=false
    have_any codium code code-oss cursor zeditor zed subl kate nvim && have_e=true || have_e=false
    # saved sysmode answer (only when nothing on the command line decided it)
    [[ "$SYSMODE_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_s" ]] && { [[ "$s_s" == yes ]] && SYSMODE=true || SYSMODE=false; SYSMODE_ASKED=true; }
    # saved safety-check answer (same rule: the command line wins, --choose asks again)
    [[ "$SAFETY_ASKED" != "true" && "$CHOOSE" != "true" && -n "$s_c" ]] && { [[ "$s_c" == yes ]] && SAFETY=true || SAFETY=false; SAFETY_ASKED=true; }
    if [[ "$interactive" == "true" ]]; then
        [[ -z "$PICK_BROWSER" && ( "$CHOOSE" == "true" || -z "$s_b" ) ]] && ask_b=true
        [[ -z "$PICK_FILES"   && ( "$CHOOSE" == "true" || -z "$s_f" ) && "$INSTALL_APPS" == "true" ]] && ask_f=true
        [[ -z "$PICK_EDITOR"  && ( "$CHOOSE" == "true" || -z "$s_e" ) ]] && ask_e=true
        [[ "$SYSMODE_ASKED" != "true" ]] && ask_s=true
        [[ "$SAFETY_ASKED" != "true" ]] && ask_c=true
        if [[ "$ask_b$ask_f$ask_e$ask_s$ask_c" == *true* ]]; then
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
    # ---- sysmode
    if [[ "$ask_s" == "true" ]]; then
        echo -e "\n  ${CYAN}${BOLD}sysmode${RESET}  ${DIM}hardening profiles + a honeypot / IDS lab: secure | relaxed | stealth | lockdown${RESET}"
        echo -e "   ${DIM}installs ~10 security tools (nmap, ufw, audit, docker, lynis ...) and a boot service; skip it if you only want the desktop${RESET}"
        if ask "  Install sysmode?"; then SYSMODE=true; else SYSMODE=false; fi
        SYSMODE_ASKED=true
    fi
    # ---- safety check (default NO: it is only installed when you say yes; otherwise its Settings entry is greyed out)
    if [[ "$ask_c" == "true" ]]; then
        echo -e "\n  ${CYAN}${BOLD}Safety check${RESET}  ${DIM}one command that updates the system, scans for malware and rootkits, checks the firewall, audits and can back up to a disk${RESET}"
        echo -e "   ${DIM}installs clamav, rkhunter, lynis, aide, ufw and rsync, and adds \"Safety check\" to Settings > Backup. Say no and that entry stays greyed out and disabled.${RESET}"
        if confirm "  Add the safety check?"; then SAFETY=true; else SAFETY=false; fi
        SAFETY_ASKED=true
    fi
    # ---- check the names (a typo in --browser must not silently install nothing)
    local lst
    for kind in browser files editor; do
        case "$kind" in browser) lst="$PICK_BROWSER" ;; files) lst="$PICK_FILES" ;; editor) lst="$PICK_EDITOR" ;; esac
        lst="${lst//,/ }"
        for id in $lst; do choice_valid "$kind" "$id" || die "Unknown $kind '$id' (see ./install.sh --help for the names)"; done
        case "$kind" in browser) PICK_BROWSER="$lst" ;; files) PICK_FILES="$lst" ;; editor) PICK_EDITOR="$lst" ;; esac
    done
    PICK_BROWSER="${PICK_BROWSER%% *}"                                  # one browser
    [[ "$PICK_BROWSER" == keep && "$have_b" != "true" ]] && PICK_BROWSER=firefox   # "keep" with nothing installed: never leave the desktop without one
    # what is new this run (command line or menu) becomes the system default; a saved choice does not override a later change in Settings
    # (only an explicit pick: a default or a saved one must never override what you chose later in Settings > Default apps)
    APPLY_PICKS=()
    [[ ( -n "$flag_b" || "$ask_b" == true ) && "$PICK_BROWSER" != keep ]] && APPLY_PICKS+=("browser=$PICK_BROWSER")
    id="${PICK_FILES%% *}";  [[ ( -n "$flag_f" || "$ask_f" == true ) && -n "$id" && "$id" != none ]] && APPLY_PICKS+=("files=$id")
    id="${PICK_EDITOR%% *}"; [[ ( -n "$flag_e" || "$ask_e" == true ) && -n "$id" && "$id" != none ]] && APPLY_PICKS+=("editor=$(apps_id editor "$id")")
    log_info "Your choices: browser=${PICK_BROWSER:-keep}  files=${PICK_FILES:-none}  editor=${PICK_EDITOR:-none}  sysmode=$([[ "$SYSMODE" == true ]] && echo yes || echo no)  safety-check=$([[ "$SAFETY" == true ]] && echo yes || echo no)"
}
if [[ "$PACKAGES" == "true" && "$REMOVE_LOGIN" != "true" ]]; then choose_apps
else PICK_BROWSER="${PICK_BROWSER:-keep}"; PICK_FILES="${PICK_FILES:-none}"; PICK_EDITOR="${PICK_EDITOR:-none}"; fi

# ---------------------------------------------------------------------------------------------- step 5
log_step "Step 5: Hyprland and the desktop"

if [[ "$PACKAGES" == "true" ]]; then
    install_pkgs --critical hyprland quickshell mesa vulkan-icd-loader
    CORE=(xdg-desktop-portal-hyprland xdg-desktop-portal-gtk polkit-kde-agent
          hypridle hyprlock hyprsunset hyprutils
          qt6-base qt6-declarative qt6-svg qt6-wayland qt6-5compat qt6-multimedia qt5-wayland qt6ct kvantum kservice
          imagemagick cava btop fish starship poppler fd ripgrep fzf grim slurp wl-clipboard cliphist fuzzel
          dmidecode util-linux lsof jq zenity gamemode python libnotify
          inter-font ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji adwaita-icon-theme)
    # (the browser, file manager and editor you chose are installed below)
    install_pkgs "${CORE[@]}"
    # AUR: the cursor theme Halcyon is configured for, the log-out menu, emoji picker, frozen screenshots
    install_pkgs sweet-cursors-git wlogout bemoji wayfreeze

    # ---- the apps YOU chose (choose_apps above): web browser, file manager(s), code editor(s)
    CH_PKGS=()
    for id in $PICK_BROWSER; do [[ "$id" == keep ]] || CH_PKGS+=($(browser_pkgs "$id")); done
    for id in $PICK_FILES;   do [[ "$id" == none ]] || CH_PKGS+=($(files_pkgs "$id")); done
    for id in $PICK_EDITOR;  do [[ "$id" == none ]] || CH_PKGS+=($(editor_pkgs "$id")); done
    if [[ ${#CH_PKGS[@]} -gt 0 ]]; then
        log_info "Your apps: browser ${PICK_BROWSER:-keep}, files ${PICK_FILES:-none}, editor ${PICK_EDITOR:-none}"
        install_pkgs "${CH_PKGS[@]}"
    fi
    # ---- terminal, music, chat: installed unless --no-apps
    if [[ "$INSTALL_APPS" == "true" ]]; then
        log_info "Apps: foot (terminal), Spotify, Discord (+ spicetify and Vesktop so they can wear the rice colours)"
        install_pkgs foot
        # Spotify: spotify-launcher is in the official repositories and downloads the official Spotify client the first time
        # you start it. Only when that package does not exist is the AUR package 'spotify' used.
        if pkg_missing spotify && pkg_missing spotify-launcher; then
            if pacman -Si spotify-launcher >/dev/null 2>&1; then install_pkgs spotify-launcher; else install_pkgs spotify; fi
        fi
        install_pkgs discord
        # themes: spicetify patches Spotify (AUR); stock Discord cannot be themed, Vesktop (AUR) is a themeable Discord client
        install_pkgs spicetify-cli vesktop
    else
        log_info "Apps skipped (--no-apps): foot, Spotify, Discord."
    fi
    try run_as_user_cmd "Creating the standard user folders" xdg-user-dirs-update
else
    log_info "Skipped (--no-packages)."
fi

if command -v Hyprland >/dev/null 2>&1; then
    HL_VER="$(Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    log_info "Hyprland ${HL_VER:-installed}"
    if [[ -n "$HL_VER" && "$(printf '%s\n0.55\n' "$HL_VER" | sort -V | head -n1)" != "0.55" ]]; then
        warn_later "Hyprland ${HL_VER} is older than 0.55: Halcyon's config is written in Lua, which needs 0.55 or newer (sudo pacman -Syu hyprland)."
    fi
else warn_later "Hyprland is not installed."; fi

# ---------------------------------------------------------------------------------------------- step 6
log_step "Step 6: Rust toolchain"

[[ -d "$TARGET_HOME/.cargo/bin" ]] && export PATH="$TARGET_HOME/.cargo/bin:$PATH"
rust_ok() { run_as_user cargo --version >/dev/null 2>&1 && run_as_user rustc --version >/dev/null 2>&1; }

if [[ "$DRY_RUN" == "true" ]]; then
    log_task "[DRY-RUN] would check for cargo / rustc and install one if missing"
elif rust_ok; then
    log_success "Rust: $(run_as_user rustc --version)"
else
    if command -v rustup >/dev/null 2>&1; then
        run_as_user_cmd "Setting up the stable Rust toolchain (rustup)" rustup default stable || warn_later "rustup could not set up a toolchain."
    elif [[ "$PACKAGES" == "true" ]]; then
        install_pkgs rust                           # the plain package: nothing is removed, nothing conflicts with rustup
    fi
    rust_ok && log_success "Rust: $(run_as_user rustc --version)" \
            || warn_later "No working Rust toolchain: the helpers (hx, power-manager, touchpad-gestures, recon-deceiver, log-analyst, attacker-dossier, setStaticMac) cannot be built (sudo pacman -S rust)."
fi

# ---------------------------------------------------------------------------------------------- step 7
log_step "Step 7: Copying Halcyon to ~/.config/Halcyon"

run_as_user_cmd "Creating the config, state and cache folders" mkdir -p \
    "$TARGET_HOME/.config" "$TARGET_HOME/.config/systemd/user" "$TARGET_HOME/.local/state/island" \
    "$TARGET_HOME/.cache/island" "$TARGET_HOME/Pictures/Wallpapers" "$TARGET_HOME/Pictures/Screenshots" "$TARGET_HOME/logs" \
    || die "Could not create folders in $TARGET_HOME"

KEEP_FILES=(hypr-user.lua scheme/current.lua gamemode.conf gpu.lua special.conf apps.custom gpu-mode autostart.conf)     # yours: never overwritten by the copy
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
[[ -f "$TARGET_RICE/scripts/user-setup.sh" ]] && USER_SETUP="$TARGET_RICE/scripts/user-setup.sh"

try run_as_user_cmd "Making the scripts executable" bash -c '
    cd "$1" || exit 0
    for f in install.sh update.sh scripts/*.sh scripts/halcyon-tune launch/*.sh quickshell/island/scripts/*.sh \
             quickshell/scripts/*.sh waybar/*.sh sysmode/sysmode sysmode/*.py sysmode/*.py.bak; do
        [ -f "$f" ] && chmod +x "$f"
    done
    exit 0' _ "$TARGET_RICE"

# ---------------------------------------------------------------------------------------------- step 8
log_step "Step 8: Building the Rust helpers"

BIN_DIR="$TARGET_RICE/bin"
BUILD_ROOT="$TARGET_HOME/.cache/halcyon-build"           # outside the rice: the copy stays clean and rebuilds are quick
run_as_user_cmd "Creating $BIN_DIR" mkdir -p "$BIN_DIR" "$BUILD_ROOT" \
    || die "Cannot create $BIN_DIR$([[ "$LINK_CONFIG" == "true" ]] && echo " (with --link the Halcyon folder itself must be writable by $TARGET_USER)")"
BUILD_FAILED=()
CRATES=(hx power-manager touchpad-gestures recon-deceiver log-analyst attacker-dossier setStaticMac)
[[ "$SAFETY" == "true" ]] && CRATES+=(safety-check)

if [[ "$DRY_RUN" != "true" ]]; then
    user_bus_ready && user_systemctl stop power-manager.service touchpad-gestures.service >/dev/null 2>&1 || true
    pkill -u "$TARGET_UID" -x touchpad-gestures 2>/dev/null || true
fi
if [[ "$DRY_RUN" != "true" ]] && ! rust_ok; then
    warn_later "No Rust toolchain: skipped building the helpers. Install it (sudo pacman -S rust), then run install.sh again."
    BUILD_FAILED=("${CRATES[@]}")
else
    for crate in "${CRATES[@]}"; do
        MANIFEST="$TARGET_RICE/src/$crate/Cargo.toml"; [[ -f "$MANIFEST" ]] || MANIFEST="$RICE_SOURCE/src/$crate/Cargo.toml"
        log_info "Building ${BOLD}${crate}${RESET} (the first time takes a few minutes)..."
        if run_as_user_cmd "cargo build --release: $crate" env "CARGO_TARGET_DIR=$BUILD_ROOT/$crate" cargo build --release --manifest-path "$MANIFEST" \
           && { [[ "$DRY_RUN" == "true" ]] || [[ -f "$BUILD_ROOT/$crate/release/$crate" ]]; } \
           && run_as_user_cmd "Installing $crate" bash -c 'install -m755 "$1" "$2.new" && mv -f "$2.new" "$2"' _ "$BUILD_ROOT/$crate/release/$crate" "$BIN_DIR/$crate"; then
            [[ "$DRY_RUN" == "true" ]] || log_success "Installed ${BIN_DIR}/${crate}"
            # Keep sysmode symlinks in sync
            case "$crate" in
                recon-deceiver|log-analyst|attacker-dossier|setStaticMac)
                    [[ -d "$TARGET_RICE/sysmode" ]] && ln -sf "$BIN_DIR/$crate" "$TARGET_RICE/sysmode/$crate" 2>/dev/null || true
                    ;;
            esac
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

WANT_LOCK_LOGIN=false
if have_dm; then
    log_success "Login manager found ($(dm_name)): pick the \"Halcyon\" session on its login screen. Halcyon's own lock screen is used when you lock."
    [[ "$LOCK_LOGIN" == "1" ]] && WANT_LOCK_LOGIN=true
else
    log_info "No login manager (sddm, gdm, ...): at boot you get a text console; start Halcyon with: start-halcyon"
    if [[ "$LOCK_LOGIN" == "0" ]]; then log_info "Lock-screen login skipped (--no-lock-login)."
    elif [[ "$LOCK_LOGIN" == "1" ]]; then WANT_LOCK_LOGIN=true
    else
        # Opt-in only. It used to be "yes" by default (and --yes always said yes), so a machine whose Halcyon did not start
        # right booted straight into a broken desktop with no text console in sight. Now it is only set up when you ask for it.
        echo "   Optional: Halcyon can use its own lock screen as the login screen: tty1 logs you in by itself, Halcyon starts ALREADY"
        echo "   LOCKED, and you type your password on the lock screen. Other consoles (Ctrl+Alt+F2) stay normal text logins."
        echo "   Undo any time: ./install.sh --remove-lock-login"
        if [[ "$AUTO_CONFIRM" != "true" && -t 0 ]] && confirm "   Set that up? (answer n if you are not sure: start-halcyon works from any text console)"; then WANT_LOCK_LOGIN=true
        else log_info "Not set up. Add --lock-login (or answer y when asked) to enable it later."; fi
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
# Remove with ./install.sh --remove-lock-login
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin @USER@ - $TERM
GETTY
}
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

# ---------------------------------------------------------------------------------------------- step 10
log_step "Step 10: Services"

UNITS="$TARGET_HOME/.config/systemd/user"
try run_as_user_cmd "Installing the user services (gestures start with the desktop, Auto power from the island)" \
    install -m644 "$TARGET_RICE/systemd/power-manager.service" "$TARGET_RICE/systemd/touchpad-gestures.service" "$UNITS/"
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
else warn_later "dmidecode is missing: the RAM card shows the size only (sudo pacman -S dmidecode, then run this again)."; fi

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
        # the Cowrie honeypot runs in Docker: the daemon has to be up for `sysmode stealth`
        if command -v docker >/dev/null 2>&1 && ! unit_enabled docker.service; then try run_cmd "Enabling docker (for the Cowrie honeypot)" as_root systemctl enable --now docker.service; fi
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
    if ! is_laptop; then log_info "Keyboard light: this is not a laptop, so there is no keyboard-light driver to load (an RGB keyboard: sudo pacman -S openrgb)."; return 0; fi
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
        *razer*)                       note="Razer keyboards are not a standard keyboard light: install openrazer (pacman -S openrazer-daemon) and polychromatic" ;;
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
    id="$(tr 'A-Z' 'a-z' < /sys/class/dmi/id/sys_vendor 2>/dev/null)"
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
if [[ "$DRY_RUN" != "true" ]] && ! kbd_led_present && is_laptop; then
    run_as_user bash "$TARGET_RICE/scripts/kbd-backlight.sh" doctor 2>&1 | sed 's/^/   /' | head -n 8 || true
fi

# ---- safety check (optional): the program Settings > Backup > "Safety check" starts
# Like sysmode it runs as root (system update, scans, firewall, backup), so the installed copy is root-owned: nothing running
# as you can change what you later start with sudo. Settings greys the entry out when /usr/local/bin/safety-check is missing.
if [[ "$SAFETY" == "true" ]]; then
    if [[ "$PACKAGES" == "true" ]]; then
        log_info "The safety check uses: clamav rkhunter lynis aide ufw rsync libnotify"
        install_pkgs clamav rkhunter lynis aide ufw rsync libnotify
    fi
    if [[ "$DRY_RUN" == "true" ]] || [[ -f "$BIN_DIR/safety-check" ]]; then
        try run_cmd "Installing /usr/local/bin/safety-check (root-owned)" as_root install -Dm755 -o root -g root "$BIN_DIR/safety-check" /usr/local/bin/safety-check
        log_info "Run it from Settings > Backup > Safety check, or in a terminal:  sudo safety-check   (logs: ~/logs/safety_check/)"
    else
        warn_later "safety-check was not built, so it is not installed (its Settings entry stays greyed out). Retry: ./install.sh --safety-check"
    fi
elif [[ "$SAFETY_ASKED" == "true" && "$PACKAGES" == "true" && "$DRY_RUN" != "true" && -e /usr/local/bin/safety-check ]]; then
    try run_cmd "Removing /usr/local/bin/safety-check (you chose no safety check)" as_root rm -f /usr/local/bin/safety-check
else
    log_info "Safety check skipped: its entry in Settings > Backup stays greyed out (add it later: ./install.sh --safety-check)."
fi

# ---------------------------------------------------------------------------------------------- step 12
log_step "Step 12: Wallpaper and colours"
user_setup wallpaper  || warn_later "Wallpaper / colours: something did not work (is ImageMagick installed?)"
user_setup terminals  || warn_later "Terminal colour files could not be written."
user_setup app-themes || warn_later "App themes (Starship, fish, btop, yazi, Spotify, Discord, Thunar) could not all be set up: run ~/.config/Halcyon/scripts/user-setup.sh app-themes"
if [[ "$PACKAGES" == "true" ]]; then
    if [[ "$INSTALL_APPS" == "true" || ${#APPLY_PICKS[@]} -gt 0 ]]; then user_setup default-apps ${APPLY_PICKS[@]+"${APPLY_PICKS[@]}"} || true; fi
    # remember what you chose, so update.sh (and the next install.sh) install the same things without asking
    user_setup save-choices "BROWSER=$PICK_BROWSER" "FILES=$PICK_FILES" "EDITOR=$PICK_EDITOR" "SYSMODE=$([[ "$SYSMODE" == true ]] && echo yes || echo no)" "SAFETY_CHECK=$([[ "$SAFETY" == true ]] && echo yes || echo no)" || true
fi
[[ "$PACKAGES" == "true" && "$SKIP_DRIVERS" != "true" ]] && { user_setup gpu-env "$GPU_ENV_MODE" || true; }

if [[ "$DRY_RUN" != "true" && $EUID -eq 0 ]]; then      # run as root: make sure nothing of the user's ended up owned by root
    chown -R "$TARGET_UID:$TARGET_GID" "$TARGET_HOME/.local/state/island" "$TARGET_HOME/.cache/island" "$TARGET_HOME/.cache/halcyon-build" \
        "$TARGET_HOME/.config/systemd" "$TARGET_HOME/Pictures/Wallpapers" "$TARGET_HOME/Pictures/Screenshots" 2>/dev/null || true
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
check_cmd touchpad-gestures "$BIN_DIR/touchpad-gestures" critical
check_cmd recon-deceiver "$BIN_DIR/recon-deceiver" critical
check_cmd log-analyst "$BIN_DIR/log-analyst" critical
check_cmd attacker-dossier "$BIN_DIR/attacker-dossier" critical
check_cmd setStaticMac "$BIN_DIR/setStaticMac" critical
if [[ "$PACKAGES" == "true" ]]; then
    for id in $PICK_BROWSER; do [[ "$id" == keep ]] || check_cmd "$id" "$(choice_bin browser "$id")"; done
    for id in $PICK_FILES;   do [[ "$id" == none ]] || check_cmd "$id" "$(choice_bin files "$id")"; done
    for id in $PICK_EDITOR;  do [[ "$id" == none ]] || check_cmd "$id" "$(choice_bin editor "$id")"; done
fi
if [[ "$INSTALL_APPS" == "true" && "$PACKAGES" == "true" ]]; then
    command -v spotify >/dev/null 2>&1 && check_cmd spotify spotify || check_cmd spotify-launcher spotify-launcher
    check_cmd discord discord
fi
for c in foot fuzzel brightnessctl playerctl wpctl nmcli bluetoothctl powerprofilesctl cava grim slurp wl-copy cliphist \
         hypridle hyprlock hyprsunset pkexec lspci nm-applet blueman-applet kbuildsycoca6 wayfreeze bemoji wlogout iw; do
    check_cmd "$c" "$c"
done
check_cmd polkit-kde-agent /usr/lib/polkit-kde-authentication-agent-1
if [[ -x /usr/lib/xdg-desktop-portal-hyprland || -x /usr/lib/hyprland/xdg-desktop-portal-hyprland ]]; then echo -e "  ${GREEN}✔${RESET} xdg-desktop-portal-hyprland"
else echo -e "  ${YELLOW}⚠${RESET} xdg-desktop-portal-hyprland (missing)"; fi
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
[[ "$WANT_LOCK_LOGIN" == "true" ]] && echo -e "  ${CYAN}•${RESET} Lock-screen login is on: just reboot, Halcyon starts locked. (undo: ./install.sh --remove-lock-login; skip it once: touch ~/.cache/island/no-autostart)"
[[ "$NEED_RELOGIN" == "true" ]] && echo -e "  ${CYAN}•${RESET} ${YELLOW}Log out and in again first${RESET}: you were added to the input / video groups (touchpad gestures, brightness)."
echo -e "  ${CYAN}•${RESET} Already inside Halcyon? Restart the island:  pkill quickshell; $TARGET_RICE/scripts/start-shell.sh island &"
echo -e "  ${CYAN}•${RESET} Something not working (no bar, no keybinds)?  ${BOLD}$TARGET_RICE/scripts/halcyon-doctor.sh${RESET}   (island log: ~/.cache/island/quickshell-island.log)"
echo
echo -e "${BOLD}First keys${RESET}"
echo -e "  ${MAGENTA}Super (tap)${RESET}       Launcher          ${MAGENTA}Super + T${RESET}         Terminal"
echo -e "  ${MAGENTA}Super + Q${RESET}         Close window      ${MAGENTA}Super + Tab${RESET}       Workspace tree"
echo -e "  ${MAGENTA}Super + /${RESET}         All shortcuts     ${MAGENTA}Super + L${RESET}         Lock screen"
echo -e "  ${MAGENTA}Super + Ctrl + ←/→${RESET}  Previous / next workspace (a new one after the last)"
[[ "$SAFETY" == "true" ]] && echo -e "  ${MAGENTA}Settings > Backup${RESET}   Safety check (update, malware / rootkit scan, firewall, backup)"
echo
echo -e "${DIM}Update later: ~/.config/Halcyon/update.sh     ·     Settings: from the island     ·     Log of this run: ${LOG_FILE}${RESET}"
echo
[[ ${#MISSING_CRITICAL[@]} -gt 0 ]] && exit 1
exit 0
