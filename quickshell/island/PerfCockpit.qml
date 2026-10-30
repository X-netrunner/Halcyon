import QtQuick

// Performance look "Cockpit": instruments. A big 270-degree dial in the middle is the CPU load (the percent in its middle, the CPU
// temperature under it) with a thinner arc outside it for the temperature; two small rings on each side: Memory and GPU on the left,
// Network and Storage on the right; a row of indicator lamps along the bottom (Hot, Charging, Battery, power mode, sysmode).
// Colours are the theme's only: the dial, the network and memory rings use the accent, the temperature arc and the GPU / storage rings the
// second accent, tracks the line colour. Red (pal.bad) appears only on the element that passes its limit: CPU load or temperature over 90,
// memory over 92, storage over 90, battery at 20 or below. Unlit lamps are dim, lit ones accent (Charging green).
// Motion: opening the tab sweeps the dial in first, then the side rings one after another. Cost: one Canvas, repainted by PerfBase.frame()
// only while the tab is on screen; Motion right down paints once per change.
PerfBase {
    id: root

    readonly property real cx: 352
    readonly property real cy: 138
    readonly property real rDial: 100
    readonly property real rTemp: 116
    readonly property real ringR: 32
    readonly property var ringX: [110, 110, 594, 594]
    readonly property var ringY: [86, 206, 86, 206]
    readonly property var ringName: ["Memory", "GPU", "Network", "Storage"]

    // eased copies for this look: the network ring and the temperature
    property real sNetRing: netLoad
    Behavior on sNetRing { enabled: root.live; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
    property real sTemp: temp
    Behavior on sTemp { enabled: root.live; NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    onSNetRingChanged: if (!live) frame()
    onSTempChanged: if (!live) frame()

    // the limits of THIS look (the dial itself is red when the load, not only the temperature, passes 90)
    readonly property bool cpuBusy: cpuLoad > 0.9
    readonly property bool anyHot: cpuBusy || cpuHot || memHot || stoHot
    readonly property bool batLow: hasBat && batLevel <= 20
    readonly property bool gpuAsleep: hasGpu && !gpuOn
    readonly property var ringV: [sMem, gpuOn ? sGpu : 0, sNetRing, sSto]
    readonly property var ringC: pal ? [pal.accent, pal.accent2, pal.accent, pal.accent2] : []
    readonly property var ringHot: [memHot, false, false, stoHot]
    readonly property var ringText: [
        Math.round(memLoad * 100) + "%",
        !hasGpu ? "—" : (gpuOn ? Math.round(gpuLoad * 100) + "%" : "asleep"),
        rate(Number(stats.down || 0) + Number(stats.up || 0)),
        diskRows.length > 0 ? Math.round(stoLoad * 100) + "%" : "—"
    ]
    property var hot: [0, 0, 0, 0, 0, 0]       // eased 0 .. 1 red mix: dial, temperature, memory ring, (gpu), network ring, storage ring

    // the lamps: label, lit or not, colour when lit (arrays, so the five delegates are made once and only re-read)
    readonly property var lampT: ["Hot", "Charging", hasBat ? Math.round(sBat) + "%" : "—", profileLabel, sysmode !== "" ? sysmode : "—"]
    readonly property var lampLit: [anyHot, charging, hasBat, true, sysmode !== ""]
    readonly property var lampC: pal ? [pal.bad, pal.good, batLow ? pal.bad : pal.accent, pal.accent, pal.accent] : []

    function aOf(f) { return (135 + 270 * f) * Math.PI / 180 }

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
            var cx = root.cx, cy = root.cy
            ctx.lineCap = "round"

            // ease the red mixes
            var HT = [root.cpuBusy, root.cpuHot, root.memHot, false, false, root.stoHot]
            for (var h = 0; h < 6; h++) root.hot[h] += ((HT[h] ? 1 : 0) - root.hot[h]) * 0.16

            // ticks every 10 % just inside the dial
            var ta = root.seg(0, 0.3)
            ctx.lineWidth = 1.5
            ctx.strokeStyle = rgba(P.line, 0.9 * ta)
            for (var k = 0; k <= 10; k++) {
                var a = root.aOf(k / 10)
                ctx.beginPath()
                ctx.moveTo(cx + Math.cos(a) * (root.rDial - 20), cy + Math.sin(a) * (root.rDial - 20))
                ctx.lineTo(cx + Math.cos(a) * (root.rDial - (k % 5 === 0 ? 30 : 26)), cy + Math.sin(a) * (root.rDial - (k % 5 === 0 ? 30 : 26)))
                ctx.stroke()
            }

            // the temperature arc (outside), 0 .. 100 C
            ctx.lineWidth = 5
            ctx.strokeStyle = rgba(P.line, 0.8)
            ctx.beginPath(); ctx.arc(cx, cy, root.rTemp, root.aOf(0), root.aOf(1)); ctx.stroke()
            var ft = Math.max(0, Math.min(1, root.sTemp / 100)) * root.seg(0.15, 0.75)
            if (root.temp > 0 && ft > 0.003) {
                ctx.strokeStyle = rgba(root.mix(P.accent2, P.bad, root.hot[1]), 1)
                ctx.beginPath(); ctx.arc(cx, cy, root.rTemp, root.aOf(0), root.aOf(ft)); ctx.stroke()
            }

            // the big dial: the CPU load
            ctx.lineWidth = 14
            ctx.strokeStyle = rgba(P.line, 0.8)
            ctx.beginPath(); ctx.arc(cx, cy, root.rDial, root.aOf(0), root.aOf(1)); ctx.stroke()
            var fd = Math.max(0, Math.min(1, root.sCpu)) * root.seg(0, 0.65)
            var dc = root.mix(P.accent, P.bad, root.hot[0])
            if (fd > 0.003) {
                ctx.strokeStyle = rgba(dc, 1)
                ctx.beginPath(); ctx.arc(cx, cy, root.rDial, root.aOf(0), root.aOf(fd)); ctx.stroke()
            }
            // the arc head: a soft glow and a white core
            var he = root.aOf(fd)
            var hx = cx + Math.cos(he) * root.rDial, hy = cy + Math.sin(he) * root.rDial
            var g = ctx.createRadialGradient(hx, hy, 0, hx, hy, 20)
            g.addColorStop(0, rgba(dc, 0.55)); g.addColorStop(1, rgba(dc, 0))
            ctx.fillStyle = g
            ctx.beginPath(); ctx.arc(hx, hy, 20, 0, Math.PI * 2); ctx.fill()
            ctx.fillStyle = "rgba(255,255,255,0.95)"
            ctx.beginPath(); ctx.arc(hx, hy, 3.2, 0, Math.PI * 2); ctx.fill()

            // the four small rings
            for (var i = 0; i < 4; i++) {
                var e = root.seg(0.35 + i * 0.1, 0.9 + i * 0.03)
                var x = root.ringX[i], y = root.ringY[i]
                var dim = (i === 1 && root.gpuAsleep) ? 0.45 : 1
                ctx.lineWidth = 6
                ctx.strokeStyle = rgba(P.line, 0.8 * dim * Math.min(1, e * 2))
                ctx.beginPath(); ctx.arc(x, y, root.ringR, 0, Math.PI * 2); ctx.stroke()
                var v = Math.max(0, Math.min(1, root.ringV[i])) * e
                if (v > 0.003) {
                    var rc = root.mix(root.ringC[i], P.bad, root.hot[i === 0 ? 2 : (i === 2 ? 4 : (i === 3 ? 5 : 3))])
                    ctx.strokeStyle = rgba(rc, 1)
                    ctx.beginPath(); ctx.arc(x, y, root.ringR, -Math.PI / 2, -Math.PI / 2 + v * Math.PI * 2); ctx.stroke()
                }
            }
        }
    }

    // the dial's number and the temperature
    Text {
        x: root.cx - 70; y: root.cy - 44; width: 140
        horizontalAlignment: Text.AlignHCenter
        opacity: root.seg(0.1, 0.6)
        text: Math.round(root.sCpu * 100) + "%"
        color: root.cpuBusy ? root.pal.bad : root.pal.text
        font.family: root.pal.uiFont; font.pixelSize: 48; font.weight: Font.Bold
    }
    Text {
        visible: root.temp > 0
        x: root.cx - 70; y: root.cy + 20; width: 140
        horizontalAlignment: Text.AlignHCenter
        opacity: root.seg(0.2, 0.7)
        text: Math.round(root.sTemp) + "°"
        color: root.cpuHot ? root.pal.bad : root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold
    }

    // the small rings' values and names
    Repeater {
        model: 4
        Item {
            id: rt
            required property int index
            opacity: root.seg(0.4 + index * 0.1, 0.95)
            Text {
                x: root.ringX[rt.index] - 30; y: root.ringY[rt.index] - height / 2; width: 60
                horizontalAlignment: Text.AlignHCenter
                text: root.ringText[rt.index]
                fontSizeMode: Text.Fit; minimumPixelSize: 8
                color: root.ringHot[rt.index] ? root.pal.bad : (rt.index === 1 && !root.gpuOn ? root.pal.muted : root.pal.text)
                font.family: root.pal.uiFont; font.pixelSize: rt.index === 2 || (rt.index === 1 && root.gpuAsleep) ? 12 : 16; font.weight: Font.DemiBold
            }
            Text {
                x: root.ringX[rt.index] - 40; y: root.ringY[rt.index] + root.ringR + 8; width: 80
                horizontalAlignment: Text.AlignHCenter
                text: root.ringName[rt.index]
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.2
                font.capitalization: Font.AllUppercase
            }
        }
    }

    // the lamps
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 282
        spacing: 24
        Repeater {
            model: 5
            Row {
                id: lamp
                required property int index
                spacing: 7
                opacity: root.seg(0.6, 1)
                Rectangle {
                    width: 9; height: 9; radius: 4.5
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.lampLit[lamp.index] ? root.lampC[lamp.index] : root.pal.line
                    Behavior on color { ColorAnimation { duration: 250 } }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.lampT[lamp.index]
                    color: root.lampLit[lamp.index] ? root.pal.text : root.pal.muted
                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium
                }
            }
        }
    }
}
