#!/usr/bin/env bash
# halcyon-settings-io.sh: export -> import round trip, the import preview (new / changed / same, nothing written), and that a
# hostile archive (path escape, link, file that is not on the list) is refused.   bash tests/settings-io.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd); io="$here/scripts/halcyon-settings-io.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" HALCYON_DIR="$T/home/.config/Halcyon" XDG_STATE_HOME="$T/home/.local/state"
S="$XDG_STATE_HOME/island"; R="$HALCYON_DIR"; mkdir -p "$S" "$R/scheme"
n=0; fails=0
t() { n=$((n+1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

echo '{"theme":"dark","routeShow":false}' > "$S/settings.json"; echo 'MUSIC_CMD=spotify' > "$R/special.conf"; echo 'return {}' > "$R/scheme/current.lua"
bash "$io" export "$T/a.tar.gz" >/dev/null
t "export writes an archive that list accepts"          'bash "$io" list "$T/a.tar.gz" | grep -q "state/settings.json"'

# the machine "now": one file edited, one removed, a new one would appear
echo '{"theme":"light","routeShow":true}' > "$S/settings.json"; rm "$R/special.conf"
out=$(bash "$io" import "$T/a.tar.gz" --dry-run 2>&1)
t "preview says changed for an edited file"             'grep -q "changed  state/settings.json" <<<"$out"'
t "preview shows the difference (- now, + import)"      'grep -q "+{\"theme\":\"dark\"" <<<"$out" && grep -q -- "-{\"theme\":\"light\"" <<<"$out"'
t "preview says new for a file missing here"            'grep -q "new      rice/special.conf" <<<"$out"'
t "preview says same for an identical file"             'grep -q "same     rice/scheme/current.lua" <<<"$out"'
t "preview counts"                                      'grep -q "1 new, 1 changed, 1 unchanged" <<<"$out"'
t "preview wrote nothing"                               'grep -q "light" "$S/settings.json" && [ ! -e "$R/special.conf" ]'

bash "$io" import "$T/a.tar.gz" >/dev/null
t "import restores the edited file"                     'grep -q dark "$S/settings.json"'
t "import restores the missing file"                    '[ -f "$R/special.conf" ]'
t "import saved the previous settings first"            'ls "$HOME"/.cache/halcyon/settings-before-import-*.tar.gz >/dev/null 2>&1'

# hostile archives
mk() { rm -rf "$T/h"; mkdir -p "$T/h/state" "$T/h/rice"; echo 'halcyon-settings 1' > "$T/h/MANIFEST"; }
mk; echo x > "$T/h/rice/evil.sh";                       tar -C "$T/h" -czf "$T/b1.tar.gz" MANIFEST state rice
t "a file that is not on the list is refused"           '! bash "$io" import "$T/b1.tar.gz" >/dev/null 2>&1 && [ ! -e "$R/evil.sh" ]'
mk; ln -s /etc/passwd "$T/h/state/settings.json";       tar -C "$T/h" -czf "$T/b2.tar.gz" MANIFEST state rice
t "a symlink is refused"                                '! bash "$io" import "$T/b2.tar.gz" >/dev/null 2>&1'
mk; echo x > "$T/h/x"; tar -C "$T/h" -czf "$T/b3.tar.gz" --transform='s|^x$|state/../../escape|' MANIFEST x
t "a path with .. is refused"                           '! bash "$io" import "$T/b3.tar.gz" >/dev/null 2>&1 && [ ! -e "$T/escape" ]'
mk; rm "$T/h/MANIFEST"; echo '{}' > "$T/h/state/settings.json"; tar -C "$T/h" -czf "$T/b4.tar.gz" state rice
t "an archive without MANIFEST is refused"              '! bash "$io" import "$T/b4.tar.gz" >/dev/null 2>&1'

echo "$((n-fails))/$n passed"; exit $((fails>0))
