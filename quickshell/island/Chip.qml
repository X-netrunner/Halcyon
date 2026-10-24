import QtQuick

// Pill button. Resting = quiet raised surface; on = accent wash with a faint accent edge.
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property string label: ""
    property bool on: false
    property bool primary: false       // the window's main action (Done, Save ...): solid accent in the new style, like `on` before
    property int maxLabel: 120
    property int padX: 16
    signal clicked()
    signal rightClicked()

    implicitHeight: 36
    implicitWidth: content.implicitWidth + padX * 2
    radius: height / 2
    readonly property bool solid: primary && pal.zen
    color: solid ? (ma.containsMouse ? Qt.lighter(pal.primary, 1.08) : pal.primary)
         : pal.zen ? ((on || primary) ? pal.chosenFill : (ma.containsMouse ? pal.fillHover : pal.fill))
         : pal.calm ? ((on || primary) ? Qt.alpha(pal.accent, 0.17) : (ma.pressed ? pal.fillHover : (ma.containsMouse ? pal.fillHover : pal.fill)))
         : (on || primary) ? Qt.alpha(pal.accent, 0.18)
               : (ma.pressed ? pal.surfaceHi : (ma.containsMouse ? Qt.alpha(pal.surfaceHi, 0.9) : Qt.alpha(pal.surface, 0.8)))
    border.width: pal.calm ? 0 : 1          // calm: a soft fill is enough
    border.color: (on || primary) ? Qt.alpha(pal.accent, 0.40) : pal.lineSoft
    scale: ma.pressed ? 0.97 : 1
    Behavior on color { ColorAnimation { duration: pal.dFast } }
    Behavior on border.color { ColorAnimation { duration: pal.dFast } }
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: root.label !== "" && root.glyph !== "" ? 8 : 0       // an icon-only chip stays centred
        Text {
            visible: root.glyph !== ""
            text: root.glyph
            color: root.solid ? root.pal.primaryText : (root.on || root.primary) ? (root.pal.zen ? root.pal.chosenText : root.pal.accent) : root.pal.muted
            font.family: root.pal.font
            font.pixelSize: 15
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        }
        Text {
            visible: root.label !== ""
            text: root.label
            width: Math.min(implicitWidth, root.maxLabel)
            elide: Text.ElideRight
            color: root.solid ? root.pal.primaryText : (root.on || root.primary) ? (root.pal.zen ? root.pal.chosenText : root.pal.calm ? root.pal.accent : root.pal.text) : Qt.alpha(root.pal.text, root.pal.zen ? 0.86 : 0.78)
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
            font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => m.button === Qt.RightButton ? root.rightClicked() : root.clicked()
    }
}
