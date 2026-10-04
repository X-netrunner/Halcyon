import QtQuick

// Horizontal slider, value 0..1. Emits moved() while you drag.
Item {
    id: root
    property var pal
    property string glyph: ""
    property real value: 0
    property bool dimmed: false
    signal moved(real v)

    property bool dragging: false
    property real local: 0
    readonly property real shown: dragging ? local : value

    implicitHeight: 32

    Text {
        id: ico
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 22
        text: root.glyph
        color: root.dimmed ? root.pal.muted : root.pal.accent
        font.family: root.pal.font
        font.pixelSize: 17
    }
    Text {
        id: pct
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 36
        horizontalAlignment: Text.AlignRight
        text: Math.round(root.shown * 100) + "%"
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
        font.weight: Font.Medium
    }
    Item {
        anchors.left: ico.right
        anchors.leftMargin: 10
        anchors.right: pct.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        height: 26

        Rectangle {
            id: track
            width: parent.width
            height: 10
            radius: 5
            anchors.verticalCenter: parent.verticalCenter
            color: root.pal.surface
            border.width: 1
            border.color: root.pal.lineSoft
            Rectangle {
                width: Math.max(10, parent.width * Math.min(1, Math.max(0, root.shown)))
                height: parent.height
                radius: 5
                color: root.dimmed ? Qt.alpha(root.pal.muted, 0.7) : root.pal.accent
                Behavior on width { enabled: !root.dragging; NumberAnimation { duration: root.pal.dFast; easing.type: Easing.OutCubic } }
            }
        }
        MouseArea {
            anchors.fill: parent
            function setFrom(x) {
                root.local = Math.max(0, Math.min(1, x / width))
                root.moved(root.local)
            }
            onPressed: m => { root.dragging = true; setFrom(m.x) }
            onPositionChanged: m => { if (pressed) setFrom(m.x) }
            onReleased: root.dragging = false
            onCanceled: root.dragging = false
        }
    }
}
