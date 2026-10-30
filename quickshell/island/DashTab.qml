import QtQuick

// One tab of the rail dashboard's strip (Caelestia's Tabs.qml): the icon over its name. The current tab is in the spotlight (full colour,
// the accent, a touch bigger; Dashboard.qml glides one soft pill behind it); the other tabs are faded back.
//   `contentW` is how wide the icon / name really is.
Item {
    id: root
    property var pal
    property string glyph: ""
    property string label: ""
    property bool current: false
    signal clicked()
    readonly property real contentW: Math.max(ico.implicitWidth, lbl.implicitWidth)
    implicitHeight: 48

    Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -2
        spacing: 1
        opacity: root.current ? 1 : (ma.containsMouse ? 0.8 : 0.5)
        scale: root.current ? 1.06 : 1
        Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
        Behavior on scale { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        Text {
            id: ico
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.glyph
            color: root.current ? root.pal.accent : root.pal.muted
            font.family: root.pal.font
            font.pixelSize: 18
            Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        }
        Text {
            id: lbl
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.label
            color: root.current ? root.pal.accent : root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody - 1
            font.weight: root.current ? Font.DemiBold : Font.Normal
            Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
