import QtQuick

// Moving stars for the notes panels (new note, all notes, clipboard, screenshot, lyrics and queue): the same stars as the desktop ones.
// They slide across the pane at three depths (far and slow, near and quick), twinkle, the near ones have a small glint, and now and
// then a shooting star crosses. Direction, speed, size and colour follow Settings > Appearance > Desktop builder (opt.deskStarDir /
// Speed / Size / Tone), so changing them there changes these too. Count, twinkle and the shooting stars are fixed here (the pane is small).
// One Canvas for all of them (no scene-graph node per star), a timer that only runs while the panel is on screen, and it stops by
// itself when motion is turned down (Settings > Motion).
Item {
    id: root
    property var pal
    opacity: pal ? pal.decor : 1          // the calm interface keeps the moving stars, softly (Pal.decor)
    property var opt: ({})                  // the island's settings (root.opt in shell.qml); only the deskStar* keys are read
    property bool running: true
    property int count: 44
    property real speed: 1

    readonly property real deskSpeed: Math.max(0.1, Math.min(4, opt && opt.deskStarSpeed !== undefined ? Number(opt.deskStarSpeed) : 1))
    readonly property real sizeK: Math.max(0.5, Math.min(3, opt && opt.deskStarSize !== undefined ? Number(opt.deskStarSize) : 1))
    readonly property string dir: (opt && opt.deskStarDir) || "right"       // right | left | up | down | diag
    readonly property string tone: (opt && opt.deskStarTone) || "mix"       // accent | mix | white
    readonly property real vx: dir === "right" ? 1 : dir === "left" ? -1 : dir === "diag" ? 1 : 0
    readonly property real vy: dir === "down" ? 1 : dir === "up" ? -1 : dir === "diag" ? 0.4 : 0

    readonly property bool live: running && visible && width > 0 && height > 0 && (pal ? pal.motion > 0.3 : true)
    property real t: 0                      // seconds of falling so far
    property real lastMs: 0

    Timer {
        interval: Math.round(40 * (root.pal ? root.pal.starSlow : 1))
        repeat: true
        running: root.live
        onRunningChanged: root.lastMs = 0
        onTriggered: {
            var now = Date.now()
            root.t += root.lastMs > 0 ? Math.min(0.25, (now - root.lastMs) / 1000) : interval / 1000
            root.lastMs = now
            canvas.requestPaint()
        }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        visible: root.live
        renderTarget: Canvas.FramebufferObject
        renderStrategy: Canvas.Immediate

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var w = width, h = height, t = root.t, n = root.count, sp = root.speed * root.deskSpeed, szK = root.sizeK
            var vx = root.vx, vy = root.vy, tone = root.tone
            var a1 = root.pal ? String(root.pal.accent) : "#9aa9d4"
            var a2 = root.pal ? String(root.pal.accent2) : "#c2add8"
            var light = root.pal ? root.pal.light : false
            for (var i = 0; i < n; i++) {
                var fx = (i * 0.6180339 + 0.17) % 1
                var fy = (i * 0.4142135 + 0.31) % 1
                var depth = i % 3                                   // 0 far and slow, 2 near and quick
                var rate = 0.016 * sp * (0.5 + 0.55 * depth)        // fraction of the pane per second
                var px = (((fx + vx * rate * t + 0.008 * Math.sin(t * 0.35 + i * 1.7)) % 1) + 1) % 1
                var py = (((fy + vy * rate * t + 0.008 * Math.cos(t * 0.31 + i * 1.3)) % 1) + 1) % 1
                var ex = Math.min(1, Math.min(px, 1 - px) * w / 28)
                var ey = Math.min(1, Math.min(py, 1 - py) * h / 40)
                var size = (1.2 + depth * 0.65 + (i % 4) * 0.2) * szK
                var tw = 0.5 + 0.5 * Math.sin(6.2832 * (t * (0.1 + (i % 5) * 0.05) + fx * 7))
                var op = ex * ey * (0.32 + 0.2 * depth) * (0.4 + 0.6 * tw)
                if (op < 0.012) continue
                var tint = tone === "white" ? (light ? a1 : "#ffffff")
                         : tone === "accent" ? a1
                         : (light ? (i % 2 === 0 ? a1 : a2) : (i % 3 === 0 ? a1 : (i % 3 === 1 ? a2 : "#ffffff")))
                var cx = px * w, cy = py * h
                ctx.fillStyle = tint
                ctx.globalAlpha = op
                ctx.beginPath()
                ctx.arc(cx, cy, size / 2, 0, 6.2832)
                ctx.fill()
                if (depth === 2 && i % 2 === 0) {                   // the glint of a near star: a small cross
                    ctx.globalAlpha = op * 0.5
                    var gl = size * 4.5
                    ctx.fillRect(cx - gl / 2, cy - 0.5, gl, 1)
                    ctx.fillRect(cx - 0.5, cy - gl / 2, 1, gl)
                }
            }
            ctx.globalAlpha = 1
        }
    }

    // a shooting star, one at a time, every 5 to 12 seconds, crossing the way the stars drift (a pure left / right or up / down drift
    // gets a slight slant, like the desktop's)
    Item {
        id: shot
        property real prog: 0
        property real sx: 0
        property real sy: 0
        readonly property real tx: root.vx !== 0 ? root.vx * 0.35 : 0.10       // how far it travels, as a share of the pane
        readonly property real ty: root.vy !== 0 ? root.vy * 0.35 : 0.22
        visible: prog > 0 && prog < 1
        x: sx + prog * root.width * tx
        y: sy + prog * root.height * ty
        opacity: Math.sin(Math.PI * prog) * 0.9
        rotation: Math.atan2(ty * root.height, tx * root.width) * 180 / Math.PI
        Rectangle {
            width: 70; height: 1.5
            x: -width; y: -height / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.alpha(root.pal ? root.pal.accent2 : "#c2add8", 0.95) }
            }
        }
        Rectangle { width: 3; height: 3; radius: 1.5; x: -1.5; y: -1.5; color: root.pal && root.pal.light ? root.pal.accent : "#ffffff" }
        NumberAnimation on prog { id: shotAnim; running: false; from: 0; to: 1; duration: 1100; easing.type: Easing.InOutSine }
    }
    Timer {
        interval: 3500
        repeat: true
        running: root.live
        onTriggered: {
            interval = 5000 + Math.random() * 7000
            // start on the side the stars come from, so the streak crosses the pane instead of leaving it at once
            shot.sx = root.width * (shot.tx < 0 ? 0.45 + Math.random() * 0.5 : 0.05 + Math.random() * 0.5)
            shot.sy = root.height * (shot.ty < 0 ? 0.5 + Math.random() * 0.45 : 0.02 + Math.random() * 0.35)
            shotAnim.restart()
        }
    }
}
