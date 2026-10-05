import QtQuick
import Quickshell
import Quickshell.Wayland

// The little bar that slides up from the bottom edge whenever the volume, the screen brightness or the keyboard light changes,
// whoever changed it (keys, touchpad edge gestures, the panel sliders, other apps). It is click-through and goes away by itself.
// shell.qml feeds it: Osd.show("vol" | "bright" | "kbd", 0..1 (volume may go above 1), muted)
Scope {
    id: root
    property var pal
    property bool enabled: true
    property int holdMs: 1700

    property string kind: "vol"
    property real value: 0
    property bool muted: false
    property bool shown: false

    function show(k, v, m) {
        if (!enabled) return
        kind = k
        value = v
        muted = !!m
        shown = true
        hideT.restart()
    }
    Timer { id: hideT; interval: root.holdMs; onTriggered: root.shown = false }

    readonly property string glyph: kind === "bright" ? String.fromCodePoint(0xF00E0)
                                  : kind === "kbd" ? String.fromCodePoint(0xF030C)
                                  : (muted || value <= 0.001 ? String.fromCodePoint(0xF0581) : String.fromCodePoint(0xF057E))
    readonly property string title: kind === "bright" ? "Brightness" : (kind === "kbd" ? "Keyboard light" : (muted ? "Muted" : "Volume"))
    readonly property bool over: kind === "vol" && value > 1.001

    PanelWindow {
        id: win
        visible: root.shown || card.opacity > 0.01
        anchors { bottom: true }
        implicitWidth: 360
        implicitHeight: 120
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-osd"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}              // nothing in here takes clicks

        Glass {
            id: card
            pal: root.pal
            width: 316
            height: 56
            radius: 28
            anchors.horizontalCenter: parent.horizontalCenter
            // slides up from below the edge, slides back down when done
            y: root.shown ? parent.height - height - 34 : parent.height + 8
            opacity: root.shown ? 1 : 0
            opacityBody: root.pal.glassSolid
            Behavior on y { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }

            Text {
                id: ic
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyph
                color: root.muted ? root.pal.muted : root.pal.accent
                font.family: root.pal.font
                font.pixelSize: 22
            }
            Rectangle {
                id: track
                anchors.left: ic.right
                anchors.leftMargin: 14
                anchors.right: pct.left
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                height: 8
                radius: 4
                color: root.pal.surface
                Rectangle {
                    height: parent.height
                    radius: 4
                    width: parent.width * Math.max(0, Math.min(1, root.value / (root.kind === "vol" ? 1.5 : 1)))
                    color: root.muted ? root.pal.muted : (root.over ? root.pal.warn : root.pal.accent)
                    Behavior on width { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                }
                // the 100% mark on the volume bar (it can go to 150%)
                Rectangle {
                    visible: root.kind === "vol"
                    x: parent.width * (1 / 1.5) - 1
                    y: -2; width: 2; height: parent.height + 4
                    color: Qt.alpha(root.pal.text, 0.35)
                }
            }
            Text {
                id: pct
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                horizontalAlignment: Text.AlignRight
                text: root.muted && root.kind === "vol" ? "mute" : Math.round(root.value * 100) + "%"
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: Font.DemiBold
            }
        }
    }
}
