import QtQuick
import QtQuick.Layouts

// A label with a row of option chips. When the chips do not fit the width they wrap onto the next line instead of running out
// of the box (the desktop builder's side panel is only ~530 px wide, and "Top-left / Top-right / Bottom-left / Bottom-right" is wider).
//   options: [[id, "Label"], ...]   current: the id that is on   picked(id): a chip was clicked
RowLayout {
    id: r
    property var pal
    property string label: ""
    property var options: []
    property var current: ""
    property int labelWidth: 128
    property bool drop: false         // true: one drop-down (SDrop) instead of a row of chips
    property bool fit: false          // true: all chips share one line, each an equal share of the width (labels elide if they must)
    property int chipPad: 16
    signal picked(var id)
    function nameOf(id) { for (var i = 0; i < options.length; i++) if (options[i][0] === id) return options[i][1]; return "Choose" }

    spacing: 8
    Text {
        Layout.preferredWidth: r.labelWidth
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: r.drop ? 10 : 6
        text: r.label
        color: r.pal.text
        font.family: r.pal.uiFont
        font.pixelSize: r.pal.tBody
        elide: Text.ElideRight
    }
    SDrop {
        visible: r.drop
        Layout.fillWidth: true
        Layout.maximumWidth: 300
        Layout.alignment: Qt.AlignTop
        pal: r.pal
        items: r.drop ? r.options.map(function (o) { return { t: o[1], on: r.current === o[0] } }) : []
        summary: r.nameOf(r.current)
        onPicked: i => r.picked(r.options[i][0])
    }
    Flow {
        id: flow
        visible: !r.drop
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        spacing: 8
        Layout.preferredHeight: childrenRect.height
        Repeater {
            model: r.drop ? [] : r.options
            delegate: Chip {
                required property var modelData
                pal: r.pal
                implicitHeight: 30
                padX: r.fit ? 6 : r.chipPad
                width: r.fit ? Math.floor((flow.width - flow.spacing * (r.options.length - 1)) / Math.max(1, r.options.length)) : implicitWidth
                maxLabel: r.fit ? Math.max(20, width - 12) : 240
                label: modelData[1]
                on: r.current === modelData[0]
                onClicked: r.picked(modelData[0])
            }
        }
    }
}
