import QtQuick

// "Horizon": a hairline with a glowing dot that walks along it as the day goes by, and its quiet reflection in the water below
// (the wallpaper's own picture).   horizon | dual (day and year) | quiet
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
    Loader { id: body; sourceComponent: root.style === "dual" ? dualC : (root.style === "quiet" ? quietC : horC) }

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
}
