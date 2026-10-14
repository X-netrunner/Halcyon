import QtQuick

// Pill button. Resting = quiet raised surface; on = accent wash with a faint accent edge.
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property string label: ""
    property bool on: false
    property int maxLabel: 120
    signal clicked()
    signal rightClicked()

    implicitHeight: 36
    implicitWidth: content.implicitWidth + 32
    radius: height / 2
    color: on ? Qt.alpha(pal.accent, 0.18)
               : (ma.pressed ? pal.surfaceHi : (ma.containsMouse ? Qt.alpha(pal.surfaceHi, 0.9) : Qt.alpha(pal.surface, 0.8)))
    border.width: 1
    border.color: on ? Qt.alpha(pal.accent, 0.40) : pal.lineSoft
    scale: ma.pressed ? 0.97 : 1
    Behavior on color { ColorAnimation { duration: pal.dFast } }
    Behavior on border.color { ColorAnimation { duration: pal.dFast } }
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 8
        Text {
            visible: root.glyph !== ""
            text: root.glyph
            color: root.on ? root.pal.accent : root.pal.muted
            font.family: root.pal.font
            font.pixelSize: 15
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        }
        Text {
            text: root.label
            width: Math.min(implicitWidth, root.maxLabel)
            elide: Text.ElideRight
            color: root.on ? root.pal.text : Qt.alpha(root.pal.text, 0.78)
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
