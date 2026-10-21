import QtQuick

// "Focus streak graph": the same graph as Settings > Desktop > Focus mode (the rail with your streak and your best), as a desktop
// widget, plus a 14-day bar graph. It only READS the minutes the island already counts (shell.qml, ~/.local/state/island/focus-days.json,
// scripts/focus-log.sh), so it shows your real history from the first moment. A click opens the Focus streak view (FocusStreak.qml),
// where a session can be started.   rail | bars
WBase {
    id: root

    readonly property var days: env && env.focusDays ? env.focusDays : ({})
    readonly property int goal: Math.round(opt("goal", 25))
    readonly property bool showDetail: opt("detail", true) === true
    readonly property bool tracked: { for (var k in days) return true; return false }

    // ---- today (worked out again only when the day changes)
    property date today: new Date()
    function checkDay() { var n = new Date(); if (key(n) !== key(today)) today = n }
    onLiveChanged: if (live) checkDay()
    Timer { running: root.live; repeat: true; interval: 60000; onTriggered: root.checkDay() }
    function key(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    function minutesOn(d) { return days[key(d)] || 0 }
    readonly property int todayMin: { var t = today; return days[key(t)] || 0 }

    // ---- the current streak (today is still to be earned: the streak stands until the day ends) and the best one ever
    readonly property int streak: {
        var n = 0, d = new Date(today)
        if ((days[key(d)] || 0) < goal) d.setDate(d.getDate() - 1)
        for (var i = 0; i < 4000; i++) {
            if ((days[key(d)] || 0) >= goal) { n++; d.setDate(d.getDate() - 1) } else break
        }
        return n
    }
    readonly property int best: {
        var ks = []
        for (var k in days) if ((days[k] || 0) >= goal) ks.push(k)
        ks.sort()
        var run = 0, top = 0, prev = null
        for (var i = 0; i < ks.length; i++) {
            var p = ks[i].split("-")
            var t = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]), 12, 0, 0).getTime()
            run = (prev !== null && Math.round((t - prev) / 86400000) === 1) ? run + 1 : 1
            if (run > top) top = run
            prev = t
        }
        return Math.max(top, streak)
    }
    readonly property real frac: !tracked || streak === 0 ? 0 : (best > streak ? streak / best : 1)
    readonly property int ticks: { var t = Math.max(7, best); return t <= 14 ? t : 4 }
    function plural(n) { return n + (n === 1 ? " day" : " days") }
    readonly property color tone: (todayMin >= goal || streak === 0) ? accent : (pal ? pal.warn : accent)

    // the last 14 days, oldest first
    readonly property var last14: {
        var out = [], t = today
        for (var i = 13; i >= 0; i--) {
            var d = new Date(t); d.setDate(d.getDate() - i)
            out.push({ m: days[key(d)] || 0, day: Qt.formatDate(d, "ddd").charAt(0), today: i === 0 })
        }
        return out
    }
    readonly property int peak: { var p = goal; for (var i = 0; i < last14.length; i++) if (last14[i].m > p) p = last14[i].m; return p }

    property real shown: frac
    Behavior on shown { enabled: root.live; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }

    readonly property real bw: sz(270)
    implicitWidth: bw
    implicitHeight: body.item ? body.item.implicitHeight : sz(100)
    Loader { id: body; width: root.bw; sourceComponent: root.style === "bars" ? barsC : railC }
    MouseArea {
        anchors.fill: parent
        enabled: !root.editing && !!root.env && typeof root.env.openFocusStreak === "function"
        cursorShape: Qt.PointingHandCursor
        onClicked: root.env.openFocusStreak()
    }

    // ---- rail: the Settings graph
    Component {
        id: railC
        Column {
            spacing: root.sz(8)
            Row {
                width: parent.width
                WLbl { b: root; text: "FOCUS STREAK"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold; width: parent.width - st.implicitWidth }
                WLbl { id: st; b: root; color: root.dim; font.pixelSize: root.sz(11)
                    text: !root.tracked ? "" : (root.streak > 0 && root.streak >= root.best ? "Your best" : (root.streak > 0 ? "On a streak" : "No streak")) }
            }
            Item {
                id: rail
                width: parent.width; height: root.sz(22)
                readonly property real pad: root.sz(8)
                readonly property real run: width - 2 * pad
                Rectangle { x: rail.pad; width: rail.run; height: root.sz(6); radius: height / 2; anchors.verticalCenter: parent.verticalCenter; color: root.track }
                Repeater {
                    model: root.ticks + 1
                    delegate: Rectangle {
                        required property int index
                        x: rail.pad + rail.run * index / root.ticks - 0.5; width: 1; height: root.sz(10); y: (rail.height - height) / 2
                        color: root.dim; opacity: 0.35
                    }
                }
                Rectangle { x: rail.pad; width: Math.max(root.sz(6), rail.run * root.shown); height: root.sz(6); radius: height / 2; anchors.verticalCenter: parent.verticalCenter; color: root.tone }
                // the end ring: your best (a goal, not a deadline)
                Rectangle {
                    x: rail.pad + rail.run - width / 2; width: root.sz(14); height: width; radius: width / 2; anchors.verticalCenter: parent.verticalCenter
                    color: root.tracked && root.streak > 0 && root.streak >= root.best ? root.tone : "transparent"
                    border.width: 2; border.color: root.tracked ? root.tone : root.track
                }
                // today's marker
                Rectangle {
                    x: rail.pad + rail.run * root.shown - width / 2; width: root.sz(12); height: width; radius: width / 2; anchors.verticalCenter: parent.verticalCenter
                    color: root.fg; visible: root.tracked
                }
            }
            Row {
                width: parent.width
                WLbl { b: root; width: parent.width / 2; font.pixelSize: root.sz(12)
                    text: !root.tracked ? "No focus sessions yet" : (root.streak === 0 ? "No streak right now" : "Streak: " + root.plural(root.streak)) }
                WLbl { b: root; width: parent.width / 2; horizontalAlignment: Text.AlignRight; color: root.dim; font.pixelSize: root.sz(12)
                    text: !root.tracked ? "Start a Focus session" : (root.best > root.streak ? "Best: " + root.plural(root.best) + "  \u00b7  " + (root.best - root.streak) + " to go" : (root.streak > 0 ? "This is your best" : "Reach " + root.goal + " min in a day")) }
            }
            WLbl {
                visible: root.showDetail && root.tracked
                b: root; width: parent.width; wrapMode: Text.WordWrap; color: root.dim; font.pixelSize: root.sz(11)
                text: "Today: " + root.todayMin + " / " + root.goal + " min" + (root.streak > 0 && root.todayMin < root.goal ? "  \u00b7  " + (root.goal - root.todayMin) + " more keeps the streak" : "")
            }
        }
    }

    // ---- bars: minutes of focus per day, the last two weeks, a line at the goal
    Component {
        id: barsC
        Column {
            spacing: root.sz(6)
            Row {
                width: parent.width
                WLbl { b: root; text: "FOCUS, 14 DAYS"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold; width: parent.width - sk.implicitWidth }
                WLbl { id: sk; b: root; color: root.dim; font.pixelSize: root.sz(11); text: root.streak > 0 ? root.plural(root.streak) + " streak" : "" }
            }
            Item {
                id: plot
                width: parent.width; height: root.sz(64)
                readonly property real slot: width / 14
                Repeater {
                    model: root.last14
                    delegate: Item {
                        required property var modelData
                        required property int index
                        x: index * plot.slot; width: plot.slot; height: plot.height
                        Rectangle {
                            width: Math.max(2, plot.slot - root.sz(4)); anchors.horizontalCenter: parent.horizontalCenter
                            height: modelData.m > 0 ? Math.max(root.sz(3), plot.height * modelData.m / root.peak) : root.sz(2)
                            anchors.bottom: parent.bottom; radius: Math.min(width / 2, 3)
                            color: modelData.m >= root.goal ? root.accent : (modelData.m > 0 ? Qt.alpha(root.accent, 0.4) : root.track)
                            border.width: modelData.today ? 1 : 0; border.color: root.fg
                        }
                    }
                }
                // the goal line
                Rectangle { width: parent.width; height: 1; y: plot.height - plot.height * root.goal / root.peak; color: root.dim; opacity: 0.5 }
            }
            Row {
                Repeater {
                    model: root.last14
                    delegate: WLbl { required property var modelData; b: root; width: root.bw / 14; horizontalAlignment: Text.AlignHCenter; text: modelData.day; color: modelData.today ? root.fg : root.dim; font.pixelSize: root.sz(9) }
                }
            }
            WLbl { visible: root.showDetail; b: root; width: parent.width; color: root.dim; font.pixelSize: root.sz(11); text: "Today: " + root.todayMin + " / " + root.goal + " min" }
        }
    }
}
