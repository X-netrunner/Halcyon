import QtQuick

// a figure tile (alerts read / cleared / waiting) used by the Security center's AI card
Rectangle {
    id: rt
    property var pal
    property string value: "0"
    property string caption: ""
    property color tone: pal ? pal.text : "#ffffff"
    implicitHeight: 64
    radius: 14
    color: Qt.alpha(tone, 0.10)
    Column {
        anchors.centerIn: parent
        spacing: 1
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: rt.value
            color: rt.tone
            font.family: rt.pal ? rt.pal.uiFont : "sans-serif"
            font.pixelSize: (rt.pal ? rt.pal.tTitle : 15) + 6
            font.weight: Font.Medium
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: rt.caption
            color: rt.pal ? rt.pal.muted : "#aaaaaa"
            font.family: rt.pal ? rt.pal.uiFont : "sans-serif"
            font.pixelSize: rt.pal ? rt.pal.tCap : 11
        }
    }
}
