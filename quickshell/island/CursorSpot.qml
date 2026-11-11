import QtQuick
import Quickshell
import Quickshell.Io

// Asks Hyprland where the mouse pointer is, so a panel can open there (the screenshot menu, the recording menu).
//   ask()  -> starts one `hyprctl cursorpos` + `hyprctl monitors` look (a few ms); `found` fires when it is known, `failed` when it is not
//   x, y   -> the pointer inside the monitor it is on (logical px, the same numbers a full-screen layer window uses); -1 = unknown
//   screen -> that monitor's name, so the window opens on the right screen
// Same numbers as ClipMenu.qml works out; this one is shared, so the panels that need it do not each carry a copy. It runs nothing
// until ask() is called, and a guard timer makes sure a hung hyprctl can never keep a panel from opening.
Scope {
    id: root
    property real x: -1
    property real y: -1
    property string screen: ""
    property bool busy: false
    readonly property bool known: x >= 0 && y >= 0
    signal found()
    signal failed()

    function ask() {
        x = -1; y = -1; screen = ""
        busy = true
        guard.restart()
        proc.running = true
    }
    function cancel() { busy = false; guard.stop() }
    function finish() {
        if (!busy) return
        busy = false
        guard.stop()
        if (known) found(); else failed()
    }

    Process {
        id: proc
        command: ["python3", "-c",
            "import json,subprocess as s\n" +
            "try:\n" +
            " c=json.loads(s.check_output(['hyprctl','cursorpos','-j'],timeout=2))\n" +
            " for m in json.loads(s.check_output(['hyprctl','monitors','-j'],timeout=2)):\n" +
            "  sc=m.get('scale') or 1\n" +
            "  w=m['width']/sc; h=m['height']/sc\n" +
            "  if m.get('transform',0)%2: w,h=h,w\n" +
            "  if m['x']<=c['x']<m['x']+w and m['y']<=c['y']<m['y']+h:\n" +
            "   print(m['name'],c['x']-m['x'],c['y']-m['y']); break\n" +
            "except Exception: pass\n"]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = text.trim().split(" ")
                if (p.length === 3 && !isNaN(parseFloat(p[1])) && !isNaN(parseFloat(p[2]))) {
                    root.screen = p[0]; root.x = parseFloat(p[1]); root.y = parseFloat(p[2])
                }
            }
        }
        onExited: root.finish()
    }
    // safety net: if hyprctl hangs, the panel still opens (on its usual spot)
    Timer { id: guard; interval: 600; onTriggered: root.finish() }
}
