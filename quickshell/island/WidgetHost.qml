import QtQuick
import "WidgetData.js" as WD

// One desktop widget: the frame (the surface, the colours, the position) around a body (WClock, WMetric, WMusic ...).
//   Normal: it sits where the Desktop builder put it and the body works (buttons, scroll).
//   editing: a drag handle over it. Drag = move (snaps to the screen's middle and edges), the corner dot = resize, the wheel = resize,
//            a click picks it, a double click opens it in the Widget builder.
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

    signal picked(string uid)
    signal dragMoved(real guideX, real guideY)    // -1 = no guide line on that axis
    signal dropped(string uid, real px, real py)
    signal rescaled(string uid, real s)
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
    readonly property color accent: look.tone === "custom" ? look.color : (look.tone === "second" ? pal.accent2 : pal.accent)
    readonly property color fg: look.textTone === "custom" ? look.textColor : pal.text
    readonly property color dim: look.textTone === "custom" ? Qt.alpha(look.textColor, 0.62) : pal.muted
    readonly property color track: Qt.alpha(fg, 0.14)
    readonly property string face: look.font === "mono" ? pal.mono : pal.uiFont
    readonly property string iconFont: pal.font
    readonly property real fs: look.fs
    readonly property bool live: visible && shown

    // ---- size and place
    readonly property real pad: look.pad >= 0 ? look.pad : (look.surface === "clear" ? 4 : 14)
    readonly property real k: resizing ? liveScale : (item ? item.scale : 1)
    readonly property bool bodyHidden: ld.item ? ld.item.hidden === true : false
    property bool dragging: false
    property bool resizing: false
    property real dragX: 0
    property real dragY: 0
    property real liveScale: 1

    width: Math.max(24, ld.implicitWidth + pad * 2)
    height: Math.max(24, ld.implicitHeight + pad * 2)
    scale: k
    transformOrigin: Item.TopLeft
    readonly property real vw: width * k
    readonly property real vh: height * k
    x: preview ? 0 : (dragging ? dragX : WD.posX(item || { px: 0 }, screenW, vw, margin))
    y: preview ? 0 : (dragging ? dragY : WD.posY(item || { py: 0 }, screenH, vh, topInset, bottomInset))
    visible: item !== null && (!bodyHidden || editing || preview)
    opacity: (bodyHidden && editing) ? 0.4 : 1

    // ---- the surface
    readonly property real corner: look.surface === "pill" ? height / 2 : (look.radius >= 0 ? Math.min(look.radius, height / 2) : pal.rLg)
    Glass {
        visible: host.look.surface === "glass" || host.look.surface === "pill"
        anchors.fill: parent
        pal: host.pal
        radius: host.corner
        opacityBody: host.look.op
        shadow: host.look.shadow
        border.width: host.look.border ? 1 : 0
        border.color: Qt.alpha(host.accent, 0.28)
    }
    Item {
        visible: host.look.surface === "solid"
        anchors.fill: parent
        Shadow { visible: host.look.shadow; z: -1; anchors.fill: parent; radius: host.corner }
        Rectangle {
            anchors.fill: parent
            radius: host.corner
            color: Qt.alpha(host.pal.surface, host.look.op)
            border.width: host.look.border ? 1 : 0
            border.color: Qt.alpha(host.accent, 0.28)
        }
    }
    Rectangle {
        visible: host.look.surface === "outline"
        anchors.fill: parent
        radius: host.corner
        color: Qt.alpha(host.pal.bg, host.look.op * 0.5)
        border.width: host.look.border ? 1.5 : 0
        border.color: Qt.alpha(host.accent, 0.85)
    }
    // "No box": a soft glow behind light text keeps it readable on a bright wallpaper
    Rectangle {
        visible: host.look.surface === "clear" && host.look.shadow
        anchors.fill: parent
        anchors.margins: -10
        radius: 24
        color: Qt.alpha("black", 0.10)
    }

    // ---- the body
    Loader {
        id: ld
        x: host.pad; y: host.pad
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
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real sx: 0
        property real sy: 0
        property real ox: 0
        property real oy: 0
        onPressed: m => {
            host.picked(host.uid)
            var p = grab.mapToItem(host.parent, m.x, m.y)
            sx = p.x; sy = p.y; ox = host.x; oy = host.y
            host.dragX = ox; host.dragY = oy
            host.dragging = true
        }
        onPositionChanged: m => {
            if (!pressed || !host.dragging) return
            var p = grab.mapToItem(host.parent, m.x, m.y)
            var nx = ox + p.x - sx, ny = oy + p.y - sy
            var gx = -1, gy = -1
            var lo = host.margin, hi = host.screenW - host.vw - host.margin
            var cx = (host.screenW - host.vw) / 2
            if (Math.abs(nx - cx) < 12) { nx = cx; gx = host.screenW / 2 }
            else if (Math.abs(nx - lo) < 12) { nx = lo; gx = lo }
            else if (Math.abs(nx - hi) < 12) { nx = hi; gx = hi + host.vw }
            var tlo = host.topInset, thi = host.screenH - host.vh - host.bottomInset
            var cy = (host.screenH - host.vh) / 2
            if (Math.abs(ny - cy) < 12) { ny = cy; gy = host.screenH / 2 }
            else if (Math.abs(ny - tlo) < 12) { ny = tlo; gy = tlo }
            else if (Math.abs(ny - thi) < 12) { ny = thi; gy = thi + host.vh }
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
        visible: host.editing && host.selected
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
            onPressed: { host.liveScale = host.k; host.resizing = true }
            onPositionChanged: m => {
                if (!pressed) return
                var p = mapToItem(host.parent, m.x, m.y)
                var s = (p.x - host.x) / Math.max(1, host.width)
                host.liveScale = Math.max(0.5, Math.min(2.5, Math.round(s * 20) / 20))
            }
            onReleased: { host.resizing = false; host.rescaled(host.uid, host.liveScale) }
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
            Text { id: nameT; anchors.centerIn: parent; text: WD.nameOf(host.type); color: host.pal.text; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.Medium }
        }
        Rectangle {
            height: 26; width: styleT.implicitWidth + 20; radius: 13
            color: Qt.alpha(host.pal.accent, 0.9)
            Text { id: styleT; anchors.centerIn: parent; text: "Style and look"; color: host.pal.bg; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.DemiBold }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: host.openRequested(host.uid) }
        }
        Rectangle {
            height: 26; width: 26; radius: 13
            color: Qt.alpha(host.pal.bad, 0.9)
            Text { anchors.centerIn: parent; text: "✕"; color: host.pal.bg; font.family: host.pal.uiFont; font.pixelSize: 12; font.weight: Font.Bold }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: host.removeRequested(host.uid) }
        }
    }
}
