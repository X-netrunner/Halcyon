import QtQuick
import QtQuick.Shapes

// "Audio visualizer": the music as bars, a mirror, a wave, dots or a circle. Reads the desktop's own cava feed (48 bars at 30 / 15 fps, only
// started while this widget is on the desktop and something plays); the number of bars you pick is cut from it.
//   bars | mirror | wave | dots | circle
WBase {
    id: root

    readonly property bool playing: env ? env.playing === true : false
    readonly property var feed: (env && env.cavaDesk) ? env.cavaDesk : []
    readonly property int n: Math.round(opt("count", 24))
    readonly property real wide: opt("width", 280)
    // the width the bars are laid out in: its own, or the wider one a link gives it (the frame sets this item's width)
    readonly property real lw: Math.max(wide, width)
    readonly property real tall: opt("height", 90)
    hidden: !playing && opt("idle", "dots") === "hide"

    // the n values (0..1) cut from the feed; nothing playing = all zero, so the bars rest as dots
    readonly property var vals: {
        var a = feed, L = a.length, out = []
        for (var i = 0; i < n; i++) {
            if (!playing || L === 0) { out.push(0); continue }
            var pos = n > 1 ? i * (L - 1) / (n - 1) : 0, i0 = Math.floor(pos), i1 = Math.min(L - 1, i0 + 1), f = pos - i0
            out.push(Math.max(0, Math.min(1, ((a[i0] || 0) * (1 - f) + (a[i1] || 0) * f) / 100)))
        }
        return out
    }
    function tone(v) { return Qt.alpha(accent, 0.45 + 0.55 * v) }

    implicitWidth: style === "circle" ? Math.min(wide, tall * 1.6) : wide
    implicitHeight: tall

    Loader {
        anchors.fill: parent
        sourceComponent: root.style === "mirror" ? mirrorC : (root.style === "wave" ? waveC : (root.style === "dots" ? dotsC : (root.style === "circle" ? circleC : barsC)))
    }

    Component {
        id: barsC
        Row {
            spacing: Math.max(1, Math.round(root.lw / root.n * 0.28))
            Repeater {
                model: root.n
                delegate: Item {
                    required property int index
                    readonly property real v: root.vals[index] || 0
                    width: (root.lw - (root.n - 1) * Math.max(1, Math.round(root.lw / root.n * 0.28))) / root.n
                    height: root.tall
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: Math.max(width, parent.v * parent.height); radius: Math.min(width / 2, 4)
                        color: root.playing ? root.tone(parent.v) : root.track
                        Behavior on height { NumberAnimation { duration: 70 } }
                    }
                }
            }
        }
    }
    Component {
        id: mirrorC
        Row {
            spacing: Math.max(1, Math.round(root.lw / root.n * 0.28))
            Repeater {
                model: root.n
                delegate: Item {
                    required property int index
                    readonly property real v: root.vals[index] || 0
                    width: (root.lw - (root.n - 1) * Math.max(1, Math.round(root.lw / root.n * 0.28))) / root.n
                    height: root.tall
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width; height: Math.max(width, parent.v * parent.height); radius: Math.min(width / 2, 4)
                        color: root.playing ? root.tone(parent.v) : root.track
                        Behavior on height { NumberAnimation { duration: 70 } }
                    }
                }
            }
        }
    }
    Component {
        id: dotsC
        Row {
            spacing: Math.max(1, Math.round(root.lw / root.n * 0.28))
            Repeater {
                model: root.n
                delegate: Item {
                    required property int index
                    readonly property real v: root.vals[index] || 0
                    readonly property real d: Math.max(4, Math.min(width, 14))
                    width: (root.lw - (root.n - 1) * Math.max(1, Math.round(root.lw / root.n * 0.28))) / root.n
                    height: root.tall
                    Rectangle {
                        width: parent.d; height: width; radius: width / 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: (parent.height - height) * (1 - parent.v)
                        color: root.playing ? root.tone(parent.v) : root.track
                        Behavior on y { NumberAnimation { duration: 70 } }
                    }
                }
            }
        }
    }
    Component {
        id: waveC
        Shape {
            id: sh
            layer.enabled: true
            layer.samples: 4
            readonly property string d: {
                var w = root.lw, h = root.tall, n = root.n, s = ""
                for (var i = 0; i < n; i++) {
                    var x = n > 1 ? i * w / (n - 1) : 0, y = h - 3 - (root.vals[i] || 0) * (h - 6)
                    s += (i === 0 ? "M " : " L ") + x.toFixed(1) + " " + y.toFixed(1)
                }
                return s
            }
            ShapePath {
                strokeColor: root.playing ? root.accent : root.track
                strokeWidth: 3
                fillColor: Qt.alpha(root.accent, root.playing ? 0.16 : 0.0)
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                PathSvg { path: sh.d + " L " + root.lw + " " + root.tall + " L 0 " + root.tall + " Z" }
            }
        }
    }
    Component {
        id: circleC
        Item {
            id: cc
            readonly property real r0: Math.min(width, height) * 0.26
            readonly property real maxLen: Math.min(width, height) * 0.24
            Repeater {
                model: root.n
                delegate: Item {
                    required property int index
                    readonly property real v: root.vals[index] || 0
                    x: cc.width / 2; y: cc.height / 2; width: 0; height: 0
                    rotation: index * 360 / root.n
                    Rectangle {
                        width: Math.max(2, 2 * Math.PI * cc.r0 / root.n * 0.55)
                        height: Math.max(3, parent.v * cc.maxLen)
                        x: -width / 2; y: -(cc.r0 + height)
                        radius: width / 2
                        color: root.playing ? root.tone(parent.v) : root.track
                        Behavior on height { NumberAnimation { duration: 70 } }
                    }
                }
            }
        }
    }
}
