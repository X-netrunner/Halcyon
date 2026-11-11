#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
runner=/usr/lib/qt6/bin/qmltestrunner
[ -x "$runner" ] || runner=$(command -v qmltestrunner6 || command -v qmltestrunner || true)
[ -n "$runner" ] || { echo "skip: qmltestrunner (qt6-declarative) is not installed"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp tests/qml/actionpill/*.qml quickshell/island/ActionPill.qml "$tmp/"
QT_QPA_PLATFORM=offscreen "$runner" -input "$tmp/tst_actionpill.qml" 2>&1 | grep -E "^(PASS|FAIL|Totals)|Loc:|Actual|Expected"
exit "${PIPESTATUS[0]}"
