import QtQuick

// On / off switch. The knob slides, the track fills with the accent, and a ring flashes the moment you click it, so there
// is never any doubt that the click went through. `busy` = a script is working on it (the ring keeps pulsing until the real
// state is known).
Item {
    id: root
    property var pal
    property bool on: false
    property bool busy: false
    signal toggled()

    implicitWidth: 46
    implicitHeight: 26

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: root.on ? Qt.alpha(root.pal.accent, 0.88) : (ma.containsMouse ? root.pal.surfaceHi : Qt.alpha(root.pal.surfaceHi, 0.75))
        border.width: 1
        border.color: root.on ? root.pal.accent : root.pal.line
        scale: ma.pressed ? 0.95 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

        Rectangle {
            id: knob
            y: 3
            width: ma.pressed ? 24 : 20
            height: 20
            radius: 10
            x: root.on ? track.width - width - 3 : 3
            color: root.on ? root.pal.bg : root.pal.text
            opacity: root.on ? 1 : 0.85
            Behavior on x { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on width { NumberAnimation { duration: root.pal.dFast } }
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        }
    }

    // flash on click
    Rectangle {
        id: ring
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: root.pal.accent
        opacity: 0
        function flash() { flashAnim.restart() }
        ParallelAnimation {
            id: flashAnim
            NumberAnimation { target: ring; property: "opacity"; from: 0.95; to: 0; duration: 520; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "scale"; from: 1; to: 1.45; duration: 520; easing.type: Easing.OutCubic }
        }
    }
    // working on it
    property real tp: 0
    NumberAnimation on tp { from: 0; to: 1; duration: 800; loops: Animation.Infinite; running: root.busy }
    Rectangle {
        anchors.fill: parent
        anchors.margins: -2
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: root.pal.accent
        opacity: root.busy ? 0.25 + 0.75 * Math.abs(Math.sin(root.tp * Math.PI)) : 0
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { ring.flash(); root.toggled() }
    }
}
