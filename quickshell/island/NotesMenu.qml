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
    function hide() { open = false; flash = false }
    function close() { hide() }
    function toggle() { if (open) hide(); else show() }
    function toggleAll() { if (open && mode === "all") hide(); else showAll() }

    // the window outlives `open` for a moment so the panel can slide away
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    property bool reloadAgain: false
    function loadNotes() {
        if (fetchProc.running) { reloadAgain = true; return }      // a list asked for while one is being read was dropped, and the old one stayed
        fetchProc.running = true
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
    function aiLine(n) {
        if (!n.think) return ""
        if (n.think.state === "thinking") return aiThinking(n) ? "AI is thinking ..." : ""
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

    readonly property var filteredNotes: {
        var q = search.trim().toLowerCase()
        var f = filter
        var out = notes.filter(function (n) {
            if (f === "open" && n.done) return false
            if (f === "done" && !n.done) return false
            if (f === "pinned" && !n.pinned) return false
            if (f === "tasks" && (!n.task || n.done)) return false
            return !q || (n.text || "").toLowerCase().indexOf(q) >= 0
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
                        Item { Layout.fillWidth: true }
                        Text {
                            text: root.flash ? "Saved" : (root.notes.length + (root.notes.length === 1 ? " note" : " notes"))
                            color: root.flash ? root.pal.good : root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            font.weight: root.flash ? Font.Medium : Font.Normal
                        }
                        RoundBtn {
                            pal: root.pal
                            size: 28
                            glyph: String.fromCodePoint(0xF0156)
                            onClicked: root.hide()
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
                                wrapMode: TextEdit.Wrap
                                color: root.pal.text
                                selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                selectedTextColor: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody + 1
                                onCursorRectangleChanged: fl.ensureVisible(cursorRectangle)
                                Keys.onPressed: e => {
                                    if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                                    else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                        if (root.saveQuick(qin.text)) qin.text = ""
                                        e.accepted = true
                                    }
                                }
                                Text {
                                    visible: qin.text.length === 0
                                    text: "Type a note, then press Enter"
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
                                    text: (modelData.text || "").replace(/\s*\n\s*/g, "  ")
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

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            text: "Enter saves   \u00b7   Shift + Enter new line   \u00b7   Esc closes"
                            color: Qt.alpha(root.pal.muted, 0.85)
                            font.family: root.pal.uiFont
                            font.pixelSize: 10
                        }
                        Item { Layout.fillWidth: true }
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
                                text: "Search your notes"
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
                            width: listView.width
                            height: Math.max(58, noteCol.implicitHeight + 24)
                            radius: root.pal.rMd
                            color: modelData.pinned ? Qt.alpha(root.pal.accent, 0.11) : Qt.alpha(root.pal.bg, 0.5)
                            border.width: 1
                            border.color: modelData.pinned ? Qt.alpha(root.pal.accent, 0.40) : root.pal.lineSoft
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
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 3
                                    Text {
                                        Layout.fillWidth: true
                                        text: noteRow.modelData.text || ""
                                        color: noteRow.modelData.done ? root.pal.muted : root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        font.strikeout: !!noteRow.modelData.done
                                        wrapMode: Text.Wrap
                                    }
                                    Row {
                                        spacing: 10
                                        Text {
                                            visible: !!noteRow.modelData.task
                                            text: "Task"
                                            color: root.pal.accent
                                            font.family: root.pal.uiFont
                                            font.pixelSize: 10
                                            font.weight: Font.Medium
                                        }
                                        Text {
                                            text: root.whenOf(noteRow.modelData)
                                            color: Qt.alpha(root.pal.muted, 0.75)
                                            font.family: root.pal.uiFont
                                            font.pixelSize: 10
                                        }
                                        Text {
                                            visible: !!noteRow.modelData.due
                                            text: (root.isOverdue(noteRow.modelData) ? "Overdue  " : "Due  ") + root.dueText(noteRow.modelData.due)
                                            color: noteRow.modelData.done ? Qt.alpha(root.pal.muted, 0.75)
                                                 : root.isOverdue(noteRow.modelData) ? root.pal.bad : root.pal.accent
                                            font.family: root.pal.uiFont
                                            font.pixelSize: 10
                                            font.weight: Font.Medium
                                        }
                                        Text {
                                            visible: !!noteRow.modelData.later && !noteRow.modelData.done
                                            text: "Later today" + (noteRow.modelData.nudges ? "  \u00b7  nudged " + noteRow.modelData.nudges + (noteRow.modelData.nudges === 1 ? " time" : " times") : "")
                                            color: root.pal.accent
                                            font.family: root.pal.uiFont
                                            font.pixelSize: 10
                                            font.weight: Font.Medium
                                        }
                                    }

                                    // what the AI made of this note (Settings > Notes > Sort new notes into tasks): a short line right under it
                                    Text {
                                        id: aiText
                                        visible: root.aiLine(noteRow.modelData) !== ""
                                        Layout.fillWidth: true
                                        text: (root.aiThinking(noteRow.modelData) ? "" : "AI  \u00b7  ") + root.aiLine(noteRow.modelData)
                                        color: Qt.alpha(root.pal.muted, 0.95)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                        font.italic: true
                                        wrapMode: Text.Wrap
                                        SequentialAnimation on opacity {
                                            running: root.aiThinking(noteRow.modelData) && root.open
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                                            onStopped: aiText.opacity = 1
                                        }
                                    }

                                    // the model thinks this is a task (Settings > Notes > ask first)
                                    Row {
                                        visible: !!noteRow.modelData.suggest
                                        spacing: 8
                                        topPadding: 4
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "Looks like a task" + (noteRow.modelData.suggest && noteRow.modelData.suggest.due ? ", due " + root.dueText(noteRow.modelData.suggest.due) : "")
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                        ActionChip { pal: root.pal; label: "Make task"; implicitHeight: 26; on: true; onClicked: root.answerTask(noteRow.modelData.id, true) }
                                        ActionChip { pal: root.pal; label: "Keep as note"; implicitHeight: 26; onClicked: root.answerTask(noteRow.modelData.id, false) }
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
                                }

                                // actions: faint until the pointer is over the note
                                Row {
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 4
                                    opacity: rowHover.hovered ? 1 : 0.4
                                    Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
                                    Repeater {
                                        model: [
                                            { k: "pin", t: noteRow.modelData.pinned ? "Unpin" : "Pin" },
                                            { k: "task", t: noteRow.modelData.task ? "Note" : "Task" },
                                            { k: "think", t: root.aiThinking(noteRow.modelData) ? "Thinking" : "Think", hide: false },
                                            { k: "remind", t: noteRow.picking ? "Close" : "Remind", hide: !noteRow.modelData.task },
                                            { k: "copy", t: noteRow.copied ? "Copied" : "Copy" },
                                            { k: "del", t: "Delete" }
                                        ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            visible: !modelData.hide
                                            width: visible ? at.implicitWidth + 16 : 0
                                            height: 26
                                            radius: 13
                                            color: ama.containsMouse ? Qt.alpha(modelData.k === "del" ? root.pal.bad : root.pal.accent, 0.16) : "transparent"
                                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                            Text {
                                                id: at
                                                anchors.centerIn: parent
                                                text: modelData.t
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
                                                    if (modelData.k === "pin") root.pinNote(noteRow.modelData.id)
                                                    else if (modelData.k === "del") root.delNote(noteRow.modelData.id)
                                                    else if (modelData.k === "task") root.toggleTask(noteRow.modelData.id)
                                                    else if (modelData.k === "think") { if (!root.aiThinking(noteRow.modelData)) root.thinkNote(noteRow.modelData.id) }
                                                    else if (modelData.k === "remind") noteRow.picking = !noteRow.picking
                                                    else {
                                                        Quickshell.execDetached(["wl-copy", noteRow.modelData.text || ""])
                                                        noteRow.copied = true
                                                        copiedT.restart()
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
