import QtQuick

// A round icon button (refresh, close): the wallpaper gallery's look.
Rectangle {
    id: ri
    property var pal
    property string glyph: ""
    signal clicked()

    implicitWidth: 32
    implicitHeight: 32
    radius: 16
    color: ma.containsMouse ? Qt.alpha(pal.accent, 0.2) : Qt.alpha(pal.bg, 0.5)
    border.width: 1
    border.color: pal.line
    Behavior on color { ColorAnimation { duration: ri.pal.dFast } }

    Text { anchors.centerIn: parent; text: ri.glyph; color: ri.pal.text; font.family: ri.pal.font; font.pixelSize: 12 }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ri.clicked()
    }
}
