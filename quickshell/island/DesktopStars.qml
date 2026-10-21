import QtQuick

// Moving stars for the desktop (Settings > Appearance > Desktop builder). Lives inside Wallpaper.qml, ABOVE the picture, so it
// works on a wallpaper, on a blurred one and on the plain background you get with the wallpaper switched off.
//   count / speed / size / direction / colour / twinkle / shooting stars all come from opt.desk* (Desktop builder).
// Ultra-optimized: Uses a single hardware-accelerated Canvas with precomputed star matrices and direct rect blits.
Item {
    id: root
    property var pal
    property var opt: ({})
    property var env: null
    property real previewScale: 1          // the builder's small preview draws the same stars smaller
    property bool forceOn: false           // the builder preview shows them even while the real ones are off

    readonly property bool on: forceOn || (opt && opt.deskStars === true)
    readonly property int count: Math.max(10, Math.min(250, opt && opt.deskStarCount !== undefined ? Number(opt.deskStarCount) : 70))
    readonly property real speed: Math.max(0.1, Math.min(4, opt && opt.deskStarSpeed !== undefined ? Number(opt.deskStarSpeed) : 1))
    readonly property real sizeK: Math.max(0.5, Math.min(3, opt && opt.deskStarSize !== undefined ? Number(opt.deskStarSize) : 1)) * previewScale
    readonly property string dir: (opt && opt.deskStarDir) || "right"       // right | left | up | down | diag
    readonly property string tone: (opt && opt.deskStarTone) || "mix"       // accent | mix | white
    readonly property bool twinkle: !(opt && opt.deskStarTwinkle === false)
    readonly property bool shooting: opt && opt.deskStarShoot === true
    readonly property real vx: dir === "right" ? 1 : dir === "left" ? -1 : dir === "diag" ? 1 : 0
    readonly property real vy: dir === "down" ? 1 : dir === "up" ? -1 : dir === "diag" ? 0.4 : 0

    // Suppress painting when desktop is obscured (locked screen, fullscreen window, gaming mode)
    readonly property bool covered: (env && env.gaming) || (env && env.screenLocked) || (env && env.fsQuiet)
    readonly property bool live: on && visible && width > 0 && height > 0 && (pal ? pal.motion > 0.3 : true) && !covered
    property real t: 0                      // seconds of drifting so far (kept while hidden, so the stars carry on)

    // Precompute invariant static star calculations to eliminate hot-loop JS math and GC churn
    property var cachedStars: []
    function rebuildStars() {
        var arr = []
        var n = root.count
        var sp = root.speed, szK = root.sizeK
        for (var i = 0; i < n; i++) {
            var fx = (i * 0.6180339 + 0.11) % 1
            var fy = (i * 0.4142135 + 0.23) % 1
            var depth = i % 3
            var rate = 0.012 * sp * (0.5 + 0.55 * depth)
            var size = (1.1 + depth * 0.7 + (i % 4) * 0.25) * szK
            var base = 0.35 + 0.22 * depth
            var twFreq = 6.2832 * (0.12 + (i % 5) * 0.06)
            var twPhase = 6.2832 * (fx * 7)
            var isCross = (depth === 2 && i % 2 === 0)
            var colorType = i % 3
            arr.push({ fx: fx, fy: fy, depth: depth, rate: rate, size: size, base: base,
                       twFreq: twFreq, twPhase: twPhase, isCross: isCross, colorType: colorType })
        }
        cachedStars = arr
    }
    onCountChanged: rebuildStars()
    onSpeedChanged: rebuildStars()
    onSizeKChanged: rebuildStars()
    Component.onCompleted: rebuildStars()

    // Smooth ~13.3 fps drift: visually silky, minimal CPU and allocator overhead
    property real lastMs: 0
    Timer {
        interval: Math.round(75 * (root.pal ? root.pal.starSlow : 1))
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
            var stars = root.cachedStars
            var len = stars.length
            var w = width, h = height
            var t = root.t
            var vx = root.vx, vy = root.vy
            var twOn = root.twinkle
            var tone = root.tone
            var pAccent = root.pal ? String(root.pal.accent) : "#88c0d0"
            var pAccent2 = root.pal ? String(root.pal.accent2) : "#81a1c1"

            var curTint = ""
            for (var i = 0; i < len; i++) {
                var s = stars[i]
                var px = (((s.fx + vx * s.rate * t) % 1) + 1) % 1
                var py = (((s.fy + vy * s.rate * t) % 1) + 1) % 1
                var ex = Math.min(1, Math.min(px, 1 - px) * w / 36)
                var ey = Math.min(1, Math.min(py, 1 - py) * h / 36)
                var tw = twOn ? (0.5 + 0.5 * Math.sin(t * s.twFreq + s.twPhase)) : 1.0
                var op = ex * ey * s.base * (twOn ? (0.35 + 0.65 * tw) : 1)
                if (op < 0.01) continue

                var tint = tone === "white" ? "#ffffff"
                         : tone === "accent" ? pAccent
                         : (s.colorType === 0 ? pAccent : (s.colorType === 1 ? pAccent2 : "#ffffff"))

                if (curTint !== tint) {
                    ctx.fillStyle = tint
                    curTint = tint
                }
                ctx.globalAlpha = op
                var cx = px * w
                var cy = py * h
                var sz = s.size
                var half = sz * 0.5

                ctx.fillRect(cx - half, cy - half, sz, sz)

                if (s.isCross) {
                    ctx.globalAlpha = op * 0.45
                    var gl = sz * 4.5
                    ctx.fillRect(cx - gl * 0.5, cy - 0.5, gl, 1)
                    ctx.fillRect(cx - 0.5, cy - gl * 0.5, 1, gl)
                }
            }
        }
    }

    // ---- an occasional shooting star (one at a time, every 6 to 15 seconds)
    Item {
        id: shot
        property real prog: 0
        property real sx: 0
        property real sy: 0
        visible: prog > 0 && prog < 1
        x: sx + prog * root.width * 0.22
        y: sy + prog * root.height * 0.16
        opacity: Math.sin(Math.PI * prog)
        rotation: 36
        Rectangle {
            width: 90 * root.previewScale + 20; height: Math.max(1, 1.5 * root.previewScale)
            x: -width; y: -height / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.alpha(root.pal ? root.pal.accent2 : "#81a1c1", 0.95) }
            }
        }
        Rectangle { width: 3 * root.previewScale + 1; height: width; radius: width / 2; x: -width / 2; y: -width / 2; color: "#ffffff" }
        NumberAnimation on prog { id: shotAnim; running: false; from: 0; to: 1; duration: 950; easing.type: Easing.InOutSine }
    }
    Timer {
        interval: 5000
        repeat: true
        running: root.live && root.shooting
        onTriggered: {
            interval = 6000 + Math.random() * 9000
            shot.sx = root.width * (0.15 + Math.random() * 0.6)
            shot.sy = root.height * (0.02 + Math.random() * 0.4)
            shotAnim.restart()
        }
    }
}
