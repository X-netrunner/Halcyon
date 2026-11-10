#!/usr/bin/env bash
# halcyon-selftest.sh: the CI checks, run here, plus a few live ones CI cannot do. Read-only: it changes nothing.
#   halcyon-selftest.sh [DIR] [--quick] [--rust]
#   DIR      the Halcyon to check (default: the installed one, ~/.config/Halcyon; a git checkout works too)
#   --quick  only what breaks a login: shell syntax, Python syntax and the QML lint (what `push halcyon` runs before a push)
#   --rust   also build-check the Rust helpers with the CI clippy gate (needs cargo; slow the first time)
# Exit code 0 = everything that ran passed. Tests that are not in DIR (an installed copy carries no tests/) are skipped, not failed.
DIR=""; QUICK=0; RUST=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --rust) RUST=1 ;;
    -h|--help) sed -n 2,8p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) DIR="$a" ;;
  esac
done
DIR="${DIR:-${HALCYON_DIR:-$HOME/.config/Halcyon}}"
DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "No such folder: $DIR"; exit 2; }
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
[ -t 1 ] || { G=""; Y=""; R=""; B=""; N=""; }
fails=0; skips=0; passes=0
pass() { printf '  %s✔%s %s\n' "$G" "$N" "$1"; passes=$((passes + 1)); }
fail() { printf '  %s✘%s %s\n' "$R" "$N" "$1"; [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/      /' | head -n 15; fails=$((fails + 1)); }
skip() { printf '  %s-%s %s\n' "$Y" "$N" "$1"; skips=$((skips + 1)); }
# run LABEL CMD...: pass when CMD exits 0, else show the end of its output
run() { local label="$1" out; shift; if out=$("$@" 2>&1); then pass "$label"; else fail "$label" "$(printf '%s\n' "$out" | tail -n 15)"; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%sHalcyon self-test%s  %s\n' "$B" "$N" "$DIR"

# ---- syntax: shell, Python, JSON
bad=""
while IFS= read -r f; do bash -n "$f" 2>>"$tmp/sh" || bad="$bad $f"; done < <(
  find "$DIR/scripts" "$DIR/quickshell" -name '*.sh' -type f 2>/dev/null
  for f in install.sh update.sh get.sh sysmode/sysmode scripts/halcyon-tune; do [ -f "$DIR/$f" ] && echo "$DIR/$f"; done)
[ -z "$bad" ] && pass "shell scripts parse" || fail "shell scripts parse" "$(cat "$tmp/sh")"
# ast.parse instead of compileall: nothing is written next to the scripts
run "Python files parse" python3 -c '
import ast, glob, sys
bad = []
for p in glob.glob(sys.argv[1] + "/scripts/*.py") + glob.glob(sys.argv[1] + "/quickshell/island/scripts/*.py"):
    try: ast.parse(open(p, encoding="utf-8").read(), p)
    except SyntaxError as e: bad.append(f"{p}:{e.lineno}: {e.msg}")
print("\n".join(bad)); sys.exit(1 if bad else 0)' "$DIR"
run "JSON files are valid" python3 -c '
import glob, json, sys
bad = []
for p in glob.glob(sys.argv[1] + "/quickshell/island/*.json"):
    try: json.load(open(p, encoding="utf-8"))
    except ValueError as e: bad.append(f"{p}: {e}")
print("\n".join(bad)); sys.exit(1 if bad else 0)' "$DIR"

# ---- QML: the lint classes that stop the island from loading (the same grep as CI)
QL=""
for c in /usr/lib/qt6/bin/qmllint qmllint6 qmllint-qt6; do command -v "$c" >/dev/null 2>&1 && { QL=$c; break; }; done
if [ -n "$QL" ]; then
  "$QL" -I "$DIR/quickshell/island" "$DIR"/quickshell/island/*.qml > "$tmp/qml" 2>&1
  if grep -iE "is not a type|failed to import|could not resolve|syntax error|unexpected token|expected token" "$tmp/qml" > "$tmp/qmlbad"; then
    fail "QML lint (load-breaking errors)" "$(cat "$tmp/qmlbad")"
  else
    pass "QML lint (no load-breaking errors)"
  fi
else
  skip "QML lint: no Qt 6 qmllint (sudo pacman -S qt6-declarative)"
fi
# qmllint has no Quickshell types, so it cannot see these two: an unknown element type and a property / handler set twice
if [ -f "$DIR/tests/qml-types.test.js" ] && command -v node >/dev/null 2>&1; then
  run "QML types are known, nothing set twice" node "$DIR/tests/qml-types.test.js"
fi

if [ "$QUICK" = 0 ]; then
  # ---- the test suites, when this copy has them
  if [ -d "$DIR/tests" ]; then
    for t in "$DIR"/tests/*.test.js; do [ -f "$t" ] || continue
      [ "$(basename "$t")" = qml-types.test.js ] && continue          # ran above
      command -v node >/dev/null 2>&1 && run "test $(basename "$t")" node "$t" || skip "test $(basename "$t"): no node"; done
    for t in "$DIR"/tests/*.test.sh "$DIR"/tests/counterscan.sh; do [ -f "$t" ] && run "test $(basename "$t")" bash "$t"; done
    for t in "$DIR"/tests/test_*.py; do [ -f "$t" ] && run "test $(basename "$t")" env PYTHONDONTWRITEBYTECODE=1 python3 "$t"; done
  else
    skip "test suites: $DIR has no tests/ (run it on a git checkout for those)"
  fi

  # ---- live: only for the copy that is running
  if [ "$DIR" = "$(cd "$HOME/.config/Halcyon" 2>/dev/null && pwd)" ]; then
    if pgrep -x quickshell >/dev/null || pgrep -x qs >/dev/null; then pass "the island is running"; else fail "the island is not running" "start it: ~/.config/Halcyon/scripts/start-shell.sh island"; fi
    log="$HOME/.cache/island/quickshell-island.log"
    if [ -f "$log" ]; then
      last=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E "Configuration Loaded|Failed to load configuration" | tail -n 1)
      case "$last" in
        *Failed*) fail "the island's last (re)load failed" "$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -A4 "Failed to load configuration" | tail -n 5)" ;;
        *Loaded*) pass "the island's last (re)load succeeded" ;;
        *) skip "island log has no load line yet" ;;
      esac
    fi
    for feed in stats net; do
      pgrep -f "bin/hx $feed " >/dev/null && pass "hx $feed feed is running" || skip "hx $feed feed is not running (the island uses the slower bash fallback)"
    done
  fi
fi

# ---- Rust: the CI clippy gate
if [ "$RUST" = 1 ]; then
  if [ -f "$DIR/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
    run "Rust: clippy gate (no unwrap, documented unsafe)" bash -c 'cd "$1" && cargo clippy --workspace -q -- -D clippy::unwrap_used -D clippy::undocumented_unsafe_blocks' _ "$DIR"
  else
    skip "Rust: no Cargo.toml in $DIR or no cargo"
  fi
fi

echo
if [ "$fails" = 0 ]; then printf '%s%d passed%s' "$G" "$passes" "$N"; else printf '%s%d failed%s, %d passed' "$R" "$fails" "$N" "$passes"; fi
[ "$skips" -gt 0 ] && printf ', %d skipped' "$skips"
echo
[ "$fails" = 0 ]
