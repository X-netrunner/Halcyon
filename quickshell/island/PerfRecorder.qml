import QtQuick

// Performance look "Recorder" (Flight Recorder): the last five minutes of the machine on one wide graph. Four glowing lines (CPU, Memory,
// GPU, Network) glide left all the time, a little brighter dot at the right edge is the live value; three faint grid lines; a dashed marker
// with a short label wherever the power mode or the sysmode changed. Rest the pointer on the graph and a cursor follows it with a dot on every
// line and a small card with the values at that moment. Left under the graph "5 min ago", right "now" with the battery and the sysmode.
// Colours are the theme's only: CPU = accent, Memory = accent2, GPU = a mix of accent and text, Network = a mix of accent2 and text.
// Needs PerfBase's slow buffer (`wantLong`, one point every 5 seconds) and `events` (Part 5a); this look switches `wantLong` on while it is
// loaded, so the other looks never sample it. Motion: opening the tab draws the lines in from the left. Cost: one Canvas, repainted by
// PerfBase.frame() only while the tab is on screen; Motion right down paints once per change and per pointer move.
PerfBase {
    id: root

    wantLong: true

    readonly property real gx0: 40
    readonly property real gx1: 680
    readonly property real gy0: 70
    readonly property real gy1: 260
    readonly property real spanMs: 300000
    readonly property var names: ["CPU", "Memory", "GPU", "Network"]
    readonly property var cols: pal ? [pal.accent, pal.accent2, mix(pal.accent, pal.text, 0.5), mix(pal.accent2, pal.text, 0.5)] : []

    property double nowMs: Date.now()
    property double lastLong: 0                       // when the newest slow point was taken
    property real hoverX: -1                          // the pointer on the graph (screen x), -1 = not there
    property var hoverVals: [-1, -1, -1, -1]
    property real hoverAgo: 0                         // seconds before now at the pointer

    onLongCpuChanged: { lastLong = Date.now(); frame() }
    onEventsChanged: frame()

    // the four lines' points: { t (ms), v (0 .. 1) } from the slow buffer, then the live value at "now"
    function pts(i) {
        var a = [longCpu, longMem, longGpu, longNet][i]
        var head = [sCpu, sMem, hasGpu ? sGpu : 0, Math.max(sDown, sUp)][i]
        var out = []
        for (var k = 0; k < a.length; k++) out.push({ t: lastLong - (a.length - 1 - k) * 5000, v: a[k] })
        out.push({ t: nowMs, v: head })
        return out
    }
    function xOf(t) { return gx1 - (nowMs - t) / spanMs * (gx1 - gx0) }
    function yOf(v) { return gy1 - Math.max(0, Math.min(1, v)) * (gy1 - gy0) }
    function valueAtX(i, x) {
        var tm = nowMs - (gx1 - x) / (gx1 - gx0) * spanMs
        var p = pts(i)
        if (p.length < 2 || tm < p[0].t) return -1
        for (var k = 1; k < p.length; k++)
            if (tm <= p[k].t) { var f = (tm - p[k - 1].t) / Math.max(1, p[k].t - p[k - 1].t); return p[k - 1].v + (p[k].v - p[k - 1].v) * f }
        return p[p.length - 1].v
    }
    function updateHover() {
        nowMs = Date.now()
        if (hoverX < 0) return
        hoverAgo = (gx1 - hoverX) / (gx1 - gx0) * spanMs / 1000
        hoverVals = [valueAtX(0, hoverX), valueAtX(1, hoverX), valueAtX(2, hoverX), valueAtX(3, hoverX)]
    }
    function agoText(s) { s = Math.round(s); return s < 3 ? "now" : (s >= 60 ? Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60) : s + "s") + " ago" }
    onHoverXChanged: { updateHover(); frame() }
    Connections { target: root; function onFrame() { root.updateHover() } }

    PerfBack { pal: root.pal; running: root.active; stars: 14 }

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
            var reveal = root.seg(0.05, 0.85)
            var ga = root.seg(0, 0.4)

            // three faint grid lines (25, 50, 75 %)
            ctx.lineWidth = 1
            ctx.strokeStyle = rgba(P.text, 0.07 * ga)
            for (var g = 1; g <= 3; g++) {
                var gy = Math.round(root.yOf(g / 4)) + 0.5
                ctx.beginPath(); ctx.moveTo(root.gx0, gy); ctx.lineTo(root.gx1, gy); ctx.stroke()
            }
            ctx.strokeStyle = rgba(P.text, 0.14 * ga)
            ctx.beginPath(); ctx.moveTo(root.gx0, root.gy1 + 0.5); ctx.lineTo(root.gx1, root.gy1 + 0.5); ctx.stroke()

            // event markers (dashed)
            var ev = root.events
            ctx.save()
            ctx.setLineDash([3, 4])
            ctx.strokeStyle = rgba(P.accent2, 0.5)
            for (var e = 0; e < ev.length; e++) {
                var ex = Math.round(root.xOf(ev[e].atMs)) + 0.5
                if (ex < root.gx0 || ex > root.gx1) continue
                ctx.beginPath(); ctx.moveTo(ex, root.gy0 - 2); ctx.lineTo(ex, root.gy1); ctx.stroke()
            }
            ctx.restore()

            // the lines, clipped to the graph (older points slide off the left edge), drawn in from the left while the tab opens
            ctx.save()
            ctx.beginPath(); ctx.rect(root.gx0, root.gy0 - 6, (root.gx1 - root.gx0 + 8) * reveal, root.gy1 - root.gy0 + 12); ctx.clip()
            ctx.lineJoin = "round"; ctx.lineCap = "round"
            for (var i = 0; i < 4; i++) {
                var p = root.pts(i)
                if (p.length < 2) continue
                var c = root.cols[i]
                for (var pass = 0; pass < 2; pass++) {
                    ctx.lineWidth = pass === 0 ? 5 : 2
                    ctx.strokeStyle = rgba(c, pass === 0 ? 0.16 : 0.95)
                    ctx.beginPath()
                    ctx.moveTo(root.xOf(p[0].t), root.yOf(p[0].v))
                    for (var k = 1; k < p.length; k++) {
                        var mx = (root.xOf(p[k - 1].t) + root.xOf(p[k].t)) / 2, my = (root.yOf(p[k - 1].v) + root.yOf(p[k].v)) / 2
                        ctx.quadraticCurveTo(root.xOf(p[k - 1].t), root.yOf(p[k - 1].v), mx, my)
                    }
                    ctx.lineTo(root.xOf(p[p.length - 1].t), root.yOf(p[p.length - 1].v))
                    ctx.stroke()
                }
            }
            ctx.restore()

            // the live value: a bright head at the right edge
            if (reveal > 0.95) {
                for (var j = 0; j < 4; j++) {
                    var hv = root.pts(j)
                    var hh = hv[hv.length - 1]
                    var hc = root.cols[j]
                    var gr = ctx.createRadialGradient(root.gx1, root.yOf(hh.v), 0, root.gx1, root.yOf(hh.v), 11)
                    gr.addColorStop(0, rgba(hc, 0.6)); gr.addColorStop(1, rgba(hc, 0))
                    ctx.fillStyle = gr
                    ctx.beginPath(); ctx.arc(root.gx1, root.yOf(hh.v), 11, 0, Math.PI * 2); ctx.fill()
                    ctx.fillStyle = rgba(root.mix(hc, { r: 1, g: 1, b: 1 }, 0.6), 1)
                    ctx.beginPath(); ctx.arc(root.gx1, root.yOf(hh.v), 3, 0, Math.PI * 2); ctx.fill()
                }
            }

            // the scrub cursor and a dot on each line
            if (root.hoverX >= 0) {
                ctx.strokeStyle = rgba(P.text, 0.35)
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(Math.round(root.hoverX) + 0.5, root.gy0 - 2); ctx.lineTo(Math.round(root.hoverX) + 0.5, root.gy1); ctx.stroke()
                for (var d = 0; d < 4; d++) {
                    var hvv = root.hoverVals[d]
                    if (hvv < 0) continue
                    ctx.fillStyle = rgba(root.cols[d], 1)
                    ctx.beginPath(); ctx.arc(root.hoverX, root.yOf(hvv), 4, 0, Math.PI * 2); ctx.fill()
                    ctx.strokeStyle = rgba(P.bg, 0.9); ctx.lineWidth = 1.5
                    ctx.stroke()
                }
            }
        }
    }

    // the legend, top right
    Row {
        anchors.right: parent.right; anchors.rightMargin: 24
        y: 36
        spacing: 14
        opacity: root.seg(0.1, 0.6)
        Repeater {
            model: 4
            Row {
                id: lg
                required property int index
                spacing: 5
                Rectangle { width: 14; height: 3; radius: 1.5; anchors.verticalCenter: parent.verticalCenter; color: root.cols[lg.index] }
                Text { text: root.names[lg.index]; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
            }
        }
    }

    // the events' labels
    Repeater {
        model: root.events
        Text {
            id: el
            required property var modelData
            required property int index
            readonly property real mx: root.xOf(modelData.atMs)
            visible: mx > root.gx0 + 2 && mx <= root.gx1
            x: mx > 520 ? mx - width - 5 : mx + 5
            y: root.gy0 + 2 + (index % 3) * 14
            text: modelData.text
            color: root.pal.muted
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1
        }
    }

    // the axis
    Text {
        x: root.gx0; y: root.gy1 + 8
        text: "5 min ago"
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
    Text {
        x: root.gx1 - width; y: root.gy1 + 8
        text: "now" + (root.hasBat ? "  ·  " + Math.round(root.sBat) + "%" : "") + (root.sysmode !== "" ? "  ·  " + root.sysmode : "")
        color: root.batLevel <= 20 && root.hasBat ? root.pal.bad : root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }

    // scrubbing: the pointer on the graph
    MouseArea {
        x: root.gx0; y: root.gy0 - 8; width: root.gx1 - root.gx0; height: root.gy1 - root.gy0 + 16
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: mouse => root.hoverX = root.gx0 + Math.max(0, Math.min(width, mouse.x))
        onExited: root.hoverX = -1
    }

    // the card with the values at that moment
    Rectangle {
        visible: root.hoverX >= 0
        width: 124; height: 22 + 4 * 17
        x: root.hoverX > 540 ? root.hoverX - width - 12 : root.hoverX + 12
        y: root.gy0 + 14
        radius: root.pal.rMd
        color: Qt.alpha(root.pal.bg, 0.92)
        border.width: 1; border.color: root.pal.lineSoft
        Column {
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
            spacing: 2
            Text {
                text: root.agoText(root.hoverAgo)
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1
            }
            Repeater {
                model: 4
                Row {
                    id: tr
                    required property int index
                    width: parent.width
                    spacing: 6
                    Rectangle { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter; color: root.cols[tr.index] }
                    Text {
                        width: 52
                        text: root.names[tr.index]
                        color: root.pal.muted
                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                    }
                    Text {
                        text: root.hoverVals[tr.index] < 0 ? "—" : Math.round(root.hoverVals[tr.index] * 100) + "%"
                        color: root.pal.text
                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.DemiBold
                    }
                }
            }
        }
    }
}
