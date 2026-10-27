import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// "Notes & agenda": your pinned notes (scripts/halcyon-notes.py) and, if you want, what is left of today's calendar (gcal.py).
// This is the old desktop notes widget, now one of many. Super + N still opens the full notes manager.
//   glass (a list) | cards
WBase {
    id: root

    readonly property bool events: opt("events", false) === true
    readonly property bool addRow: opt("add", true) === true
    readonly property bool quietHints: !!(pal && pal.hideHints)     // Settings > Look > Hide explanations: no "Super + N ..." line, the add row is just a small +
    function dueOf(ts) {                       // "18:00" today, "Tomorrow 09:00", "20 Oct 14:30"
        var d = new Date(ts * 1000), t0 = new Date(); t0.setHours(0, 0, 0, 0)
        var day = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() - t0.getTime()) / 86400000)
        var hm = Qt.formatTime(d, Qt.locale().timeFormat(Locale.ShortFormat))
        return day === 0 ? hm : day === 1 ? "Tomorrow " + hm : Qt.formatDate(d, "d MMM") + " " + hm
    }
    readonly property color taskColor: accent             // tasks (notes with a job / a reminder) are drawn with a small ring in the accent colour, so they match any wallpaper
    property real nowMs: Date.now()                       // moves on every refresh, so "overdue" turns red by itself
    readonly property int most: Math.round(opt("max", 4))
    readonly property real wide: opt("width", 290)
    property var notes: []
    property var calEvents: []

    property string today: Qt.formatDate(new Date(), "dddd, MMM d")     // the heading (it was drawn once and stayed on yesterday after midnight)
    property string lastNotes: ""                                      // the raw answers: the lists are only rebuilt when they really changed
    property string lastCal: ""
    property int beat: 0
    function refresh() {
        nowMs = Date.now()
        today = Qt.formatDate(new Date(), "dddd, MMM d")
        notesFile.reload()
        // the calendar file only changes when it syncs: read it every minute, not every 15 seconds
        if (events && (beat++ % 4 === 0) && !calProc.running) calProc.running = true
    }
    onEventsChanged: if (live) { beat = 0; refresh() }
    Timer { interval: 15000; repeat: true; running: root.live; triggeredOnStart: true; onTriggered: root.refresh() }

    // notes.json is read here, not through `halcyon-notes.py json` (which only prints the same file): no Python start every 15 s.
    // A change shows at once (watchChanges); the timer's reload also catches a save that replaced the file under the watch.
    function takeNotes(text) {
        if (text === root.lastNotes) return
        try {
            var all = text.trim() === "" ? [] : JSON.parse(text)
            if (!Array.isArray(all)) return
            root.notes = all.filter(function (n) { return !n.done }).sort(function (a, b) { return (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) })
            root.lastNotes = text
        } catch (e) { /* a failed read (a save half written) keeps what is shown instead of blanking the list */ }
    }
    FileView {
        id: notesFile
        path: root.live ? Quickshell.env("HOME") + "/.local/state/island/notes.json" : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.takeNotes(text())
        onLoadFailed: err => { if (err === FileViewError.FileNotFound) root.takeNotes("[]") }
    }
    Process {
        id: calProc
        command: ["python3", Quickshell.env("HOME") + "/.config/Halcyon/quickshell/island/scripts/gcal.py", "events"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(text)
                    var now = Date.now() / 1000
                    var d = new Date(); d.setHours(23, 59, 59, 0)
                    var endOfDay = d.getTime() / 1000
                    var done = data.done || []
                    var list = (data.events || []).filter(function (e) { return e.end > now && e.start <= endOfDay && done.indexOf(e.id) < 0 }).sort(function (a, b) { return a.start - b.start })
                    var key = JSON.stringify(list)          // events that ended drop out; the list is only swapped when it really differs
                    if (key !== root.lastCal) { root.lastCal = key; root.calEvents = list }
                } catch (e) { /* keep the last good list */ }
            }
        }
    }

    // A note that is too long for this widget is shown by its AI summary (the full summary's opening, else the short overview under the note),
    // and by its own words, cut short, when the AI has written neither (no model installed, AI off, not summarised yet). This is only what
    // the widget draws: the notes manager (Super + N, >notes) always shows the whole note.
    readonly property int cap: Math.max(50, Math.round(110 * wide / 290))      // about three lines at this width
    function clip(t) {
        t = String(t).replace(/\s+/g, " ").trim()
        if (t.length <= cap) return t
        var cut = t.lastIndexOf(" ", cap)
        return t.substring(0, cut > cap * 0.6 ? cut : cap).replace(/[\s,;:.\-]+$/, "") + "\u2026"
    }
    function gist(s) {                        // the first two lines of a summary, without the list marks and bold
        var l = String(s).split("\n").map(function (x) { return x.replace(/^\s*([-*\u2022]|\d+[.)]|#+)\s*/, "").replace(/\*\*/g, "").trim() }).filter(function (x) { return x !== "" })
        return l.slice(0, 2).join("  \u00b7  ")
    }
    function brief(n) {
        var raw = String(n.text || "")
        var flat = raw.replace(/\s+/g, " ").trim()
        if (flat.length <= cap && (raw.match(/\n/g) || []).length <= 2) return raw
        var sum = n.summary && n.summary.state === "done" && n.summary.text ? gist(n.summary.text) : ""
        var why = n.think && n.think.state === "done" && n.think.why ? String(n.think.why).trim() : ""
        return clip(sum !== "" ? sum : (why !== "" && why !== flat ? why : flat))
    }

    // what is shown: events first, then notes, up to `most` lines
    readonly property int hiddenCount: Math.max(0, notes.length + (events ? calEvents.length : 0) - lines.length)
    readonly property var lines: {
        var out = []
        if (events) for (var i = 0; i < calEvents.length && out.length < most; i++) {
            var e = calEvents[i]
            out.push({ kind: "event", t: (e.allDay ? "" : Qt.formatTime(new Date(e.start * 1000), "hh:mm") + "  ") + (e.title || ""), pinned: false })
        }
        var rank = function (n) {
            if (!n.task) return n.pinned ? 2 : 3
            return (n.due && !n.reminded && n.due * 1000 < nowMs) ? 0 : 1
        }
        var sorted = notes.slice().sort(function (a, b) {
            var d = rank(a) - rank(b)
            if (d !== 0) return d
            if (a.task && b.task) return (a.due || 9e12) - (b.due || 9e12)
            return 0
        })
        for (var j = 0; j < sorted.length && out.length < most; j++) {
            var n = sorted[j]
            var badge = (n.image ? " img" : "") + (n.audio ? " voice" : "")
            var noteTitle = brief(n) + badge + (n.task && n.due ? "  \u00b7  " + dueOf(n.due) + (n.repeat ? " \u21bb" : "") : "")
            out.push({ kind: n.task ? "task" : "note", t: noteTitle, pinned: !!n.pinned, id: n.id || "",
                       overdue: !!(n.task && n.due && !n.reminded && n.due * 1000 < nowMs) })
        }
        return out
    }

    implicitWidth: wide - 28
    implicitHeight: col.implicitHeight
    Column {
        id: col
        width: parent.width
        spacing: root.sz(10)
        Row {
            spacing: root.sz(8)
            Rectangle { width: root.sz(7); height: width; radius: width / 2; color: root.accent; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.today; font.pixelSize: root.sz(13); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.events ? "Calendar & notes" : "Quick notes"; color: root.dim; font.pixelSize: root.sz(10); anchors.verticalCenter: parent.verticalCenter }
        }
        Rectangle { width: parent.width; height: 1; color: root.track }
        Repeater {
            model: root.lines
            delegate: Rectangle {
                required property var modelData
                width: col.width
                height: ln.implicitHeight + (root.style === "cards" ? root.sz(14) : 0)
                radius: root.sz(10)
                color: root.style === "cards" ? Qt.alpha(root.fg, 0.07) : "transparent"
                Row {
                    anchors.fill: parent
                    anchors.leftMargin: root.style === "cards" ? root.sz(10) : 0
                    anchors.rightMargin: root.style === "cards" ? root.sz(10) : 0
                    spacing: root.sz(8)
                    Item {          // task: a small ring (click = done); event / note / pinned: the usual glyph
                        width: root.sz(12); height: root.sz(14); anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            visible: modelData.kind === "task"
                            anchors.centerIn: parent
                            width: root.sz(8); height: width; radius: width / 2
                            color: ringMa.containsMouse ? Qt.alpha(ringCol, 0.55) : "transparent"
                            border.width: 1.5
                            border.color: ringCol
                            readonly property color ringCol: modelData.overdue ? "#ff6b6b" : root.taskColor
                        }
                        WLbl { b: root; visible: modelData.kind !== "task"; anchors.centerIn: parent
                               text: modelData.kind === "event" ? "\u2022" : (modelData.pinned ? "\u2605" : "\u203a")
                               color: modelData.pinned && modelData.kind !== "event" ? "#f5a623" : root.accent; font.pixelSize: root.sz(12) }
                        MouseArea {
                            id: ringMa
                            anchors.fill: parent; anchors.margins: -root.sz(3)
                            hoverEnabled: true
                            enabled: modelData.kind === "task" && modelData.id !== "" && !root.editing && !!root.env
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: { Quickshell.execDetached(["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "done", modelData.id]); root.lastNotes = ""; root.refresh() }
                        }
                    }
                    WLbl { id: ln; b: root; width: parent.width - root.sz(20); color: modelData.kind === "task" ? (modelData.overdue ? Qt.tint(root.fg, Qt.alpha("#ff6b6b", 0.35)) : root.fg) : root.fg; text: modelData.t; wrapMode: Text.Wrap; font.pixelSize: root.sz(12); anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
        Rectangle {      // opens the real new-note panel; nothing is typed in the widget
            visible: root.addRow
            width: root.quietHints ? height : parent.width
            height: addTxt.implicitHeight + root.sz(10)
            radius: root.sz(10)
            color: addMa.containsMouse ? Qt.alpha(root.accent, 0.18) : Qt.alpha(root.fg, 0.05)
            border.width: 1
            border.color: Qt.alpha(root.accent, addMa.containsMouse ? 0.5 : 0.22)
            WLbl { id: addTxt; b: root; anchors.centerIn: parent; text: root.quietHints ? "+" : "+  Add a note"; color: root.accent; font.pixelSize: root.sz(11) }
            MouseArea {
                id: addMa
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.editing && !!root.env
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.env.deskAct("notes")
            }
        }
        WLbl { b: root; visible: root.hiddenCount > 0; text: "+" + root.hiddenCount + " more"; color: root.dim; font.pixelSize: root.sz(10) }
        WLbl { b: root; visible: root.lines.length === 0; width: parent.width; text: root.quietHints ? "Nothing to show" : "Nothing to show. Super + N adds a note."; color: root.dim; font.pixelSize: root.sz(11); wrapMode: Text.WordWrap }
    }
}
