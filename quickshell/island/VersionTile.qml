import QtQuick
import QtQuick.Layouts

// One fact on the Halcyon card in the Version Center: a small label, the value, and a line under it. It is flat; the whole card around it does the tilting.
Rectangle {
    id: tl
    property var pal
    property string label: ""
    property string value: ""
    property string sub: ""
    property bool mono: false
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    implicitHeight: tlCol.implicitHeight + 24
    radius: pal.rSm
    color: Qt.alpha(pal.bg, 0.35)
    border.width: 1
    border.color: pal.lineSoft
    ColumnLayout {
        id: tlCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 12
        spacing: 4
        Text {
            text: tl.label
            color: tl.pal.muted
            font.family: tl.pal.uiFont
            font.pixelSize: tl.pal.tCap
            font.weight: Font.Medium
        }
        Text {
            Layout.fillWidth: true
            text: tl.value
            elide: Text.ElideRight
            color: tl.pal.text
            font.family: tl.mono ? tl.pal.mono : tl.pal.uiFont
            font.pixelSize: tl.pal.tTitle
            font.weight: Font.Medium
        }
        Text {
            Layout.fillWidth: true
            visible: tl.sub !== ""
            text: tl.sub
            elide: Text.ElideRight
            color: tl.pal.muted
            font.family: tl.pal.uiFont
            font.pixelSize: tl.pal.tCap + 1
        }
    }
}
