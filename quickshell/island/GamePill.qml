import QtQuick
import Quickshell
import Quickshell.Wayland

// The "now playing" overlay for the game launcher (hgl), like the Xbox game bar's tab. While a game runs it is a tab tucked into
// the left (or right) edge of the screen: only a thin sliver shows. Touch it and the chip slides out (the game glyph and how long
// it has been running, a red dot while recording); it tucks back in once the pointer leaves. A click opens it: Record, Screenshot,
// Discord (open it to go live / share the game in a call), Mic, Do not disturb, Move (to the other edge, remembered as
// opt.gamePillSide) and Stop. It closes again after a while without the pointer on it, or on a click on its header. It sits on the
// Overlay layer so it is there over a fullscreen game too, never takes the keyboard (the game keeps it) and is click-through
// outside the tab / panel.
// shell.qml feeds it from `island gamestart / gameend` (IPC, called by `hgl run`); Stop asks shell.qml to run `hgl stop`.
// No game running = no window at all (LazyLoader), so it costs nothing when you are not playing.
Scope {
    id: root
    property var pal
    property var env: null              // the shell: isRecording, micMuted, dnd, opt and the actions
    property bool running: false
    property string name: ""
    property double since: 0            // unix seconds the game started
    property bool lean: false
    property bool enabled: true
    property bool expanded: false
    signal stopRequested()

    readonly property bool right: !!(env && env.opt && env.opt.gamePillSide === "r")     // l (default) | r
    readonly property bool recording: !!(env && env.isRecording)
    readonly property bool micMuted: !!(env && env.micMuted)
    readonly property bool dnd: !!(env && env.dnd)
    readonly property string home: Quickshell.env("HOME")

    onRunningChanged: if (!running) expanded = false

    property double nowSecs: Date.now() / 1000
    function fmt(secs) {
        var s = Math.max(0, Math.floor(secs))
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
        function p(n) { return (n < 10 ? "0" : "") + n }
        return h > 0 ? h + ":" + p(m) + ":" + p(r) : p(m) + ":" + p(r)
    }
    function otherSide() {
        if (env && typeof env.setOpt === "function") env.setOpt("gamePillSide", right ? "l" : "r")
    }
    function act(id) {
        switch (id) {
        case "record": if (env) env.toggleRecording(); break
        case "shot": Quickshell.execDetached(["python3", home + "/.config/Halcyon/scripts/halcyon-shot.py", "full", "both"]); break
        case "discord":
            // a running Vesktop / Discord just raises its window when started again; there you pick the game in Go Live / Share screen
            Quickshell.execDetached(["sh", "-c", "for a in vesktop discord discord-canary; do command -v \"$a\" >/dev/null && exec \"$a\"; done; "
                                     + "for f in dev.vencord.Vesktop com.discordapp.Discord; do flatpak info \"$f\" >/dev/null 2>&1 && exec flatpak run \"$f\"; done; "
                                     + "notify-send -a Halcyon 'Discord' 'Neither Vesktop nor Discord is installed'"])
            root.expanded = false
            break
        case "mic": Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]); break
        case "dnd": if (env) env.setDnd(!env.dnd); break
        case "move": otherSide(); break
        case "stop": root.expanded = false; root.stopRequested(); break
        }
    }

    LazyLoader {
        active: root.running && root.enabled
        PanelWindow {
            id: win
            // the whole height of the edge, fixed size: the tab and the panel move inside it, the mask keeps the rest click-through
            anchors { top: true; bottom: true; left: !root.right; right: root.right }
            implicitWidth: 300 + 12
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-game"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: root.expanded ? panel : chip }

            // the clock only ticks while the overlay exists
            Timer {
                interval: 1000; repeat: true; running: true; triggeredOnStart: true
                onTriggered: root.nowSecs = Date.now() / 1000
            }
            // out = the chip has slid out of the edge. It shows for a few seconds when the game starts (so you know where it is),
            // then tucks in; touching the sliver brings it out after a short moment (a pointer flicking past does not), and it
            // tucks back in a little after the pointer has left. The open panel closes after 8 s without the pointer on it.
            property bool out: true
            Timer { id: tuckT; interval: 4000; running: true; onTriggered: if (!chipHover.hovered) win.out = false }
            Timer { id: peekT; interval: 180; onTriggered: if (chipHover.hovered) win.out = true }
            Timer { id: closeT; interval: 8000; running: root.expanded && !panelHover.hovered; onTriggered: root.expanded = false }
            // the panel closed (its header, Stop, the 8 s timer): the tab tucks back in soon after
            Connections {
                target: root
                function onExpandedChanged() { if (!root.expanded) { tuckT.interval = 1200; tuckT.restart() } }
            }
            readonly property int sliver: 5           // what is left of the tab on screen while it is tucked in
            readonly property int tabY: Math.round(height * 0.3)

            // ---- the tab (the chip, tucked into the edge)
            Glass {
                id: chip
                visible: !root.expanded
                pal: root.pal
                height: 38
                radius: 12
                width: chipRow.implicitWidth + 30
                readonly property real shown: win.out ? width : win.sliver
                x: root.right ? win.width - shown : shown - width
                Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                y: win.tabY
                opacityBody: root.pal.glassSolid
                opacity: win.out ? 1 : 0.55
                Behavior on opacity { NumberAnimation { duration: 220 } }
                HoverHandler {
                    id: chipHover
                    onHoveredChanged: {
                        if (hovered) { tuckT.stop(); if (!win.out) peekT.restart() }
                        else { peekT.stop(); tuckT.interval = 700; tuckT.restart() }
                    }
                }
                // the sliver: an accent line along the screen edge (red while recording) so the tab can be found
                Rectangle {
                    x: root.right ? 1 : parent.width - width - 1
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: parent.height - 14
                    radius: 1.5
                    color: root.recording ? "#e5484d" : root.pal.accent
                    opacity: win.out ? 0 : 0.9
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }
                Row {
                    id: chipRow
                    anchors.centerIn: parent
                    // keeps clear of the screen edge side, where the rounded end is hidden
                    anchors.horizontalCenterOffset: root.right ? -3 : 3
                    spacing: 7
                    opacity: win.out ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                    Rectangle {
                        visible: root.recording
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4; color: "#e5484d"
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(0xF0297)
                        color: root.pal.accent
                        font.family: root.pal.font
                        font.pixelSize: 15
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.fmt(root.nowSecs - root.since)
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: 12
                    }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { win.out = true; root.expanded = true } }
            }

            // ---- the open panel
            Glass {
                id: panel
                visible: root.expanded
                pal: root.pal
                width: 300
                height: col.implicitHeight + 24
                radius: 18
                // next to the edge, level with the tab (kept on screen)
                x: root.right ? win.width - width - 12 : 12
                y: Math.max(12, Math.min(win.tabY - 12, win.height - height - 12))
                opacityBody: root.pal.glassSolid
                HoverHandler { id: panelHover }

                Column {
                    id: col
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 10

                    // header: a click folds it back into the chip
                    Item {
                        width: parent.width
                        height: 30
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: String.fromCodePoint(0xF0297)
                                color: root.pal.accent
                                font.family: root.pal.font
                                font.pixelSize: 18
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, 150)
                                elide: Text.ElideRight
                                text: root.name
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.fmt(root.nowSecs - root.since)
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: 12
                            }
                            Rectangle {
                                visible: root.lean
                                anchors.verticalCenter: parent.verticalCenter
                                height: 18
                                width: leanTxt.implicitWidth + 14
                                radius: 9
                                color: Qt.alpha(root.pal.accent, 0.14)
                                Text {
                                    id: leanTxt
                                    anchors.centerIn: parent
                                    text: "lean"
                                    color: root.pal.accent
                                    font.family: root.pal.uiFont
                                    font.pixelSize: 10
                                    font.weight: Font.Medium
                                }
                            }
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "✕"
                            color: root.pal.muted
                            font.pixelSize: 12
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.expanded = false }
                    }

                    // the actions: three to a row
                    Grid {
                        id: grid
                        columns: 3
                        spacing: 8
                        Repeater {
                            model: [
                                { id: "record", glyph: 0xF044A, label: root.recording ? "Stop rec" : "Record", hot: root.recording },
                                { id: "shot", glyph: 0xF0100, label: "Screenshot", hot: false },
                                { id: "discord", glyph: 0xF066F, label: "Discord", hot: false },
                                { id: "mic", glyph: root.micMuted ? 0xF036D : 0xF036C, label: root.micMuted ? "Mic off" : "Mic on", hot: root.micMuted },
                                { id: "dnd", glyph: root.dnd ? 0xF009B : 0xF009A, label: root.dnd ? "Quiet" : "Popups", hot: root.dnd },
                                { id: "move", glyph: 0xF0041, label: "Move", hot: false }
                            ]
                            delegate: Rectangle {
                                id: btn
                                required property var modelData
                                width: (col.width - 16) / 3
                                height: 54
                                radius: 12
                                color: btnMa.containsMouse ? Qt.alpha(root.pal.accent, 0.22)
                                     : (btn.modelData.hot ? Qt.alpha(btn.modelData.id === "record" ? "#e5484d" : root.pal.accent, 0.18) : Qt.alpha(root.pal.text, 0.05))
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 3
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: String.fromCodePoint(btn.modelData.glyph)
                                        color: btn.modelData.hot && btn.modelData.id === "record" ? "#e5484d" : root.pal.accent
                                        font.family: root.pal.font
                                        font.pixelSize: 18
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: btn.modelData.label
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: 10
                                    }
                                }
                                MouseArea { id: btnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.act(btn.modelData.id) }
                            }
                        }
                    }

                    // stop: its own wide button, apart from the rest
                    Rectangle {
                        width: parent.width
                        height: 32
                        radius: 16
                        color: stopMa.containsMouse ? Qt.alpha("#e5484d", 0.30) : Qt.alpha("#e5484d", 0.14)
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent
                            text: "Stop the game"
                            color: "#f2a7a9"
                            font.family: root.pal.uiFont
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }
                        MouseArea { id: stopMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.act("stop") }
                    }
                }
            }
        }
    }
}
