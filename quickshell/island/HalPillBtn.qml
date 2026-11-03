import QtQuick

// One icon button inside the Halcyon button's pill (HalcyonButton.qml): a glyph, and optionally a short label ("Auto").
// 44 px high so it is an easy target. `active` = the thing it opens is open (the model sheet) or on (Pop out is popped).
//   glyph   a Nerd Font code point (the same numbers the centres already use)      label   shown next to the glyph when set
//   maxLabel   the label is elided to this width, so a long model name cannot push the pill out of the corner cell
Rectangle {
    id: pb
    property var pal
    property int glyph: 0
    property string label: ""
    property bool active: false
    property int maxLabel: 44
    signal clicked()

    implicitHeight: 44
    implicitWidth: label !== "" ? pbRow.implicitWidth + 24 : 44
    radius: height / 2
    color: active ? Qt.alpha(pal.accent, 0.16) : (pbMa.containsMouse ? pal.fillHover : "transparent")
    scale: pbMa.pressed ? 0.96 : 1
    Behavior on color { ColorAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curveCalm } }
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

    Row {
        id: pbRow
        anchors.centerIn: parent
        spacing: 6
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(pb.glyph)
            color: pb.active ? pb.pal.accent : (pbMa.containsMouse ? pb.pal.text : pb.pal.muted)
            font.family: pb.pal.font
            font.pixelSize: 20
        }
        Text {
            visible: pb.label !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, pb.maxLabel)
            elide: Text.ElideRight
            text: pb.label
            color: pb.active ? pb.pal.accent : pb.pal.text
            font.family: pb.pal.uiFont
            font.pixelSize: pb.pal.tBody
            font.weight: Font.Medium
        }
    }
    MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked() }
}
