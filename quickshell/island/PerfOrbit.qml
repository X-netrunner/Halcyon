import QtQuick

// Performance look "Orbit": the machine as four rings around one centre, like the orbits of a small solar system.
//   Outer to inner: CPU, memory, GPU, storage. Each ring is a track with a bright arc as long as its load (a gauge of 270 degrees), a soft glow
//   under the arc, a head that shines at its end, and a small spark that runs along the lit part, faster the busier the part is. The CPU's
//   number and temperature sit in the centre. On the right the five parts are listed in the same colours (network has no ring: its speeds
//   are the last row), and the battery is a ring of its own with the power mode and sysmode under it.
//   Motion: opening the tab sweeps the rings in one after the other; after that every value is eased, a part that gets too hot slides to red.
//   Cost: one Canvas, repainted by PerfBase.frame() only while the tab is on screen; Motion right down paints once per change.
PerfBase {
    id: root

    readonly property real cx: 186
    readonly property real cy: 158
    readonly property var radii: [136, 114, 92, 70]
    readonly property real ringW: 12
    property var hotMix: [0, 0, 0, 0]

    PerfBack { pal: root.pal; running: root.active; stars: 24 }

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
            var A0 = 0.75 * Math.PI                   // the gauge starts at the lower left ...
            var SW = 1.5 * Math.PI                    // ... and sweeps 270 degrees
            var L = [root.sCpu, root.sMem, root.hasGpu ? root.sGpu : 0, root.sSto]
            var HOT = [root.cpuHot, root.memHot, false, root.stoHot]
            var BASE = [P.accent, P.accent2, P.accent, P.accent2]
            for (var k = 0; k < 4; k++) {
                root.hotMix[k] += ((HOT[k] ? 1 : 0) - root.hotMix[k]) * 0.16
                var r = root.radii[k]
                var e = root.seg(0.04 + k * 0.09, 0.56 + k * 0.09)
                if (e <= 0.001) continue
                var col = root.mix(BASE[k], P.bad, root.hotMix[k])
                var idle = (k === 2 && !root.gpuOn)
                // the track
                ctx.beginPath()
                ctx.arc(root.cx, root.cy, r, A0, A0 + SW * e, false)
                ctx.strokeStyle = rgba(P.text, 0.07)
                ctx.lineWidth = root.ringW
                ctx.lineCap = "round"
                ctx.stroke()
                var ld = Math.max(0.012, L[k])
                var a1 = A0 + SW * ld * e
                // its glow, then the arc itself
                ctx.beginPath()
                ctx.arc(root.cx, root.cy, r, A0, a1, false)
                ctx.strokeStyle = rgba(col, (idle ? 0.04 : 0.14) + 0.12 * L[k])
                ctx.lineWidth = root.ringW + 9
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(root.cx, root.cy, r, A0, a1, false)
                ctx.strokeStyle = rgba(col, idle ? 0.30 : 0.92)
                ctx.lineWidth = root.ringW
                ctx.stroke()
                // the head shines
                var hx = root.cx + r * Math.cos(a1), hy = root.cy + r * Math.sin(a1)
                var hg = ctx.createRadialGradient(hx, hy, 0, hx, hy, 14)
                hg.addColorStop(0, rgba(col, idle ? 0.2 : 0.75))
                hg.addColorStop(1, rgba(col, 0))
                ctx.beginPath(); ctx.arc(hx, hy, 14, 0, 6.2832); ctx.fillStyle = hg; ctx.fill()
                ctx.beginPath(); ctx.arc(hx, hy, 2.6, 0, 6.2832)
                ctx.fillStyle = "rgba(255,255,255," + (idle ? 0.35 : 0.9) + ")"
                ctx.fill()
                // a spark runs along the lit part: slow when the part idles, quick when it works
                if (!idle && L[k] > 0.02) {
                    var ph = (t * (0.08 + 0.55 * L[k]) + k * 0.27) % 1
                    for (var j = 0; j < 4; j++) {
                        var p = ph - j * 0.03
                        if (p < 0) p += 1
                        var sa = A0 + SW * ld * e * p
                        ctx.beginPath()
                        ctx.arc(root.cx + r * Math.cos(sa), root.cy + r * Math.sin(sa), 2.1 - j * 0.45, 0, 6.2832)
                        ctx.fillStyle = "rgba(255,255,255," + (0.8 * (1 - j * 0.26)) + ")"
                        ctx.fill()
                    }
                }
            }

            // ---- the battery: one ring of its own
            if (root.hasBat) {
                var me = root.seg(0.35, 0.9)
                var bx = 648, by = 74, br = 31
                var f = Math.max(0, Math.min(1, root.sBat / 100))
                var bc = root.batTint
                var pulse = root.charging ? 0.7 + 0.3 * Math.sin(t * 2.2) : 0.85
                var gl = ctx.createRadialGradient(bx, by, br * 0.5, bx, by, br * 2)
                gl.addColorStop(0, rgba(bc, 0.22 * f * pulse * me))
                gl.addColorStop(1, rgba(bc, 0))
                ctx.beginPath(); ctx.arc(bx, by, br * 2, 0, 6.2832); ctx.fillStyle = gl; ctx.fill()
                ctx.beginPath()
                ctx.arc(bx, by, br, 0, 6.2832 * me, false)
                ctx.strokeStyle = rgba(P.text, 0.08)
                ctx.lineWidth = 7
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(bx, by, br, -Math.PI / 2, -Math.PI / 2 + 6.2832 * Math.max(0.01, f) * me, false)
                ctx.strokeStyle = rgba(bc, 0.95)
                ctx.lineWidth = 7
                ctx.lineCap = "round"
                ctx.stroke()
            }
        }
    }

    // ---- the middle: what the CPU is doing
    Column {
        x: root.cx - 52; y: root.cy - 36
        width: 104
        opacity: root.seg(0.3, 0.8)
        spacing: 0
        Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: "CPU"
            color: root.pal.muted
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4
        }
        Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: Math.round(root.cpuLoad * 100) + "%"
            color: root.cpuHot ? root.pal.bad : root.pal.text
            font.family: root.pal.uiFont; font.pixelSize: 30; font.weight: Font.DemiBold
        }
        Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: root.temp > 0 ? Math.round(root.temp) + "°C" : ""
            color: root.cpuHot ? root.pal.bad : root.pal.muted
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
        }
    }

    // ---- the list, in the colours of the rings
    Repeater {
        model: root.lanes
        delegate: Item {
            id: row
            required property var modelData
            required property int index
            x: 352; y: 22 + index * 55
            width: 226; height: 48
            opacity: root.seg(0.2 + index * 0.08, 0.7 + index * 0.08)
            transform: Translate { x: (1 - row.opacity) * 14 }
            Rectangle {
                x: 0; y: 10; width: 8; height: 8; radius: 4
                color: row.modelData.tint
            }
            Text {
                x: 18; y: 4
                text: row.modelData.name
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4
                font.capitalization: Font.AllUppercase
            }
            Text {
                x: 18; y: 22
                width: 118; elide: Text.ElideRight
                text: row.modelData.detail
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
            }
            Text {
                anchors.right: parent.right
                y: row.modelData.small ? 10 : 6
                width: 100; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft
                text: row.modelData.value
                color: row.modelData.tint
                font.family: root.pal.uiFont
                font.pixelSize: row.modelData.small ? 15 : 24
                font.weight: Font.DemiBold
            }
        }
    }

    // ---- the right column: the battery ring, the power mode and the sysmode
    Rectangle { x: 598; y: 16; width: 1; height: (root.height - 32) * root.seg(0.2, 0.7); color: root.pal.line }
    Text {
        visible: root.hasBat
        opacity: root.seg(0.5, 0.95)
        x: 604; y: 62; width: 88
        horizontalAlignment: Text.AlignHCenter
        text: Math.round(root.sBat) + "%"
        color: root.batTint
        font.family: root.pal.uiFont; font.pixelSize: 17; font.weight: Font.DemiBold
    }
    Text {
        visible: root.hasBat
        opacity: root.seg(0.55, 1.0)
        x: 604; y: 114; width: 88
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.charging ? "charging" : (root.stats.batEst ? String(root.stats.batEst) : "")
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
    SkyLabel {
        pal: root.pal
        x: 604; y: 158; width: 88
        opacity: root.seg(0.6, 1.0)
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
        name: "Sysmode"
        value: root.sysmode !== "" ? root.sysmode : "not set"
        valueSize: 15
        detail: ""
        tint: root.pal.modeColor[root.sysmode] || root.pal.muted
    }
}
