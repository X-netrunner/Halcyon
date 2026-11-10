#!/usr/bin/env bash
# sync-and-push.sh - find every Halcyon checkout on this machine, pick one, sync it with
# its remote and push your changes. Also supports ai-firewall, ai-antivirus and LUNA-AI.
#
# The friendly entry point is the fish function `push`:
#
#     push halcyon
#     push firewall
#     push antivirus
#     push luna
#     push all
#
# which runs this script. It scans the usual places, lists every git checkout it
# finds (1, 2, 3 ...), asks which one you mean, then commits your work, rebases it onto the
# remote and pushes. For unversioned folders, it initializes git on `main`, links to the
# proper GitHub remote, fetches and aligns with origin/main, and commits your work on top.
#
#     sync-and-push.sh                 interactive: list the checkouts, ask which one
#     sync-and-push.sh --list          only list them and exit
#     sync-and-push.sh --repo DIR      skip the menu, use DIR
#     sync-and-push.sh --slug SLUG     remote repository slug (e.g. X-netrunner/LUNA-AI)
#     sync-and-push.sh --remote URL    remote repository URL
#     sync-and-push.sh --all           sync & push every checkout it finds
#     sync-and-push.sh --dry-run       show what would happen, change nothing
#     sync-and-push.sh --yes           do not ask for confirmation
#     sync-and-push.sh --force | -f    push with --force-with-lease
#     sync-and-push.sh -m "message"    use this commit message (skips the prompt)
#     sync-and-push.sh --no-pull       commit and push, but never pull first
#     sync-and-push.sh --ask           on a conflict, ask k/a instead of "mine wins"
#     sync-and-push.sh -h | --help     this text
#
# "sync" = stage everything that is not ignored and commit it FIRST, then `git pull --rebase`
# so your commit lands on top of the remote. Where the same file changed on both sides YOUR
# version wins automatically (what you push is final) - pass --ask to be asked k/a instead.
# "push" = push the branch to main (setting the upstream the first time).

set -uo pipefail

# ---------------------------------------------------------------------------
# look & feel
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; H=$'\033[1;36m'
    OK=$'\033[32m'; W=$'\033[33m'; E=$'\033[31m'; C=$'\033[1;36m'; R=$'\033[0m'
else
    B=; DIM=; H=; OK=; W=; E=; C=; R=
fi
say()  { printf '%s== %s%s\n' "$H" "$*" "$R"; }
step() { printf '   %s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '   %s✓%s %s\n' "$OK" "$R" "$*"; }
warn() { printf '   %s!%s %s\n' "$W" "$R" "$*"; }
die()  { printf '   %s✗%s %s\n' "$E" "$R" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# options
# ---------------------------------------------------------------------------
LIST=0; DRY=0; YES=0; ALL=0; NOPULL=0; ASK=0; FORCE=0; PICK="" ; MSG="" ; REPO="" ; SLUG="" ; REMOTE_URL=""
usage() { sed -n '2,/^# "sync" =/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        LIST=1 ;;
        --dry-run|-n)  DRY=1 ;;
        --yes|-y)      YES=1 ;;
        --all|-a)      ALL=1 ;;
        --no-pull)     NOPULL=1 ;;
        --ask)         ASK=1 ;;              # ask k/a on a conflict instead of "mine wins"
        --force|-f)    FORCE=1 ;;
        --slug)        [ $# -ge 2 ] || die "--slug needs a slug"; SLUG="$2"; shift ;;
        --slug=*)      SLUG="${1#*=}" ;;
        --remote)      [ $# -ge 2 ] || die "--remote needs a URL"; REMOTE_URL="$2"; shift ;;
        --remote=*)    REMOTE_URL="${1#*=}" ;;
        --repo)        [ $# -ge 2 ] || die "--repo needs a directory"; REPO="$2"; shift ;;
        --repo=*)      REPO="${1#*=}" ;;
        -m|--message)  [ $# -ge 2 ] || die "$1 needs a message"; MSG="$2"; shift ;;
        --message=*)   MSG="${1#*=}" ;;
        -h|--help)     usage; exit 0 ;;
        [0-9]*)        PICK="$1" ;;          # `push halcyon 3` also works
        *)             die "unknown option: $1  (try --help)" ;;
    esac
    shift
done

command -v git >/dev/null 2>&1 || die "git is required."

# ---------------------------------------------------------------------------
# helper: detect appropriate remote URL for a project
# ---------------------------------------------------------------------------
detect_default_remote() {
    local d="$1"
    if [ -n "${REMOTE_URL:-}" ]; then
        printf '%s' "$REMOTE_URL"
        return
    fi
    if [ -n "${SLUG:-}" ]; then
        case "$SLUG" in
            http*|git@*) printf '%s' "$SLUG" ;;
            *) printf 'https://github.com/%s.git' "$SLUG" ;;
        esac
        return
    fi

    local base; base="$(basename "$d" | tr '[:upper:]' '[:lower:]')"
    # 1. Check LUNA-AI
    if [[ "$base" == *luna* ]] || [ -f "$d/luna.toml.example" ] || [ -d "$d/whapp" ] || grep -q 'name = "luna' "$d/Cargo.toml" 2>/dev/null; then
        printf 'https://github.com/X-netrunner/LUNA-AI.git'
        return
    fi
    # 2. Check ai-firewall
    if [[ "$base" == *firewall* ]] || [ -d "$d/ai-firewall-ebpf" ] || grep -q 'ai-firewall' "$d/Cargo.toml" 2>/dev/null; then
        printf 'https://github.com/X-netrunner/ai-firewall.git'
        return
    fi
    # 3. Check ai-antivirus
    if [[ "$base" == *antivirus* ]] || ([ -d "$d/xtask" ] && [ -d "$d/rules" ]) || grep -q 'ai-antivirus' "$d/Cargo.toml" 2>/dev/null; then
        printf 'https://github.com/X-netrunner/ai-antivirus.git'
        return
    fi
    # 4. Check Halcyon
    if [[ "$base" == *halcyon* ]] || [ -f "$d/install.sh" ] || [ -f "$d/hyprland.lua" ]; then
        printf 'https://github.com/X-netrunner/Halcyon.git'
        return
    fi

    # Fallback to Halcyon
    printf 'https://github.com/X-netrunner/Halcyon.git'
}

# ---------------------------------------------------------------------------
# find the Halcyon checkouts
# ---------------------------------------------------------------------------
# A checkout counts when it is a git repo whose origin points at a *Halcyon* repo, or when
# it looks like the rice itself (install.sh + sysmode/ + a folder named Halcyon*). Trash and
# backup copies are skipped - pushing those is almost never what you want.
CANDIDATES=()

looks_like_halcyon() {
    local d="$1" url base
    case "$d" in
        */.local/share/Trash/*|*/Trash/*|*/Trash-*/*|*-backups/*|*/.stversions/*) return 1 ;;
    esac
    base="$(basename "$d")"
    if [ -d "$d/.git" ]; then
        url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
        case "$url" in *[Hh]alcyon*) return 0 ;; esac
        case "$base" in [Hh]alcyon*) ;; *) return 1 ;; esac
        [ -f "$d/install.sh" ] && [ -d "$d/sysmode" ]
    else
        # Unversioned Halcyon folder (e.g. ~/Downloads/Halcyon without .git)
        case "$base" in [Hh]alcyon*) ;; *) return 1 ;; esac
        [ -f "$d/install.sh" ] && ([ -d "$d/sysmode" ] || [ -f "$d/hyprland.lua" ])
    fi
}

scan_root() {
    local root="$1"
    [ -d "$root" ] || return 0
    # -prune the heavy/noisy trees; only .git dirs are printed
    find "$root" -maxdepth 6 \
        \( -name node_modules -o -name target -o -name .gradle -o -name .venv \
           -o -name venv -o -name dist -o -name build \) -prune -o \
        -type d -name .git -print 2>/dev/null
    # Also discover unversioned Halcyon folders in ~/Downloads, ~/Projects, and ~
    if [ "$root" = "$HOME" ]; then
        for parent in "$HOME/Downloads" "$HOME/Projects" "$HOME"; do
            [ -d "$parent" ] || continue
            find "$parent" -maxdepth 2 -type d -name "[Hh]alcyon*" 2>/dev/null | while read -r d; do
                [ ! -d "$d/.git" ] && printf '%s/.git\n' "$d"
            done
        done
    fi
}

discover() {
    local g d seen=""
    while IFS= read -r g; do
        d="${g%/.git}"
        # de-dupe (a repo can be reached through a symlinked root)
        case "$seen" in *"|$d|"*) continue ;; esac
        seen="$seen|$d|"
        looks_like_halcyon "$d" && printf '%s\n' "$d"
    done < <(scan_root "$HOME"; scan_root /opt; scan_root /srv; scan_root /workspace; scan_root /Workspace)
}

# short "$HOME/Projects/Halcyon" -> "Projects/Halcyon"
short() { printf '%s' "${1#"$HOME"/}"; }
is_cache() { case "$1" in */.cache/*) return 0 ;; *) return 1 ;; esac; }

git_remote_name() {
    local d="$1" r
    r="$(git -C "$d" config --get branch."$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null)".remote 2>/dev/null || true)"
    if [ -n "$r" ] && [ "$r" != "." ]; then printf '%s' "$r"; return; fi
    if git -C "$d" remote get-url origin >/dev/null 2>&1; then printf 'origin'; return; fi
    git -C "$d" remote | head -n1
}

# counts as  "<behind> <ahead>"  relative to the branch's upstream; with no upstream set (a fresh clone, a new branch) against
# <remote>/<branch> when the remote has it, else every commit counts as ahead. (It used to say "0 0" there, so the push step
# reported "already up to date" and never pushed.)
ahead_behind() {
    local d="$1" up br r
    up="$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [ -z "$up" ]; then
        br="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || true)"
        r="$(git_remote_name "$d")"
        if [ -n "$br" ] && [ -n "$r" ] && git -C "$d" rev-parse --verify -q "refs/remotes/$r/$br" >/dev/null; then
            up="$r/$br"
        else
            printf '0 %s' "$(git -C "$d" rev-list --count HEAD 2>/dev/null || echo 0)"; return
        fi
    fi
    git -C "$d" rev-list --left-right --count "$up...HEAD" 2>/dev/null || printf '0 0'
}

# one menu line per checkout
describe() {
    local d="$1" br dirty ab behind ahead tag color
    if [ ! -d "$d/.git" ]; then
        color="$W"
        printf '  [%s%s%s] %-34s %s%-7s%s %s%2s files%s    %s(unversioned - will init & sync)%s\n' \
            "$C" "$2" "$R" "$(short "$d")" "$color" "no-git" "$R" \
            "$color" "$(find "$d" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')" "$R" "$DIM" "$R"
        return
    fi
    br="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || printf 'detached@%s' "$(git -C "$d" rev-parse --short HEAD 2>/dev/null)")"
    dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    read -r behind ahead < <(ahead_behind "$d")
    tag=""; is_cache "$d" && tag=" ${DIM}(cache)${R}"
    color="$OK"; [ "$dirty" -gt 0 ] && color="$W"
    printf '  [%s%s%s] %-34s %s%-7s%s %s%2s changed%s  %s↑%s ↓%s%s%s\n' \
        "$C" "$2" "$R" "$(short "$d")" "$color" "$br" "$R" \
        "$color" "$dirty" "$R" "$OK" "$ahead" "$behind" "$R" "$tag"
}

list_repos() {
    local i=1 d
    for d in "${CANDIDATES[@]}"; do describe "$d" "$i"; i=$((i + 1)); done
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------
# --repo (push firewall / push luna) names the checkout itself: no Halcyon menu then
if [ -z "$REPO" ] || [ "$LIST" = 1 ]; then
    printf '%sHalcyon checkouts found:%s\n\n' "$B" "$R"
    mapfile -t CANDIDATES < <(discover)
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        die "no Halcyon git checkout found (looked in ~, /opt, /srv, /workspace)."
    fi
    # stable order: real working trees first, caches last, then by path
    mapfile -t CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | awk '{print (index($0,"/.cache/")?"1":"0") "\t" $0}' | sort -k1,1 -k2,2 | cut -f2-)
    list_repos
    echo
fi

if [ "$LIST" = 1 ]; then exit 0; fi

# --repo skips the menu; a leading number (push halcyon 3) selects directly
if [ -n "$REPO" ]; then
    [ -d "$REPO" ] || die "$REPO is not a directory."
    TARGETS=("$REPO")
elif [ "$ALL" = 1 ]; then
    TARGETS=("${CANDIDATES[@]}")
else
    if [ -z "$PICK" ]; then
        [ -t 0 ] || die "not a terminal: use --repo DIR, --all or --list."
        printf 'Select a Halcyon to sync & push [1-%d, q to quit]: ' "${#CANDIDATES[@]}"
        read -r PICK
    fi
    case "$PICK" in
        q|Q|quit) echo "nothing done."; exit 0 ;;
        ''|*[!0-9]*) die "please type a number between 1 and ${#CANDIDATES[@]}." ;;
    esac
    if [ "$PICK" -lt 1 ] || [ "$PICK" -gt "${#CANDIDATES[@]}" ]; then
        die "no checkout number $PICK (choose 1-${#CANDIDATES[@]})."
    fi
    TARGETS=("${CANDIDATES[$((PICK - 1))]}")
fi

# ---------------------------------------------------------------------------
# sync + push
# ---------------------------------------------------------------------------
confirm() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || return 0
    local a; printf '   %s [Y/n] ' "$1"; read -r a
    case "$a" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

sync_push() {
    local d="$1" remote branch behind ahead dirty msg label
    label="${PICK:-$(short "$d")}"
    say "pushing $label"
    step "$d"
    echo

    if [ ! -d "$d/.git" ]; then
        local default_remote; default_remote="$(detect_default_remote "$d")"
        step "$label is not a git repository yet - initializing git and linking to remote ($default_remote)..."
        git -C "$d" init -b main --quiet 2>/dev/null || { git -C "$d" init --quiet && git -C "$d" branch -M main --quiet 2>/dev/null || true; }
        git -C "$d" remote add origin "$default_remote" 2>/dev/null || git -C "$d" remote set-url origin "$default_remote"
        step "fetching origin/main from $default_remote..."
        git -C "$d" fetch --quiet origin main 2>/dev/null || true
        git -C "$d" reset origin/main --quiet 2>/dev/null || true
        git -C "$d" branch -M main 2>/dev/null || true
        git -C "$d" branch -u origin/main main 2>/dev/null || true
        ok "git initialized tracking origin/main"
    fi

    # Force to main branch
    branch="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ -z "$branch" ]; then
        step "detached HEAD detected in $d - forcing to main branch..."
        git -C "$d" checkout -B main 2>/dev/null || git -C "$d" switch -C main 2>/dev/null || true
        branch="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || echo "main")"
    fi
    if [ "$branch" != "main" ]; then
        step "current branch is '$branch' - forcing to main branch..."
        git -C "$d" branch -M main 2>/dev/null || true
        branch="main"
    fi

    for f in rebase-merge rebase-apply MERGE_HEAD; do
        if [ -e "$(git -C "$d" rev-parse --git-path "$f" 2>/dev/null)" ]; then
            warn "a git $f is unfinished in $d - finish or abort it first (git -C $d status). skipped."
            return 1
        fi
    done

    remote="$(git_remote_name "$d")"
    if [ -z "$remote" ]; then
        local def_rem; def_rem="$(detect_default_remote "$d")"
        git -C "$d" remote add origin "$def_rem" 2>/dev/null || true
        remote="origin"
    fi
    ref="$remote/$branch"
    step "remote: $remote  ($(git -C "$d" remote get-url "$remote" 2>/dev/null))"

    # Ensure tracking origin/main if upstream is not set or points to master
    local cur_up; cur_up="$(git -C "$d" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
    if [ -z "$cur_up" ] || [ "$cur_up" = "$remote/master" ]; then
        git -C "$d" branch -u "$remote/main" main 2>/dev/null || true
    fi

    # ---- what would break the island at login never leaves this machine: shell / Python syntax, the QML lint, unknown QML types and
    #      double bindings (scripts/halcyon-selftest.sh --quick, a few seconds). HALCYON_PUSH_SKIP_CHECKS=1 skips it.
    local st="$d/scripts/halcyon-selftest.sh"
    if [ -f "$st" ] && [ "${HALCYON_PUSH_SKIP_CHECKS:-0}" != 1 ]; then
        step "quick self-test (what breaks a login)"
        if bash "$st" "$d" --quick | sed 's/^/   /'; then
            :
        elif [ "$YES" = 1 ] || [ ! -t 0 ]; then
            warn "the self-test failed (above): nothing was committed or pushed. HALCYON_PUSH_SKIP_CHECKS=1 pushes anyway."
            return 1
        else
            local go; printf '   %sThe self-test failed (above). Push anyway? [y/N] %s' "$B" "$R"; read -r go
            case "$go" in y|Y|yes) warn "pushing despite the failed self-test" ;; *) warn "nothing was committed or pushed."; return 1 ;; esac
        fi
    fi

    # ---- stage and commit your work FIRST: a pull can then never clobber it or leave
    #      half-applied changes, and any clash with the remote is a normal rebase conflict.
    local f choice cf
    dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$dirty" = 0 ]; then
        ok "no local changes to commit"
    else
        step "$dirty path(s) to commit:"
        if [ "$DRY" = 1 ]; then
            git -C "$d" status --short | sed 's/^/      /'
        else
            git -C "$d" add -A
            git -C "$d" diff --cached --stat | sed 's/^/      /'
            if [ -z "$MSG" ]; then
                local def; def="sync: $(date '+%Y-%m-%d %H:%M') from $(uname -n)"
                if [ "$YES" = 1 ] || [ ! -t 0 ]; then
                    msg="$def"
                else
                    printf '   %sCommit message [%s]: %s' "$B" "$def" "$R"
                    read -r msg
                    [ -n "$msg" ] || msg="$def"
                fi
            else
                msg="$MSG"
            fi
            if ! git -C "$d" commit --quiet -m "$msg"; then
                warn "git commit failed (GPG signing? pre-commit hook?) - the changes stay staged."
                return 1
            fi
            ok "committed: $msg"
            git -C "$d" log --oneline -1 | sed 's/^/      /'
        fi
    fi

    # ---- sync: fetch, then rebase your commit(s) onto the remote
    if [ "$NOPULL" = 1 ]; then
        ok "skipping pull (--no-pull)"
    else
        if timeout 30 git -C "$d" fetch --quiet "$remote" 2>/dev/null; then
            read -r behind ahead < <(ahead_behind "$d")
            if [ "$behind" -gt 0 ] 2>/dev/null; then
                if [ "$DRY" = 1 ]; then
                    warn "dry-run: would rebase onto $ref ($behind commit(s) behind)"
                else
                    step "remote is $behind commit(s) ahead - rebasing onto $ref..."
                    local pullrc=0
                    git -C "$d" pull --rebase -Xtheirs --quiet "$remote" "$branch" 2>&1 | sed 's/^/      /' || pullrc=1
                    if [ "$pullrc" = 0 ]; then
                        ok "rebased onto $ref"
                    else
                        # auto-settle any remaining conflict favoring local work
                        warn "settling rebase conflicts (keeping your version)..."
                        local guard=0
                        while [ -d "$(git -C "$d" rev-parse --git-path rebase-merge 2>/dev/null)" ] || \
                              [ -d "$(git -C "$d" rev-parse --git-path rebase-apply 2>/dev/null)" ]; do
                            mapfile -t cf < <(git -C "$d" diff --name-only --diff-filter=U 2>/dev/null)
                            if [ "${#cf[@]}" -gt 0 ]; then
                                for f in "${cf[@]}"; do
                                    git -C "$d" checkout --theirs -- "$f" 2>/dev/null || git -C "$d" rm -q -f -- "$f" 2>/dev/null || true
                                done
                                git -C "$d" add -A 2>/dev/null
                            fi
                            GIT_EDITOR=true git -C "$d" rebase --continue >/dev/null 2>&1 || \
                                git -C "$d" rebase --skip >/dev/null 2>&1 || true
                            guard=$((guard + 1)); [ "$guard" -gt 100 ] && break
                        done
                        if [ -n "$(git -C "$d" diff --name-only --diff-filter=U 2>/dev/null)" ] || \
                           [ -d "$(git -C "$d" rev-parse --git-path rebase-merge 2>/dev/null)" ] || \
                           [ -d "$(git -C "$d" rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
                            git -C "$d" rebase --abort >/dev/null 2>&1
                            warn "could not settle every conflict automatically - rebase aborted."
                            warn "your work is safe in the commit. finish it yourself:  cd $d && git pull --rebase"
                            return 1
                        fi
                        ok "rebased onto $ref (kept your version of the conflicting files)"
                    fi
                fi
            else
                ok "already current with $ref"
            fi
        else
            warn "could not reach $remote (offline?) - pushing anyway"
        fi
    fi

    if [ "$DRY" = 1 ]; then
        warn "dry-run: stopping before push"
        return 0
    fi

    # ---- push
    read -r behind ahead < <(ahead_behind "$d")
    if [ "$ahead" = 0 ] 2>/dev/null && [ "$FORCE" = 0 ]; then
        ok "nothing to push - already up to date with $remote/$branch"
        return 0
    fi
    if ! confirm "push $ahead commit(s) to $remote/$branch?"; then
        warn "not pushed. your commit is local; run this again when you want to push."
        return 0
    fi
    step "pushing $ahead commit(s) to $remote/$branch..."
    local push_opts=()
    [ "$FORCE" = 1 ] && push_opts+=(--force-with-lease)

    if git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        if ! git -C "$d" push "${push_opts[@]}" 2>&1 | sed 's/^/      /'; then
            if [ "$FORCE" = 1 ]; then
                step "retrying with force push..."
                git -C "$d" push --force -u "$remote" "$branch" 2>&1 | sed 's/^/      /' || return 1
            else
                if ! git -C "$d" push "${push_opts[@]}" -u "$remote" "$branch" 2>&1 | sed 's/^/      /'; then return 1; fi
            fi
        fi
    else
        if ! git -C "$d" push "${push_opts[@]}" -u "$remote" "$branch" 2>&1 | sed 's/^/      /'; then
            if [ "$FORCE" = 1 ]; then
                step "retrying with force push..."
                git -C "$d" push --force -u "$remote" "$branch" 2>&1 | sed 's/^/      /' || return 1
            else
                return 1
            fi
        fi
    fi
    ok "pushed"
}

rc=0
for d in "${TARGETS[@]}"; do
    sync_push "$d" || rc=1
    [ "$ALL" = 1 ] && echo
done
exit "$rc"
