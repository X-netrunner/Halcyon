import QtQuick

// A button of the Version Center.
Rectangle {
    id: b
    property var pal
    property string label: ""
    property bool primary: false
    property bool disabled: false
    signal clicked()
    implicitWidth: bTxt.implicitWidth + 26
    implicitHeight: 32
    radius: 10
    opacity: disabled ? 0.4 : 1
    color: primary ? (bMa.containsMouse && !disabled ? Qt.lighter(pal.accent, 1.08) : pal.accent)
                   : (bMa.containsMouse && !disabled ? pal.fillHover : pal.fill)
    scale: bMa.pressed && !disabled ? 0.97 : 1
    Behavior on color { ColorAnimation { duration: b.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    Behavior on opacity { NumberAnimation { duration: b.pal.dFast } }
    Behavior on scale { NumberAnimation { duration: b.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    Text {
        id: bTxt
        anchors.centerIn: parent
        text: b.label
        color: b.primary ? b.pal.bg : b.pal.text
        font.family: b.pal.uiFont
        font.pixelSize: b.pal.tBody - 1
        font.weight: Font.Medium
    }
    MouseArea { id: bMa; anchors.fill: parent; hoverEnabled: true; cursorShape: b.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!b.disabled) b.clicked() }
}
