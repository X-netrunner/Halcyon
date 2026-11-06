import QtQuick
import QtQuick.Layouts

// a titled value on the firewall's Rules page (SecurityCenter.qml). Was an inline component there; a file of its own loads reliably.
Rectangle {
    id: fc
    property var pal
    property string title: ""
    property string value: ""
    property string note: ""
    property bool mono: false
    Layout.fillWidth: true
    implicitHeight: fcCol.implicitHeight + 22
    radius: pal.rMd
    color: pal.fill
    Column {
        id: fcCol
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 20; rightMargin: 20 }
        spacing: 4
        Text { text: fc.title; color: fc.pal.muted; font.family: fc.pal.uiFont; font.pixelSize: fc.pal.tCap }
        Text { width: parent.width; text: fc.value; wrapMode: Text.WordWrap; color: fc.pal.text; font.family: fc.mono ? fc.pal.mono : fc.pal.uiFont; font.pixelSize: fc.pal.tBody }
        Text { visible: fc.note !== ""; width: parent.width; text: fc.note; wrapMode: Text.WordWrap; color: fc.pal.muted; font.family: fc.pal.uiFont; font.pixelSize: fc.pal.tCap }
    }
}
