import QtQuick

// Performance look "Sea" (Part 1): a calm sea under a sky that follows the THEME.
//   Day / night: Settings > Theme. Light theme = a sun (soft rays, a few clouds), dark theme = a moon with a halo and twinkling stars; the two cross-fade
//   in 800 ms when the theme changes. (`day` below is the one line to change if it should follow the wallpaper's brightness instead:
//   pal.wallLum is 0 .. 1, but it only tracks the picture on the dark theme, so the theme is what decides today.)
//   Every colour is mixed from the wallpaper palette (pal.bg, accent, accent2, text); only the status colours (good, warn, bad) are fixed by Pal.
//   The sun / moon is also the battery: its light follows the charge (dimmer as it falls), a slow green pulse while it charges, red at 20 % or less.
//   The waves: height of the middle wave = CPU, the slow swell behind it = memory, the foam on the front wave runs with the network.
//   Four buoys ride the middle wave: CPU, memory, GPU, storage (name + value from `lanes`). A buoy turns red only past a limit (PerfBase cpuHot ...);
//   GPU asleep is a grey buoy. The sky warms (pal.warn) as the CPU gets hotter than 80 C.
//   Motion: opening the tab raises the waves from the bottom and drops the buoys in one after another; after that values are eased.
//   Cost: one Canvas repainted by PerfBase.frame() only while the tab is on screen; Motion right down paints once per change.
PerfBase {
    id: root

    readonly property bool day: pal ? pal.light : false
    property real dm: day ? 1 : 0                              // 0 = night .. 1 = day (eased)
    Behavior on dm { enabled: root.live; NumberAnimation { duration: 800; easing.type: Easing.InOutSine } }
    onDmChanged: if (!live) frame()
    readonly property real heatT: Math.max(0, Math.min(1, (temp - 80) / 15))
    property real heat: heatT
    Behavior on heat { enabled: root.live; NumberAnimation { duration: 1500; easing.type: Easing.InOutSine } }
    onHeatChanged: if (!live) frame()

    readonly property var buoyX: [92, 244, 396, 548]
    property real lastT: 0
    property real foamPh: 0

    Rectangle {
        id: frameBox
        anchors.fill: parent
        radius: root.pal.rLg
        clip: true
        color: "transparent"
        border.width: root.pal.calm ? 0 : 1
        border.color: root.pal.lineSoft

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
                var W = width, H = height
                var t = root.t
                var rgba = root.rgba, mix = root.mix
                var WHITE = { r: 1, g: 1, b: 1 }
                var dm = root.dm
                var dt = Math.max(0, Math.min(0.2, t - root.lastT))
                root.lastT = t
                var net = Math.max(root.sDown, root.sUp)
                root.foamPh += dt * (10 + 90 * net)

                // ---- the colours: both palettes from the wallpaper's colours, blended by dm (day / night)
                var heat = root.heat
                var skyTopN = mix(P.bg, P.accent, 0.16), skyMidN = mix(P.bg, P.accent2, 0.30), horN = mix(P.bg, P.accent, 0.50)
                var skyTopD = mix(P.accent, WHITE, 0.62), skyMidD = mix(P.accent2, WHITE, 0.50), horD = mix(P.accent2, { r: 1, g: 0.94, b: 0.82 }, 0.55)
                var skyTop = mix(skyTopN, skyTopD, dm), skyMid = mix(skyMidN, skyMidD, dm), hor = mix(horN, horD, dm)
                skyMid = mix(skyMid, P.warn, 0.35 * heat)
                hor = mix(hor, P.warn, 0.45 * heat)
                var sky = ctx.createLinearGradient(0, 0, 0, 230)
                sky.addColorStop(0, rgba(skyTop, 1))
                sky.addColorStop(0.6, rgba(skyMid, 1))
                sky.addColorStop(1, rgba(hor, 1))
                ctx.fillStyle = sky
                ctx.fillRect(0, 0, W, H)
                var shallow = mix(mix(P.accent, P.bg, 0.45), mix(P.accent2, WHITE, 0.25), dm)
                var deep = mix(mix(P.bg, P.accent, 0.25), mix(P.accent, P.text, 0.35), dm)

                // ---- the stars of the night and the clouds of the day
                var starA = (1 - dm) * root.seg(0.05, 0.5)
                if (starA > 0.01) {
                    for (var s = 0; s < 22; s++) {
                        var sx = (s * 97.3 + 31) % W, sy = 10 + (s * 53.7) % 150
                        var tw = 0.35 + 0.65 * Math.abs(Math.sin(t * 1.3 + s * 1.7))
                        ctx.beginPath()
                        ctx.arc(sx, sy, s % 5 === 0 ? 1.5 : 1, 0, 6.2832)
                        ctx.fillStyle = rgba(WHITE, 0.75 * tw * starA)
                        ctx.fill()
                    }
                }
                var cloudA = dm * root.seg(0.1, 0.6)
                if (cloudA > 0.01) {
                    for (var c = 0; c < 2; c++) {
                        var cx0 = ((t * (5 + c * 3) + c * 330) % (W + 220)) - 110
                        var cy0 = 46 + c * 52
                        ctx.fillStyle = rgba(WHITE, 0.42 * cloudA)
                        ctx.beginPath(); ctx.arc(cx0, cy0, 15, 0, 6.2832); ctx.fill()
                        ctx.beginPath(); ctx.arc(cx0 + 18, cy0 - 7, 19, 0, 6.2832); ctx.fill()
                        ctx.beginPath(); ctx.arc(cx0 + 40, cy0, 14, 0, 6.2832); ctx.fill()
                        ctx.beginPath(); ctx.arc(cx0 + 20, cy0 + 4, 16, 0, 6.2832); ctx.fill()
                    }
                }

                // ---- the sun and the moon: also the battery
                var me = root.seg(0.1, 0.6)
                var bx0 = 620, by0 = 64, R = 26
                var f = root.hasBat ? 0.35 + 0.65 * Math.max(0, Math.min(1, root.sBat / 100)) : 1
                var low = root.hasBat && root.batLevel <= 20
                var pulse = root.charging ? 0.7 + 0.3 * Math.sin(t * 2.2) : 0.9
                var sunCol = mix({ r: 1, g: 0.92, b: 0.66 }, P.accent2, 0.12)
                var moonCol = mix(WHITE, P.accent, 0.10)
                var haloSun = (root.charging || low) ? root.batTint : sunCol
                var haloMoon = (root.charging || low) ? root.batTint : moonCol
                if (dm > 0.01) {
                    var a1 = dm * me
                    var hs = ctx.createRadialGradient(bx0, by0, R * 0.4, bx0, by0, R * 3.2)
                    hs.addColorStop(0, rgba(haloSun, 0.5 * f * pulse * a1)); hs.addColorStop(1, rgba(haloSun, 0))
                    ctx.beginPath(); ctx.arc(bx0, by0, R * 3.2, 0, 6.2832); ctx.fillStyle = hs; ctx.fill()
                    for (var r = 0; r < 12; r++) {
                        var ra = t * 0.12 + r * 0.5236
                        var l0 = R * 1.35, l1 = R * (1.75 + 0.25 * Math.sin(t * 1.1 + r * 1.3))
                        ctx.beginPath()
                        ctx.moveTo(bx0 + l0 * Math.cos(ra), by0 + l0 * Math.sin(ra))
                        ctx.lineTo(bx0 + l1 * Math.cos(ra), by0 + l1 * Math.sin(ra))
                        ctx.strokeStyle = rgba(sunCol, 0.55 * f * a1)
                        ctx.lineWidth = 2
                        ctx.lineCap = "round"
                        ctx.stroke()
                    }
                    ctx.beginPath(); ctx.arc(bx0, by0, R, 0, 6.2832); ctx.fillStyle = rgba(sunCol, f * a1); ctx.fill()
                    ctx.beginPath(); ctx.arc(bx0 - 6, by0 - 6, R * 0.5, 0, 6.2832); ctx.fillStyle = rgba(WHITE, 0.4 * f * a1); ctx.fill()
                }
                if (dm < 0.99) {
                    var a2 = (1 - dm) * me
                    var hm = ctx.createRadialGradient(bx0, by0, R * 0.5, bx0, by0, R * 3.0)
                    hm.addColorStop(0, rgba(haloMoon, 0.38 * f * pulse * a2)); hm.addColorStop(1, rgba(haloMoon, 0))
                    ctx.beginPath(); ctx.arc(bx0, by0, R * 3.0, 0, 6.2832); ctx.fillStyle = hm; ctx.fill()
                    ctx.beginPath(); ctx.arc(bx0, by0, R, 0, 6.2832); ctx.fillStyle = rgba(moonCol, f * a2); ctx.fill()
                    var cr = [[-8, -6, 6], [7, 4, 8], [-3, 12, 4]]
                    for (var q = 0; q < 3; q++) {
                        ctx.beginPath(); ctx.arc(bx0 + cr[q][0], by0 + cr[q][1], cr[q][2], 0, 6.2832)
                        ctx.fillStyle = rgba(mix(moonCol, P.bg, 0.35), 0.35 * f * a2); ctx.fill()
                    }
                }

                // ---- the waves
                var rise = (1 - root.seg(0, 0.6)) * 130
                function wy(base, amp, k, sp, ph, x) {
                    return base + rise + amp * Math.sin(x * k + t * sp + ph) + amp * 0.45 * Math.sin(x * k * 2.3 - t * sp * 1.4 + ph * 1.7)
                }
                function wave(base, amp, k, sp, ph, col, alpha) {
                    var g = ctx.createLinearGradient(0, base - amp, 0, H)
                    g.addColorStop(0, rgba(col, alpha))
                    g.addColorStop(1, rgba(mix(col, deep, 0.6), Math.min(1, alpha + 0.1)))
                    ctx.beginPath()
                    ctx.moveTo(0, H + 4)
                    for (var x = 0; x <= W + 8; x += 8) ctx.lineTo(x, wy(base, amp, k, sp, ph, x))
                    ctx.lineTo(W + 8, H + 4)
                    ctx.closePath()
                    ctx.fillStyle = g
                    ctx.fill()
                }
                var swellAmp = 4 + 14 * root.sMem
                var midAmp = 4 + 16 * root.sCpu
                var frontAmp = 3 + 5 * net
                wave(196, swellAmp, 0.011, 0.35, 1.0, shallow, 0.55)
                wave(226, midAmp, 0.015, 0.6, 2.2, mix(shallow, deep, 0.45), 0.85)

                // ---- the buoys ride the middle wave
                var LN = root.lanes
                for (var i = 0; i < 4; i++) {
                    var e = root.seg(0.25 + i * 0.1, 0.7 + i * 0.1)
                    if (e <= 0.001 || !LN || LN.length < 4) continue
                    var tint = LN[i].tint
                    var bx = root.buoyX[i]
                    var drop = -(1 - root.back(e)) * 46
                    var by = wy(226, midAmp, 0.015, 0.6, 2.2, bx) - 3 + Math.sin(t * 1.6 + i * 1.3) * 1.5 + drop
                    var ld = LN[i].load
                    var gl = ctx.createRadialGradient(bx, by - 16, 0, bx, by - 16, 8 + 16 * ld)
                    gl.addColorStop(0, rgba(tint, 0.65 * e)); gl.addColorStop(1, rgba(tint, 0))
                    ctx.beginPath(); ctx.arc(bx, by - 16, 8 + 16 * ld, 0, 6.2832); ctx.fillStyle = gl; ctx.fill()
                    ctx.beginPath(); ctx.moveTo(bx, by - 15); ctx.lineTo(bx, by - 2)
                    ctx.strokeStyle = rgba(tint, 0.85 * e); ctx.lineWidth = 2; ctx.stroke()
                    ctx.beginPath(); ctx.arc(bx, by - 16, 3.4, 0, 6.2832); ctx.fillStyle = rgba(WHITE, 0.9 * e); ctx.fill()
                    ctx.beginPath(); ctx.arc(bx, by, 8, Math.PI, 0, false); ctx.closePath()
                    ctx.fillStyle = rgba(tint, 0.95 * e); ctx.fill()
                    var rf = ctx.createLinearGradient(0, by, 0, by + 26)
                    rf.addColorStop(0, rgba(tint, 0.30 * e)); rf.addColorStop(1, rgba(tint, 0))
                    ctx.fillStyle = rf
                    ctx.fillRect(bx - 3, by, 6, 26)
                }

                wave(262, frontAmp, 0.02, 0.9, 3.4, deep, 0.95)
                // foam on the front wave: it runs faster with the network
                ctx.lineCap = "round"
                for (var fm = 0; fm < 14; fm++) {
                    var fx = (fm * 54 + root.foamPh) % W
                    var fy = wy(262, frontAmp, 0.02, 0.9, 3.4, fx) - 1
                    ctx.beginPath(); ctx.moveTo(fx - 6, fy); ctx.lineTo(fx + 6, fy)
                    ctx.strokeStyle = rgba(WHITE, (0.25 + 0.3 * net) * root.seg(0.2, 0.7))
                    ctx.lineWidth = 1.5
                    ctx.stroke()
                }
            }
        }

        // the bottom line: speeds on the left, power mode and sysmode on the right
        Rectangle {
            x: 0; y: root.height - 40; width: root.width; height: 40
            color: Qt.alpha(root.pal.bg, 0.55)
            opacity: root.seg(0.4, 1.0)
            Text {
                x: 20; anchors.verticalCenter: parent.verticalCenter
                text: "↓ " + root.rate(root.stats.down) + "     ↑ " + root.rate(root.stats.up)
                color: root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 2
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 20; anchors.verticalCenter: parent.verticalCenter
                text: root.profileLabel + (root.sysmode !== "" ? " · " + root.sysmode : "")
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 2
            }
        }
    }

    // ---- the buoys' names and values
    Repeater {
        model: root.lanes.length >= 4 ? 4 : 0
        delegate: Item {
            id: lab
            required property int index
            readonly property var ln: root.lanes[index]
            readonly property real e: root.seg(0.25 + index * 0.1, 0.7 + index * 0.1)
            x: root.buoyX[index] - 60; y: 120
            width: 120; height: 52
            opacity: e
            transform: Translate { y: (1 - lab.e) * -10 }
            Text {
                width: parent.width; horizontalAlignment: Text.AlignHCenter
                text: lab.ln.name
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4
                font.capitalization: Font.AllUppercase
            }
            Text {
                y: 14
                width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                text: lab.ln.value
                color: lab.ln.hot ? root.pal.bad : root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: 24; font.weight: Font.DemiBold
            }
        }
    }

    // the battery's number under the sun / moon (red only at 20 % or less, green while charging)
    Text {
        visible: root.hasBat
        opacity: root.seg(0.3, 0.8)
        x: 580; y: 100; width: 80
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(root.sBat) + "%"
        color: (root.charging || root.batLevel <= 20) ? root.batTint : root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.Medium
    }
}
