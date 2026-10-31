import QtQuick

// Tall vertical slider, value 0..1 (utilities box, style "Split"). Drag anywhere above the icon; click the icon (mute / extra dim).
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property real value: 0
    property bool dimmed: false
    signal moved(real v)
    signal glyphClicked()

    property bool dragging: false
    property real local: 0
    readonly property real shown: dragging ? local : value

    implicitWidth: 52
    implicitHeight: 150
    radius: 18
    color: pal.fill

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: Math.max(parent.width, parent.height * Math.min(1, Math.max(0, root.shown)))
        radius: parent.radius
        color: root.dimmed ? Qt.alpha(root.pal.muted, 0.28) : Qt.alpha(root.pal.accent, 0.34)
        Behavior on height { enabled: !root.dragging; NumberAnimation { duration: root.pal.dFast; easing.type: Easing.OutCubic } }
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 9
        text: Math.round(root.shown * 100)
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: 11
    }
    Text {
        id: ico
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 11
        text: root.glyph
        color: root.dimmed ? root.pal.muted : root.pal.accent
        font.family: root.pal.font
        font.pixelSize: 19
    }
    MouseArea {
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.bottom: parent.bottom; anchors.bottomMargin: 40
        function setFrom(y) {
            root.local = Math.max(0, Math.min(1, 1 - y / root.height))
            root.moved(root.local)
        }
        onPressed: m => { root.dragging = true; setFrom(m.y) }
        onPositionChanged: m => { if (pressed) setFrom(m.y) }
        onReleased: root.dragging = false
        onCanceled: root.dragging = false
    }
    MouseArea {
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 40
        onClicked: root.glyphClicked()
    }
}
