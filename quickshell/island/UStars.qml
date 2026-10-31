import QtQuick

// Five small stars; `lit` of them are lit (0..5). Used by the utilities box tiles: Wi-Fi signal, Bluetooth battery, hotspot devices.
Row {
    id: root
    property var pal
    property int lit: 0
    property int total: 5
    spacing: 2
    Repeater {
        model: root.total
        delegate: Text {
            required property int index
            text: "\u2605"
            font.pixelSize: 11
            font.family: root.pal.uiFont
            color: index < root.lit ? root.pal.accent : Qt.alpha(root.pal.text, 0.22)
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        }
    }
}
