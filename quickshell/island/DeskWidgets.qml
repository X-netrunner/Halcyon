import QtQuick
import "WidgetData.js" as WD

// All the desktop widgets, drawn over the wallpaper (Wallpaper.qml) and, with `editing`, over the screen while you place them
// (DesktopEditor.qml). The layout is opt.deskWidgets; this only draws it and reports what you changed (commit).
//   layout    the clean layout          uids   the widget ids in drawing order (the Repeater only rebuilds when this list changes,
//                                                so a slider in the Widget builder never restarts the widgets)
Item {
    id: root
    property var pal
    property var env
    property var opt: ({})
    property bool editing: false
    property string selected: ""
    property bool shown: true
    property real topInset: 24
    property real bottomInset: 24
    property real margin: 24

    // the editor's helpers (DesktopEditor.qml sets these; the live desktop never draws them)
    property bool showGrid: false
    property int gridSize: 40
    property bool snapGrid: false
    property bool showCenter: false
    property bool showThirds: false
    property bool showSafe: false
    property bool showMeasure: false

    signal commit(var data)               // the layout changed (moved, resized, removed)
    signal selectedRequested(string uid)
    signal openRequested(string uid)

    readonly property var layout: WD.normalize(opt ? opt.deskWidgets : null)
    property var uids: []
    function syncUids() {
        var u = []
        for (var i = 0; i < layout.items.length; i++) u.push(layout.items[i].uid)
        if (u.join("|") !== uids.join("|")) uids = u
    }
    onLayoutChanged: syncUids()
    Component.onCompleted: syncUids()

    property real guideX: -1
    property real guideY: -1

    // where the other widgets are (for snapping), and moving one by a few pixels (arrow keys)
    function rectsExcept(uid) {
        var out = []
        for (var i = 0; i < rep.count; i++) {
            var h = rep.itemAt(i)
            if (h && h.uid !== uid && h.visible) out.push({ x: h.x, y: h.y, w: h.vw, h: h.vh })
        }
        return out
    }
    // the host of the picked widget (the guides measure it); refreshed when the pick or the set of widgets changes
    property var selHost: null
    function pickHost() {
        var f = null
        if (editing && selected !== "") for (var i = 0; i < rep.count; i++) { var h = rep.itemAt(i); if (h && h.uid === selected) { f = h; break } }
        if (f !== selHost) selHost = f
    }
    onSelectedChanged: pickHost()
    onEditingChanged: pickHost()
    function nudge(uid, dx, dy) {
        for (var i = 0; i < rep.count; i++) { var h = rep.itemAt(i); if (h && h.uid === uid) { h.nudge(dx, dy); return } }
    }

    Repeater {
        id: rep
        model: root.uids
        onItemAdded: Qt.callLater(root.pickHost)
        onItemRemoved: Qt.callLater(root.pickHost)
        delegate: WidgetHost {
            id: dw
            required property string modelData
            pal: root.pal
            env: root.env
            item: WD.find(root.layout, modelData)
            editing: root.editing
            selected: root.editing && root.selected === modelData
            shown: root.shown
            screenW: root.width
            screenH: root.height
            margin: root.margin
            topInset: root.topInset
            bottomInset: root.bottomInset
            collect: root.rectsExcept
            gridSnap: root.editing && root.snapGrid ? root.gridSize : 0
            z: selected ? 1000 : 1
            onPicked: uid => root.selectedRequested(uid)
            onDragMoved: (gx, gy) => { root.guideX = gx; root.guideY = gy }
            onDropped: (uid, px, py) => root.commit(WD.setPos(root.layout, uid, px, py))
            // resizing keeps the top-left corner where it is (the position is stored relative to the room left, which changes with the size)
            onRescaled: (uid, s) => root.commit(WD.setScalePos(root.layout, uid, s,
                WD.fracX(dw.x, root.width, dw.width * s, root.margin),
                WD.fracY(dw.y, root.height, dw.height * s, root.topInset, root.bottomInset)))
            onRemoveRequested: uid => root.commit(WD.remove(root.layout, uid))
            onToggleOffRequested: uid => root.commit(WD.setOff(root.layout, uid, !WD.isOff(WD.find(root.layout, uid))))
            onOpenRequested: uid => root.openRequested(uid)
        }
    }

    // grid, centre, thirds and the gaps / size of the picked widget (editing only)
    DeskGuides {                          // below the widgets: grid, centre, thirds, safe area
        anchors.fill: parent
        visible: root.editing
        z: 0
        pal: root.pal
        showGrid: root.showGrid; gridSize: root.gridSize
        showCenter: root.showCenter; showThirds: root.showThirds; showSafe: root.showSafe; showMeasure: false
        margin: root.margin; topInset: root.topInset; bottomInset: root.bottomInset
    }
    DeskGuides {                          // above them: the gaps and size of the picked widget
        anchors.fill: parent
        visible: root.editing && root.showMeasure
        z: 1500
        measureOnly: true
        pal: root.pal
        showGrid: root.showGrid; gridSize: root.gridSize
        showCenter: root.showCenter; showThirds: root.showThirds; showSafe: root.showSafe; showMeasure: root.showMeasure
        margin: root.margin; topInset: root.topInset; bottomInset: root.bottomInset
        target: root.selHost
        collect: root.rectsExcept
    }

    // snap guides while dragging
    Rectangle { visible: root.editing && root.guideX >= 0; x: root.guideX - 0.5; y: 0; width: 1; height: root.height; color: root.pal ? root.pal.accent : "white"; opacity: 0.8; z: 2000 }
    Rectangle { visible: root.editing && root.guideY >= 0; y: root.guideY - 0.5; x: 0; height: 1; width: root.width; color: root.pal ? root.pal.accent : "white"; opacity: 0.8; z: 2000 }
}
