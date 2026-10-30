import QtQuick

// Performance look "Sky" (the default; PerfTab.qml picks the look): the tab of the rail dashboard, drawn as a piece of Halcyon's sky instead of a grid of cards.
//   The machine is a constellation: five stars, CPU, memory, GPU, storage and network, joined by faint lines. Each star shines with its
//   own load (a bigger core, a wider halo, longer rays when it works hard; a quiet pinprick when it idles) and a few sparks run along the
//   lines, faster the busier the two stars they join are. Under the stars, "the last minute" is a star trail: the CPU's and the GPU's load
//   as two little constellations. On the right the battery is Halcyon's star (bright at 100 %, dimming slowly as it runs low, green halo while
//   it charges), with the power mode and the sysmode under it. The pane's own stars drift behind everything (NoteStars.qml, which follows
//   Settings > Appearance > Desktop builder and stops with Motion off).
//   Motion: opening the tab LIGHTS the sky up (the stars ignite one after the other with a small ring, the lines draw themselves from star
//   to star, the star trails sweep in, the battery star lights up); after that nothing jumps: every value is eased, so a star swells and shrinks with its
//   load instead of snapping each time the sampler reports, a star that gets too hot blends to red, and the star trails glide to the left
//   all the time (the newest point is the live value) instead of stepping once a second.
//   Cost: one Canvas, redrawn about 28 times a second and ONLY while the tab is on screen (`active`); a closed box does nothing. With
//   Motion turned right down (gaming mode) it is drawn once per change and does not animate.
// The same inputs and signals as PerfClassic.qml (the island's page); this tab only reads, so the four signals are never emitted here.
Item {
    id: root
    property var pal
    property var stats: ({})
    property var net: ({})
    property var gpu: ({ gpu: 0, state: "none" })
    property var specs: ({})
    property var disks: ({ disks: [] })
    property string profile: "balanced"
    property string profileLabel: "Balanced"
    property bool autoPower: false
    property string autoNote: ""
    property string sysmode: ""
    property bool active: false              // the tab is on screen
    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()

    implicitWidth: 704
    implicitHeight: 316

    // ------------------------------------------------------------ what the stars say
    readonly property bool hasBat: !!(stats && (stats.hasBat || stats.bat > 0 || (stats.batEst && stats.batEst !== "")))
    readonly property bool hasGpu: gpu.state !== "none"
    readonly property bool gpuOn: gpu.state === "on"
    readonly property real temp: Number(stats.temp || 0)
    readonly property real cpuLoad: Math.max(0, Math.min(1, Number(stats.cpu || 0) / 100))
    readonly property real memLoad: Math.max(0, Math.min(1, Number(stats.mem || 0) / 100))
    readonly property real gpuLoad: gpuOn ? Math.max(0, Math.min(1, Number(gpu.gpu || 0) / 100)) : 0
    readonly property var diskRows: {
        var out = []
        var d = (disks && disks.disks) ? disks.disks : []
        for (var i = 0; i < d.length; i++)
            out.push({ label: d[i].mount, frac: d[i].used / Math.max(1, d[i].size), used: d[i].used, size: d[i].size })
        return out
    }
    readonly property real stoLoad: diskRows.length > 0 ? Math.max(0, Math.min(1, diskRows[0].frac)) : 0
    readonly property real netBytes: Number(stats.down || 0) + Number(stats.up || 0)
    // 1 KB/s is a faint glow, 1 MB/s a bright one, 10 MB/s the brightest
    readonly property real netLoad: Math.max(0, Math.min(1, Math.log(1 + netBytes / 1024) / Math.LN10 / 4))
    readonly property real batLevel: Math.max(0, Math.min(100, Number(stats.bat || 0)))
    readonly property bool charging: stats.charging === true
    readonly property color batTint: charging ? pal.good : (batLevel <= 20 ? pal.bad : pal.accent)

    // ------------------------------------------------------------ eased values (what the sky actually draws)
    property real sCpu: cpuLoad
    property real sMem: memLoad
    property real sGpu: gpuLoad
    property real sSto: stoLoad
    property real sNet: netLoad
    property real sBat: batLevel
    Behavior on sCpu { enabled: root.live; NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
    Behavior on sMem { enabled: root.live; NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    Behavior on sGpu { enabled: root.live; NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
    Behavior on sSto { enabled: root.live; NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    Behavior on sNet { enabled: root.live; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
    Behavior on sBat { enabled: root.live; NumberAnimation { duration: 2000; easing.type: Easing.InOutSine } }
    // how red each star is (0 = its own colour, 1 = too hot): eased in the canvas, so it never flips
    property var hotMix: [0, 0, 0, 0, 0]

    // ------------------------------------------------------------ the lighting-up when the tab opens
    // intro runs 0 .. 1 in one go; every part of the sky takes its own slice of it (seg), eased out
    property real intro: 1
    function ease(x) { x = Math.max(0, Math.min(1, x)); return 1 - Math.pow(1 - x, 3) }
    function back(x) { x = Math.max(0, Math.min(1, x)); var c1 = 1.7, c3 = c1 + 1; return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2) }
    function seg(a, b) { return ease((intro - a) / (b - a)) }
    function stag(n) { return seg(n * 0.09, n * 0.09 + 0.5) }          // star n (0 .. 4) and its caption
    NumberAnimation {
        id: introAnim
        target: root
        property: "intro"
        from: 0
        to: 1
        duration: Math.max(1, Math.round(1500 * (root.pal ? root.pal.motion : 1)))
        easing.type: Easing.Linear
    }
    onIntroChanged: if (!live) sky.requestPaint()

    function rate(b) {
        b = b || 0
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s"
        if (b >= 1024) return Math.round(b / 1024) + " KB/s"
        return Math.round(b) + " B/s"
    }
    function bytes(b) {
        var g = b / 1e9
        return g >= 1000 ? (g / 1000).toFixed(1) + "T" : Math.round(g) + "G"
    }

    // the stars: 0 CPU, 1 memory, 2 GPU, 3 storage, 4 network.  High stars have their caption above, low ones below, so no line runs through a caption.
    readonly property var px: [62, 180, 298, 416, 534]
    readonly property real yHigh: 72
    readonly property real yLow: 146
    readonly property var edges: [[0, 1], [1, 2], [2, 3], [3, 4], [0, 2], [2, 4], [1, 3]]
    readonly property var tints: [pal.accent, pal.accent2, pal.accent, pal.accent2, pal.accent]
    readonly property var hot: [temp > 90, memLoad > 0.92, false, stoLoad > 0.9, false]

    // ------------------------------------------------------------ the last minute
    readonly property int samples: 60
    property var cpuHist: []
    property var gpuHist: []
    property double lastSampleMs: 0                  // when the newest point was added: the trails glide left from then on
    Timer {
        interval: 1000
        repeat: true
        running: root.active && root.visible
        triggeredOnStart: true
        onTriggered: {
            // one more point than the trail is wide: the oldest one slides out of the left edge instead of vanishing
            var a = root.cpuHist.slice(); a.push(root.sCpu); if (a.length > root.samples + 1) a.shift(); root.cpuHist = a
            var g = root.gpuHist.slice(); g.push(root.sGpu); if (g.length > root.samples + 1) g.shift(); root.gpuHist = g
            root.lastSampleMs = Date.now()
            if (!root.live) sky.requestPaint()
        }
    }

    // ------------------------------------------------------------ the sky
    property real t: 0
    readonly property bool live: active && visible && (pal ? pal.motion > 0.3 : true)
    onActiveChanged: {
        if (active) { if (pal && pal.motion > 0.3) introAnim.restart(); else { introAnim.stop(); intro = 1 } }
        sky.requestPaint()
    }
    Timer {
        interval: Math.round(36 * (root.pal ? root.pal.starSlow : 1))
        repeat: true
        running: root.live
        onTriggered: { root.t += interval / 1000; sky.requestPaint() }
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: root.pal.rLg
        clip: true
        border.width: root.pal.calm ? 0 : 1
        border.color: root.pal.lineSoft
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.alpha(root.pal.accent, 0.10) }
            GradientStop { position: 0.6; color: Qt.alpha(root.pal.accent2, 0.05) }
            GradientStop { position: 1.0; color: Qt.alpha(root.pal.text, 0.04) }
        }
        NoteStars {
            anchors.fill: parent
            pal: root.pal
            opt: ({})
            running: root.active
            count: 34
            speed: 0.6
        }
    }

    Canvas {
        id: sky
        anchors.fill: parent
        renderTarget: Canvas.FramebufferObject
        renderStrategy: Canvas.Immediate
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var P = root.pal
            var t = root.t
            function rgba(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }
            function mix(c1, c2, m) { return { r: c1.r + (c2.r - c1.r) * m, g: c1.g + (c2.g - c1.g) * m, b: c1.b + (c2.b - c1.b) * m } }
            function ray(s, dx, dy, l, al2) {
                var g2 = ctx.createLinearGradient(s.x - dx * l, s.y - dy * l, s.x + dx * l, s.y + dy * l)
                g2.addColorStop(0, rgba(s.c, 0))
                g2.addColorStop(0.5, rgba(s.c, al2))
                g2.addColorStop(1, rgba(s.c, 0))
                ctx.beginPath()
                ctx.moveTo(s.x - dx * l, s.y - dy * l)
                ctx.lineTo(s.x + dx * l, s.y + dy * l)
                ctx.strokeStyle = g2
                ctx.lineWidth = 1.2
                ctx.stroke()
            }
            // the eased loads (not the raw ones), and each star's slide towards red while it is too hot
            var L = [root.sCpu, root.sMem, root.hasGpu ? root.sGpu : 0.06, root.sSto, root.sNet]
            var N = []
            for (var i = 0; i < 5; i++) {
                root.hotMix[i] += ((root.hot[i] ? 1 : 0) - root.hotMix[i]) * 0.16
                N.push({ x: root.px[i], y: (i % 2 === 0) ? root.yHigh : root.yLow, load: L[i], c: mix(root.tints[i], P.bad, root.hotMix[i]), e: root.stag(i) })
            }

            // ---- the lines of the constellation: they draw themselves from one star to the next, then brighten with the load
            var sparkOn = root.seg(0.78, 1.0)
            for (var k = 0; k < root.edges.length; k++) {
                var a = N[root.edges[k][0]], b = N[root.edges[k][1]]
                var ep = root.seg(0.26 + k * 0.035, 0.7 + k * 0.035)
                if (ep <= 0.001) continue
                var avg = (a.load + b.load) / 2
                var al = 0.16 + 0.42 * avg
                var ex = a.x + (b.x - a.x) * ep, ey = a.y + (b.y - a.y) * ep
                var lg = ctx.createLinearGradient(a.x, a.y, b.x, b.y)
                lg.addColorStop(0, rgba(a.c, al))
                lg.addColorStop(1, rgba(b.c, al))
                ctx.beginPath()
                ctx.moveTo(a.x, a.y)
                ctx.lineTo(ex, ey)
                ctx.strokeStyle = lg
                ctx.lineWidth = 1
                ctx.stroke()
                if (sparkOn <= 0.01) continue
                // sparks that run along the line: slow when the two stars idle, quick when they work
                var ph = (t * (0.05 + 0.45 * avg) + k * 0.37) % 1
                for (var j = 0; j < 4; j++) {
                    var p = ph - j * 0.028
                    if (p < 0) p += 1
                    ctx.beginPath()
                    ctx.arc(a.x + (b.x - a.x) * p, a.y + (b.y - a.y) * p, 1.9 - j * 0.4, 0, 6.2832)
                    ctx.fillStyle = rgba(a.c, (0.35 + 0.55 * avg) * (1 - j * 0.26) * sparkOn)
                    ctx.fill()
                }
            }

            // ---- the stars: each one ignites in turn (a small ring goes out as it does), then breathes with its load
            for (var n = 0; n < 5; n++) {
                var s = N[n]
                var e = s.e
                if (e <= 0.001) continue
                var pop = root.back(e)
                var tw = 0.82 + 0.18 * Math.sin(t * 2.1 + n * 1.9)
                var r = (2.6 + 5.2 * s.load) * pop
                var gr = (r * 5 + 6) * (0.6 + 0.4 * e)
                var rg = ctx.createRadialGradient(s.x, s.y, 0, s.x, s.y, gr)
                rg.addColorStop(0, rgba(s.c, (0.20 + 0.45 * s.load) * tw * e))
                rg.addColorStop(1, rgba(s.c, 0))
                ctx.beginPath()
                ctx.arc(s.x, s.y, gr, 0, 6.2832)
                ctx.fillStyle = rg
                ctx.fill()
                if (e < 0.98) {
                    ctx.beginPath()
                    ctx.arc(s.x, s.y, 4 + 30 * e, 0, 6.2832)
                    ctx.strokeStyle = rgba(s.c, 0.5 * (1 - e))
                    ctx.lineWidth = 1
                    ctx.stroke()
                }
                // the rays: a cross, and a second one turned half way round when it is busy (it fades in with the load)
                var len = (8 + 26 * s.load) * tw * pop
                ray(s, 1, 0, len, 0.85 * e)
                ray(s, 0, 1, len, 0.85 * e)
                var diag = Math.max(0, Math.min(1, (s.load - 0.4) / 0.2))
                if (diag > 0.01) { ray(s, 0.7071, 0.7071, len * 0.6, 0.6 * diag * e); ray(s, 0.7071, -0.7071, len * 0.6, 0.6 * diag * e) }
                ctx.beginPath()
                ctx.arc(s.x, s.y, r, 0, 6.2832)
                ctx.fillStyle = rgba(s.c, e)
                ctx.fill()
                ctx.beginPath()
                ctx.arc(s.x, s.y, r * 0.45, 0, 6.2832)
                ctx.fillStyle = "rgba(255,255,255," + (0.85 * e) + ")"
                ctx.fill()
            }

            // ---- the last minute: two star trails that sweep in from the left, then glide left all the time
            var bx0 = 22, bx1 = 578, by0 = 232, bh = 62
            var rev = root.seg(0.35, 0.95)
            ctx.strokeStyle = rgba(P.text, 0.07 * rev)
            ctx.lineWidth = 1
            for (var gy = 0; gy <= 2; gy++) {
                var yy = Math.round(by0 + bh * gy / 2) + 0.5
                ctx.beginPath(); ctx.moveTo(bx0, yy); ctx.lineTo(bx0 + (bx1 - bx0) * rev, yy); ctx.stroke()
            }
            var fr = root.lastSampleMs > 0 ? Math.max(0, Math.min(1, (Date.now() - root.lastSampleMs) / 1000)) : 0
            if (!root.live) fr = 0
            function trail(h, head, col) {
                if (h.length < 1 || rev <= 0.001) return
                var step = (bx1 - bx0) / (root.samples - 1)
                var n2 = h.length
                ctx.save()
                ctx.beginPath()
                ctx.rect(bx0 - 2, by0 - 18, (bx1 - bx0 + 30) * rev, bh + 36)         // the sweep: it opens from the left
                ctx.clip()
                var fade = ctx.createLinearGradient(bx0, 0, bx1, 0)                    // the old end of the trail fades out
                fade.addColorStop(0, rgba(col, 0))
                fade.addColorStop(0.16, rgba(col, 0.55))
                fade.addColorStop(1, rgba(col, 0.55))
                ctx.beginPath()
                var started = false
                for (var q = 0; q < n2; q++) {
                    var xx = bx1 - (n2 - 1 - q + fr) * step
                    if (xx < bx0 - step) continue
                    var yv = by0 + bh - h[q] * bh
                    if (!started) { ctx.moveTo(xx, yv); started = true } else ctx.lineTo(xx, yv)
                }
                var hy = by0 + bh - head * bh
                if (started) ctx.lineTo(bx1, hy); else ctx.moveTo(bx1, hy)
                ctx.strokeStyle = fade
                ctx.lineWidth = 1.1
                ctx.lineJoin = "round"
                ctx.stroke()
                for (var q2 = 0; q2 < n2; q2++) {
                    var x2 = bx1 - (n2 - 1 - q2 + fr) * step
                    if (x2 < bx0) continue
                    var fa = Math.min(1, (x2 - bx0) / 48)
                    ctx.beginPath()
                    ctx.arc(x2, by0 + bh - h[q2] * bh, 0.9 + 1.5 * h[q2], 0, 6.2832)
                    ctx.fillStyle = rgba(col, (0.55 + 0.4 * h[q2]) * fa)
                    ctx.fill()
                }
                // the live point at the head is the bright one
                var lg2 = ctx.createRadialGradient(bx1, hy, 0, bx1, hy, 11)
                lg2.addColorStop(0, rgba(col, 0.7))
                lg2.addColorStop(1, rgba(col, 0))
                ctx.beginPath()
                ctx.arc(bx1, hy, 11, 0, 6.2832)
                ctx.fillStyle = lg2
                ctx.fill()
                ctx.beginPath()
                ctx.arc(bx1, hy, 1.9 + 1.5 * head, 0, 6.2832)
                ctx.fillStyle = rgba(col, 0.95)
                ctx.fill()
                ctx.restore()
            }
            if (root.hasGpu) trail(root.gpuHist, root.sGpu, P.accent2)
            trail(root.cpuHist, root.sCpu, P.accent)

            // ---- the battery: Halcyon's own star (the splash's mark). It dims slowly as the charge drops, down to a faint star inside
            // its thin outline; it lights up as the tab opens, and while it charges it is green and its halo breathes
            if (root.hasBat) {
                var me = root.seg(0.45, 0.95)
                var cx = 648, cy = 46, R = 28
                var f = Math.max(0, Math.min(1, root.sBat / 100))
                var lit = 0.2 + 0.8 * f
                var bc = root.batTint
                var Rs = R * (0.55 + 0.45 * root.back(me))
                function bstar(rv, rh, kc) {
                    var c = Math.min(rv, rh) * kc
                    ctx.beginPath()
                    ctx.moveTo(cx, cy - rv)
                    ctx.quadraticCurveTo(cx + c, cy - c, cx + rh, cy)
                    ctx.quadraticCurveTo(cx + c, cy + c, cx, cy + rv)
                    ctx.quadraticCurveTo(cx - c, cy + c, cx - rh, cy)
                    ctx.quadraticCurveTo(cx - c, cy - c, cx, cy - rv)
                    ctx.closePath()
                }
                var br = root.charging ? 0.7 + 0.3 * Math.sin(t * 2.2) : 0.8
                var hr = R * 2.3
                var hg = ctx.createRadialGradient(cx, cy, 0, cx, cy, hr)
                hg.addColorStop(0, rgba(bc, 0.5 * lit * lit * br * me))
                hg.addColorStop(0.5, rgba(bc, 0.14 * lit * lit * br * me))
                hg.addColorStop(1, rgba(bc, 0))
                ctx.beginPath(); ctx.arc(cx, cy, hr, 0, 6.2832); ctx.fillStyle = hg; ctx.fill()
                bstar(Rs, Rs * 0.84, 0.11)                                           // the outline stays, whatever the charge
                ctx.strokeStyle = rgba(bc, 0.34 * me)
                ctx.lineWidth = 1
                ctx.stroke()
                bstar(Rs, Rs * 0.84, 0.11)
                ctx.fillStyle = rgba(bc, lit * me)
                ctx.fill()
                var cg = ctx.createRadialGradient(cx, cy, 0, cx, cy, Rs * 0.42)
                cg.addColorStop(0, "rgba(255,255,255," + (0.9 * lit * me) + ")")
                cg.addColorStop(1, "rgba(255,255,255,0)")
                ctx.beginPath(); ctx.arc(cx, cy, Rs * 0.42, 0, 6.2832); ctx.fillStyle = cg; ctx.fill()
            }
        }
    }

    // ------------------------------------------------------------ the captions
    SkyLabel {
        pal: root.pal
        x: root.px[0] - width / 2; y: root.yHigh - 12 - height
        opacity: root.stag(0)
        transform: Translate { y: (1 - root.stag(0)) * 8 }
        name: "CPU"
        value: Math.round(root.cpuLoad * 100) + "%"
        detail: (root.temp > 0 ? Math.round(root.temp) + "°C" : "") + (root.specs.cores ? (root.temp > 0 ? " · " : "") + root.specs.cores + " cores" : "")
        tint: root.hot[0] ? root.pal.bad : root.pal.accent
    }
    SkyLabel {
        pal: root.pal
        x: root.px[1] - width / 2; y: root.yLow + 12
        opacity: root.stag(1)
        transform: Translate { y: (1 - root.stag(1)) * 8 }
        name: "Memory"
        value: Math.round(root.memLoad * 100) + "%"
        detail: (root.stats.memGb || "0.0") + "G" + ((root.specs.ram && root.specs.ram.total) ? " of " + root.specs.ram.total : "")
        tint: root.hot[1] ? root.pal.bad : root.pal.accent2
    }
    SkyLabel {
        pal: root.pal
        x: root.px[2] - width / 2; y: root.yHigh - 12 - height
        opacity: root.stag(2)
        transform: Translate { y: (1 - root.stag(2)) * 8 }
        name: "GPU"
        value: !root.hasGpu ? "—" : (root.gpuOn ? Math.round(root.gpuLoad * 100) + "%" : "off")
        detail: !root.hasGpu ? "none found" : (root.gpuOn ? "awake" : "asleep, saving power")
        tint: root.gpuOn ? root.pal.accent : root.pal.muted
    }
    SkyLabel {
        pal: root.pal
        x: root.px[3] - width / 2; y: root.yLow + 12
        opacity: root.stag(3)
        transform: Translate { y: (1 - root.stag(3)) * 8 }
        name: "Storage"
        value: root.diskRows.length > 0 ? Math.round(root.stoLoad * 100) + "%" : "—"
        detail: root.diskRows.length > 0
                ? root.bytes(root.diskRows[0].used) + " of " + root.bytes(root.diskRows[0].size) + (root.diskRows.length > 1 ? "  +" + (root.diskRows.length - 1) : "")
                : "no disks found"
        tint: root.hot[3] ? root.pal.bad : root.pal.accent2
    }
    SkyLabel {
        pal: root.pal
        x: root.px[4] - width / 2; y: root.yHigh - 12 - height
        opacity: root.stag(4)
        transform: Translate { y: (1 - root.stag(4)) * 8 }
        name: "Network"
        value: "↓ " + root.rate(root.stats.down)
        valueSize: 16
        detail: "↑ " + root.rate(root.stats.up)
        tint: root.pal.accent
    }

    // the key to the star trails
    Text {
        x: 22; y: 212
        opacity: root.seg(0.35, 0.8)
        text: "Last minute"
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap - 1
        font.letterSpacing: 1.4
        font.capitalization: Font.AllUppercase
    }
    Row {
        x: 578 - width; y: 212
        opacity: root.seg(0.35, 0.8)
        spacing: 12
        Row {
            spacing: 5
            Rectangle { width: 6; height: 6; radius: 3; color: root.pal.accent; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "CPU"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1 }
        }
        Row {
            visible: root.hasGpu
            spacing: 5
            Rectangle { width: 6; height: 6; radius: 3; color: root.pal.accent2; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "GPU"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1 }
        }
    }

    // ---- the right column: the star's charge, the power mode and the sysmode
    Rectangle { x: 598; y: 16; width: 1; height: (root.height - 32) * root.seg(0.2, 0.7); color: root.pal.line }
    Text {
        visible: root.hasBat
        opacity: root.seg(0.5, 0.95)
        x: 604; y: 80; width: 88
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(root.sBat) + "%"
        color: root.batTint
        font.family: root.pal.uiFont
        font.pixelSize: 20
        font.weight: Font.DemiBold
    }
    Text {
        visible: root.hasBat
        opacity: root.seg(0.55, 1.0)
        x: 604; y: 106; width: 88
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.charging ? "charging" : (root.stats.batEst ? String(root.stats.batEst) : "")
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
    }
    SkyLabel {
        pal: root.pal
        x: 604; y: 158; width: 88
        opacity: root.seg(0.6, 1.0)
        transform: Translate { y: (1 - root.seg(0.6, 1.0)) * 8 }
        name: "Power"
        value: root.profileLabel
        valueSize: 15
        detail: root.autoPower ? "auto" + (root.autoNote !== "" ? " · " + root.autoNote : "") : ""
        tint: root.pal.accent2
    }
    SkyLabel {
        pal: root.pal
        x: 604; y: 224; width: 88
        opacity: root.seg(0.68, 1.0)
        transform: Translate { y: (1 - root.seg(0.68, 1.0)) * 8 }
        name: "Sysmode"
        value: root.sysmode !== "" ? root.sysmode : "not set"
        valueSize: 15
        detail: ""
        tint: root.pal.modeColor[root.sysmode] || root.pal.muted
    }
}
