import QtQuick

// Performance look "Tiles": a bento of soft tiles, each part of the machine drawn the way it behaves.
//   CPU: a half-circle gauge with ticks. Memory: columns of little blocks that breathe like an equaliser, as many lit as memory is used.
//   GPU: a ring of 24 dots, lit by the load, one bright dot circling while it is awake. Storage: a donut for the first disk and a thin bar
//   for each disk (up to three). Network: two glowing waves, down and up, with the two speeds beside them. Battery: a stack of ten
//   cells that fill from the bottom (one pulses while it charges), then the power mode and the sysmode.
//   Motion: the tiles rise in one after the other and their drawings fill in; after that every value is eased. Cost: one Canvas for all
//   the drawings, repainted by PerfBase.frame() only while the tab is on screen; Motion right down paints once per change.
PerfBase {
    id: root

    readonly property var lc: lanes.length === 5 ? lanes : null
    property var hotMix: [0, 0, 0]

    PerfBack { pal: root.pal; running: root.active; stars: 16 }

    // ---- the tiles
    PerfTile { id: tCpu; pal: root.pal; reveal: root.seg(0.00, 0.5); x: 16; y: 16; width: 196; height: 136 }
    PerfTile { id: tMem; pal: root.pal; reveal: root.seg(0.07, 0.57); x: 222; y: 16; width: 156; height: 136 }
    PerfTile { id: tGpu; pal: root.pal; reveal: root.seg(0.14, 0.64); x: 388; y: 16; width: 156; height: 136 }
    PerfTile { id: tSto; pal: root.pal; reveal: root.seg(0.21, 0.71); x: 16; y: 162; width: 196; height: 138 }
    PerfTile { id: tNet; pal: root.pal; reveal: root.seg(0.28, 0.78); x: 222; y: 162; width: 322; height: 138 }
    PerfTile { id: tBat; pal: root.pal; reveal: root.seg(0.35, 0.85); x: 554; y: 16; width: 134; height: 284 }

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
            var t = root.t
            var rgba = root.rgba
            var HOT = [root.cpuHot, root.memHot, root.stoHot]
            for (var h = 0; h < 3; h++) root.hotMix[h] += ((HOT[h] ? 1 : 0) - root.hotMix[h]) * 0.16
            var cCpu = root.mix(P.accent, P.bad, root.hotMix[0])
            var cMem = root.mix(P.accent2, P.bad, root.hotMix[1])
            var cSto = root.mix(P.accent2, P.bad, root.hotMix[2])

            // ---- CPU: the half-circle gauge with its ticks
            var e = tCpu.reveal
            if (e > 0.001) {
                var gx = 114, gy = 130, gr = 56
                for (var k = 0; k <= 10; k++) {
                    var ta = Math.PI + Math.PI * k / 10
                    ctx.beginPath()
                    ctx.moveTo(gx + (gr + 9) * Math.cos(ta), gy + (gr + 9) * Math.sin(ta))
                    ctx.lineTo(gx + (gr + (k % 5 === 0 ? 15 : 12)) * Math.cos(ta), gy + (gr + (k % 5 === 0 ? 15 : 12)) * Math.sin(ta))
                    ctx.strokeStyle = rgba(P.text, 0.16 * e)
                    ctx.lineWidth = 1
                    ctx.stroke()
                }
                ctx.beginPath()
                ctx.arc(gx, gy, gr, Math.PI, 2 * Math.PI, false)
                ctx.strokeStyle = rgba(P.text, 0.07 * e)
                ctx.lineWidth = 10
                ctx.lineCap = "round"
                ctx.stroke()
                var ea = Math.PI + Math.PI * Math.max(0.012, root.sCpu) * e
                ctx.beginPath()
                ctx.arc(gx, gy, gr, Math.PI, ea, false)
                ctx.strokeStyle = rgba(cCpu, 0.16 + 0.1 * root.sCpu)
                ctx.lineWidth = 18
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(gx, gy, gr, Math.PI, ea, false)
                ctx.strokeStyle = rgba(cCpu, 0.95)
                ctx.lineWidth = 10
                ctx.stroke()
                var hx = gx + gr * Math.cos(ea), hy = gy + gr * Math.sin(ea)
                var hg = ctx.createRadialGradient(hx, hy, 0, hx, hy, 13)
                hg.addColorStop(0, rgba(cCpu, 0.7)); hg.addColorStop(1, rgba(cCpu, 0))
                ctx.beginPath(); ctx.arc(hx, hy, 13, 0, 6.2832); ctx.fillStyle = hg; ctx.fill()
                ctx.beginPath(); ctx.arc(hx, hy, 2.5, 0, 6.2832); ctx.fillStyle = "rgba(255,255,255,0.9)"; ctx.fill()
            }

            // ---- memory: columns of blocks that breathe
            e = tMem.reveal
            if (e > 0.001) {
                var cols = 16, rows = 6
                for (var c = 0; c < cols; c++) {
                    var wob = 0.84 + 0.16 * Math.sin(t * 1.4 + c * 0.75)
                    var lit = Math.round(rows * Math.max(0, Math.min(1, root.sMem * wob)) * e)
                    for (var r = 0; r < rows; r++) {
                        var on = r < lit
                        ctx.fillStyle = rgba(on ? cMem : P.text, on ? 0.35 + 0.6 * (r + 1) / rows : 0.07)
                        ctx.fillRect(236 + c * 8, 88 + (rows - 1 - r) * 6, 5, 4)
                    }
                }
            }

            // ---- GPU: a ring of dots, one bright dot circling while it is awake
            e = tGpu.reveal
            if (e > 0.001) {
                var rx = 498, ry = 92, rr = 30, dots = 24
                var litN = Math.round(dots * (root.hasGpu ? root.sGpu : 0) * e)
                var spin = root.gpuOn ? Math.floor(t * 7) % dots : -1
                for (var d = 0; d < dots; d++) {
                    var da = -Math.PI / 2 + 6.2832 * d / dots
                    var dx = rx + rr * Math.cos(da), dy = ry + rr * Math.sin(da)
                    var son = d < litN
                    ctx.beginPath()
                    ctx.arc(dx, dy, d === spin ? 3.4 : 2.5, 0, 6.2832)
                    ctx.fillStyle = d === spin ? "rgba(255,255,255,0.95)" : rgba(son ? P.accent : P.text, son ? 0.95 : (root.gpuOn ? 0.14 : 0.07))
                    ctx.fill()
                }
            }

            // ---- storage: the donut of the first disk
            e = tSto.reveal
            if (e > 0.001) {
                var sx = 58, sy = 246, sr = 30
                ctx.beginPath()
                ctx.arc(sx, sy, sr, 0, 6.2832 * e, false)
                ctx.strokeStyle = rgba(P.text, 0.07)
                ctx.lineWidth = 9
                ctx.lineCap = "round"
                ctx.stroke()
                if (root.diskRows.length > 0) {
                    ctx.beginPath()
                    ctx.arc(sx, sy, sr, -Math.PI / 2, -Math.PI / 2 + 6.2832 * Math.max(0.012, root.sSto) * e, false)
                    ctx.strokeStyle = rgba(cSto, 0.95)
                    ctx.lineWidth = 9
                    ctx.stroke()
                }
            }

            // ---- network: two waves, down and up
            e = tNet.reveal
            if (e > 0.001) {
                var nx0 = 364, nx1 = 526, ny0 = 190, nh = 90
                var step = (nx1 - nx0) / (root.samples - 1)
                var fr = root.glide()
                ctx.strokeStyle = rgba(P.text, 0.07 * e)
                ctx.lineWidth = 1
                for (var gl = 0; gl <= 2; gl++) {
                    var yy = Math.round(ny0 + nh * gl / 2) + 0.5
                    ctx.beginPath(); ctx.moveTo(nx0, yy); ctx.lineTo(nx0 + (nx1 - nx0) * e, yy); ctx.stroke()
                }
                var HS = [root.upHist, root.downHist]
                var HD = [root.sUp, root.sDown]
                var HC = [P.accent2, P.accent]
                for (var s = 0; s < 2; s++) {
                    var hist = HS[s], n = hist.length, col = HC[s]
                    ctx.save()
                    ctx.beginPath()
                    ctx.rect(nx0 - 2, ny0 - 12, (nx1 - nx0 + 26) * e, nh + 24)
                    ctx.clip()
                    var pts = []
                    for (var q = 0; q < n; q++) {
                        var xx = nx1 - (n - 1 - q + fr) * step
                        if (xx < nx0 - step) continue
                        pts.push({ x: xx, y: ny0 + nh - hist[q] * nh })
                    }
                    var py = ny0 + nh - HD[s] * nh
                    pts.push({ x: nx1, y: py })
                    if (pts.length > 1) {
                        var fade = ctx.createLinearGradient(nx0, 0, nx1, 0)
                        fade.addColorStop(0, rgba(col, 0)); fade.addColorStop(0.25, rgba(col, 0.9)); fade.addColorStop(1, rgba(col, 0.9))
                        if (s === 1) {
                            var area = ctx.createLinearGradient(0, ny0, 0, ny0 + nh)
                            area.addColorStop(0, rgba(col, 0.26)); area.addColorStop(1, rgba(col, 0))
                            ctx.beginPath()
                            ctx.moveTo(pts[0].x, ny0 + nh)
                            for (var a = 0; a < pts.length; a++) ctx.lineTo(pts[a].x, pts[a].y)
                            ctx.lineTo(nx1, ny0 + nh)
                            ctx.closePath()
                            ctx.fillStyle = area
                            ctx.fill()
                        }
                        ctx.beginPath()
                        ctx.moveTo(pts[0].x, pts[0].y)
                        for (var b = 1; b < pts.length; b++) ctx.lineTo(pts[b].x, pts[b].y)
                        ctx.strokeStyle = fade
                        ctx.lineWidth = 1.5
                        ctx.lineJoin = "round"
                        ctx.stroke()
                    }
                    var ng = ctx.createRadialGradient(nx1, py, 0, nx1, py, 10)
                    ng.addColorStop(0, rgba(col, 0.7)); ng.addColorStop(1, rgba(col, 0))
                    ctx.beginPath(); ctx.arc(nx1, py, 10, 0, 6.2832); ctx.fillStyle = ng; ctx.fill()
                    ctx.beginPath(); ctx.arc(nx1, py, 2.6, 0, 6.2832); ctx.fillStyle = rgba(col, 1); ctx.fill()
                    ctx.restore()
                }
            }

            // ---- battery: a stack of ten cells, filling from the bottom
            e = tBat.reveal
            if (e > 0.001 && root.hasBat) {
                var f = Math.max(0, Math.min(1, root.sBat / 100))
                var bc = root.batTint
                var cells = 10
                var litC = f * cells * e
                for (var i = 0; i < cells; i++) {
                    var amt = Math.max(0, Math.min(1, litC - i))
                    var pulse = (root.charging && amt <= 0 && i === Math.floor(litC)) ? 0.25 + 0.25 * Math.sin(t * 4) : 0
                    ctx.fillStyle = rgba(amt > 0 ? bc : P.text, amt > 0 ? 0.3 + 0.65 * amt : 0.07 + pulse)
                    ctx.fillRect(601, 48 + (cells - 1 - i) * 10, 40, 7)
                }
            }
        }
    }

    // ---- CPU
    Text { x: 30; y: 28; opacity: tCpu.reveal; text: "CPU"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4 }
    Text {
        x: 14; y: 98; width: 200; opacity: tCpu.reveal
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(root.cpuLoad * 100) + "%"
        color: root.cpuHot ? root.pal.bad : root.pal.text
        font.family: root.pal.uiFont; font.pixelSize: 26; font.weight: Font.DemiBold
    }
    Text {
        x: 16; y: 133; width: 196; opacity: tCpu.reveal
        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: root.lc ? root.lc[0].detail : ""
        color: root.cpuHot ? root.pal.bad : root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }

    // ---- memory
    Text { x: 236; y: 28; opacity: tMem.reveal; text: "MEMORY"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4 }
    Text {
        x: 236; y: 44; opacity: tMem.reveal
        text: Math.round(root.memLoad * 100) + "%"
        color: root.memHot ? root.pal.bad : root.pal.accent2
        font.family: root.pal.uiFont; font.pixelSize: 26; font.weight: Font.DemiBold
    }
    Text {
        x: 236; y: 128; width: 132; opacity: tMem.reveal; elide: Text.ElideRight
        text: root.lc ? root.lc[1].detail : ""
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }

    // ---- GPU
    Text { x: 402; y: 28; opacity: tGpu.reveal; text: "GPU"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4 }
    Text {
        x: 402; y: 44; width: 66; opacity: tGpu.reveal; elide: Text.ElideRight
        text: root.lc ? root.lc[2].value : ""
        color: root.lc ? root.lc[2].tint : root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: 24; font.weight: Font.DemiBold
    }
    Text {
        x: 402; y: 128; width: 132; opacity: tGpu.reveal; elide: Text.ElideRight
        text: root.lc ? root.lc[2].detail : ""
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }

    // ---- storage
    Text { x: 30; y: 174; opacity: tSto.reveal; text: "STORAGE"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4 }
    Text {
        x: 28; y: 236; width: 60; opacity: tSto.reveal
        horizontalAlignment: Text.AlignHCenter
        text: root.diskRows.length > 0 ? Math.round(root.stoLoad * 100) + "%" : "—"
        color: root.stoHot ? root.pal.bad : root.pal.text
        font.family: root.pal.uiFont; font.pixelSize: 16; font.weight: Font.DemiBold
    }
    Text {
        x: 30; y: 284; width: 170; opacity: tSto.reveal; elide: Text.ElideRight
        text: root.lc ? root.lc[3].detail : ""
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
    Repeater {
        model: root.diskRows.slice(0, 3)
        delegate: Item {
            id: dk
            required property var modelData
            required property int index
            x: 108; y: 198 + index * 30
            width: 92; height: 24
            opacity: tSto.reveal
            Text {
                x: 0; y: 0; width: 56; elide: Text.ElideRight
                text: dk.modelData.label
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
            }
            Text {
                x: 56; y: 0; width: 36; horizontalAlignment: Text.AlignRight
                text: Math.round(dk.modelData.frac * 100) + "%"
                color: dk.modelData.frac > 0.9 ? root.pal.bad : root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium
            }
            Rectangle { x: 0; y: 18; width: 92; height: 4; radius: 2; color: Qt.alpha(root.pal.text, 0.08) }
            Rectangle {
                x: 0; y: 18; height: 4; radius: 2
                width: 92 * Math.max(0.02, Math.min(1, dk.modelData.frac))
                color: dk.modelData.frac > 0.9 ? root.pal.bad : root.pal.accent2
                Behavior on width { enabled: root.live; NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
            }
        }
    }

    // ---- network
    Text { x: 236; y: 174; opacity: tNet.reveal; text: "NETWORK"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4 }
    Text { x: 236; y: 198; opacity: tNet.reveal; text: "DOWN"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.2 }
    Text {
        x: 236; y: 212; width: 124; opacity: tNet.reveal; elide: Text.ElideRight
        text: root.rate(root.stats.down)
        color: root.pal.accent
        font.family: root.pal.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold
    }
    Text { x: 236; y: 246; opacity: tNet.reveal; text: "UP"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.2 }
    Text {
        x: 236; y: 260; width: 124; opacity: tNet.reveal; elide: Text.ElideRight
        text: root.rate(root.stats.up)
        color: root.pal.accent2
        font.family: root.pal.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold
    }

    // ---- battery, power mode, sysmode
    Text { x: 568; y: 28; opacity: tBat.reveal; text: root.hasBat ? "BATTERY" : "POWER"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4 }
    Text {
        visible: root.hasBat
        x: 554; y: 148; width: 134; opacity: tBat.reveal
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(root.sBat) + "%"
        color: root.batTint
        font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
    }
    Text {
        visible: root.hasBat
        x: 558; y: 174; width: 126; opacity: tBat.reveal
        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        text: root.charging ? "charging" : (root.stats.batEst ? String(root.stats.batEst) : "")
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
    SkyLabel {
        pal: root.pal
        x: 566; y: root.hasBat ? 196 : 52; width: 110
        opacity: tBat.reveal
        name: "Power"
        value: root.profileLabel
        valueSize: 15
        detail: root.autoPower ? "auto" + (root.autoNote !== "" ? " · " + root.autoNote : "") : ""
        tint: root.pal.accent2
    }
    SkyLabel {
        pal: root.pal
        x: 566; y: root.hasBat ? 246 : 124; width: 110
        opacity: tBat.reveal
        name: "Sysmode"
        value: root.sysmode !== "" ? root.sysmode : "not set"
        valueSize: 15
        detail: ""
        tint: root.pal.modeColor[root.sysmode] || root.pal.muted
    }
}
