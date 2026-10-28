import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "BarLayout.js" as BL

// Bar style "Custom" (Settings > Bar style > Style, then Settings > Bar style > Bar builder).
// What is on the bar, where it sits and what it looks like is up to you: opt.barLayout (BarLayout.js has the list of widgets and the rules,
// the Bar builder edits it).
//   shape "notch":  hangs from the edge, flared corners at both ends, rounded corners on the free side
//   shape "island": a floating rounded pill, a little away from the edge
//   shape "rail":   the whole length of the edge, like the side bar of the Caelestia shell. With the border around the screen it is one piece
//                   with the border (the two ends flare into it); every widget can sit in its own soft capsule ("caps")
//   side: top | bottom | left | right: the edge of the screen the bar sits on. A left / right bar stacks its widgets from the top down:
//         the clock reads hours over minutes, the workspaces are a column, the stats stack ...
//   edge / gap / clear / pads: the padding the person typed in the builder (null = the automatic spacing)
//   left / right: grow from the ends      middle: always centred on the screen (both sides get the same length so it stays centred)
//   ("left" and "right" are the START and END of the bar: on a left / right bar they are its top and its bottom)
// Same inputs and signals as NotchBar.qml, so shell.qml feeds it the same way.
//
// How it is drawn: the body (the shape, the halo, the stars) is drawn once for a bar on the top edge, in `flat`, and `flat` is turned
// 180 / -90 / 90 degrees for the other edges. The widgets are NOT turned: each one is written for both directions (win.vert).
PanelWindow {
    id: win

    // ---- fed by shell.qml
    property var pal
    property var stats: ({})
    property var net: ({})
    property var cava: []
    property bool playing: false
    property string activeSpecial: ""
    property bool caffeine: false
    property bool numLock: false         // Num Lock is on (the Num Lock widget)
    property string focusText: ""        // Focus mode running: the time left ("" = no session)
    property bool focusPaused: false
    property int bgCount: 0
    property var opt: ({})
    property string barPadding: "normal"      // low | normal | high (Settings > Bar > Bar size and padding)
    property bool autoHide: false
    property bool clickMode: false            // Settings > Edge boxes = Click: an auto-hidden bar comes back on a click on its edge, not on a hover
    property bool clock24: false
    property bool showStats: false            // Settings > Bar > "When you hover the bar" = Live stats
    property bool pageOpen: false             // the performance / media page or the launcher is open (bar is not clickable behind it)
    property int gaps: 8                      // Hyprland's gaps (see exclusiveZone)

    signal workspaceClicked(int wsId)
    signal workspaceScrolled(int dir)         // +1 wheel up, -1 wheel down
    signal specialClicked(string name)
    signal statusClicked()
    signal pageDrop(int dir)                  // drag the bar towards the screen's inside (+1) / back (-1): the utilities box and notifications (Settings > Bar style)
    signal clockToggled(string what)          // right click on the time = 12 / 24 hour, middle click = seconds (shell.qml flips the setting)
    signal bgClicked()
    signal numLockClicked()                   // click on the Num Lock widget (shell.qml flips the key)
    signal pageStep(int dir)                  // wheel / drag along the bar: -1 = media, +1 = performance (shell.qml go())
    signal hoverEdited(bool on)               // the pointer is on the bar / left it (shell.qml opens perf / media after a moment)

    // ---- layout: what is on the bar, where, and how it looks
    readonly property var lay: BL.normalize(opt.barLayout)
    readonly property string side: lay.side                        // top | bottom | left | right
    readonly property bool vert: side === "left" || side === "right"
    readonly property int inSign: (side === "bottom" || side === "right") ? -1 : 1        // +1: the screen's inside is towards +x / +y of the bar
    readonly property bool rail: lay.shape === "rail"
    readonly property bool isl: lay.shape === "island"
    readonly property bool caps: rail && lay.caps                   // a capsule behind every widget
    readonly property bool ears: frameT > 0                         // the border around the screen is on: the ends of a rail flare into it
    readonly property color ac: {
        var m = opt.notchAccent || "theme"
        if (m === "theme") return pal.accent
        if (m === "accent2") return pal.accent2
        var c = pal.accent
        return Qt.hsla(pal.hueOf(c, 0.5), Math.min(1, Math.max(0.6, c.hslSaturation * 1.7)), pal.light ? 0.40 : 0.58, 1)
    }
    readonly property int wsMin: Math.max(1, Math.min(10, Number(opt.notchWsMin || 5)))
    readonly property bool showSeconds: opt.clockSeconds === true
    readonly property string btMode: opt.notchBtMode || "connected"
    readonly property bool btShown: net.bt === "on" && (btMode === "on" || (btMode === "connected" && (net.btdev || "") !== ""))
    readonly property string wifiLook: opt.notchWifiStyle || "bars"
    readonly property bool spacious: opt.notchSpacing === "spacious"
    readonly property var sp: BL.resolve(lay, barH, spacious)
    // a typed gap is used everywhere; otherwise each zone keeps its own automatic one
    readonly property int midGap: lay.gap !== null ? lay.gap : sp.autoMidGap
    readonly property int groupGap: sp.clear
    readonly property int itemGap: sp.gap
    readonly property int rightGap: lay.gap !== null ? lay.gap : sp.autoRightGap
    readonly property bool showBatPct: opt.notchBatPct === true
    signal clockClicked()                 // a left click on the time while Settings > Calendar > Clock click is on
    readonly property bool calClock: opt.calOn !== false && opt.calClock !== false
    readonly property bool dropOn: opt.dropDown === "stack" || opt.dropDown === "side"

    // ---- size (Bar size and padding): the same numbers as the Notch
    readonly property var sizeSet: ({ low: { h: 26, gap: 3 }, normal: { h: 32, gap: 8 }, high: { h: 40, gap: 12 } })[barPadding] || ({ h: 32, gap: 8 })
    readonly property int barH: sizeSet.h
    // how thick the bar is, across (its height on a top / bottom bar, its width on a left / right one). A rail is a little thicker: its
    // widgets sit in capsules with room around them.
    readonly property int bt: rail ? barH + 8 : barH
    readonly property real earR: isl ? 0 : Math.round(barH * 0.42)             // the flare of the notch (the island has none)
    readonly property real cornR: isl ? barH / 2 : Math.round(barH * 0.42)
    readonly property int edgeM: isl ? Math.max(4, sizeSet.gap) : 0             // the island floats a little away from the screen edge
    readonly property int padX: sp.edge
    readonly property int textPx: Math.round(barH * 0.44)
    readonly property int curH: Math.round(textPx * 1.3)
    readonly property int curW: Math.round(curH * 0.55)
    readonly property int offH: Math.round(curH * 0.85)
    readonly property int offW: Math.round(curW * 0.8)
    readonly property int icoH: offH
    readonly property int comboSize: Math.round(barH * 0.78)

    // what shell.qml needs to know: how wide the bar is while it hangs from the TOP (the pages grow out of it). A bar on another edge,
    // or a rail, leaves the top free, like Bar style = Off: the pages just hang from the top edge.
    readonly property real bodyWidth: (side === "top" && !rail) ? notch.bw : 260
    // the room the bar takes along the screen's edge (0 while it is auto-hidden)
    readonly property int reserve: autoHide ? 0 : bt + edgeM
    readonly property bool shown: !autoHide || peek || hov.hovered
    property bool peek: false
    Timer { id: peekT; interval: 700; onTriggered: win.peek = false }
    Timer { id: graceT; interval: 2500; onTriggered: if (!hov.hovered) win.peek = false }

    property int frameT: 0                   // the border around the screen (ScreenFrame.qml): the bar hangs from its inner edge
    // the window is a strip along the bar's edge, the whole length of the screen
    readonly property int span: frameT + bt + edgeM + 34
    anchors { top: win.side !== "bottom"; bottom: win.side !== "top"; left: win.side !== "right"; right: win.side !== "left" }
    exclusionMode: frameT > 0 ? ExclusionMode.Ignore : ExclusionMode.Normal
    implicitWidth: vert ? span : 0
    implicitHeight: vert ? 0 : span
    exclusiveZone: frameT + (autoHide ? 0 : Math.max(0, bt + edgeM + sizeSet.gap - gaps * 2))
    color: "transparent"

    WlrLayershell.namespace: "island-notch"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region { regions: [ Region { item: strip }, Region { item: win.pageOpen ? null : notch } ] }

    // the strip along the screen's edge that brings an auto-hidden bar back
    Item {
        id: strip
        width: win.vert ? 5 : 420
        height: win.vert ? 420 : 5
        x: win.vert ? (win.side === "left" ? 0 : win.width - width) : Math.round((win.width - width) / 2)
        y: win.vert ? Math.round((win.height - height) / 2) : (win.side === "top" ? 0 : win.height - height)
        HoverHandler {
            enabled: !win.clickMode
            onHoveredChanged: { if (hovered) { peekT.stop(); win.peek = true } else peekT.restart() }
        }
        TapHandler {
            enabled: win.clickMode
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: { peekT.stop(); win.peek = true; graceT.restart() }
        }
    }

    // a click on any status widget: the drop-down, or the performance page
    function statusTap() { if (dropOn) pageDrop(1); else statusClicked() }

    // ------------------------------------------------------------------ the bar
    Item {
        id: notch

        // "along" is the bar's direction (its length), "across" its thickness. The sizes below are the bar as drawn on a TOP edge (in `flat`).
        readonly property real bh: win.bt                                  // the bar's thickness
        readonly property real boxT: win.bt + (win.rail && win.ears ? win.earR : 0)     // + the flares at the ends of a rail
        readonly property real e: win.rail ? 0 : win.earR                  // the flare at each end of a notch (the widgets start after it)
        readonly property real winLen: win.vert ? win.height : win.width
        readonly property real sideW: Math.max(leftZone.along, rightZone.along)
        readonly property real centerW: midBox.along
        readonly property real bodyW: sideW * 2 + centerW + (sideW > 0 ? (centerW > 0 ? win.groupGap * 2 : win.groupGap) : 0) + win.padX * 2
        // a notch / island is as long as its content; a rail is as long as the edge (inside the border)
        property real alongLen: win.rail ? Math.max(0, winLen - 2 * win.frameT) : bodyW + e * 2
        Behavior on alongLen { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }

        // how far the bar's near side is from the screen edge (slides out of the screen while the bar is hidden)
        property real inset: win.shown ? win.edgeM + win.frameT : -(boxT + 30)
        Behavior on inset { NumberAnimation { duration: win.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }

        width: win.vert ? boxT : alongLen
        height: win.vert ? alongLen : boxT
        x: win.vert ? (win.side === "left" ? inset : win.width - inset - boxT) : Math.round((win.width - width) / 2)
        y: win.vert ? Math.round((win.height - height) / 2) : (win.side === "top" ? inset : win.height - inset - boxT)
        opacity: win.pageOpen ? 0.0 : 1.0
        Behavior on opacity { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

        SystemClock { id: clock; precision: win.showSeconds ? SystemClock.Seconds : SystemClock.Minutes }
        readonly property string timeStr: Qt.formatDateTime(clock.date, (win.clock24 ? "HH:mm" : "hh:mm") + (win.showSeconds ? ":ss" : "") + (win.clock24 ? "" : " AP"))
        readonly property string dateStr: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")
        // the same, for a left / right bar: one short line each
        readonly property string hourStr: Qt.formatDateTime(clock.date, win.clock24 ? "HH" : "hh")
        readonly property string minStr: Qt.formatDateTime(clock.date, "mm")
        readonly property string secStr: Qt.formatDateTime(clock.date, "ss")
        readonly property string apStr: Qt.formatDateTime(clock.date, "AP")
        readonly property string dayStr: Qt.formatDateTime(clock.date, "ddd")
        readonly property string dayNumStr: Qt.formatDateTime(clock.date, "d")
        readonly property string monStr: Qt.formatDateTime(clock.date, "MMM")

        readonly property real r: win.earR
        readonly property real cr: win.cornR
        readonly property real bw: alongLen - 2 * r

        HoverHandler {
            id: hov
            onHoveredChanged: {
                win.hoverEdited(hovered)
                if (hovered) { peekT.stop() } else peekT.restart()
            }
        }

        // ------------------------------------------------------------ the body, drawn for a top edge and turned for the others
        Item {
            id: flat
            width: win.vert ? notch.height : notch.width
            height: win.vert ? notch.width : notch.height
            x: (notch.width - width) / 2
            y: (notch.height - height) / 2
            transformOrigin: Item.Center
            rotation: win.side === "left" ? -90 : (win.side === "right" ? 90 : (win.side === "bottom" ? 180 : 0))

            // soft halo under the bar: hollow, so the glass is not darkened from behind (rules.lua blurs only what is more opaque)
            Item {
                id: haloBody
                x: win.rail ? 0 : notch.r
                width: win.rail ? flat.width : notch.bw
                y: win.isl ? 0 : -60
                height: notch.bh + (win.isl ? 0 : 60)
                visible: win.shown
                HaloShadow {
                    anchors.fill: parent
                    radius: notch.cr
                    spread: 20
                    peak: 0.16
                }
            }

            // ---- the outline: flare, straight side, rounded corner, free side, rounded corner, straight side, flare
            // the island: one rounded pill with a hairline all around
            Rectangle {
                visible: win.isl
                anchors.fill: parent
                radius: notch.cr
                color: notch.fillCol
                border.width: win.pal.calm ? 0 : 1
                border.color: win.pal.line
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, parent.radius - 1)
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.alpha(win.pal.text, win.pal.frameOn ? 0 : 0.05) }
                        GradientStop { position: 0.55; color: Qt.alpha(win.pal.text, 0.0) }
                    }
                }
            }
            Shape {
                id: body
                visible: !win.isl && !win.rail
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                antialiasing: true

                ShapePath {
                    fillColor: notch.fillCol
                    strokeColor: "transparent"
                    strokeWidth: 0
                    startX: 0; startY: 0
                    PathArc { x: notch.r; y: notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                    PathLine { x: notch.r; y: notch.bh - notch.cr }
                    PathArc { x: notch.r + notch.cr; y: notch.bh; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                    PathLine { x: notch.r + notch.bw - notch.cr; y: notch.bh }
                    PathArc { x: notch.r + notch.bw; y: notch.bh - notch.cr; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                    PathLine { x: notch.r + notch.bw; y: notch.r }
                    PathArc { x: notch.alongLen; y: 0; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                    PathLine { x: 0; y: 0 }
                }
                // faint sheen from the screen edge, like the other glass surfaces
                ShapePath {
                    strokeColor: "transparent"
                    strokeWidth: 0
                    fillGradient: LinearGradient {
                        x1: 0; y1: 0; x2: 0; y2: notch.bh
                        GradientStop { position: 0.0; color: Qt.alpha(win.pal.text, win.pal.frameOn ? 0 : 0.05) }
                        GradientStop { position: 0.55; color: Qt.alpha(win.pal.text, 0.0) }
                    }
                    startX: 0; startY: 0
                    PathArc { x: notch.r; y: notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                    PathLine { x: notch.r; y: notch.bh - notch.cr }
                    PathArc { x: notch.r + notch.cr; y: notch.bh; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                    PathLine { x: notch.r + notch.bw - notch.cr; y: notch.bh }
                    PathArc { x: notch.r + notch.bw; y: notch.bh - notch.cr; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                    PathLine { x: notch.r + notch.bw; y: notch.r }
                    PathArc { x: notch.alongLen; y: 0; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                    PathLine { x: 0; y: 0 }
                }
                // hairline: the same outline, open at the screen edge (nothing is drawn along it)
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: win.pal.frameOn ? "transparent" : win.pal.line
                    strokeWidth: 1
                    startX: 0; startY: 0
                    PathArc { x: notch.r; y: notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                    PathLine { x: notch.r; y: notch.bh - notch.cr }
                    PathArc { x: notch.r + notch.cr; y: notch.bh; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                    PathLine { x: notch.r + notch.bw - notch.cr; y: notch.bh }
                    PathArc { x: notch.r + notch.bw; y: notch.bh - notch.cr; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                    PathLine { x: notch.r + notch.bw; y: notch.r }
                    PathArc { x: notch.alongLen; y: 0; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                }
            }

            // the rail: a strip along the whole edge. With the border around the screen its two ends flare into the border (concave
            // fillets, like the ears of a notch); without it the free side has rounded corners.
            Shape {
                id: railBody
                visible: win.rail
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                antialiasing: true
                readonly property real fw: flat.width                       // length of the rail
                readonly property real tt: notch.bh                         // thickness of the rail itself
                readonly property real rr: win.ears ? win.earR : win.cornR  // radius of a flare / of a corner
                readonly property real yA: win.ears ? tt + rr : tt - rr     // where the end arcs meet the rail's two ends

                ShapePath {
                    fillColor: notch.fillCol
                    strokeColor: "transparent"
                    strokeWidth: 0
                    startX: 0; startY: 0
                    PathLine { x: railBody.fw; y: 0 }
                    PathLine { x: railBody.fw; y: railBody.yA }
                    PathArc { x: railBody.fw - railBody.rr; y: railBody.tt; radiusX: railBody.rr; radiusY: railBody.rr; direction: win.ears ? PathArc.Counterclockwise : PathArc.Clockwise }
                    PathLine { x: railBody.rr; y: railBody.tt }
                    PathArc { x: 0; y: railBody.yA; radiusX: railBody.rr; radiusY: railBody.rr; direction: win.ears ? PathArc.Counterclockwise : PathArc.Clockwise }
                    PathLine { x: 0; y: 0 }
                }
                // hairline along the free side (only without the border: with it the rail and the border are one piece)
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: (win.ears || win.pal.frameOn) ? "transparent" : win.pal.line
                    strokeWidth: 1
                    startX: 0; startY: railBody.yA
                    PathArc { x: railBody.rr; y: railBody.tt; radiusX: railBody.rr; radiusY: railBody.rr; direction: PathArc.Counterclockwise }
                    PathLine { x: railBody.fw - railBody.rr; y: railBody.tt }
                    PathArc { x: railBody.fw; y: railBody.yA; radiusX: railBody.rr; radiusY: railBody.rr; direction: PathArc.Counterclockwise }
                }
            }

            // a few drifting stars behind the widgets (Settings > Look > Moving stars)
            BarStars {
                pal: win.pal
                active: !win.pageOpen
                visible: win.shown && win.opt.starsBar !== false
                x: win.rail ? 12 : notch.r + notch.cr
                y: 3
                width: Math.max(0, win.rail ? flat.width - 24 : notch.bw - notch.cr * 2)
                height: notch.bh - 6
            }
        }
        readonly property color fillCol: win.frameT > 0 ? win.pal.frameCol : Qt.alpha(win.pal.bg, Math.min(0.97, win.pal.glassBar + 0.26))

        // scroll / two-finger swipe on the bar = change page (the wheel over the workspaces walks through workspaces instead)
        property real wheelAcc: 0
        Timer { id: wheelCool; interval: 450 }
        Timer { id: wheelReset; interval: 300; onTriggered: notch.wheelAcc = 0 }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: e => {
                if (wheelCool.running) return
                var d = Math.abs(e.angleDelta.x) > Math.abs(e.angleDelta.y) ? e.angleDelta.x : e.angleDelta.y
                if (d === 0) return
                notch.wheelAcc += d
                wheelReset.restart()
                if (Math.abs(notch.wheelAcc) < 90) return
                win.pageStep(notch.wheelAcc > 0 ? -1 : 1)
                notch.wheelAcc = 0
                wheelCool.start()
            }
        }
        // hold + drag along the bar: towards its start = performance, towards its end = media (like the island). On a left / right bar the
        // start is the top. Drag it towards the screen's inside and back = the utilities box and notifications (when the drop-down is on).
        property real dragX: 0
        property real dragY: 0
        DragHandler {
            id: dragH
            target: null
            xAxis.enabled: win.vert ? win.dropOn : true
            yAxis.enabled: win.vert ? true : win.dropOn
            onTranslationChanged: if (active) { notch.dragX = translation.x; notch.dragY = translation.y }
            onActiveChanged: {
                if (active) return
                var dx = notch.dragX, dy = notch.dragY
                notch.dragX = 0; notch.dragY = 0
                var al = win.vert ? dy : dx                                    // along the bar
                var cr = (win.vert ? dx : dy) * win.inSign                     // across it, + = towards the screen's inside
                if (win.dropOn && Math.abs(cr) > Math.abs(al) && Math.abs(cr) > 40) win.pageDrop(cr > 0 ? 1 : -1)
                else if (al < -50) win.pageStep(1)
                else if (al > 50) win.pageStep(-1)
            }
        }

        // ------------------------------------------------------------ content
        // Every widget is a component with an implicit size: its length along the bar (implicitWidth on a top / bottom bar,
        // implicitHeight on a left / right one) and the bar's thickness across. 0 length = nothing to show.
        // The workspaces and the specials are a BarFlow: a row on a top / bottom bar, a column on a left / right one.
        Component { id: wsDelegate
            Item {
                id: wsItem
                required property int index
                readonly property int wsId: index + 1
                readonly property var ws: win.findWs(wsId)
                readonly property bool cur: ws !== null && ws.focused
                readonly property bool occ: ws !== null && win.wsWindows(ws) > 0
                // the capsule grows when it is the current one: along the bar, and across it
                property real aLen: cur ? win.curW : win.offW
                property real xLen: cur ? win.curH : win.offH
                Behavior on aLen { NumberAnimation { duration: Math.round(win.pal.dSlow * 0.8); easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
                Behavior on xLen { NumberAnimation { duration: Math.round(win.pal.dSlow * 0.8); easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
                width: win.vert ? notch.bh : aLen
                height: win.vert ? aLen : notch.bh
                Rectangle {
                    anchors.centerIn: parent
                    width: win.vert ? wsItem.xLen : wsItem.aLen
                    height: win.vert ? wsItem.aLen : wsItem.xLen
                    radius: Math.min(width, height) / 2
                    color: wsItem.cur ? win.ac
                         : wsItem.occ ? Qt.alpha(win.ac, wsMa.containsMouse ? 0.55 : 0.36)
                         : Qt.alpha(win.pal.text, wsMa.containsMouse ? 0.28 : 0.14)
                    Behavior on color { ColorAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                }
                MouseArea {
                    id: wsMa
                    anchors.fill: parent
                    anchors.leftMargin: win.vert ? 0 : -3
                    anchors.rightMargin: win.vert ? 0 : -3
                    anchors.topMargin: win.vert ? -3 : 0
                    anchors.bottomMargin: win.vert ? -3 : 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: win.workspaceClicked(wsItem.wsId)
                }
            }
        }
        Component { id: cWorkspaces
            Item {
                id: wsBox
                implicitWidth: win.vert ? notch.bh : wsFlow.along
                implicitHeight: win.vert ? wsFlow.along : notch.bh
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: function (e) { if (e.angleDelta.y !== 0) win.workspaceScrolled(e.angleDelta.y > 0 ? 1 : -1) }
                }
                BarFlow {
                    id: wsFlow
                    anchors.centerIn: parent
                    vert: win.vert
                    spacing: win.itemGap
                    model: win.wsCount
                    delegate: wsDelegate
                }
            }
        }

        Component { id: spDelegate
            Item {
                id: spItem
                required property var modelData
                readonly property bool lit: win.activeSpecial === modelData.name
                readonly property bool show: lit || win.hasSpecial(modelData.name)
                visible: show
                width: win.vert ? notch.bh : (show ? win.icoH + 4 : 0)
                height: win.vert ? (show ? win.icoH + 4 : 0) : notch.bh
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(spItem.modelData.glyph)
                    color: spItem.lit ? win.ac : Qt.alpha(win.pal.text, spMa.containsMouse ? 0.8 : 0.5)
                    font.family: win.pal.font
                    font.pixelSize: win.icoH
                    Behavior on color { ColorAnimation { duration: win.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                }
                MouseArea {
                    id: spMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: win.specialClicked(spItem.modelData.name)
                }
            }
        }
        Component { id: cSpecials
            Item {
                id: spBox
                implicitWidth: win.vert ? notch.bh : spFlow.along
                implicitHeight: win.vert ? spFlow.along : notch.bh
                BarFlow {
                    id: spFlow
                    anchors.centerIn: parent
                    vert: win.vert
                    spacing: win.itemGap
                    model: win.specials
                    delegate: spDelegate
                }
            }
        }

        // the visualizer turns on its side on a left / right bar
        Component { id: cMusic
            Item {
                id: musicBox
                readonly property real aLen: win.opt.viz === "off" ? 0 : (win.vert ? viz.implicitHeight : viz.implicitWidth)
                implicitWidth: win.vert ? notch.bh : aLen
                implicitHeight: win.vert ? aLen : notch.bh
                Visualizer {
                    id: viz
                    anchors.centerIn: parent
                    rotation: win.vert ? 90 : 0
                    pal: win.pal
                    values: win.cava
                    active: win.playing
                }
            }
        }

        // a left / right bar: hours over minutes (over seconds, and am / pm in 12 h)
        Component { id: cClock
            Item {
                id: clkBox
                implicitWidth: win.vert ? notch.bh : clkH.implicitWidth
                implicitHeight: win.vert ? clkV.implicitHeight : notch.bh
                Text {
                    id: clkH
                    visible: !win.vert
                    height: notch.bh
                    verticalAlignment: Text.AlignVCenter
                    text: notch.timeStr
                    color: win.pal.text
                    font.family: win.pal.uiFont
                    font.pixelSize: win.textPx
                    font.weight: Font.DemiBold
                }
                Column {
                    id: clkV
                    visible: win.vert
                    anchors.centerIn: parent
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.hourStr; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: win.textPx; font.weight: Font.DemiBold }
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.minStr; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: win.textPx; font.weight: Font.DemiBold }
                    Text { visible: win.showSeconds; width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.secStr; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: Math.max(9, win.textPx - 3) }
                    Text { visible: !win.clock24; width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.apStr; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: Math.max(9, win.textPx - 4) }
                }
                TapHandler { acceptedButtons: Qt.LeftButton; onTapped: { if (win.calClock) win.clockClicked(); else win.statusTap() } }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: win.clockToggled("24h") }
                TapHandler { acceptedButtons: Qt.MiddleButton; onTapped: win.clockToggled("seconds") }
            }
        }

        Component { id: cDate
            Item {
                id: dateBox
                implicitWidth: win.vert ? notch.bh : dateH.implicitWidth
                implicitHeight: win.vert ? dateV.implicitHeight : notch.bh
                Text {
                    id: dateH
                    visible: !win.vert
                    height: notch.bh
                    verticalAlignment: Text.AlignVCenter
                    text: notch.dateStr
                    color: win.pal.muted
                    font.family: win.pal.uiFont
                    font.pixelSize: Math.max(10, win.textPx - 2)
                }
                Column {
                    id: dateV
                    visible: win.vert
                    anchors.centerIn: parent
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.dayStr; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: Math.max(9, win.textPx - 3) }
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.dayNumStr; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: Math.max(10, win.textPx - 1); font.weight: Font.DemiBold }
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: notch.monStr; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: Math.max(9, win.textPx - 3) }
                }
            }
        }

        // a left / right bar: the three readings stacked, the name over its number
        Component { id: cStats
            Item {
                id: stBox
                readonly property var items: [
                    { k: "CPU", v: Math.round(win.stats.cpu || 0) + "%", frac: (win.stats.cpu || 0) / 100 },
                    { k: "RAM", v: (win.stats.memGb || "0.0") + "G", frac: (win.stats.mem || 0) / 100 },
                    { k: "TEMP", v: Math.round(win.stats.temp || 0) + "°", frac: (win.stats.temp || 0) / 100 }
                ]
                implicitWidth: win.vert ? notch.bh : stRow.width
                implicitHeight: win.vert ? stCol.height : notch.bh
                Row {
                    id: stRow
                    visible: !win.vert
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Repeater {
                        model: win.vert ? [] : stBox.items
                        delegate: Row {
                            required property var modelData
                            spacing: 4
                            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                            Text { text: modelData.k; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: win.pal.tCap; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: modelData.v; color: modelData.frac > 0.9 ? win.pal.bad : (modelData.frac > 0.75 ? win.pal.warn : win.pal.text); font.family: win.pal.uiFont; font.pixelSize: win.pal.tBody; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
                Column {
                    id: stCol
                    visible: win.vert
                    anchors.centerIn: parent
                    spacing: 6
                    Repeater {
                        model: win.vert ? stBox.items : []
                        delegate: Column {
                            required property var modelData
                            width: notch.bh
                            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.k; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: Math.max(8, win.pal.tCap - 1); font.weight: Font.Medium }
                            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.v; color: modelData.frac > 0.9 ? win.pal.bad : (modelData.frac > 0.75 ? win.pal.warn : win.pal.text); font.family: win.pal.uiFont; font.pixelSize: win.pal.tBody; font.weight: Font.DemiBold }
                        }
                    }
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        // (the battery percentage next to the ring is left out on a left / right bar: there is no room beside it)
        Component { id: cStatus
            Item {
                id: stsBox
                readonly property real aLen: ring.any ? (win.vert ? ring.height : ring.width) : 0
                implicitWidth: win.vert ? notch.bh : aLen
                implicitHeight: win.vert ? aLen : notch.bh
                StatusRing {
                    id: ring
                    anchors.centerIn: parent
                    pal: win.pal
                    net: win.net
                    stats: win.stats
                    tint: win.ac
                    size: win.comboSize
                    showWifi: true
                    showBat: true
                    btMode: win.btMode
                    showPct: win.showBatPct && !win.vert
                    textColor: win.pal.text
                    textFont: win.pal.uiFont
                    textPx: Math.max(10, win.textPx - 2)
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cWifi
            Item {
                id: wfBox
                implicitWidth: win.vert ? notch.bh : wf.width
                implicitHeight: win.vert ? wf.height : notch.bh
                WifiIcon {
                    id: wf
                    anchors.centerIn: parent
                    pal: win.pal
                    net: win.net
                    look: win.wifiLook
                    tint: win.ac
                    offTint: Qt.alpha(win.ac, 0.3)
                    size: win.icoH
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cBluetooth
            Item {
                id: btBox
                readonly property real aLen: win.btShown ? (win.vert ? btText.implicitHeight : btText.implicitWidth) : 0
                implicitWidth: win.vert ? notch.bh : aLen
                implicitHeight: win.vert ? aLen : notch.bh
                clip: true
                Text {
                    id: btText
                    anchors.centerIn: parent
                    text: String.fromCodePoint(0xF00AF)
                    color: (win.net.btdev || "") !== "" ? win.ac : Qt.alpha(win.ac, 0.45)
                    font.family: win.pal.font
                    font.pixelSize: win.icoH
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        // the pill lies flat on every bar; on a left / right bar the percentage goes under it
        Component { id: cBattery
            Item {
                id: bat
                readonly property int bh: Math.round(win.icoH * 0.8)
                readonly property int bw: Math.round(win.icoH * 1.75)
                readonly property bool has: win.stats.hasBat === true
                implicitWidth: win.vert ? notch.bh : (has ? bw + (win.showBatPct ? pctText.implicitWidth + 5 : 0) : 0)
                implicitHeight: win.vert ? (has ? bh + (win.showBatPct ? pctText.implicitHeight + 3 : 0) : 0) : notch.bh
                Rectangle {
                    x: win.vert ? Math.round((notch.bh - bat.bw) / 2) : 0
                    y: win.vert ? 0 : Math.round((notch.bh - bat.bh) / 2)
                    width: bat.bw
                    height: bat.bh
                    radius: height / 2
                    antialiasing: true
                    color: "transparent"
                    border.width: 1.5
                    border.color: Qt.alpha(win.ac, 0.85)
                    Rectangle {
                        x: 2.5; y: 2.5
                        height: parent.height - 5
                        width: Math.max(height, (parent.width - 5) * Math.max(0, Math.min(100, win.stats.bat || 0)) / 100)
                        radius: height / 2
                        antialiasing: true
                        color: win.stats.charging ? win.pal.good : ((win.stats.bat || 0) <= 20 ? win.pal.bad : win.ac)
                        Behavior on width { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                    }
                }
                Text {
                    id: pctText
                    visible: win.showBatPct
                    x: win.vert ? Math.round((notch.bh - implicitWidth) / 2) : bat.bw + 5
                    y: win.vert ? bat.bh + 3 : 0
                    height: win.vert ? implicitHeight : notch.bh
                    verticalAlignment: Text.AlignVCenter
                    text: (win.stats.bat || 0) + "%"
                    color: win.pal.text
                    font.family: win.pal.uiFont
                    font.pixelSize: Math.max(10, win.textPx - 2)
                    font.weight: Font.Medium
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cCaffeine
            Item {
                id: cafBox
                readonly property real aLen: win.caffeine ? (win.vert ? cafText.implicitHeight : cafText.implicitWidth) : 0
                implicitWidth: win.vert ? notch.bh : aLen
                implicitHeight: win.vert ? aLen : notch.bh
                clip: true
                Text { id: cafText; anchors.centerIn: parent; text: String.fromCodePoint(0xF0176); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH }
            }
        }

        // a small key: lit with the accent while Num Lock is on, outline only while it is off. Always shown (it is a switch).
        Component { id: cNumLock
            Item {
                id: nlBox
                implicitWidth: win.vert ? notch.bh : nlKey.width
                implicitHeight: win.vert ? nlKey.height : notch.bh
                Rectangle {
                    id: nlKey
                    anchors.centerIn: parent
                    width: nlText.implicitWidth + 12
                    height: Math.round(win.textPx * 1.35)
                    radius: height / 2
                    color: win.numLock ? win.ac : (nlMa.containsMouse ? Qt.alpha(win.pal.text, 0.10) : "transparent")
                    border.width: win.numLock ? 0 : 1
                    border.color: Qt.alpha(win.pal.text, nlMa.containsMouse ? 0.45 : 0.28)
                    Behavior on color { ColorAnimation { duration: win.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                    Text {
                        id: nlText
                        anchors.centerIn: parent
                        text: "123"
                        color: win.numLock ? win.pal.bg : Qt.alpha(win.pal.text, nlMa.containsMouse ? 0.8 : 0.5)
                        font.family: win.pal.uiFont
                        font.pixelSize: Math.max(9, win.textPx - 4)
                        font.weight: Font.DemiBold
                        Behavior on color { ColorAnimation { duration: win.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                    }
                    MouseArea {
                        id: nlMa
                        anchors.fill: parent
                        anchors.margins: -3
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.numLockClicked()
                    }
                }
            }
        }

        // the icon, and the time left beside it (a left / right bar: under it)
        Component { id: cFocus
            Item {
                id: focBox
                readonly property bool on: win.focusText !== ""
                implicitWidth: win.vert ? notch.bh : (on ? focusRow.implicitWidth : 0)
                implicitHeight: win.vert ? (on ? focusCol.implicitHeight : 0) : notch.bh
                clip: true
                opacity: win.focusPaused ? 0.55 : 1
                Row {
                    id: focusRow
                    visible: !win.vert
                    anchors.centerIn: parent
                    spacing: 5
                    Text { text: String.fromCodePoint(0xF051B); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: win.focusText; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: Math.max(10, win.textPx - 2); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                }
                Column {
                    id: focusCol
                    visible: win.vert
                    anchors.centerIn: parent
                    spacing: 2
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: String.fromCodePoint(0xF051B); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH }
                    Text { width: notch.bh; horizontalAlignment: Text.AlignHCenter; text: win.focusText; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: Math.max(9, win.textPx - 4); font.weight: Font.Medium }
                }
            }
        }

        Component { id: cBgApps
            Item {
                id: bgBox
                readonly property real aLen: win.bgCount > 0 ? (win.vert ? bgIco.implicitHeight : bgIco.implicitWidth) : 0
                implicitWidth: win.vert ? notch.bh : aLen
                implicitHeight: win.vert ? aLen : notch.bh
                clip: true
                Item {
                    id: bgRow
                    anchors.centerIn: parent
                    width: bgIco.implicitWidth
                    height: bgIco.implicitHeight
                    Text { id: bgIco; text: String.fromCodePoint(0xF003B); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH }
                    // a dot on the icon's corner: something is running in the background (click to see what)
                    Rectangle {
                        readonly property int d: Math.max(6, Math.round(win.icoH * 0.38))
                        anchors.top: parent.top; anchors.right: parent.right
                        width: d; height: d; radius: d / 2
                        color: win.ac
                        border.width: 1.5; border.color: Qt.alpha(win.pal.bg, 0.9)
                    }
                }
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: win.bgClicked() }
            }
        }

        // widget id -> component
        function comp(id) {
            switch (id) {
            case "workspaces": return cWorkspaces
            case "specials": return cSpecials
            case "music": return cMusic
            case "clock": return cClock
            case "date": return cDate
            case "stats": return cStats
            case "status": return cStatus
            case "wifi": return cWifi
            case "bluetooth": return cBluetooth
            case "battery": return cBattery
            case "caffeine": return cCaffeine
            case "numlock": return cNumLock
            case "focus": return cFocus
            case "bgapps": return cBgApps
            }
            return null
        }

        // one place for one widget (padding, capsule, hidden while it has nothing to show)
        Component { id: slotDelegate
            BarSlot { bar: win; host: notch }
        }

        // ---- the three places: left = the start of the bar, middle = always centred, right = the end of the bar
        BarFlow {
            id: leftZone
            vert: win.vert
            spacing: win.itemGap
            model: win.lay.left
            delegate: slotDelegate
            x: win.vert ? 0 : notch.e + win.padX
            y: win.vert ? notch.e + win.padX : 0
        }
        Item {
            id: midBox
            readonly property real along: midZone.along + (liveStats.visible ? (midZone.along > 0 ? win.midGap : 0) + liveStats.along : 0)
            width: win.vert ? win.bt : along
            height: win.vert ? along : win.bt
            x: win.vert ? 0 : Math.round(notch.width / 2 - width / 2)
            y: win.vert ? Math.round(notch.height / 2 - height / 2) : 0
            BarFlow {
                id: midZone
                vert: win.vert
                spacing: win.midGap
                model: win.lay.center
                delegate: slotDelegate
            }
            // live stats: slide out while the pointer is on the bar (Settings > Bar > When you hover the bar = Live stats).
            // Not shown when the Stats widget is already placed on the bar: that one is always there.
            Item {
                id: liveStats
                readonly property bool want: win.showStats && win.lay.left.indexOf("stats") < 0 && win.lay.center.indexOf("stats") < 0 && win.lay.right.indexOf("stats") < 0
                property real p: want ? 1 : 0
                Behavior on p { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
                readonly property real along: Math.round(p * statsLd.along)
                x: win.vert ? 0 : midZone.along + (midZone.along > 0 ? win.midGap : 0)
                y: win.vert ? midZone.along + (midZone.along > 0 ? win.midGap : 0) : 0
                width: win.vert ? win.bt : along
                height: win.vert ? along : win.bt
                visible: want || p > 0.01
                clip: true
                opacity: p
                Loader {
                    id: statsLd
                    sourceComponent: cStats
                    readonly property real along: item ? (win.vert ? item.implicitHeight : item.implicitWidth) : 0
                }
            }
        }
        BarFlow {
            id: rightZone
            vert: win.vert
            spacing: win.rightGap
            model: win.lay.right
            delegate: slotDelegate
            x: win.vert ? 0 : notch.width - notch.e - win.padX - width
            y: win.vert ? notch.height - notch.e - win.padX - height : 0
        }
    }

    // ------------------------------------------------------------------ data helpers (same lists as NotchBar.qml)
    readonly property var specials: [
        { name: "special", glyph: 0xF04CE },
        { name: "music", glyph: 0xF075A },
        { name: "sysmon", glyph: 0xF04C5 },
        { name: "communication", glyph: 0xF0361 },
        { name: "todo", glyph: 0xF05E0 }
    ]
    readonly property int specCount: {
        var n = 0
        for (var i = 0; i < specials.length; i++)
            if (activeSpecial === specials[i].name || hasSpecial(specials[i].name)) n++
        return n
    }
    readonly property int wsCount: {
        var l = Hyprland.workspaces.values, m = wsMin
        for (var i = 0; i < l.length; i++) if (l[i].id > m) m = l[i].id
        return Math.min(10, m)
    }
    function findWs(id) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].id === id) return l[i]
        return null
    }
    function wsWindows(w) {
        try { return w.toplevels.values.length } catch (e) { return 0 }
    }
    function hasSpecial(n) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].name === "special:" + n) return wsWindows(l[i]) > 0
        return false
    }
}
