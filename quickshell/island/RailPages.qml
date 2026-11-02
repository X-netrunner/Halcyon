import QtQuick
import Quickshell
import Quickshell.Wayland

// The dashboard of a RAIL bar: ONE box with three tabs, Media | Calendar | Performance (Dashboard.qml; learned from Caelestia's dashboard).
// It drops from the TOP edge of the screen, centred, whichever edge the rail is on (with the border around the screen it hangs from the
// border and flares into it, without it it floats a few px below the edge).
//   rest the pointer on the wake spot at the top middle of the screen (ActivationZone in shell.qml) = it opens on Calendar, in the spotlight
//   the rail itself does NOT open it (no resting near its ends, no scrolling or dragging along it): the wake spot is the only way in
//   click a tab, scroll over the tab strip, or press Left / Right to switch (Tabs style only; Settings > Bar > Dashboard style picks Tabs, Bento or Command,
//   see Dashboard.qml). Esc closes it (after a click in the box, so it has the keyboard).
// The same pages as the island's (MediaPage.qml, PerfTab.qml) are still what the island and the notch show: they grow out of the top edge
// at their own size and shell.qml's page switching is untouched. The box folds back after the pointer has left the wake spot and
// the box for Settings > Bar > "Page closes" ms (opt.pageClose; 0 = it stays until Esc / a click elsewhere).
Scope {
    id: root
    property var pal
    property var player: null
    property var cava: []                    // the six cava values (shell.qml): the ring round the cover
    property var stats: ({})
    property var gpu: ({ gpu: 0, state: "none" })
    property var specs: ({})
    property var disks: ({ disks: [] })
    property var net: ({})
    property var cal: null                   // the Calendar scope (Calendar.qml): the Calendar tab's month and events
    property string perfLook: "sky"          // the Performance tab's look (opt.perfLook): sky | orbit | pulse | tiles | sea | forecast | radar | cockpit | recorder | editorial | stars | classic (shell.qml resolves 'auto')
    property string profile: "balanced"
    property string profileLabel: "Balanced"
    property bool autoPower: false
    property string autoNote: ""
    property string sysmode: ""
    property string side: "left"             // the rail's edge
    property real edge: 0                    // how far the rail's inner edge is from the screen edge (px)
    property real frameT: 0                  // thickness of the border around the screen (0 = none): the box hangs from it
    property bool railHeld: false            // the pointer is on the rail or on the top wake spot
    property int closeMs: 600
    property string which: ""                // "" (closed) | media | cal | perf   (shell.qml reads it: perfShown)
    property string dashStyle: "tabs"        // opt.dashStyle: tabs | bento | command (anything else counts as tabs)
    property bool dashStrip: true            // opt.dashStrip: the stat strip under the Calendar page of the Tabs style
    property bool wifiOn: false              // the state of the switches of the Bento and Command styles (shell.qml)
    property bool btOn: false
    property bool dndOn: false
    property bool caffeineOn: false
    property bool airplaneOn: false         // more switches of the Command style (shell.qml): airplane mode, sound muted, gaming mode, extra dim
    property bool muteOn: false
    property bool gamingOn: false
    property bool dimOn: false
    readonly property string styleNow: (dashStyle === "bento" || dashStyle === "command") ? dashStyle : "tabs"
    readonly property bool open: which !== ""
    property bool linger: false

    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()
    signal openMusic(string tab)
    signal openCalendar()
    signal openLauncher()
    signal runCmd(string id)

    readonly property var order: ["media", "cal", "perf"]
    function show(w) { if (order.indexOf(w) < 0) return; which = w; held = true }
    function hide() { which = "" }
    // wheel / drag along the rail, Left / Right: one tab at a time (a closed box opens on Calendar first)
    function step(dir) { if (!open) { show("cal"); return } if (styleNow !== "tabs") return show(order[Math.max(0, Math.min(2, tabIdx + (dir < 0 ? -1 : 1)))]) }
    // the tab that is shown; while the box folds away it keeps the last one (which is "" then). Calendar is the one it opens on.
    property int tabIdx: 1
    onWhichChanged: { var i = order.indexOf(which); if (i >= 0) tabIdx = i }
    onOpenChanged: { if (open) { linger = true; lingerT.stop() } else lingerT.restart() }
    Timer { id: lingerT; interval: root.pal.dClose + 140; onTriggered: root.linger = false }

    // the box stays while the pointer is on the rail or on the box; it folds back shortly after it has left both
    property bool held: false
    property bool cardHover: false
    Timer {
        interval: root.closeMs
        running: root.open && root.closeMs > 0 && !root.railHeld && !root.cardHover
        onTriggered: root.hide()
    }

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-railpage"
            WlrLayershell.layer: WlrLayer.Top
            // a click in the box gives it the keyboard (Esc closes it); it never takes the keyboard from the app you are typing in on its own
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            mask: Region { item: root.open ? clipper : null }

            Shortcut { sequence: "Escape"; onActivated: root.hide() }
            Shortcut { sequence: "Left"; enabled: root.open && root.styleNow === "tabs"; onActivated: root.step(-1) }
            Shortcut { sequence: "Right"; enabled: root.open && root.styleNow === "tabs"; onActivated: root.step(1) }
            Shortcut { sequence: "Up"; enabled: root.open && root.styleNow === "command"; onActivated: dash.cmdMove(-1) }
            Shortcut { sequence: "Down"; enabled: root.open && root.styleNow === "command"; onActivated: dash.cmdMove(1) }
            // Enter opens the place picked with Up / Down; with nothing picked it opens the launcher, as before
            Shortcut { sequence: "Return"; enabled: root.open && root.styleNow === "command"; onActivated: { if (!dash.cmdEnter()) root.openLauncher() } }

            Item {
                id: area
                anchors.fill: parent

                readonly property bool joined: root.pal.frameOn === true
                readonly property real gap: joined ? 0 : 8                  // hung from the border: flush; else a little away from the edge
                readonly property real fl: joined ? 16 : 0                  // how far the flares reach along the edge (Glass.qml earR)
                // 0 = folded into the top edge, 1 = out: it opens on the soft spring and folds on the closing ease
                property real shown: root.open ? 1 : 0
                Behavior on shown {
                    NumberAnimation {
                        duration: root.open ? root.pal.dSlow : root.pal.dClose
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.open ? root.pal.curve : root.pal.curveClose
                    }
                }

                readonly property real dw: surface.width
                readonly property real dh: surface.height
                // where the box rests: hung from the top edge (below the rail when the rail is on top), centred on the screen
                readonly property real bx: Math.round((area.width - dw) / 2)
                readonly property real by: (root.side === "top" ? root.edge : root.frameT) + gap

                // the window the box slides out of: the box's own rectangle (plus the flares along the rail), so it comes out of the rail
                Item {
                    id: clipper
                    clip: true
                    x: area.bx - area.fl
                    y: area.by
                    width: area.dw + area.fl * 2
                    height: area.dh
                    opacity: Math.min(1, area.shown * 1.8)

                    Glass {
                        id: surface
                        pal: root.pal
                        opacityBody: Math.max(0.86, root.pal.glassBarOpen)
                        radius: root.pal.rXl
                        joinV: area.joined ? "t" : ""
                        width: dash.implicitWidth
                        height: dash.implicitHeight
                        // switching the dashboard style (Tabs / Bento / Command) changes the box's size: glide to it instead of jumping
                        Behavior on width { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                        Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                        // folded: pushed up into the top edge by its own height; the clip hides the part that is above its window.
                        // (x / y are inside the clipper: sideways the flares need `fl` of room, downwards the box slides)
                        readonly property real travel: height + area.gap
                        readonly property real off: (1 - area.shown) * travel
                        x: area.fl
                        y: -off

                        HoverHandler { onHoveredChanged: root.cardHover = hovered }

                        Dashboard {
                            id: dash
                            anchors.fill: parent
                            pal: root.pal
                            player: root.player
                            cava: root.cava
                            stats: root.stats
                            gpu: root.gpu
                            specs: root.specs
                            disks: root.disks
                            net: root.net
                            cal: root.cal
                            perfLook: root.perfLook
                            profile: root.profile
                            profileLabel: root.profileLabel
                            autoPower: root.autoPower
                            autoNote: root.autoNote
                            sysmode: root.sysmode
                            tab: root.tabIdx
                            open: root.open
                            style: root.styleNow
                            showStats: root.dashStrip
                            wifiOn: root.wifiOn; btOn: root.btOn; dndOn: root.dndOn; caffeineOn: root.caffeineOn
                            airplaneOn: root.airplaneOn; muteOn: root.muteOn; gamingOn: root.gamingOn; dimOn: root.dimOn
                            onOpenLauncher: root.openLauncher()
                            onRunCmd: id => root.runCmd(id)
                            onLaunch: id => { root.hide(); root.runCmd(id) }
                            onTabPicked: i => root.show(root.order[i])
                            onOpenCalendar: { root.hide(); root.openCalendar() }
                            onOpenMusic: tab => { root.hide(); root.openMusic(tab) }
                            onToggleWifi: root.toggleWifi()
                            onToggleBt: root.toggleBt()
                            onSetProfile: p => root.setProfile(p)
                            onSetAuto: root.setAuto()
                        }
                    }
                }
            }
        }
    }
}
