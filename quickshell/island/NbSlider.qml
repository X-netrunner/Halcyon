import QtQuick

// A labelled slider with whole-number steps, for the notification box builder.
Item {
    id: s
    property var pal
    property string label: ""
    property int from: 0
    property int to: 100
    property int value: 0
    property string unit: " px"
    property string zeroText: ""             // shown instead of "0 px" (e.g. "Auto", "Off")
    signal picked(int v)

    implicitHeight: 32
    Text {
        id: lab
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 128
        text: s.label
        color: s.pal.text
        font.family: s.pal.uiFont
        font.pixelSize: s.pal.tBody
        elide: Text.ElideRight
    }
    Slider {
        anchors.left: lab.right
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        pal: s.pal
        value: (s.value - s.from) / Math.max(1, s.to - s.from)
        readout: (s.value === 0 && s.zeroText !== "") ? s.zeroText : s.value + s.unit
        onMoved: v => s.picked(Math.round(s.from + v * (s.to - s.from)))
    }
}
