import QtQuick
import Quickshell
import Quickshell.Wayland

// The spot that wakes one of the corner boxes (notifications, utilities, background apps, console), anywhere on any edge of the screen.
// Desktop builder: drag the tag of a box along the screen's edges; opt.boxZone says where (DeskSpots.js zoneOf). With no zone the box wakes
// from its own corner, as before, and this file does nothing (no window at all).
//   hover mode   touching the strip wakes the box; leaving it is passed on after `graceMs`, so there is time to move the pointer on to the box,
//                which can be far away (the box opens from its corner, the strip may be in the middle of an edge)
//   click mode   a faint dot marks the spot and a click toggles the box
Scope {
    id: root
    property var pal
    property var zone: null                 // { edge, pos } or null
    property bool clickMode: false
    property bool blocked: false            // a fullscreen window: nothing wakes
    property int graceMs: 1100
    signal hoverChanged(bool on)
    signal tapped()

    property bool inside: false
    function enter() { leaveT.stop(); if (!inside) { inside = true; hoverChanged(true) } }
    function leave() { leaveT.restart() }
    Timer { id: leaveT; interval: root.graceMs; onTriggered: { if (root.inside) { root.inside = false; root.hoverChanged(false) } } }
    onBlockedChanged: if (blocked && inside) { leaveT.stop(); inside = false; hoverChanged(false) }

    LazyLoader {
        active: root.zone !== null && !root.blocked
        PanelWindow {
            id: win
            visible: true
            readonly property string edge: root.zone ? root.zone.edge : "right"
            readonly property bool vert: edge === "left" || edge === "right"
            readonly property int thick: root.clickMode ? 28 : 14
            readonly property int len: root.clickMode ? 44 : 120
            // a strip along the whole edge (click-through everywhere except the spot itself)
            anchors { top: edge !== "bottom"; bottom: edge !== "top"; left: edge !== "right"; right: edge !== "left" }
            implicitWidth: vert ? thick : 0
            implicitHeight: vert ? 0 : thick
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-wake"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: spot }

            Item {
                id: spot
                readonly property real p: root.zone ? root.zone.pos : 0.5
                width: win.vert ? win.thick : win.len
                height: win.vert ? win.len : win.thick
                x: win.vert ? (win.edge === "left" ? 0 : win.width - width) : Math.round(p * (win.width - width))
                y: win.vert ? Math.round(p * (win.height - height)) : (win.edge === "top" ? 0 : win.height - height)

                HoverHandler {
                    enabled: !root.clickMode
                    onHoveredChanged: { if (hovered) root.enter(); else root.leave() }
                }
                TapHandler {
                    enabled: root.clickMode
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.tapped()
                }
                // click mode: a faint dot marks the spot (the same dot the corners show)
                Rectangle {
                    visible: root.clickMode
                    anchors.centerIn: parent
                    width: 12; height: 12; radius: 6
                    color: Qt.alpha(root.pal.accent, 0.35)
                }
            }
        }
    }
}
