import QtQuick

// A few tiny stars drifting slowly along the bar: the constellation theme, kept light on purpose.
// One 15 fps timer moves every star (they stand still, and the timer stops, whenever the bar is hidden, a page is open,
// or the motion setting is nearly off, e.g. Gaming mode). Position and twinkle both loop exactly once per `loopMs`,
// so there is no jump when the clock wraps. Give it the area to fly in (x / y / width / height) and it clips to it.
Item {
    id: root
    property var pal
    opacity: pal ? pal.decor : 1          // the calm interface keeps the moving stars, softly (Pal.decor)
    property bool active: true
    property int count: 7
    property int loopMs: 90000
    property real sizeScale: 1
    clip: true

    readonly property bool live: active && visible && width > 0 && (pal ? pal.motion > 0.3 : true)
    property real t: 0
    Timer {
        interval: Math.round(66 * (root.pal ? root.pal.starSlow : 1))
        repeat: true
        running: root.live
        onTriggered: root.t = (root.t + interval / root.loopMs) % 1
    }

    Repeater {
        model: root.live ? root.count : 0
        delegate: Item {
            id: st
            required property int index
            readonly property real fx: (index * 0.6180339 + 0.11) % 1
            readonly property real fy: (index * 0.4142135 + 0.23) % 1
            readonly property int dir: index % 3 === 1 ? -1 : 1               // most fly one way, a few the other
            readonly property int speed: 1 + index % 3                         // 1..3 widths per loop
            readonly property int blink: 5 + (index * 7) % 8                   // twinkles per loop
            readonly property real size: (1.5 + (index % 4) * 0.5) * root.sizeScale
            readonly property real px: (((fx + dir * root.t * speed) % 1) + 1) % 1
            readonly property real edge: Math.min(1, Math.min(px, 1 - px) * root.width / 26)   // fade in / out at the two ends
            readonly property real tw: 0.5 + 0.5 * Math.sin(6.2832 * (root.t * blink + fx * 3))
            readonly property color tone: index % 2 === 0 ? root.pal.accent : root.pal.accent2

            x: px * root.width
            y: 2 + fy * Math.max(0, root.height - 4) + 1.2 * Math.sin(6.2832 * (root.t * 2 + fx))
            opacity: edge * (0.30 + 0.70 * tw)

            // a short fading tail behind the ones that fly right, so they read as flying
            Rectangle {
                visible: st.dir > 0 && st.index % 2 === 0
                anchors.right: dot.horizontalCenter
                anchors.verticalCenter: dot.verticalCenter
                width: 9 * root.sizeScale; height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.alpha(st.tone, 0.45) }
                }
            }
            Rectangle {
                id: dot
                width: st.size; height: st.size; radius: st.size / 2
                color: root.pal.solid ? Qt.lighter(st.tone, 1.25) : st.tone
            }
        }
    }
}
