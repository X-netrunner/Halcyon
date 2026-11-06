import QtQuick
import Quickshell
import Quickshell.Wayland

// The sign that a recording is running: a thin red line around the screen, and one small pill with a red dot and the time.
// The pill is the only part that takes a click (it stops the recording); the line lets everything through.
//
// It is drawn above every window on purpose: while it runs, you can not forget it is on. wf-recorder captures the composited
// screen, so the line and the pill are in the file as well; the pill sits in the top-right corner, and a region recording only
// takes the rectangle you picked (usually away from it).
Scope {
    id: root
    property var pal
    property bool recording: false
    property double startedAt: 0
    property int tick: 0
    // Date.now() is not something QML watches, so this only changed when `recording` or `startedAt` did, and the pill sat at 0:00.
    // Reading `tick` (the timer below adds one every second) makes it work out the time again each second.
    readonly property int secs: {
        var t = tick
        return recording && startedAt > 0 ? Math.max(0, Math.floor((Date.now() - startedAt) / 1000)) : 0
    }
    signal stopRequested()

    function fmt(s) {
        var m = Math.floor(s / 60), r = s % 60
        return m + ":" + (r < 10 ? "0" : "") + r
    }

    Timer { interval: 1000; repeat: true; running: root.recording; onTriggered: root.tick++ }

    // one surface per screen; only the first one shows the pill (the others are just the line)
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: scr
            required property var modelData
            screen: modelData
            visible: root.recording
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-rec"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: pillBox }
            readonly property bool main: modelData === Quickshell.screens[0]

            // the line: 2 px, a calm red, a slow breath so it is alive without moving the eye
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: 2
                border.color: Qt.alpha(root.pal.bad, 0.55)
                SequentialAnimation on border.color {
                    running: root.recording
                    loops: Animation.Infinite
                    ColorAnimation { to: Qt.alpha(root.pal.bad, 0.32); duration: 1600; easing.type: Easing.InOutSine }
                    ColorAnimation { to: Qt.alpha(root.pal.bad, 0.62); duration: 1600; easing.type: Easing.InOutSine }
                }
            }

            // the pill: dot, REC, time; a click stops it
            Rectangle {
                id: pillBox
                visible: scr.main
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: 22
                anchors.topMargin: 22
                width: pillRow.implicitWidth + 26
                height: 34
                radius: 17
                color: Qt.alpha(root.pal.bg, 0.92)
                border.width: 1
                border.color: Qt.alpha(root.pal.bad, 0.35)
                opacity: root.recording ? 1 : 0

                Row {
                    id: pillRow
                    anchors.centerIn: parent
                    spacing: 9
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: root.pal.bad
                        SequentialAnimation on opacity {
                            running: root.recording
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.4; duration: 850; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 850; easing.type: Easing.InOutSine }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "REC"
                        color: root.pal.bad
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tCap
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.2
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.fmt(root.secs)
                        color: root.pal.text
                        font.family: root.pal.mono
                        font.pixelSize: root.pal.tCap + 1
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(0xF04DB)
                        color: Qt.alpha(root.pal.muted, 0.9)
                        font.family: root.pal.font
                        font.pixelSize: 13
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stopRequested()
                }
            }
        }
    }
}
