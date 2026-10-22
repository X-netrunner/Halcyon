#!/usr/bin/env bash
# hgl (Halcyon game launcher) end-to-end test with fake system programs: umu-run, systemd-run, systemctl, gamemoderun, curl, steam and a fake
# gamemode.sh. Nothing real is started and nothing outside a temp HOME is touched.
#   HGL=target/debug/hgl bash tests/hgl.test.sh
set -u
HGL="${HGL:-target/debug/hgl}"
[ -x "$HGL" ] || HGL="target/release/hgl"
HGL="$(realpath "$HGL")" || exit 1
T="$(mktemp -d)"
trap 'pkill -f "$T/bin/quickshell" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
mkdir -p "$HOME" "$T/bin" "$T/scopes" "$HOME/.config/Halcyon/scripts"
export PATH="$T/bin:$PATH"
export FAKE_T="$T"
fail=0
ok() { local d="$1"; shift; if "$@" >"$T/last.out" 2>&1; then echo "ok   $d"; else echo "FAIL $d"; sed 's/^/     /' "$T/last.out" | head -20; fail=1; fi; }
no() { local d="$1"; shift; if "$@" >"$T/last.out" 2>&1; then echo "FAIL $d (should have failed)"; fail=1; else echo "ok   $d"; fi; }
has() { grep -q -- "$1" "$2"; }

# ---- fakes
cat >"$T/bin/umu-run" <<'F'
#!/bin/bash
echo "fake umu-run $*"
echo "WINEPREFIX=$WINEPREFIX PROTONPATH=$PROTONPATH GAMEID=$GAMEID WAYLAND=${PROTON_ENABLE_WAYLAND:-} PWD=$PWD"
[ -n "${FAKE_UMU_OUT:-}" ] && echo "$FAKE_UMU_OUT"
sleep "${FAKE_UMU_SLEEP:-1}"
exit "${FAKE_UMU_EXIT:-0}"
F
cat >"$T/bin/gamemoderun" <<'F'
#!/bin/bash
exec "$@"
F
cat >"$T/bin/gamescope" <<'F'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
F
cat >"$T/bin/systemd-run" <<'F'
#!/bin/bash
unit=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) unit="$2"; shift 2 ;;
    -p) shift 2 ;;
    --) shift; break ;;
    --*) shift ;;
    *) break ;;
  esac
done
[ -n "$unit" ] && echo $$ >"$FAKE_T/scopes/$unit.scope"
exec "$@"
F
cat >"$T/bin/systemctl" <<'F'
#!/bin/bash
[ "$1" = "--user" ] && shift
case "$1" in
  is-active) u="${@: -1}"; [ -f "$FAKE_T/scopes/$u" ] && kill -0 "$(cat "$FAKE_T/scopes/$u")" 2>/dev/null ;;
  stop) u="$2"; [ -f "$FAKE_T/scopes/$u" ] && { kill "$(cat "$FAKE_T/scopes/$u")" 2>/dev/null; rm -f "$FAKE_T/scopes/$u"; }; echo "stop $u" >>"$FAKE_T/systemctl.log"; exit 0 ;;
  set-property) echo "$*" >>"$FAKE_T/systemctl.log"; exit 0 ;;
  *) exit 0 ;;
esac
F
cat >"$HOME/.config/Halcyon/scripts/gamemode.sh" <<'F'
#!/bin/bash
case "$1" in
  on)  touch "$FAKE_T/gm-state"; echo on >>"$FAKE_T/gm.log" ;;
  off) rm -f "$FAKE_T/gm-state"; echo off >>"$FAKE_T/gm.log" ;;
  status) [ -f "$FAKE_T/gm-state" ] && echo on || echo off ;;
esac
F
chmod +x "$T/bin/"* "$HOME/.config/Halcyon/scripts/gamemode.sh"
# a Halcyon process to sample
cp "$(command -v sleep)" "$T/bin/quickshell"; "$T/bin/quickshell" 120 &

mkdir -p "$T/games/Hades"
printf 'MZ' >"$T/games/Hades/HadesII.exe"

echo "--- library"
ok "add" "$HGL" add "$T/games/Hades/HadesII.exe" --no-icon --name "Hades II" --umu-id umu-1145350
ok "list shows it" bash -c "'$HGL' list | grep -q hades-ii"
ok "same name gets a new id" "$HGL" add "$T/games/Hades/HadesII.exe" --no-icon --name "Hades II"
ok "remove the duplicate" "$HGL" remove hades-ii-2
ok "json list" bash -c "'$HGL' list --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[0][\"id\"]==\"hades-ii\" and d[0][\"status\"]==\"attention\"'"   # no Proton yet
no "bad id refused" "$HGL" show "../etc/passwd"
no "bad wrapper refused" "$HGL" set hades-ii wrappers gamemode,evil
ok "set env" "$HGL" set hades-ii env.DXVK_HUD fps
ok "set gamescope preset" "$HGL" set hades-ii gamescope 1080p

echo "--- fake Proton runtime (checksum-verified install through a fake curl)"
mkdir -p "$T/srv/GE-Proton10-4" "$T/srv/GE-Proton10-3"
for v in GE-Proton10-4 GE-Proton10-3; do
  printf '#!/bin/sh\n' >"$T/srv/$v/proton"; chmod +x "$T/srv/$v/proton"
  ( cd "$T/srv" && tar -czf "$v.tar.gz" "$v" && sha512sum "$v.tar.gz" >"$v.sha512sum" )
done
cat >"$T/srv/releases.json" <<J
[{"tag_name":"GE-Proton10-4","assets":[{"browser_download_url":"https://dl/GE-Proton10-4.sha512sum"},{"browser_download_url":"https://dl/GE-Proton10-4.tar.gz"}]},
 {"tag_name":"GE-Proton10-3","assets":[{"browser_download_url":"https://dl/GE-Proton10-3.tar.gz"},{"browser_download_url":"https://dl/GE-Proton10-3.sha512sum"}]}]
J
cat >"$T/bin/curl" <<'F'
#!/bin/bash
echo "$*" >>"$FAKE_T/curl.log"
# fake curl: api URL -> releases.json; https://dl/X -> file X from the fake server (-o FILE saves it, otherwise stdout)
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; -H|-A|--max-time|--retry) shift 2 ;; *) shift ;; esac; done
case "$url" in
  *api.github.com*) src="$FAKE_T/srv/releases.json" ;;
  *) src="$FAKE_T/srv/${url##*/}"; [ -n "${FAKE_CORRUPT:-}" ] && { echo corrupt >"$FAKE_T/bad"; src="$FAKE_T/bad"; [[ "$url" == *.sha512sum ]] && src="$FAKE_T/srv/${url##*/}"; } ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
F
chmod +x "$T/bin/curl"
ok "available lists releases" bash -c "'$HGL' proton available | grep -q GE-Proton10-4"
FAKE_CORRUPT=1 no "corrupt download is refused" "$HGL" proton install GE-Proton10-4
ok "nothing installed after the refusal" bash -c "[ -z \"\$('$HGL' proton list | grep GE)\" ]"
ok "install older" "$HGL" proton install GE-Proton10-3
ok "install latest" "$HGL" proton install latest
ok "list shows both, newest first" bash -c "'$HGL' proton list | head -1 | grep -q GE-Proton10-4"
ok "default is the first one installed" bash -c "'$HGL' config proton_default | grep -q GE-Proton10-3"
ok "rollback needs something older" bash -c "'$HGL' proton default GE-Proton10-4 && '$HGL' proton rollback | grep -q 'GE-Proton10-3'"
ok "pin a game" "$HGL" set hades-ii proton GE-Proton10-3
no "cannot remove a pinned runtime" "$HGL" proton remove GE-Proton10-3
ok "link into Steam tool dir" bash -c "mkdir -p '$HOME/.local/share/Steam/steamapps' && '$HGL' proton link-steam && [ -L '$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton10-4' ]"
ok "unlink" bash -c "'$HGL' proton link-steam --off && [ ! -e '$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton10-4' ]"

echo "--- run"
ok "dry run prints the plan" bash -c "'$HGL' run hades-ii --dry-run | grep -q 'gamescope -W 1920 -H 1080 -f'"
ok "dry run: umu-run last, with the exe" bash -c "'$HGL' run hades-ii --dry-run | grep '^cmd:' | grep -q 'umu-run .*HadesII.exe'"
ok "dry run: pinned runtime + GAMEID" bash -c "'$HGL' run hades-ii --dry-run | grep '^env:' | grep -q 'PROTONPATH=.*GE-Proton10-3.*GAMEID=umu-1145350'"
ok "dry run: user env" bash -c "'$HGL' run hades-ii --dry-run | grep -q DXVK_HUD=fps"
"$HGL" set hades-ii gamescope "" >/dev/null
FAKE_UMU_SLEEP=2 ok "real run" "$HGL" run hades-ii
ok "game saw its prefix, runtime and folder" bash -c "grep -q 'WINEPREFIX=.*prefixes/hades-ii' '$T/last.out' || true; cat '$HOME/.local/state/Halcyon/hgl/logs/hades-ii/'*.log | grep -q 'WINEPREFIX=.*prefixes/hades-ii PROTONPATH=.*GE-Proton10-3 GAMEID=umu-1145350'"
ok "game ran in its own folder" bash -c "cat '$HOME/.local/state/Halcyon/hgl/logs/hades-ii/'*.log | grep -q 'PWD=.*/games/Hades'"
ok "gaming mode on then off" bash -c "[ \"\$(tr '\n' ' ' <'$T/gm.log')\" = 'on off ' ]"
ok "gaming mode left off" bash -c "[ ! -f '$T/gm-state' ]"
ok "session state file is gone" bash -c "[ ! -e /dev/shm/halcyon-hgl-\$(id -u) ]"
ok "scope was stopped at the end" bash -c "grep -q '^stop hgl-hades-ii-' '$T/systemctl.log'"
ok "report has playtime and Halcyon cost" bash -c "'$HGL' run hades-ii --no-lean >'$T/r.out' 2>&1; grep -q 'Halcyon while you played' '$T/r.out'"
ok "last-session.json" bash -c "python3 -c 'import json;d=json.load(open(\"$HOME/.local/state/Halcyon/hgl/last-session.json\"));assert d[\"id\"]==\"hades-ii\" and d[\"samples\"]>=2 and d[\"haRamPeakMB\"]>0'"
ok "playtime and last played recorded" bash -c "'$HGL' list --json | python3 -c 'import sys,json; d=json.load(sys.stdin)[0]; assert d[\"playtime\"]>=2 and d[\"lastPlayed\"]>0'"
ok "--no-lean leaves gaming mode alone" bash -c "[ \"\$(wc -l <'$T/gm.log')\" = 2 ]"
ok "already-on gaming mode stays on" bash -c "touch '$T/gm-state'; '$HGL' run hades-ii >/dev/null 2>&1; [ -f '$T/gm-state' ] && [ \"\$(wc -l <'$T/gm.log')\" = 2 ]"
rm -f "$T/gm-state"

echo "--- the island is told (Quickshell IPC)"
mkdir -p "$T/ipc"
cat >"$T/ipc/quickshell" <<'F'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_T/ipc.log"
F
chmod +x "$T/ipc/quickshell"
: >"$T/ipc.log"
PATH="$T/ipc:$PATH" FAKE_UMU_SLEEP=1 ok "a lean run calls gamestart and gameend" bash -c "'$HGL' run hades-ii >/dev/null 2>&1; grep -q 'call island gamestart hades-ii .* true\$' '$T/ipc.log' && grep -q 'call island gameend\$' '$T/ipc.log'"
ok "gamestart comes before gameend" bash -c "[ \"\$(grep -n -m1 gamestart '$T/ipc.log' | cut -d: -f1)\" -lt \"\$(grep -n -m1 gameend '$T/ipc.log' | cut -d: -f1)\" ]"
: >"$T/ipc.log"
PATH="$T/ipc:$PATH" FAKE_UMU_SLEEP=1 ok "--no-lean still shows the pill (lean flag false)" bash -c "'$HGL' run hades-ii --no-lean >/dev/null 2>&1; grep -q 'call island gamestart hades-ii .* false\$' '$T/ipc.log'"
rm -f "$T/gm-state"

echo "--- crash triage"
FAKE_UMU_EXIT=1 FAKE_UMU_SLEEP=0 FAKE_UMU_OUT="vkCreateInstance failed: VK_ERROR_INCOMPATIBLE_DRIVER" ok "crashing run still finishes cleanly" "$HGL" run hades-ii
ok "status says attention after the crash" bash -c "'$HGL' list --json | python3 -c 'import sys,json; d=json.load(sys.stdin)[0]; assert d[\"status\"]==\"attention\" and \"code 1\" in d[\"statusReason\"], d'"
ok "triage finds the Vulkan problem" bash -c "'$HGL' triage hades-ii --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert [f[\"id\"] for f in d[\"findings\"]]==[\"vulkan-icd\"], d'"
ok "the header (PROTONPATH, command line) never triggers a rule" bash -c "FAKE_UMU_EXIT=0 FAKE_UMU_SLEEP=0 '$HGL' run hades-ii >/dev/null 2>&1; '$HGL' triage hades-ii --json | python3 -c 'import sys,json; assert json.load(sys.stdin)[\"findings\"]==[]'"
FAKE_UMU_EXIT=1 FAKE_UMU_SLEEP=0 FAKE_UMU_OUT="Application tried to create a window, but no driver could be loaded." "$HGL" run hades-ii >/dev/null 2>&1
"$HGL" set hades-ii wayland on >/dev/null
ok "one-button fix (Wayland off)" bash -c "'$HGL' fix hades-ii wayland-driver && '$HGL' show hades-ii | grep -q '^wayland=0'"
no "advice-only findings have no fix" bash -c "FAKE_UMU_EXIT=1 FAKE_UMU_SLEEP=0 FAKE_UMU_OUT='EasyAntiCheat: launch failed' '$HGL' run hades-ii >/dev/null 2>&1; '$HGL' fix hades-ii anticheat"

echo "--- the supervisor dies: the watchdog still restores"
FAKE_UMU_SLEEP=6 "$HGL" run hades-ii >/dev/null 2>&1 &
sup=$!
for _ in $(seq 1 40); do [ -f "$T/gm-state" ] && break; sleep 0.25; done
ok "gaming mode is on while the game runs" test -f "$T/gm-state"
ok "status shows the running game" bash -c "'$HGL' status | grep -q '\"running\":true'"
kill -9 "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
for _ in $(seq 1 60); do [ ! -f "$T/gm-state" ] && break; sleep 0.5; done
ok "watchdog switched gaming mode off after the game ended" bash -c "[ ! -f '$T/gm-state' ] && [ ! -e /dev/shm/halcyon-hgl-\$(id -u) ]"

echo "--- stop"
FAKE_UMU_SLEEP=60 "$HGL" run hades-ii >/dev/null 2>&1 &
sup=$!
for _ in $(seq 1 40); do [ -f "$T/gm-state" ] && break; sleep 0.25; done
no "a second launch is refused" "$HGL" run hades-ii
ok "stop" "$HGL" stop hades-ii
wait "$sup"
ok "restored after stop" bash -c "[ ! -f '$T/gm-state' ] && [ ! -e /dev/shm/halcyon-hgl-\$(id -u) ]"

echo "--- Steam import"
S="$HOME/.local/share/Steam"
mkdir -p "$S/steamapps" "$S/appcache/librarycache/1145360/abc" "$T/lib2/steamapps"
cat >"$S/steamapps/libraryfolders.vdf" <<V
"libraryfolders"
{
	"0" { "path" "$S" }
	"1" { "path" "$T/lib2" }
}
V
printf '"AppState" { "appid" "1145360" "name" "Hades" "StateFlags" "4" "LastPlayed" "1700000000" }' >"$S/steamapps/appmanifest_1145360.acf"
printf '"AppState" { "appid" "1493710" "name" "Proton Experimental" "StateFlags" "4" }' >"$S/steamapps/appmanifest_1493710.acf"
printf '"AppState" { "appid" "620" "name" "Portal 2" "StateFlags" "4" }' >"$T/lib2/steamapps/appmanifest_620.acf"
printf '"AppState" { "appid" "999" "name" "Half Downloaded" "StateFlags" "1026" }' >"$S/steamapps/appmanifest_999.acf"
printf 'jpg' >"$S/appcache/librarycache/1145360/abc/library_600x900.jpg"
ok "import" bash -c "'$HGL' import steam | grep -q '2 added'"
ok "tools and half-installed games are skipped" bash -c "'$HGL' list | grep -q steam-1145360 && '$HGL' list | grep -q steam-620 && ! '$HGL' list | grep -qi 'proton exp' && ! '$HGL' list | grep -q steam-999"
ok "cover art found in the Steam cache" bash -c "'$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; assert d[\"steam-1145360\"][\"cover\"].endswith(\"library_600x900.jpg\"), d'"
ok "a second import changes nothing" bash -c "'$HGL' import steam | grep -q '0 added, 0 updated, 0 no longer'"
rm "$T/lib2/steamapps/appmanifest_620.acf"
ok "uninstalled game leaves the library" bash -c "'$HGL' import steam | grep -q '1 no longer' && ! '$HGL' list | grep -q steam-620"

cat >"$T/bin/steam" <<'F'
#!/bin/bash
echo "$@" >>"$FAKE_T/steam.log"
# a game process the way Steam's children look: SteamGameId in the environment
( SteamGameId=1145360 exec -a fakegame sleep 3 ) &
F
chmod +x "$T/bin/steam"
ok "steam launch: headless URL, waits for the game, restores" bash -c "'$HGL' run steam-1145360 >'$T/s.out' 2>&1; grep -q -- '-silent steam://rungameid/1145360' '$T/steam.log' && grep -q 'Session over' '$T/s.out' && [ ! -f '$T/gm-state' ]"

echo "--- Epic (fake legendary)"
mkdir -p "$T/epic/Hades2Game/Bin"
printf 'MZ' >"$T/epic/Hades2Game/Bin/Game.exe"
cat >"$T/epic-list.json" <<'J'
[{"app_name":"Fortnite","app_title":"Fortnite","metadata":{"keyImages":[{"type":"DieselGameBoxTall","url":"https://cdn.epic/fort.jpg"}]}},
 {"app_name":"Hades2Game","app_title":"Hades II \u00e9","metadata":{"keyImages":[{"type":"Thumbnail","url":"https://cdn.epic/thumb.jpg"},{"type":"DieselGameBoxTall","url":"https://cdn.epic/hades-tall.jpg"}]}},
 {"app_name":"HadesDLC","app_title":"Hades DLC","metadata":{"mainGameItem":{"id":"x"}}}]
J
cat >"$T/epic-installed.full.json" <<J
[{"app_name":"Hades2Game","title":"Hades II \u00e9","install_path":"$T/epic/Hades2Game","executable":"Bin/GAME.EXE","platform":"Windows"},
 {"app_name":"MacOnly","title":"Mac","install_path":"$T/epic/mac","executable":"x","platform":"Mac"}]
J
cp "$T/epic-installed.full.json" "$T/epic-installed.json"
printf 'jpgdata' >"$T/srv/hades-tall.jpg"
cat >"$T/bin/legendary" <<'F'
#!/bin/bash
echo "$*" >>"$FAKE_T/legendary.log"
case "$1" in
  status) echo '{"account":"tester","games_available":2,"games_installed":1}' ;;
  list) cat "$FAKE_T/epic-list.json" ;;
  list-installed) cat "$FAKE_T/epic-installed.json" ;;
  install)
    mkdir -p "$FAKE_T/epic/Hades2Game/Bin"
    printf 'MZ' >"$FAKE_T/epic/Hades2Game/Bin/Game.exe"
    cp "$FAKE_T/epic-installed.full.json" "$FAKE_T/epic-installed.json" ;;
  launch)
    app="$2"; shift 2
    wrapper=""; extra=()
    while [ $# -gt 0 ]; do case "$1" in --wrapper) wrapper="$2"; shift 2 ;; --no-wine) shift ;; *) extra+=("$1"); shift ;; esac; done
    echo "legendary launch $app wrapper=[$wrapper]"
    exec $wrapper "$FAKE_T/epic/Hades2Game/Bin/Game.exe" "${extra[@]}" ;;
esac
F
chmod +x "$T/bin/legendary"
ok "epic status" bash -c "'$HGL' epic status --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"installed\"] and d[\"loggedIn\"] and d[\"account\"]==\"tester\", d'"
ok "epic list: owned games, DLC left out, installed marked, \\u escapes read" bash -c "'$HGL' epic list --json | python3 -c 'import sys,json; d={x[\"app\"]:x for x in json.load(sys.stdin)}; assert sorted(d)==[\"Fortnite\",\"Hades2Game\"], d; assert d[\"Hades2Game\"][\"installed\"] and not d[\"Fortnite\"][\"installed\"]; assert d[\"Hades2Game\"][\"title\"]==\"Hades II \u00e9\", d'"
ok "epic import adds the Windows game (and its art)" bash -c "'$HGL' import epic | grep -q '1 added.*art for 1'"
ok "epic game: source, exact exe path (case fixed)" bash -c "'$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; g=d[\"epic-hades2game\"]; assert g[\"source\"]==\"epic\" and g[\"appid\"]==\"Hades2Game\" and g[\"exe\"].endswith(\"/Bin/Game.exe\") and g[\"cover\"].endswith(\"epic-hades2game-art.jpg\"), g'"
ok "a second epic import changes nothing" bash -c "'$HGL' import epic | grep -q '0 added, 0 updated, 0 no longer'"
ok "epic dry run: legendary launch with umu-run as its wrapper" bash -c "'$HGL' run epic-hades2game --dry-run | grep '^cmd:' | grep -q \"legendary launch Hades2Game --no-wine --wrapper 'gamemoderun umu-run'\""
FAKE_UMU_SLEEP=1 ok "epic run goes through legendary, gamemoderun and umu-run" bash -c "'$HGL' run epic-hades2game >/dev/null 2>&1; cat '$HOME/.local/state/Halcyon/hgl/logs/epic-hades2game/'*.log | grep -q 'legendary launch Hades2Game wrapper=\[gamemoderun umu-run\]' && cat '$HOME/.local/state/Halcyon/hgl/logs/epic-hades2game/'*.log | grep -q 'WINEPREFIX=.*prefixes/epic-hades2game'"
rm -f "$T/gm-state"
ok "legendary config of another launcher is passed on" bash -c "'$HGL' config epic_config '$T/heroic-leg' && '$HGL' run epic-hades2game --dry-run | grep '^env:' | grep -q 'LEGENDARY_CONFIG_PATH=$T/heroic-leg'; r=\$?; '$HGL' config epic_config ''; exit \$r"
printf '[]' >"$T/epic-installed.json"
ok "uninstalled in legendary: leaves the library" bash -c "'$HGL' import epic | grep -q '1 no longer' && ! '$HGL' list | grep -q epic-hades2game"
ok "epic install: base path, Windows, then the game is in the library" bash -c "'$HGL' epic install Hades2Game >/dev/null && grep -q 'install Hades2Game --base-path .*Games/Halcyon/Epic --platform Windows -y' '$T/legendary.log' && '$HGL' list | grep -q epic-hades2game"
no "epic install refuses an odd app name" "$HGL" epic install "x;rm -rf"
printf 'name=Fortnite\nsource=epic\nappid=Fortnite\nexe=%s\n' "$T/epic/Hades2Game/Bin/Game.exe" >"$HOME/.config/Halcyon/games/epic-fortnite.conf"
ok "known warning shows up in the list" bash -c "'$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; assert \"Linux\" in d[\"epic-fortnite\"][\"known\"] and d[\"epic-hades2game\"][\"known\"]==\"\", d'"
ok "hgl fixes prints the warning" bash -c "'$HGL' fixes epic-fortnite | grep -q Linux"
"$HGL" remove epic-fortnite >/dev/null

echo "--- GOG (fake gogdl, fake GOG web API)"
mkdir -p "$T/gogdir/Witcher/bin"
printf 'MZ' >"$T/gogdir/Witcher/bin/witcher3.exe"
cat >"$T/gogdir/Witcher/goggame-1207664643.info" <<'J'
{"gameId":"1207664643","rootGameId":"1207664643","name":"The Witcher 3","playTasks":[{"type":"URLTask","path":"x"},{"isPrimary":true,"type":"FileTask","path":"BIN\\Witcher3.EXE","arguments":"-windowed"}]}
J
cat >"$T/gogdir/Witcher/goggame-111.info" <<'J'
{"gameId":"111","rootGameId":"1207664643","name":"Witcher DLC","playTasks":[{"isPrimary":true,"type":"FileTask","path":"bin/witcher3.exe"}]}
J
cat >"$T/bin/gogdl" <<'F'
#!/bin/bash
echo "$*" >>"$FAKE_T/gogdl.log"
auth=""
if [ "$1" = "--auth-config-path" ]; then auth="$2"; shift 2; fi
case "$1" in
  auth)
    [ "$2" = "--code" ] || exit 2
    mkdir -p "$(dirname "$auth")"
    printf '{"46899977096215655":{"access_token":"AT","refresh_token":"RT","expires_in":3600,"loginTime":%s}}' "$(date +%s)" >"$auth" ;;
  download)
    id="$2"; shift 2; p=""
    while [ $# -gt 0 ]; do case "$1" in --path) p="$2"; shift 2 ;; *) shift ;; esac; done
    mkdir -p "$p/bin"
    printf 'MZ' >"$p/bin/c.exe"
    printf '{"gameId":"%s","name":"Cyber Thing","playTasks":[{"isPrimary":true,"type":"FileTask","path":"bin/c.exe"}]}' "$id" >"$p/goggame-$id.info" ;;
esac
F
chmod +x "$T/bin/gogdl"
printf '%s' '{"page":1,"totalPages":1,"products":[{"id":1207664643,"title":"The Witcher 3","worksOn":{"Windows":true,"Mac":false}},{"id":999,"title":"Linux Only","worksOn":{"Windows":false}},{"id":555,"title":"Cyber Thing","worksOn":{"Windows":true}}]}' >"$T/srv/getFilteredProducts?mediaType=1&page=1"
printf '%s' '{"_links":{"boxArtImage":{"href":"https://images.gog-statics.com/box555.png"}}}' >"$T/srv/555"
printf 'pngdata' >"$T/srv/box555.png"
ok "gog status before login" bash -c "'$HGL' gog status --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"installed\"] and not d[\"loggedIn\"] and \"auth.gog.com\" in d[\"url\"], d'"
ok "gog login without an address prints the sign-in page" bash -c "'$HGL' gog login | grep -q 'auth.gog.com'"
no "gog login refuses something that is not a code" "$HGL" gog login "nope"
no "gog list needs a login" "$HGL" gog list --json
ok "gog login takes the redirect address" "$HGL" gog login "https://embed.gog.com/on_login_success?origin=client&code=ABCDEFGH12345"
ok "gogdl got the code" grep -q -- "auth --code ABCDEFGH12345" "$T/gogdl.log"
ok "login file is private" bash -c "[ \"\$(stat -c %a '$HOME/.config/Halcyon/gog/auth.json')\" = 600 ]"
ok "gog status after login" bash -c "'$HGL' gog status --json | python3 -c 'import sys,json; assert json.load(sys.stdin)[\"loggedIn\"]'"
ok "gog import reads the info file (add-ons skipped)" bash -c "'$HGL' import gog '$T/gogdir' | grep -q '1 added,'"
ok "gog game: program found whatever the case, arguments kept" bash -c "'$HGL' run gog-1207664643 --dry-run | grep '^cmd:' | grep -q 'umu-run .*bin/witcher3.exe -windowed'"
ok "umu id sets the store" bash -c "'$HGL' set gog-1207664643 umu_id umu-1207664643 >/dev/null && '$HGL' run gog-1207664643 --dry-run | grep '^env:' | grep -q 'GAMEID=umu-1207664643.*STORE=gog'"
"$HGL" config gog_dirs "$T/gogdir" >/dev/null
ok "gog list: Windows games only, installed marked" bash -c "'$HGL' gog list --json | python3 -c 'import sys,json; d={x[\"id\"]:x for x in json.load(sys.stdin)}; assert sorted(d)==[\"1207664643\",\"555\"] and d[\"1207664643\"][\"installed\"] and not d[\"555\"][\"installed\"], d'"
ok "the token never appears on a command line" bash -c "! grep -q 'Bearer' '$T/curl.log'"
ok "gog install: gogdl gets the platform and a folder, then art" bash -c "'$HGL' gog install 555 --title 'Cyber Thing' >/dev/null && grep -q 'download 555 --platform windows --path .*Games/Halcyon/GOG/cyber-thing --lang en-US' '$T/gogdl.log' && '$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; assert d[\"gog-555\"][\"cover\"].endswith(\"gog-555-art.png\"), d[\"gog-555\"]'"
no "gog install refuses a non-numeric id" "$HGL" gog install "12;x"

echo "--- cover art"
mkdir -p "$S/steamapps"
printf '"AppState" { "appid" "730" "name" "Counter Thing" "StateFlags" "4" }' >"$S/steamapps/appmanifest_730.acf"
printf 'jpgdata' >"$T/srv/library_600x900.jpg"
ok "steam import adds a game without cached art" bash -c "'$HGL' import steam | grep -q '1 added'"
ok "hgl art takes Steam art from the CDN" bash -c "'$HGL' art steam-730 | grep -q '1 found' && '$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; assert d[\"steam-730\"][\"cover\"].endswith(\"steam-730-art.jpg\"), d[\"steam-730\"]'"
ok "a game that has art is left alone" bash -c "'$HGL' art steam-730 | grep -q '0 found, 0 of 0'"
ok "a Steam re-read keeps the art that was fetched" bash -c "'$HGL' import steam >/dev/null && '$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; assert d[\"steam-730\"][\"cover\"].endswith(\"steam-730-art.jpg\"), d[\"steam-730\"]'"
printf '%s' '{"success":true,"data":[{"id":77,"name":"Hades II"}]}' >"$T/srv/Hades%20II"
printf '%s' '{"success":true,"data":[{"url":"https://cdn2.steamgriddb.com/grid/abc.png"}]}' >"$T/srv/77?dimensions=600x900&types=static"
printf 'pngdata' >"$T/srv/abc.png"
ok "without a key an .exe game gets no art (and no network)" bash -c ": >'$T/curl.log'; '$HGL' art hades-ii | grep -q '0 found'; [ ! -s '$T/curl.log' ]"
ok "the key is stored but never printed" bash -c "'$HGL' config steamgriddb_key SECRETKEY >/dev/null && '$HGL' config | grep steamgriddb_key | grep -q '(set)' && ! '$HGL' config | grep -q SECRETKEY && [ \"\$(stat -c %a '$HOME/.config/Halcyon/hgl.conf')\" = 600 ]"
ok "with a key, SteamGridDB art is found by name" bash -c "'$HGL' art hades-ii | grep -q '1 found' && '$HGL' list --json | python3 -c 'import sys,json; d={g[\"id\"]:g for g in json.load(sys.stdin)}; assert d[\"hades-ii\"][\"cover\"].endswith(\"hades-ii-art.png\"), d[\"hades-ii\"]'"
ok "the key was not on any command line" bash -c "! grep -q SECRETKEY '$T/curl.log'"
"$HGL" config steamgriddb_key "" >/dev/null

echo "--- doctor"
ok "doctor runs and prints" bash -c "'$HGL' doctor | grep -q 'umu-launcher'"
ok "doctor --json is valid JSON" bash -c "'$HGL' doctor --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(c[\"id\"]==\"vulkan\" for c in d)'"


echo "--- class and suggestions"
ok "class --json names a class A-D" bash -c "'$HGL' class --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"class\"] in \"ABCD\" and isinstance(d[\"gpus\"], list)'"
ok "suggest --json has changes and in-game settings" bash -c "'$HGL' suggest hades-ii --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"inGame\"] and \"changes\" in d and d[\"applied\"] is False'"
ok "suggest --apply leaves nothing more to change" bash -c "'$HGL' suggest hades-ii --apply >/dev/null && '$HGL' suggest hades-ii --json | python3 -c 'import sys,json; assert json.load(sys.stdin)[\"changes\"] == []'"
echo
if [ "$fail" = 0 ]; then echo "hgl: all tests passed"; else echo "hgl: FAILURES"; fi
exit "$fail"
