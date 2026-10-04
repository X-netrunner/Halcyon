import QtQuick

Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property bool primary: false
    property int size: 34
    property bool enabledBtn: true
    signal clicked()

    width: size
    height: size
    radius: size / 2
    opacity: enabledBtn ? 1 : 0.35
    color: primary ? (ma.containsMouse ? Qt.lighter(pal.accent, 1.08) : pal.accent)
                   : (ma.containsMouse ? pal.surface : "transparent")
    scale: ma.pressed ? 0.94 : 1
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
    Behavior on color { ColorAnimation { duration: pal.dFast } }

    Text {
        anchors.centerIn: parent
        text: root.glyph
        color: root.primary ? root.pal.bg : root.pal.text
        font.family: root.pal.font
        font.pixelSize: root.primary ? 20 : 18
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabledBtn
        onClicked: root.clicked()
    }
}
