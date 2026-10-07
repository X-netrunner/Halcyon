import QtQuick

// A pill button for things that just DO something (repaint the terminals, reload, next wallpaper ...). Same look as Chip, but
// it answers the click: it lights up in the accent and shows a tick (and `doneLabel`, if given) for a moment, then settles
// back. `on` can still light it permanently (e.g. a mode that is active).
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property string label: ""
    property string doneLabel: ""      // what it says for a moment after the click ("" = the same label, with a tick)
    property bool on: false
    property bool flashing: false
    property int maxLabel: 1000
    signal clicked()

    implicitHeight: 36
    implicitWidth: content.implicitWidth + 32
    radius: height / 2
    color: flashing ? Qt.alpha(pal.accent, 0.30)
         : on ? Qt.alpha(pal.accent, 0.18)
         : (ma.pressed ? pal.surfaceHi : (ma.containsMouse ? Qt.alpha(pal.surfaceHi, 0.9) : Qt.alpha(pal.surface, 0.8)))
    border.width: 1
    border.color: flashing ? pal.accent : (on ? Qt.alpha(pal.accent, 0.40) : pal.lineSoft)
    scale: ma.pressed ? 0.95 : 1
    Behavior on color { ColorAnimation { duration: pal.dFast } }
    Behavior on border.color { ColorAnimation { duration: pal.dFast } }
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

    Timer { id: doneT; interval: 1700; onTriggered: root.flashing = false }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 8
        Text {
            visible: root.flashing || root.glyph !== ""
            text: root.flashing ? "✓" : root.glyph
            color: root.flashing || root.on ? root.pal.accent : root.pal.muted
            font.family: root.flashing ? root.pal.uiFont : root.pal.font
            font.pixelSize: root.flashing ? 14 : 15
            font.weight: Font.Bold
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.flashing && root.doneLabel !== "" ? root.doneLabel : root.label
            width: Math.min(implicitWidth, root.maxLabel)
            elide: Text.ElideRight
            color: root.flashing || root.on ? root.pal.text : Qt.alpha(root.pal.text, 0.78)
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
            font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.flashing = true; doneT.restart(); root.clicked() }
    }
}
