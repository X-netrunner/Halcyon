import QtQuick

// A small state tag of the Version Center ("3 commits behind", "pinned 8d1c6e3"); fs and hgt make a bigger one for the Halcyon card.
Rectangle {
    id: tg
    property var pal
    property string label: ""
    property color tone: pal.muted
    property bool dot: false
    property int fs: pal.tCap
    property int hgt: 22
    implicitWidth: tagRow.implicitWidth + 16 + (hgt > 22 ? 8 : 0)
    implicitHeight: hgt
    radius: hgt / 2
    color: Qt.alpha(tone, 0.16)
    Row {
        id: tagRow
        anchors.centerIn: parent
        spacing: 6
        Rectangle { visible: tg.dot; width: 6; height: 6; radius: 3; color: tg.tone; anchors.verticalCenter: parent.verticalCenter }
        Text { text: tg.label; color: tg.tone; font.family: tg.pal.uiFont; font.pixelSize: tg.fs; font.weight: Font.Medium }
    }
}
