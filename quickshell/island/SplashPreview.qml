import QtQuick
import Quickshell
import Quickshell.Wayland

// Plays Splash.qml full screen, once, on its own. Three ways in:
//   play()              the login splash as a preview (Settings > Power & lock > "Play the splash", `halcyon splash`, `>splash`)
//                       and once per session for people who log in through a display manager. A click, Esc or any key ends it.
//   playMode("unlock")  the stars rush out again right after you unlock the screen. It sits on top of the desktop but takes
//                       no clicks and no keys (the window is click-through and never asks for the keyboard), about 2.2 s.
//   playMode("shutdown") the stars are drawn back into the centre and the mark folds shut, then the screen stays bare and
//                       done() is emitted: the shell powers off / reboots on that cue. A click or a key jumps to the end.
//                       If nothing happens afterwards (the power-off was refused) the window lets go by itself after 8 s,
//                       or on the next click / key, so it can never trap the screen.
// The real login splash is inside the lock screen (Lock.qml). The window does not exist while nothing is playing.
Scope {
    id: root
    property var pal
    property bool open: false
    property string mode: "login"          // login | unlock | shutdown
    property bool sound: false             // Settings > "Soft sounds with the splash"
    signal done()                          // shutdown only: the collapse is over, act now

    readonly property int durLogin: 3600
    readonly property int durUnlock: 2200
    readonly property int durShutdown: 2400

    function play() { playMode("login") }
    function playMode(m) {
        mode = (m === "unlock" || m === "shutdown") ? m : "login"
        open = true
        if (sound) Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/splash-sound.sh", mode])
    }
    function stop() { open = false }

    // shutdown: if the power-off did not happen, give the screen back
    Timer { id: holdT; interval: 8000; onTriggered: root.open = false }

    LazyLoader {
        active: root.open
        PanelWindow {
            id: win
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-splash"
            WlrLayershell.layer: WlrLayer.Overlay
            // unlock: never take the keyboard (you may already be typing) and let every click through (an empty mask)
            WlrLayershell.keyboardFocus: root.mode === "unlock" ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
            mask: root.mode === "unlock" ? clickThrough : null
            Region { id: clickThrough }

            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: event => {
                    if (root.mode === "shutdown" && sp.ended) root.open = false      // the power-off did not come: any key gives the screen back
                    else sp.skip()
                    event.accepted = true
                }
                Splash {
                    id: sp
                    anchors.fill: parent
                    pal: root.pal
                    mode: root.mode
                    duration: root.mode === "unlock" ? root.durUnlock : (root.mode === "shutdown" ? root.durShutdown : root.durLogin)
                    onFinished: {
                        if (root.mode === "shutdown") { holdT.restart(); root.done() }
                        else root.open = false
                    }
                    Component.onCompleted: start()
                }
                // shutdown, collapse over: a click gives the screen back (only reachable when the power-off was refused)
                MouseArea { anchors.fill: parent; enabled: root.mode === "shutdown" && sp.ended; onPressed: root.open = false }
            }
        }
    }
}
