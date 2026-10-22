import QtQuick
import Quickshell
import Quickshell.Wayland

// The "now playing" pill for the game launcher (hgl): the game's name, how long it has been running, a "lean" mark while the island
// is resting, and a Stop button. It sits at the top of the screen on the Top layer, so a fullscreen game covers it and you meet it
// when you leave the game for a moment. Click-through everywhere except the pill itself.
// shell.qml feeds it from `island gamestart / gameend` (IPC, called by `hgl run`); Stop asks shell.qml to run `hgl stop`.
// No game running = no window at all (LazyLoader), so it costs nothing when you are not playing.
Scope {
    id: root
    property var pal
    property bool running: false
    property string name: ""
    property double since: 0            // unix seconds the game started
    property bool lean: false
    property bool enabled: true
    signal stopRequested()

    property double nowSecs: Date.now() / 1000
    function fmt(secs) {
        var s = Math.max(0, Math.floor(secs))
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
        function p(n) { return (n < 10 ? "0" : "") + n }
        return h > 0 ? h + ":" + p(m) + ":" + p(r) : p(m) + ":" + p(r)
    }

    LazyLoader {
        active: root.running && root.enabled
        PanelWindow {
            id: win
            anchors { top: true }
            margins.top: 52
            implicitWidth: 380
            implicitHeight: 56
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-game"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: card }

            // the clock only ticks while the pill exists
            Timer {
                interval: 1000; repeat: true; running: true; triggeredOnStart: true
                onTriggered: root.nowSecs = Date.now() / 1000
            }

            Glass {
                id: card
                pal: root.pal
                height: 44
                radius: 22
                width: Math.min(win.implicitWidth - 8, row.implicitWidth + 28)
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                opacityBody: root.pal.glassSolid

                Row {
                    id: row
                    anchors.centerIn: parent
                    spacing: 10

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
                    // lean: the island has paused its feeds, widgets and animations while the game runs
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
                    Rectangle {
                        id: stopBtn
                        anchors.verticalCenter: parent.verticalCenter
                        height: 26
                        width: stopTxt.implicitWidth + 22
                        radius: 13
                        color: stopArea.containsMouse ? Qt.alpha(root.pal.accent, 0.28) : Qt.alpha(root.pal.accent, 0.14)
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            id: stopTxt
                            anchors.centerIn: parent
                            text: "Stop"
                            color: root.pal.accent
                            font.family: root.pal.uiFont
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }
                        MouseArea {
                            id: stopArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.stopRequested()
                        }
                    }
                }
            }
        }
    }
}
