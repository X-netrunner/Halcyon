import QtQuick

// A small rounded tag on a note: Task, Due 18:00, Overdue, Later today.
Rectangle {
    id: pill
    property var pal
    property string text: ""
    property color tone: pal.accent
    implicitHeight: 18
    implicitWidth: lab.implicitWidth + 14
    radius: 9
    color: Qt.alpha(tone, 0.14)
    Text {
        id: lab
        anchors.centerIn: parent
        text: pill.text
        color: pill.tone
        font.family: pill.pal.uiFont
        font.pixelSize: 10
        font.weight: Font.Medium
    }
}
