import QtQuick
import QtQuick.Shapes

// One round status icon for Wi-Fi + battery + Bluetooth (Settings > Bar style > "Combined status icon"),
// shared by the island and the notch:
//
//        .-""""-.         centre      Wi-Fi: a dot with three arcs, lit by the signal strength (net.signal).
//      .'  .--.  '.                   A cable shows a plug instead.
//     |   (  o  )   |     outer ring  Battery: a horseshoe, open at the bottom. It fills clockwise from the
//      '.  '--'  .'                   bottom-left and is red when low, green while charging.
//        '. . .'          bottom dots Bluetooth: up to three dots that close the gap of the ring. One lit dot
//                                     per connected device (net.btn); dim dots show Bluetooth is on.
//
// It sits on a soft round backdrop. Everything scales with `size`.
Item {
    id: root

    property var pal
    property var net: ({})
    property var stats: ({})
    property color tint: pal.accent          // lit parts (Wi-Fi, ring, dots)
    property color btTint: tint              // lit Bluetooth dots
    property int size: 26                    // diameter of the round icon in px

    property bool showWifi: true
    property bool showBat: true
    property string btMode: "connected"      // off | connected (only while a device is connected) | on (whenever Bluetooth is on)
    property bool backdrop: true

    // optional battery percentage to the right of the circle
    property bool showPct: false
    property color textColor: pal.text
    property string textFont: pal.uiFont
    property int textPx: 12

    // ---- state
    readonly property bool wired: net.eth === true
    readonly property bool up: net.wifi === "on" && (net.ssid || "") !== ""
    readonly property real sig: Number(net.signal || 0)
    // 0..4 like WifiIcon: 1 = the dot only, 4 = the dot and all three arcs. Connected without a reading = all lit
    readonly property int lit: !up ? 0 : (sig <= 0 ? 4 : (sig >= 75 ? 4 : (sig >= 50 ? 3 : (sig >= 25 ? 2 : 1))))

    readonly property bool hasBat: showBat && stats.hasBat === true
    readonly property real pct: Math.max(0, Math.min(100, Number(stats.bat || 0))) / 100
    property real shownPct: pct
    Behavior on shownPct { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
    readonly property color batCol: stats.charging ? pal.good : (Number(stats.bat || 0) <= 20 ? pal.bad : tint)

    readonly property bool btOn: net.bt === "on"
    readonly property int btCount: Math.max(Number(net.btn || 0), (net.btdev || "") !== "" ? 1 : 0)
    readonly property bool dotsShown: btOn && btMode !== "off" && (btMode === "on" || btCount > 0)
    readonly property int dotsLit: Math.min(3, btCount)
    // "Always": three slots (dim until a device connects). "When connected": only the lit dots, centred on the bottom
    readonly property int dotSlots: btMode === "on" ? 3 : dotsLit

    // nothing to show at all (no Wi-Fi, no battery, no Bluetooth): the owner hides the whole icon
    readonly property bool any: showWifi || hasBat || dotsShown
    readonly property bool pctShown: showPct && hasBat

    // ---- geometry (all derived from size)
    readonly property real stroke: Math.max(2, Math.round(size * 0.085))     // ring thickness
    readonly property real cx: size / 2
    readonly property real cy: size / 2
    readonly property real ringR: size / 2 - stroke / 2 - 0.5                // radius of the ring's centre line
    readonly property real gapHalf: 38                                       // degrees of ring left open at the bottom (each side of 6 o'clock)
    readonly property real ringStart: 90 + gapHalf                           // bottom-left; angles run clockwise, 0 = 3 o'clock
    readonly property real ringSweep: 360 - 2 * gapHalf

    readonly property real wR: ringR * 0.66                                  // radius of the biggest Wi-Fi arc
    readonly property real wStroke: Math.max(1.2, stroke * 0.72)
    readonly property real wDot: Math.max(1.2, wStroke * 0.85)               // radius of the Wi-Fi dot
    // the Wi-Fi glyph (dot + arcs) is centred vertically in the circle
    readonly property real wPivotY: cy + (wR + wStroke / 2 - wDot) / 2

    readonly property real dotD: Math.max(2.4, stroke * 1.15)                // Bluetooth dot diameter
    readonly property real dotStep: 19                                       // degrees between Bluetooth dots

    implicitWidth: size + (pctShown ? pctText.implicitWidth + Math.round(size * 0.2) : 0)
    implicitHeight: size

    // soft muted disc behind everything
    Rectangle {
        visible: root.backdrop
        width: root.size
        height: root.size
        radius: width / 2
        color: Qt.alpha(root.tint, 0.11)
    }

    Shape {
        id: shape
        width: root.size
        height: root.size
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer

        // battery ring: track, then the level on top
        ShapePath {
            strokeColor: Qt.alpha(root.tint, root.hasBat ? 0.22 : 0.16)
            strokeWidth: root.stroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.cx; centerY: root.cy
                radiusX: root.ringR; radiusY: root.ringR
                startAngle: root.ringStart
                sweepAngle: root.ringSweep
            }
        }
        ShapePath {
            strokeColor: root.batCol
            strokeWidth: root.stroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.cx; centerY: root.cy
                radiusX: root.ringR; radiusY: root.ringR
                startAngle: root.ringStart
                sweepAngle: root.hasBat ? Math.max(0.5, root.ringSweep * root.shownPct) : 0
            }
        }

        // Wi-Fi arcs (the dot is a Rectangle below); a cable replaces them with the plug glyph
        ShapePath {
            strokeColor: root.lit >= 2 ? root.tint : Qt.alpha(root.tint, 0.28)
            strokeWidth: root.wStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: root.cx; centerY: root.wPivotY; radiusX: root.wR * 0.40; radiusY: root.wR * 0.40; startAngle: -135; sweepAngle: root.showWifi && !root.wired ? 90 : 0 }
        }
        ShapePath {
            strokeColor: root.lit >= 3 ? root.tint : Qt.alpha(root.tint, 0.28)
            strokeWidth: root.wStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: root.cx; centerY: root.wPivotY; radiusX: root.wR * 0.70; radiusY: root.wR * 0.70; startAngle: -135; sweepAngle: root.showWifi && !root.wired ? 90 : 0 }
        }
        ShapePath {
            strokeColor: root.lit >= 4 ? root.tint : Qt.alpha(root.tint, 0.28)
            strokeWidth: root.wStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: root.cx; centerY: root.wPivotY; radiusX: root.wR; radiusY: root.wR; startAngle: -135; sweepAngle: root.showWifi && !root.wired ? 90 : 0 }
        }
    }

    // Wi-Fi dot
    Rectangle {
        visible: root.showWifi && !root.wired
        x: root.cx - root.wDot
        y: root.wPivotY - root.wDot
        width: root.wDot * 2
        height: root.wDot * 2
        radius: root.wDot
        antialiasing: true
        color: root.lit >= 1 ? root.tint : Qt.alpha(root.tint, 0.28)
    }
    // cable
    Text {
        visible: root.showWifi && root.wired
        anchors.centerIn: parent
        text: String.fromCodePoint(0xF0200)
        color: root.tint
        font.family: root.pal.font
        font.pixelSize: Math.round(root.size * 0.5)
    }

    // Bluetooth dots on the ring, closing its gap: left to right, one lit per connected device (up to 3).
    // Angles run clockwise, so the left dot has the bigger angle.
    Repeater {
        model: root.dotsShown ? root.dotSlots : 0
        delegate: Rectangle {
            required property int index
            readonly property real ang: (90 - (index - (root.dotSlots - 1) / 2) * root.dotStep) * Math.PI / 180
            readonly property bool on: index < root.dotsLit
            x: root.cx + root.ringR * Math.cos(ang) - root.dotD / 2
            y: root.cy + root.ringR * Math.sin(ang) - root.dotD / 2
            width: root.dotD
            height: root.dotD
            radius: root.dotD / 2
            antialiasing: true
            color: on ? root.btTint : Qt.alpha(root.btTint, 0.32)
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }

    Text {
        id: pctText
        visible: root.pctShown
        x: root.size + Math.round(root.size * 0.2)
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(Number(root.stats.bat || 0)) + "%"
        color: root.textColor
        font.family: root.textFont
        font.pixelSize: root.textPx
        font.weight: Font.Medium
    }
}
