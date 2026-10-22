import QtQuick
import Quickshell
import Quickshell.Wayland

// The "now playing" overlay for the game launcher (hgl). While a game runs it is a small chip in a corner of the screen (the game
// glyph and how long it has been running, a red dot while recording) that fades back after a few seconds so it stays out of the
// way. A click opens it: Record, Screenshot, Discord (open it to go live / share the game in a call), Mic, Do not disturb,
// Move (to the next corner, remembered as opt.gamePillCorner) and Stop. It closes again after a while without the pointer on it,
// or on a click on its header. It never takes the keyboard (the game keeps it) and is click-through outside the chip / panel.
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

    readonly property string corner: (env && env.opt && env.opt.gamePillCorner) || "tr"     // tr | tl | br | bl
    readonly property bool top: corner.charAt(0) === "t"
    readonly property bool right: corner.charAt(1) === "r"
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
    function nextCorner() {
        var order = ["tr", "br", "bl", "tl"]
        if (env && typeof env.setOpt === "function") env.setOpt("gamePillCorner", order[(order.indexOf(corner) + 1) % 4])
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
        case "move": nextCorner(); break
        case "stop": root.expanded = false; root.stopRequested(); break
        }
    }

    LazyLoader {
        active: root.running && root.enabled
        PanelWindow {
            id: win
            anchors { top: root.top; bottom: !root.top; left: !root.right; right: root.right }
            margins { top: 52; bottom: 18; left: 18; right: 18 }
            implicitWidth: 300
            implicitHeight: 260
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-game"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: root.expanded ? panel : chip }

            // the clock only ticks while the overlay exists
            Timer {
                interval: 1000; repeat: true; running: true; triggeredOnStart: true
                onTriggered: root.nowSecs = Date.now() / 1000
            }
            // the chip fades back after 4 s; the open panel closes after 8 s without the pointer on it
            property bool awake: true
            Timer { id: sleepT; interval: 4000; running: true; onTriggered: win.awake = false }
            Timer { id: closeT; interval: 8000; running: root.expanded && !panelHover.hovered; onTriggered: root.expanded = false }

            // ---- the chip
            Glass {
                id: chip
                visible: !root.expanded
                pal: root.pal
                height: 34
                radius: 17
                width: chipRow.implicitWidth + 24
                x: root.right ? win.width - width : 0
                y: root.top ? 0 : win.height - height
                opacityBody: root.pal.glassSolid
                opacity: win.awake || chipHover.hovered || root.recording ? 1 : 0.4
                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                HoverHandler { id: chipHover; onHoveredChanged: if (hovered) { win.awake = true; sleepT.restart() } }
                Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 7
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
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.expanded = true }
            }

            // ---- the open panel
            Glass {
                id: panel
                visible: root.expanded
                pal: root.pal
                width: win.width
                height: col.implicitHeight + 24
                radius: 18
                x: 0
                y: root.top ? 0 : win.height - height
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
