import QtQuick

// One line of the quiet Halcyon footprint note in the tree view (Overview.qml): a faint star, a label and a value.
Item {
    id: hr
    property var pal
    property bool main: true                // CPU / RAM: a bit stronger than the small lines for the heaviest parts
    property color tint: pal.accent
    property string label: ""
    property string value: ""
    width: 240
    height: main ? 20 : 17

    Text {
        x: 0
        anchors.verticalCenter: parent.verticalCenter
        text: hr.main ? "✦" : "✧"
        color: hr.tint
        opacity: hr.main ? 0.55 : 0.35
        font.family: hr.pal.uiFont
        font.pixelSize: hr.main ? 11 : 9
    }
    Text {
        x: 19
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - 19 - valT.implicitWidth - 8)
        elide: Text.ElideRight
        text: hr.label
        color: hr.pal.muted
        opacity: hr.main ? 0.85 : 0.6
        font.family: hr.main ? hr.pal.uiFont : hr.pal.font
        font.pixelSize: hr.main ? 12 : 10
    }
    Text {
        id: valT
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: hr.value
        color: hr.pal.text
        opacity: hr.main ? 0.7 : 0.45
        font.family: hr.pal.font
        font.pixelSize: hr.main ? 11 : 10
    }
}
