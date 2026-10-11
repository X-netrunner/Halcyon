import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "BarLayout.js" as BL

// Part of the bar builder window (BarBuilderWindow.qml). `bb` is that window.
Rectangle {
    required property var bb
    id: ch
    property string wid: ""
    property int idx: 0
    readonly property bool carried: bb.dragId === wid
    readonly property bool hot: cma.containsMouse && bb.dragId === ""

    implicitWidth: lbl.implicitWidth + 34
    implicitHeight: 30
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    opacity: carried ? 0.28 : 1
    color: hot ? Qt.alpha(bb.pal.surfaceHi, 0.95) : Qt.alpha(bb.pal.surface, 0.6)
    border.width: 1
    border.color: Qt.alpha(bb.pal.accent, hot ? 0.7 : 0.16)
    Behavior on color { ColorAnimation { duration: bb.pal.dFast } }
    Behavior on border.color { ColorAnimation { duration: bb.pal.dFast } }
    Behavior on opacity { NumberAnimation { duration: bb.pal.dFast } }

    Rectangle { x: 11; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: bb.pal.muted; opacity: 0.6 }
    Text {
        id: lbl
        x: 24
        anchors.verticalCenter: parent.verticalCenter
        text: BL.shortOf(ch.wid)
        color: Qt.alpha(bb.pal.text, 0.78)
        font.family: bb.pal.uiFont
        font.pixelSize: 12
        font.weight: Font.Medium
    }
    MouseArea {
        id: cma
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: bb.dragId !== "" ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real sx: 0
        property real sy: 0
        onPressed: m => { var p = mapToItem(bb, m.x, m.y); sx = p.x; sy = p.y }
        onPositionChanged: m => {
            if (!pressed) return
            var p = mapToItem(bb, m.x, m.y)
            if (bb.dragId === "") {
                if (Math.abs(p.x - sx) + Math.abs(p.y - sy) > 6) bb.beginDrag(ch.wid, "tray", ch.idx, p.x, p.y)
            } else if (bb.dragId === ch.wid) bb.moveDrag(p.x, p.y)
        }
        onReleased: m => { if (bb.dragId === ch.wid) bb.dropDrag() }
        onCanceled: bb.cancelDrag()
        onEntered: if (bb.dragId === "") bb.hint = BL.nameOf(ch.wid) + ": " + BL.hintOf(ch.wid)
        onExited: if (bb.dragId === "") bb.hint = ""
    }
}
