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
    property bool inert: false                // the lock screen: a click shield sits over the body, so nothing in it can be clicked or scrolled (a type in WD.lockButtons keeps its buttons)
    property real lockLum: -1                 // >= 0: this widget is on the lock screen, whose background is this bright (linear 0 .. 1): the blurred wallpaper under its tint sheet, or the plain theme colour
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
    property real extL: 0                     // room the widgets linked on this chain's LEFT need (DeskWidgets.chainExt): the chain root never sits closer to the edge
    property real extR: 0                     // ... and on its right
    function chainX(v) { return Math.max(margin + extL, Math.min(v, screenW - margin - vw - extR)) }
    // The saved position (px) belongs to the WHOLE chain (followers on the left / right included), not to this widget alone:
    // the chain's left edge sits at  margin + px * (free room left over by the chain).  So when a follower gets wider (uptime
    // "9m" -> "2h 59m") the chain grows from its own edge and pushes this widget along, and when it gets narrower again
    // (uptime back to "0m") everything returns to exactly where you left it. Before, px was relative to this widget only, so
    // every width change of a follower slid the whole chain and it never came back.
    readonly property real chainW: extL + vw + extR
    property var chainRoot: null              // the first widget of the chain this one belongs to (itself when it is not linked): dragging ANY widget of the chain drags that one, and the rest follow

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
    // Settings > Widget builder: one halo switch and one readability offset for every widget (the shell's opt)
    readonly property var gOpt: (env && env.opt) ? env.opt : ({})
    readonly property real boost: Math.max(0, Math.min(1, look.contrast + Number(gOpt.widgetReadability || 0) / 100))
    // look.match ("Match wallpaper accent"): the lit colour, the text and the box all follow the wallpaper accent, whatever the colour pickers say
    readonly property bool match: look.match === true
    readonly property string toneEff: match ? "theme" : look.tone
    readonly property string textToneEff: match ? "theme" : look.textTone
    readonly property real depth: match ? Math.max(look.depth, 0.6) : look.depth
    // ---- bright wallpaper: when the picture right behind this widget is bright (and the widget has no dark box of its own),
    // the theme text would be pale on pale. Then the text, the lit colour and the bars turn DARK but keep the wallpaper's accent hue,
    // with a light halo, so they read on any wallpaper. Only for the "Theme" text colour: a colour you picked yourself stays as you set it.
    readonly property real bodyOp: (look.surface === "clear" || look.surface === "outline") ? 0 : look.op
    // the patch of wallpaper behind this widget (screen fractions); the preview in the builder looks at the whole picture
    readonly property real fX: preview ? 0 : x / Math.max(1, screenW)
    readonly property real fY: preview ? 0 : y / Math.max(1, screenH)
    readonly property real fW: preview ? 1 : vw / Math.max(1, screenW)
    readonly property real fH: preview ? 1 : vh / Math.max(1, screenH)
    // on the lock screen the wallpaper is blurred (an even patch) and under a tint sheet, so the patch behind a widget is one even brightness (lockLum), not the desktop picture
    readonly property bool onLockBg: lockLum >= 0
    readonly property real backLum: onLockBg ? lockLum : (pal ? pal.lumAt(fX, fY, fW, fH) : 0.1)
    readonly property real backSpread: onLockBg ? 0 : (pal ? pal.lumSpreadAt(fX, fY, fW, fH) : 0)
    readonly property real backMax: onLockBg ? lockLum : (pal ? pal.lumMaxAt(fX, fY, fW, fH) : 0.1)
    readonly property real effLum: backLum * (1 - bodyOp) + 0.012 * bodyOp     // linear luminance seen through the box (a dark glass box is ~0.012)
    readonly property bool themed: textToneEff === "theme"
    // 1) an evenly BRIGHT patch: dark, accent-tinted text.   0.18 is where black text starts to beat white on contrast
    readonly property bool autoTone: textToneEff === "auto"
    readonly property bool onBright: (themed || autoTone) && effLum > 0.45 && backSpread < 0.1
    // 2) a MIXED patch (pink next to black ...): neither colour reads on all of it, so light text with a strong dark outline, like subtitles
    readonly property bool onMixed: themed && !onBright && bodyOp < 0.5 && backMax > 0.2 && (backSpread >= 0.15 || effLum > 0.2)
    readonly property color accentRaw: toneEff === "custom" ? look.color : (toneEff === "second" ? pal.accent2 : pal.accent)
    readonly property color accentInk: Qt.hsla(Math.max(0, accentRaw.hslHue), Math.min(1, Math.max(0.55, accentRaw.hslSaturation)), 0.22, 1)   // the accent, darkened to read on light
    readonly property color accentSoft: autoPair[0]      // light, coloured, and different from what is behind it: bars / dots on a busy patch
    readonly property color accent: onBright && toneEff !== "custom" ? accentInk
                                    : ((onMixed || autoTone) && toneEff !== "custom" ? accentSoft
                                       : (boost > 0 ? Qt.tint(accentRaw, Qt.rgba(1, 1, 1, 0.2 * boost)) : accentRaw))
    // the accent as readable LIGHT text that keeps its hue (the old "washed towards white" turned every colour into white on a busy wallpaper)
    readonly property color accentRawB: pal.accent2
    // (the same colour the terminal prompt gets: the accent's own hue and saturation, lifted to at least 62 % lightness so it reads)
    readonly property color vividA: Qt.hsla(Math.max(0, accentRaw.hslHue), Math.min(1, Math.max(0.65, accentRaw.hslSaturation)), Math.max(0.62, accentRaw.hslLightness), 1)
    readonly property color vividB: Qt.hsla(Math.max(0, accentRawB.hslHue), Math.min(1, Math.max(0.65, accentRawB.hslSaturation)), Math.max(0.62, accentRawB.hslLightness), 1)
    // ---- "Auto" text colour: of the wallpaper's own colours (accent, second colour, every swatch) plus white, take the one that stands out
    // best from what is right behind THIS widget: enough contrast against the brightest part of the patch, and a hue far from the
    // patch's own (pink text on a cyan corner, cyan on a pink one). [0] = the main colour, [1] = a second one for the quiet text.
    readonly property var backRgb: (pal && !onLockBg) ? pal.colorAt(fX, fY, fW, fH) : null
    function relLum(c) {
        function l(x) { return x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * l(c.r) + 0.7152 * l(c.g) + 0.0722 * l(c.b)
    }
    readonly property var autoPair: {
        var cands = [vividA, vividB]
        var sw = (pal && pal.swatches) ? pal.swatches : []
        for (var i = 0; i < sw.length && i < 6; i++) {
            var q = Qt.color(sw[i])
            cands.push(Qt.hsla(Math.max(0, q.hslHue), Math.min(1, Math.max(0.65, q.hslSaturation)), Math.max(0.62, q.hslLightness), 1))
        }
        cands.push(Qt.color("#ffffff"))
        var rgb = backRgb, bHue = -1, bSat = 0
        if (rgb) { var bc = Qt.rgba(rgb[0], rgb[1], rgb[2], 1); bHue = bc.hslHue; bSat = bc.hslSaturation }
        var sc = []
        for (var j = 0; j < cands.length; j++) {
            var c = cands[j]
            var contrast = (relLum(c) + 0.05) / (backMax + 0.05)
            var sep = 0
            if (bHue >= 0 && c.hslHue >= 0) { var d = Math.abs(c.hslHue - bHue); if (d > 0.5) d = 1 - d; sep = Math.min(1, d * 2.2) * Math.min(1, bSat * 1.8) }
            sc.push({ c: c, h: c.hslHue, s: Math.min(contrast, 6) / 6 + 0.9 * sep + (j < 2 ? 0.1 : 0) - (contrast < 2.2 ? 1 : 0) })
        }
        sc.sort(function (a, b) { return b.s - a.s })
        var first = sc[0], second = sc.length > 1 ? sc[1] : sc[0]
        for (var m = 1; m < sc.length; m++) {
            var dh = Math.abs(sc[m].h - first.h); if (dh > 0.5) dh = 1 - dh
            if (dh >= 0.07) { second = sc[m]; break }
        }
        return [first.c, second.c]
    }
    readonly property color boxTint: Qt.alpha(accentRaw, 0.7 * depth)       // laid over the surface colour
    readonly property color fg: textToneEff === "custom" ? look.textColor
                                : (textToneEff === "light" ? "#ffffff" : (textToneEff === "dark" ? "#14151c"
                                   : (textToneEff === "accent" || textToneEff === "split" ? vividA : (textToneEff === "second" ? vividB
                                   : (onBright ? Qt.hsla(Math.max(0, accentRaw.hslHue), Math.min(0.7, accentRaw.hslSaturation), 0.10, 1)
                                      : ((onMixed || autoTone) ? autoPair[0]
                                                 : Qt.tint(pal.text, Qt.alpha(accentRaw, match ? 0.55 : 0.4 * depth))))))))
    readonly property color dim: (textToneEff === "split") ? Qt.alpha(vividB, 0.9)
                                 : ((textToneEff === "custom" || textToneEff === "light" || textToneEff === "dark" || textToneEff === "accent" || textToneEff === "second")
                                 ? Qt.alpha(fg, 0.62 + 0.26 * boost)
                                 : (onBright ? Qt.alpha(accentInk, 0.82 + 0.16 * boost)
                                    : ((onMixed || autoTone) ? Qt.alpha(autoPair[1], 0.92)
                                               : Qt.tint(Qt.tint(pal.muted, Qt.alpha(accentRaw, 0.5 * depth)), Qt.rgba(1, 1, 1, 0.3 * boost)))))
    readonly property color outlineColor: (onMixed || (autoTone && !onBright)) ? Qt.rgba(0, 0, 0, 0.9)
                                          : ((textToneEff === "dark" || onBright) ? Qt.rgba(1, 1, 1, 0.45 * Math.max(boost, onBright ? 0.7 : 0)) : Qt.rgba(0, 0, 0, 0.55 * boost))
    readonly property color track: onMixed ? Qt.alpha(accentSoft, 0.4) : Qt.alpha(onBright ? accentInk : accentRaw, 0.14 + 0.2 * depth)
    readonly property string face: look.font === "mono" ? pal.mono : (look.font === "serif" ? pal.serifFont : pal.uiFont)
    readonly property string iconFont: pal.font
    readonly property real fs: look.fs
    readonly property bool live: visible && shown && !off

    // ---- size and place
    readonly property real pad: look.pad >= 0 ? look.pad : (look.surface === "clear" ? 4 : 14)
    // a linked widget takes its leader's size; the rest of the chain follows because the leader's k does
    readonly property bool linked: linkHost !== null && !preview
    readonly property string linkSide: item ? WD.sideOf(item.linkSide) : "below"
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
    // a linked widget sits linkGap px from its leader: straight above / below it (same left edge, same width), or beside it
    // (left / right, centred on it; its leader's width counts, so when the leader grows this one is pushed along, never overlapped)
    x: preview ? 0 : (linked ? (linkSide === "right" ? linkHost.x + linkHost.vw + linkGap
                                : (linkSide === "left" ? linkHost.x - vw - linkGap : linkHost.x))
                             : (dragging ? dragX : (resizing ? pinX + extL : chainX(WD.posX(item || { px: 0 }, screenW, chainW, margin) + extL))))
    y: preview ? 0 : (linked ? (linkSide === "above" ? linkHost.y - vh - linkGap
                                : (linkSide === "below" ? linkHost.y + linkHost.vh + linkGap
                                   : linkHost.y + (linkHost.vh - vh) / 2))
                             : (dragging ? dragY : (resizing ? pinY : WD.posY(item || { py: 0 }, screenH, vh, topInset, bottomInset))))

    // move by dx, dy pixels (arrow keys)
    function nudge(dx, dy) {
        var lo = margin + extL, hi = Math.max(lo, screenW - vw - margin - extR)
        var tlo = topInset, thi = Math.max(tlo, screenH - vh - bottomInset)
        var nx = Math.max(lo, Math.min(hi, x + dx)), ny = Math.max(tlo, Math.min(thi, y + dy))
        dropped(uid, WD.fracX(nx - extL, screenW, chainW, margin), WD.fracY(ny, screenH, vh, topInset, bottomInset))
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

    // Soft halo: a faint, feathered dark glow behind the words, only where the wallpaper is BUSY behind them (high contrast spread).
    // On flat or even patches (a plain pink sky, a dark area) it fades out completely, so it is never seen as a blob.
    Item {
        id: halo
        readonly property real busy: Math.max(0, Math.min(1, (host.backSpread - 0.22) / 0.3))     // 0 = even patch, 1 = very busy
        readonly property real strength: busy * (0.45 + 0.55 * host.boost)
        visible: host.look.halo !== false && host.gOpt.widgetHalo !== false && host.bodyOp < 0.5 && !host.preview && strength > 0.02
        anchors.fill: parent
        Repeater {
            model: 12
            delegate: Rectangle {
                required property int index
                anchors.fill: parent
                anchors.margins: -(index * 3 - 2)
                radius: Math.max(host.corner, 8) + index * 3
                color: Qt.rgba(0, 0, 0, 0.026 * halo.strength)
            }
        }
    }

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
    // the click shield (lock screen): takes every press and scroll over the body, so no button, slider or wheel in it ever fires
    MouseArea {
        z: 40
        anchors.fill: parent
        enabled: host.inert && WD.lockButtons[host.type] !== true
        visible: enabled
        acceptedButtons: Qt.AllButtons
        onWheel: w => { w.accepted = true }
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
        property real pressX: 0                 // (was sx / sy: the `var sx` inside onPositionChanged shadowed them, so the move was NaN and nothing dragged)
        property real pressY: 0
        property real ox: 0
        property real oy: 0
        property var tgt: null                  // the widget that really moves: this one, or (linked) the first of its chain
        onPressed: m => {
            host.picked(host.uid)
            var t = host.linked ? host.chainRoot : host
            if (!t) { tgt = null; return }
            tgt = t
            var p = grab.mapToItem(host.parent, m.x, m.y)
            pressX = p.x; pressY = p.y; ox = t.x; oy = t.y
            t.others = t.collect ? t.collect(t.uid) : []      // the widgets of the chain are not "others": they travel along
            t.dragX = ox; t.dragY = oy
            t.dragging = true
        }
        onPositionChanged: m => {
            var t = tgt
            if (!pressed || !t || !t.dragging) return
            var p = grab.mapToItem(host.parent, m.x, m.y)
            var nx = ox + p.x - pressX, ny = oy + p.y - pressY
            var gx = -1, gy = -1
            var lo = t.margin + t.extL, hi = t.screenW - t.vw - t.margin - t.extR
            var tlo = t.topInset, thi = t.screenH - t.vh - t.bottomInset
            // Alt or Ctrl held = move freely, no snapping
            if ((m.modifiers & (Qt.AltModifier | Qt.ControlModifier)) === 0) {
                var xo = [], yo = []
                for (var i = 0; i < t.others.length; i++) {
                    var o = t.others[i]
                    xo.push({ p: o.x, s: o.w, near: ny < o.y + o.h + 40 && ny + t.vh > o.y - 40 })   // beside it only if level with it
                    yo.push({ p: o.y, s: o.h, near: nx < o.x + o.w + 40 && nx + t.vw > o.x - 40 })   // under it only if above / below it
                }
                // the grid first (when it is on), then the other widgets / the middle / the edges win when they are close
                if (t.gridSnap > 0) {
                    nx = t.margin + Math.round((nx - t.margin) / t.gridSnap) * t.gridSnap
                    ny = t.topInset + Math.round((ny - t.topInset) / t.gridSnap) * t.gridSnap
                }
                var snapX = WD.snapAxis(nx, t.vw, lo, hi, t.screenW, xo, t.snapGap, 10)
                var snapY = WD.snapAxis(ny, t.vh, tlo, thi, t.screenH, yo, t.snapGap, 10)
                if (snapX) { nx = snapX.pos; gx = snapX.guide }
                if (snapY) { ny = snapY.pos; gy = snapY.guide }
            }
            t.dragX = Math.max(lo, Math.min(Math.max(lo, hi), nx))
            t.dragY = Math.max(tlo, Math.min(Math.max(tlo, thi), ny))
            t.dragMoved(gx, gy)
        }
        onReleased: {
            var t = tgt
            tgt = null
            if (!t || !t.dragging) return
            t.dragging = false
            t.dragMoved(-1, -1)
            t.dropped(t.uid, WD.fracX(t.dragX - t.extL, t.screenW, t.chainW, t.margin), WD.fracY(t.dragY, t.screenH, t.vh, t.topInset, t.bottomInset))
        }
        onCanceled: {
            var t = tgt
            tgt = null
            if (t && t.dragging) { t.dragging = false; t.dragMoved(-1, -1) }
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
            onPressed: { host.pinX = host.x - host.extL; host.pinY = host.y; host.liveScale = host.k; host.resizing = true }
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
