import QtQuick
import Quickshell
import Quickshell.Wayland

// The room a rail takes along its screen edge (so tiled windows stop at it). The rail's own window has to ignore the zones other windows
// reserve, or the border around the screen shrinks it and it stops short of the border; this 1 px window reserves the room instead.
//   side   left | right | top | bottom      zone   px to keep free (the border + the rail)
Scope {
    id: root
    property bool on: false
    property string side: "left"
    property int zone: 0
    readonly property bool vert: side === "left" || side === "right"

    PanelWindow {
        visible: root.on && root.zone > 0
        anchors { top: root.side !== "bottom"; bottom: root.side !== "top"; left: root.side !== "right"; right: root.side !== "left" }
        implicitWidth: root.vert ? 1 : 0
        implicitHeight: root.vert ? 0 : 1
        exclusiveZone: root.zone
        color: "transparent"
        WlrLayershell.namespace: "island-rail-edge"
        WlrLayershell.layer: WlrLayer.Bottom
        mask: Region {}
    }
}
