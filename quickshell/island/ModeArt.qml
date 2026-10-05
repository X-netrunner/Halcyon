import QtQuick
import QtQuick.Shapes
import "StarData.js" as Stars

// Constellation art, drawn in the wallpaper accent colour: stars with soft halos joined by hairlines.
//   lockdown  a shield          stealth  a coiled dragon          (both hand-placed, see StarData.js)
//   avatar    your profile picture turned into a constellation (`hx stars <image>`), via `custom`
// Vector only, so it is crisp at any size and free while hidden. Sits behind content; `strength` scales it.
//
// Alive: the whole sky breathes and sways a little, every star flickers on its own rhythm, lights travel along
// the lines, a shooting star crosses now and then, and the near / far layers drift against each other when the
// pointer moves. `energy` (0..1) makes it flare up: the lock screen kicks it on every key press.
// Everything stops when `pal.motion` is low (Gaming mode) or the art is hidden, so it costs nothing then.
Item {
    id: root
    property var pal
    property string mode: ""            // lockdown | stealth | avatar | "" (nothing)
    property var custom: null           // { w, h, stars:[[x,y,size]], edges:[[a,b]], dust:[[x,y,size]] } for mode "avatar"
    property real strength: 1.0
    property real fit: 0.9
    property real tilt: 0
    property real energy: 0             // 0..1: brief flare (set by the owner, it decays back by itself)
    property bool alive: true           // set false to freeze (still art)

    readonly property var art: mode === "lockdown" ? Stars.shield : (mode === "stealth" ? Stars.dragon : (mode === "avatar" ? custom : null))
    visible: art !== null && art !== undefined && strength > 0
    opacity: strength

    readonly property color tone: pal.accent
    readonly property real dw: art ? art.w : 100
    readonly property real dh: art ? art.h : 100
    readonly property bool live: alive && visible && (pal ? pal.motion > 0.3 : true)

    // ---- growth (0..1, Settings > Constellations): stars / edges with a birth value t appear as it passes t
    readonly property real g: (pal && pal.growthOn) ? pal.growth : 0
    function bornT(s) { return s.length > 3 ? s[3] : 0 }
    // how far a star has travelled from where it started (0..1, eased): wings unfold, rims bloom
    function grownAmt(s) {
        var t = bornT(s)
        if (t <= 0 || s.length < 6) return 1
        var r = Math.max(0, Math.min(1, (g - t) / 0.12))
        return r * r * (3 - 2 * r)
    }
    function sx(s) { var k = grownAmt(s); return k >= 1 ? s[0] : s[4] + (s[0] - s[4]) * k }
    function sy(s) { var k = grownAmt(s); return k >= 1 ? s[1] : s[5] + (s[1] - s[5]) * k }
    // fades in over a little growth after its birth value
    function fadeIn(s) { var t = bornT(s); return t <= 0 ? 1 : Math.max(0, Math.min(1, (g - t) / 0.04)) }
    function edgeOn(e) { return e.length < 3 || e[2] <= g }

    // edges as one path: "M x,y L x,y M ...", with the line segments kept for the travelling lights
    readonly property string edgePath: {
        if (!art) return ""
        var p = "", s = art.stars, e = art.edges, gg = g
        for (var i = 0; i < e.length; i++) {
            if (!edgeOn(e[i])) continue
            var a = s[e[i][0]], b = s[e[i][1]]
            if (a && b) p += "M" + sx(a) + "," + sy(a) + " L" + sx(b) + "," + sy(b) + " "
        }
        return p
    }
    // up to 16 evenly spread edges carry a travelling light
    readonly property var pulseEdges: {
        if (!art) return []
        var e = [], all = art.edges, gg = g
        for (var k = 0; k < all.length; k++) if (edgeOn(all[k])) e.push(all[k])
        var out = [], step = Math.max(1, Math.floor(e.length / 16))
        for (var i = 0; i < e.length && out.length < 16; i += step) out.push(e[i])
        return out
    }

    // sizes are in screen pixels whatever the art is scaled to (the avatar grid is only 96 units wide)
    readonly property real baseScale: Math.min(root.width / root.dw, root.height / root.dh) * root.fit
    readonly property real u: 1 / Math.max(0.05, baseScale)

    // shared clocks: ph = slow twinkle / breathing (7 s), cyc = travelling lights (6 s). Integer multiples keep them seamless.
    property real ph: 0
    NumberAnimation on ph { from: 0; to: 6.2832; duration: 7000; loops: Animation.Infinite; running: root.live }
    property real cyc: 0
    NumberAnimation on cyc { from: 0; to: 1; duration: 6000; loops: Animation.Infinite; running: root.live }

    // pointer parallax: -0.5 .. 0.5 across the art, eased
    HoverHandler { id: hh; enabled: root.live }
    readonly property real px: hh.hovered ? (hh.point.position.x / Math.max(1, root.width) - 0.5) : 0
    readonly property real py: hh.hovered ? (hh.point.position.y / Math.max(1, root.height) - 0.5) : 0

    Item {
        id: stage
        width: root.dw
        height: root.dh
        anchors.centerIn: parent
        rotation: root.tilt
        scale: root.baseScale

        // the sky breathes and sways
        Item {
            id: sky
            anchors.fill: parent
            scale: 1 + 0.010 * Math.sin(root.ph) + 0.035 * root.energy
            rotation: root.live ? 0.7 * Math.sin(root.ph + 1.0) : 0

            // far layer: dust, moves against the pointer a little
            Item {
                id: far
                width: parent.width; height: parent.height
                x: -root.px * 7 * root.u
                y: -root.py * 7 * root.u
                Behavior on x { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                Behavior on y { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                Repeater {
                    model: root.art && root.art.dust ? root.art.dust : []
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        x: modelData[0] - 0.8 * root.u; y: modelData[1] - 0.8 * root.u
                        width: (1.6 + 0.5 * root.energy) * root.u; height: width; radius: width / 2
                        color: root.tone
                        opacity: 0.18 + 0.14 * Math.sin(root.ph * (1 + index % 2) + index * 1.7) + 0.25 * root.energy
                    }
                }
            }

            // near layer: lines, stars, lights; moves with the pointer
            Item {
                id: near
                width: parent.width; height: parent.height
                x: root.px * 9 * root.u
                y: root.py * 9 * root.u
                Behavior on x { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                Behavior on y { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }

                Shape {
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: Qt.alpha(root.tone, 0.07 + 0.10 * root.energy)
                        strokeWidth: 4 * root.u
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathSvg { path: root.edgePath }
                    }
                    ShapePath {
                        strokeColor: Qt.alpha(root.tone, 0.34 + 0.38 * root.energy)
                        strokeWidth: (1.0 + 0.5 * root.energy) * root.u
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathSvg { path: root.edgePath }
                    }
                }

                // lights travelling along the lines (alternate directions, staggered)
                Repeater {
                    model: root.live ? root.pulseEdges : []
                    delegate: Item {
                        id: pulse
                        required property var modelData
                        required property int index
                        readonly property var a: root.art.stars[modelData[0]]
                        readonly property var b: root.art.stars[modelData[1]]
                        readonly property real t0: ((root.cyc * (1 + index % 2) + index * 0.137) % 1)
                        readonly property real t: index % 2 === 0 ? t0 : 1 - t0
                        visible: a !== undefined && b !== undefined
                        x: a && b ? root.sx(a) + (root.sx(b) - root.sx(a)) * t : 0
                        y: a && b ? root.sy(a) + (root.sy(b) - root.sy(a)) * t : 0
                        opacity: Math.sin(3.1416 * t0) * (0.75 + 0.25 * root.energy)
                        Rectangle {
                            anchors.centerIn: parent
                            width: 7 * root.u; height: width; radius: width / 2
                            color: Qt.alpha(root.tone, 0.18)
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 2.2 * root.u; height: width; radius: width / 2
                            color: Qt.lighter(root.tone, 1.7)
                        }
                    }
                }

                // the stars: halo + core, each on its own flicker rhythm
                Repeater {
                    model: root.art ? root.art.stars : []
                    delegate: Item {
                        required property var modelData
                        required property int index
                        readonly property real r: modelData[2] || 1.5
                        readonly property real flick: 0.5 + 0.5 * Math.sin(root.ph * (1 + index % 3) + index * 0.9)
                        x: root.sx(modelData); y: root.sy(modelData)
                        visible: root.fadeIn(modelData) > 0
                        opacity: Math.min(1, 0.55 + 0.45 * flick * flick + 0.3 * root.energy) * root.fadeIn(modelData)
                        Rectangle {
                            anchors.centerIn: parent
                            width: r * (9 + 3 * flick + 9 * root.energy) * root.u; height: width; radius: width / 2
                            color: Qt.alpha(root.tone, 0.07 + 0.08 * root.energy)
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: r * (4.2 + 1.2 * flick + 2 * root.energy) * root.u; height: width; radius: width / 2
                            color: Qt.alpha(root.tone, 0.18)
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: r * 2 * root.u; height: width; radius: width / 2
                            color: Qt.lighter(root.tone, 1.5)
                        }
                    }
                }

                // a shooting star every 8-18 s
                Item {
                    id: shooter
                    property real prog: -1
                    property real x0: 0
                    property real y0: 0
                    property real dx: 70
                    property real dy: 30
                    visible: prog >= 0 && prog <= 1
                    x: x0 + dx * Math.max(0, prog)
                    y: y0 + dy * Math.max(0, prog)
                    opacity: Math.sin(3.1416 * Math.max(0, Math.min(1, prog))) * 0.9
                    function go() {
                        var ang = (0.15 + Math.random() * 0.5)            // shallow downward streak
                        var len = root.dw * (0.28 + Math.random() * 0.2)
                        x0 = Math.random() * root.dw * 0.6
                        y0 = Math.random() * root.dh * 0.5
                        dx = Math.cos(ang) * len; dy = Math.sin(ang) * len
                        streak.rotation = ang * 57.2958
                        prog = 0
                        shootAnim.restart()
                    }
                    Rectangle {
                        id: streak
                        width: 34 * root.u; height: 1.3 * root.u; radius: height / 2
                        x: -width; y: -height / 2
                        transformOrigin: Item.Right
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 1.0; color: Qt.lighter(root.tone, 1.8) }
                        }
                    }
                    NumberAnimation { id: shootAnim; target: shooter; property: "prog"; from: 0; to: 1; duration: 900; easing.type: Easing.OutQuad }
                }
            }
        }
    }

    Timer {
        id: shootT
        interval: 6000
        running: root.live
        repeat: true
        onTriggered: { interval = 8000 + Math.random() * 10000; shooter.go() }
    }
}
