import QtQuick

// "Horizon": a hairline with a glowing dot that walks along it as the day goes by, and its quiet reflection in the water below
// (the wallpaper's own picture).   horizon | dual (day and year) | quiet | arc (a half circle, like the sun's path) | ticks (24 hours)
WBase {
    id: root

    property date now: new Date()
    onLiveChanged: if (live) now = new Date()          // the dot was up to 30 s behind after the widget came back on screen
    Timer { running: root.live; repeat: true; interval: 30000; onTriggered: root.now = new Date() }

    readonly property real dayFrac: (now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds()) / 86400
    readonly property real yearFrac: {
        var y = now.getFullYear()
        var a = new Date(y, 0, 1), b = new Date(y + 1, 0, 1)
        return Math.max(0, Math.min(1, (now.getTime() - a.getTime()) / (b.getTime() - a.getTime())))
    }
    readonly property real wide: Math.round(sz(Number(opt("width", 300))))
    readonly property bool reflect: opt("reflect", true) === true
    readonly property bool pct: opt("percent", true) === true

    property real shownDay: dayFrac
    property real shownYear: yearFrac
    Behavior on shownDay { NumberAnimation { duration: 800; easing.type: Easing.OutCubic } }
    Behavior on shownYear { NumberAnimation { duration: 800; easing.type: Easing.OutCubic } }

    // one hairline: frac 0..1, with its dot and (optionally) the reflection under it
    component HLine: Item {
        id: ln
        property real frac: 0
        property bool mirror: true
        width: root.wide
        height: root.sz(mirror ? 30 : 16)
        readonly property real mid: root.sz(8)
        readonly property real px: Math.max(0, Math.min(width, width * frac))
        // the line, lit up to the dot
        Rectangle { y: ln.mid; width: ln.width; height: 1; color: root.track }
        Rectangle { y: ln.mid - 0.25; width: Math.max(1, ln.px); height: 1.5; color: Qt.alpha(root.fg, 0.55) }
        // the dot and its light
        WGlow { x: ln.px - width / 2; y: ln.mid - height / 2; width: root.sz(46); height: width; color: root.accent; strength: 0.30 }
        Rectangle { x: ln.px - width / 2; y: ln.mid - height / 2; width: root.sz(7); height: width; radius: width / 2; color: root.accent }
        // the water: the same line and dot, dimmer, with a few ripples
        Rectangle { visible: ln.mirror; y: ln.mid + root.sz(9); width: ln.width; height: 1; color: Qt.alpha(root.track, 0.5) }
        Rectangle { visible: ln.mirror; y: ln.mid + root.sz(9); width: Math.max(1, ln.px); height: 1; color: Qt.alpha(root.fg, 0.14) }
        Rectangle { visible: ln.mirror; x: ln.px - width / 2; y: ln.mid + root.sz(9) - height / 2; width: root.sz(7); height: width * 0.55; radius: height / 2; color: Qt.alpha(root.accent, 0.28) }
        Rectangle { visible: ln.mirror; x: ln.px - width / 2; y: ln.mid + root.sz(15); width: root.sz(26); height: 1; color: Qt.alpha(root.fg, 0.10) }
        Rectangle { visible: ln.mirror; x: ln.px - width / 2; y: ln.mid + root.sz(20); width: root.sz(14); height: 1; color: Qt.alpha(root.fg, 0.06) }
    }

    implicitWidth: body.item ? body.item.implicitWidth : root.wide
    implicitHeight: body.item ? body.item.implicitHeight : 40
    Loader { id: body; sourceComponent: root.style === "dual" ? dualC : (root.style === "quiet" ? quietC : (root.style === "arc" ? arcC : (root.style === "ticks" ? ticksC : horC))) }

    Component {
        id: horC
        Column {
            spacing: root.sz(6)
            Row {
                visible: root.pct
                width: root.wide
                WLbl { b: root; width: parent.width / 2; text: "TODAY"; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3 }
                WLbl { b: root; width: parent.width / 2; horizontalAlignment: Text.AlignRight; text: Math.round(root.dayFrac * 100) + " %"; font.pixelSize: root.sz(14); font.weight: Font.Light }
            }
            HLine { frac: root.shownDay; mirror: root.reflect }
        }
    }
    Component {
        id: dualC
        Column {
            spacing: root.sz(10)
            Column {
                spacing: root.sz(4)
                Row {
                    width: root.wide
                    WLbl { b: root; width: parent.width / 2; text: "TODAY"; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3 }
                    WLbl { b: root; visible: root.pct; width: parent.width / 2; horizontalAlignment: Text.AlignRight; text: Math.round(root.dayFrac * 100) + " %"; font.pixelSize: root.sz(13); font.weight: Font.Light }
                }
                HLine { frac: root.shownDay; mirror: false }
            }
            Column {
                spacing: root.sz(4)
                Row {
                    width: root.wide
                    WLbl { b: root; width: parent.width / 2; text: String(root.now.getFullYear()); color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3 }
                    WLbl { b: root; visible: root.pct; width: parent.width / 2; horizontalAlignment: Text.AlignRight; text: Math.round(root.yearFrac * 100) + " %"; font.pixelSize: root.sz(13); font.weight: Font.Light }
                }
                HLine { frac: root.shownYear; mirror: root.reflect }
            }
        }
    }
    Component {
        id: quietC
        HLine { frac: root.shownDay; mirror: false }
    }
    // arc: a half circle of small dots from sunrise side to sunset side, the lit dot is where the day is now
    Component {
        id: arcC
        Item {
            id: arc
            readonly property real r: root.wide / 2 - root.sz(8)
            readonly property real cy: r + root.sz(10)
            readonly property int steps: 24
            implicitWidth: root.wide
            implicitHeight: cy + root.sz(root.pct ? 30 : 14)
            // the dotted path
            Repeater {
                model: arc.steps + 1
                delegate: Rectangle {
                    required property int index
                    readonly property real a: Math.PI * index / arc.steps
                    readonly property bool passed: index / arc.steps <= root.shownDay
                    width: root.sz(passed ? 3 : 2); height: width; radius: width / 2
                    x: arc.width / 2 - arc.r * Math.cos(a) - width / 2
                    y: arc.cy - arc.r * Math.sin(a) - height / 2
                    color: passed ? Qt.alpha(root.fg, 0.6) : Qt.alpha(root.track, 0.9)
                }
            }
            // the ground
            Rectangle { x: arc.width / 2 - arc.r - root.sz(8); y: arc.cy + root.sz(4); width: arc.r * 2 + root.sz(16); height: 1; color: root.track }
            // the sun
            WGlow { x: sun.x + sun.width / 2 - width / 2; y: sun.y + sun.height / 2 - height / 2; width: root.sz(52); height: width; color: root.accent; strength: 0.30 }
            Rectangle {
                id: sun
                width: root.sz(9); height: width; radius: width / 2
                x: arc.width / 2 - arc.r * Math.cos(Math.PI * root.shownDay) - width / 2
                y: arc.cy - arc.r * Math.sin(Math.PI * root.shownDay) - height / 2
                color: root.accent
            }
            WLbl {
                visible: root.pct
                b: root
                anchors.horizontalCenter: parent.horizontalCenter
                y: arc.cy + root.sz(10)
                text: Math.round(root.dayFrac * 100) + " %"
                font.pixelSize: root.sz(14); font.weight: Font.Light
            }
        }
    }
    // ticks: one tick for every hour of the day, lit up to now, the current hour taller and in the accent colour
    Component {
        id: ticksC
        Column {
            spacing: root.sz(8)
            Item {
                id: tk
                width: root.wide; height: root.sz(26)
                readonly property real tw: root.sz(2)
                readonly property real step: (width - tw) / 23
                readonly property int hour: Math.min(23, Math.floor(root.shownDay * 24))
                Repeater {
                    model: 24
                    delegate: Rectangle {
                        required property int index
                        readonly property bool now: index === tk.hour
                        width: tk.tw; radius: width / 2
                        height: root.sz(now ? 26 : (index % 6 === 0 ? 18 : 12))
                        x: index * tk.step
                        y: tk.height - height
                        color: now ? root.accent : (index < tk.hour ? Qt.alpha(root.fg, 0.55) : root.track)
                    }
                }
            }
            Row {
                visible: root.pct
                width: root.wide
                WLbl { b: root; width: parent.width / 2; text: "TODAY"; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3 }
                WLbl { b: root; width: parent.width / 2; horizontalAlignment: Text.AlignRight; text: Math.round(root.dayFrac * 100) + " %"; font.pixelSize: root.sz(13); font.weight: Font.Light }
            }
        }
    }
}
