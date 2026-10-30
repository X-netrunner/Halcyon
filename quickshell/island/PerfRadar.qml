import QtQuick

// Performance look "Radar": a pentagon radar with one axis per part (CPU, Memory, GPU, Storage, Network). The LIVE shape is filled with the
// accent and outlined; a dashed ghost shape behind it is the average of the last minute (it moves once a second), so you see at a glance
// whether now is busier or calmer than usual. Every corner eases; a part over its limit turns its corner and label red (pal.bad).
// Very little text: a vertex label is the part's name and percent. The right column has only three big values and no captions: the
// battery (a small bolt while it charges), the network speeds on two short lines, and the power mode over the sysmode.
// Motion: opening the tab grows the shape from the centre with a small overshoot. Cost: one Canvas, repainted by PerfBase.frame() only
// while the tab is on screen; Motion right down paints once per change.
PerfBase {
    id: root

    readonly property real cx: 230
    readonly property real cy: 170
    readonly property real rad: 115
    // the live corners, 0 .. 1 (network = the larger of the eased down and up loads; GPU asleep = 0)
    readonly property real sNet: Math.max(sDown, sUp)
    readonly property var vals: [sCpu, sMem, hasGpu ? sGpu : 0, sSto, sNet]
    readonly property var hots: [cpuHot, memHot, false, stoHot, false]
    readonly property var names: ["CPU", "Memory", "GPU", "Storage", "Net"]
    // the ghost: the average of the last minute of each axis (the histories hold the eased loads, one point a second)
    function avg(a) { if (!a || a.length === 0) return 0; var s = 0; for (var i = 0; i < a.length; i++) s += a[i]; return s / a.length }
    readonly property var ghost: {
        var net = []
        for (var i = 0; i < downHist.length; i++) net.push(Math.max(downHist[i], upHist[i] || 0))
        return [avg(cpuHist), avg(memHist), hasGpu ? avg(gpuHist) : 0, stoLoad, avg(net)]
    }
    onGhostChanged: if (!live) frame()
    property var hotMix: [0, 0, 0, 0, 0]

    function ang(i) { return -Math.PI / 2 + i * 2 * Math.PI / 5 }
    function label(i) {
        if (i === 2) return !hasGpu ? "GPU —" : (gpuOn ? "GPU " + Math.round(sGpu * 100) + "%" : "GPU asleep")
        if (i === 3) return diskRows.length > 0 ? "Storage " + Math.round(stoLoad * 100) + "%" : "Storage —"
        return names[i] + " " + Math.round(vals[i] * 100) + "%"
    }

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
            var rgba = root.rgba
            var cx = root.cx, cy = root.cy, R = root.rad
            function pt(i, f) { var a = root.ang(i); return [cx + Math.cos(a) * R * f, cy + Math.sin(a) * R * f] }
            function poly(f) {
                ctx.beginPath()
                for (var i = 0; i < 5; i++) { var p = pt(i, f(i)); if (i === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1]) }
                ctx.closePath()
            }
            var grow = Math.max(0, root.back(root.seg(0.05, 0.85)))

            // two grid pentagons and five spokes
            var gridA = root.seg(0, 0.4)
            ctx.lineWidth = 1
            ctx.strokeStyle = rgba(P.text, 0.10 * gridA)
            poly(function () { return 0.5 }); ctx.stroke()
            ctx.strokeStyle = rgba(P.text, 0.16 * gridA)
            poly(function () { return 1 }); ctx.stroke()
            ctx.strokeStyle = rgba(P.text, 0.08 * gridA)
            for (var s = 0; s < 5; s++) { var e = pt(s, 1); ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(e[0], e[1]); ctx.stroke() }

            // the ghost: the last minute's average, dashed
            var gv = root.ghost
            ctx.save()
            ctx.setLineDash([5, 4])
            ctx.lineWidth = 1.5
            ctx.strokeStyle = rgba(P.accent2, 0.75 * root.seg(0.3, 0.9))
            poly(function (i) { return Math.max(0.02, gv[i]) * grow })
            ctx.stroke()
            ctx.restore()

            // the live shape
            var v = root.vals
            poly(function (i) { return Math.max(0.02, v[i]) * grow })
            ctx.fillStyle = rgba(P.accent, 0.25)
            ctx.fill()
            ctx.lineWidth = 2
            ctx.lineJoin = "round"
            ctx.strokeStyle = rgba(P.accent, 0.95)
            ctx.stroke()

            // a dot on every corner; red only past a limit
            for (var i = 0; i < 5; i++) {
                root.hotMix[i] += ((root.hots[i] ? 1 : 0) - root.hotMix[i]) * 0.16
                var c = root.mix(i === 2 && !root.gpuOn ? P.muted : P.accent, P.bad, root.hotMix[i])
                var p = pt(i, Math.max(0.02, v[i]) * grow)
                ctx.beginPath()
                ctx.arc(p[0], p[1], 4, 0, Math.PI * 2)
                ctx.fillStyle = rgba(c, 1)
                ctx.fill()
            }

            // the legend: a tiny solid line (now) and a tiny dashed line (the last minute), no words
            ctx.lineWidth = 2
            ctx.strokeStyle = rgba(P.accent, 0.95)
            ctx.beginPath(); ctx.moveTo(36, 28); ctx.lineTo(54, 28); ctx.stroke()
            ctx.save()
            ctx.setLineDash([4, 3]); ctx.lineWidth = 1.5
            ctx.strokeStyle = rgba(P.accent2, 0.75)
            ctx.beginPath(); ctx.moveTo(36, 42); ctx.lineTo(54, 42); ctx.stroke()
            ctx.restore()

            // the bolt next to the battery number while it charges
            if (root.hasBat && root.charging) {
                var bx = 480, by = 66
                ctx.beginPath()
                ctx.moveTo(bx + 8, by); ctx.lineTo(bx, by + 14); ctx.lineTo(bx + 5, by + 14)
                ctx.lineTo(bx + 3, by + 26); ctx.lineTo(bx + 12, by + 10); ctx.lineTo(bx + 7, by + 10)
                ctx.closePath()
                ctx.fillStyle = rgba(P.good, 0.95 * root.seg(0.5, 0.95))
                ctx.fill()
            }
        }
    }

    // vertex labels: the name and percent at the tip of each axis
    Repeater {
        model: 5
        Text {
            id: vl
            required property int index
            readonly property real a: root.ang(index)
            readonly property real ca: Math.cos(a)
            readonly property real sa: Math.sin(a)
            width: 96
            opacity: root.seg(0.35, 0.9)
            x: root.cx + ca * (root.rad + 14) - (ca > 0.3 ? 0 : (ca < -0.3 ? width : width / 2))
            y: root.cy + sa * (root.rad + 14) - height / 2 + sa * height / 2
            horizontalAlignment: ca > 0.3 ? Text.AlignLeft : (ca < -0.3 ? Text.AlignRight : Text.AlignHCenter)
            text: root.label(index)
            color: root.hots[index] ? root.pal.bad : (index === 2 && root.hasGpu && !root.gpuOn ? root.pal.muted : root.pal.text)
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.DemiBold
        }
    }

    // the right column: three values, no captions
    Text {
        id: bat
        visible: root.hasBat
        opacity: root.seg(0.45, 0.9)
        x: 480 + (root.charging ? 20 : 0); y: 58
        Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        text: Math.round(root.sBat) + "%"
        color: root.batTint
        font.family: root.pal.uiFont; font.pixelSize: 44; font.weight: Font.Bold
    }
    Column {
        x: 480; y: 132
        spacing: 4
        opacity: root.seg(0.55, 1)
        Text {
            text: "↓ " + root.rate(root.stats.down)
            color: root.pal.accent
            font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
        }
        Text {
            text: "↑ " + root.rate(root.stats.up)
            color: root.pal.accent2
            font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
        }
    }
    Column {
        x: 480; y: 224
        spacing: 2
        opacity: root.seg(0.65, 1)
        Text {
            text: root.profileLabel
            color: root.pal.text
            font.family: root.pal.uiFont; font.pixelSize: 22; font.weight: Font.DemiBold
        }
        Text {
            visible: root.sysmode !== ""
            text: root.sysmode
            color: root.pal.muted
            font.family: root.pal.uiFont; font.pixelSize: 16
        }
    }
}
