import QtQuick

// The "Pop out" / "Back to overlay" button every centre has in its header (Luna, Study, Games, Security, Firewall).
// Pop out turns this one open window into an ordinary desktop window (see Host.qml); closing the centre forgets it.
// It is hidden when Settings > Windows already makes every centre a desktop window (nothing to pop out of).
//   popped   the centre's own `popped` flag      onClicked   the centre flips it
Rectangle {
    id: pb
    property var pal
    property bool popped: false
    property bool compact: false            // glyph only (a tight header)
    signal clicked()

    visible: pal ? !pal.deskWin : false
    implicitWidth: compact ? 32 : pbRow.implicitWidth + 20
    implicitHeight: 30
    radius: 15
    color: pbMa.containsMouse ? Qt.alpha(pal.text, 0.07) : "transparent"
    Behavior on color { ColorAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

    Row {
        id: pbRow
        anchors.centerIn: parent
        spacing: 6
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(pb.popped ? 0xF0141 : 0xF03CC)
            color: pbMa.containsMouse ? pb.pal.text : pb.pal.muted
            font.family: pb.pal.font
            font.pixelSize: 16
        }
        Text {
            visible: !pb.compact
            anchors.verticalCenter: parent.verticalCenter
            text: pb.popped ? "Back to overlay" : "Pop out"
            color: pbMa.containsMouse ? pb.pal.text : pb.pal.muted
            font.family: pb.pal.uiFont
            font.pixelSize: pb.pal.tCap + 1
        }
    }
    MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked() }
}
