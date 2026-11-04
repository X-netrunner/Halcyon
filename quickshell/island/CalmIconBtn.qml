import QtQuick
import Quickshell

// One icon button for the calm centres: a glyph, no label. The name is a tooltip that appears while the pointer rests on it,
// so a header row can be three 38 px circles instead of three text buttons. The one place a word is kept is a `label` that is
// asked for (the main action of a page, a primary button), because a bare triangle does not say "Stop" or "Play".
//
//   glyph    a Nerd Font code point                tip   the name shown on hover ("" = none)
//   active   the thing it controls is on/open      primary   solid accent (one per page at most)
//   quiet    the header's resting tone (muted glyph, no background until hover)
//   size     38 by default; 30 for a dense row, 44 for a main action
Item {
    id: b
    property var pal
    property int glyph: 0
    property string tip: ""
    property string label: ""                // only when a word is really needed next to the glyph
    property bool active: false
    property bool primary: false
    property bool danger: false
    property bool quiet: true
    property bool enabledBtn: true
    property int size: 38
    signal clicked()

    implicitWidth: label !== "" ? row.implicitWidth + 26 : size
    implicitHeight: size
    opacity: enabledBtn ? 1 : 0.32

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: b.primary ? (ma.containsMouse ? Qt.lighter(b.pal.accent, 1.06) : b.pal.accent)
                         : b.active ? Qt.alpha(b.pal.accent, 0.15)
                         : (ma.containsMouse && b.enabledBtn ? b.pal.fillHover : "transparent")
        scale: ma.pressed ? 0.94 : 1
        Behavior on color { ColorAnimation { duration: b.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: b.pal.curveCalm } }
        Behavior on scale { NumberAnimation { duration: b.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: b.pal.curve } }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(b.glyph)
            color: b.primary ? b.pal.primaryText : b.danger ? b.pal.bad : b.active ? b.pal.accent : (ma.containsMouse ? b.pal.text : (b.quiet ? b.pal.muted : b.pal.text))
            font.family: b.pal.font
            font.pixelSize: Math.round(b.size * 0.45)
        }
        Text {
            visible: b.label !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: b.label
            color: b.primary ? b.pal.primaryText : b.danger ? b.pal.bad : b.active ? b.pal.accent : b.pal.text
            font.family: b.pal.uiFont
            font.pixelSize: b.pal.tBody
            font.weight: Font.Medium
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: b.enabledBtn
        cursorShape: Qt.PointingHandCursor
        onClicked: b.clicked()
    }

    // the name, below the button, only while the pointer rests on it; it is its own window so no row can clip it
    LazyLoader {
        active: b.tip !== "" && b.enabledBtn && ma.containsMouse
        PopupWindow {
            anchor.item: b
            anchor.rect.x: Math.round((b.width - implicitWidth) / 2)
            anchor.rect.y: b.height + 7
            implicitWidth: tipTxt.implicitWidth + 20
            implicitHeight: tipTxt.implicitHeight + 12
            color: "transparent"
            visible: true
            Rectangle {
                anchors.fill: parent
                radius: 9
                color: Qt.alpha(b.pal.surfaceHi, 0.97)
                border.width: 1
                border.color: b.pal.lineSoft
                Text {
                    id: tipTxt
                    anchors.centerIn: parent
                    text: b.tip
                    color: b.pal.text
                    font.family: b.pal.uiFont
                    font.pixelSize: b.pal.tCap
                    font.weight: Font.Medium
                }
            }
        }
    }
}
