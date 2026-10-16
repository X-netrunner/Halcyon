import QtQuick

// A small pill with a number or a few words, used by DeskGuides.qml for the gaps and the size of the picked widget.
Rectangle {
    property var pal
    property string text: ""
    property color tone: "#9aa9d4"
    width: t.implicitWidth + 10; height: 16; radius: 8
    color: tone
    Text { id: t; anchors.centerIn: parent; text: parent.text; color: "#101114"; font.family: parent.pal ? parent.pal.uiFont : "sans-serif"; font.pixelSize: 10; font.weight: Font.DemiBold }
}
