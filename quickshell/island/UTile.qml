import QtQuick

// A square-ish tile for the utilities box (style "Tiles"): an icon with, under it, either a short caption or a row of stars.
// Click = on / off, right click = the list. A hover bubble says the long version.
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property string caption: ""
    property int stars: -1               // -1: show the caption; 0..5: that many lit stars instead
    property bool on: false
    property string tip: ""
    property string tipAlign: "center"   // center | left | right
    property bool tipReady: false
    signal clicked()
    signal rightClicked()

    implicitHeight: 64
    radius: 18
    color: pal.zen ? (on ? pal.chosenFill : (ma.containsMouse ? pal.fillHover : pal.fill))
         : on ? Qt.alpha(pal.accent, 0.17) : (ma.containsMouse ? pal.fillHover : pal.fill)
    border.width: pal.calm ? 0 : 1
    border.color: on ? Qt.alpha(pal.accent, 0.40) : pal.lineSoft
    scale: ma.pressed ? 0.97 : 1
    Behavior on color { ColorAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

    Column {
        anchors.centerIn: parent
        spacing: 5
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.glyph
            color: root.on ? (root.pal.zen ? root.pal.chosenText : root.pal.accent) : root.pal.muted
            font.family: root.pal.font
            font.pixelSize: 21
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        }
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(starRow.width, cap.width)
            height: 14
            UStars { id: starRow; visible: root.stars >= 0; pal: root.pal; lit: Math.max(0, root.stars); anchors.centerIn: parent }
            Text {
                id: cap
                visible: root.stars < 0
                anchors.centerIn: parent
                width: Math.min(implicitWidth, root.width - 10)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.caption
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 11
            }
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => m.button === Qt.RightButton ? root.rightClicked() : root.clicked()
    }
    Timer { id: tipT; interval: 380; onTriggered: root.tipReady = root.tip !== "" }
    Connections {
        target: ma
        function onContainsMouseChanged() {
            if (ma.containsMouse) tipT.restart()
            else { tipT.stop(); root.tipReady = false }
        }
    }
    Rectangle {
        z: 100
        visible: opacity > 0.01
        opacity: root.tipReady && ma.containsMouse ? 1 : 0
        y: root.height + 6
        x: root.tipAlign === "left" ? 0 : root.tipAlign === "right" ? root.width - width : (root.width - width) / 2
        width: tipText.width + 20
        height: tipText.implicitHeight + 12
        radius: 10
        color: root.pal.bg
        border.width: 1
        border.color: root.pal.lineSoft
        Behavior on opacity { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.InOutSine } }
        Text {
            id: tipText
            anchors.centerIn: parent
            width: Math.min(implicitWidth, 220)
            text: root.tip
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody - 1
        }
    }
}
