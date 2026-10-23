import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

// The Focus streak view: your streak as something to look at and act on. `>focus streak graph`, `halcyon focus-graph`, a click on the
// Focus streak graph widget, or the IPC call `focusgraph`. Esc / a click outside closes it, Space starts or stops a Focus session.
//   - the flame and the streak (it counts up when the view opens), your best and the next milestone
//   - today's ring: the minutes you focused against the goal, filling up
//   - the last 14 days as bars that grow in, and the last 12 weeks as a heat map
//   - milestones (3, 7, 14, 30, 60, 100 days in a row) that light up once your best reaches them
//   - Start / Pause / Stop for a Focus session right there (scripts/focus.sh, the same session as the utilities box)
// It only READS what the island already counts (env.focusDays, from ~/.local/state/island/focus-days.json). The window does not exist
// while it is closed, and its animations only run while it is open.
Scope {
    id: root
    property var pal
    property var env                         // the shell: focusDays, focusState, focusText, focusToggle(), focusRun(), opt
    property bool open: false
    function show() { open = true }
    function hide() { open = false }
    function toggle() { open = !open }
    onOpenChanged: if (open && env && typeof env.refreshFocusDays === "function") env.refreshFocusDays()

    // the minutes that make a focus day: the Focus widgets' own goal, else 25 (the same rule as the widgets and halcyon-ai.py brief)
    readonly property int goal: {
        var o = env && env.opt ? env.opt : ({})
        var lists = [o.deskWidgets, o.lockDeskWidgets]
        for (var l = 0; l < lists.length; l++) {
            var a = lists[l] && lists[l].items ? lists[l].items : []
            for (var i = 0; i < a.length; i++)
                if ((a[i].type === "focus" || a[i].type === "focusgraph") && a[i].opts && Number(a[i].opts.goal) > 0) return Math.round(Number(a[i].opts.goal))
        }
        return 25
    }
    readonly property var days: env && env.focusDays ? env.focusDays : ({})
    readonly property var fst: env && env.focusState ? env.focusState : ({ on: false })
    property date today: new Date()
    function key(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    function mins(d) { return Number(days[key(d)] || 0) }
    readonly property int todayMin: { var t = today; return mins(t) }
    readonly property bool tracked: { for (var k in days) return true; return false }
    readonly property int streak: {
        var n = 0, d = new Date(today)
        if (mins(d) < goal) d.setDate(d.getDate() - 1)          // today is still to be earned: the streak stands until the day ends
        for (var i = 0; i < 4000; i++) { if (mins(d) >= goal) { n++; d.setDate(d.getDate() - 1) } else break }
        return n
    }
    readonly property int best: {
        var ks = []
        for (var k in days) if (Number(days[k] || 0) >= goal) ks.push(k)
        ks.sort()
        var run = 0, top = 0, prev = null
        for (var i = 0; i < ks.length; i++) {
            var p = ks[i].split("-")
            var t = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]), 12, 0, 0).getTime()
            run = (prev !== null && Math.round((t - prev) / 86400000) === 1) ? run + 1 : 1
            top = Math.max(top, run)
            prev = t
        }
        return Math.max(top, streak)
    }
    readonly property int total: { var s = 0; for (var k in days) s += Number(days[k] || 0); return s }
    readonly property var milestones: [3, 7, 14, 30, 60, 100]
    readonly property int nextMile: { for (var i = 0; i < milestones.length; i++) if (milestones[i] > streak) return milestones[i]; return 0 }
    readonly property var last14: {
        var out = [], t = today
        for (var i = 13; i >= 0; i--) {
            var d = new Date(t); d.setDate(d.getDate() - i)
            out.push({ m: mins(d), day: Qt.formatDate(d, "ddd").charAt(0), date: Qt.formatDate(d, "d MMM"), today: i === 0 })
        }
        return out
    }
    readonly property int peak: { var p = goal; for (var i = 0; i < last14.length; i++) p = Math.max(p, last14[i].m); return p }
    // 12 weeks, Monday first, a column per week (the last column is this week; days after today are left empty)
    readonly property var weeks: {
        var t = new Date(today), dow = (t.getDay() + 6) % 7
        var start = new Date(t); start.setDate(t.getDate() - dow - 7 * 11)
        var out = []
        for (var w = 0; w < 12; w++) {
            var col = []
            for (var d = 0; d < 7; d++) {
                var x = new Date(start); x.setDate(start.getDate() + w * 7 + d)
                col.push({ m: x > t ? -1 : mins(x), date: Qt.formatDate(x, "d MMM") })
            }
            out.push(col)
        }
        return out
    }
    readonly property string mood: {
        if (!tracked) return "Your first focus session starts the streak."
        if (todayMin >= goal && streak >= best && streak > 1) return "A new best. Keep the fire going."
        if (todayMin >= goal) return "Today counts. Nice work."
        if (streak > 0) return (goal - todayMin) + " more minutes today keeps the flame alive."
        return "No streak right now. " + goal + " minutes today lights it again."
    }

    LazyLoader {
        active: root.open
        PanelWindow {
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-focus-streak"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            Item {
                id: stage
                anchors.fill: parent
                focus: true
                Component.onCompleted: { root.today = new Date(); intro.start() }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) root.open = false
                    else if (e.key === Qt.Key_Space && root.env) root.env.focusToggle()
                    else return
                    e.accepted = true
                }

                // the intro: 0 .. 1 once when the view opens (the number counts up, the ring fills, the bars grow in turn)
                property real t: 0
                NumberAnimation on t { id: intro; running: false; from: 0; to: 1; duration: 1400; easing.type: Easing.OutCubic }
                // the flame flickers while the view is open
                property real flick: 0
                NumberAnimation on flick { running: root.open; from: 0; to: 2 * Math.PI; duration: 2600; loops: Animation.Infinite }

                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.72); opacity: Math.min(1, stage.t * 3) }
                MouseArea { anchors.fill: parent; onClicked: root.open = false }

                Glass {
                    id: card
                    pal: root.pal
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 48, 980)
                    height: Math.min(parent.height - 48, col.implicitHeight + 64)
                    radius: root.pal.rXl
                    opacityBody: root.pal.solid ? 1 : 0.86
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.4)
                    scale: 0.94 + 0.06 * stage.t
                    opacity: Math.min(1, stage.t * 2)
                    MouseArea { anchors.fill: parent }

                    ColumnLayout {
                        id: col
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 32 }
                        spacing: 22

                        // ---- the flame, the streak, today's ring
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 28
                            Item {
                                Layout.preferredWidth: 120; Layout.preferredHeight: 120
                                Text {
                                    anchors.centerIn: parent
                                    text: String.fromCodePoint(0xF0238)
                                    font.family: root.pal.font
                                    font.pixelSize: 96 + 6 * Math.sin(stage.flick * 2)
                                    color: root.streak > 0 ? (root.todayMin >= root.goal ? root.pal.accent : root.pal.warn) : Qt.alpha(root.pal.muted, 0.5)
                                    rotation: 4 * Math.sin(stage.flick)
                                    opacity: 0.85 + 0.15 * Math.sin(stage.flick * 3)
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text { text: root.pal.cap("FOCUS STREAK"); color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: 12; font.letterSpacing: root.pal.calm ? 0.2 : 2.5; font.weight: Font.DemiBold }
                                Row {
                                    spacing: 12
                                    Text { id: big; text: Math.round(root.streak * stage.t); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 72; font.weight: Font.Light }
                                    Text { text: root.streak === 1 ? "day in a row" : "days in a row"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 18; anchors.baseline: big.baseline }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: "Best " + root.best + (root.best === 1 ? " day" : " days")
                                          + (root.nextMile > 0 ? "   ·   next milestone " + root.nextMile + " (" + (root.nextMile - root.streak) + " to go)" : "   ·   every milestone reached")
                                          + "   ·   " + Math.round(root.total / 60) + " h focused in all"
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 13; wrapMode: Text.WordWrap
                                }
                                Text { Layout.fillWidth: true; Layout.topMargin: 6; text: root.mood; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; wrapMode: Text.WordWrap }
                            }
                            // today's ring
                            Item {
                                Layout.preferredWidth: 150; Layout.preferredHeight: 150
                                Canvas {
                                    id: ring
                                    anchors.fill: parent
                                    readonly property real frac: Math.min(1, root.todayMin / Math.max(1, root.goal)) * stage.t
                                    onFracChanged: requestPaint()
                                    onPaint: {
                                        var c = getContext("2d"), r = width / 2 - 9
                                        c.reset()
                                        c.lineWidth = 12; c.lineCap = "round"
                                        c.strokeStyle = Qt.alpha(root.pal.text, 0.1)
                                        c.beginPath(); c.arc(width / 2, height / 2, r, 0, 2 * Math.PI); c.stroke()
                                        if (frac > 0.001) {
                                            c.strokeStyle = frac >= 0.999 ? root.pal.accent : root.pal.warn
                                            c.beginPath(); c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * frac); c.stroke()
                                        }
                                    }
                                }
                                Column {
                                    anchors.centerIn: parent
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.fst.on ? (root.env ? root.env.focusText : "") : String(root.todayMin); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.fst.on ? 28 : 34; font.weight: Font.Light }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.fst.on ? (root.fst.paused ? "paused" : "focusing") : "/ " + root.goal + " min today"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11 }
                                }
                            }
                        }

                        // ---- start / pause / stop
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            ActionChip { pal: root.pal; glyph: String.fromCodePoint(root.fst.on ? 0xF04DB : 0xF040A); label: root.fst.on ? "Stop the session" : "Start focusing"; on: !root.fst.on; onClicked: if (root.env) root.env.focusToggle() }
                            ActionChip { visible: root.fst.on; pal: root.pal; glyph: String.fromCodePoint(root.fst.paused ? 0xF040A : 0xF03E4); label: root.fst.paused ? "Resume" : "Pause"; onClicked: if (root.env) root.env.focusRun([root.fst.paused ? "resume" : "pause"]) }
                            Text { Layout.fillWidth: true; text: "Space starts or stops   ·   Esc closes"; color: Qt.alpha(root.pal.muted, 0.8); font.family: root.pal.uiFont; font.pixelSize: 11; horizontalAlignment: Text.AlignRight }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- the last 14 days
                        Text { text: "THE LAST 14 DAYS"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; font.letterSpacing: 2 }
                        Item {
                            id: plot
                            Layout.fillWidth: true
                            Layout.preferredHeight: 120
                            readonly property real slot: width / 14
                            Repeater {
                                model: root.last14
                                delegate: Item {
                                    id: bar
                                    required property var modelData
                                    required property int index
                                    // each bar grows a moment after the one before it
                                    readonly property real grow: Math.max(0, Math.min(1, stage.t * 2.2 - bar.index * 0.08))
                                    x: index * plot.slot; width: plot.slot; height: plot.height
                                    Rectangle {
                                        width: Math.max(4, plot.slot - 10); anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom; anchors.bottomMargin: 18
                                        height: Math.max(3, (plot.height - 34) * bar.modelData.m / root.peak * bar.grow)
                                        radius: 4
                                        color: bar.modelData.m >= root.goal ? root.pal.accent : (bar.modelData.m > 0 ? Qt.alpha(root.pal.accent, 0.4) : Qt.alpha(root.pal.text, 0.08))
                                        border.width: bar.modelData.today ? 1 : 0; border.color: root.pal.text
                                    }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; text: bar.modelData.day; color: bar.modelData.today ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11 }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: plot.height - 22 - (plot.height - 34) * bar.modelData.m / root.peak * bar.grow
                                        visible: bm.containsMouse && bar.modelData.m > 0
                                        text: bar.modelData.m + " min"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 11
                                    }
                                    MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true }
                                }
                            }
                            // the goal line
                            Rectangle {
                                width: parent.width; height: 1
                                y: plot.height - 18 - (plot.height - 34) * root.goal / root.peak
                                color: root.pal.muted; opacity: 0.45
                            }
                            Text {
                                anchors.right: parent.right
                                y: plot.height - 32 - (plot.height - 34) * root.goal / root.peak
                                text: root.goal + " min goal"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                            }
                        }

                        // ---- 12 weeks, and the milestones
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 32
                            ColumnLayout {
                                spacing: 8
                                Text { text: "12 WEEKS"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; font.letterSpacing: 2 }
                                Row {
                                    spacing: 4
                                    Repeater {
                                        model: root.weeks
                                        delegate: Column {
                                            id: wk
                                            required property var modelData
                                            required property int index
                                            spacing: 4
                                            Repeater {
                                                model: wk.modelData
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    width: 16; height: 16; radius: 4
                                                    opacity: Math.max(0, Math.min(1, stage.t * 2.5 - wk.index * 0.1))
                                                    color: modelData.m < 0 ? "transparent"
                                                         : (modelData.m >= root.goal ? Qt.alpha(root.pal.accent, Math.min(1, 0.55 + 0.45 * modelData.m / (root.goal * 3)))
                                                         : (modelData.m > 0 ? Qt.alpha(root.pal.accent, 0.25) : Qt.alpha(root.pal.text, 0.07)))
                                                    border.width: modelData.m < 0 ? 1 : 0; border.color: Qt.alpha(root.pal.text, 0.06)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: root.pal.cap("MILESTONES"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; font.letterSpacing: root.pal.calm ? 0.2 : 2 }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Repeater {
                                        model: root.milestones
                                        delegate: Rectangle {
                                            required property int modelData
                                            readonly property bool got: root.best >= modelData
                                            width: 74; height: 74; radius: 37
                                            color: got ? Qt.alpha(root.pal.accent, 0.18) : Qt.alpha(root.pal.surface, 0.5)
                                            border.width: got ? 2 : 1; border.color: got ? root.pal.accent : root.pal.lineSoft
                                            scale: got ? 1 + 0.04 * Math.sin(stage.flick * 2 + modelData) : 1
                                            Column {
                                                anchors.centerIn: parent
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: String.fromCodePoint(parent.parent.got ? 0xF0538 : 0xF04CE); font.family: root.pal.font; font.pixelSize: 20; color: parent.parent.got ? root.pal.accent : Qt.alpha(root.pal.muted, 0.5) }
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.modelData + " days"; font.family: root.pal.uiFont; font.pixelSize: 11; color: parent.parent.got ? root.pal.text : root.pal.muted }
                                            }
                                        }
                                    }
                                }
                                Text { Layout.fillWidth: true; text: "A day counts from " + root.goal + " minutes of focus (change it in the Widget builder > Focus widgets > Minutes that count as a focus day)."; color: Qt.alpha(root.pal.muted, 0.85); font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap }
                            }
                        }
                    }
                }
            }
        }
    }
}
