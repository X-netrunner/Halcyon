import QtQuick

// A small button of the dashboard styles (DashBento.qml, DashCommand.qml, DashStrip.qml): one glyph on a soft fill, lit with an accent wash while `on`.
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property bool on: false
    property int glyphSize: 18
    signal clicked()
    radius: pal.rSm
    color: on ? Qt.alpha(pal.accent, 0.18) : (ma.containsMouse ? Qt.alpha(pal.text, 0.10) : Qt.alpha(pal.text, 0.06))
    Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    Text {
        anchors.centerIn: parent
        text: root.glyph
        color: root.on ? root.pal.accent : root.pal.muted
        font.family: root.pal.font
        font.pixelSize: root.glyphSize
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
