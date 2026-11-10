import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Super + Shift + R: the RECORDING menu (the screenshot menu is Super + Shift + S, ShotMenu.qml). Four doors: Region (drag a rectangle),
// Window (click a window: its rectangle is recorded), Screen (the whole screen), Audio only (just sound, an .m4a), and under them the sound that goes with the video (None / Desktop /
// Mic / Both: the same setting as Settings > Screen & audio recording, changed here too).
//
// The menu leaves first, then the recording starts (the menu must not be in the video). R / W / F / A pick the door, 1 2 3 4 the sound,
// Esc closes. While a recording runs the menu shows its time and turns into Stop, so the same keys end it. Super + Alt + R still
// starts and stops a recording at once with whatever is set, with no menu.
Scope {
    id: root
    property var pal
    property bool open: false
    property bool recording: false
    property string audio: "system"            // the sound setting (opt.recAudio), shown in the chips; the shell keeps it in step
    signal setRec(string key, string value)    // a change made here: key recKind | recAudio (the shell saves it like Settings does)
    property double startedAt: 0
    property int tick: 0
    property bool linger: false
    property string pending: ""

    readonly property string home: Quickshell.env("HOME")
    readonly property string recScript: home + "/.config/Halcyon/scripts/screen-record.sh"
    // reads `tick` so the time is worked out again every second (see RecIndicator.qml: Date.now() alone is never re-read)
    readonly property int secs: {
        var t = tick
        return recording && startedAt > 0 ? Math.max(0, Math.floor((Date.now() - startedAt) / 1000)) : 0
    }

    function fmt(s) {
        var m = Math.floor(s / 60), r = s % 60
        return m + ":" + (r < 10 ? "0" : "") + r
    }
    function show() {
        open = true
        statusProc.running = true
    }
    function hide() { open = false }
    function toggle() { if (open) hide(); else show() }
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: (root.pal ? root.pal.dMed : 300) + 100; onTriggered: root.linger = false }

    // the menu goes, then the recording starts: kind = region | window | full | audio
    function begin(kind) {
        if (!open) return
        open = false
        setRec("recKind", kind === "audio" ? "audio" : "screen")
        pending = "rec:" + kind
        goT.restart()
    }
    function recordRegion() { begin("region") }
    function pickSound(v) { setRec("recAudio", v) }
    function stopRecording() {
        open = false
        pending = "stop"
        goT.restart()
    }
    Timer {
        id: goT
        interval: 420
        onTriggered: {
            var p = root.pending
            root.pending = ""
            if (p === "rec:region") Quickshell.execDetached(["bash", root.recScript, "region"])
            else if (p === "rec:window") Quickshell.execDetached(["bash", root.recScript, "window"])
            else if (p === "rec:full" || p === "rec:audio") Quickshell.execDetached(["bash", root.recScript, "start"])
            else if (p === "stop") Quickshell.execDetached(["bash", root.recScript, "stop"])
            settleT.restart()
        }
    }
    // the recorder takes a moment to write its pid file: ask again instead of missing the change
    Timer { id: settleT; interval: 900; onTriggered: statusProc.running = true }
    Timer { interval: 2500; repeat: true; running: root.open; onTriggered: statusProc.running = true }
    Process {
        id: statusProc
        command: ["bash", root.recScript, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                var on = text.trim() === "recording"
                if (on && !root.recording) root.startedAt = Date.now()
                root.recording = on
                if (!on) root.startedAt = 0
            }
        }
    }
    // the time in the pill while it runs
    Timer { interval: 1000; repeat: true; running: root.recording && root.open; onTriggered: root.tick++ }

    readonly property var tiles: [
        { key: "region", glyph: 0xF019E, label: "Region", cap: "R", hint: "Drag a rectangle, then it records" },
        { key: "window", glyph: 0, label: "Window", cap: "W", hint: "Click a window, then it records that part of the screen" },
        { key: "full", glyph: 0xF0379, label: "Screen", cap: "F", hint: "Record the whole screen" },
        { key: "audio", glyph: 0xF036C, label: "Audio only", cap: "A", hint: "Just sound, saved as an .m4a file" }
    ]
    readonly property var sounds: [
        { key: "none", label: "No sound" },
        { key: "system", label: "Desktop" },
        { key: "mic", label: "Microphone" },
        { key: "both", label: "Both" }
    ]

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-capture"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                property bool ready: false
                property real reveal: 0
                readonly property real target: (ready && root.open) ? 1 : 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { keys.forceActiveFocus() }) }
                Connections {
                    target: root
                    function onOpenChanged() { if (root.open) Qt.callLater(function () { keys.forceActiveFocus() }) }
                }

                Item {
                    id: keys
                    anchors.fill: parent
                    focus: true
                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                        else if (root.recording) { if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.stopRecording(); e.accepted = true } }
                        else if (e.key === Qt.Key_R) { root.begin("region"); e.accepted = true }
                        else if (e.key === Qt.Key_W) { root.begin("window"); e.accepted = true }
                        else if (e.key === Qt.Key_F) { root.begin("full"); e.accepted = true }
                        else if (e.key === Qt.Key_A) { root.begin("audio"); e.accepted = true }
                        else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_4) { root.pickSound(root.sounds[e.key - Qt.Key_1].key); e.accepted = true }
                    }
                }

                Glass {
                    id: panel
                    pal: root.pal
                    width: root.recording ? 330 : 500
                    height: root.recording ? 96 : 206
                    radius: root.pal.rXl
                    opacityBody: root.pal.solid ? 1 : 0.96
                    border.color: root.recording ? Qt.alpha(root.pal.bad, 0.35) : root.pal.line
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: root.pal.boxTop + 18 + (1 - qp.reveal) * -12
                    opacity: qp.reveal
                    scale: 0.96 + 0.04 * qp.reveal
                    Behavior on width { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    // ---- recording: the time, the dot, and one way out
                    RowLayout {
                        visible: root.recording
                        anchors.fill: parent
                        anchors.margins: 18
                        spacing: 14
                        Rectangle {
                            width: 42; height: 42; radius: 14
                            color: Qt.alpha(root.pal.bad, 0.14)
                            Rectangle {
                                id: dot
                                anchors.centerIn: parent
                                width: 12; height: 12; radius: 6
                                color: root.pal.bad
                                SequentialAnimation on opacity {
                                    running: root.recording && root.open
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                text: "Recording"
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                                font.weight: Font.Medium
                            }
                            Text {
                                text: root.fmt(root.secs) + "  ·  click to stop"
                                color: root.pal.muted
                                font.family: root.pal.mono
                                font.pixelSize: root.pal.tCap + 1
                            }
                        }
                        CalmIconBtn {
                            pal: root.pal
                            glyph: 0xF04DB
                            size: 42
                            danger: true
                            tip: "Stop recording"
                            onClicked: root.stopRecording()
                        }
                    }

                    // ---- not recording: four doors, and the sound under them
                    ColumnLayout {
                        visible: !root.recording
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 8
                            Repeater {
                                model: root.tiles
                                delegate: Rectangle {
                                    id: tile
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: root.pal.rLg
                                    color: tMa.containsMouse ? Qt.alpha(root.pal.bad, 0.13) : root.pal.fill
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curveCalm } }
                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 7
                                        Rectangle {          // the Window tile: a small window with a title bar, drawn (like the screenshot menu's targets)
                                            visible: tile.modelData.key === "window"
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 30; height: 24; radius: 5
                                            color: "transparent"
                                            border.width: 2
                                            border.color: tMa.containsMouse ? root.pal.bad : root.pal.text
                                            Rectangle { x: 2; y: 2; width: parent.width - 8; height: 5; radius: 2; color: parent.border.color; opacity: 0.8 }
                                        }
                                        Text {
                                            visible: tile.modelData.key !== "window"
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: String.fromCodePoint(tile.modelData.glyph)
                                            color: tMa.containsMouse ? root.pal.bad : root.pal.text
                                            font.family: root.pal.font
                                            font.pixelSize: 24
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: tile.modelData.label
                                            color: tMa.containsMouse ? root.pal.text : root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                            font.weight: Font.Medium
                                        }
                                    }
                                    // the key that does the same, in the corner
                                    Text {
                                        anchors { right: parent.right; top: parent.top; margins: 8 }
                                        text: tile.modelData.cap
                                        color: Qt.alpha(root.pal.muted, 0.8)
                                        font.family: root.pal.mono
                                        font.pixelSize: root.pal.tCap - 1
                                    }
                                    MouseArea {
                                        id: tMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.begin(tile.modelData.key)
                                    }
                                    LazyLoader {
                                        active: tMa.containsMouse
                                        PopupWindow {
                                            anchor.item: tile
                                            anchor.rect.x: Math.round((tile.width - implicitWidth) / 2)
                                            anchor.rect.y: tile.height + 8
                                            implicitWidth: tipT.implicitWidth + 18
                                            implicitHeight: tipT.implicitHeight + 10
                                            color: "transparent"
                                            visible: true
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: 8
                                                color: Qt.alpha(root.pal.surfaceHi, 0.97)
                                                border.width: 1
                                                border.color: root.pal.lineSoft
                                                Text {
                                                    id: tipT
                                                    anchors.centerIn: parent
                                                    text: tile.modelData.hint
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // the sound that goes with the video (the same setting as Settings > Screen & audio recording)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text {
                                text: "Sound"
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                                Layout.rightMargin: 4
                            }
                            Repeater {
                                model: root.sounds
                                delegate: Rectangle {
                                    id: snd
                                    required property var modelData
                                    required property int index
                                    readonly property bool on: root.audio === modelData.key
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 30
                                    radius: height / 2
                                    color: on ? Qt.alpha(root.pal.accent, 0.18) : (sMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                    border.width: on ? 1 : 0
                                    border.color: Qt.alpha(root.pal.accent, 0.55)
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curveCalm } }
                                    Text {
                                        anchors.centerIn: parent
                                        text: snd.modelData.label
                                        color: snd.on ? root.pal.accent : root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                        font.weight: snd.on ? Font.Medium : Font.Normal
                                    }
                                    MouseArea { id: sMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickSound(snd.modelData.key) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
