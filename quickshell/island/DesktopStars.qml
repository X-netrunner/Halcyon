import QtQuick

// Moving stars for the desktop (Settings > Appearance > Desktop builder). Lives inside Wallpaper.qml, ABOVE the picture, so it
// works on a wallpaper, on a blurred one and on the plain background you get with the wallpaper switched off.
//   count / speed / size / direction / colour / twinkle / shooting stars all come from opt.desk* (Desktop builder).
// Light on purpose: ONE 30 fps timer moves everything; it stops completely when the stars are off, the window is hidden or the
// motion setting is nearly off (Gaming mode). Nothing is drawn per frame except the star items themselves (a few dozen rectangles).
Item {
    id: root
    property var pal
    property var opt: ({})
    property real previewScale: 1          // the builder's small preview draws the same stars smaller
    property bool forceOn: false           // the builder preview shows them even while the real ones are off

    readonly property bool on: forceOn || (opt && opt.deskStars === true)
    readonly property int count: Math.max(10, Math.min(250, opt && opt.deskStarCount !== undefined ? Number(opt.deskStarCount) : 70))
    readonly property real speed: Math.max(0.1, Math.min(4, opt && opt.deskStarSpeed !== undefined ? Number(opt.deskStarSpeed) : 1))
    readonly property real sizeK: Math.max(0.5, Math.min(3, opt && opt.deskStarSize !== undefined ? Number(opt.deskStarSize) : 1)) * previewScale
    readonly property string dir: (opt && opt.deskStarDir) || "right"       // right | left | up | down | diag
    readonly property string tone: (opt && opt.deskStarTone) || "mix"       // accent | mix | white
    readonly property bool twinkle: !(opt && opt.deskStarTwinkle === false)
    readonly property bool shooting: opt && opt.deskStarShoot === true
    readonly property real vx: dir === "right" ? 1 : dir === "left" ? -1 : dir === "diag" ? 1 : 0
    readonly property real vy: dir === "down" ? 1 : dir === "up" ? -1 : dir === "diag" ? 0.4 : 0

    readonly property bool live: on && visible && width > 0 && height > 0 && (pal ? pal.motion > 0.3 : true)
    property real t: 0                      // seconds of drifting so far (kept while hidden, so the stars carry on)
    Timer {
        interval: 33
        repeat: true
        running: root.live
        onTriggered: root.t += interval / 1000
    }

    Repeater {
        model: root.live ? root.count : 0
        delegate: Item {
            id: st
            required property int index
            readonly property real fx: (index * 0.6180339 + 0.11) % 1
            readonly property real fy: (index * 0.4142135 + 0.23) % 1
            readonly property int depth: index % 3                                   // 0 far, 1 middle, 2 near: near ones are bigger, brighter, faster
            readonly property real rate: 0.012 * root.speed * (0.5 + 0.55 * depth)    // screens per second
            readonly property real px: (((fx + root.vx * rate * root.t) % 1) + 1) % 1
            readonly property real py: (((fy + root.vy * rate * root.t) % 1) + 1) % 1
            readonly property real ex: Math.min(1, Math.min(px, 1 - px) * root.width / 36)    // fade at the edges where they wrap round
            readonly property real ey: Math.min(1, Math.min(py, 1 - py) * root.height / 36)
            readonly property real size: (1.1 + depth * 0.7 + (index % 4) * 0.25) * root.sizeK
            readonly property real tw: 0.5 + 0.5 * Math.sin(6.2832 * (root.t * (0.12 + (index % 5) * 0.06) + fx * 7))
            readonly property real base: 0.35 + 0.22 * depth
            readonly property color tint: root.tone === "white" ? "#ffffff"
                                        : root.tone === "accent" ? root.pal.accent
                                        : (index % 3 === 0 ? root.pal.accent : (index % 3 === 1 ? root.pal.accent2 : "#ffffff"))

            x: px * root.width
            y: py * root.height
            opacity: ex * ey * base * (root.twinkle ? (0.35 + 0.65 * tw) : 1)

            Rectangle {
                width: st.size; height: st.size; radius: st.size / 2
                x: -st.size / 2; y: -st.size / 2
                color: st.tint
            }
            // the near, brighter ones get a small glint cross
            Rectangle { visible: st.depth === 2 && st.index % 2 === 0; width: st.size * 4.5; height: 1; x: -width / 2; y: -0.5; color: Qt.alpha(st.tint, 0.45) }
            Rectangle { visible: st.depth === 2 && st.index % 2 === 0; width: 1; height: st.size * 4.5; x: -0.5; y: -height / 2; color: Qt.alpha(st.tint, 0.45) }
        }
    }

    // ---- an occasional shooting star (one at a time, every 6 to 15 seconds)
    Item {
        id: shot
        property real prog: 0
        property real sx: 0
        property real sy: 0
        visible: prog > 0 && prog < 1
        x: sx + prog * root.width * 0.22
        y: sy + prog * root.height * 0.16
        opacity: Math.sin(Math.PI * prog)
        rotation: 36
        Rectangle {
            width: 90 * root.previewScale + 20; height: Math.max(1, 1.5 * root.previewScale)
            x: -width; y: -height / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.alpha(root.pal.accent2, 0.95) }
            }
        }
        Rectangle { width: 3 * root.previewScale + 1; height: width; radius: width / 2; x: -width / 2; y: -width / 2; color: "#ffffff" }
        NumberAnimation on prog { id: shotAnim; running: false; from: 0; to: 1; duration: 950; easing.type: Easing.InOutSine }
    }
    Timer {
        interval: 5000
        repeat: true
        running: root.live && root.shooting
        onTriggered: {
            interval = 6000 + Math.random() * 9000
            shot.sx = root.width * (0.15 + Math.random() * 0.6)
            shot.sy = root.height * (0.02 + Math.random() * 0.4)
            shotAnim.restart()
        }
    }
}
