import QtQuick

// A card that leans toward the pointer, like a real card pressed down on one side: the side under the pointer comes up, the far side
// goes down, and it follows the pointer smoothly while it moves over the card. Leaving the card lets it lie flat again. Nothing is drawn
// at rest and nothing runs when the pointer is elsewhere.
//
//   Rectangle {
//       HoverTilt { id: tilt; pal: pal }                  // anchors to the card (the card must not be laid out by a Layout inside)
//       z: tilt.t > 0.01 ? 2 : 0                          // the card under the pointer is drawn above its neighbours
//       transform: Matrix4x4 { matrix: tilt.matrix }
//   }
//
// Qt Quick's own Rotation has no perspective (a few degrees would only squeeze the card by half a percent), so the lean is a small
// perspective matrix: the raised side is a little bigger, the low side a little smaller. `lean` is how far the edge goes up / down in
// px, so a wide card and a narrow one tilt the same amount. If it leans the wrong way on your Qt, flip `way` to -1.
Item {
    id: ht
    property var pal
    property real lean: 10                   // px the edge under the pointer comes up (and the opposite one goes down)
    property real depth: 480                 // the viewing distance of the perspective, px: smaller = a stronger effect
    property real pop: 0                     // kept for old callers; the card does not grow any more, it only tips
    property real reach: 6                   // px around the card that still count as "on it", so the edge does not flicker
    property real way: 1
    readonly property bool live: !!pal && pal.motion > 0.3
    readonly property bool hovered: hv.hovered
    property real t: hv.hovered && live ? 1 : 0
    Behavior on t { NumberAnimation { duration: ht.pal ? ht.pal.dFast : 200; easing.type: Easing.OutCubic } }

    // where the pointer is on the card: -1 (left / top edge) .. 1 (right / bottom edge), eased so the card follows without snapping
    property real nx: hv.hovered && live && width > 0 ? Math.max(-1, Math.min(1, hv.point.position.x / width * 2 - 1)) : 0
    property real ny: hv.hovered && live && height > 0 ? Math.max(-1, Math.min(1, hv.point.position.y / height * 2 - 1)) : 0
    Behavior on nx { NumberAnimation { duration: ht.pal ? ht.pal.dFast : 200; easing.type: Easing.OutCubic } }
    Behavior on ny { NumberAnimation { duration: ht.pal ? ht.pal.dFast : 200; easing.type: Easing.OutCubic } }

    readonly property matrix4x4 matrix: {
        var w = width, h = height
        if (w < 1 || h < 1) return Qt.matrix4x4()
        var cx = w / 2, cy = h / 2, d = depth
        var a = Math.asin(Math.min(1, lean / cx)) * nx * way          // around the vertical axis: left / right
        var b = -Math.asin(Math.min(1, lean / cy)) * ny * way         // around the horizontal axis: top / bottom
        var ca = Math.cos(a), sa = Math.sin(a), cb = Math.cos(b), sb = Math.sin(b)
        // rotation R = Rx(b) * Ry(a), turned about the card's middle, then a perspective divide by (1 + z / d)
        // The z row of the matrix is deliberately NOT the rotated z. Qt Quick's batch renderer orders layers (background, tiles, text, ...)
        // with the depth buffer; a tilted plane gives every pixel a different depth, so across the card's middle the layers started to hide
        // each other (text and tiles cut off along diagonal wedges). With z kept at 0 the card still tips (the picture comes from x / y / w)
        // but every layer keeps its own depth, so nothing is cut.
        var r11 = ca, r12 = 0, r13 = sa
        var r21 = sb * sa, r22 = cb, r23 = -sb * ca
        var r31 = -cb * sa, r32 = sb, r33 = cb * ca
        var tx = -(r11 * cx + r12 * cy), ty = -(r21 * cx + r22 * cy), tz = -(r31 * cx + r32 * cy)
        var p0 = r31 / d, p1 = r32 / d, p2 = r33 / d, p3 = tz / d + 1
        return Qt.matrix4x4(r11 + cx * p0, r12 + cx * p1, r13 + cx * p2, tx + cx * p3,
                            r21 + cy * p0, r22 + cy * p1, r23 + cy * p2, ty + cy * p3,
                            0, 0, 1, 0,                       // depth row: keep z flat (see the note above), only x / y / w carry the tilt
                            p0, p1, p2, p3)
    }

    anchors.fill: parent
    z: -1
    HoverHandler { id: hv; margin: ht.reach }
}
