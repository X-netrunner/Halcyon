import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// >calendar : your Google Calendar (read-only) as a month and an agenda, plus reminder notifications.
//   Left: the month (dots = days with something), what is next. Right: the selected day.
//   Keys: arrows move the day, PageUp / PageDown the month, T today, R refresh, Esc close.
// The data comes from scripts/gcal.py through the calendar's private iCal address (no Google login, nothing is ever written
// back). This file also runs the background work: sync every 15 minutes, and once a minute "send the reminders that are due",
// which arrive as ordinary notifications (app name "Calendar").
Scope {
    id: root
    property var pal
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool open: false

    // Switches from Settings > Calendar (shell.qml passes them in)
    property bool enabled: true              // master switch: off = no window, no sync, no reminders, no auto Focus
    property bool notifyOn: true             // reminder notifications
    property bool focusOn: false             // start a Focus session when a task begins
    property bool nagOn: false               // keep reminding until a task is marked done
    property int nagEvery: 5                 // minutes between the nags
    property int nagGiveUp: 180              // stop nagging this many minutes after the task ended
    property bool tasksAll: false            // every event counts as a task (otherwise only the ones you flag)

    function show() { if (enabled) open = true }
    function hide() { open = false }
    // the bar page opened: bring the data up to date the way opening the full window does
    function refresh() {
        if (!enabled) return
        now = Date.now(); today = midnight(new Date()); gotoDay(new Date())
        loadConf(); loadEvents()
        if (cfg.configured && (Date.now() / 1000 - cfg.synced) > 300) sync()
    }
    function toggle() { if (open) open = false; else show() }
    onEnabledChanged: if (!enabled) open = false

    readonly property string script: Quickshell.shellDir + "/scripts/gcal.py"

    // ---------------------------------------------------------------- data
    property var cfg: ({ configured: false, count: 0, names: [], remind: [10, 0], synced: 0, error: "" })
    property var events: []
    property var doneMap: ({})               // event id -> true: marked done (kept here only, never sent to Google)
    property var taskMap: ({})               // event id -> true: flagged as a task
    function isDone(e) { return !!doneMap[e.id] }
    function isTask(e) { return tasksAll || !!taskMap[e.id] }
    function setDone(e, on) {
        var m = Object.assign({}, doneMap); if (on) m[e.id] = true; else delete m[e.id]; doneMap = m
        markProc.command = ["python3", script, on ? "done" : "undone", e.id]; markProc.running = true
    }
    function setTask(e, on) {
        var m = Object.assign({}, taskMap); if (on) m[e.id] = true; else delete m[e.id]; taskMap = m
        markProc.command = ["python3", script, "task", e.id, on ? "on" : "off"]; markProc.running = true
    }
    // the first task that is running now or comes next (for the bar page's header line)
    readonly property var nextTask: {
        var n = Math.floor(now / 1000), best = null
        for (var i = 0; i < events.length; i++) {
            var e = events[i]
            if (e.allDay || doneMap[e.id] || !(tasksAll || taskMap[e.id]) || e.end <= n) continue
            if (!best || e.start < best.start) best = e
        }
        return best
    }
    property var dayMap: ({})
    property bool syncing: false
    property bool setupOpen: false           // the connect / manage page instead of the calendar
    property string setupMsg: ""
    property real now: Date.now()
    readonly property bool ready: cfg.configured && !setupOpen

    function keyOf(d) { return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate() }
    function midnight(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()) }
    function addDays(d, n) { return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n) }
    property date today: midnight(new Date())
    property date sel: midnight(new Date())
    property int viewY: new Date().getFullYear()
    property int viewM: new Date().getMonth()

    function rebuild() {
        var m = {}
        for (var i = 0; i < events.length; i++) {
            var e = events[i]
            var s = midnight(new Date(e.start * 1000))
            // an all-day event ends at midnight of the day after its last day; a timed one on the day it ends
            var last = new Date((e.allDay ? e.end - 1 : Math.max(e.start, e.end - 1)) * 1000)
            var lastDay = midnight(last)
            var guard = 0
            for (var d = s; d <= lastDay && guard < 62; d = addDays(d, 1), guard++) {
                var k = keyOf(d)
                if (!m[k]) m[k] = []
                m[k].push(e)
            }
        }
        for (var key in m)
            m[key].sort(function (a, b) { return (b.allDay ? 1 : 0) - (a.allDay ? 1 : 0) || a.start - b.start })
        dayMap = m
    }
    onEventsChanged: rebuild()
    readonly property var selEvents: dayMap[keyOf(sel)] || []

    function gotoDay(d) {
        sel = midnight(d)
        viewY = sel.getFullYear(); viewM = sel.getMonth()
    }
    function moveMonth(n) {
        var d = new Date(viewY, viewM + n, 1)
        viewY = d.getFullYear(); viewM = d.getMonth()
        // keep the selected day inside the shown month (same day number, or the last one)
        var last = new Date(viewY, viewM + 1, 0).getDate()
        sel = new Date(viewY, viewM, Math.min(sel.getDate(), last))
    }

    // the next thing that has not finished: for the "Next up" card
    readonly property var nextUp: {
        var t = now / 1000
        for (var i = 0; i < events.length; i++) {
            var e = events[i]
            if (!e.allDay && e.end > t) return e
        }
        return null
    }
    function clock(ts) { return Qt.formatTime(new Date(ts * 1000), Qt.locale().timeFormat(Locale.ShortFormat)) }
    function rel(e) {
        var t = now / 1000
        if (e.start <= t && e.end > t) return "now, until " + clock(e.end)
        var mins = Math.round((e.start - t) / 60)
        if (mins < 60) return "in " + mins + " min"
        if (mins < 360) return "in " + Math.floor(mins / 60) + " h " + (mins % 60 ? (mins % 60) + " min" : "")
        var d = midnight(new Date(e.start * 1000))
        var diff = Math.round((d - today) / 86400000)
        return (diff === 0 ? "today " : diff === 1 ? "tomorrow " : Qt.formatDate(d, "ddd d MMM") + ", ") + clock(e.start)
    }
    function dur(e) {
        var m = Math.round((e.end - e.start) / 60)
        if (m <= 0) return ""
        if (m < 60) return m + " min"
        var h = Math.floor(m / 60)
        return h + " h" + (m % 60 ? " " + (m % 60) + " min" : "")
    }
    function ago(ts) {
        if (!ts) return "never synced"
        var m = Math.round((now / 1000 - ts) / 60)
        return m < 1 ? "synced just now" : m < 60 ? "synced " + m + " min ago" : "synced " + Math.round(m / 60) + " h ago"
    }

    // ---------------------------------------------------------------- talking to gcal.py
    function loadConf() { confProc.running = true }
    function loadEvents() { evProc.running = true }
    function sync() { if (cfg.configured && !syncing) { syncing = true; syncProc.running = true } }
    // Google sends "Busy" instead of the title for the public address: nearly every event says Busy
    readonly property bool busyOnly: {
        if (events.length < 3) return false
        var n = 0
        for (var i = 0; i < events.length; i++) if (String(events[i].title).toLowerCase() === "busy") n++
        return n >= events.length * 0.9
    }
    function connect(url) {
        setupMsg = "Connecting..."
        syncing = true
        var cmd = ["python3", script, "add-url", url.trim(), ""]
        if (busyOnly) cmd.push("--replace")      // reconnecting to fix the Busy problem: the new address replaces the old one
        addProc.command = cmd
        addProc.running = true
    }
    function disconnect() { clearProc.running = true }
    function setRemind(spec) { remindProc.command = ["python3", script, "remind", spec]; remindProc.running = true }

    Process {
        id: confProc
        command: ["python3", root.script, "conf"]
        stdout: StdioCollector { onStreamFinished: { try { root.cfg = JSON.parse(text) } catch (e) {} } }
    }
    Process {
        id: evProc
        command: ["python3", root.script, "events"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    root.events = d.events || []
                    var dm = {}, tm = {}
                    ;(d.done || []).forEach(function (k) { dm[k] = true })
                    ;(d.tasks || []).forEach(function (k) { tm[k] = true })
                    root.doneMap = dm; root.taskMap = tm
                } catch (e) {}
            }
        }
    }
    Process {
        id: syncProc
        command: ["python3", root.script, "sync"]
        onExited: { root.syncing = false; root.loadConf(); root.loadEvents() }
    }
    Process {
        id: addProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.syncing = false
                var ok = false, err = ""
                try { var r = JSON.parse(text.split("\n").filter(function (l) { return l.trim() !== "" }).pop()); ok = r.ok; err = r.error || "" } catch (e) { err = "something went wrong" }
                root.setupMsg = ok ? "" : (err || "Could not read that calendar")
                if (ok) root.setupOpen = false
                if (root.fromWatcher) {
                    root.fromWatcher = false
                    if (ok) root.show()
                    else Quickshell.execDetached(["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "Could not connect the calendar", err || "That address did not work."])
                }
                root.loadConf(); root.loadEvents()
            }
        }
    }
    Process { id: clearProc; command: ["python3", root.script, "clear"]; onExited: { root.events = []; root.setupMsg = ""; root.loadConf() } }
    Process { id: remindProc; onExited: root.loadConf() }
    // reminders: the script sends a notification for each one that is due and remembers which it sent
    Process { id: markProc }
    Process { id: notifyProc }
    function runWorker() {
        var cmd = ["python3", script, "notify"]
        if (!notifyOn) cmd.push("--no-remind")
        if (nagOn && notifyOn) cmd.push("--nag", String(nagEvery), "--giveup", String(nagGiveUp))
        if (focusOn) cmd.push("--focus")
        if (tasksAll) cmd.push("--all-tasks")
        notifyProc.command = cmd
        notifyProc.running = true
    }

    // ---------------------------------------------------------------- "open Google for me"
    // The button opens Google Calendar's settings in your browser and the window steps aside. While you copy the "Secret address in
    // iCal format", the clipboard is checked every 1.5 s (for at most 6 minutes); the moment it holds a Google calendar address the
    // calendar connects by itself and comes back. Only a calendar.google.com/.../ical/....ics link is ever acted on.
    readonly property string googleUrl: "https://calendar.google.com/calendar/u/0/r/settings"
    property bool watching: false
    property int watchTicks: 0
    property bool clipManual: false          // the "Paste from clipboard" button (accepts any web address) instead of the watcher
    function openGoogle() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "run", "browser", googleUrl])
        watchTicks = 0
        watching = true
        hide()                                // the browser opens underneath this full-screen window otherwise
        Quickshell.execDetached(["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "Connect your calendar",
            "In the browser: click your calendar, then Integrate calendar, then copy the Secret address in iCal format. It connects by itself."])
    }
    function pasteClipboard() { clipManual = true; setupMsg = "Reading the clipboard..."; clipProc.running = true }
    function stopWatching() { watching = false }
    Process {
        id: clipProc
        command: ["wl-paste", "--no-newline"]
        stdout: StdioCollector {
            onStreamFinished: {
                var t = text.trim()
                if (root.clipManual) {
                    root.clipManual = false
                    if (/^(https?|webcal):\/\/\S+$/i.test(t)) root.connect(t)
                    else root.setupMsg = "The clipboard does not hold a calendar address. Copy the secret address in iCal format first."
                } else if (/^(https?|webcal):\/\/calendar\.google\.com\/calendar\/ical\/\S+\.ics$/i.test(t)) {
                    root.watching = false
                    root.fromWatcher = true
                    root.connect(t)
                }
            }
        }
    }
    property bool fromWatcher: false
    Timer {
        interval: 1500; repeat: true; running: root.watching
        onTriggered: {
            if (++root.watchTicks > 240) { root.watching = false; return }
            if (!clipProc.running) clipProc.running = true
        }
    }

    Component.onCompleted: { if (enabled) { loadConf(); loadEvents() } }
    onCfgChanged: { if (cfg.configured && events.length === 0 && !syncing && cfg.synced === 0) sync() }
    onOpenChanged: {
        if (open) {
            today = midnight(new Date()); gotoDay(new Date()); now = Date.now()
            setupOpen = !cfg.configured; setupMsg = ""
            loadConf(); loadEvents()
            if (cfg.configured && (Date.now() / 1000 - cfg.synced) > 300) sync()
        }
    }
    // background: every 15 minutes a sync, every minute the reminders. Only when a calendar is connected.
    Timer { interval: 900000; repeat: true; running: root.enabled && root.cfg.configured; onTriggered: root.sync() }
    Timer {
        interval: 60000; repeat: true; triggeredOnStart: true
        running: root.enabled && root.cfg.configured
            && ((root.notifyOn && root.cfg.remind && root.cfg.remind.length > 0) || root.nagOn || root.focusOn)
        onTriggered: { if (!notifyProc.running) root.runWorker(); root.now = Date.now() }
    }
    Timer { interval: 30000; repeat: true; running: root.open; onTriggered: { root.now = Date.now(); root.today = root.midnight(new Date()) } }

    // ---------------------------------------------------------------- small pieces
    component IconBtn: Rectangle {
        id: ib
        property string glyph: ""
        property bool spin: false
        signal clicked()
        width: 32; height: 32; radius: 16
        color: ma.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, 0.8)
        border.width: 1; border.color: root.pal.line
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Text {
            id: gl
            anchors.centerIn: parent
            text: ib.glyph
            color: root.pal.text
            font.family: root.pal.font; font.pixelSize: 16
            RotationAnimator on rotation { running: ib.spin; from: 0; to: 360; duration: 900; loops: Animation.Infinite; onRunningChanged: if (!running) gl.rotation = 0 }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: ib.clicked() }
    }
    component Pill: Rectangle {
        id: pl
        property string label: ""
        property bool primary: false
        signal clicked()
        height: 34; radius: 17
        width: Math.max(96, t.implicitWidth + 32)
        scale: ma2.pressed ? 0.97 : 1
        color: primary ? Qt.alpha(root.pal.accent, ma2.containsMouse ? 0.95 : 0.85) : (ma2.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, 0.85))
        border.width: primary ? 0 : 1; border.color: root.pal.line
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast } }
        Text { id: t; anchors.centerIn: parent; text: pl.label; color: pl.primary ? root.pal.bg : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
        MouseArea { id: ma2; anchors.fill: parent; hoverEnabled: true; onClicked: pl.clicked() }
    }

    LazyLoader {
        active: root.open
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-calendar"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: fade
                anchors.fill: parent
                opacity: root.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                focus: root.open
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { if (root.setupOpen && root.cfg.configured) root.setupOpen = false; else root.hide(); e.accepted = true; return }
                    if (!root.ready) return
                    if (e.key === Qt.Key_Left) root.gotoDay(root.addDays(root.sel, -1))
                    else if (e.key === Qt.Key_Right) root.gotoDay(root.addDays(root.sel, 1))
                    else if (e.key === Qt.Key_Up) root.gotoDay(root.addDays(root.sel, -7))
                    else if (e.key === Qt.Key_Down) root.gotoDay(root.addDays(root.sel, 7))
                    else if (e.key === Qt.Key_PageUp) root.moveMonth(-1)
                    else if (e.key === Qt.Key_PageDown) root.moveMonth(1)
                    else if (e.key === Qt.Key_T) root.gotoDay(new Date())
                    else if (e.key === Qt.Key_R) root.sync()
                    else return
                    e.accepted = true
                }

                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.55) }
                MouseArea { anchors.fill: parent; onClicked: root.hide() }

                Glass {
                    id: card
                    pal: root.pal
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 60, 980)
                    height: Math.min(parent.height - 60, 640)
                    radius: root.pal.rXl
                    opacityBody: root.pal.glassSolid - 0.02
                    border.color: Qt.alpha(root.pal.accent, 0.35)
                    scale: root.open ? 1 : 0.96
                    Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    MouseArea { anchors.fill: parent }       // swallow clicks

                    Backdrop { visible: root.open && root.stars; anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; avatarStars: root.starData; profileStars: root.profileStars; dots: 12; artStrength: 0.5; artFit: 0.85 }

                    // ---------------- header
                    RowLayout {
                        id: head
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 }
                        spacing: 12
                        Text { text: String.fromCodePoint(0xF00ED); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                        Text {
                            text: root.ready ? Qt.formatDate(new Date(root.viewY, root.viewM, 1), "MMMM yyyy") : "Calendar"
                            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
                        }
                        IconBtn { visible: root.ready; glyph: "‹"; onClicked: root.moveMonth(-1) }
                        IconBtn { visible: root.ready; glyph: "›"; onClicked: root.moveMonth(1) }
                        Pill { visible: root.ready; label: "Today"; height: 30; width: 72; onClicked: root.gotoDay(new Date()) }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: root.cfg.configured
                            text: root.syncing ? "syncing..." : (root.cfg.error ? "offline · " + root.ago(root.cfg.synced) : root.ago(root.cfg.synced))
                            color: root.cfg.error && !root.syncing ? root.pal.accent2 : root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                        }
                        IconBtn { visible: root.cfg.configured; glyph: String.fromCodePoint(0xF04E6); spin: root.syncing; onClicked: root.sync() }
                        IconBtn { visible: root.cfg.configured; glyph: String.fromCodePoint(0xF0493); onClicked: { root.setupMsg = ""; root.setupOpen = !root.setupOpen } }
                        IconBtn { glyph: "✕"; onClicked: root.hide() }
                    }

                    // ---------------- the calendar
                    Item {
                        id: body
                        visible: root.ready
                        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 24; topMargin: 18 }

                        // left: month grid + next up
                        Item {
                            id: left
                            width: 388                  // 7 columns of 52 + 12 padding on each side
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }

                            // the month sits in its own padded card; the weekday names and the days share one column width (52),
                            // so each name is centred exactly over its day
                            Rectangle {
                                id: monthCard
                                anchors { left: parent.left; right: parent.right; top: parent.top }
                                height: 12 + weekHead.height + 6 + 6 * grid.ch + 12
                                radius: root.pal.rLg
                                color: Qt.alpha(root.pal.surface, 0.5)
                                border.width: 1; border.color: root.pal.line
                            }
                            Row {
                                id: weekHead
                                x: 12; y: 12; height: 22
                                spacing: 0
                                Repeater {
                                    model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                                    delegate: Text {
                                        required property string modelData
                                        width: grid.cw; height: 22
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                                        text: modelData; color: root.pal.muted
                                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                }
                            }
                            Grid {
                                id: grid
                                x: 12
                                anchors.top: weekHead.bottom; anchors.topMargin: 6
                                columns: 7; spacing: 0
                                readonly property real cw: 52
                                readonly property real ch: 46
                                readonly property int offset: (new Date(root.viewY, root.viewM, 1).getDay() + 6) % 7
                                Repeater {
                                    model: 42
                                    delegate: Item {
                                        id: cell
                                        required property int index
                                        readonly property date d: new Date(root.viewY, root.viewM, 1 - grid.offset + index)
                                        readonly property bool inMonth: d.getMonth() === root.viewM
                                        readonly property bool isSel: root.keyOf(d) === root.keyOf(root.sel)
                                        readonly property bool isToday: root.keyOf(d) === root.keyOf(root.today)
                                        readonly property var evs: root.dayMap[root.keyOf(d)] || []
                                        width: grid.cw; height: grid.ch

                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 40; height: 40; radius: 12
                                            color: cell.isSel ? Qt.alpha(root.pal.accent, 0.22) : (cm.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.7) : "transparent")
                                            border.width: cell.isSel ? 1.5 : (cell.isToday ? 1 : 0)
                                            border.color: cell.isSel ? root.pal.accent : Qt.alpha(root.pal.accent, 0.6)
                                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            y: 7
                                            text: cell.d.getDate()
                                            color: cell.isToday ? root.pal.accent : root.pal.text
                                            opacity: cell.inMonth ? 1 : 0.35
                                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                            font.weight: cell.isToday || cell.isSel ? Font.DemiBold : Font.Normal
                                        }
                                        Row {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            y: 29; spacing: 3
                                            Repeater {
                                                model: Math.min(3, cell.evs.length)
                                                delegate: Rectangle {
                                                    width: 4; height: 4; radius: 2
                                                    color: root.pal.accent
                                                    opacity: cell.inMonth ? 0.9 : 0.35
                                                }
                                            }
                                        }
                                        MouseArea {
                                            id: cm
                                            anchors.fill: parent; hoverEnabled: true
                                            onClicked: { root.sel = root.midnight(cell.d); if (!cell.inMonth) { root.viewY = cell.d.getFullYear(); root.viewM = cell.d.getMonth() } }
                                        }
                                    }
                                }
                            }

                            // next up
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                height: nextCol.implicitHeight + 28
                                radius: root.pal.rLg
                                color: Qt.alpha(root.pal.surface, 0.8)
                                border.width: 1; border.color: root.pal.line
                                Column {
                                    id: nextCol
                                    x: 16; y: 14; width: parent.width - 32; spacing: 4
                                    Text { text: "NEXT UP"; color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1.2 }
                                    Text {
                                        width: parent.width
                                        text: root.nextUp ? root.nextUp.title : "Nothing coming up"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        width: parent.width
                                        visible: !!root.nextUp
                                        text: root.nextUp ? root.rel(root.nextUp) + (root.nextUp.loc ? "  ·  " + root.nextUp.loc : "") : ""
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        // right: the selected day
                        Item {
                            anchors { left: left.right; leftMargin: 28; right: parent.right; top: parent.top; bottom: parent.bottom }

                            Column {
                                id: dayHead
                                width: parent.width; spacing: 2
                                Text {
                                    text: Qt.formatDate(root.sel, "dddd d MMMM")
                                    color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold
                                }
                                Text {
                                    text: root.selEvents.length === 0 ? "Free day" : root.selEvents.length + (root.selEvents.length === 1 ? " event" : " events")
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                }
                            }
                            Rectangle {
                                id: busyBanner
                                visible: root.busyOnly
                                anchors { left: parent.left; right: parent.right; top: dayHead.bottom; topMargin: 12 }
                                height: visible ? bb.implicitHeight + 24 : 0
                                radius: root.pal.rMd
                                color: Qt.alpha(root.pal.accent2, 0.12)
                                border.width: 1; border.color: Qt.alpha(root.pal.accent2, 0.5)
                                Row {
                                    id: bb
                                    x: 14; y: 12; width: parent.width - 28; spacing: 12
                                    Text {
                                        width: parent.width - fixBtn.width - 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        wrapMode: Text.WordWrap
                                        text: "Every event says \"Busy\": Google hides the titles on the public address. Reconnect with the secret address."
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                    Pill { id: fixBtn; label: "Fix it"; primary: true; height: 30; width: 70; anchors.verticalCenter: parent.verticalCenter; onClicked: { root.setupMsg = ""; root.setupOpen = true } }
                                }
                            }
                            Flickable {
                                id: agenda
                                anchors { left: parent.left; right: parent.right; top: busyBanner.visible ? busyBanner.bottom : dayHead.bottom; bottom: parent.bottom; topMargin: 14 }
                                contentWidth: width
                                contentHeight: list.height + 6
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                Column {
                                    id: list
                                    width: agenda.width; spacing: 8
                                    Repeater {
                                        model: root.selEvents
                                        delegate: Rectangle {
                                            id: row
                                            required property var modelData
                                            readonly property bool past: modelData.end * 1000 < root.now
                                            readonly property bool live: modelData.start * 1000 <= root.now && modelData.end * 1000 > root.now
                                            width: list.width
                                            height: rc.implicitHeight + 24
                                            radius: root.pal.rMd
                                            color: live ? Qt.alpha(root.pal.accent, 0.14) : Qt.alpha(root.pal.surface, 0.75)
                                            border.width: 1
                                            border.color: live ? Qt.alpha(root.pal.accent, 0.6) : root.pal.line
                                            opacity: past ? 0.55 : 1
                                            Rectangle {
                                                x: 0; y: 10; width: 3; height: parent.height - 20; radius: 2
                                                color: modelData.allDay ? root.pal.accent2 : root.pal.accent
                                            }
                                            CalMarks {
                                                pal: root.pal; cal: root; ev: modelData
                                                anchors { right: parent.right; rightMargin: 12; top: parent.top; topMargin: 10 }
                                            }
                                            Row {
                                                id: rc
                                                x: 18; y: 12; width: parent.width - 32 - 90; spacing: 14
                                                Text {
                                                    width: 70
                                                    text: modelData.allDay ? "all day" : root.clock(modelData.start)
                                                    color: row.live ? root.pal.accent : root.pal.muted
                                                    font.family: root.pal.mono; font.pixelSize: root.pal.tBody
                                                }
                                                Column {
                                                    width: parent.width - 84; spacing: 3
                                                    Text {
                                                        width: parent.width
                                                        text: modelData.title
                                                        font.strikeout: root.isDone(modelData)
                                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold
                                                        wrapMode: Text.WordWrap
                                                    }
                                                    Text {
                                                        width: parent.width
                                                        visible: text !== ""
                                                        text: (modelData.allDay ? "" : root.clock(modelData.start) + " – " + root.clock(modelData.end) + (root.dur(modelData) ? "  ·  " + root.dur(modelData) : "")) + (modelData.loc ? (modelData.allDay ? "" : "  ·  ") + modelData.loc : "")
                                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                                        wrapMode: Text.WordWrap
                                                    }
                                                    Text {
                                                        width: parent.width
                                                        visible: modelData.desc !== ""
                                                        text: modelData.desc
                                                        color: Qt.alpha(root.pal.text, 0.6); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                                        maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.WordWrap
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                Text {
                                    visible: root.selEvents.length === 0
                                    anchors.centerIn: parent
                                    text: "Nothing planned"
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                }
                            }
                        }
                    }

                    // ---------------- connect / manage
                    Item {
                        id: setup
                        visible: !root.ready
                        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 24; topMargin: 18 }
                        Flickable {
                            anchors.fill: parent
                            contentWidth: width; contentHeight: sCol.implicitHeight + 8
                            clip: true; boundsBehavior: Flickable.StopAtBounds
                            Column {
                                id: sCol
                                width: Math.min(parent.width, 600)
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 4

                                Text {
                                    width: parent.width
                                    text: root.busyOnly ? "Reconnect your calendar" : (root.cfg.configured ? "Your calendar" : "Connect Google Calendar")
                                    color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
                                }
                                Text {
                                    width: parent.width; bottomPadding: 10
                                    wrapMode: Text.WordWrap
                                    color: root.busyOnly ? root.pal.accent2 : root.pal.muted
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    text: root.busyOnly ? "Every event says \"Busy\": that is the public address, where Google hides titles. The secret address (it has \"private-\" in it) shows everything and replaces the old one."
                                                        : root.cfg.configured ? "Connected: " + (root.cfg.names || []).join(", ") + ". Read-only, nothing is ever changed in your calendar."
                                                                              : "No Google login is handed over and nothing is ever changed in your calendar."
                                }

                                CalStep {
                                    pal: root.pal; live: root.open
                                    width: sCol.width; num: 1; done: root.watching; current: !root.watching
                                    title: "Open your calendar settings"
                                    body: "Opens in your browser. The window steps aside."
                                    Pill { primary: true; label: "Open Google Calendar"; onClicked: root.openGoogle() }
                                }
                                CalStep {
                                    pal: root.pal; live: root.open
                                    width: sCol.width; num: 2; current: root.watching
                                    title: "Pick your own calendar"
                                    body: "Under \"Settings for my calendars\" click the one with your name or email, not a shared or public one."
                                }
                                CalStep {
                                    pal: root.pal; live: root.open
                                    width: sCol.width; num: 3
                                    title: "Scroll to Integrate calendar"
                                    body: "Do not use \"Public URL\": it only says Busy."
                                }
                                CalStep {
                                    pal: root.pal; live: root.open
                                    width: sCol.width; num: 4; last: true; current: root.watching
                                    title: "Copy the secret address"
                                    body: "Press the copy button next to \"Secret address in iCal format\". The island sees it and connects by itself."
                                    Pill { label: "Paste from clipboard"; onClicked: root.pasteClipboard() }
                                }

                                Text {
                                    topPadding: 12; width: parent.width
                                    text: "or paste the address here"
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                }
                                Row {
                                    width: parent.width; spacing: 8
                                    Rectangle {
                                        width: parent.width - 100; height: 38; radius: 19
                                        color: Qt.alpha(root.pal.bg, 0.55)
                                        border.width: 1; border.color: urlIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                        Text {
                                            anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                            visible: urlIn.text === ""
                                            text: "https://calendar.google.com/calendar/ical/.../basic.ics"
                                            color: root.pal.muted; font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                        }
                                        TextInput {
                                            id: urlIn
                                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: root.pal.text
                                            selectionColor: Qt.alpha(root.pal.accent, 0.4)
                                            font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                            clip: true
                                            onAccepted: if (text.trim() !== "") { root.connect(text); text = "" }
                                            Keys.onEscapePressed: { if (root.cfg.configured) root.setupOpen = false; else root.hide() }
                                        }
                                    }
                                    Pill { width: 92; height: 38; radius: 19; label: "Connect"; onClicked: if (urlIn.text.trim() !== "") { root.connect(urlIn.text); urlIn.text = "" } }
                                }
                                Row {
                                    topPadding: 8; spacing: 10
                                    Pill { visible: root.cfg.configured; label: "Back"; onClicked: root.setupOpen = false }
                                }
                                Text {
                                    width: parent.width; visible: root.setupMsg !== ""
                                    text: root.setupMsg; wrapMode: Text.WordWrap
                                    color: (root.setupMsg === "Connecting..." || root.setupMsg === "Reading the clipboard...") ? root.pal.muted : root.pal.accent2
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                }

                                // reminders + disconnect (once connected)
                                Column {
                                    width: parent.width; spacing: 10; topPadding: 14
                                    visible: root.cfg.configured
                                    Rectangle { width: parent.width; height: 1; color: root.pal.line }
                                    Text { text: "Reminders"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                                    Text {
                                        width: parent.width; wrapMode: Text.WordWrap
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                        text: "A notification this many minutes before an event starts (0 = at the start). All-day events notify at 08:00. They arrive like any other notification, on top of everything."
                                    }
                                    Flow {
                                        width: parent.width; spacing: 8
                                        Repeater {
                                            model: [
                                                { label: "10 min + start", spec: "10,0" },
                                                { label: "30 + 10 + start", spec: "30,10,0" },
                                                { label: "At start only", spec: "0" },
                                                { label: "Off", spec: "off" }
                                            ]
                                            delegate: Rectangle {
                                                id: rb
                                                required property var modelData
                                                readonly property bool on: (modelData.spec === "off" ? (root.cfg.remind || []).length === 0 : (root.cfg.remind || []).join(",") === modelData.spec)
                                                height: 32; radius: 16; width: rt.implicitWidth + 28
                                                color: on ? Qt.alpha(root.pal.accent, 0.2) : (rm.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, 0.85))
                                                border.width: 1; border.color: on ? root.pal.accent : root.pal.line
                                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                                Text { id: rt; anchors.centerIn: parent; text: rb.modelData.label; color: rb.on ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; onClicked: root.setRemind(rb.modelData.spec) }
                                            }
                                        }
                                    }
                                    Item { width: 1; height: 6 }
                                    Pill { label: "Disconnect and forget"; onClicked: root.disconnect() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
