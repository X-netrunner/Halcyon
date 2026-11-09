import QtQuick

// One line of the bar builder's panels: a muted label on the left, the control(s) on the right, all lines lined up.
// Part of the bar builder window (BarBuilderWindow.qml). `bb` is that window.
Item {
    id: r
    required property var bb
    property string label: ""
    property int labelW: 112
    default property alias content: slot.data
    width: parent ? parent.width : 0
    implicitHeight: Math.max(32, slot.implicitHeight)

    Text {
        anchors.verticalCenter: parent.verticalCenter
        width: r.labelW
        text: r.label
        elide: Text.ElideRight
        color: r.bb.pal.muted
        font.family: r.bb.pal.uiFont
        font.pixelSize: r.bb.pal.tCap
    }
    Row {
        id: slot
        x: r.labelW + 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
    }
}
