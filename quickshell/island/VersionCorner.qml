import QtQuick

// The corner button of a Version Center card: the Halcyon star in a rounded square, like the one in the top bar of every centre.
// Pressed, it turns and takes the accent; the card's actions slide open under it.
Rectangle {
    id: cb
    property var pal
    property bool open: false
    signal clicked()
    implicitWidth: 32
    implicitHeight: 32
    radius: 10
    color: open ? Qt.alpha(pal.accent, 0.16) : (cbMa.containsMouse ? pal.fillHover : pal.fill)
    border.width: open ? 1 : 0
    border.color: pal.accent
    scale: cbMa.pressed ? 0.95 : 1
    Behavior on color { ColorAnimation { duration: cb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: cb.pal.curveCalm } }
    Behavior on scale { NumberAnimation { duration: cb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: cb.pal.curve } }
    HalMark {
        anchors.centerIn: parent
        pal: cb.pal
        size: 16
        rotation: cb.open ? 90 : 0
        Behavior on rotation { NumberAnimation { duration: cb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: cb.pal.curve } }
    }
    MouseArea { id: cbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cb.clicked() }
}
