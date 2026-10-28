import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland

// A border around the whole screen (Settings > Bar style > Border around the screen).
//
// The bar (Notch / Custom) hangs from its top edge, and every box (notifications, utilities, console, app menu ...) slides in from a
// screen edge. The frame is drawn ABOVE all of them, so a box does not appear out of nowhere: it comes out from under the border.
// It is the same colour as the notch bar, the notifications and every other box (Pal.frameCol), so the bar and the pages that drop
// from it are one piece with the top of the frame. Nothing is laid over that colour: no sheen and no outline, so the border, the notch and the boxes read as one piece.
//
//   draw      one click-through window over the whole screen (overlay layer): a ring with rounded inner corners
//   reserve   the left, right and bottom edge each get a 1 px window that only reserves the border's width, so tiled windows stop at the
//             inner edge. The top edge is reserved by the bar itself (NotchBar / CustomBar / the island window in shell.qml), which
//             start `t` px lower and add `t` to their own zone, so the bar sits against the inner edge. A custom bar on the left, right or
//             bottom edge does the same for ITS edge (`skip`), and the island window then reserves the top.
//
// A fullscreen window hides the frame (`hidden`); the reservation stays, Hyprland draws a fullscreen window over it anyway.
Scope {
    id: root
    property var pal
    property bool on: false
    property int t: 12                 // thickness of the border in px
    property int r: 22                 // radius of the inner corners in px
    property bool hidden: false        // a window is fullscreen
    property string skip: ""           // left | right | bottom: a bar sits on that edge and reserves the border's width there itself (CustomBar.qml)

    // ---- the ring
    PanelWindow {
        id: ring
        visible: root.on && !root.hidden
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "island-frame"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}                // nothing in this window takes the pointer

        readonly property real w: width
        readonly property real h: height
        readonly property real t: root.t
        readonly property real rr: Math.max(1, Math.min(root.r, (Math.min(width, height) - 2 * root.t) / 2))

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            antialiasing: true

            // the outer rectangle runs clockwise and the inner rounded one counter-clockwise, so the inside is a hole
            ShapePath {
                fillColor: root.pal ? root.pal.frameCol : "#14161f"
                strokeColor: "transparent"
                strokeWidth: 0
                startX: 0; startY: 0
                PathLine { x: ring.w; y: 0 }
                PathLine { x: ring.w; y: ring.h }
                PathLine { x: 0; y: ring.h }
                PathLine { x: 0; y: 0 }
                PathMove { x: ring.t + ring.rr; y: ring.t }
                PathArc { x: ring.t; y: ring.t + ring.rr; radiusX: ring.rr; radiusY: ring.rr; direction: PathArc.Counterclockwise }
                PathLine { x: ring.t; y: ring.h - ring.t - ring.rr }
                PathArc { x: ring.t + ring.rr; y: ring.h - ring.t; radiusX: ring.rr; radiusY: ring.rr; direction: PathArc.Counterclockwise }
                PathLine { x: ring.w - ring.t - ring.rr; y: ring.h - ring.t }
                PathArc { x: ring.w - ring.t; y: ring.h - ring.t - ring.rr; radiusX: ring.rr; radiusY: ring.rr; direction: PathArc.Counterclockwise }
                PathLine { x: ring.w - ring.t; y: ring.t + ring.rr }
                PathArc { x: ring.w - ring.t - ring.rr; y: ring.t; radiusX: ring.rr; radiusY: ring.rr; direction: PathArc.Counterclockwise }
                PathLine { x: ring.t + ring.rr; y: ring.t }
            }
        }
    }

    // ---- the room it takes: left, right, bottom (the top belongs to the bar)
    PanelWindow {
        visible: root.on && root.skip !== "left"
        anchors { left: true; top: true; bottom: true }
        implicitWidth: 1
        exclusiveZone: root.t
        color: "transparent"
        WlrLayershell.namespace: "island-frame-edge"
        WlrLayershell.layer: WlrLayer.Bottom
        mask: Region {}
    }
    PanelWindow {
        visible: root.on && root.skip !== "right"
        anchors { right: true; top: true; bottom: true }
        implicitWidth: 1
        exclusiveZone: root.t
        color: "transparent"
        WlrLayershell.namespace: "island-frame-edge"
        WlrLayershell.layer: WlrLayer.Bottom
        mask: Region {}
    }
    PanelWindow {
        visible: root.on && root.skip !== "bottom"
        anchors { bottom: true; left: true; right: true }
        implicitHeight: 1
        exclusiveZone: root.t
        color: "transparent"
        WlrLayershell.namespace: "island-frame-edge"
        WlrLayershell.layer: WlrLayer.Bottom
        mask: Region {}
    }
}
