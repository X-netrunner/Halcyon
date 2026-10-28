import QtQuick

// Part of QuickChat.qml (the AI chatbox).
Text {
    id: tb
    required property var pal
    property bool hot: false
    signal clicked()
    color: (ma.containsMouse || hot) ? pal.accent : pal.muted
    font.family: pal.mono
    font.pixelSize: 11
    MouseArea { id: ma; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tb.clicked() }
}
