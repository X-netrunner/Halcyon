import QtQuick
import QtQuick.Shapes

// "Focus timer & streak": the running Focus session (scripts/focus.sh) and how many days in a row you focused at least N minutes.
// The minutes are counted by the island itself, a minute at a time while a work phase runs (shell.qml, ~/.local/state/island/focus-days.json),
// so the streak is right even before this widget was added.
//   ring | card | compact | streak
WBase {
    id: root

    readonly property var fst: env && env.focusState ? env.focusState : ({ on: false })
    readonly property bool on: fst.on === true
    readonly property bool paused: on && fst.paused === true
    readonly property string phase: on ? (fst.phase || "work") : ""
    readonly property string left: env ? env.focusText : "00:00"
    readonly property real frac: (on && fst.total > 0 && env) ? Math.max(0, Math.min(1, 1 - env.focusLeft / fst.total)) : 0
    readonly property string phaseName: !on ? "Ready" : (paused ? "Paused" : (phase === "work" ? "Focus" : (phase === "long" ? "Long break" : "Break")))
    readonly property bool showStreak: opt("streak", true) === true
    readonly property bool showBtn: opt("buttons", true) === true
    readonly property bool showWeek: opt("week", true) === true

    // ---- the streak
    property date today: new Date()
    Timer { running: root.live; repeat: true; interval: 60000; onTriggered: root.today = new Date() }
    readonly property var days: env && env.focusDays ? env.focusDays : ({})
    readonly property int goal: Math.round(opt("goal", 25))
    function key(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    function minutesOn(d) { return days[key(d)] || 0 }
    readonly property int todayMin: { var t = today; return days[key(t)] || 0 }
    readonly property int streak: {
        var n = 0, d = new Date(today)
        if ((days[key(d)] || 0) < goal) d.setDate(d.getDate() - 1)      // today is still to be earned: the streak stands until the day ends
        for (var i = 0; i < 4000; i++) {
            if ((days[key(d)] || 0) >= goal) { n++; d.setDate(d.getDate() - 1) } else break
        }
        return n
    }
    readonly property var week: {
        var out = []
        for (var i = 6; i >= 0; i--) {
            var d = new Date(today); d.setDate(d.getDate() - i)
            out.push({ day: Qt.formatDate(d, "ddd").charAt(0), m: days[key(d)] || 0, today: i === 0 })
        }
        return out
    }
    readonly property color flame: (todayMin >= goal || streak === 0) ? accent : (pal ? pal.warn : accent)

    function toggle() { if (env) env.focusToggle() }
    function pauseToggle() { if (env) env.focusRun([paused ? "resume" : "pause"]) }

    implicitWidth: body.item ? body.item.implicitWidth : 200
    implicitHeight: body.item ? body.item.implicitHeight : 100
    Loader {
        id: body
        sourceComponent: root.style === "card" ? cardC : (root.style === "compact" ? compactC : (root.style === "streak" ? streakC : ringC))
    }

    // a small row of the last 7 days
    Component {
        id: weekC
        Row {
            spacing: root.sz(8)
            Repeater {
                model: root.week
                delegate: Column {
                    required property var modelData
                    spacing: root.sz(3)
                    Rectangle {
                        width: root.sz(16); height: width; radius: width / 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: modelData.m >= root.goal ? root.accent : (modelData.m > 0 ? Qt.alpha(root.accent, 0.35) : root.track)
                        border.width: modelData.today ? 2 : 0
                        border.color: root.fg
                    }
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: modelData.day; color: root.dim; font.pixelSize: root.sz(10) }
                }
            }
        }
    }
    // start / stop (and pause while a session runs)
    Component {
        id: btnC
        Row {
            spacing: root.sz(8)
            Rectangle {
                width: sTxt.implicitWidth + root.sz(28); height: root.sz(30); radius: height / 2
                color: root.on ? Qt.alpha(root.accent, 0.2) : root.accent
                border.width: root.on ? 1 : 0; border.color: root.accent
                WLbl { id: sTxt; b: root; anchors.centerIn: parent; text: root.on ? "Stop" : "Start focus"; color: root.on ? root.fg : (root.pal ? root.pal.bg : "black"); font.pixelSize: root.sz(13); font.weight: Font.DemiBold }
                MouseArea { anchors.fill: parent; enabled: !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: root.toggle() }
            }
            Rectangle {
                visible: root.on
                width: pTxt.implicitWidth + root.sz(24); height: root.sz(30); radius: height / 2
                color: "transparent"; border.width: 1; border.color: root.track
                WLbl { id: pTxt; b: root; anchors.centerIn: parent; text: root.paused ? "Resume" : "Pause"; color: root.dim; font.pixelSize: root.sz(13) }
                MouseArea { anchors.fill: parent; enabled: !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: root.pauseToggle() }
            }
        }
    }

    // ---- ring
    Component {
        id: ringC
        Column {
            spacing: root.sz(10)
            Item {
                id: rg
                width: root.sz(124); height: width
                anchors.horizontalCenter: parent.horizontalCenter
                Shape {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 4
                    ShapePath { strokeColor: root.track; strokeWidth: root.sz(8); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: rg.width / 2; centerY: rg.height / 2; radiusX: rg.width / 2 - root.sz(6); radiusY: rg.height / 2 - root.sz(6); startAngle: -90; sweepAngle: 359.9 } }
                    ShapePath { strokeColor: root.phase === "work" || !root.on ? root.accent : (root.pal ? root.pal.good : root.accent); strokeWidth: root.sz(8); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: rg.width / 2; centerY: rg.height / 2; radiusX: rg.width / 2 - root.sz(6); radiusY: rg.height / 2 - root.sz(6); startAngle: -90; sweepAngle: 359.9 * Math.max(0.004, root.frac) } }
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 0
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.on ? root.left : root.goal + " min"; font.pixelSize: root.sz(root.on ? 26 : 20); font.weight: Font.DemiBold }
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.phaseName.toUpperCase(); color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 1.4 }
                }
            }
            Row {
                visible: root.showStreak
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.sz(6)
                WIco { b: root; text: root.glyph(0xF0238); color: root.flame; font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.streak + " day streak"; font.pixelSize: root.sz(14); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
            }
            Loader { visible: root.showWeek; anchors.horizontalCenter: parent.horizontalCenter; sourceComponent: weekC }
            Loader { visible: root.showBtn; anchors.horizontalCenter: parent.horizontalCenter; sourceComponent: btnC }
        }
    }
    // ---- card
    Component {
        id: cardC
        Column {
            spacing: root.sz(12)
            Row {
                spacing: root.sz(22)
                Column {
                    spacing: 0
                    WLbl { b: root; text: root.phaseName.toUpperCase(); color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
                    WLbl { b: root; text: root.on ? root.left : root.goal + ":00"; font.pixelSize: root.sz(48); font.weight: Font.Light }
                    Rectangle { width: root.sz(150); height: root.sz(4); radius: 2; color: root.track
                        Rectangle { width: parent.width * root.frac; height: parent.height; radius: 2; color: root.accent } }
                }
                Column {
                    visible: root.showStreak
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0
                    WIco { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.glyph(0xF0238); color: root.flame; font.pixelSize: root.sz(26) }
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.streak; font.pixelSize: root.sz(28); font.weight: Font.DemiBold }
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: "DAYS"; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 1.4 }
                }
            }
            Loader { visible: root.showWeek; sourceComponent: weekC }
            Loader { visible: root.showBtn; sourceComponent: btnC }
        }
    }
    // ---- compact
    Component {
        id: compactC
        Row {
            spacing: root.sz(10)
            WIco { b: root; text: root.glyph(0xF051B); color: root.on ? root.accent : root.dim; font.pixelSize: root.sz(20); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.on ? root.left : "Focus"; font.pixelSize: root.sz(20); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            Rectangle { visible: root.showStreak; width: 1; height: root.sz(20); color: root.track; anchors.verticalCenter: parent.verticalCenter }
            Row {
                visible: root.showStreak
                spacing: root.sz(4)
                anchors.verticalCenter: parent.verticalCenter
                WIco { b: root; text: root.glyph(0xF0238); color: root.flame; font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.streak; font.pixelSize: root.sz(18); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            }
            MouseArea { anchors.fill: parent; enabled: root.showBtn && !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: root.toggle() }
        }
    }
    // ---- streak
    Component {
        id: streakC
        Column {
            spacing: root.sz(6)
            Row {
                spacing: root.sz(10)
                anchors.horizontalCenter: parent.horizontalCenter
                WIco { b: root; text: root.glyph(0xF0238); color: root.flame; font.pixelSize: root.sz(48); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.streak; font.pixelSize: root.sz(72); font.weight: Font.Light; anchors.verticalCenter: parent.verticalCenter }
            }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.streak === 1 ? "DAY IN A ROW" : "DAYS IN A ROW"; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 2 }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.todayMin + " / " + root.goal + " min today"; color: root.todayMin >= root.goal ? root.accent : root.dim; font.pixelSize: root.sz(12) }
            Loader { visible: root.showWeek; anchors.horizontalCenter: parent.horizontalCenter; sourceComponent: weekC }
            Loader { visible: root.showBtn; anchors.horizontalCenter: parent.horizontalCenter; sourceComponent: btnC }
        }
    }
}
