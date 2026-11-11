#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
if python3 scripts/gen-tokens.py --check; then echo "ok   generated token files match design/tokens.toml"; else echo "FAIL token files are stale"; fail=1; fi
if grep -q 'import "Tokens.js" as Tok' quickshell/island/Pal.qml; then echo "ok   Pal.qml reads Tokens.js"; else echo "FAIL Pal.qml does not import Tokens.js"; fail=1; fi
if grep -q 'pal.iconFor' quickshell/island/VersionCenter.qml && grep -q 'pal.iconFor' quickshell/island/NotifIcon.qml; then
    echo "ok   Version Center and notifications share the component icons"
else
    echo "FAIL component icons are not shared"; fail=1
fi
exit "$fail"
