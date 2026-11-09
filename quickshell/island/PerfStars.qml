import QtQuick

// Performance look "Stars": six live four-point stars, the same star as the splash screen's sparkle and PerfSky's battery star (four curved
// quadratic sides, pinched in). CPU, Memory, GPU, Storage, Network and the Battery each drift slowly on a small path of their own inside their
// own part of the pane, so they never overlap. USAGE DECIDES THE LIGHT: a part at rest is a small, dim star with short rays; as its load
// grows the core gets bigger and whiter, the halo wider and brighter, the four rays longer, and above about 40 % a second pair of diagonal rays
// fades in. All of it comes from the eased loads, so a star swells and dims smoothly. Network uses the display scale, Storage the used percent,
// the Battery the charge (it dims as it falls, green with a slow pulse while charging). GPU asleep is only a faint outline, and it brightens
// briefly when the GPU wakes. Every star twinkles, and now and then a tiny shooting star crosses the background. A star turns red (pal.bad)
// only past a limit (CPU over 90 C, memory over 92 %, storage over 90 %, battery at 20 % or less). No constellation lines, no sparks (that is Sky).
// Small labels follow the stars. Motion right down: the stars sit at fixed spots, no twinkle, no shooting star.
// Cost: one Canvas, repainted by PerfBase.frame() only while the tab is on screen; at most about 6 draw calls per star plus the shooting star.
PerfBase {
    id: root

    readonly property var names: ["CPU", "Memory", "GPU", "Storage", "Network", "Battery"]
    // the centre of each star's own region, how far it drifts, how fast (rad / s) and a phase of its own
    readonly property var homeX: [118, 352, 586, 118, 352, 586]
    readonly property var homeY: [102, 98, 102, 222, 226, 222]
    readonly property var ampX: [30, 34, 30, 30, 34, 30]
    readonly property var ampY: [13, 15, 13, 13, 15, 13]
    readonly property var wX: [0.17, 0.13, 0.19, 0.14, 0.18, 0.12]
    readonly property var wY: [0.23, 0.19, 0.15, 0.21, 0.16, 0.2]
    readonly property var ph: [0.0, 1.7, 3.1, 4.4, 2.3, 5.5]
    readonly property bool still: !pal || pal.motion <= 0.3
    function sx(i) { return homeX[i] + (still ? 0 : ampX[i] * Math.sin(wX[i] * t + ph[i])) }
    function sy(i) { return homeY[i] + (still ? 0 : ampY[i] * Math.sin(wY[i] * t + ph[i] * 1.3 + 1)) }

    // eased copies for this look
    property real sNetS: netLoad
    Behavior on sNetS { enabled: root.live; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
    onSNetSChanged: if (!live) frame()
    property real awake: gpuOn ? 1 : 0
    Behavior on awake { enabled: root.live; NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    property real wake: 0                                   // a short brightening when the GPU turns on
    onGpuOnChanged: if (gpuOn && live) wakeAnim.restart()
    NumberAnimation { id: wakeAnim; target: root; property: "wake"; from: 1; to: 0; duration: 1100; easing.type: Easing.OutCubic }
    onAwakeChanged: if (!live) frame()

    readonly property var es: [sCpu, sMem, hasGpu ? sGpu * awake : 0, sSto, sNetS, Math.max(0, Math.min(1, sBat / 100))]
    readonly property var hots: [cpuHot, memHot, false, stoHot, false, hasBat && batLevel <= 20]
    property var hotMix: [0, 0, 0, 0, 0, 0]
    property var shoot: null                                // the shooting star now crossing: { t0, x, y, dx, dy }
    property real nextShoot: 5

    function labelText(i) {
        if (i === 5) return hasBat ? "Battery  " + Math.round(sBat) + "%" : "Battery  —"
        return names[i] + "  " + lanes[i].value
    }

    PerfBack { pal: root.pal; running: root.active; stars: 22 }

    Canvas {
        id: cv
        anchors.fill: parent
        renderTarget: Canvas.FramebufferObject
        renderStrategy: Canvas.Immediate
        Connections { target: root; function onFrame() { cv.requestPaint() } }
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!root.pal) return
            var P = root.pal
            var rgba = root.rgba
            var t = root.t
            var calm = root.still
            // the star's shape: rv = upright arm, rh = sideways arm, k = how deep the sides curve in (the splash's / PerfSky's)
            function star(cx, cy, rv, rh, kc) {
                var c = Math.min(rv, rh) * kc
                ctx.beginPath()
                ctx.moveTo(cx, cy - rv)
                ctx.quadraticCurveTo(cx + c, cy - c, cx + rh, cy)
                ctx.quadraticCurveTo(cx + c, cy + c, cx, cy + rv)
                ctx.quadraticCurveTo(cx - c, cy + c, cx - rh, cy)
                ctx.quadraticCurveTo(cx - c, cy - c, cx, cy - rv)
                ctx.closePath()
            }
            var BASE = [P.accent, P.accent2, P.accent, P.accent2, P.accent, root.batTint]

            // a tiny shooting star now and then
            if (!calm && root.live) {
                if (!root.shoot && t > root.nextShoot) {
                    var fromLeft = Math.random() < 0.5
                    root.shoot = { t0: t, x: fromLeft ? 30 + Math.random() * 200 : 470 + Math.random() * 200, y: 14 + Math.random() * 50, dx: fromLeft ? 1 : -1, dy: 0.45 }
                }
                if (root.shoot) {
                    var q = (t - root.shoot.t0) / 0.9
                    if (q >= 1) { root.shoot = null; root.nextShoot = t + 8 + Math.random() * 9 }
                    else {
                        var hx = root.shoot.x + root.shoot.dx * q * 150, hy = root.shoot.y + root.shoot.dy * q * 150
                        var tx = hx - root.shoot.dx * 34, ty = hy - root.shoot.dy * 34
                        var sg = ctx.createLinearGradient(tx, ty, hx, hy)
                        sg.addColorStop(0, rgba(P.text, 0)); sg.addColorStop(1, rgba(P.text, 0.8 * Math.sin(q * Math.PI)))
                        ctx.strokeStyle = sg; ctx.lineWidth = 1.5; ctx.lineCap = "round"
                        ctx.beginPath(); ctx.moveTo(tx, ty); ctx.lineTo(hx, hy); ctx.stroke()
                    }
                }
            }

            for (var i = 0; i < 6; i++) {
                root.hotMix[i] += ((root.hots[i] ? 1 : 0) - root.hotMix[i]) * 0.16
                var me = root.seg(0.05 + i * 0.09, 0.6 + i * 0.09)
                if (me <= 0.001) continue
                var asleep = (i === 2)
                var aw = asleep ? (root.hasGpu ? root.awake : 0) : 1
                var e = Math.max(0, Math.min(1, root.es[i] + (asleep ? root.wake * 0.5 : 0)))
                var col = root.mix(BASE[i], P.bad, root.hotMix[i])
                if (asleep && aw < 1) col = root.mix(P.muted, col, aw)
                var cx = root.sx(i), cy = root.sy(i)
                var tw = calm ? 0 : Math.sin(t * 1.3 + root.ph[i] * 2)
                var tw2 = calm ? 0 : Math.sin(t * 1.9 + root.ph[i] * 3)
                var pulse = (i === 5 && root.charging && !calm) ? 0.7 + 0.3 * Math.sin(t * 2.2) : 1
                var R = (8 + 26 * e * (i === 5 ? 1 : 1)) * (1 + 0.07 * tw2) * (0.55 + 0.45 * root.back(me))
                var on = aw * me

                // halo: wider and brighter with the load
                if (on > 0.01) {
                    var hr = R * (1.7 + 0.8 * e) * (1 + 0.06 * tw)
                    var ha = (0.10 + 0.45 * e) * pulse * on
                    var hg = ctx.createRadialGradient(cx, cy, 0, cx, cy, hr)
                    hg.addColorStop(0, rgba(col, ha)); hg.addColorStop(0.5, rgba(col, ha * 0.28)); hg.addColorStop(1, rgba(col, 0))
                    ctx.fillStyle = hg
                    ctx.beginPath(); ctx.arc(cx, cy, hr, 0, 6.2832); ctx.fill()
                }
                // above about 40 %: a second pair of rays on the diagonals fades in
                var de = Math.max(0, Math.min(1, (e - 0.4) / 0.25)) * on
                if (de > 0.01) {
                    ctx.save()
                    ctx.translate(cx, cy); ctx.rotate(Math.PI / 4)
                    star(0, 0, R * 0.62, R * 0.52, 0.11)
                    ctx.fillStyle = rgba(col, 0.55 * de)
                    ctx.fill()
                    ctx.restore()
                }
                // the star's thin outline stays (a sleeping GPU is only this); the body fills with the load
                star(cx, cy, R, R * 0.84, 0.11)
                ctx.strokeStyle = rgba(col, 0.34 * me)
                ctx.lineWidth = 1
                ctx.stroke()
                if (on > 0.01) {
                    star(cx, cy, R, R * 0.84, 0.11)
                    ctx.fillStyle = rgba(col, (0.30 + 0.65 * e) * pulse * on)
                    ctx.fill()
                    // the core: bigger and whiter with the load
                    var cr = R * (0.30 + 0.25 * e)
                    var cg = ctx.createRadialGradient(cx, cy, 0, cx, cy, cr)
                    cg.addColorStop(0, "rgba(255,255,255," + ((0.25 + 0.7 * e) * on) + ")")
                    cg.addColorStop(1, "rgba(255,255,255,0)")
                    ctx.fillStyle = cg
                    ctx.beginPath(); ctx.arc(cx, cy, cr, 0, 6.2832); ctx.fill()
                }
            }
        }
    }

    // a small label that follows each star (its place is a smooth function of time, so it never jitters)
    Repeater {
        model: 6
        Text {
            id: lb
            required property int index
            width: 140
            horizontalAlignment: Text.AlignHCenter
            x: root.sx(index) - width / 2
            y: root.sy(index) + 42
            opacity: root.seg(0.2 + index * 0.09, 0.8 + index * 0.09)
            text: root.labelText(index)
            color: root.hots[index] ? root.pal.bad : (index === 2 && root.hasGpu && !root.gpuOn ? root.pal.muted : root.pal.text)
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium
        }
    }

    // top right, one tiny line
    Text {
        anchors.right: parent.right; anchors.rightMargin: 24
        y: 16
        opacity: root.seg(0.3, 0.8)
        text: root.profileLabel + (root.sysmode !== "" ? "  ·  " + root.sysmode : "")
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
}
