import QtQuick

// The Halcyon sky: the splash (Splash.qml) once it has settled, kept as a live wallpaper (Settings > Wallpaper > Live wallpaper)
// and as a lock screen background (Settings > Power & lock > Lock screen background: Halcyon sky).
//   The stars   flying slowly out of the middle, at the pace the splash ends on. One scene item per star, one 20 fps clock.
//   The mark    the four-point sparkle with its two companions, painted ONCE (a Canvas only repaints when the size or the colours
//               change); its halo breathes and the small companion twinkles (scale / opacity from the same clock as the stars).
//   Paused      while `running` is false (shell.qml: a game, a fullscreen window, windows over the whole desktop, the screen locked),
//               the stars hold where they are and nothing is drawn again.
Item {
    id: root
    property var pal
    property bool running: true
    property bool showMark: true           // the lock screen has its own clock in the middle: stars only there
    property bool showWord: true
    property int count: 90
    property real speed: 1                 // 1 = the splash's closing pace
    readonly property bool live: running && visible && width > 0 && height > 0 && (pal ? pal.motion > 0.3 : true)
    readonly property color a1: pal ? pal.accent : "#9aa9d4"
    readonly property color a2: pal ? pal.accent2 : "#c2add8"
    readonly property color ink: pal ? pal.text : "#dcdde8"
    readonly property real cx: width / 2
    readonly property real cy: height * 0.45
    readonly property real maxR: Math.sqrt(width * width + height * height) / 2
    readonly property real markRadius: Math.min(width, height) * 0.11

    // ---- the stage: the theme's background with a soft glow of the accent around the middle (painted once)
    // the background, the glow and the still field of faint stars are ONE picture (one full-screen texture to put on screen per frame)
    Canvas {
        id: tintCv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d")
            ctx.fillStyle = root.pal ? root.pal.bg : "#14161f"
            ctx.fillRect(0, 0, width, height)
            var tr = Math.max(width, height) * 0.62
            var g = ctx.createRadialGradient(root.cx, root.cy, 0, root.cx, root.cy, tr)
            g.addColorStop(0, Qt.rgba(root.a1.r, root.a1.g, root.a1.b, 0.17))
            g.addColorStop(0.55, Qt.rgba(root.a2.r, root.a2.g, root.a2.b, 0.05))
            g.addColorStop(1, Qt.rgba(root.a2.r, root.a2.g, root.a2.b, 0))
            ctx.fillStyle = g
            ctx.fillRect(0, 0, width, height)
            // a little darker towards the corners, like the splash's veil
            var v = ctx.createRadialGradient(root.cx, root.cy, tr * 0.5, root.cx, root.cy, root.maxR * 1.1)
            v.addColorStop(0, "rgba(0,0,0,0)")
            v.addColorStop(1, "rgba(0,0,0,0.35)")
            ctx.fillStyle = v
            ctx.fillRect(0, 0, width, height)
            // a still field of faint stars (the same hash every time, so they never jump)
            var n = Math.round(width * height / 9000)
            for (var i = 0; i < n; i++) {
                var x = root.hash(i + 1000) * width, y = root.hash(i + 5000) * height
                var m = Math.pow(root.hash(i + 9000), 3)
                var c = i % 5 === 0 ? root.a1 : (i % 5 === 1 ? root.a2 : root.ink)
                ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 0.12 + 0.5 * m)
                var r = 0.5 + 1.1 * m
                ctx.beginPath(); ctx.arc(x, y, r, 0, 6.2832); ctx.fill()
            }
        }
    }

    // ---- the stars
    // One clock for everything that moves, 20 times a second. (An Animation would redraw at the screen's full rate, 60+ times a
    // second, and make Hyprland compose the desktop again each time.)
    property real drift: 0
    property real tt: 0                    // seconds the sky has been moving
    property real lastMs: 0
    Timer {
        interval: 50
        repeat: true
        running: root.live
        onRunningChanged: root.lastMs = 0
        onTriggered: {
            var now = Date.now()
            var dt = root.lastMs > 0 ? Math.min(0.2, (now - root.lastMs) / 1000) : 0.05
            root.lastMs = now
            root.tt += dt
            root.drift += dt * 0.022 * root.speed
        }
    }
    // the same spread of directions as the splash (the golden angle), worked out once. The splash's start positions also come
    // from the golden ratio, which lines the stars up in a spiral once they move slowly: here they start from a hash instead.
    function hash(i) { var x = Math.sin(i * 12.9898 + 4.1414) * 43758.5453; return x - Math.floor(x) }
    property var dirs: []
    function buildDirs() {
        var a = []
        for (var i = 0; i < count; i++) {
            var ang = i * 2.399963 + (i % 7) * 0.05
            a.push({ ang: ang * 57.29578, c: Math.cos(ang), s: Math.sin(ang), base: hash(i),
                     v: 0.55 + (i % 5) * 0.22, w: (i % 4 === 0 ? 0.5 : 0), al: 0.35 + 0.1 * (i % 5), k: i % 3 })
        }
        dirs = a
    }
    onCountChanged: buildDirs()
    Component.onCompleted: buildDirs()
    Item {
        anchors.fill: parent
        Repeater {
            model: root.dirs
            delegate: Rectangle {
                required property var modelData
                readonly property var q: modelData
                readonly property real rr: ((q.base + root.drift * q.v) % 1 + 1) % 1      // 0 = centre, 1 = edge
                readonly property real d: rr * rr * root.maxR + 14
                // a short streak along its way out, longer the further it is
                width: 4 + rr * 14
                height: 0.6 + rr * 1.6 + q.w
                radius: height / 2
                antialiasing: true
                x: root.cx + q.c * d - width
                y: root.cy + q.s * d - height / 2
                transformOrigin: Item.Right
                rotation: q.ang
                color: q.k === 0 ? root.a1 : (q.k === 1 ? root.a2 : root.ink)
                opacity: Math.min(1, rr * 6) * Math.min(1, (1 - rr) * 4) * q.al
            }
        }
    }

    // ---- the mark
    Item {
        id: markBox
        visible: root.showMark
        width: root.markRadius * 5.2
        height: width
        x: root.cx - width / 2
        y: root.cy - height / 2

        // the halo: painted once, breathes slowly
        Canvas {
            id: halo
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var R = root.markRadius, hr = R * 1.8
                var g = ctx.createRadialGradient(width / 2, height / 2, 0, width / 2, height / 2, hr)
                g.addColorStop(0, Qt.rgba(root.a1.r, root.a1.g, root.a1.b, 0.42))
                g.addColorStop(0.5, Qt.rgba(root.a2.r, root.a2.g, root.a2.b, 0.14))
                g.addColorStop(1, Qt.rgba(root.a2.r, root.a2.g, root.a2.b, 0))
                ctx.fillStyle = g
                ctx.beginPath(); ctx.arc(width / 2, height / 2, hr, 0, 6.2832); ctx.fill()
            }
            scale: 1 + 0.06 * Math.sin(root.tt * 0.748)          // breathes once every 8.4 s
        }

        // the star, its flare and the large companion (as the splash leaves them)
        Canvas {
            id: mark
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var R = root.markRadius, a1 = root.a1, a2 = root.a2, tx = root.ink
                function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
                function star(rv, rh, k) {
                    var c = Math.min(rv, rh) * k
                    ctx.beginPath()
                    ctx.moveTo(0, -rv)
                    ctx.quadraticCurveTo(c, -c, rh, 0)
                    ctx.quadraticCurveTo(c, c, 0, rv)
                    ctx.quadraticCurveTo(-c, c, -rh, 0)
                    ctx.quadraticCurveTo(-c, -c, 0, -rv)
                    ctx.closePath()
                }
                ctx.save()
                ctx.translate(width / 2, height / 2)
                var fl = R * 2.3
                var lg = ctx.createLinearGradient(-fl, 0, fl, 0)
                lg.addColorStop(0, rgba(a1, 0)); lg.addColorStop(0.5, rgba(tx, 0.55)); lg.addColorStop(1, rgba(a1, 0))
                ctx.fillStyle = lg
                ctx.fillRect(-fl, -0.7, fl * 2, 1.4)
                var vl = fl * 0.55
                var vg = ctx.createLinearGradient(0, -vl, 0, vl)
                vg.addColorStop(0, rgba(a2, 0)); vg.addColorStop(0.5, rgba(tx, 0.35)); vg.addColorStop(1, rgba(a2, 0))
                ctx.fillStyle = vg
                ctx.fillRect(-0.6, -vl, 1.2, vl * 2)
                var rv = R, rh = R * 0.84
                var fg = ctx.createLinearGradient(-rh, -rv, rh, rv)
                fg.addColorStop(0, rgba(a1, 1)); fg.addColorStop(0.5, rgba(tx, 0.96)); fg.addColorStop(1, rgba(a2, 1))
                ctx.fillStyle = fg
                star(rv, rh, 0.11)
                ctx.fill()
                var cg = ctx.createRadialGradient(0, 0, 0, 0, 0, R * 0.38)
                cg.addColorStop(0, Qt.rgba(1, 1, 1, 0.95)); cg.addColorStop(1, Qt.rgba(1, 1, 1, 0))
                ctx.fillStyle = cg
                ctx.beginPath(); ctx.arc(0, 0, R * 0.38, 0, 6.2832); ctx.fill()
                ctx.save(); ctx.translate(R * 1.18, -R * 0.92); ctx.rotate(0.2)
                ctx.fillStyle = rgba(a2, 0.95)
                star(R * 0.26, R * 0.22, 0.12); ctx.fill(); ctx.restore()
                ctx.restore()
            }
        }

        // the small companion twinkles
        Canvas {
            id: twinkle
            width: root.markRadius * 0.4
            height: width
            x: parent.width / 2 - root.markRadius * 1.05 - width / 2
            y: parent.height / 2 + root.markRadius * 0.98 - height / 2
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var rv = root.markRadius * 0.15, rh = root.markRadius * 0.13, c = Math.min(rv, rh) * 0.12
                ctx.translate(width / 2, height / 2)
                ctx.fillStyle = Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.95)
                ctx.beginPath()
                ctx.moveTo(0, -rv)
                ctx.quadraticCurveTo(c, -c, rh, 0)
                ctx.quadraticCurveTo(c, c, 0, rv)
                ctx.quadraticCurveTo(-c, c, -rh, 0)
                ctx.quadraticCurveTo(-c, -c, 0, -rv)
                ctx.closePath()
                ctx.fill()
            }
            opacity: 0.75 + 0.2 * Math.sin(root.tt * 1.5)         // twinkles every 4.2 s
        }
    }

    Text {
        visible: root.showMark && root.showWord
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: font.letterSpacing / 2
        y: root.cy + root.markRadius * 1.7
        text: "HALCYON"
        color: root.ink
        opacity: 0.85
        font.family: root.pal ? root.pal.uiFont : "Inter"
        font.pixelSize: Math.max(16, Math.round(root.markRadius * 0.45))
        font.weight: Font.Light
        font.letterSpacing: Math.max(8, root.markRadius * 0.34)
    }

    function repaint() { tintCv.requestPaint(); halo.requestPaint(); mark.requestPaint(); twinkle.requestPaint() }
    onWidthChanged: repaint()
    onHeightChanged: repaint()
    onA1Changed: repaint()
    onA2Changed: repaint()
    onInkChanged: repaint()
}
