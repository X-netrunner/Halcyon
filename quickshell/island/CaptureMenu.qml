import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Super + S: one small menu with four icons. Screenshot a region / a window / the whole screen, or record a region.
// It is the quick door; the full panel (Super + Ctrl + S) still exists for Copy / Save / Both / text and for the window picker.
//
// The menu leaves first, then the capture starts (the menu must not be in the picture). R records a draggable region through
// scripts/screen-record.sh, which now passes the rectangle to wf-recorder. While a recording runs the menu shows its time and
// turns into Stop, so the same key works to end it.
Scope {
    id: root
    property var pal
    property bool open: false
    property bool recording: false
    property double startedAt: 0
    property int tick: 0
    property bool linger: false
    property string pending: ""

    readonly property string home: Quickshell.env("HOME")
    readonly property string shotScript: home + "/.config/Halcyon/scripts/halcyon-shot.py"
    readonly property string recScript: home + "/.config/Halcyon/scripts/screen-record.sh"
    readonly property int secs: recording && startedAt > 0 ? Math.max(0, Math.floor((Date.now() - startedAt) / 1000)) : 0

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

    // the menu goes, then the capture starts
    function shoot(mode) {
        if (!open) return
        open = false
        pending = "shot:" + mode
        goT.restart()
    }
    function recordRegion() {
        open = false
        pending = recording ? "stop" : "record"
        goT.restart()
    }
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
            if (p === "record") Quickshell.execDetached(["bash", root.recScript, "region"])
            else if (p === "stop") Quickshell.execDetached(["bash", root.recScript, "stop"])
            else if (p.indexOf("shot:") === 0) Quickshell.execDetached(["python3", root.shotScript, p.substring(5), "both"])
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
        { key: "region", glyph: 0xF019E, label: "Region", hint: "Drag a rectangle" },
        { key: "window", glyph: 0xF05AF, label: "Window", hint: "Pick a window" },
        { key: "full", glyph: 0xF0379, label: "Screen", hint: "The whole screen" },
        { key: "record", glyph: 0xF0EC2, label: "Record", hint: "Record a region" }
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
                        else if (e.key === Qt.Key_S) { root.shoot("region"); e.accepted = true }
                        else if (e.key === Qt.Key_W) { root.shoot("window"); e.accepted = true }
                        else if (e.key === Qt.Key_F) { root.shoot("full"); e.accepted = true }
                        else if (e.key === Qt.Key_R) { root.recordRegion(); e.accepted = true }
                    }
                }

                Glass {
                    id: panel
                    pal: root.pal
                    width: root.recording ? 330 : 452
                    height: root.recording ? 96 : 156
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

                    // ---- not recording: the four doors
                    RowLayout {
                        visible: !root.recording
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 8
                        Repeater {
                            model: root.tiles
                            delegate: Rectangle {
                                id: tile
                                required property var modelData
                                readonly property bool rec: modelData.key === "record"
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: root.pal.rLg
                                color: tMa.containsMouse ? Qt.alpha(tile.rec ? root.pal.bad : root.pal.accent, 0.13) : root.pal.fill
                                Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curveCalm } }
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 7
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: String.fromCodePoint(tile.modelData.glyph)
                                        color: tile.rec ? root.pal.bad : (tMa.containsMouse ? root.pal.accent : root.pal.text)
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
                                MouseArea {
                                    id: tMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: tile.rec ? root.recordRegion() : root.shoot(tile.modelData.key)
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
                }
            }
        }
    }
}
