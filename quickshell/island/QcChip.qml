import QtQuick

// Part of QuickChat.qml (the AI chatbox).
Rectangle {
    id: ch
    required property var pal
    property string label: ""
    property bool current: false
    property bool dim: false
    property int dot: 0                // 0 none, 1 ready, 2 not ready
    signal clicked()
    implicitHeight: 24
    implicitWidth: cr.implicitWidth + 22
    radius: 8
    color: current ? pal.chosenFill : (hov.hovered ? pal.fillHover : pal.fill)
    border.width: 1
    border.color: current ? pal.lineFocus : pal.lineSoft
    Row {
        id: cr
        anchors.centerIn: parent
        spacing: 6
        Rectangle {
            visible: ch.dot > 0
            width: 6; height: 6; radius: 3
            anchors.verticalCenter: parent.verticalCenter
            color: ch.dot === 1 ? ch.pal.good : Qt.alpha(ch.pal.muted, 0.5)
        }
        Text {
            text: ch.label
            color: ch.current ? ch.pal.chosenText : (ch.dim ? Qt.alpha(ch.pal.muted, 0.85) : ch.pal.text)
            font.family: ch.pal.mono
            font.pixelSize: 11
            font.weight: ch.current ? Font.DemiBold : Font.Normal
        }
    }
    HoverHandler { id: hov }
    TapHandler { onTapped: ch.clicked() }
}
