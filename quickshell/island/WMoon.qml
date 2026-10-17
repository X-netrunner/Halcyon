import QtQuick
import QtQuick.Shapes

// "Moon phase": tonight's moon, worked out from the date (no internet, nothing to install).   disc | line | big
// The lit part is drawn from the sun's side: waxing = lit on the right in the north, turned round for the south.
WBase {
    id: root

    property date now: new Date()
    // (triggeredOnStart: the moon is worked out again the moment the widget is back on screen, not up to 10 minutes later)
    Timer { running: root.live; repeat: true; interval: 600000; triggeredOnStart: true; onTriggered: root.now = new Date() }

    readonly property real synodic: 29.530588853
    // days since a known new moon (6 Jan 2000, 18:14 UTC)
    readonly property real age: {
        var a = ((now.getTime() - Date.UTC(2000, 0, 6, 18, 14)) / 86400000) % synodic
        return a < 0 ? a + synodic : a
    }
    readonly property real ph: age / synodic                       // 0 new, 0.5 full
    readonly property real illum: (1 - Math.cos(2 * Math.PI * ph)) / 2
    readonly property bool waxing: ph < 0.5
    readonly property bool south: opt("south", false) === true
    readonly property string phaseName: {
        if (ph < 0.03 || ph >= 0.97) return "New moon"
        if (ph < 0.22) return "Waxing crescent"
        if (ph < 0.28) return "First quarter"
        if (ph < 0.47) return "Waxing gibbous"
        if (ph < 0.53) return "Full moon"
        if (ph < 0.72) return "Waning gibbous"
        if (ph < 0.78) return "Last quarter"
        return "Waning crescent"
    }
    readonly property int toFull: {
        var half = synodic / 2
        return Math.round(age < half ? half - age : synodic - age + half)
    }
    readonly property string fullText: toFull <= 0 ? "full tonight" : (toFull === 1 ? "full in 1 day" : "full in " + toFull + " days")
    readonly property bool showName: opt("label", true) === true
    readonly property bool showNext: opt("next", true) === true

    // the picture
    // the picture: drawn as vector paths (a Rectangle and an SVG path), not a Canvas, so it stays sharp at any widget size
    component Disc: Item {
        id: cv
        property real lp: root.ph
        property bool sth: root.south
        property color lc: root.fg
        property color gc: root.accent
        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property real r: Math.max(2, width / 2 - Math.max(3, width * 0.07))
        // the lit side: the limb, then the terminator back (a half ellipse); "" = new moon, nothing lit
        readonly property string lit: {
            var k = Math.cos(2 * Math.PI * lp)
            if (Math.abs(k) > 0.995 && k > 0) return ""
            var waxing = lp < 0.5
            var litRight = sth ? !waxing : waxing
            var s = litRight ? (k > 0 ? 1 : -1) : (k > 0 ? -1 : 1)
            var rx = Math.max(0.01, r * Math.abs(k))
            var f = function (v) { return v.toFixed(2) }
            // limb: top -> bottom on the lit side (clockwise on screen when it is the right side)
            // terminator: bottom -> top through x = cx + s * rx (counter-clockwise when it bulges to the right)
            return "M " + f(cx) + " " + f(cy - r) +
                   " A " + f(r) + " " + f(r) + " 0 0 " + (litRight ? 1 : 0) + " " + f(cx) + " " + f(cy + r) +
                   " A " + f(rx) + " " + f(r) + " 0 0 " + (s > 0 ? 0 : 1) + " " + f(cx) + " " + f(cy - r) + " Z"
        }
        // the dark side: a faint disc with a hairline edge
        Rectangle {
            x: cv.cx - cv.r; y: cv.cy - cv.r; width: cv.r * 2; height: width; radius: width / 2
            color: Qt.alpha(cv.lc, 0.09)
            border.width: 1; border.color: Qt.alpha(cv.lc, 0.22)
        }
        Shape {
            anchors.fill: parent
            visible: cv.lit !== ""
            layer.enabled: true
            layer.samples: 4
            layer.textureSize: Qt.size(Math.ceil(width * root.rs), Math.ceil(height * root.rs))
            ShapePath {
                strokeWidth: -1
                strokeColor: "transparent"
                fillColor: Qt.alpha(cv.lc, 0.96)
                PathSvg { path: cv.lit }
            }
        }
    }

    implicitWidth: body.item ? body.item.implicitWidth : 100
    implicitHeight: body.item ? body.item.implicitHeight : 100
    Loader { id: body; sourceComponent: root.style === "line" ? lineC : (root.style === "big" ? bigC : discC) }

    Component {
        id: discC
        Item {
            implicitWidth: Math.max(root.sz(110), col.implicitWidth)
            implicitHeight: col.implicitHeight
            WGlow { anchors.horizontalCenter: parent.horizontalCenter; y: -root.sz(14); width: root.sz(140); height: width; color: root.accent; strength: 0.16 * root.illum }
            Column {
                id: col
                width: parent.width
                spacing: root.sz(8)
                Disc { anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(96); height: width }
                WLbl { b: root; visible: root.showName; anchors.horizontalCenter: parent.horizontalCenter; text: root.phaseName.toUpperCase(); color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 2.4 }
                WLbl { b: root; visible: root.showNext; anchors.horizontalCenter: parent.horizontalCenter; text: Math.round(root.illum * 100) + " %  ·  " + root.fullText; color: root.dim; font.pixelSize: root.sz(11) }
            }
        }
    }
    Component {
        id: bigC
        Item {
            implicitWidth: Math.max(root.sz(190), col2.implicitWidth)
            implicitHeight: col2.implicitHeight
            WGlow { anchors.horizontalCenter: parent.horizontalCenter; y: -root.sz(24); width: root.sz(250); height: width; color: root.accent; strength: 0.18 * root.illum }
            Column {
                id: col2
                width: parent.width
                spacing: root.sz(12)
                Disc { anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(170); height: width }
                WLbl { b: root; visible: root.showName; anchors.horizontalCenter: parent.horizontalCenter; text: root.phaseName; font.pixelSize: root.sz(20); font.weight: Font.Light; font.letterSpacing: 1.5 }
                WLbl { b: root; visible: root.showNext; anchors.horizontalCenter: parent.horizontalCenter; text: Math.round(root.illum * 100) + " % lit  ·  " + root.fullText; color: root.dim; font.pixelSize: root.sz(12) }
            }
        }
    }
    Component {
        id: lineC
        Row {
            spacing: root.sz(10)
            Disc { width: root.sz(24); height: width; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; visible: root.showName; text: root.phaseName; font.pixelSize: root.sz(16); font.weight: Font.Light; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; visible: root.showNext; text: root.fullText; color: root.dim; font.pixelSize: root.sz(12); anchors.verticalCenter: parent.verticalCenter }
        }
    }
}
