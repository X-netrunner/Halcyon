import QtQuick

// A flower of thin petals, like the glowing ones on the wallpaper. Used by the Breathe widget (it opens and closes) and by the
// metric widgets' "Petals" style (the petals light up as the number grows).
//   open  0..1  how far the petals are open        lit  0..1  how many of them glow (the last one fades in smoothly)
Item {
    id: fl
    property var b: null
    property int count: 12
    property real open: 1
    property real lit: 1
    property color color: b ? b.accent : "white"
    property color base: b ? b.track : "#26ffffff"
    property bool glow: true
    readonly property real r: Math.min(width, height) / 2

    Repeater {
        model: fl.count
        delegate: Item {
            id: pt
            required property int index
            readonly property real fill: Math.max(0, Math.min(1, fl.lit * fl.count - index))
            readonly property real pw: Math.max(2, fl.r * (fl.count > 9 ? 0.15 : 0.22))
            readonly property real len: fl.r * 0.80 * (0.42 + 0.58 * fl.open)
            readonly property real inner: fl.r * 0.14
            x: fl.width / 2; y: fl.height / 2; width: 0; height: 0
            rotation: index * 360 / fl.count
            // the soft light around a lit petal
            Rectangle {
                visible: fl.glow && pt.fill > 0
                x: -pt.pw * 1.3; y: -(pt.inner + pt.len) - pt.pw * 0.7
                width: pt.pw * 2.6; height: pt.len + pt.pw * 1.4; radius: width / 2
                color: Qt.alpha(fl.color, 0.10 * pt.fill)
            }
            Rectangle {
                x: -pt.pw / 2; y: -(pt.inner + pt.len)
                width: pt.pw; height: pt.len; radius: width / 2
                color: fl.base
            }
            Rectangle {
                x: -pt.pw / 2; y: -(pt.inner + pt.len)
                width: pt.pw; height: pt.len; radius: width / 2
                color: fl.color
                opacity: pt.fill
            }
        }
    }
}
