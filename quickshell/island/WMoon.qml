import QtQuick

// "Moon phase": tonight's moon, worked out from the date (no internet, nothing to install).   disc | line | big
// The lit part is drawn from the sun's side: waxing = lit on the right in the north, turned round for the south.
WBase {
    id: root

    property date now: new Date()
    Timer { running: root.live; repeat: true; interval: 600000; onTriggered: root.now = new Date() }

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
    component Disc: Canvas {
        id: cv
        property real lp: root.ph
        property bool sth: root.south
        property color lc: root.fg
        property color gc: root.accent
        onLpChanged: requestPaint()
        onSthChanged: requestPaint()
        onLcChanged: requestPaint()
        onGcChanged: requestPaint()
        onWidthChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var cx = width / 2, cy = height / 2, r = Math.max(2, width / 2 - Math.max(3, width * 0.07))
            // the dark side: a faint disc with a hairline edge
            ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.closePath()
            ctx.fillStyle = Qt.alpha(cv.lc, 0.09); ctx.fill()
            ctx.lineWidth = 1; ctx.strokeStyle = Qt.alpha(cv.lc, 0.22); ctx.stroke()
            // the lit side: the limb, then the terminator back (a half ellipse)
            var k = Math.cos(2 * Math.PI * cv.lp)
            var waxing = cv.lp < 0.5
            var litRight = cv.sth ? !waxing : waxing
            if (Math.abs(k) > 0.995 && k > 0) return                      // new moon: nothing lit
            var s = litRight ? (k > 0 ? 1 : -1) : (k > 0 ? -1 : 1)
            var rx = r * Math.abs(k)
            ctx.beginPath()
            ctx.arc(cx, cy, r, -Math.PI / 2, Math.PI / 2, !litRight)
            var n = 40
            for (var i = 0; i <= n; i++) {
                var t = Math.PI / 2 - Math.PI * i / n
                ctx.lineTo(cx + s * rx * Math.cos(t), cy + r * Math.sin(t))
            }
            ctx.closePath()
            ctx.fillStyle = Qt.alpha(cv.lc, 0.96)
            ctx.fill()
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
