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
    function dueOf(ts) {                       // "18:00" today, "Tomorrow 09:00", "20 Oct 14:30"
        var d = new Date(ts * 1000), t0 = new Date(); t0.setHours(0, 0, 0, 0)
        var day = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() - t0.getTime()) / 86400000)
        var hm = Qt.formatTime(d, "hh:mm")
        return day === 0 ? hm : day === 1 ? "Tomorrow " + hm : Qt.formatDate(d, "d MMM") + " " + hm
    }
    readonly property int most: Math.round(opt("max", 4))
    readonly property real wide: opt("width", 290)
    property var notes: []
    property var calEvents: []

    property string today: Qt.formatDate(new Date(), "dddd, MMM d")     // the heading (it was drawn once and stayed on yesterday after midnight)
    property string lastNotes: ""                                      // the raw answers: the lists are only rebuilt when they really changed
    property string lastCal: ""
    property int beat: 0
    function refresh() {
        today = Qt.formatDate(new Date(), "dddd, MMM d")
        if (!notesProc.running) notesProc.running = true
        // the calendar file only changes when it syncs: read it every minute, not every 15 seconds
        if (events && (beat++ % 4 === 0) && !calProc.running) calProc.running = true
    }
    onEventsChanged: if (live) { beat = 0; refresh() }
    Timer { interval: 15000; repeat: true; running: root.live; triggeredOnStart: true; onTriggered: root.refresh() }

    Process {
        id: notesProc
        command: ["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "json"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastNotes) return
                try {
                    var all = JSON.parse(text)
                    root.notes = all.filter(function (n) { return !n.done }).sort(function (a, b) { return (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) })
                    root.lastNotes = text
                } catch (e) { /* a failed read keeps what is shown instead of blanking the list */ }
            }
        }
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

    // what is shown: events first, then notes, up to `most` lines
    readonly property var lines: {
        var out = []
        if (events) for (var i = 0; i < calEvents.length && out.length < most; i++) {
            var e = calEvents[i]
            out.push({ kind: "event", t: (e.allDay ? "" : Qt.formatTime(new Date(e.start * 1000), "hh:mm") + "  ") + (e.title || ""), pinned: false })
        }
        for (var j = 0; j < notes.length && out.length < most; j++) out.push({ kind: "note", t: (notes[j].text || "") + (notes[j].task && notes[j].due ? "  \u00b7  " + dueOf(notes[j].due) : ""), pinned: !!notes[j].pinned })
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
                    WLbl { b: root; text: modelData.kind === "event" ? "•" : (modelData.pinned ? "★" : "›"); color: modelData.pinned ? "#f5a623" : root.accent; font.pixelSize: root.sz(12); anchors.verticalCenter: parent.verticalCenter }
                    WLbl { id: ln; b: root; width: parent.width - root.sz(20); text: modelData.t; elide: Text.ElideRight; font.pixelSize: root.sz(12); anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
        Rectangle {      // opens the real new-note panel; nothing is typed in the widget
            visible: root.addRow
            width: parent.width
            height: addTxt.implicitHeight + root.sz(10)
            radius: root.sz(10)
            color: addMa.containsMouse ? Qt.alpha(root.accent, 0.18) : Qt.alpha(root.fg, 0.05)
            border.width: 1
            border.color: Qt.alpha(root.accent, addMa.containsMouse ? 0.5 : 0.22)
            WLbl { id: addTxt; b: root; anchors.centerIn: parent; text: "+  Add a note"; color: root.accent; font.pixelSize: root.sz(11) }
            MouseArea {
                id: addMa
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.editing && !!root.env
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.env.deskAct("notes")
            }
        }
        WLbl { b: root; visible: root.lines.length === 0; width: parent.width; text: "Nothing to show. Super + N adds a note."; color: root.dim; font.pixelSize: root.sz(11); wrapMode: Text.WordWrap }
    }
}
