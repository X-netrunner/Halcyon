import QtQuick
import "WidgetData.js" as WD

// One desktop widget: the frame (the surface, the colours, the position) around a body (WClock, WMetric, WMusic ...).
//   Normal: it sits where the Desktop builder put it and the body works (buttons, scroll).
//   editing: a drag handle over it. Drag = move (snaps to the screen's middle and edges AND to the other widgets: lined up with
//            them, or one gap (snapGap px) beside / under them; hold Alt or Ctrl to move freely), the corner dot = resize (the top-left
//            corner stays put), the wheel = resize, arrow keys = nudge (DesktopEditor), a click picks it, a double click opens it in the
//            Widget builder.
// The look comes from item.look (WidgetData.js), the options from item.opts; the host turns them into the colours / fonts the body uses.
Item {
    id: host
    property var pal
    property var env                         // the shell: stats, net, player, focusState ... and the actions a widget can run
    property var item: null                   // { uid, type, px, py, scale, style, opts, look }
    property bool editing: false
    property bool selected: false
    property bool preview: false              // the Widget builder's big picture: no placement, sits at 0, 0
    property bool shown: true                 // the desktop can be seen (not covered by a full-screen app)
    property real screenW: 1920
    property real screenH: 1080
    property real margin: 24
    property real topInset: 24
    property real bottomInset: 24
    property real snapGap: 16                 // the space snapping leaves between two widgets
    property real gridSnap: 0                 // > 0: moving snaps to this grid (px), set by the desktop editor
    property var collect: null                // function(uid) -> [{ x, y, w, h }]: where the other widgets are (DeskWidgets)
    property var others: []
    property real pinX: 0
    property real pinY: 0
    // links (item.link, see WidgetData.js): DeskWidgets hands over the host this widget follows and the outer width the whole chain shares
    property var linkHost: null
    property real forceW: 0

    signal picked(string uid)
    signal dragMoved(real guideX, real guideY)    // -1 = no guide line on that axis
    signal dropped(string uid, real px, real py)
    signal rescaled(string uid, real s)
    signal toggleOffRequested(string uid)
    signal removeRequested(string uid)
    signal openRequested(string uid)

    readonly property string type: item ? item.type : ""
    readonly property string uid: item ? item.uid : ""
    readonly property string style: item ? WD.styleOf(item) : ""
    readonly property var look: WD.look(item ? item.look : null)
    readonly property var opts: {
        var t = WD.typeOf(type), o = {}
        if (t) for (var i = 0; i < t.opts.length; i++) o[t.opts[i].k] = t.opts[i].def
        if (item && item.opts) for (var k in item.opts) o[k] = item.opts[k]
        return o
    }

    // ---- what the body uses
    // look.contrast (0 .. 1, "Readability" in the Widget builder) lifts the lit colour toward white, brightens the quiet text,
    // and draws a soft outline round every letter, so it reads on a busy wallpaper (no box is ever drawn for "No box").
    // look.depth ("Colour depth") pours the accent into the box, the quiet text, the bars and the hairline.
    readonly property real boost: look.contrast
    readonly property real depth: look.depth
    readonly property color accentRaw: look.tone === "custom" ? look.color : (look.tone === "second" ? pal.accent2 : pal.accent)
    readonly property color accent: boost > 0 ? Qt.tint(accentRaw, Qt.rgba(1, 1, 1, 0.2 * boost)) : accentRaw
    readonly property color boxTint: Qt.alpha(accentRaw, 0.7 * depth)       // laid over the surface colour
    readonly property color fg: look.textTone === "custom" ? look.textColor
                                : (look.textTone === "light" ? "#ffffff" : (look.textTone === "dark" ? "#14151c" : Qt.tint(pal.text, Qt.alpha(accentRaw, 0.16 * depth))))
    readonly property color dim: (look.textTone === "custom" || look.textTone === "light" || look.textTone === "dark")
                                 ? Qt.alpha(fg, 0.62 + 0.26 * boost)
                                 : Qt.tint(Qt.tint(pal.muted, Qt.alpha(accentRaw, 0.5 * depth)), Qt.rgba(1, 1, 1, 0.3 * boost))
    readonly property color outlineColor: look.textTone === "dark" ? Qt.rgba(1, 1, 1, 0.45 * boost) : Qt.rgba(0, 0, 0, 0.55 * boost)
    readonly property color track: Qt.alpha(accentRaw, 0.14 + 0.2 * depth)
    readonly property string face: look.font === "mono" ? pal.mono : (look.font === "serif" ? pal.serifFont : pal.uiFont)
    readonly property string iconFont: pal.font
    readonly property real fs: look.fs
    readonly property bool live: visible && shown && !off

    // ---- size and place
    readonly property real pad: look.pad >= 0 ? look.pad : (look.surface === "clear" ? 4 : 14)
    // a linked widget takes its leader's size; the rest of the chain follows because the leader's k does
    readonly property bool linked: linkHost !== null && !preview
    readonly property string linkSide: item && item.linkSide === "above" ? "above" : "below"
    readonly property real linkGap: item && item.linkGap !== undefined ? Number(item.linkGap) : 14
    readonly property real k: resizing ? liveScale : (linked ? linkHost.k : (item ? item.scale : 1))
    readonly property bool off: item ? item.off === true : false          // switched off by you (the eye button / Widget builder): not drawn, nothing runs
    readonly property bool bodyHidden: off || (ld.item ? ld.item.hidden === true : false)
    property bool dragging: false
    property bool resizing: false
    property real dragX: 0
    property real dragY: 0
    property real liveScale: 1

    // natW = how wide it is on its own; linked widgets are all as wide as the widest of the chain (forceW)
    readonly property real natW: Math.max(24, ld.implicitWidth + pad * 2)
    width: Math.max(natW, forceW)
    height: Math.max(24, ld.implicitHeight + pad * 2)
    scale: k
    transformOrigin: Item.TopLeft
    readonly property real vw: width * k
    readonly property real vh: height * k
    // while the corner dot resizes, the top-left corner is pinned (the saved position is a fraction of the free room, which shrinks as the widget grows)
    // a linked widget sits straight above / below its leader (same left edge, same width), linkGap px away
    x: preview ? 0 : (linked ? linkHost.x : (dragging ? dragX : (resizing ? pinX : WD.posX(item || { px: 0 }, screenW, vw, margin))))
    y: preview ? 0 : (linked ? (linkSide === "above" ? linkHost.y - vh - linkGap : linkHost.y + linkHost.vh + linkGap)
                             : (dragging ? dragY : (resizing ? pinY : WD.posY(item || { py: 0 }, screenH, vh, topInset, bottomInset))))

    // move by dx, dy pixels (arrow keys)
    function nudge(dx, dy) {
        var lo = margin, hi = Math.max(lo, screenW - vw - margin)
        var tlo = topInset, thi = Math.max(tlo, screenH - vh - bottomInset)
        var nx = Math.max(lo, Math.min(hi, x + dx)), ny = Math.max(tlo, Math.min(thi, y + dy))
        dropped(uid, WD.fracX(nx, screenW, vw, margin), WD.fracY(ny, screenH, vh, topInset, bottomInset))
    }
    visible: item !== null && (!bodyHidden || editing || preview)
    opacity: (bodyHidden && editing) ? 0.4 : 1

    // ---- the surface
    readonly property real corner: look.surface === "pill" ? height / 2 : (look.radius >= 0 ? Math.min(look.radius, height / 2) : pal.rLg)
    Glass {
        visible: host.look.surface === "glass" || host.look.surface === "pill"
        anchors.fill: parent
        pal: host.pal
        radius: host.corner
        tint: host.boxTint
        opacityBody: host.look.op
        shadow: host.look.shadow
        border.width: host.look.border ? 1 : 0
        border.color: Qt.alpha(host.accent, 0.28 + 0.4 * host.depth)
    }
    Item {
        visible: host.look.surface === "solid"
        anchors.fill: parent
        Shadow { visible: host.look.shadow; z: -1; anchors.fill: parent; radius: host.corner }
        Rectangle {
            anchors.fill: parent
            radius: host.corner
            color: Qt.alpha(Qt.tint(host.pal.surface, host.boxTint), host.look.op)
            border.width: host.look.border ? 1 : 0
            border.color: Qt.alpha(host.accent, 0.28 + 0.4 * host.depth)
        }
    }
    Rectangle {
        visible: host.look.surface === "outline"
        anchors.fill: parent
        radius: host.corner
        color: Qt.alpha(Qt.tint(host.pal.bg, host.boxTint), Math.min(1, host.look.op * 0.5 + 0.16 * host.depth))
        border.width: host.look.border ? 1.5 : 0
        border.color: Qt.alpha(host.accent, 0.85)
    }
    // "No box" (surface "clear") draws nothing at all: the words sit straight on the wallpaper. Readability only lifts the colours
    // a little and outlines the letters; it never puts a dark box behind them.

    // ---- the body
    Loader {
        id: ld
        x: host.pad; y: host.pad
        width: Math.max(0, host.width - host.pad * 2)     // the body is as wide as the frame: a linked widget stretches to the shared width
        asynchronous: false
        function load() {
            if (!host.item) return
            setSource(Qt.resolvedUrl(WD.fileOf(host.type)), { w: host })
        }
        Component.onCompleted: load()
        Connections { target: host; function onTypeChanged() { ld.load() } }
    }

    // ---- editing chrome
    Rectangle {
        visible: host.editing
        anchors.fill: parent
        anchors.margins: -2
        radius: host.corner + 2
        color: host.selected ? Qt.alpha(host.pal.accent, 0.08) : "transparent"
        border.width: (host.selected ? 2 : 1) / Math.max(0.5, host.k)
        border.color: host.selected ? host.pal.accent : Qt.alpha(host.pal.text, 0.45)
    }
    MouseArea {
        id: grab
        z: 50
        anchors.fill: parent
        visible: host.editing
        enabled: host.editing
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: host.linked ? Qt.ArrowCursor : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
        property real pressX: 0                 // (was sx / sy: the `var sx` inside onPositionChanged shadowed them, so the move was NaN and nothing dragged)
        property real pressY: 0
        property real ox: 0
        property real oy: 0
        onPressed: m => {
            host.picked(host.uid)
            if (host.linked) return              // linked: it moves with its leader (drag the leader), a click still picks it
            var p = grab.mapToItem(host.parent, m.x, m.y)
            pressX = p.x; pressY = p.y; ox = host.x; oy = host.y
            host.others = host.collect ? host.collect(host.uid) : []
            host.dragX = ox; host.dragY = oy
            host.dragging = true
        }
        onPositionChanged: m => {
            if (!pressed || !host.dragging) return
            var p = grab.mapToItem(host.parent, m.x, m.y)
            var nx = ox + p.x - pressX, ny = oy + p.y - pressY
            var gx = -1, gy = -1
            var lo = host.margin, hi = host.screenW - host.vw - host.margin
            var tlo = host.topInset, thi = host.screenH - host.vh - host.bottomInset
            // Alt or Ctrl held = move freely, no snapping
            if ((m.modifiers & (Qt.AltModifier | Qt.ControlModifier)) === 0) {
                var xo = [], yo = []
                for (var i = 0; i < host.others.length; i++) {
                    var o = host.others[i]
                    xo.push({ p: o.x, s: o.w, near: ny < o.y + o.h + 40 && ny + host.vh > o.y - 40 })   // beside it only if level with it
                    yo.push({ p: o.y, s: o.h, near: nx < o.x + o.w + 40 && nx + host.vw > o.x - 40 })   // under it only if above / below it
                }
                // the grid first (when it is on), then the other widgets / the middle / the edges win when they are close
                if (host.gridSnap > 0) {
                    nx = host.margin + Math.round((nx - host.margin) / host.gridSnap) * host.gridSnap
                    ny = host.topInset + Math.round((ny - host.topInset) / host.gridSnap) * host.gridSnap
                }
                var snapX = WD.snapAxis(nx, host.vw, lo, hi, host.screenW, xo, host.snapGap, 10)
                var snapY = WD.snapAxis(ny, host.vh, tlo, thi, host.screenH, yo, host.snapGap, 10)
                if (snapX) { nx = snapX.pos; gx = snapX.guide }
                if (snapY) { ny = snapY.pos; gy = snapY.guide }
            }
            host.dragX = Math.max(lo, Math.min(Math.max(lo, hi), nx))
            host.dragY = Math.max(tlo, Math.min(Math.max(tlo, thi), ny))
            host.dragMoved(gx, gy)
        }
        onReleased: {
            if (!host.dragging) return
            host.dragging = false
            host.dragMoved(-1, -1)
            host.dropped(host.uid, WD.fracX(host.dragX, host.screenW, host.vw, host.margin), WD.fracY(host.dragY, host.screenH, host.vh, host.topInset, host.bottomInset))
        }
        onDoubleClicked: host.openRequested(host.uid)
        onWheel: wh => {
            var s = Math.max(0.5, Math.min(2.5, host.k + (wh.angleDelta.y > 0 ? 0.05 : -0.05)))
            host.rescaled(host.uid, Math.round(s * 100) / 100)
        }
    }

    // the corner dot: drag it to resize
    Rectangle {
        id: dot
        visible: host.editing && host.selected && !host.linked
        z: 60
        width: 16; height: 16; radius: 8
        x: host.width - 8; y: host.height - 8
        scale: 1 / Math.max(0.5, host.k)
        color: host.pal.accent
        border.width: 2
        border.color: host.pal.bg
        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            cursorShape: Qt.SizeFDiagCursor
            property real baseW: 1
            onPressed: { host.pinX = host.x; host.pinY = host.y; host.liveScale = host.k; host.resizing = true }
            onPositionChanged: m => {
                if (!pressed) return
                var p = mapToItem(host.parent, m.x, m.y)
                var s = (p.x - host.x) / Math.max(1, host.width)
                host.liveScale = Math.max(0.5, Math.min(2.5, Math.round(s * 20) / 20))
            }
            onReleased: { host.rescaled(host.uid, host.liveScale); host.resizing = false }
        }
    }

    // the name and the small buttons above a picked widget (kept the same size whatever the widget's size)
    Row {
        visible: host.editing && host.selected
        z: 60
        spacing: 6
        x: 0
        y: -(height + 8) / Math.max(0.5, host.k)
        scale: 1 / Math.max(0.5, host.k)
        transformOrigin: Item.TopLeft
        Rectangle {
            height: 26; width: nameT.implicitWidth + 20; radius: 13
            color: Qt.alpha(host.pal.bg, 0.92); border.width: 1; border.color: Qt.alpha(host.pal.accent, 0.6)
            Text { id: nameT; anchors.centerIn: parent; text: WD.nameOf(host.type) + (host.linked ? "  ·  linked to " + WD.nameOf(host.linkHost.type) : ""); color: host.pal.text; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.Medium }
        }
        Rectangle {
            height: 26; width: styleT.implicitWidth + 20; radius: 13
            color: Qt.alpha(host.pal.accent, 0.9)
            Text { id: styleT; anchors.centerIn: parent; text: "Style and look"; color: host.pal.bg; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.DemiBold }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: host.openRequested(host.uid) }
        }
        Rectangle {
            height: 26; width: offT.implicitWidth + 20; radius: 13
            color: host.off ? Qt.alpha(host.pal.warn, 0.92) : Qt.alpha(host.pal.bg, 0.92)
            border.width: 1; border.color: Qt.alpha(host.pal.text, 0.35)
            Text { id: offT; anchors.centerIn: parent; text: host.off ? "Switch on" : "Switch off"; color: host.off ? host.pal.bg : host.pal.text; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.Medium }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: host.toggleOffRequested(host.uid) }
        }
        Rectangle {
            height: 26; width: 26; radius: 13
            color: Qt.alpha(host.pal.bad, 0.9)
            Text { anchors.centerIn: parent; text: "✕"; color: host.pal.bg; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.Bold }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: host.removeRequested(host.uid) }
        }
    }
}
