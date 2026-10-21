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
    property string target: "desktop"      // "desktop" or "lock": which list is drawn (opt.deskWidgets / opt.lockDeskWidgets; on the lock screen every widget is inert)
    property bool inert: false              // the lock screen: nothing can be clicked (WidgetHost's click shield)
    property real lockLum: -1               // the lock screen's background brightness, for the readability colours (WidgetHost.lockLum)
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

    // opt is replaced by every setting that changes anywhere; the layout is only rebuilt (and every widget re-bound) when the saved
    // widgets themselves changed
    property var layout: ({ items: [] })
    property string layoutKey: "\u0000"
    function refreshLayout() {
        var raw = opt ? opt[WD.keyOf(target)] : null
        var key = raw ? JSON.stringify(raw) : ""
        if (key === layoutKey) return
        layoutKey = key
        layout = WD.normalizeFor(raw, target)
    }
    onOptChanged: refreshLayout()
    onTargetChanged: { layoutKey = "\u0000"; refreshLayout() }
    readonly property bool anyLinks: { for (var i = 0; i < layout.items.length; i++) if (layout.items[i].link) return true; return false }
    property var uids: []
    function syncUids() {
        var u = []
        for (var i = 0; i < layout.items.length; i++) u.push(layout.items[i].uid)
        if (u.join("|") !== uids.join("|")) uids = u
    }
    onLayoutChanged: { syncUids(); Qt.callLater(applyGroupW) }
    Component.onCompleted: { refreshLayout(); syncUids() }

    property real guideX: -1
    property real guideY: -1

    // links (WidgetData.js: item.link): `tick` is bumped whenever a widget's own width or visibility changes, so the shared width and
    // the "who do I follow" bindings below are worked out again (the Repeater's items are not something a binding can watch)
    property int tick: 0
    function hostOf(uid) {
        for (var i = 0; i < rep.count; i++) { var h = rep.itemAt(i); if (h && h.uid === uid) return h }
        return null
    }
    // the widget this one sits next to: its leader, or (when several widgets follow the same leader on the same side) the one
    // before it in that line, so they line up one after the other instead of lying on top of each other
    function linkHostOf(uid, t) {
        if (!anyLinks) return null
        var l = WD.leaderOf(layout, uid)
        if (l === "") return null
        var me = WD.find(layout, uid)
        var sib = WD.siblings(layout, l, WD.sideOf(me ? me.linkSide : ""))
        for (var j = sib.indexOf(uid) - 1; j >= 0; j--) {
            var h = hostOf(sib[j])
            if (h && !h.bodyHidden) return h
        }
        return hostOf(l)
    }
    // the first widget of the chain this one belongs to (the widget itself when nothing is linked): that is the one a drag really moves
    function chainRootOf(uid, t) {
        if (!anyLinks) return hostOf(uid)
        return hostOf(WD.linkRoot(layout, uid))
    }
    // how far the widgets linked to `uid` reach beyond it to the LEFT ("l") or RIGHT ("r"), gap included, followers of followers too. The first
    // widget of a chain is kept that far from the screen edge, so a linked widget that gets wider (uptime "9h" -> "2h 59m", linked on the
    // left) pushes the chain to the right instead of growing off the screen.
    function chainExt(uid, side, t, depth) {
        if (!anyLinks || (depth || 0) > 8) return 0
        var m = 0, sum = 0
        for (var i = 0; i < layout.items.length; i++) {
            var f = layout.items[i]
            if (f.link !== uid) continue
            var h = hostOf(f.uid)
            if (!h || h.bodyHidden) continue
            var sd = WD.sideOf(f.linkSide), gap = f.linkGap !== undefined ? Number(f.linkGap) : 14
            var inner = chainExt(f.uid, side, t, (depth || 0) + 1)
            // several followers on the same side stand in a row, so their widths add up
            if (sd === "left") { if (side === "l") sum += h.vw + gap + inner }
            else if (sd === "right") { if (side === "r") sum += h.vw + gap + inner }
            else m = Math.max(m, inner)               // stacked above / below: same left edge, same width
        }
        return Math.max(m, sum)
    }
    // the outer width every widget stacked with this one (above / below links) shares: the widest of them (0 = nothing is forced; side-by-side links never force a width)
    // A member that is only hidden for now (a visualizer while nothing plays, "hide when idle") still counts: the others keep their width and
    // their place instead of shrinking to their own text and jumping to the left edge every time the music stops. Only a widget you switched OFF drops out.
    // a linked chain is as wide as its widest member. Set from here after a change (not a binding: a member's natural width can
    // depend on its own width when its text wraps, and the binding fed on itself, "Binding loop detected for property forceW")
    onTickChanged: Qt.callLater(applyGroupW)
    onAnyLinksChanged: Qt.callLater(applyGroupW)
    function applyGroupW() {
        for (var i = 0; i < rep.count; i++) {
            var h = rep.itemAt(i)
            if (!h) continue
            var w = groupW(h.uid, tick)
            if (Math.abs(w - h.forceW) > 0.5) h.forceW = w
        }
    }
    function groupW(uid, t) {
        if (!anyLinks) return 0
        var g = WD.widthGroup(layout, uid)
        if (g.length < 2) return 0
        var m = 0
        for (var i = 0; i < g.length; i++) {
            var h = hostOf(g[i])
            if (h && (g[i] === uid || !h.off)) m = Math.max(m, h.natW)
        }
        return m
    }

    // where the other widgets are (for snapping), and moving one by a few pixels (arrow keys); the widgets linked to the moving one
    // are not "others": they travel with it
    function rectsExcept(uid) {
        var out = [], mine = WD.linkGroup(layout, uid)
        for (var i = 0; i < rep.count; i++) {
            var h = rep.itemAt(i)
            if (h && mine.indexOf(h.uid) < 0 && h.visible) out.push({ x: h.x, y: h.y, w: h.vw, h: h.vh })
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
        var h = hostOf(WD.linkRoot(layout, uid))      // a linked widget is moved through its leader
        if (h) h.nudge(dx, dy)
    }

    Repeater {
        id: rep
        model: root.uids
        onItemAdded: { Qt.callLater(root.pickHost); root.tick++ }
        onItemRemoved: { Qt.callLater(root.pickHost); root.tick++ }
        delegate: WidgetHost {
            id: dw
            required property string modelData
            pal: root.pal
            env: root.env
            item: WD.find(root.layout, modelData)
            editing: root.editing
            selected: root.editing && root.selected === modelData
            shown: root.shown
            inert: root.inert
            lockLum: root.lockLum
            screenW: root.width
            screenH: root.height
            margin: root.margin
            topInset: root.topInset
            bottomInset: root.bottomInset
            collect: root.rectsExcept
            linkHost: root.linkHostOf(modelData, root.tick)
            extL: root.chainExt(modelData, "l", root.tick)
            extR: root.chainExt(modelData, "r", root.tick)
            chainRoot: root.chainRootOf(modelData, root.tick)
            onNatWChanged: if (root.anyLinks) root.tick++
            onBodyHiddenChanged: if (root.anyLinks) root.tick++
            gridSnap: root.editing && root.snapGrid ? root.gridSize : 0
            z: selected ? 1000 : 1
            onPicked: uid => root.selectedRequested(uid)
            onDragMoved: (gx, gy) => { root.guideX = gx; root.guideY = gy }
            onDropped: (uid, px, py) => root.commit(WD.setPos(root.layout, uid, px, py))
            // resizing keeps the top-left corner where it is (the position is stored relative to the room left, which changes with the size)
            // (a linked widget resizes through the first widget of its chain: they all share one size)
            onRescaled: (uid, s) => {
                var ru = WD.linkRoot(root.layout, uid), rh = root.hostOf(ru) || dw
                // the position belongs to the whole chain (WidgetHost.chainW): keep its left edge where it is
                var f = s / Math.max(0.01, rh.k)
                root.commit(WD.setScalePos(root.layout, ru, s,
                    WD.fracX(rh.x - rh.extL, root.width, rh.chainW * f, root.margin),
                    WD.fracY(rh.y, root.height, rh.height * s, root.topInset, root.bottomInset)))
            }
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
