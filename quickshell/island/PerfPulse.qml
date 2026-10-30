import QtQuick

// Performance look "Pulse": five lanes, like the channels of a heart monitor, and the battery as a tank of light.
//   Each lane is one part of the machine: its name and detail on the left, its number, and the last minute drawn as a glowing wave that
//   glides left all the time with the live value as its bright head. Storage has no history worth drawing, so its lane is a bar of 30
//   little cells that fill with the disk. A part that gets too hot turns its lane red. On the right the battery is a tank: the charge is
//   a liquid with a gently moving surface (bubbles rise while it charges, green), the power mode and the sysmode under it.
//   Motion: opening the tab sweeps the waves in from the left lane by lane and fills the tank. Cost: one Canvas, repainted by PerfBase.frame()
//   only while the tab is on screen; Motion right down paints once per change.
PerfBase {
    id: root

    readonly property real gx0: 276
    readonly property real gx1: 582
    readonly property real laneY0: 24
    readonly property real lanePitch: 55
    readonly property real laneH: 46
    property var hotMix: [0, 0, 0, 0, 0]

    PerfBack { pal: root.pal; running: root.active; stars: 18 }

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
            var step = (root.gx1 - root.gx0) / (root.samples - 1)
            var fr = root.glide()
            var HIST = [root.cpuHist, root.memHist, root.gpuHist, [], root.downHist]
            var HEAD = [root.sCpu, root.sMem, root.hasGpu ? root.sGpu : 0, root.sSto, root.sDown]
            var BASE = [P.accent, P.accent2, P.accent, P.accent2, P.accent]
            var HOT = [root.cpuHot, root.memHot, false, root.stoHot, false]
            for (var i = 0; i < 5; i++) {
                root.hotMix[i] += ((HOT[i] ? 1 : 0) - root.hotMix[i]) * 0.16
                var e = root.seg(0.05 + i * 0.09, 0.6 + i * 0.09)
                if (e <= 0.001) continue
                var col = root.mix(BASE[i], P.bad, root.hotMix[i])
                var y0 = root.laneY0 + i * root.lanePitch
                var gy0 = y0 + 4, gh = root.laneH - 10
                var base = gy0 + gh
                // the floor of the lane
                ctx.beginPath()
                ctx.moveTo(root.gx0, base + 0.5)
                ctx.lineTo(root.gx0 + (root.gx1 - root.gx0) * e, base + 0.5)
                ctx.strokeStyle = rgba(P.text, 0.08)
                ctx.lineWidth = 1
                ctx.stroke()

                if (i === 3) {
                    // storage: a bar of cells, the first disk big, a second one as a thin line under it
                    var cells = 30
                    var cw = (root.gx1 - root.gx0) / cells
                    var lit = Math.round(root.sSto * cells)
                    for (var c = 0; c < cells; c++) {
                        var ce = Math.max(0, Math.min(1, e * 1.6 - c / cells * 0.6))
                        if (ce <= 0) continue
                        var on = c < lit
                        ctx.fillStyle = rgba(on ? col : P.text, on ? (0.35 + 0.55 * (c / cells)) * ce : 0.07 * ce)
                        ctx.fillRect(root.gx0 + c * cw + 1, gy0 + 6, cw - 2, gh - 12)
                    }
                    if (root.diskRows.length > 1) {
                        ctx.fillStyle = rgba(P.text, 0.07 * e)
                        ctx.fillRect(root.gx0, base - 3, root.gx1 - root.gx0, 2)
                        ctx.fillStyle = rgba(col, 0.7 * e)
                        ctx.fillRect(root.gx0, base - 3, (root.gx1 - root.gx0) * Math.max(0, Math.min(1, root.diskRows[1].frac)), 2)
                    }
                    continue
                }

                var h = HIST[i]
                var idle = (i === 2 && !root.gpuOn)
                var n = h.length
                ctx.save()
                ctx.beginPath()
                ctx.rect(root.gx0 - 2, y0 - 6, (root.gx1 - root.gx0 + 26) * e, root.laneH + 12)      // the sweep: it opens from the left
                ctx.clip()
                // the wave: points glide left, the newest is the live value; the old end fades out
                var pts = []
                for (var q = 0; q < n; q++) {
                    var xx = root.gx1 - (n - 1 - q + fr) * step
                    if (xx < root.gx0 - step) continue
                    pts.push({ x: xx, y: base - h[q] * gh })
                }
                var hy = base - HEAD[i] * gh
                pts.push({ x: root.gx1, y: hy })
                if (pts.length > 1) {
                    var fade = ctx.createLinearGradient(root.gx0, 0, root.gx1, 0)
                    fade.addColorStop(0, rgba(col, 0))
                    fade.addColorStop(0.2, rgba(col, idle ? 0.25 : 0.9))
                    fade.addColorStop(1, rgba(col, idle ? 0.25 : 0.9))
                    var area = ctx.createLinearGradient(0, gy0, 0, base)
                    area.addColorStop(0, rgba(col, idle ? 0.05 : 0.28))
                    area.addColorStop(1, rgba(col, 0))
                    ctx.beginPath()
                    ctx.moveTo(pts[0].x, base)
                    for (var a = 0; a < pts.length; a++) ctx.lineTo(pts[a].x, pts[a].y)
                    ctx.lineTo(root.gx1, base)
                    ctx.closePath()
                    ctx.fillStyle = area
                    ctx.fill()
                    ctx.beginPath()
                    ctx.moveTo(pts[0].x, pts[0].y)
                    for (var b = 1; b < pts.length; b++) ctx.lineTo(pts[b].x, pts[b].y)
                    ctx.strokeStyle = fade
                    ctx.lineWidth = 1.6
                    ctx.lineJoin = "round"
                    ctx.stroke()
                }
                // the head: the live point
                var hg = ctx.createRadialGradient(root.gx1, hy, 0, root.gx1, hy, 12)
                hg.addColorStop(0, rgba(col, idle ? 0.2 : 0.7))
                hg.addColorStop(1, rgba(col, 0))
                ctx.beginPath(); ctx.arc(root.gx1, hy, 12, 0, 6.2832); ctx.fillStyle = hg; ctx.fill()
                ctx.beginPath(); ctx.arc(root.gx1, hy, 2.4 + 1.6 * HEAD[i], 0, 6.2832)
                ctx.fillStyle = rgba(col, idle ? 0.5 : 1)
                ctx.fill()
                ctx.restore()
            }

            // ---- the battery tank
            if (root.hasBat) {
                var me = root.seg(0.35, 0.95)
                var tx = 626, ty = 34, tw = 44, th = 96, tr = 11
                var f = Math.max(0, Math.min(1, root.sBat / 100))
                var bc = root.batTint
                function body() {
                    ctx.beginPath()
                    ctx.moveTo(tx + tr, ty)
                    ctx.lineTo(tx + tw - tr, ty)
                    ctx.arc(tx + tw - tr, ty + tr, tr, -Math.PI / 2, 0, false)
                    ctx.lineTo(tx + tw, ty + th - tr)
                    ctx.arc(tx + tw - tr, ty + th - tr, tr, 0, Math.PI / 2, false)
                    ctx.lineTo(tx + tr, ty + th)
                    ctx.arc(tx + tr, ty + th - tr, tr, Math.PI / 2, Math.PI, false)
                    ctx.lineTo(tx, ty + tr)
                    ctx.arc(tx + tr, ty + tr, tr, Math.PI, 1.5 * Math.PI, false)
                    ctx.closePath()
                }
                // the cap on top
                ctx.fillStyle = rgba(bc, 0.45 * me)
                ctx.fillRect(tx + tw / 2 - 8, ty - 5, 16, 5)
                // the liquid: clipped to the tank, its surface moves a little
                ctx.save()
                body()
                ctx.clip()
                var level = (th - 6) * f * me
                var top = ty + th - 3 - level
                var liq = ctx.createLinearGradient(0, top, 0, ty + th)
                liq.addColorStop(0, rgba(bc, 0.95))
                liq.addColorStop(1, rgba(bc, 0.45))
                ctx.beginPath()
                ctx.moveTo(tx - 2, ty + th + 2)
                ctx.lineTo(tx - 2, top)
                for (var wx = 0; wx <= tw + 4; wx += 4)
                    ctx.lineTo(tx - 2 + wx, top + Math.sin(t * 2.4 + wx * 0.2) * (root.charging ? 2.2 : 1.3))
                ctx.lineTo(tx + tw + 2, ty + th + 2)
                ctx.closePath()
                ctx.fillStyle = liq
                ctx.fill()
                if (root.charging && f > 0.05) {                      // bubbles rise while it charges
                    for (var bb = 0; bb < 5; bb++) {
                        var bp = (t * 0.35 + bb * 0.21) % 1
                        ctx.beginPath()
                        ctx.arc(tx + 9 + ((bb * 37) % 26), ty + th - 4 - level * bp, 1.3 + (bb % 2), 0, 6.2832)
                        ctx.fillStyle = "rgba(255,255,255," + (0.5 * (1 - bp)) + ")"
                        ctx.fill()
                    }
                }
                ctx.restore()
                body()
                ctx.strokeStyle = rgba(bc, 0.5 * me)
                ctx.lineWidth = 1.3
                ctx.stroke()
            }
        }
    }

    // ---- the lanes: name and detail, and the number
    Repeater {
        model: root.lanes
        delegate: Item {
            id: row
            required property var modelData
            required property int index
            x: 24; y: root.laneY0 + index * root.lanePitch
            width: 540; height: root.laneH
            opacity: root.seg(0.1 + index * 0.08, 0.6 + index * 0.08)
            transform: Translate { x: (1 - row.opacity) * -12 }
            Text {
                x: 0; y: 5
                text: row.modelData.name
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4
                font.capitalization: Font.AllUppercase
            }
            Text {
                x: 0; y: 22
                width: 130; elide: Text.ElideRight
                text: row.modelData.detail
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
            }
            Text {
                x: 134; y: row.modelData.small ? 14 : 8
                width: 104; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft
                text: row.modelData.value
                color: row.modelData.tint
                font.family: root.pal.uiFont
                font.pixelSize: row.modelData.small ? 14 : 22
                font.weight: Font.DemiBold
            }
        }
    }

    // ---- the right column: the tank's charge, the power mode and the sysmode
    Rectangle { x: 598; y: 16; width: 1; height: (root.height - 32) * root.seg(0.2, 0.7); color: root.pal.line }
    Text {
        visible: root.hasBat
        opacity: root.seg(0.5, 0.95)
        x: 604; y: 138; width: 88
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(root.sBat) + "%"
        color: root.batTint
        font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
    }
    Text {
        visible: root.hasBat
        opacity: root.seg(0.55, 1.0)
        x: 604; y: 164; width: 88
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.charging ? "charging" : (root.stats.batEst ? String(root.stats.batEst) : "")
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
    SkyLabel {
        pal: root.pal
        x: 604; y: root.hasBat ? 196 : 40; width: 88
        opacity: root.seg(0.6, 1.0)
        name: "Power"
        value: root.profileLabel
        valueSize: 15
        detail: root.autoPower ? "auto" + (root.autoNote !== "" ? " · " + root.autoNote : "") : ""
        tint: root.pal.accent2
    }
    SkyLabel {
        pal: root.pal
        x: 604; y: root.hasBat ? 254 : 110; width: 88
        opacity: root.seg(0.68, 1.0)
        name: "Sysmode"
        value: root.sysmode !== "" ? root.sysmode : "not set"
        valueSize: 15
        detail: ""
        tint: root.pal.modeColor[root.sysmode] || root.pal.muted
    }
}
