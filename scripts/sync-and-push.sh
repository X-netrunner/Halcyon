#!/usr/bin/env bash
# sync-and-push.sh - find every Halcyon checkout on this machine, pick one, sync it with
# its remote and push your changes.
#
# The friendly entry point is the fish function `push`:
#
#     push halcyon
#
# which runs this script. It scans the usual places, lists every Halcyon git checkout it
# finds (1, 2, 3 ...), asks which one you mean, then commits your work, rebases it onto the
# remote and pushes.
#
#     sync-and-push.sh                 interactive: list the checkouts, ask which one
#     sync-and-push.sh --list          only list them and exit
#     sync-and-push.sh --repo DIR      skip the menu, use DIR
#     sync-and-push.sh --all           sync & push every checkout it finds
#     sync-and-push.sh --dry-run       show what would happen, change nothing
#     sync-and-push.sh --yes           do not ask for confirmation
#     sync-and-push.sh -m "message"    use this commit message (skips the prompt)
#     sync-and-push.sh --no-pull       commit and push, but never pull first
#     sync-and-push.sh --ask           on a conflict, ask k/a instead of "mine wins"
#     sync-and-push.sh -h | --help     this text
#
# "sync" = stage everything that is not ignored and commit it FIRST, then `git pull --rebase`
# so your commit lands on top of the remote. Where the same file changed on both sides YOUR
# version wins automatically (what you push is final) - pass --ask to be asked k/a instead.
# "push" = push the branch (setting the upstream the first time).

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
LIST=0; DRY=0; YES=0; ALL=0; NOPULL=0; ASK=0; PICK="" ; MSG="" ; REPO=""
usage() { sed -n '2,/^# "sync" =/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        LIST=1 ;;
        --dry-run|-n)  DRY=1 ;;
        --yes|-y)      YES=1 ;;
        --all|-a)      ALL=1 ;;
        --no-pull)     NOPULL=1 ;;
        --ask)         ASK=1 ;;              # ask k/a on a conflict instead of "mine wins"
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
    [ -d "$d/.git" ] || return 1
    url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    case "$url" in *[Hh]alcyon*) return 0 ;; esac
    base="$(basename "$d")"
    case "$base" in [Hh]alcyon*) ;; *) return 1 ;; esac
    [ -f "$d/install.sh" ] && [ -d "$d/sysmode" ]
}

scan_root() {
    local root="$1"
    [ -d "$root" ] || return 0
    # -prune the heavy/noisy trees; only .git dirs are printed
    find "$root" -maxdepth 6 \
        \( -name node_modules -o -name target -o -name .gradle -o -name .venv \
           -o -name venv -o -name dist -o -name build \) -prune -o \
        -type d -name .git -print 2>/dev/null
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

# counts as  "<behind> <ahead>"  relative to the branch's upstream (0 0 if none)
ahead_behind() {
    local d="$1" up
    up="$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    [ -n "$up" ] || { printf '0 0'; return; }
    git -C "$d" rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null || printf '0 0'
}

# one menu line per checkout
describe() {
    local d="$1" br dirty ab behind ahead tag color
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
printf '%sHalcyon checkouts found:%s\n\n' "$B" "$R"
mapfile -t CANDIDATES < <(discover)
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    die "no Halcyon git checkout found (looked in ~, /opt, /srv, /workspace)."
fi
# stable order: real working trees first, caches last, then by path
mapfile -t CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | awk '{print (index($0,"/.cache/")?"1":"0") "\t" $0}' | sort -k1,1 -k2,2 | cut -f2-)
list_repos
echo

if [ "$LIST" = 1 ]; then exit 0; fi

# --repo skips the menu; a leading number (push halcyon 3) selects directly
if [ -n "$REPO" ]; then
    [ -d "$REPO/.git" ] || die "$REPO is not a git checkout."
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

    branch="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ -z "$branch" ]; then
        warn "detached HEAD - check a branch out first (git -C $d switch main). skipped."
        return 1
    fi
    for f in rebase-merge rebase-apply MERGE_HEAD; do
        if [ -e "$(git -C "$d" rev-parse --git-path "$f")" ]; then
            warn "a git $f is unfinished in $d - finish or abort it first (git -C $d status). skipped."
            return 1
        fi
    done

    remote="$(git_remote_name "$d")"
    [ -n "$remote" ] || { warn "no git remote configured in $d. skipped."; return 1; }
    ref="$remote/$branch"
    step "remote: $remote  ($(git -C "$d" remote get-url "$remote" 2>/dev/null))"

    # ---- stage and commit your work FIRST: a pull can then never clobber it or leave
    #      half-applied changes, and any clash with the remote is a normal rebase conflict.
    local f choice cf
    dirty="$(git -C "$d" status --porcelain | wc -l | tr -d ' ')"
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
                local def; def="sync: $(date '+%Y-%m-%d %H:%M') from $(hostname)"
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
                    git -C "$d" pull --rebase --quiet "$remote" "$branch" 2>&1 | sed 's/^/      /' || pullrc=1
                    if [ "$pullrc" = 0 ]; then
                        ok "rebased onto $ref"
                    elif [ -n "$(git -C "$d" diff --name-only --diff-filter=U)" ]; then
                        # a real conflict: your commit and the incoming one touch the same lines.
                        # default: YOURS WINS (what you push is final). --ask to decide by hand.
                        warn "your changes conflict with the incoming ones - keeping yours:"
                        git -C "$d" diff --name-only --diff-filter=U | sed 's/^/        /'
                        choice="k"
                        if [ "$ASK" = 1 ] && [ -t 0 ] && [ "$YES" = 0 ]; then
                            printf '   %s[k]eep mine (yours wins)  [a]bort [k/a] %s' "$B" "$R"
                            read -r choice
                        fi
                        if [ "$choice" = k ] || [ "$choice" = K ]; then
                            local guard=0
                            while mapfile -t cf < <(git -C "$d" diff --name-only --diff-filter=U) && [ "${#cf[@]}" -gt 0 ]; do
                                for f in "${cf[@]}"; do
                                    # during a rebase "theirs" is the commit being replayed - i.e. yours
                                    git -C "$d" checkout --theirs -- "$f" 2>/dev/null || git -C "$d" rm -q -f -- "$f" 2>/dev/null || true
                                done
                                git -C "$d" add -A
                                GIT_EDITOR=true git -C "$d" rebase --continue >/dev/null 2>&1 || break
                                guard=$((guard + 1)); [ "$guard" -gt 20 ] && break
                            done
                            if [ -n "$(git -C "$d" diff --name-only --diff-filter=U)" ] || \
                               [ -d "$(git -C "$d" rev-parse --git-path rebase-merge)" ] || \
                               [ -d "$(git -C "$d" rev-parse --git-path rebase-apply)" ]; then
                                git -C "$d" rebase --abort >/dev/null 2>&1
                                warn "could not settle every conflict automatically - rebase aborted."
                                warn "your work is safe in the commit. finish it yourself:  cd $d && git pull --rebase"
                                return 1
                            fi
                            ok "rebased onto $ref (kept your version of the conflicting files)"
                        else
                            git -C "$d" rebase --abort >/dev/null 2>&1
                            warn "rebase aborted - your commit is safe. resolve it yourself with:"
                            warn "  cd $d && git pull --rebase"
                            return 1
                        fi
                    else
                        git -C "$d" rebase --abort >/dev/null 2>&1
                        warn "could not rebase onto $ref - your commit is safe."
                        warn "look at it yourself:  cd $d && git status"
                        return 1
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
    if [ "$ahead" = 0 ] 2>/dev/null; then
        ok "nothing to push - already up to date with $remote/$branch"
        return 0
    fi
    if ! confirm "push $ahead commit(s) to $remote/$branch?"; then
        warn "not pushed. your commit is local; run this again when you want to push."
        return 0
    fi
    step "pushing $ahead commit(s) to $remote/$branch..."
    if git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        if ! git -C "$d" push 2>&1 | sed 's/^/      /'; then return 1; fi
    else
        if ! git -C "$d" push -u "$remote" "$branch" 2>&1 | sed 's/^/      /'; then return 1; fi
    fi
    ok "pushed"
}

rc=0
for d in "${TARGETS[@]}"; do
    sync_push "$d" || rc=1
    [ "$ALL" = 1 ] && echo
done
exit "$rc"
