import QtQuick

// The Halcyon splash: a sky of slow moving stars and a four-point sparkle that unfolds in the middle, then the word HALCYON.
// Played on the lock screen when it is also the login screen (so the session lock is already up while it shows: nothing is ever left
// open behind it), and on its own from Settings > Power & lock > "Play the splash" / `halcyon splash`.
//
//   The mark    a four-point star with curved, pinched sides (the same family as the sparkle you know, but with a longer upright arm,
//               a hot white core, a fine flare line through it and two small companion stars), filled from accent to accent 2.
//   The stars   about 90 dots flying out of the centre, fast at first and slowing as the mark settles. One 30 fps timer, one Canvas,
//               and both stop the moment it ends. Nothing is kept afterwards.
//   Skip        a click, or any key (the lock screen calls skip() when you start typing; the preview window on any key).
//
//   Modes       login     the stars rush out of the centre and the mark unfolds (the one above; lock screen at login)
//               unlock    the same, but shorter, and the stage itself fades away so the desktop shows through while the mark flares
//                         (played on top of the desktop right after you unlock; it never takes a click or a key)
//               shutdown  the same film played BACKWARDS: the stars are drawn back into the centre, the mark folds shut, and the
//                         screen is left bare (it holds there until the host powers off; finished() is the cue to do that)
//
//   start()     play from the beginning       skip()  fade out now (shutdown: jump to the end, finished() at once)
//   handoff()   (signal) the fade-out begins: the screen under it can start easing in
//   finished()  (signal) it is over (login / unlock: invisible; shutdown: bare screen, still shown)
Item {
    id: root
    property var pal
    property int duration: 3600           // ms from the first star to the last fade
    property string mode: "login"         // login | unlock | shutdown (see above)
    property real dim: 0.75               // 0 .. 0.9: how dark the screen gets while it plays (Settings > Splash, sky & time of day), so the
                                          // stars and the word read on a light theme or a bright wallpaper showing through on unlock
    // on a darkened screen the theme's own text colour can be dark (light theme): use a soft white then
    readonly property color ink: pal && pal.light && dim >= 0.35 ? Qt.rgba(0.95, 0.95, 0.98, 1) : (pal ? pal.text : "white")
    readonly property bool rev: mode === "shutdown"
    property bool ended: false            // shutdown: the collapse has finished and the screen is being held bare
    property bool playing: false
    property real p: 0                    // 0 .. 1 over `duration`
    property real skipFade: 0             // 0 .. 1 when skipped
    property bool handed: false
    signal handoff()
    signal finished()

    visible: playing
    // login / unlock fade out over the last 12 %; the shutdown film (p runs 1 -> 0) fades IN over its first 10 % and never out
    opacity: rev ? (1 - skipFade) * (1 - seg(0.90, 1.0)) : (1 - skipFade) * (1 - seg(0.88, 1.0))

    function seg(a, b) { return Math.max(0, Math.min(1, (p - a) / (b - a))) }
    function eo(x) { return 1 - Math.pow(1 - x, 3) }
    function start() {
        anim.stop(); skipAnim.stop()
        p = rev ? 1 : 0; skipFade = 0; handed = rev; drift = 0; lastMs = 0; ended = false
        playing = true
        anim.restart()
    }
    function skip() {
        if (!playing || skipAnim.running || ended) return
        anim.stop()
        if (rev) { p = 0; ended = true; finished(); return }       // goodbye: no fade, straight to the bare screen and the cue
        if (!handed) { handed = true; handoff() }
        skipAnim.restart()
    }
    function end() {
        if (rev) { if (!ended) { ended = true; finished() } return }   // keep the bare screen up until the host acts
        playing = false; p = 0; skipFade = 0; finished()
    }
    onPChanged: {
        if (!handed && p >= 0.86) { handed = true; handoff() }
        mark.requestPaint()           // the mark, its companions and the pulse all depend on p
    }

    NumberAnimation { id: anim; target: root; property: "p"; from: root.rev ? 1 : 0; to: root.rev ? 0 : 1; duration: root.duration; onFinished: root.end() }
    NumberAnimation { id: skipAnim; target: root; property: "skipFade"; from: 0; to: 1; duration: 260; onFinished: root.end() }

    // ---- stage
    // (unlock: the stage melts away early, so the desktop is already visible while the stars are still flying and the mark is flaring)
    Rectangle { anchors.fill: parent; color: root.pal.bg; opacity: root.mode === "unlock" ? 1 - root.eo(root.seg(0.30, 0.78)) : 1 }
    // the dark veil over the stage (and over the desktop once the unlock stage has melted); it leaves with the whole splash
    Rectangle { anchors.fill: parent; color: "black"; opacity: root.dim }

    // ---- moving stars (they fly out of the middle; their speed falls as the mark settles)
    property real drift: 0
    property real lastMs: 0
    Timer {
        interval: 33
        repeat: true
        running: root.playing && !root.ended          // shutdown: stops once the stars are all home, while the bare screen is held
        onTriggered: {
            var now = Date.now()
            var dt = root.lastMs > 0 ? Math.min(0.12, (now - root.lastMs) / 1000) : 0.033
            root.lastMs = now
            // backwards for shutdown: the same speed curve (it is read from p, which is running down), so the stars are slow while the
            // mark is whole and are pulled in faster and faster as it folds up
            root.drift += (root.rev ? -dt : dt) * (0.045 + 0.34 * (1 - root.eo(root.seg(0.0, 0.7))))
            sky.requestPaint()
        }
    }
    // every star's direction and speed never change: worked out once, not 30 times a second
    readonly property int nStars: 90
    property var dirs: []
    function buildDirs() {
        var a = []
        for (var i = 0; i < nStars; i++) {
            var ang = i * 2.399963 + (i % 7) * 0.05          // the golden angle: an even spread, no clumps
            a.push({ c: Math.cos(ang), s: Math.sin(ang), base: (i * 0.6180339 + 0.13) % 1, v: 0.55 + (i % 5) * 0.22,
                     w: (i % 4 === 0 ? 0.5 : 0), al: 0.35 + 0.1 * (i % 5), k: i % 3 })
        }
        dirs = a
    }
    Component.onCompleted: buildDirs()

    Canvas {
        id: sky
        anchors.fill: parent
        renderTarget: Canvas.FramebufferObject
        renderStrategy: Canvas.Immediate
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!root.playing) return
            var cx = width / 2, cy = height * 0.45
            var maxR = Math.sqrt(width * width + height * height) / 2
            var a1 = root.pal.accent, a2 = root.pal.accent2, tx = root.ink
            var fadeIn = root.eo(root.seg(0.0, 0.2))
            var calm = 1 - root.eo(root.seg(0.0, 0.7))           // 1 while the stars rush, 0 once the mark has settled
            // a soft tint in the middle, so the mark has something to glow against (a real radial gradient)
            var tr = Math.max(width, height) * 0.6
            var tg = ctx.createRadialGradient(cx, cy, 0, cx, cy, tr)
            tg.addColorStop(0, Qt.rgba(a1.r, a1.g, a1.b, 0.16 * root.eo(root.seg(0.05, 0.5))))
            tg.addColorStop(1, Qt.rgba(a1.r, a1.g, a1.b, 0))
            ctx.fillStyle = tg
            ctx.fillRect(0, 0, width, height)
            ctx.lineCap = "round"
            var D = root.dirs
            for (var i = 0; i < D.length; i++) {
                var q = D[i]
                var rr = ((q.base + root.drift * q.v) % 1 + 1) % 1   // 0 = centre, 1 = edge (the +1 keeps it positive when drift runs backwards)
                var d = rr * rr * maxR + 14
                var tail = Math.min(d - 10, 4 + rr * 26 * (0.5 + 1.5 * calm))
                var al = Math.min(1, rr * 6) * Math.min(1, (1 - rr) * 4) * fadeIn * q.al
                var c = q.k === 0 ? a1 : (q.k === 1 ? a2 : tx)
                ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, al)
                ctx.lineWidth = 0.6 + rr * 1.6 + q.w
                ctx.beginPath()
                // the streak trails behind the star: towards the centre while they fly out, towards the edge while they are drawn in
                var d0 = root.rev ? d : d - tail, d1 = root.rev ? d + tail : d
                ctx.moveTo(cx + q.c * d0, cy + q.s * d0)
                ctx.lineTo(cx + q.c * d1, cy + q.s * d1)
                ctx.stroke()
            }
        }
    }

    // ---- the mark
    readonly property real markRadius: Math.min(width, height) * 0.13
    readonly property real grow: eo(seg(0.10, 0.50))
    readonly property real glow: eo(seg(0.28, 0.62))
    readonly property real flare: eo(seg(0.40, 0.68))
    readonly property real pulse: 0.5 + 0.5 * Math.sin(Math.max(0, p - 0.55) * 14)
    onWidthChanged: mark.requestPaint()

    Canvas {
        id: mark
        width: root.markRadius * 5.2
        height: width
        x: root.width / 2 - width / 2
        y: root.height * 0.45 - height / 2
        renderTarget: Canvas.FramebufferObject
        renderStrategy: Canvas.Immediate
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!root.playing) return
            var R = root.markRadius, g = root.grow, a1 = root.pal.accent, a2 = root.pal.accent2, tx = root.ink
            function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
            // a four-point star with pinched, curved sides; rv = upright arm, rh = sideways arm, k = how deep the sides curve in
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

            // halo
            var hr = R * (1.7 + 0.25 * root.pulse)
            var hg = ctx.createRadialGradient(0, 0, 0, 0, 0, hr)
            hg.addColorStop(0, rgba(a1, 0.42 * root.glow))
            hg.addColorStop(0.5, rgba(a2, 0.14 * root.glow))
            hg.addColorStop(1, rgba(a2, 0))
            ctx.fillStyle = hg
            ctx.beginPath(); ctx.arc(0, 0, hr, 0, 6.2832); ctx.fill()

            // flare: a fine line through the middle, a little longer sideways
            var fl = R * 2.3 * root.flare
            if (fl > 1) {
                var lg = ctx.createLinearGradient(-fl, 0, fl, 0)
                lg.addColorStop(0, rgba(a1, 0)); lg.addColorStop(0.5, rgba(tx, 0.55 * root.flare)); lg.addColorStop(1, rgba(a1, 0))
                ctx.fillStyle = lg
                ctx.fillRect(-fl, -0.7, fl * 2, 1.4)
                var vl = fl * 0.55
                var vg = ctx.createLinearGradient(0, -vl, 0, vl)
                vg.addColorStop(0, rgba(a2, 0)); vg.addColorStop(0.5, rgba(tx, 0.35 * root.flare)); vg.addColorStop(1, rgba(a2, 0))
                ctx.fillStyle = vg
                ctx.fillRect(-0.6, -vl, 1.2, vl * 2)
            }

            // the main star: unwinds a little as it opens, upright arm longer than the sideways one
            ctx.save()
            ctx.rotate((1 - g) * -1.1)
            var rv = R * g, rh = R * 0.84 * g
            if (rv > 1) {
                var fg = ctx.createLinearGradient(-rh, -rv, rh, rv)
                fg.addColorStop(0, rgba(a1, 1)); fg.addColorStop(0.5, rgba(tx, 0.96)); fg.addColorStop(1, rgba(a2, 1))
                ctx.fillStyle = fg
                star(rv, rh, 0.11)
                ctx.fill()
                // hot core
                var cg = ctx.createRadialGradient(0, 0, 0, 0, 0, R * 0.38 * g)
                cg.addColorStop(0, Qt.rgba(1, 1, 1, 0.95)); cg.addColorStop(1, Qt.rgba(1, 1, 1, 0))
                ctx.fillStyle = cg
                ctx.beginPath(); ctx.arc(0, 0, R * 0.38 * g, 0, 6.2832); ctx.fill()
            }
            ctx.restore()

            // two companions, born a moment later (the small one twinkles)
            var s1 = root.eo(root.seg(0.46, 0.68)), s2 = root.eo(root.seg(0.54, 0.76))
            if (s1 > 0.01) {
                ctx.save(); ctx.translate(R * 1.18, -R * 0.92); ctx.rotate(0.2)
                ctx.fillStyle = rgba(a2, 0.95)
                star(R * 0.26 * s1, R * 0.22 * s1, 0.12); ctx.fill(); ctx.restore()
            }
            if (s2 > 0.01) {
                ctx.save(); ctx.translate(-R * 1.05, R * 0.98)
                ctx.fillStyle = rgba(tx, 0.55 + 0.4 * root.pulse)
                star(R * 0.15 * s2, R * 0.13 * s2, 0.12); ctx.fill(); ctx.restore()
            }
            ctx.restore()
        }
    }

    // ---- the word
    Text {
        id: word
        anchors.horizontalCenter: parent.horizontalCenter
        // Qt adds the letter spacing after the last letter too, which pushes the word left of centre by half of it: give that back
        anchors.horizontalCenterOffset: font.letterSpacing / 2
        y: root.height * 0.45 + root.markRadius * 1.7 + 18 * (1 - root.eo(root.seg(0.52, 0.82)))
        text: "HALCYON"
        color: root.ink
        font.family: root.pal.uiFont
        font.pixelSize: Math.max(18, Math.round(root.markRadius * 0.5))
        font.weight: Font.Light
        font.letterSpacing: Math.max(8, root.markRadius * 0.34) * (1.4 - 0.4 * root.eo(root.seg(0.52, 0.9)))
        opacity: root.eo(root.seg(0.52, 0.82))
    }

    // a click skips it (keys are handled by whoever hosts it: the lock screen skips when you start typing, the preview window on any key)
    MouseArea { anchors.fill: parent; enabled: root.playing && root.mode !== "unlock"; onPressed: root.skip() }
}
