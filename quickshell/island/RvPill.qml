import QtQuick

// a tinted pill (verdict, count) used by the Security center's AI card
Rectangle {
    id: rp
    property var pal
    property string text: ""
    property color tone: pal ? pal.accent : "#8ab4ff"
    implicitWidth: rpT.implicitWidth + 16
    implicitHeight: 20
    radius: 10
    color: Qt.alpha(tone, 0.16)
    Text {
        id: rpT
        anchors.centerIn: parent
        text: rp.text
        color: rp.tone
        font.family: rp.pal ? rp.pal.uiFont : "sans-serif"
        font.pixelSize: rp.pal ? rp.pal.tCap : 11
        font.weight: Font.Medium
    }
}
