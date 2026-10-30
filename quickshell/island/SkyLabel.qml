import QtQuick

// One caption under (or over) a star of the performance sky (PerfTab.qml): a small name, the value, a line of detail, all centred.
Item {
    id: root
    property var pal
    property string name: ""
    property string value: ""
    property string detail: ""
    property color tint: pal.accent
    property int valueSize: 20
    width: 112
    height: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: 0
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.name
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap - 1
            font.letterSpacing: 1.4
            font.capitalization: Font.AllUppercase
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.value
            color: root.tint
            font.family: root.pal.uiFont
            font.pixelSize: root.valueSize
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.detail
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap
        }
    }
}
