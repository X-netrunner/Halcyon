import QtQuick
import QtQuick.Layouts

// One hardware line on the performance page: icon tile, small caption, value, optional usage bars.
Item {
    id: root
    property var pal
    property string glyph: ""
    property string label: ""
    property string value: ""
    property var usage: []          // [{ label, frac, text }]  e.g. one per mounted disk

    implicitHeight: Math.max(36, body.implicitHeight)

    Rectangle {
        id: tile
        width: 36; height: 36; radius: root.pal.rMd - 2
        color: Qt.alpha(root.pal.accent, 0.12)
        border.width: 1
        border.color: root.pal.line
        Text {
            anchors.centerIn: parent
            text: root.glyph
            color: root.pal.accent
            font.family: root.pal.font
            font.pixelSize: 17
        }
    }

    Column {
        id: body
        anchors { left: tile.right; leftMargin: 12; right: parent.right; top: parent.top }
        spacing: 1
        Text {
            text: root.label.toUpperCase()
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 9
            font.letterSpacing: 1.1
        }
        Text {
            width: parent.width
            text: root.value
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: 12
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
        }
        Repeater {
            model: root.usage
            delegate: Column {
                required property var modelData
                width: body.width
                topPadding: 4
                spacing: 3
                Text {
                    width: parent.width
                    text: modelData.label + "  ·  " + modelData.text
                    elide: Text.ElideRight
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: 10
                }
                Rectangle {
                    width: parent.width; height: 4; radius: 2
                    color: root.pal.surface
                    Rectangle {
                        width: parent.width * Math.min(1, Math.max(0.02, modelData.frac))
                        height: parent.height; radius: 2
                        color: modelData.frac > 0.9 ? "#e58a8a" : (modelData.frac > 0.75 ? "#e5c07b" : root.pal.accent)
                        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
    }
}
