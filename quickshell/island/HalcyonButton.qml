import QtQuick

// The Halcyon button every centre has in the corner of its top bar: the HalMark star in a rounded square, and the centre's name beside it.
// Click toggles `menuOpen`: the star turns 90 degrees, the square takes the accent border and fill, and a pill slides out to the
// right of the star, over the name, holding icon buttons (HalPillBtn). Closing slides it back, turns the star back, the name returns.
// The pill never grows past `maxPill`, so it stays inside the corner cell and does not cover the tabs next to it.
// Use:  HalcyonButton { pal: pal; name: "Study"; maxPill: 150; HalPillBtn { ... } HalPillBtn { ... } }   (the buttons are the pill's content)
//   menuOpen   the pill is out (the centre closes it on Esc / click-away / after a choice)      busy   the star pulses while the centre works
//   canOpen    false = nothing to put in the pill (a centre with no model choice that is already an ordinary window): the click does nothing
// Nothing here runs at rest: the pulse only runs while `busy`, the animations only while something moves.
Item {
    id: hb
    property var pal
    property string name: ""
    property bool menuOpen: false
    property bool busy: false
    property bool canOpen: true
    property int maxPill: 150
    default property alias pill: pillRow.data

    implicitWidth: 44 + 12 + nameT.implicitWidth
    implicitHeight: 44

    Rectangle {
        id: star
        width: 44; height: 44
        radius: hb.pal.rMd
        color: hb.menuOpen ? Qt.alpha(hb.pal.accent, 0.16) : (starMa.containsMouse ? hb.pal.fillHover : hb.pal.fill)
        border.width: hb.menuOpen ? 1 : 0
        border.color: hb.pal.accent
        Behavior on color { ColorAnimation { duration: hb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: hb.pal.curveCalm } }
        scale: starMa.pressed && hb.canOpen ? 0.95 : 1
        Behavior on scale { NumberAnimation { duration: hb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: hb.pal.curve } }

        HalMark {
            id: mark
            anchors.centerIn: parent
            pal: hb.pal
            size: 24
            rotation: hb.menuOpen ? 90 : 0
            Behavior on rotation { NumberAnimation { duration: hb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: hb.pal.curve } }
            opacity: hb.busy ? 0.45 + 0.55 * Math.abs(Math.sin(pulse.tp * Math.PI)) : 1
        }
        Item { id: pulse; property real tp: 0; NumberAnimation on tp { from: 0; to: 1; duration: 1100; loops: Animation.Infinite; running: hb.busy && hb.visible } }
        MouseArea {
            id: starMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: hb.canOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (hb.canOpen) hb.menuOpen = !hb.menuOpen
        }
    }

    // the centre's name; the pill slides over it
    Text {
        id: nameT
        anchors { left: star.right; leftMargin: 12; verticalCenter: star.verticalCenter }
        width: Math.max(0, hb.width - 56)
        elide: Text.ElideRight
        text: hb.name
        color: hb.pal.text
        font.family: hb.pal.uiFont
        font.pixelSize: hb.pal.tTitle + 1
        font.weight: Font.Medium
        opacity: hb.menuOpen ? 0 : 1
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: hb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: hb.pal.curveCalm } }
    }

    // the pill: grows out of the star towards the close button, no further than maxPill (no overshoot curve: it must not leave the cell)
    Rectangle {
        id: pillBox
        x: star.width + 8
        height: 44
        radius: 22
        clip: true
        width: hb.menuOpen && hb.canOpen ? hb.maxPill : 0
        visible: width > 0.5
        color: hb.pal.fill
        border.width: 1
        border.color: Qt.alpha(hb.pal.accent, 0.35)
        Behavior on width { NumberAnimation { duration: hb.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: hb.pal.curveCalm } }
        Row {
            id: pillRow
            x: 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            opacity: hb.menuOpen ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: hb.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: hb.pal.curveCalm } }
        }
    }
}
