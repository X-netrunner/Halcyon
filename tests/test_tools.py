"""Everyday tools: python3 tests/test_tools.py   (scripts/halcyon-tools.py; the system programs are replaced by stubs)"""
import importlib.util, io, json, os, stat, sys, tempfile, zlib, contextlib

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-tools-test-")
stubs = os.path.join(tmp, "bin")
os.makedirs(stubs)
# only the stubs plus a few basic tools: with /usr/bin on PATH a real machine's own yay / nmcli / pactl were found (and run) instead
base = os.path.join(tmp, "base")
os.makedirs(base)
for prog in ("sh", "bash", "cat", "env", "id", "sleep", "mkdir", "rm", "printf", "true", "false", "grep", "sed", "head", "tr", "date"):
    for d in ("/usr/bin", "/bin"):
        if os.path.exists(os.path.join(d, prog)):
            os.symlink(os.path.join(d, prog), os.path.join(base, prog))
            break
LOG = os.path.join(tmp, "calls.log")
os.environ.update({"HOME": tmp, "XDG_RUNTIME_DIR": tmp, "XDG_CONFIG_HOME": os.path.join(tmp, "c"),
                   "XDG_STATE_HOME": os.path.join(tmp, "s"), "XDG_CACHE_HOME": os.path.join(tmp, "k"),
                   "PATH": stubs + ":" + base, "STUB_LOG": LOG})

spec = importlib.util.spec_from_file_location("tools", os.path.join(here, "..", "scripts", "halcyon-tools.py"))
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)

bad = 0
n_checks = 0


def check(label, got, want):
    global bad, n_checks
    n_checks += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


def stub(name, out="", rc=0, script=None):
    """A fake program: logs its arguments, prints `out`, exits `rc` (or runs a custom shell body)."""
    p = os.path.join(stubs, name)
    body = script if script is not None else f"cat <<'EOF'\n{out}\nEOF\nexit {rc}\n" if out else f"exit {rc}\n"
    with open(p, "w") as f:
        f.write(f'#!/bin/sh\necho "{name} $*" >> "$STUB_LOG"\n' + body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


def calls():
    try:
        return open(LOG).read().splitlines()
    except OSError:
        return []


def reset():
    for f in os.listdir(stubs):
        os.remove(os.path.join(stubs, f))
    if os.path.exists(LOG):
        os.remove(LOG)


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        t.IS_TTY = True                      # messages go to the terminal streams here, not to notify-send
        rc = t.main(argv)
    return rc, out.getvalue(), err.getvalue()


# ---- pure functions
check("esc", t.wifi_escape('a;b,c:d"e\\f'), 'a\\;b\\,c\\:d\\"e\\\\f')
check("payload wpa", t.wifi_payload("Home", "pa;ss", "wpa-psk"), "WIFI:T:WPA;S:Home;P:pa\\;ss;;")
check("payload sae", t.wifi_payload("Home", "secret99", "sae"), "WIFI:T:WPA;S:Home;P:secret99;;")
check("payload open", t.wifi_payload("Cafe", "", ""), "WIFI:T:nopass;S:Cafe;;")
check("payload wep", t.wifi_payload("Old", "wxyz1", "none"), "WIFI:T:WEP;S:Old;P:wxyz1;;")
check("payload hex-looking password is quoted", t.wifi_payload("H", "12345678", "wpa-psk"), 'WIFI:T:WPA;S:H;P:"12345678";;')
check("hex", t.format_color((255, 0, 128), "hex"), "#ff0080")
check("rgb", t.format_color((255, 0, 128), "rgb"), "rgb(255, 0, 128)")
check("hsl red", t.format_color((255, 0, 0), "hsl"), "hsl(0, 100%, 50%)")
check("hsl grey", t.format_color((128, 128, 128), "hsl"), "hsl(0, 0%, 50%)")
check("parse_hex", t.parse_hex("  #A1b2C3\n"), (161, 178, 195))
check("parse_hex none", t.parse_hex("nothing"), None)
png = t.swatch_png((1, 2, 3), 4)
check("png signature", png[:8], b"\x89PNG\r\n\x1a\n")
idat = png[png.index(b"IDAT") + 4:png.index(b"IEND") - 8]
check("png pixels", zlib.decompress(idat), (b"\x00" + bytes((1, 2, 3)) * 4) * 4)
check("level abs", t.parse_level("30", 80), 30)
check("level up", t.parse_level("+5", 80), 85)
check("level down clamp", t.parse_level("-90", 80), 0)
check("level cap", t.parse_level("500", 80), 150)
check("zoom in from 1", t.zoom_next(1.0, "in"), 1.5)
check("zoom in", t.zoom_next(2.0, "in"), 2.5)
check("zoom out floor", t.zoom_next(1.0, "out"), 1.0)
check("zoom toggle on", t.zoom_next(1.0, "toggle"), 2.0)
check("zoom toggle off", t.zoom_next(3.0, "toggle"), 1.0)
check("expand date", t.expand("on {date} at {time}", (2026, 10, 22, 9, 5, 0, 3, 295, 0), ""), "on 2026-10-22 at 09:05")
check("expand clip", t.expand("[{clip}]", None, "hi"), "[hi]")
cl = [{"address": "0xb", "workspace": {"id": 2}, "at": [0, 0]}, {"address": "0xa", "workspace": {"id": 1}, "at": [900, 0]},
      {"address": "0xc", "workspace": {"id": 1}, "at": [0, 0]}]
check("window order", [c["address"] for c in t.window_order(cl)], ["0xc", "0xa", "0xb"])
check("next wraps", t.next_window(cl, "0xb", 1)["address"], "0xc")
check("prev wraps", t.next_window(cl, "0xc", -1)["address"], "0xb")
check("next from none", t.next_window(cl, "", 1)["address"], "0xc")
sample = [{"index": 7, "mute": False, "volume": {"front-left": {"value_percent": "40%"}, "front-right": {"value_percent": "38%"}},
           "properties": {"application.name": "Spotify", "application.process.binary": "spotify", "media.name": "Song"}},
          {"index": 9, "mute": True, "volume": {"mono": {"value_percent": "100%"}}, "properties": {"application.name": "Firefox"}}]
ins = t.parse_inputs(sample)
check("inputs", [(i["id"], i["name"], i["vol"], i["mute"]) for i in ins], [(7, "Spotify", 40, False), (9, "Firefox", 100, True)])
check("match", [i["id"] for i in t.match_inputs(ins, "spot")], [7])

# ---- with stub programs
reset()
stub("pactl", json.dumps(sample))
rc, out, err = run(["mixer", "set", "spotify", "+10"])
check("mixer set rc", rc, 0)
check("mixer set call", [c for c in calls() if "set-sink-input-volume" in c], ["pactl set-sink-input-volume 7 50%"])
rc, out, err = run(["mixer", "mute", "firefox"])
check("mixer mute call", [c for c in calls() if "mute" in c], ["pactl set-sink-input-mute 9 1"])
rc, out, err = run(["mixer", "set", "nobody", "30"])
check("mixer unknown app", (rc, "nobody" in err), (1, True))
rc, out, err = run(["mixer", "list"])
check("mixer list", ("Spotify" in out and "40%" in out and "(muted)" in out), True)

reset()
stub("nmcli", script='''case "$*" in
  *"-f active,ssid"*) printf 'no:Other\\nyes:Home\\\\:Net\\n' ;;
  *"psk"*) echo 'pass;word' ;;
  *"key-mgmt"*) echo 'wpa-psk' ;;
esac
''')
rc, out, err = run(["wifi-qr", "--text"])
check("wifi-qr text", out.strip(), "WIFI:T:WPA;S:Home\\:Net;P:pass\\;word;;")

reset()
stub("nmcli", script='''case "$*" in
  *"--active"*) printf 'Work VPN:vpn\\neth:ethernet\\n' ;;
  *"NAME,TYPE,DEVICE"*) printf 'Work VPN:vpn:tun0\\nHome WG:wireguard:\\neth:ethernet:eth0\\n' ;;
esac
''')
rc, out, err = run(["vpn", "status"])
check("vpn status", out.splitlines(), ["on   Work VPN  (vpn)", "off  Home WG  (wireguard)"])
rc, out, err = run(["vpn", "toggle"])
check("vpn toggle turns the active one off", [c for c in calls() if "connection down" in c], ["nmcli connection down Work VPN"])
rc, out, err = run(["vpn", "up", "home"])
check("vpn up by name", [c for c in calls() if "connection up" in c], ["nmcli connection up Home WG"])
rc, out, err = run(["vpn", "up", "mars"])
check("vpn unknown", (rc, "mars" in err), (1, True))

reset()
stub("checkupdates", "linux 6.1-1 -> 6.2-1\nfirefox 1 -> 2", rc=0)
stub("yay", "someaur 1 -> 2", rc=0)
rc, out, err = run(["updates", "check"])
check("updates check", (rc, out.strip()), (0, "3 updates: 2 from the repositories, 1 from the AUR"))
rc, out, err = run(["updates", "status"])
check("updates status", "3 updates" in out, True)
rc, out, err = run(["updates", "now"])
check("updates now", (rc, "3 updates" in out), (0, True))
reset()
stub("checkupdates", rc=2)
rc, out, err = run(["updates", "check"])
check("updates none", out.strip(), "Everything is up to date")

reset()
stub("kdeconnect-cli", script='''case "$*" in *--list-available*) echo "abcd1234_ef Pixel 8" ;; esac\n''')
stub("wl-paste", "from clipboard")
open(os.path.join(tmp, "a.txt"), "w").write("x")
rc, out, err = run(["phone", "send", os.path.join(tmp, "a.txt")])
check("phone send", [c for c in calls() if "--share " in c], [f"kdeconnect-cli -d abcd1234_ef --share {tmp}/a.txt"])
rc, out, err = run(["phone", "ring", "--to", "pixel"])
check("phone ring", [c for c in calls() if "--ring" in c], ["kdeconnect-cli -d abcd1234_ef --ring"])
rc, out, err = run(["phone", "ring", "--to", "nokia"])
check("phone unknown", (rc, "nokia" in err), (1, True))

reset()
stub("hyprpicker", "#336699")
stub("wl-copy")
rc, out, err = run(["colorpick", "rgb"])
check("colorpick rc", rc, 0)
check("colorpick copies", [c for c in calls() if c.startswith("wl-copy")], ["wl-copy "])
check("colorpick log", open(os.path.join(tmp, "s", "island", "colors.log")).read().split()[1], "#336699")
check("swatch file", os.path.exists(os.path.join(tmp, "halcyon-swatch.png")), True)
reset()
stub("hyprpicker", rc=1)
check("colorpick cancelled", run(["colorpick"])[0], 1)
check("colorpick bad format", run(["colorpick", "cmyk"])[0], 1)

reset()
stub("slurp", "320 200 10 20")
stub("wl-copy")
rc, out, err = run(["measure"])
check("measure", (rc, "320x200" in out), (0, True))

# snippets (no picker needed for these)
reset()
stub("wl-copy")
stub("wtype")
rc, out, err = run(["snippets", "add", "addr", "12 Main St"])
check("snippet add", rc, 0)
check("snippet file", json.load(open(t.SNIPPETS)), {"addr": "12 Main St"})
check("snippet bad name", run(["snippets", "add", "no way", "x"])[0], 1)
rc, out, err = run(["snippets", "list"])
check("snippet list", out.split()[:2], ["addr", "12"])
run(["snippets", "type", "addr"])
check("snippet type", [c for c in calls() if c.startswith("wtype")], ["wtype -- 12 Main St"])
check("snippet missing", run(["snippets", "copy", "zzz"])[0], 1)
run(["snippets", "rm", "addr"])
check("snippet rm", json.load(open(t.SNIPPETS)), {})

# windows via a fake hyprctl
reset()
stub("hyprctl", script='''case "$*" in
  "clients -j") echo '[{"address":"0x1","class":"kitty","title":"t","workspace":{"id":1,"name":"1"},"at":[0,0],"mapped":true,"hidden":false,"focusHistoryID":1},{"address":"0x2","class":"firefox","title":"w","workspace":{"id":1,"name":"1"},"at":[800,0],"mapped":true,"hidden":false,"focusHistoryID":0}]' ;;
  "activewindow -j") echo '{"address":"0x2"}' ;;
  "dispatch hl."*) echo ok ;;
esac
''')
run(["windows", "last"])
check("windows last (Lua dispatcher)", [c for c in calls() if "dispatch" in c], ["hyprctl dispatch hl.dsp.focus({ last = true })"])
run(["windows", "next"])
check("windows next wraps to first", [c for c in calls() if "hl.dsp.focus({ window" in c], ['hyprctl dispatch hl.dsp.focus({ window = "address:0x1" })'])
rc, out, err = run(["windows", "list"])
check("windows list", out.splitlines()[0].startswith("kitty"), True)
# an older Hyprland (hyprlang config): the Lua form is refused, the legacy dispatcher runs
reset()
stub("hyprctl", script='''case "$*" in
  "dispatch hl."*) echo "Invalid dispatcher" ;;
  "dispatch focuscurrentorlast") echo ok ;;
esac
''')
rc, out, err = run(["windows", "last"])
check("windows last falls back to the legacy dispatcher", (rc, [c for c in calls() if "dispatch" in c][-1]), (0, "hyprctl dispatch focuscurrentorlast"))
# both refused: an error, not a silent nothing
reset()
stub("hyprctl", script='echo "hl.dispatch: expected a dispatcher"\n')
rc, out, err = run(["windows", "last"])
check("a refused dispatcher is reported", (rc != 0, "refused" in err), (True, True))

# zoom
reset()
stub("hyprctl", script='''case "$*" in "getoption cursor:zoom_factor -j") echo '{"option":"cursor:zoom_factor","float":1.0}' ;; eval*) echo ok ;; esac\n''')
run(["zoom", "toggle"])
check("zoom call (Lua config: eval)", [c for c in calls() if "eval" in c or "keyword" in c], ["hyprctl eval hl.config({ cursor = { zoom_factor = 2.0 } })"])
# an older Hyprland without eval: the keyword form
reset()
stub("hyprctl", script='''case "$*" in "getoption cursor:zoom_factor -j") echo '{"option":"cursor:zoom_factor","float":2.0}' ;; eval*) echo "unknown request" ;; keyword*) echo ok ;; esac\n''')
run(["zoom", "toggle"])
check("zoom fallback (keyword)", [c for c in calls() if "keyword" in c], ["hyprctl keyword cursor:zoom_factor 1.0"])
# Hyprland refuses both: say so instead of silently doing nothing
reset()
stub("hyprctl", script='''case "$*" in "getoption cursor:zoom_factor -j") echo '{"float":1.0}' ;; *) echo "keyword can't work with non-legacy parsers. Use eval." ;; esac\n''')
rc, out, err = run(["zoom", "toggle"])
check("zoom refused is reported", (rc != 0, "did not take the zoom" in err), (True, True))

# a missing program says what to install, usage errors exit 2
reset()
rc, out, err = run(["wifi-qr"])
check("missing nmcli", (rc, "nmcli" in err), (1, True))
check("unknown tool", run(["nope"])[0], 2)
check("no args", run([])[0], 2)

# ---- ">do" plain-English rules: one app's volume must not hijack the speaker volume
sys.argv = ["halcyon-ai.py"]
aspec = importlib.util.spec_from_file_location("ai", os.path.join(here, "..", "scripts", "halcyon-ai.py"))
ai = importlib.util.module_from_spec(aspec)
aspec.loader.exec_module(ai)
for phrase, want in [("spotify volume 30", {"action": "app-volume", "value": "spotify|30"}),
                     ("set the volume of discord to 20%", {"action": "app-volume", "value": "discord|20"}),
                     ("mute firefox", {"action": "app-volume", "value": "firefox|mute"}),
                     ("unmute spotify", {"action": "app-volume", "value": "spotify|unmute"}),
                     ("mute", {"action": "volume", "value": "mute"}),
                     ("mute it", {"action": "volume", "value": "mute"}),
                     ("sound volume 30", {"action": "volume", "value": 30}),
                     ("volume 40", {"action": "volume", "value": 40}),
                     ("workspace 3", {"action": "workspace", "value": 3})]:
    check("do rule: " + phrase, ai.plan_by_rules(phrase), want)
check("do app via model value", ai.value_for("app-volume", "x", "Spotify|40"), "spotify|40")
check("do app rejects speaker words", ai.value_for("app-volume", "x", "sound|40"), None)
check("do app describe", ai.describe({"action": "app-volume", "value": "spotify|30"}), "Volume of spotify: 30%")

print(f"ok ({n_checks} checks)" if not bad else f"{bad} of {n_checks} failed")
sys.exit(1 if bad else 0)
