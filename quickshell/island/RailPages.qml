import QtQuick
import Quickshell
import Quickshell.Wayland

// The music and the performance page for a RAIL bar. On the island and the notch those pages grow down out of the top edge; a rail
// is on the side, so here they come out sideways, next to the rail:
//   rest the pointer near the TOP of the rail = the music window (up in the corner)
//   rest it near the BOTTOM of the rail       = the performance window (down in the corner)
//   (a bar along the top / bottom edge: the start = music, the end = performance, the pages drop / rise from the bar)
// They are the same pages as the island's (MediaPage.qml, PerfPage.qml). The window folds back after the pointer has left both the
// rail and the page for Settings > Bar > "Page closes" ms (opt.pageClose; 0 = it stays until Esc / a click elsewhere).
Scope {
    id: root
    property var pal
    property var player: null
    property var stats: ({})
    property var gpu: ({ gpu: 0, state: "none" })
    property var specs: ({})
    property var disks: ({ disks: [] })
    property var net: ({})
    property string profile: "balanced"
    property string profileLabel: "Balanced"
    property bool autoPower: false
    property string autoNote: ""
    property string sysmode: ""
    property string side: "left"             // the rail's edge
    property real edge: 0                    // how far the rail's inner edge is from the screen edge (px)
    property bool railHeld: false            // the pointer is on the rail
    property int closeMs: 600
    property string which: ""                // "" (closed) | media | perf
    readonly property bool open: which !== ""
    property bool linger: false

    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()
    signal openMusic(string tab)

    function show(w) { if (w !== "media" && w !== "perf") return; which = w; held = true }
    function hide() { which = "" }
    // wheel / drag along the rail: the same two pages, one step at a time
    function step(dir) { show(dir < 0 ? "media" : "perf") }
    onOpenChanged: { if (open) { linger = true; lingerT.stop() } else lingerT.restart() }
    Timer { id: lingerT; interval: 400; onTriggered: root.linger = false }

    // the page stays while the pointer is on the rail or on the page; it folds back shortly after it has left both
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
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: card }

            Item {
                id: area
                anchors.fill: parent

                Rectangle {
                    id: card
                    readonly property real gap: 8
                    readonly property bool vertBar: root.side === "left" || root.side === "right"
                    width: root.which === "perf" ? 720 : 500
                    height: root.which === "perf" ? 316 : 156
                    radius: root.pal.rXl
                    color: Qt.alpha(root.pal.bg, root.pal.glassBarOpen !== undefined ? Math.max(0.82, root.pal.glassBarOpen) : 0.92)
                    border.width: 1
                    border.color: root.pal.lineSoft
                    clip: true
                    // music: up in the corner, performance: down in the corner (a top / bottom bar: left end / right end)
                    x: {
                        if (root.side === "left") return root.edge + gap
                        if (root.side === "right") return area.width - root.edge - width - gap
                        return root.which === "perf" ? area.width - width - 16 : 16
                    }
                    y: {
                        if (root.side === "top") return root.edge + gap
                        if (root.side === "bottom") return area.height - root.edge - height - gap
                        return root.which === "perf" ? area.height - height - 16 : 16
                    }
                    transformOrigin: root.side === "left" ? Item.Left : root.side === "right" ? Item.Right : root.side === "top" ? Item.Top : Item.Bottom
                    opacity: root.open ? 1 : 0
                    scale: root.open ? 1 : 0.92
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    Behavior on width { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

                    HoverHandler { onHoveredChanged: root.cardHover = hovered }
                    Keys.onEscapePressed: root.hide()

                    MediaPage {
                        anchors.fill: parent
                        pal: root.pal
                        player: root.player
                        opacity: root.which === "media" ? 1 : 0
                        visible: opacity > 0.01
                        Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                        onOpenMusic: tab => { root.hide(); root.openMusic(tab) }
                    }
                    PerfPage {
                        anchors.fill: parent
                        pal: root.pal
                        stats: root.stats
                        gpu: root.gpu
                        specs: root.specs
                        disks: root.disks
                        net: root.net
                        profile: root.profile
                        profileLabel: root.profileLabel
                        autoPower: root.autoPower
                        autoNote: root.autoNote
                        sysmode: root.sysmode
                        opacity: root.which === "perf" ? 1 : 0
                        visible: opacity > 0.01
                        Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
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
