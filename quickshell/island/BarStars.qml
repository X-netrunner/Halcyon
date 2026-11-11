import QtQuick

// The moving stars of the bar (and of every panel that flies a few): a small sky that drifts slowly along the area it is given.
//   - three depths: far stars are small, dim and slow, near ones are bigger, brighter, quicker and leave a short tail, so the row has
//     a parallax instead of seven dots on one line. Each star has its own hash, so nothing lines up.
//   - a soft halo round the brighter ones, a little four-point glint on the nearest ones when they twinkle up, a very gentle bob
//   - now and then (every 9 to 20 s) a shooting star crosses; `shooting: false` leaves it out
//   - the clock is REAL time (Date.now), so a late tick never makes them stutter or jump; ~30 fps, half of that in Low power
//     (Pal.starSlow), and one timer moves every star. They stand still, and the timer stops, whenever the area is hidden, a page is open,
//     or the motion setting is nearly off (e.g. Gaming mode).
// Position, twinkle and bob all loop exactly once per `loopMs`, so there is no jump when the clock wraps. Give it the area to fly in
// (x / y / width / height); it clips to it.
Item {
    id: root
    property var pal
    opacity: pal ? pal.decor : 1          // the calm interface keeps the moving stars, softly (Pal.decor)
    property bool active: true
    property int count: 7
    property int loopMs: 90000
    property real sizeScale: 1
    property bool shooting: true
    clip: true

    readonly property bool live: active && visible && width > 0 && height > 0 && (pal ? pal.motion > 0.3 : true)
    property real t: 0                    // 0..1 of the loop
    property real lastMs: 0

    Timer {
        interval: Math.round(33 * (root.pal ? root.pal.starSlow : 1))
        repeat: true
        running: root.live
        onRunningChanged: root.lastMs = 0
        onTriggered: {
            var now = Date.now()
            var dt = root.lastMs > 0 ? Math.min(250, now - root.lastMs) : interval
            root.lastMs = now
            root.t = (root.t + dt / root.loopMs) % 1
        }
    }

    // a hash per star and per quantity: stable (the same sky every time), nothing on a visible lattice
    function rnd(i, k) { var x = Math.sin(i * 127.1 + k * 311.7 + 17.3) * 43758.5453; return x - Math.floor(x) }

    Repeater {
        model: root.live ? root.count : 0
        delegate: Item {
            id: st
            required property int index
            readonly property int depth: Math.floor(root.rnd(index, 1) * 3)                    // 0 far, 1 middle, 2 near
            readonly property real fx: root.rnd(index, 2)
            readonly property real fy: root.rnd(index, 3)
            readonly property int dir: root.rnd(index, 4) < 0.22 ? -1 : 1                       // most fly one way, a few the other
            readonly property int speed: 1 + depth                                              // widths per loop: far 1, near 3
            readonly property int blink: 4 + Math.floor(root.rnd(index, 5) * 9)                 // twinkles per loop
            readonly property real size: (1.1 + depth * 0.55 + root.rnd(index, 6) * 0.5) * root.sizeScale
            readonly property real bright: 0.38 + depth * 0.24                                  // far ones are dim
            readonly property real px: (((fx + dir * root.t * speed) % 1) + 1) % 1
            readonly property real edge: Math.min(1, Math.min(px, 1 - px) * root.width / 30)    // fade in / out at the two ends
            readonly property real tw: 0.5 + 0.5 * Math.sin(6.2832 * (root.t * blink + fx * 3))
            readonly property color tone: root.rnd(index, 7) < 0.4 ? root.pal.accent
                                          : (root.rnd(index, 7) < 0.8 ? root.pal.accent2 : (root.pal.light ? root.pal.accent : "#ffffff"))

            x: px * root.width
            y: 2 + fy * Math.max(0, root.height - 4) + (0.8 + depth * 0.5) * Math.sin(6.2832 * (root.t * 2 + fx))
            opacity: edge * st.bright * (0.45 + 0.55 * tw)

            // a short fading tail behind the quick ones (the direction it flies in)
            Rectangle {
                visible: st.depth >= 1
                x: st.dir > 0 ? -width : 0
                y: -height / 2
                width: (st.depth === 2 ? 14 : 8) * root.sizeScale; height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: st.dir > 0 ? "transparent" : Qt.alpha(st.tone, 0.5) }
                    GradientStop { position: 1.0; color: st.dir > 0 ? Qt.alpha(st.tone, 0.5) : "transparent" }
                }
            }
            // the halo
            Rectangle {
                visible: st.depth >= 1
                width: st.size * 4; height: width; radius: width / 2
                x: -width / 2; y: -height / 2
                color: Qt.alpha(st.tone, 0.10 + 0.10 * st.tw)
            }
            // the star
            Rectangle {
                width: st.size; height: st.size; radius: st.size / 2
                x: -width / 2; y: -height / 2
                color: root.pal.solid ? Qt.lighter(st.tone, 1.25) : Qt.lighter(st.tone, 1.1)
            }
            // the glint of a near star at the top of its twinkle
            Rectangle {
                visible: st.depth === 2 && st.tw > 0.75
                width: st.size * 5.5; height: 1
                x: -width / 2; y: -0.5
                color: st.tone; opacity: (st.tw - 0.75) * 3
            }
            Rectangle {
                visible: st.depth === 2 && st.tw > 0.75
                width: 1; height: st.size * 5.5
                x: -0.5; y: -height / 2
                color: st.tone; opacity: (st.tw - 0.75) * 3
            }
        }
    }

    // ---- a shooting star, one at a time: a thin streak with a bright head, a slight downward slant
    Item {
        id: shot
        property real prog: 0
        property real sx: 0
        property real sy: 0
        property int sdir: 1
        readonly property real run: Math.min(root.width * 0.35, 170 * root.sizeScale)
        visible: root.live && root.shooting && prog > 0 && prog < 1
        x: sx + sdir * prog * run
        y: sy + prog * Math.min(root.height * 0.5, 10)
        opacity: Math.sin(Math.PI * prog) * 0.85
        rotation: sdir > 0 ? 8 : 172
        Rectangle {
            width: 30 * root.sizeScale; height: 1
            x: -width; y: -0.5
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.alpha(root.pal ? root.pal.accent2 : "#81a1c1", 0.95) }
            }
        }
        Rectangle { width: 2.2 * root.sizeScale; height: width; radius: width / 2; x: -width / 2; y: -height / 2; color: "#ffffff" }
        NumberAnimation on prog { id: shotAnim; running: false; from: 0; to: 1; duration: 1300; easing.type: Easing.InOutSine }
    }
    Timer {
        interval: 6000
        repeat: true
        running: root.live && root.shooting && root.width > 220
        onTriggered: {
            interval = 9000 + Math.random() * 11000
            shot.sdir = Math.random() < 0.8 ? 1 : -1
            shot.sx = root.width * (shot.sdir > 0 ? 0.05 + Math.random() * 0.45 : 0.5 + Math.random() * 0.45)
            shot.sy = 3 + Math.random() * Math.max(0, root.height * 0.45)
            shotAnim.restart()
        }
    }
}
