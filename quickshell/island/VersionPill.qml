import QtQuick

// One entry of the actions pill in the Version Center.
Rectangle {
    id: pi
    property var pal
    property string label: ""
    property bool primary: false
    property bool disabled: false
    signal clicked()
    implicitWidth: piTxt.implicitWidth + 20
    implicitHeight: 28
    radius: 8
    opacity: disabled ? 0.4 : 1
    color: primary ? (piMa.containsMouse && !disabled ? Qt.lighter(pal.accent, 1.08) : pal.accent)
                   : (piMa.containsMouse && !disabled ? pal.fillHover : "transparent")
    Behavior on color { ColorAnimation { duration: pi.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pi.pal.curveCalm } }
    Behavior on opacity { NumberAnimation { duration: pi.pal.dFast } }
    Text {
        id: piTxt
        anchors.centerIn: parent
        text: pi.label
        color: pi.primary ? pi.pal.bg : pi.pal.text
        font.family: pi.pal.uiFont
        font.pixelSize: pi.pal.tBody - 1
        font.weight: Font.Normal
    }
    MouseArea { id: piMa; anchors.fill: parent; hoverEnabled: true; cursorShape: pi.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!pi.disabled) pi.clicked() }
}
