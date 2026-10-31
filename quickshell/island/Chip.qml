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
    property string tip: ""            // hover text (a calm icon-only chip says what it is here); shows after a short pause under the chip
    property string tipAlign: "center" // center | left | right: which edge of the chip the bubble lines up with (keeps it inside the box)
    property bool tipReady: false
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
    Behavior on color { ColorAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    Behavior on border.color { ColorAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
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
            Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
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
            Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => m.button === Qt.RightButton ? root.rightClicked() : root.clicked()
    }

    // the hover bubble: the first part of the text (before the first "  ·  ") is the name, the rest a quieter second line; it hangs
    // under the chip, or above it when there is no room below (a chip on the bottom row of a box at the bottom of the screen)
    readonly property var tipParts: String(tip).split("  ·  ")
    readonly property string tipTitle: tipParts[0]
    readonly property string tipMore: tipParts.slice(1).join("  ·  ")
    property bool tipAbove: false
    Timer {
        id: tipT; interval: 380
        onTriggered: {
            var win = root.Window.window
            if (win) {
                var p = root.mapToItem(null, 0, root.height)
                root.tipAbove = p.y + bubble.height + 10 > win.height
            }
            root.tipReady = root.tip !== ""
        }
    }
    Connections {
        target: ma
        function onContainsMouseChanged() {
            if (ma.containsMouse) tipT.restart()
            else { tipT.stop(); root.tipReady = false }
        }
    }
    Rectangle {
        id: bubble
        z: 100
        visible: opacity > 0.01
        opacity: root.tipReady && ma.containsMouse ? 1 : 0
        y: root.tipAbove ? -height - 5 : root.height + 5
        x: root.tipAlign === "left" ? 0 : root.tipAlign === "right" ? root.width - width : (root.width - width) / 2
        width: Math.max(tipHead.implicitWidth, tipSub.visible ? tipSub.width : 0) + 18
        height: tipCol.implicitHeight + 10
        radius: 9
        color: root.pal.bg
        border.width: 1
        border.color: root.pal.line
        Behavior on opacity { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.InOutSine } }
        Column {
            id: tipCol
            anchors.centerIn: parent
            spacing: 1
            Text {
                id: tipHead
                anchors.horizontalCenter: tipSub.visible ? undefined : parent.horizontalCenter
                text: root.tipTitle
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody - 1
                font.weight: Font.Medium
            }
            Text {
                id: tipSub
                visible: root.tipMore !== ""
                width: Math.min(implicitWidth, 190)
                text: root.tipMore
                wrapMode: Text.WordWrap
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
    }
}
