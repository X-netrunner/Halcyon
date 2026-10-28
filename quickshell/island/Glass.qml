import QtQuick
import QtQuick.Shapes

// The shared surface: translucent body (the compositor blurs behind it), a neutral hairline,
// and a faint top sheen so it reads as a slightly curved pane of frosted glass rather than a flat fill.
Rectangle {
    id: root
    property var pal
    property real opacityBody: pal.glass
    property bool shadow: true
    property color tint: "transparent"   // a colour laid over the body (a widget uses the wallpaper accent here); transparent = none
    property bool flat: false       // no body, no hairline, no sheen: something else draws the surface (the notch shape)

    // Border around the screen (ScreenFrame.qml): a box that opens from a screen edge is flush with the border, drawn in the
    // border's colour, and its corners where it meets the border flare out (concave) so box and border are one piece.
    //   joinH  "l" / "r": the box touches the left / right border      joinV  "t" / "b": the top / bottom border
    // Both empty (or the border off) = the ordinary floating glass pane. The flares reach `earR` px outside the box.
    property string joinH: ""
    property string joinV: ""
    property real earR: 16
    readonly property bool joined: !!pal && pal.frameOn === true && (joinH !== "" || joinV !== "")
    // with the border on, a pane that is not tinted (notifications, utilities, console ...) is painted in the border's own colour,
    // so a floating card and a box that flares into the border are the same colour as the border and the notch
    readonly property bool frameMatch: !!pal && pal.frameOn === true && !flat && tint.a === 0
    readonly property real _pad: earR + 4
    // the outline as an SVG path, walked clockwise from the top-left corner. Every corner is one of: square (both of its sides
    // are flush), a concave flare (one side flush) or a normal round corner. `o` shifts it into the Shape that is a little bigger.
    function silhouette(o) {
        var w = width, h = height
        var e = Math.max(0, Math.min(earR, w / 2, h / 2))
        var R = Math.max(0, Math.min(radius, w / 2, h / 2))
        var fl = joinH === "l", fr = joinH === "r", ft = joinV === "t", fb = joinV === "b"
        // corner x, corner y, quarter turns, flush on the edge it arrives along, flush on the edge it leaves along
        var cs = [[0, 0, 0, fl, ft], [w, 0, 1, ft, fr], [w, h, 2, fr, fb], [0, h, 3, fb, fl]]
        var d = ""
        function put(c, x, y, cmd) {
            for (var i = 0; i < c[2]; i++) { var t = x; x = -y; y = t }
            return cmd + " " + (c[0] + o + x) + " " + (c[1] + o + y) + " "
        }
        function arc(c, rad, sweep, x, y) {
            for (var i = 0; i < c[2]; i++) { var t = x; x = -y; y = t }
            return "A " + rad + " " + rad + " 0 0 " + sweep + " " + (c[0] + o + x) + " " + (c[1] + o + y) + " "
        }
        for (var k = 0; k < 4; k++) {
            var c = cs[k], before = c[3], after = c[4], first = (k === 0)
            var m = first ? "M" : "L"
            if (before && after) d += put(c, 0, 0, m)
            else if (after) { d += put(c, 0, e, m) + arc(c, e, 0, -e, 0) }
            else if (before) { d += put(c, 0, -e, m) + arc(c, e, 0, e, 0) }
            else { d += put(c, 0, R, m) + arc(c, R, 1, R, 0) }
        }
        return d + "Z"
    }

    // the light of the pane: on the dark theme it is the text colour (a soft light edge); on the light theme a dark edge would look like
    // a bruise, so the sheen and the top line are white there and a little stronger (white on pale needs more to show)
    readonly property color sheenCol: pal.light ? "#ffffff" : pal.text
    readonly property real sheenA: pal.light ? 0.50 : 0.055
    readonly property real edgeA: pal.light ? 0.90 : 0.20

    color: (flat || joined) ? "transparent" : (frameMatch ? pal.frameCol : Qt.alpha(Qt.tint(pal.bg, tint), opacityBody))
    // the calm style draws its own neutral hairline (below), so an accent outline a window asks for does not show there
    border.width: flat || joined || pal.calm ? 0 : 1
    border.color: pal.lineTint
    Rectangle {
        visible: !root.flat && !root.joined && root.pal.calm
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1             // the pane keeps its one hairline in every calm style; only what is inside it loses outlines
        border.color: root.pal.line
    }

    // the box joined to the border: same fill as the border and the bar (pal.frameCol), flares into the border
    Shape {
        visible: root.joined
        z: -1
        x: -root._pad; y: -root._pad
        width: root.width + 2 * root._pad
        height: root.height + 2 * root._pad
        preferredRendererType: Shape.CurveRenderer
        antialiasing: true
        ShapePath {
            fillColor: root.pal ? root.pal.frameCol : "#14161f"
            strokeColor: "transparent"
            strokeWidth: 0
            PathSvg { path: root.joined ? root.silhouette(root._pad) : "" }
        }
    }

    // sheen: lighter at the top edge, gone by ~45% height (legacy style; the calm panes are flat)
    Rectangle {
        visible: !root.flat && !root.joined && !root.frameMatch && !root.pal.calm
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.alpha(root.sheenCol, root.sheenA) }
            GradientStop { position: 0.45; color: Qt.alpha(root.sheenCol, 0.0) }
        }
    }

    // top-edge highlight: a crisp 1px light line that fades out toward the corners, so the pane looks raised
    Rectangle {
        visible: !root.flat && !root.joined && !root.frameMatch && !root.pal.calm && root.height > 40
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Math.max(8, root.radius * 0.6)
        anchors.rightMargin: Math.max(8, root.radius * 0.6)
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.alpha(root.sheenCol, 0.0) }
            GradientStop { position: 0.5; color: Qt.alpha(root.sheenCol, root.edgeA) }
            GradientStop { position: 1.0; color: Qt.alpha(root.sheenCol, 0.0) }
        }
    }

    Shadow {
        visible: root.shadow && !root.joined && root.pal.boxShadow
        z: -1
        anchors.fill: parent
        radius: root.radius
        // calm: wider and fainter, the pane floats instead of sitting on a dark edge
        // new: wide, soft and a little deeper, the one pane floats over the wallpaper
        spread: root.pal.zen ? 34 : root.pal.calm ? 28 : 22
        drop: root.pal.zen ? 14 : root.pal.calm ? 10 : 6
        strength: root.pal.zen ? 0.024 : root.pal.calm ? 0.02 : 0.026
    }
}
