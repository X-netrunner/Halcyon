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
    // left | right | top | bottom: a rail sits on that edge and draws the border's width there itself (CustomBar.qml: band). The ring leaves
    // that edge out, so the border is never laid over the bar: bar and border are one band. Empty = no such bar (or it is auto-hidden).
    property string bandSide: ""
    property string _bandWas: ""
    onBandSideChanged: if (bandSide !== "") _bandWas = bandSide
    property real bandAmt: bandSide !== "" ? 1 : 0
    Behavior on bandAmt { NumberAnimation { duration: root.pal ? root.pal.dSlow : 400; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal ? root.pal.curve : [0.34, 0.8, 0.34, 1, 1, 1] } }

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
        // thickness of each edge of the ring: 0 on the edge the rail draws itself, and the inner corners next to it are square (a round
        // corner there would show as a thin arc over the bar)
        readonly property real tl: root._bandWas === "left" ? root.t * (1 - root.bandAmt) : root.t
        readonly property real tr: root._bandWas === "right" ? root.t * (1 - root.bandAmt) : root.t
        readonly property real tt: root._bandWas === "top" ? root.t * (1 - root.bandAmt) : root.t
        readonly property real tb: root._bandWas === "bottom" ? root.t * (1 - root.bandAmt) : root.t
        readonly property real rTL: Math.max(0.01, rr * Math.min(1, tl / root.t, tt / root.t))
        readonly property real rTR: Math.max(0.01, rr * Math.min(1, tr / root.t, tt / root.t))
        readonly property real rBR: Math.max(0.01, rr * Math.min(1, tr / root.t, tb / root.t))
        readonly property real rBL: Math.max(0.01, rr * Math.min(1, tl / root.t, tb / root.t))

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
                PathMove { x: ring.tl + ring.rTL; y: ring.tt }
                PathArc { x: ring.tl; y: ring.tt + ring.rTL; radiusX: ring.rTL; radiusY: ring.rTL; direction: PathArc.Counterclockwise }
                PathLine { x: ring.tl; y: ring.h - ring.tb - ring.rBL }
                PathArc { x: ring.tl + ring.rBL; y: ring.h - ring.tb; radiusX: ring.rBL; radiusY: ring.rBL; direction: PathArc.Counterclockwise }
                PathLine { x: ring.w - ring.tr - ring.rBR; y: ring.h - ring.tb }
                PathArc { x: ring.w - ring.tr; y: ring.h - ring.tb - ring.rBR; radiusX: ring.rBR; radiusY: ring.rBR; direction: PathArc.Counterclockwise }
                PathLine { x: ring.w - ring.tr; y: ring.tt + ring.rTR }
                PathArc { x: ring.w - ring.tr - ring.rTR; y: ring.tt; radiusX: ring.rTR; radiusY: ring.rTR; direction: PathArc.Counterclockwise }
                PathLine { x: ring.tl + ring.rTL; y: ring.tt }
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
