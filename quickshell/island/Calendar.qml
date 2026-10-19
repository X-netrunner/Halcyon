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

    property int flyCount: 0              // moving stars drifting in this box (0 = none): set by shell.qml from Resource use
    property int flyLoop: 150000          // ms for one slow pass of them
    property bool constellation: true       // false = only the drifting dots, no constellation picture (Settings > Constellations)
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool open: false
    property bool consoleOpen: false

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
    property bool holidayModalOpen: false
    property string holidayModalMsg: ""
    property bool bdayModalOpen: false
    property string bdayModalMsg: ""
    property var bdayList: []
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
    onEventsChanged: { rebuild(); nextWake = 0 }
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
    Process {
        id: holidayProc
        command: ["python3", root.script, "add-holidays"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.setupMsg = "Regional holidays added & synced!"
                root.holidayModalMsg = "Regional holidays added & synced!"
                root.loadConf()
                root.loadEvents()
            }
        }
    }
    Process {
        id: addCountryProc
        property string countryName: ""
        stdout: StdioCollector {
            onStreamFinished: {
                root.holidayModalMsg = "Added " + (addCountryProc.countryName || "Country") + " Holidays!"
                root.loadConf()
                root.loadEvents()
            }
        }
    }
    Process {
        id: importBdayProc
        command: ["python3", root.script, "import-birthdays"]
        stdout: StdioCollector {
            onStreamFinished: {
                var msg = ""
                try {
                    var r = JSON.parse(text.split("\n").filter(function(l){ return l.trim() !== "" }).pop())
                    if (r.ok) msg = "Imported " + r.count + " birthdays from " + r.file + (r.skipped > 0 ? " (" + r.skipped + " already in your list)" : "")
                    else msg = r.error || "Could not import birthdays"
                } catch(e) { msg = "Could not import birthdays" }
                root.setupMsg = msg
                root.holidayModalMsg = msg
                root.bdayModalMsg = msg
                root.loadConf()
                root.loadEvents()
                root.loadBdayList()
            }
        }
    }
    function loadBdayList() { listBdayProc.running = false; listBdayProc.running = true }
    function importBirthdays() {
        root.setupMsg = "Scanning Downloads for Google Contacts (.vcf / .csv / .zip)..."
        root.holidayModalMsg = root.setupMsg
        root.bdayModalMsg = root.setupMsg
        importBdayProc.running = true
    }
    function openGoogleContacts() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "run", "browser", "https://contacts.google.com/"])
        root.watchTicks = 0
        root.watching = true
        root.hide()
        Quickshell.execDetached(["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "Export Google Contacts (1 click)",
            "In Google Contacts: click Export (left sidebar) → Export. Halcyon will detect the download in ~/Downloads and import all birthdays automatically!"])
    }
    function openGoogleExport() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "run", "browser", "https://calendar.google.com/calendar/u/0/r/settings/export"])
        root.watchTicks = 0
        root.watching = true
        root.hide()
        Quickshell.execDetached(["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "Export Google Calendar (1 click)",
            "Click the 'Export' button on the page — Halcyon will detect the downloaded .zip in ~/Downloads and connect your calendars automatically!"])
    }
    Process {
        id: listBdayProc
        command: ["python3", root.script, "list-birthdays"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var r = JSON.parse(text.trim())
                    if (r.ok && r.birthdays) root.bdayList = r.birthdays
                } catch (e) {}
            }
        }
    }
    Process {
        id: singleBdayProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var r = JSON.parse(text.split("\n").filter(function(l){ return l.trim() !== "" }).pop())
                    if (r.ok) {
                        root.bdayModalMsg = "✓ Saved birthday for " + (r.name || "contact") + "!"
                        root.loadConf(); root.loadEvents(); root.loadBdayList()
                    } else {
                        root.bdayModalMsg = r.error || "Could not save birthday"
                    }
                } catch (e) { root.bdayModalMsg = "Could not save birthday" }
            }
        }
    }
    Process {
        id: remBdayProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.bdayModalMsg = "Removed birthday."
                root.loadConf(); root.loadEvents(); root.loadBdayList()
            }
        }
    }
    Process {
        id: autoGrabProc
        // Only start Python when ~/Downloads changed since the last scan (a finished download is renamed into place, which
        // updates the folder's time). Without this the interpreter started every tick just to find nothing new.
        command: ["sh", "-c",
            "d=\"$HOME/Downloads\"; s=\"$HOME/.cache/island/.grabstamp\"; mkdir -p \"$HOME/.cache/island\"; " +
            "if [ ! -e \"$s\" ] || [ \"$d\" -nt \"$s\" ]; then touch \"$s\"; exec python3 \"$1\" auto-grab; fi",
            "sh", root.script]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var r = JSON.parse(text.split("\n").filter(function(l){ return l.trim() !== "" }).pop())
                    if (r.ok && (r.addedCalendars > 0 || r.addedBirthdays > 0)) {
                        var msg = "✓ Auto-imported "
                        if (r.addedCalendars > 0 && r.addedBirthdays > 0)
                            msg += r.addedCalendars + " calendar(s) & " + r.addedBirthdays + " birthdays from " + r.file
                        else if (r.addedCalendars > 0)
                            msg += r.addedCalendars + " calendar(s) from " + r.file
                        else
                            msg += r.addedBirthdays + " birthdays from " + r.file
                        root.setupMsg = msg
                        root.bdayModalMsg = msg
                        root.holidayModalMsg = msg
                        root.watching = false
                        root.setupOpen = false
                        root.loadConf(); root.loadEvents(); root.loadBdayList()
                        root.show()
                        Quickshell.execDetached(["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "Halcyon Calendar Ready", msg])
                    }
                } catch (e) {}
            }
        }
    }
    // Google's built-in Birthdays calendar has no iCal address, so the birthday-sync helper reads it through the Calendar API
    // (read-only login, nothing is written to Google) and fills the "Google Calendar" block of birthdays.txt.
    // gSync: just sync. gConnect: take the newest client_secret_*.json from Downloads (if there is one), log in in the browser, then sync.
    readonly property string gBin: Quickshell.env("HOME") + "/.config/Halcyon/bin/birthday-sync"
    readonly property string gNoBin: '{"ok":false,"error":"birthday-sync is not installed. Run ./install.sh again."}'
    function gShow(msg) { root.setupMsg = msg; root.holidayModalMsg = msg; root.bdayModalMsg = msg }
    Process {
        id: gProc
        stdout: StdioCollector {
            onStreamFinished: {
                var msg = ""
                try {
                    var r = JSON.parse(text.split("\n").filter(function(l){ return l.trim() !== "" }).pop())
                    if (r.ok) {
                        msg = "Synced " + r.count + " birthdays from Google" + (r.skipped > 0 ? " (" + r.skipped + " already in your list)" : "")
                        if (r.clashes && r.clashes.length > 0) msg += ". Different date than your list: " + r.clashes.join("; ")
                    } else if (/not logged in/i.test(r.error || "")) {
                        msg = "Google is not connected yet. Save your OAuth client JSON (client_secret_*.json) to Downloads and press Connect Google Birthdays."
                    } else msg = r.error || "Could not sync Google birthdays"
                } catch(e) { msg = "Could not sync Google birthdays" }
                root.gShow(msg)
                root.loadConf()
                root.loadEvents()
                root.loadBdayList()
            }
        }
    }
    function gSync() {
        gShow("Syncing Google birthdays...")
        gProc.command = ["sh", "-c", 'B="$1"; [ -x "$B" ] || { echo "$2"; exit 0; }; exec "$B" sync --json', "sh", gBin, gNoBin]
        gProc.running = true
    }
    function gConnect() {
        gShow("Waiting for Google in your browser (up to 5 minutes)...")
        gProc.command = ["sh", "-c",
            'B="$1"; [ -x "$B" ] || { echo "$2"; exit 0; }\n' +
            'f=$(ls -t "$HOME"/Downloads/client_secret_*.json 2>/dev/null | head -n1)\n' +
            'if [ -n "$f" ]; then "$B" setup "$f" >/dev/null 2>&1 || { echo \'{"ok":false,"error":"That client_secret file could not be read. Create the credential as type Desktop app."}\'; exit 0; }; fi\n' +
            'out=$("$B" auth --json) || { printf "%s\\n" "$out" | tail -n 1; exit 0; }\n' +
            'exec "$B" sync --json', "sh", gBin, gNoBin]
        gProc.running = true
    }
    Process {
        id: singleHolidayProc
        stdout: StdioCollector {
            onStreamFinished: {
                var ok = false, err = "", name = ""
                try {
                    var r = JSON.parse(text.split("\n").filter(function(l){ return l.trim() !== "" }).pop())
                    ok = r.ok; err = r.error || ""; name = r.name || ""
                } catch(e) { err = "Failed to parse response" }
                if (ok) {
                    root.holidayModalMsg = "Holiday '" + name + "' added!"
                    root.loadConf()
                    root.loadEvents()
                } else {
                    root.holidayModalMsg = err || "Failed to add holiday"
                }
            }
        }
    }
    // reminders: the script sends a notification for each one that is due and remembers which it sent
    Process { id: markProc }
    // The worker says when it next has something to do ({"next": unix seconds}); until then the 60 s tick below only compares two
    // numbers instead of starting Python. Anything that can change the answer (events, done / task marks, the reminder settings)
    // sets nextWake back to 0, and a 15 minute ceiling covers everything else (and a clock that jumped after a suspend).
    property double nextWake: 0
    onDoneMapChanged: nextWake = 0
    onTaskMapChanged: nextWake = 0
    onNotifyOnChanged: nextWake = 0
    onNagOnChanged: nextWake = 0
    onNagEveryChanged: nextWake = 0
    onNagGiveUpChanged: nextWake = 0
    onFocusOnChanged: nextWake = 0
    onTasksAllChanged: nextWake = 0
    Process {
        id: notifyProc
        stdout: StdioCollector {
            onStreamFinished: {
                var cap = Date.now() + 900000
                try {
                    var r = JSON.parse(text.split("\n").filter(function(l){ return l.trim() !== "" }).pop())
                    root.nextWake = r.next > 0 ? Math.min(r.next * 1000, cap) : cap
                } catch (e) { root.nextWake = 0 }      // no answer: run again on the next tick, as before
            }
        }
    }
    function runWorker() {
        var cmd = ["python3", script, "notify", "--next"]
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
        // 1.5 s only while waiting for the copied calendar address; with just the setup / Birthdays window open 5 s is plenty
        interval: root.watching ? 1500 : 5000; repeat: true; running: root.watching || (root.open && (root.setupOpen || root.bdayModalOpen))
        onTriggered: {
            if (root.watching && ++root.watchTicks > 240) { root.watching = false; return }
            if (!clipProc.running) clipProc.running = true
            if (!autoGrabProc.running) autoGrabProc.running = true
        }
    }

    Component.onCompleted: { if (enabled) { loadConf(); loadEvents() } }
    onCfgChanged: { nextWake = 0; if (cfg.configured && events.length === 0 && !syncing && cfg.synced === 0) sync() }
    onOpenChanged: {
        if (open) {
            today = midnight(new Date()); gotoDay(new Date()); now = Date.now()
            setupOpen = !cfg.configured; setupMsg = ""; bdayModalOpen = false
            loadConf(); loadEvents(); loadBdayList()
            if (!autoGrabProc.running) autoGrabProc.running = true
            if (cfg.configured && (Date.now() / 1000 - cfg.synced) > 300) sync()
        }
    }
    // background: every 15 minutes a sync, every minute the reminders. Only when a calendar is connected.
    Timer { interval: 900000; repeat: true; running: root.enabled && root.cfg.configured; onTriggered: root.sync() }
    Timer {
        interval: 60000; repeat: true; triggeredOnStart: true
        running: root.enabled && root.cfg.configured
            && ((root.notifyOn && root.cfg.remind && root.cfg.remind.length > 0) || root.nagOn || root.focusOn)
        onTriggered: { if (!notifyProc.running && Date.now() >= root.nextWake) root.runWorker(); root.now = Date.now() }
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
        radius: 17
        implicitWidth: Math.max(96, t.implicitWidth + 32)   // implicit, not width: layouts re-measure when the label changes
        implicitHeight: 34
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
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.open && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: fade
                anchors.fill: parent
                opacity: root.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                focus: root.open
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { if (root.bdayModalOpen) root.bdayModalOpen = false; else if (root.holidayModalOpen) root.holidayModalOpen = false; else if (root.setupOpen && root.cfg.configured) root.setupOpen = false; else root.hide(); e.accepted = true; return }
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

                    Backdrop { visible: root.open && root.stars; anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; avatarStars: root.starData; profileStars: root.profileStars; dots: 12; dotAlpha: 2.6; dotDrift: 16; artStrength: !root.constellation ? 0 : ((root.bdayModalOpen || root.holidayModalOpen || root.setupOpen) ? 0.12 : 0.30); artFit: 0.85 }
                    BarStars { anchors.fill: parent; anchors.margins: 12; pal: root.pal; count: root.flyCount; loopMs: root.flyLoop; sizeScale: 1.3; active: root.open; visible: root.open && root.flyCount > 0 }

                    // ---------------- header
                    RowLayout {
                        id: head
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 }
                        spacing: 10
                        Text { text: String.fromCodePoint(0xF00ED); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                        Text {
                            text: root.ready ? Qt.formatDate(new Date(root.viewY, root.viewM, 1), "MMMM yyyy") : "Calendar"
                            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
                            Layout.preferredWidth: 175
                            Layout.minimumWidth: 175
                            Layout.maximumWidth: 175
                        }
                        IconBtn { opacity: (root.ready && !root.holidayModalOpen && !root.bdayModalOpen) ? 1 : 0; enabled: root.ready && !root.holidayModalOpen && !root.bdayModalOpen; glyph: "‹"; onClicked: root.moveMonth(-1) }
                        IconBtn { opacity: (root.ready && !root.holidayModalOpen && !root.bdayModalOpen) ? 1 : 0; enabled: root.ready && !root.holidayModalOpen && !root.bdayModalOpen; glyph: "›"; onClicked: root.moveMonth(1) }
                        Pill { opacity: (root.ready && !root.holidayModalOpen && !root.bdayModalOpen) ? 1 : 0; enabled: root.ready && !root.holidayModalOpen && !root.bdayModalOpen; label: "Today"; height: 30; width: 72; onClicked: root.gotoDay(new Date()) }
                        Pill {
                            label: root.bdayModalOpen ? "Back" : ("Birthdays" + (root.bdayList.length > 0 ? " (" + root.bdayList.length + ")" : ""))
                            primary: root.bdayModalOpen
                            height: 30
                            Layout.preferredWidth: 136
                            onClicked: {
                                root.bdayModalMsg = ""
                                root.bdayModalOpen = !root.bdayModalOpen
                                if (root.bdayModalOpen) {
                                    root.holidayModalOpen = false
                                    root.setupOpen = false
                                    root.loadBdayList()
                                }
                            }
                        }
                        Pill {
                            label: root.holidayModalOpen ? "Back" : "Holidays"
                            primary: root.holidayModalOpen
                            height: 30
                            Layout.preferredWidth: 136
                            onClicked: {
                                root.holidayModalMsg = ""
                                root.holidayModalOpen = !root.holidayModalOpen
                                if (root.holidayModalOpen) {
                                    root.bdayModalOpen = false
                                    root.setupOpen = false
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: root.cfg.configured && !root.holidayModalOpen && !root.bdayModalOpen
                            text: root.syncing ? "syncing..." : (root.cfg.error ? "offline · " + root.ago(root.cfg.synced) : root.ago(root.cfg.synced))
                            color: root.cfg.error && !root.syncing ? root.pal.accent2 : root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                        }
                        IconBtn { visible: root.cfg.configured && !root.holidayModalOpen && !root.bdayModalOpen; glyph: String.fromCodePoint(0xF04E6); spin: root.syncing; onClicked: root.sync() }
                        IconBtn { visible: root.cfg.configured && !root.holidayModalOpen && !root.bdayModalOpen; glyph: String.fromCodePoint(0xF0493); onClicked: { root.setupMsg = ""; root.holidayModalOpen = false; root.bdayModalOpen = false; root.setupOpen = !root.setupOpen } }
                        IconBtn { glyph: "✕"; onClicked: root.hide() }
                    }

                    // ---------------- the calendar
                    Item {
                        id: body
                        visible: root.ready && !root.holidayModalOpen && !root.bdayModalOpen
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
                                color: Qt.alpha(root.pal.surface, 0.8)
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
                        visible: !root.ready && !root.holidayModalOpen && !root.bdayModalOpen
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
                                    width: sCol.width; num: 1; done: root.watching || root.cfg.configured; current: !root.watching && !root.cfg.configured
                                    title: "Connect Google Calendar in 2 clicks (never make your calendar public!)"
                                    body: "Click '1-Click Export All Calendars' to open Google's Export page and click Export (Halcyon auto-imports the .zip from ~/Downloads!), OR click 'Live Sync (Secret iCal Link)' → click your calendar → copy 'Secret address in iCal format' (Halcyon auto-detects your clipboard!)."
                                    Pill { primary: true; label: "1-Click Export All Calendars ↗"; onClicked: root.openGoogleExport() }
                                    Pill { label: "Live Sync (Secret iCal Link) ↗"; onClicked: root.openGoogle() }
                                    Pill { label: "Paste from clipboard"; onClicked: root.pasteClipboard() }
                                }
                                CalStep {
                                    pal: root.pal; live: root.open
                                    width: sCol.width; num: 2; last: true; done: root.bdayList.length > 0; current: root.cfg.configured && root.bdayList.length === 0
                                    title: "Get Google Contacts Birthdays in 2 clicks (" + root.bdayList.length + " saved)"
                                    body: "Google Calendar's Birthdays calendar is separate from Google Contacts and has no iCal link. Click '1. Open Google Contacts' → click Export (left menu) → Export (CSV or vCard). Halcyon watches ~/Downloads and imports every birthday (with birth years!) automatically."
                                    Pill { primary: true; label: "1. Open Google Contacts ↗"; onClicked: root.openGoogleContacts() }
                                    Pill { label: "Auto-Import Downloads"; onClicked: root.importBirthdays() }
                                    Pill { label: "Manage Birthdays"; onClicked: { root.setupOpen = false; root.bdayModalOpen = true; root.loadBdayList() } }
                                }

                                Text {
                                    topPadding: 12; width: parent.width
                                    text: root.cfg.configured ? "Add another calendar (Holidays, Birthdays, Work, or any iCal feed)" : "or paste the address here"
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
                                Flow {
                                    width: parent.width; topPadding: 8; spacing: 10
                                    Pill { visible: root.cfg.configured; label: "Back"; onClicked: root.setupOpen = false }
                                    Pill {
                                        primary: true
                                        label: "Auto-Add My Country's Holidays"
                                        onClicked: {
                                            root.setupMsg = "Detecting region & adding holidays..."
                                            holidayProc.running = true
                                        }
                                    }
                                    Pill {
                                        label: "Import Contacts"
                                        onClicked: root.importBirthdays()
                                    }
                                    Pill {
                                        label: "Sync Google Birthdays"
                                        onClicked: root.gSync()
                                    }
                                    Pill {
                                        label: "Connect Google Birthdays"
                                        onClicked: root.gConnect()
                                    }
                                    Pill {
                                        label: "Edit Birthdays"
                                        onClicked: {
                                            Quickshell.execDetached(["xdg-open", Quickshell.env("HOME") + "/.config/Halcyon/birthdays.txt"])
                                        }
                                    }
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

                    // ---------------- holidays & feasts panel
                    Item {
                        id: holidayView
                        visible: root.holidayModalOpen
                        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 24; topMargin: 18 }
                        Flickable {
                            anchors.fill: parent
                            contentWidth: width; contentHeight: hCol.implicitHeight + 20
                            clip: true; boundsBehavior: Flickable.StopAtBounds
                            Column {
                                id: hCol
                                width: Math.min(parent.width, 680)
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 14

                                RowLayout {
                                    width: parent.width
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text {
                                            text: "Holidays & Feasts"
                                            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
                                        }
                                        Text {
                                            text: "1-Click national holidays feeds, local custom dates, and recurring celebrations."
                                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                        }
                                    }
                                    Pill {
                                        label: "Close"
                                        onClicked: root.holidayModalOpen = false
                                    }
                                }

                                Rectangle { width: parent.width; height: 1; color: root.pal.line }

                                // Status message banner
                                Rectangle {
                                    width: parent.width; height: 36; radius: 10
                                    visible: root.holidayModalMsg !== ""
                                    color: Qt.alpha(root.pal.accent, 0.15)
                                    border.width: 1; border.color: root.pal.accent
                                    Row {
                                        anchors.centerIn: parent; spacing: 8
                                        Text {
                                            text: root.holidayModalMsg
                                            color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
                                        }
                                    }
                                }

                                // Section 1: One-click National Feeds
                                Column {
                                    width: parent.width; spacing: 8
                                    Text {
                                        text: "1-Click Country Feeds"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        text: "Click any country to automatically add its public holidays to your calendar:"
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                    Flow {
                                        width: parent.width; spacing: 8
                                        Repeater {
                                            model: [
                                                { label: "India", code: "indian", name: "India" },
                                                { label: "USA", code: "usa", name: "United States" },
                                                { label: "UK", code: "uk", name: "United Kingdom" },
                                                { label: "Canada", code: "canadian", name: "Canada" },
                                                { label: "Australia", code: "australian", name: "Australia" },
                                                { label: "Germany", code: "german", name: "Germany" },
                                                { label: "France", code: "french", name: "France" },
                                                { label: "Japan", code: "japanese", name: "Japan" },
                                                { label: "Brazil", code: "brazilian", name: "Brazil" },
                                                { label: "Italy", code: "italian", name: "Italy" },
                                                { label: "Spain", code: "spanish", name: "Spain" },
                                                { label: "Netherlands", code: "dutch", name: "Netherlands" },
                                                { label: "UAE", code: "united_arab_emirates", name: "UAE" },
                                                { label: "Singapore", code: "singapore", name: "Singapore" }
                                            ]
                                            delegate: Rectangle {
                                                id: cBtn
                                                required property var modelData
                                                height: 32; radius: 16
                                                width: cTxt.implicitWidth + 24
                                                color: cMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, 0.7)
                                                border.width: 1; border.color: cMa.containsMouse ? root.pal.accent : root.pal.line
                                                Text {
                                                    id: cTxt
                                                    anchors.centerIn: parent
                                                    text: cBtn.modelData.label
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                }
                                                MouseArea {
                                                    id: cMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        root.holidayModalMsg = "Adding " + cBtn.modelData.name + " holidays..."
                                                        addCountryProc.countryName = cBtn.modelData.name
                                                        addCountryProc.command = ["python3", root.script, "add-holidays", cBtn.modelData.code]
                                                        addCountryProc.running = true
                                                    }
                                                }
                                            }
                                        }
                                        // Auto-detect button
                                        Rectangle {
                                            height: 32; radius: 16
                                            width: adTxt.implicitWidth + 24
                                            color: adMa.containsMouse ? Qt.alpha(root.pal.accent, 0.3) : Qt.alpha(root.pal.accent, 0.15)
                                            border.width: 1; border.color: root.pal.accent
                                            Text {
                                                id: adTxt
                                                anchors.centerIn: parent
                                                text: "Auto-Detect My Region"
                                                color: root.pal.accent
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                font.weight: Font.DemiBold
                                            }
                                            MouseArea {
                                                id: adMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.holidayModalMsg = "Detecting region & adding holidays..."
                                                    addCountryProc.countryName = "Regional"
                                                    addCountryProc.command = ["python3", root.script, "add-holidays"]
                                                    addCountryProc.running = true
                                                }
                                            }
                                        }
                                    }
                                }

                                Rectangle { width: parent.width; height: 1; color: root.pal.line }

                                // Section 2: Quick Custom Holiday Input
                                Column {
                                    width: parent.width; spacing: 8
                                    Text {
                                        text: "Add Custom Holiday or Celebration"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        text: "Quickly record an annual or one-off holiday (e.g. 10-24 or 2026-12-25):"
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                    RowLayout {
                                        width: parent.width; spacing: 8
                                        Rectangle {
                                            Layout.preferredWidth: 140; height: 38; radius: 19
                                            color: Qt.alpha(root.pal.bg, 0.55)
                                            border.width: 1; border.color: hDateIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                            Text {
                                                anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                                visible: hDateIn.text === ""
                                                text: "MM-DD (e.g. 12-25)"
                                                color: root.pal.muted; font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                            }
                                            TextInput {
                                                id: hDateIn
                                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: root.pal.text
                                                font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                                clip: true
                                            }
                                        }
                                        Rectangle {
                                            Layout.fillWidth: true; height: 38; radius: 19
                                            color: Qt.alpha(root.pal.bg, 0.55)
                                            border.width: 1; border.color: hNameIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                            Text {
                                                anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                                visible: hNameIn.text === ""
                                                text: "Holiday Name (e.g. Diwali, Anniversary, Summer Break)"
                                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                            }
                                            TextInput {
                                                id: hNameIn
                                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: root.pal.text
                                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                                clip: true
                                                onAccepted: {
                                                    if (hDateIn.text.trim() !== "" && hNameIn.text.trim() !== "") {
                                                        root.holidayModalMsg = "Saving holiday..."
                                                        singleHolidayProc.command = ["python3", root.script, "add-holiday", hDateIn.text.trim(), hNameIn.text.trim()]
                                                        singleHolidayProc.running = true
                                                        hDateIn.text = ""; hNameIn.text = ""
                                                    }
                                                }
                                            }
                                        }
                                        Pill {
                                            Layout.preferredWidth: 80; height: 38; radius: 19
                                            primary: true
                                            label: "Add"
                                            onClicked: {
                                                if (hDateIn.text.trim() !== "" && hNameIn.text.trim() !== "") {
                                                    root.holidayModalMsg = "Saving holiday..."
                                                    singleHolidayProc.command = ["python3", root.script, "add-holiday", hDateIn.text.trim(), hNameIn.text.trim()]
                                                    singleHolidayProc.running = true
                                                    hDateIn.text = ""; hNameIn.text = ""
                                                } else {
                                                    root.holidayModalMsg = "Please enter both date and holiday name."
                                                }
                                            }
                                        }
                                    }
                                }

                                Rectangle { width: parent.width; height: 1; color: root.pal.line }

                                // Section 3: File Management
                                RowLayout {
                                    width: parent.width; spacing: 10
                                    Column {
                                        Layout.fillWidth: true; Layout.minimumWidth: 160; spacing: 2
                                        Text {
                                            text: "Direct Text File Editing"
                                            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 14; font.weight: Font.DemiBold
                                        }
                                        Text {
                                            width: parent.width; wrapMode: Text.WordWrap
                                            text: "Plain text files in ~/.config/Halcyon/. For birthdays, export contacts.vcf from contacts.google.com and press Import."
                                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                        }
                                    }
                                    Pill {
                                        label: "Edit holidays.txt"
                                        onClicked: {
                                            Quickshell.execDetached(["xdg-open", Quickshell.env("HOME") + "/.config/Halcyon/holidays.txt"])
                                        }
                                    }
                                    Pill {
                                        label: "Import contacts.vcf"
                                        onClicked: root.importBirthdays()
                                    }
                                    Pill {
                                        label: "Sync Google Birthdays"
                                        onClicked: root.gSync()
                                    }
                                    Pill {
                                        label: "Edit birthdays.txt"
                                        onClicked: {
                                            Quickshell.execDetached(["xdg-open", Quickshell.env("HOME") + "/.config/Halcyon/birthdays.txt"])
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // ---------------- birthdays & google contacts panel
                    Item {
                        id: bdayView
                        visible: root.bdayModalOpen
                        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 24; topMargin: 18 }
                        Flickable {
                            anchors.fill: parent
                            contentWidth: width; contentHeight: bCol.implicitHeight + 20
                            clip: true; boundsBehavior: Flickable.StopAtBounds
                            Column {
                                id: bCol
                                width: Math.min(parent.width, 680)
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 14

                                RowLayout {
                                    width: parent.width
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text {
                                            text: "Google Contacts & Calendar Birthdays"
                                            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold
                                        }
                                        Text {
                                            text: "Sync birthdays from Google Contacts in 2 clicks, or add & manage birthdays right here."
                                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                        }
                                    }
                                    Pill {
                                        label: "Close"
                                        onClicked: root.bdayModalOpen = false
                                    }
                                }

                                Rectangle { width: parent.width; height: 1; color: root.pal.line }

                                Rectangle {
                                    width: parent.width; height: 36; radius: 10
                                    visible: root.bdayModalMsg !== ""
                                    color: Qt.alpha(root.pal.accent, 0.15)
                                    border.width: 1; border.color: root.pal.accent
                                    Row {
                                        anchors.centerIn: parent; spacing: 8
                                        Text {
                                            text: root.bdayModalMsg
                                            color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
                                        }
                                    }
                                }

                                // Section 1: 2-Click Google Contacts Auto-Sync
                                Column {
                                    width: parent.width; spacing: 8
                                    Text {
                                        text: "Why Google Calendar & Google Contacts Birthdays Differ — Fixed in 2 Clicks"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        width: parent.width; wrapMode: Text.WordWrap
                                        text: "Google Calendar's Birthdays calendar has no iCal address and often misses Google Contacts birthdays or birth years. Click '1. Open Google Contacts', then click Export → Export in your browser (Google CSV, Outlook CSV, or vCard all work!). Halcyon automatically grabs the download from ~/Downloads and imports every birthday with its birth year."
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                    Flow {
                                        width: parent.width; spacing: 10
                                        Pill {
                                            primary: true
                                            label: "1. Open Google Contacts & Auto-Import ↗"
                                            onClicked: root.openGoogleContacts()
                                        }
                                        Pill {
                                            label: "Scan ~/Downloads Now"
                                            onClicked: root.importBirthdays()
                                        }
                                        Pill {
                                            label: "Sync Google API"
                                            onClicked: root.gSync()
                                        }
                                        Pill {
                                            label: "Connect Google OAuth"
                                            onClicked: root.gConnect()
                                        }
                                    }
                                }

                                Rectangle { width: parent.width; height: 1; color: root.pal.line }

                                // Section 2: Quick Add Birthday in UI
                                Column {
                                    width: parent.width; spacing: 8
                                    Text {
                                        text: "Quick Add Birthday"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        text: "Add a birthday directly (use MM-DD like 05-12, or YYYY-MM-DD like 1998-05-12 to show age):"
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                    RowLayout {
                                        width: parent.width; spacing: 8
                                        Rectangle {
                                            Layout.preferredWidth: 165; height: 38; radius: 19
                                            color: Qt.alpha(root.pal.bg, 0.55)
                                            border.width: 1; border.color: bDateIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                            Text {
                                                anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                                visible: bDateIn.text === ""
                                                text: "MM-DD or YYYY-MM-DD"
                                                color: root.pal.muted; font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                            }
                                            TextInput {
                                                id: bDateIn
                                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: root.pal.text
                                                font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                                clip: true
                                            }
                                        }
                                        Rectangle {
                                            Layout.fillWidth: true; height: 38; radius: 19
                                            color: Qt.alpha(root.pal.bg, 0.55)
                                            border.width: 1; border.color: bNameIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                            Text {
                                                anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                                visible: bNameIn.text === ""
                                                text: "Person's Name (e.g. Alex Rivera)"
                                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                            }
                                            TextInput {
                                                id: bNameIn
                                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: root.pal.text
                                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                                clip: true
                                                onAccepted: {
                                                    if (bDateIn.text.trim() !== "" && bNameIn.text.trim() !== "") {
                                                        singleBdayProc.command = ["python3", root.script, "add-birthday", bNameIn.text.trim(), bDateIn.text.trim()]
                                                        singleBdayProc.running = true
                                                        bDateIn.text = ""; bNameIn.text = ""
                                                    }
                                                }
                                            }
                                        }
                                        Pill {
                                            Layout.preferredWidth: 86; height: 38; radius: 19
                                            primary: true
                                            label: "+ Add"
                                            onClicked: {
                                                if (bDateIn.text.trim() !== "" && bNameIn.text.trim() !== "") {
                                                    singleBdayProc.command = ["python3", root.script, "add-birthday", bNameIn.text.trim(), bDateIn.text.trim()]
                                                    singleBdayProc.running = true
                                                    bDateIn.text = ""; bNameIn.text = ""
                                                } else {
                                                    root.bdayModalMsg = "Enter both a date (MM-DD or YYYY-MM-DD) and a name."
                                                }
                                            }
                                        }
                                    }
                                }

                                Rectangle { width: parent.width; height: 1; color: root.pal.line }

                                // Section 3: Upcoming Birthdays List
                                Column {
                                    width: parent.width; spacing: 6
                                    RowLayout {
                                        width: parent.width
                                        Text {
                                            text: "Upcoming Birthdays (" + root.bdayList.length + ")"
                                            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                                        }
                                        Item { Layout.fillWidth: true }
                                        Pill {
                                            label: "Edit birthdays.txt"
                                            height: 28
                                            onClicked: Quickshell.execDetached(["xdg-open", Quickshell.env("HOME") + "/.config/Halcyon/birthdays.txt"])
                                        }
                                    }
                                    Repeater {
                                        model: root.bdayList
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: bCol.width; height: 36; radius: 10
                                            color: Qt.alpha(root.pal.surface, 0.75)
                                            border.width: 1; border.color: root.pal.line
                                            RowLayout {
                                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                                Text {
                                                    text: modelData.name
                                                    color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                                                    Layout.fillWidth: true; elide: Text.ElideRight
                                                }
                                                Text {
                                                    text: modelData.mmdd + (modelData.year ? (" (" + modelData.year + ")") : "")
                                                    color: root.pal.muted; font.family: root.pal.mono; font.pixelSize: root.pal.tCap
                                                }
                                                Text {
                                                    text: (modelData.daysUntil === 0 ? "Today!" : ("in " + modelData.daysUntil + "d")) + (modelData.ageNext ? (" · turns " + modelData.ageNext) : "")
                                                    color: modelData.daysUntil === 0 ? root.pal.accent : root.pal.accent2
                                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.DemiBold
                                                }
                                                Text {
                                                    text: "✕"
                                                    color: delBdayMa.containsMouse ? root.pal.accent2 : root.pal.muted
                                                    font.family: root.pal.uiFont; font.pixelSize: 13
                                                    MouseArea {
                                                        id: delBdayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            remBdayProc.command = ["python3", root.script, "remove-birthday", modelData.name]
                                                            remBdayProc.running = true
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
