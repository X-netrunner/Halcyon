import QtQuick

// Squash and stretch for a panel that moves or resizes: while it travels fast it stretches a little along the direction of travel and
// pinches the other way, then settles back to exactly 1. This is the part of the Caelestia shell's liquid "blob" panels that you feel
// (its boxes deform with their velocity); it costs next to nothing: one Scale transform on the GPU, and a FrameAnimation that only
// runs while the panel is actually moving (nothing at rest, no timers, no shader).
//
//   Jelly { target: someItem; pal: pal; originX: 0.5; originY: 0 }
//
//   originX / originY   where the item is pinned while it deforms, as a fraction of its size (0.5, 0 = the middle of the top edge, so a
//                       box that drops from the top stays glued to it; 1, 0.5 = the right edge, for a box that slides out from the right)
//   pinchX / pinchY     0 = do not deform sideways / vertically (a box joined to the screen border must keep its flush sides)
//   maxStretch          the largest deformation (0.06 = 6 %) at `amount` 1
//
// Off when Settings > Motion > "Jelly motion" is off, in Gaming / lean mode and when motion is turned down (pal.motion <= 0.3).
Item {
    id: j
    property Item target
    property var pal
    property real originX: 0.5
    property real originY: 0
    property real pinchX: 1
    property real pinchY: 1
    property real maxStretch: 0.06
    property real speedRef: 1400            // px/s at which the stretch is half of maxStretch
    property real settle: 0.09             // seconds: how quickly the deformation follows the motion and lets go

    readonly property real amount: pal && pal.jellyAmt !== undefined ? pal.jellyAmt : 1
    readonly property bool allowed: !!target && !!pal && pal.jelly === true && pal.motion > 0.3 && amount > 0
    property real sx: 1
    property real sy: 1
    property bool busy: false
    property real _w: 0
    property real _h: 0
    property real _x: 0
    property real _y: 0
    property real _fx: 0                    // smoothed 0..1 "how fast is it moving horizontally / vertically"
    property real _fy: 0
    property int _still: 0

    visible: false
    width: 0; height: 0

    Scale {
        id: sc
        origin.x: j.target ? j.target.width * j.originX : 0
        origin.y: j.target ? j.target.height * j.originY : 0
        xScale: j.sx
        yScale: j.sy
    }

    Component.onCompleted: {
        if (!target) return
        var t = []
        for (var i = 0; i < target.transform.length; i++) t.push(target.transform[i])
        t.push(sc)
        target.transform = t
        _w = target.width; _h = target.height; _x = target.x; _y = target.y
    }

    function wake() { if (allowed) { _still = 0; busy = true } }
    Connections {
        target: j.target
        function onWidthChanged() { j.wake() }
        function onHeightChanged() { j.wake() }
        function onXChanged() { j.wake() }
        function onYChanged() { j.wake() }
    }
    onAllowedChanged: if (!allowed) { busy = false; sx = 1; sy = 1; _fx = 0; _fy = 0 }

    FrameAnimation {
        running: j.busy && j.allowed
        onTriggered: {
            var dt = Math.max(0.001, Math.min(0.05, frameTime))
            var t = j.target
            // how far the panel's leading edge moved this frame, per second (sliding and growing both count)
            var vx = (Math.abs(t.width - j._w) + Math.abs(t.x - j._x)) / dt
            var vy = (Math.abs(t.height - j._h) + Math.abs(t.y - j._y)) / dt
            j._w = t.width; j._h = t.height; j._x = t.x; j._y = t.y
            var rx = vx / (vx + j.speedRef), ry = vy / (vy + j.speedRef)     // soft 0..1, no spikes from one big jump
            var a = 1 - Math.exp(-dt / j.settle)
            j._fx += (rx - j._fx) * a
            j._fy += (ry - j._fy) * a
            var m = j.maxStretch * 2 * j.amount
            j.sx = 1 + m * (j._fx - 0.6 * j._fy) * j.pinchX
            j.sy = 1 + m * (j._fy - 0.6 * j._fx) * j.pinchY
            if (j._fx < 0.002 && j._fy < 0.002 && vx < 1 && vy < 1) {
                if (++j._still > 6) { j.busy = false; j.sx = 1; j.sy = 1; j._fx = 0; j._fy = 0 }
            } else j._still = 0
        }
    }
}
