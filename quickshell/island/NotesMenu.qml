import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Notes.
//   Super + N  ->  a small panel on the side of the screen, over your windows, already waiting for the text of a new note:
//                  type, press Enter, it is saved and the panel goes away. Shift + Enter makes a new line, Esc closes.
//   >all notes ->  (launcher commands) every note in one window: search, filter, pin, tick off, copy, delete.
// Tasks: a note can be a task, with a time. Settings > Notes lets the local Ollama model sort new notes in the background
//   ("call mom at 6" = a task due 18:00, "idea: dark lock screen" = a plain note) and asks first or does it by itself. A task with a
//   time sends a notification when it is due (scripts/halcyon-notes.py + halcyon-notes-due.timer). Saving never waits for the model.
// The panel opens on the opposite side from the pop-out console (so the two never sit on top of each other), at the same height.
Scope {
    id: root
    property var pal
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property var opt: ({})                  // the island's settings: the stars follow the Desktop builder's direction, speed and colour
    property string spot: "tl"              // where the pop-out console opens (Desktop builder > Where the boxes open)
    property bool open: false
    property string mode: "quick"           // quick: the small new-note panel | all: the full list

    property var notes: []
    property string search: ""
    property string filter: "all"           // all | open | tasks | pinned | done
    property bool flash: false              // "Saved", for a moment, before the quick panel leaves

    readonly property bool panelRight: spot.charAt(1) !== "r"      // the console is on the left -> the notes panel goes right
    readonly property bool panelBottom: spot.charAt(0) === "b"

    function show() { mode = "quick"; flash = false; open = true; loadNotes() }
    function showAll() { mode = "all"; search = ""; filter = "all"; open = true; loadNotes() }
    function openAll() { mode = "all"; search = ""; filter = "all"; loadNotes() }      // from the panel: stays open, becomes the list
    function hide() { dropStaged(); open = false; flash = false }
    function close() { hide() }
    function toggle() { if (open) hide(); else show() }
    function toggleAll() { if (open && mode === "all") hide(); else showAll() }

    // the window outlives `open` for a moment so the panel can slide away
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    property bool reloadAgain: false
    property bool vlmOn: false                  // Settings > Notes > Describe pictures: shows the Describe button
    function loadNotes() {
        if (fetchProc.running) { reloadAgain = true; return }      // a list asked for while one is being read was dropped, and the old one stayed
        fetchProc.running = true
        if (!confProc.running) confProc.running = true
    }

    Process {
        id: confProc
        command: ["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "conf"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.vlmOn = !!JSON.parse(text).NOTES_VLM && !!JSON.parse(text).aiEnabled } catch (e) { } }
        }
    }

    Process {
        id: fetchProc
        command: ["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.notes = JSON.parse(text) }
                catch (e) { /* a failed read keeps the list that is shown instead of emptying it */ }
            }
        }
        onExited: { if (root.reloadAgain) { root.reloadAgain = false; root.loadNotes() } }
    }

    // every change (add, delete, pin, done) goes through one queue: a second one started while the first was still running
    // used to be lost (the process was busy, only its command was swapped), e.g. two quick pins or two notes added in a row
    property var queue: []
    function act(args) {
        queue = queue.concat([args])
        if (!actProc.running) nextAct()
    }
    function nextAct() {
        if (queue.length === 0) { loadNotes(); return }
        var a = queue[0]
        queue = queue.slice(1)
        actProc.command = ["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py"].concat(a)
        actProc.running = true
    }
    Process { id: actProc; onExited: root.nextAct() }

    function addNote(t) {
        var str = (t || "").trim()
        if (!str) return false
        act(["add", str])
        return true
    }
    // the quick panel: save, say so, leave
    function saveQuick(t) {
        if (stagedImage !== "") {
            // a pasted picture is waiting: it becomes the note, what is typed is its caption (may be empty)
            var cap = (t || "").trim()
            act(["image", stagedImage, cap || "Clipboard image"])
            stagedImage = ""
            flash = true
            saveT.restart()
            return true
        }
        if (!addNote(t)) return false
        flash = true
        saveT.restart()
        return true
    }
    Timer { id: saveT; interval: 620; onTriggered: root.hide() }

    function toggleTask(id) { act(["task", String(id)]) }
    function setDue(id, spec) { act(["due", String(id), spec]) }            // "+1h" | "18:00" | "tomorrow 09:00" | "none"
    function answerTask(id, yes) { act([yes ? "accept" : "dismiss", String(id)]) }
    function thinkNote(id) { act(["think", String(id)]) }                 // run the AI over the note again
    // what the AI says under a note (the script writes think = {state, why, at}); "thinking" counts only while it is fresh,
    // so a crashed helper can never leave "thinking ..." on a note for ever
    function aiThinking(n) { return !!n.think && n.think.state === "thinking" && (Date.now() / 1000 - (n.think.at || 0)) < 120 }
    // the title of a note in the list is ALWAYS what you wrote (or said). The AI overview is shown under it and never replaces it.
    function titleOf(n) {
        var t = n.text || ""
        return t !== "" ? t : (n.image ? "Image note" : (n.audio ? "Voice note" : ""))
    }
    function hasTitle(n) { return false }
    function aiLabel(n) { return (n.think && n.think.real) ? "Overview" : "AI" }      // real = a summary of the note, not a status line
    function aiLine(n) {
        if (!n.think) return ""
        if (n.think.state === "thinking") return aiThinking(n) ? "AI is thinking ..." : ""
        if (hasTitle(n)) return (n.think.why || "").split("\n").slice(1).join("\n")   // the first line is the title now: only the rest (bullets) goes under it
        return n.think.why || ""
    }
    function delNote(id) { act(["del", String(id)]) }
    function pinNote(id) { act(["pin", String(id)]) }
    function toggleDone(id) { act(["done", String(id)]) }

    readonly property int openCount: notes.filter(function (n) { return !n.done }).length
    readonly property int pinnedCount: notes.filter(function (n) { return n.pinned }).length
    readonly property int doneCount: notes.filter(function (n) { return n.done }).length
    readonly property int taskCount: notes.filter(function (n) { return n.task && !n.done }).length
    readonly property int suggestCount: notes.filter(function (n) { return !!n.suggest }).length

    // where the words of a search are found in a note: [] when some word is nowhere, else the places ("picture text", ...)
    function editOne(a, b) {                  // true when a and b differ by at most one letter (typo, missing or extra letter)
        if (a === b) return true
        var la = a.length, lb = b.length
        if (Math.abs(la - lb) > 1) return false
        var i = 0
        while (i < la && i < lb && a[i] === b[i]) i++
        if (la === lb) return a.substring(i + 1) === b.substring(i + 1)
        return la > lb ? a.substring(i + 1) === b.substring(i) : a.substring(i) === b.substring(i + 1)
    }
    function matchWhere(n, q) {
        var terms = q.split(/\s+/).filter(function (t) { return t.length > 0 })
        var fields = [
            { name: "note", txt: ((n.text || "") + " " + (n.transcript || "")).toLowerCase() },
            { name: "picture text", txt: ((n.ocr && n.ocr.text) || "").toLowerCase() },
            { name: "picture description", txt: ((n.describe && n.describe.text) || "").toLowerCase() },
            { name: "overview", txt: ((n.think && n.think.why) || "").toLowerCase() },
            { name: "summary", txt: ((n.summary && n.summary.text) || "").toLowerCase() }
        ]
        var where = []
        for (var t = 0; t < terms.length; t++) {
            var hit = false
            for (var f = 0; f < fields.length; f++) {
                if (fields[f].txt.indexOf(terms[t]) >= 0) { hit = true; if (where.indexOf(fields[f].name) < 0) where.push(fields[f].name) }
            }
            if (!hit && terms[t].length >= 5) {
                for (var g = 0; g < fields.length && !hit; g++) {
                    var ws = fields[g].txt.split(/\W+/)
                    for (var w = 0; w < ws.length; w++) {
                        if (ws[w].length >= 4 && root.editOne(terms[t], ws[w])) { hit = true; if (where.indexOf(fields[g].name) < 0) where.push(fields[g].name); break }
                    }
                }
            }
            if (!hit) return []
        }
        return where
    }
    // under a row while searching: where the words were found when it is not in the note itself ("Found in: picture text")
    function foundIn(n) {
        var q = search.trim().toLowerCase()
        if (!q) return ""
        var w = root.matchWhere(n, q)
        if (w.length === 0 || w.indexOf("note") >= 0) return ""
        return "Found in: " + w.join(", ")
    }

    readonly property var filteredNotes: {
        var q = search.trim().toLowerCase()
        var f = filter
        var out = notes.filter(function (n) {
            if (f === "open" && n.done) return false
            if (f === "done" && !n.done) return false
            if (f === "pinned" && !n.pinned) return false
            if (f === "tasks" && (!n.task || n.done)) return false
            return !q || root.matchWhere(n, q).length > 0
        })
        // pinned first, otherwise the order of the file (newest first)
        return out.map(function (n, i) { return { n: n, i: i } })
                  .sort(function (a, b) { return ((b.n.pinned ? 1 : 0) - (a.n.pinned ? 1 : 0)) || (a.i - b.i) })
                  .map(function (e) { return e.n })
    }

    // when a task is due, in the same words: "Today 18:00" / "Tomorrow 09:00" / "20 Oct 14:30"
    function dueText(ts) {
        if (!ts) return ""
        var d = new Date(ts * 1000)
        var t0 = new Date(); t0.setHours(0, 0, 0, 0)
        var day = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() - t0.getTime()) / 86400000)
        var hm = Qt.formatTime(d, "hh:mm")
        return day === 0 ? "Today " + hm : day === 1 ? "Tomorrow " + hm : day === -1 ? "Yesterday " + hm : Qt.formatDate(d, "d MMM") + " " + hm
    }
    function isOverdue(n) { return !!n.due && !n.done && n.due * 1000 < Date.now() }
    // the quick choices when you press Remind on a task (the script reads them: "18:00" means the next 18:00)
    function remindChoices() {
        var h = new Date().getHours()
        return [
            { t: "In 30 min", s: "+30m" },
            { t: "In 1 hour", s: "+1h" },
            { t: "Later today", s: "later" },                 // a few gentle nudges during the day instead of one time
            { t: (h < 18 ? "Today" : "Tomorrow") + " 18:00", s: "18:00" },
            { t: "Tomorrow 09:00", s: "tomorrow 09:00" },
            { t: "No reminder", s: "none" }
        ]
    }

    // "Today 14:30" / "Yesterday 09:05" / "18 Oct 21:40"
    function whenOf(n) {
        if (!n.created) return n.date || ""
        var d = new Date(n.created * 1000)
        var t0 = new Date(); t0.setHours(0, 0, 0, 0)
        var day = Math.floor((t0.getTime() - new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()) / 86400000)
        var hm = Qt.formatTime(d, "hh:mm")
        return day <= 0 ? "Today " + hm : day === 1 ? "Yesterday " + hm : Qt.formatDate(d, "d MMM") + " " + hm
    }

    // Multimedia notes support (Audio playback, voice recording, image clip)
    property string playingAudioId: ""
    Process {
        id: audioPlayProc
        onExited: root.playingAudioId = ""
    }
    function togglePlayAudio(id, path) {
        if (playingAudioId === id) {
            audioPlayProc.running = false
            playingAudioId = ""
        } else {
            audioPlayProc.running = false
            playingAudioId = id
            audioPlayProc.command = ["pw-play", path]
            audioPlayProc.running = true
        }
    }

    // ---- voice notes: record (stays on while you work elsewhere) -> speech to text -> the AI
    readonly property string notesPy: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py"
    property bool isRecording: false
    property bool stopping: false            // the recorder is being closed: a status read in that moment must not switch the card back on
    property real recStart: 0                // when it began (ms)
    property real nowMs: Date.now()
    property string notice: ""               // a short message in the panel header ("No microphone ...")
    function say(t) { notice = t; noticeT.restart() }
    Timer { id: noticeT; interval: 4500; onTriggered: root.notice = "" }
    Timer { id: stopT; interval: 4000; onTriggered: root.stopping = false }
    Timer { interval: 1000; repeat: true; running: root.isRecording; triggeredOnStart: true; onTriggered: root.nowMs = Date.now() }

    Process {
        id: recStartProc
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.indexOf("REC_STARTED") < 0) {
                    root.isRecording = false
                    var m = text.match(/REC_FAILED:(.*)/)
                    root.say(m ? m[1] : "The recording could not start")
                }
            }
        }
    }
    // is a recording really running? (asked when the shell starts, e.g. after a reload, and every 3 s while one is on:
    // a recorder that died - no microphone, sound server restarted - must not leave the card up for ever)
    Process {
        id: recStatProc
        command: ["python3", root.notesPy, "rec-status"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.stopping) return
                try {
                    var st = JSON.parse(text.trim().split("\n").pop())
                    if (st.recording) { if (!root.isRecording) root.recStart = (st.started || 0) * 1000; root.isRecording = true }
                    else if (root.isRecording) root.isRecording = false
                } catch (e) { /* keep what is shown */ }
            }
        }
    }
    Timer { interval: 3000; repeat: true; running: root.isRecording; onTriggered: if (!recStatProc.running) recStatProc.running = true }
    Component.onCompleted: recStatProc.running = true

    // the dots: start -> the panel leaves and a small card stays on every workspace until Stop; Stop -> saved, written down, sorted by the AI
    function toggleRecord(text) {
        if (isRecording) {
            isRecording = false
            stopping = true; stopT.restart()
            Quickshell.execDetached(["python3", notesPy, "rec-stop"])
            recStopTimer.restart()
        } else {
            stopping = false
            isRecording = true
            recStart = Date.now(); nowMs = recStart
            recStartProc.command = ["python3", notesPy, "rec-start", text || ""]
            recStartProc.running = true
            hide()
        }
    }
    function cancelRecord() {                // throw the recording away
        isRecording = false
        stopping = true; stopT.restart()
        Quickshell.execDetached(["python3", notesPy, "rec-cancel"])
    }
    Timer {
        id: recStopTimer
        interval: 900
        onTriggered: root.loadNotes()
    }
    function transcribeNote(id) { Quickshell.execDetached(["python3", notesPy, "transcribe", String(id)]) }
    // what the speech-to-text says under a voice note
    function summaryNote(id) { Quickshell.execDetached(["python3", notesPy, "summary", String(id)]) }
    function summaryBusy(n) { return !!n.summary && n.summary.state === "working" && (Date.now() / 1000 - (n.summary.at || 0)) < 600 }
    function summaryText(n) { return (n.summary && n.summary.state === "done" && n.summary.text) ? n.summary.text : "" }
    function summaryStatus(n) {
        if (!n.summary) return ""
        if (n.summary.state === "working") return summaryBusy(n) ? "Writing the summary ..." : ""
        if (n.summary.state === "done") return ""
        return n.summary.msg || ""
    }
    // the short overview under a note; the generic "plain note" line says nothing and is left out
    function overviewText(n) {
        var l = aiLine(n)
        return (n.think && (n.think.why || "").indexOf("Looks like a plain note") === 0 && !aiThinking(n)) ? "" : l
    }
    function panelShown(n) {
        return overviewText(n) !== "" || summaryText(n) !== "" || summaryStatus(n) !== ""
            || (!!n.image && (ocrText(n) !== "" || ocrLine(n) !== "" || descLine(n) !== "")) || (!!n.describe && n.describe.state === "done")
    }
    function ocrNote(id) { Quickshell.execDetached(["python3", notesPy, "ocr", String(id)]) }
    function describeNote(id) { Quickshell.execDetached(["python3", notesPy, "describe", String(id)]) }
    function ocrBusy(n) { return !!n.ocr && n.ocr.state === "working" && (Date.now() / 1000 - (n.ocr.at || 0)) < 120 }
    function descBusy(n) { return !!n.describe && n.describe.state === "working" && (Date.now() / 1000 - (n.describe.at || 0)) < 330 }
    function ocrText(n) { return (n.ocr && n.ocr.state === "done" && n.ocr.text) ? n.ocr.text : "" }
    function ocrLine(n) {                     // a status under a picture note: reading it, or why it could not be read
        if (!n.ocr) return ""
        if (n.ocr.state === "working") return ocrBusy(n) ? "Reading the text in the picture ..." : ""
        if (n.ocr.state === "empty") return "No text found in the picture."
        if (n.ocr.state === "done") return ""
        return n.ocr.msg || ""
    }
    function descLine(n) {
        if (!n.describe) return ""
        if (n.describe.state === "working") return descBusy(n) ? "Looking at the picture ..." : ""
        if (n.describe.state === "done") return ""
        return n.describe.msg || ""
    }
    function sttBusy(n) { return !!n.stt && n.stt.state === "working" && (Date.now() / 1000 - (n.stt.at || 0)) < 900 }
    function sttLine(n) {
        if (!n.stt) return ""
        if (n.stt.state === "working") return sttBusy(n) ? "Writing it down ..." : ""
        if (n.stt.state === "done") return ""
        return n.stt.msg || ""
    }

    // Ctrl + V in the quick panel: a picture on the clipboard is shown in the panel and waits for a caption; Enter then saves it
    // as a note (the picture alone is fine too), the x or Esc throws it away. Anything else on the clipboard is pasted as text.
    Process {
        id: pasteProc
        stdout: StdioCollector {
            onStreamFinished: {
                var m = text.match(/CLIP_STAGED:(.+)/)
                if (m) {
                    root.dropStaged()                // a second picture replaces the first
                    root.stagedImage = m[1].trim()
                    root.pasteDone = false
                    root.pasteText = false
                } else if (text.indexOf("CLIP_OK") >= 0) {
                    root.pasteDone = true
                    root.flash = true
                    saveT.restart()
                    root.loadNotes()
                } else {
                    root.pasteDone = false
                    root.pasteText = true            // no picture there: the field pastes the text
                }
            }
        }
    }
    property bool pasteDone: false
    property bool pasteText: false
    property string stagedImage: ""          // a pasted picture that is waiting for its caption (not a note until Enter)
    function dropStaged() {
        if (stagedImage !== "") Quickshell.execDetached(["python3", notesPy, "clip-drop", stagedImage])
        stagedImage = ""
    }
    function pasteClipboard(caption) {
        if (pasteProc.running) return
        pasteDone = false; pasteText = false
        pasteProc.command = ["python3", notesPy, "clip-stage"]
        pasteProc.running = true
    }

    // the recording card: where the panel opens, on every workspace, until the recording is stopped. It takes no keyboard focus
    // and covers only itself, so you can keep working underneath
    LazyLoader {
        active: root.isRecording && !(root.open && root.mode === "quick")
        PanelWindow {
            id: recWin
            visible: true
            anchors { top: !root.panelBottom; bottom: root.panelBottom; left: !root.panelRight; right: root.panelRight }
            margins {
                top: Math.max(0, root.pal.boxTop - 24)
                bottom: Math.max(0, root.pal.boxEdge - 24)
                left: Math.max(0, 22 - 24)
                right: Math.max(0, 22 - 24)
            }
            implicitWidth: 384
            implicitHeight: 100
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-notes"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            Glass {
                pal: root.pal
                anchors.centerIn: parent
                width: 336
                height: 68
                radius: root.pal.rXl
                opacityBody: root.pal.solid ? 1 : 0.92
                border.color: Qt.alpha(root.pal.bad, 0.55)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 12
                    spacing: 12
                    Rectangle {
                        Layout.preferredWidth: 12
                        Layout.preferredHeight: 12
                        radius: 6
                        color: root.pal.bad
                        SequentialAnimation on opacity {
                            running: true
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        spacing: 2
                        Text {
                            Layout.fillWidth: true
                            text: "Recording voice note"
                            elide: Text.ElideRight
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            font.weight: Font.DemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            readonly property int secs: Math.max(0, Math.floor((root.nowMs - root.recStart) / 1000))
                            text: Math.floor(secs / 60) + ":" + (secs % 60 < 10 ? "0" : "") + (secs % 60) + "   \u00b7   becomes a note when you stop"
                            elide: Text.ElideRight
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                        }
                    }
                    ActionChip {
                        pal: root.pal
                        label: "Stop"
                        on: true
                        implicitHeight: 32
                        onClicked: root.toggleRecord("")
                    }
                    RoundBtn {
                        pal: root.pal
                        size: 30
                        glyph: String.fromCodePoint(0xF01B4)
                        onClicked: root.cancelRecord()
                    }
                }
            }
        }
    }

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-notes"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // a click anywhere outside the panel closes it; the full list also dims what is behind it
            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(root.pal.bg, root.mode === "all" ? 0.45 : 0)
                opacity: root.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }
                Behavior on color { ColorAnimation { duration: root.pal.dMed } }
                MouseArea { anchors.fill: parent; onClicked: root.hide() }
            }

            Loader {
                anchors.fill: parent
                active: root.mode === "quick"
                sourceComponent: quickPanel
            }
            Loader {
                anchors.fill: parent
                active: root.mode === "all"
                sourceComponent: allNotes
            }
        }
    }

    // =====================================================================================================================
    //  SUPER + N: the new-note panel
    // =====================================================================================================================
    Component {
        id: quickPanel
        Item {
            id: qp
            property bool ready: false
            readonly property real target: (ready && root.open) ? 1 : 0
            property real reveal: 0
            onTargetChanged: reveal = target
            Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Component.onCompleted: { ready = true; Qt.callLater(function () { qin.forceActiveFocus() }) }

            Glass {
                id: panel
                pal: root.pal
                width: 520
                height: col.implicitHeight + 40
                radius: root.pal.rXl
                opacityBody: root.pal.solid ? 1 : 0.90
                border.color: Qt.alpha(root.pal.accent, 0.40)
                opacity: qp.reveal
                x: root.panelRight ? qp.width - width - 22 + (1 - qp.reveal) * width * 0.4
                                   : 22 - (1 - qp.reveal) * width * 0.4
                y: root.panelBottom ? qp.height - height - root.pal.boxEdge : root.pal.boxTop
                MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                NoteStars {
                    anchors.fill: parent
                    anchors.margins: 1
                    pal: root.pal
                    opt: root.opt
                    running: root.stars && root.open
                    count: 38
                }

                ColumnLayout {
                    id: col
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
                    spacing: 14

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: root.flash ? root.pal.good : root.pal.accent
                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        }
                        Text {
                            text: "New note"
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tTitle
                            font.weight: Font.DemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                            text: root.notice !== "" ? root.notice : (root.flash ? "Saved" : (root.notes.length + (root.notes.length === 1 ? " note" : " notes")))
                            color: root.notice !== "" ? root.pal.bad : (root.flash ? root.pal.good : root.pal.muted)
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            font.weight: (root.flash || root.notice !== "") ? Font.Medium : Font.Normal
                        }
                        RoundBtn {
                            pal: root.pal
                            size: 28
                            glyph: String.fromCodePoint(0xF0156)
                            onClicked: root.hide()
                        }
                    }

                    // a pasted picture, waiting for its caption
                    Rectangle {
                        visible: root.stagedImage !== ""
                        Layout.fillWidth: true
                        Layout.preferredHeight: visible ? 120 : 0
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.bg, 0.55)
                        border.width: 1
                        border.color: root.pal.lineSoft
                        clip: true
                        Image {
                            anchors.fill: parent
                            anchors.margins: 6
                            source: root.stagedImage !== "" ? "file://" + root.stagedImage : ""
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: false
                        }
                        RoundBtn {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 6
                            pal: root.pal
                            size: 24
                            glyph: String.fromCodePoint(0xF0156)
                            onClicked: root.dropStaged()
                        }
                    }

                    // the text of the note
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(88, Math.min(190, qin.contentHeight + 28))
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.bg, 0.55)
                        border.width: 1
                        border.color: qin.activeFocus ? root.pal.accent : root.pal.lineSoft
                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }

                        Flickable {
                            id: fl
                            anchors.fill: parent
                            anchors.margins: 14
                            contentWidth: width
                            contentHeight: qin.contentHeight
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            function ensureVisible(r) {
                                if (contentY >= r.y) contentY = r.y
                                else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
                            }
                            TextEdit {
                                id: qin
                                width: fl.width
                                wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                                color: root.pal.text
                                selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                selectedTextColor: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody + 1
                                onCursorRectangleChanged: fl.ensureVisible(cursorRectangle)
                                Connections {
                                    target: root
                                    function onPasteTextChanged() { if (root.pasteText) { qin.paste(); root.pasteText = false } }
                                    function onPasteDoneChanged() { if (root.pasteDone) { qin.text = ""; root.pasteDone = false } }
                                }
                                Keys.onPressed: e => {
                                    if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                                    else if ((e.matches(StandardKey.Paste) || ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_V))) {
                                        // a picture on the clipboard is saved as a note; otherwise the text is pasted when the check answers
                                        root.pasteClipboard(qin.text)
                                        e.accepted = true
                                    }
                                    else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                        if (root.saveQuick(qin.text)) qin.text = ""
                                        e.accepted = true
                                    }
                                }
                                Text {
                                    visible: qin.text.length === 0
                                    text: root.stagedImage !== "" ? "Add a note for this picture, then press Enter" : "Type a note, then press Enter"
                                    color: root.pal.muted
                                    font: qin.font
                                }
                            }
                        }
                    }

                    // the latest notes, one line each
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        visible: root.notes.length > 0
                        Text {
                            text: "LATEST"
                            color: Qt.alpha(root.pal.muted, 0.8)
                            font.family: root.pal.uiFont
                            font.pixelSize: 9
                            font.letterSpacing: 1.2
                        }
                        Repeater {
                            model: root.notes.filter(function (n) { return !n.done }).slice(0, 3)
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 8
                                Rectangle {
                                    Layout.preferredWidth: 3
                                    Layout.preferredHeight: 12
                                    radius: 1.5
                                    color: modelData.pinned ? root.pal.accent : Qt.alpha(root.pal.muted, 0.4)
                                }
                                Text {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: root.titleOf(modelData).replace(/\s*\n\s*/g, "  ")
                                    elide: Text.ElideRight
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                Text {
                                    visible: !!modelData.due
                                    text: root.dueText(modelData.due)
                                    color: root.isOverdue(modelData) ? root.pal.bad : root.pal.accent
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Enter saves   \u00b7   Ctrl + V adds an image, then type its note   \u00b7   Shift + Enter new line   \u00b7   Esc closes"
                        elide: Text.ElideRight
                        color: Qt.alpha(root.pal.muted, 0.85)
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Item { Layout.fillWidth: true }
                        ActionChip {
                            pal: root.pal
                            glyph: String.fromCodePoint(0xF036D)
                            label: root.isRecording ? "Stop rec" : "Voice"
                            on: root.isRecording
                            implicitHeight: 30
                            onClicked: { root.toggleRecord(qin.text); if (root.isRecording) qin.text = "" }
                        }
                        ActionChip {
                            pal: root.pal
                            label: "All notes"
                            implicitHeight: 30
                            onClicked: root.openAll()
                        }
                        ActionChip {
                            pal: root.pal
                            label: "Save"
                            implicitHeight: 30
                            on: qin.text.trim().length > 0
                            onClicked: { if (root.saveQuick(qin.text)) qin.text = "" }
                        }
                    }
                }
            }
        }
    }

    // =====================================================================================================================
    //  >all notes: the whole list
    // =====================================================================================================================
    Component {
        id: allNotes
        Item {
            id: an
            property bool ready: false
            readonly property real target: (ready && root.open) ? 1 : 0
            property real reveal: 0
            onTargetChanged: reveal = target
            Behavior on reveal { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Component.onCompleted: { ready = true; Qt.callLater(function () { sin.forceActiveFocus() }) }

            Glass {
                id: card
                pal: root.pal
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 700)
                height: Math.min(parent.height - 80, 700)
                radius: root.pal.rXl
                opacityBody: root.pal.solid ? 1 : 0.90
                border.color: Qt.alpha(root.pal.accent, 0.35)
                opacity: an.reveal
                scale: 0.96 + 0.04 * an.reveal
                MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                NoteStars {
                    anchors.fill: parent
                    anchors.margins: 1
                    pal: root.pal
                    opt: root.opt
                    running: root.stars && root.open
                    count: 56
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 14

                    // header
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Rectangle { width: 8; height: 8; radius: 4; color: root.pal.accent }
                        Text {
                            text: "Notes"
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: 18
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.openCount + " open" + (root.taskCount > 0 ? "   \u00b7   " + root.taskCount + (root.taskCount === 1 ? " task" : " tasks") : "") + (root.doneCount > 0 ? "   \u00b7   " + root.doneCount + " done" : "")
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                        }
                        Item { Layout.fillWidth: true }
                        ActionChip {
                            pal: root.pal
                            label: "New note"
                            implicitHeight: 30
                            onClicked: root.show()
                        }
                        RoundBtn {
                            pal: root.pal
                            size: 30
                            glyph: String.fromCodePoint(0xF0156)
                            onClicked: root.hide()
                        }
                    }

                    // search
                    Rectangle {
                        Layout.fillWidth: true
                        height: 38
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.bg, 0.55)
                        border.width: 1
                        border.color: sin.activeFocus ? root.pal.accent : root.pal.lineSoft
                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                        TextInput {
                            id: sin
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.pal.text
                            selectionColor: Qt.alpha(root.pal.accent, 0.45)
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            clip: true
                            onTextChanged: root.search = text
                            Keys.onEscapePressed: root.hide()
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Search notes, voice, picture text"
                                color: root.pal.muted
                                font: sin.font
                                visible: !sin.text
                            }
                        }
                    }

                    // filter
                    Row {
                        spacing: 8
                        Repeater {
                            model: [
                                { id: "all", t: "All", n: root.notes.length },
                                { id: "open", t: "Open", n: root.openCount },
                                { id: "tasks", t: "Tasks", n: root.taskCount },
                                { id: "pinned", t: "Pinned", n: root.pinnedCount },
                                { id: "done", t: "Done", n: root.doneCount }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool on: root.filter === modelData.id
                                width: fl2.implicitWidth + 24
                                height: 28
                                radius: 14
                                color: on ? Qt.alpha(root.pal.accent, 0.18) : (fma.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, 0.7))
                                border.width: 1
                                border.color: on ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                Text {
                                    id: fl2
                                    anchors.centerIn: parent
                                    text: modelData.t + "  " + modelData.n
                                    color: parent.on ? root.pal.accent : root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                    font.weight: parent.on ? Font.Medium : Font.Normal
                                }
                                MouseArea {
                                    id: fma
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.filter = modelData.id
                                }
                            }
                        }
                    }

                    // the list
                    ListView {
                        id: listView
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 8
                        model: root.filteredNotes
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: noteRow
                            required property var modelData
                            property bool copied: false
                            property bool picking: false               // the Remind choices are open
                            property bool copiedOcr: false
                            Timer { id: ocrCopyT; interval: 1400; onTriggered: noteRow.copiedOcr = false }
                            function markCopied() { copied = true; copiedT.restart() }
                            width: listView.width
                            height: Math.max(58, noteCol.implicitHeight + 32)
                            radius: root.pal.rMd
                            color: modelData.pinned ? Qt.alpha(root.pal.accent, 0.11) : Qt.alpha(root.pal.bg, 0.5)
                            border.width: 1
                            border.color: modelData.pinned ? Qt.alpha(root.pal.accent, 0.40) : root.pal.lineSoft
                            clip: true
                            HoverHandler { id: rowHover }
                            Timer { id: copiedT; interval: 1300; onTriggered: noteRow.copied = false }

                            Rectangle {      // pinned notes carry an accent bar on the left
                                visible: noteRow.modelData.pinned
                                x: 0; y: 12
                                width: 3; height: parent.height - 24
                                radius: 1.5
                                color: root.pal.accent
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 12
                                spacing: 12

                                // done box
                                MouseArea {
                                    Layout.preferredWidth: 22
                                    Layout.preferredHeight: 22
                                    Layout.alignment: Qt.AlignVCenter
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleDone(noteRow.modelData.id)
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 18; height: 18; radius: 5
                                        color: noteRow.modelData.done ? root.pal.accent : "transparent"
                                        border.width: 1.5
                                        border.color: noteRow.modelData.done ? root.pal.accent : root.pal.muted
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        Loader {
                                            anchors.fill: parent
                                            active: !!noteRow.modelData.done
                                            sourceComponent: Canvas {
                                                onPaint: {
                                                    var c = getContext("2d")
                                                    c.clearRect(0, 0, width, height)
                                                    c.strokeStyle = String(root.pal.bg)
                                                    c.lineWidth = 2
                                                    c.lineCap = "round"
                                                    c.lineJoin = "round"
                                                    c.beginPath()
                                                    c.moveTo(width * 0.24, height * 0.52)
                                                    c.lineTo(width * 0.43, height * 0.70)
                                                    c.lineTo(width * 0.76, height * 0.30)
                                                    c.stroke()
                                                }
                                            }
                                        }
                                    }
                                }

                                // text and time
                                ColumnLayout {
                                    id: noteCol
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 0
                                    Layout.minimumWidth: 0
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 10
                                    // ---- the note itself: the voice player, then what you wrote or said, then when ----
                                    // audio player
                                    Rectangle {
                                        visible: !!noteRow.modelData.audio
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        Layout.preferredHeight: 34
                                        clip: true
                                        radius: 17
                                        color: Qt.alpha(root.pal.surface, 0.75)
                                        border.width: 1
                                        border.color: (root.playingAudioId === noteRow.modelData.id) ? root.pal.accent : root.pal.lineSoft
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            anchors.rightMargin: 12
                                            spacing: 8
                                            RoundBtn {
                                                pal: root.pal
                                                size: 24
                                                glyph: (root.playingAudioId === noteRow.modelData.id) ? String.fromCodePoint(0xF04DB) : String.fromCodePoint(0xF040A)
                                                onClicked: root.togglePlayAudio(noteRow.modelData.id, noteRow.modelData.audio)
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                text: (root.playingAudioId === noteRow.modelData.id) ? "Playing voice note..." : "Voice note"
                                                color: (root.playingAudioId === noteRow.modelData.id) ? root.pal.accent : root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap
                                                font.weight: (root.playingAudioId === noteRow.modelData.id) ? Font.Medium : Font.Normal
                                            }
                                            Text {
                                                text: String.fromCodePoint(0xF036D)
                                                color: (root.playingAudioId === noteRow.modelData.id) ? root.pal.accent : root.pal.muted
                                                font.family: root.pal.font
                                                font.pixelSize: 13
                                            }
                                        }
                                    }

                                    // speech to text: while it writes, or why it could not
                                    Text {
                                        visible: !!noteRow.modelData.audio && root.sttLine(noteRow.modelData) !== ""
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        text: root.sttLine(noteRow.modelData)
                                        color: root.sttBusy(noteRow.modelData) ? Qt.alpha(root.pal.muted, 0.95) : root.pal.bad
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                        font.italic: true
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        spacing: 4
                                        Text {
                                            visible: !!noteRow.modelData.audio && !!noteRow.modelData.transcript
                                            text: "TRANSCRIPT"
                                            color: Qt.alpha(root.pal.muted, 0.75)
                                            font.family: root.pal.uiFont
                                            font.pixelSize: 9
                                            font.letterSpacing: 1.3
                                            font.weight: Font.Medium
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: root.titleOf(noteRow.modelData)
                                            color: noteRow.modelData.done ? root.pal.muted : root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                            font.strikeout: !!noteRow.modelData.done
                                            lineHeight: 1.1
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        }
                                        // when it was saved, and the task tags
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                height: 18
                                                verticalAlignment: Text.AlignVCenter
                                                text: root.whenOf(noteRow.modelData)
                                                color: Qt.alpha(root.pal.muted, 0.8)
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 10
                                            }
                                            NotePill { visible: !!noteRow.modelData.task; pal: root.pal; text: "Task" }
                                            NotePill {
                                                visible: !!noteRow.modelData.due
                                                pal: root.pal
                                                text: (root.isOverdue(noteRow.modelData) ? "Overdue  " : "Due  ") + root.dueText(noteRow.modelData.due)
                                                tone: noteRow.modelData.done ? root.pal.muted : root.isOverdue(noteRow.modelData) ? root.pal.bad : root.pal.accent
                                            }
                                            NotePill {
                                                visible: !!noteRow.modelData.later && !noteRow.modelData.done
                                                pal: root.pal
                                                text: "Later today" + (noteRow.modelData.nudges ? "  \u00b7  nudged " + noteRow.modelData.nudges + (noteRow.modelData.nudges === 1 ? " time" : " times") : "")
                                            }
                                        }
                                    }

                                    // image preview
                                    Rectangle {
                                        visible: !!noteRow.modelData.image
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        Layout.maximumWidth: 360
                                        Layout.preferredHeight: 140
                                        radius: root.pal.rSm
                                        clip: true
                                        color: Qt.alpha(root.pal.bg, 0.45)
                                        border.width: 1
                                        border.color: imgMa.containsMouse ? root.pal.accent : root.pal.lineSoft
                                        Image {
                                            anchors.fill: parent
                                            source: noteRow.modelData.image ? (noteRow.modelData.image.indexOf("://") >= 0 ? noteRow.modelData.image : "file://" + noteRow.modelData.image) : ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            sourceSize.width: 500
                                        }
                                        MouseArea {
                                            id: imgMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (noteRow.modelData.image) Quickshell.execDetached(["xdg-open", noteRow.modelData.image])
                                            }
                                        }
                                    }

                                    // the model thinks this is a task (Settings > Notes > ask first)
                                    Flow {
                                        visible: !!noteRow.modelData.suggest
                                        Layout.fillWidth: true
                                        spacing: 8
                                        topPadding: 4
                                        Text {
                                            height: 26
                                            verticalAlignment: Text.AlignVCenter
                                            text: "Looks like a task" + (noteRow.modelData.suggest && noteRow.modelData.suggest.due ? ", due " + root.dueText(noteRow.modelData.suggest.due) : "")
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                        ActionChip { pal: root.pal; label: "Make task"; implicitHeight: 26; on: true; onClicked: root.answerTask(noteRow.modelData.id, true) }
                                        ActionChip { pal: root.pal; label: "Keep as note"; implicitHeight: 26; onClicked: root.answerTask(noteRow.modelData.id, false) }
                                    }

                                    // ---- what the computer made of it, in one quiet panel under your own words ----
                                    Rectangle {
                                        visible: root.panelShown(noteRow.modelData)
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        implicitHeight: aiCol.implicitHeight + 22
                                        radius: root.pal.rSm
                                        color: Qt.alpha(root.pal.text, 0.045)
                                        ColumnLayout {
                                            id: aiCol
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.margins: 11
                                            spacing: 12
                                            NoteSection {
                                                pal: root.pal
                                                label: root.aiThinking(noteRow.modelData) ? "AI" : root.aiLabel(noteRow.modelData)
                                                body: root.overviewText(noteRow.modelData)
                                                pulse: root.aiThinking(noteRow.modelData) && root.open
                                                italic: root.aiThinking(noteRow.modelData)
                                            }
                                            NoteSection {
                                                pal: root.pal
                                                label: "Summary"
                                                body: root.summaryText(noteRow.modelData) !== "" ? root.summaryText(noteRow.modelData) : root.summaryStatus(noteRow.modelData)
                                                italic: root.summaryText(noteRow.modelData) === ""
                                                pulse: root.summaryBusy(noteRow.modelData) && root.open
                                            }
                                            NoteSection {
                                                pal: root.pal
                                                label: "Picture description"
                                                body: root.descText(noteRow.modelData) !== "" ? root.descText(noteRow.modelData) : root.descLine(noteRow.modelData)
                                                italic: root.descText(noteRow.modelData) === ""
                                            }
                                            NoteSection {
                                                pal: root.pal
                                                label: "Text in picture"
                                                body: root.ocrText(noteRow.modelData) !== "" ? root.ocrText(noteRow.modelData) : (noteRow.modelData.image ? root.ocrLine(noteRow.modelData) : "")
                                                italic: root.ocrText(noteRow.modelData) === ""
                                                collapsedLines: root.ocrText(noteRow.modelData) !== "" ? 6 : 0
                                            }
                                        }
                                    }
                                    Text {
                                        visible: root.foundIn(noteRow.modelData) !== ""
                                        text: root.foundIn(noteRow.modelData)
                                        color: root.pal.accent
                                        font.family: root.pal.uiFont
                                        font.pixelSize: 10
                                        font.weight: Font.Medium
                                    }

                                    // Remind: when to send the notification
                                    Flow {
                                        visible: noteRow.picking
                                        Layout.fillWidth: true
                                        spacing: 6
                                        topPadding: 4
                                        Repeater {
                                            model: noteRow.picking ? root.remindChoices() : []
                                            delegate: ActionChip {
                                                required property var modelData
                                                pal: root.pal
                                                label: modelData.t
                                                implicitHeight: 26
                                                onClicked: { root.setDue(noteRow.modelData.id, modelData.s); noteRow.picking = false }
                                            }
                                        }
                                    }

                                    // actions: faint until the pointer is over the note. Yours first, a thin line, then the ones that ask the AI or read a picture
                                    Flow {
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        spacing: 2
                                        opacity: rowHover.hovered ? 1 : 0.4
                                        Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
                                        Repeater {
                                            model: [
                                                { k: "pin", t: noteRow.modelData.pinned ? "Unpin" : "Pin" },
                                                { k: "task", t: noteRow.modelData.task ? "Note" : "Task" },
                                                { k: "remind", t: noteRow.picking ? "Close" : "Remind", hide: !noteRow.modelData.task },
                                                { k: "copy", t: noteRow.copied ? "Copied" : "Copy" },
                                                { k: "del", t: "Delete" },
                                                { k: "sep" },
                                                { k: "stt", t: root.sttBusy(noteRow.modelData) ? "Writing" : "To text", hide: !noteRow.modelData.audio },
                                                { k: "think", t: root.aiThinking(noteRow.modelData) ? "Thinking" : "Overview" },
                                                { k: "summary", t: root.summaryBusy(noteRow.modelData) ? "Writing" : (noteRow.modelData.summary && noteRow.modelData.summary.state === "done" ? "Summarise again" : "Summarise") },
                                                { k: "describe", t: root.descBusy(noteRow.modelData) ? "Looking" : (noteRow.modelData.describe && noteRow.modelData.describe.state === "done" ? "Describe again" : "Describe"), hide: !noteRow.modelData.image || !root.vlmOn },
                                                { k: "ocr", t: root.ocrBusy(noteRow.modelData) ? "Reading" : "Read text", hide: !noteRow.modelData.image || root.ocrText(noteRow.modelData) !== "" },
                                                { k: "copyocr", t: noteRow.copiedOcr ? "Copied" : "Copy text", hide: root.ocrText(noteRow.modelData) === "" }
                                            ]
                                            delegate: Item {
                                                required property var modelData
                                                visible: !modelData.hide
                                                width: visible ? (modelData.k === "sep" ? 13 : at.implicitWidth + 16) : 0
                                                height: 26
                                                Rectangle {          // the thin line between the two groups
                                                    visible: modelData.k === "sep"
                                                    anchors.centerIn: parent
                                                    width: 1; height: 14
                                                    color: Qt.alpha(root.pal.muted, 0.35)
                                                }
                                                Rectangle {
                                                    visible: modelData.k !== "sep"
                                                    anchors.fill: parent
                                                    radius: 13
                                                    color: ama.containsMouse ? Qt.alpha(modelData.k === "del" ? root.pal.bad : root.pal.accent, 0.16) : "transparent"
                                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                                    Text {
                                                        id: at
                                                        anchors.centerIn: parent
                                                        text: modelData.t || ""
                                                        color: ama.containsMouse ? (modelData.k === "del" ? root.pal.bad : root.pal.accent) : root.pal.muted
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: 10
                                                        font.weight: Font.Medium
                                                    }
                                                    MouseArea {
                                                        id: ama
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            var n = noteRow.modelData
                                                            if (modelData.k === "pin") root.pinNote(n.id)
                                                            else if (modelData.k === "del") root.delNote(n.id)
                                                            else if (modelData.k === "task") root.toggleTask(n.id)
                                                            else if (modelData.k === "stt") { if (!root.sttBusy(n)) root.transcribeNote(n.id) }
                                                            else if (modelData.k === "think") { if (!root.aiThinking(n)) root.thinkNote(n.id) }
                                                            else if (modelData.k === "summary") { if (!root.summaryBusy(n)) root.summaryNote(n.id) }
                                                            else if (modelData.k === "describe") { if (!root.descBusy(n)) root.describeNote(n.id) }
                                                            else if (modelData.k === "ocr") { if (!root.ocrBusy(n)) root.ocrNote(n.id) }
                                                            else if (modelData.k === "copyocr") { Quickshell.execDetached(["wl-copy", root.ocrText(n)]); noteRow.copiedOcr = true; ocrCopyT.restart() }
                                                            else if (modelData.k === "remind") noteRow.picking = !noteRow.picking
                                                            else {
                                                                Quickshell.execDetached(["wl-copy", n.text || ""])
                                                                noteRow.markCopied()
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

                        // empty state
                        Item {
                            visible: root.filteredNotes.length === 0
                            width: listView.width
                            height: 200
                            Column {
                                anchors.centerIn: parent
                                spacing: 8
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.search || root.filter !== "all" ? "Nothing matches" : "No notes yet"
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tTitle
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.search ? "Try a different search" : (root.filter !== "all" ? "Pick another filter above" : "Press Super + N to write the first one")
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                            }
                        }
                    }

                    // footer
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            text: "From a terminal:  notes <text>"
                            color: Qt.alpha(root.pal.muted, 0.85)
                            font.family: root.pal.uiFont
                            font.pixelSize: 10
                        }
                        Item { Layout.fillWidth: true }
                        ActionChip {
                            pal: root.pal
                            label: "Clear completed"
                            implicitHeight: 30
                            visible: root.doneCount > 0
                            onClicked: root.act(["clear"])
                        }
                    }
                }
            }
        }
    }
}
