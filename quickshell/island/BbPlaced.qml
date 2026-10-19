import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "BarLayout.js" as BL

// Part of the bar builder window (BarBuilderWindow.qml). `bb` is that window.
Item {
    required property var bb
    id: sl
    property string wid: ""
    property string zone: "left"
    property int idx: 0
    readonly property real pad: BL.padOf(bb.cur, wid)
    readonly property bool carried: bb.dragId === wid
    readonly property bool hot: sma.containsMouse && bb.dragId === ""
    readonly property bool picked: bb.sel === wid
    height: bb.barH
    width: mw.width + pad * 2
    opacity: carried ? 0.25 : 1
    Behavior on opacity { NumberAnimation { duration: bb.pal.dFast } }

    // the box of the widget with its padding
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2
        anchors.bottomMargin: 2
        radius: 6
        color: sl.picked ? Qt.alpha(bb.pal.accent, 0.16) : (sl.hot ? Qt.alpha(bb.pal.accent, 0.10) : "transparent")
        border.width: (sl.picked || sl.hot) ? 1 : 0
        border.color: Qt.alpha(bb.pal.accent, sl.picked ? 0.9 : 0.5)
        Behavior on color { ColorAnimation { duration: bb.pal.dFast } }
    }
    // the widget itself (same drawing as MockW, written out here: an inline component can't use another inline component)
    Item {
        id: mw
        x: sl.pad
        height: bb.barH
        width: mld.item ? mld.item.implicitWidth : 0
        Loader { id: mld; height: bb.barH; sourceComponent: bb.mockFor(sl.wid) }
    }

    MouseArea {
        id: sma
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: bb.dragId !== "" ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real sx: 0
        property real sy: 0
        onPressed: m => { var p = mapToItem(bb, m.x, m.y); sx = p.x; sy = p.y }
        onPositionChanged: m => {
            if (!pressed || !(pressedButtons & Qt.LeftButton)) return
            var p = mapToItem(bb, m.x, m.y)
            if (bb.dragId === "") {
                if (Math.abs(p.x - sx) + Math.abs(p.y - sy) > 6) bb.beginDrag(sl.wid, sl.zone, sl.idx, p.x, p.y)
            } else if (bb.dragId === sl.wid) bb.moveDrag(p.x, p.y)
        }
        onReleased: m => { if (bb.dragId === sl.wid) bb.dropDrag() }
        onCanceled: bb.cancelDrag()
        onClicked: m => {
            if (m.button === Qt.RightButton) bb.edited(BL.remove(bb.cur, sl.wid))
            else bb.selId = (bb.sel === sl.wid ? "" : sl.wid)
        }
        onEntered: if (bb.dragId === "") bb.hint = BL.nameOf(sl.wid) + ": " + BL.hintOf(sl.wid)
        onExited: if (bb.dragId === "") bb.hint = ""
    }
    // × takes it off the bar
    Rectangle {
        visible: (sl.hot || sl.picked) && bb.dragId === ""
        anchors.right: parent.right
        anchors.top: parent.top
        width: 12; height: 12; radius: 6
        color: xma.containsMouse ? bb.pal.accent : Qt.alpha(bb.pal.surfaceHi, 0.95)
        Text { anchors.centerIn: parent; text: "×"; color: xma.containsMouse ? bb.pal.bg : bb.pal.text; font.family: bb.pal.uiFont; font.pixelSize: 10 }
        MouseArea { id: xma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: bb.edited(BL.remove(bb.cur, sl.wid)) }
    }
}
