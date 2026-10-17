import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Super + N: Quick Notes Overlay
Scope {
    id: root
    property var pal
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool open: false

    property var notes: []
    property string search: ""

    function show() {
        open = true
        loadNotes()
        Qt.callLater(function () { input.forceActiveFocus() })
    }
    function hide() { open = false }
    function toggle() { if (open) hide(); else show() }

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
        if (!str) return
        act(["add", str])
        input.text = ""
    }
    function delNote(id) { act(["del", String(id)]) }
    function pinNote(id) { act(["pin", String(id)]) }
    function toggleDone(id) { act(["done", String(id)]) }

    readonly property var filteredNotes: {
        var q = search.trim().toLowerCase()
        if (!q) return notes
        return notes.filter(function (n) {
            return (n.text || "").toLowerCase().indexOf(q) >= 0
        })
    }

    PanelWindow {
        id: win
        visible: root.open
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-notes"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Backdrop dimmer
        Rectangle {
            anchors.fill: parent
            color: Qt.alpha(root.pal.bg, 0.45)
            MouseArea { anchors.fill: parent; onClicked: root.hide() }
        }

        Glass {
            id: card
            pal: root.pal
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 560)
            height: Math.min(parent.height - 80, 680)
            radius: root.pal.rXl
            opacityBody: root.pal.solid ? 1 : 0.88
            border.color: Qt.alpha(root.pal.accent, 0.35)
            scale: root.open ? 1 : 0.95
            Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Rectangle { width: 8; height: 8; radius: 4; color: root.pal.accent }
                    Text {
                        text: "Quick Notes"
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "(" + root.notes.length + ")"
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tCap
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "Esc to close"
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                    }
                    RoundBtn {
                        pal: root.pal
                        glyph: String.fromCodePoint(0xF0156)
                        onClicked: root.hide()
                    }
                }

                // Add note row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.fillWidth: true
                        height: 40
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.bg, 0.6)
                        border.width: 1
                        border.color: input.activeFocus ? root.pal.accent : root.pal.lineSoft

                        TextInput {
                            id: input
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            clip: true
                            Keys.onReturnPressed: root.addNote(input.text)
                            Keys.onEscapePressed: root.hide()

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Add a note or task (Enter to save)..."
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                                visible: !input.text && !input.activeFocus
                            }
                        }
                    }
                    ActionChip {
                        pal: root.pal
                        label: "Add"
                        on: input.text.trim().length > 0
                        onClicked: root.addNote(input.text)
                    }
                }

                // Search / Filter row (only shown if > 3 notes)
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.notes.length > 3
                    spacing: 8
                    Rectangle {
                        Layout.fillWidth: true
                        height: 32
                        radius: root.pal.rSm
                        color: Qt.alpha(root.pal.bg, 0.4)
                        border.width: 1
                        border.color: root.pal.lineSoft
                        TextInput {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            clip: true
                            onTextChanged: root.search = text
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Search notes..."
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                                visible: !parent.text
                            }
                        }
                    }
                }

                // Notes List
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
                        width: listView.width
                        height: Math.max(54, noteCol.implicitHeight + 16)
                        radius: root.pal.rMd
                        color: modelData.pinned ? Qt.alpha(root.pal.accent, 0.12) : Qt.alpha(root.pal.bg, 0.5)
                        border.width: 1
                        border.color: modelData.pinned ? Qt.alpha(root.pal.accent, 0.45) : root.pal.lineSoft

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 10
                            spacing: 10

                            // Done checkbox
                            MouseArea {
                                Layout.preferredWidth: 20
                                Layout.preferredHeight: 20
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleDone(noteRow.modelData.id)
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 18; height: 18; radius: 4
                                    color: noteRow.modelData.done ? root.pal.accent : "transparent"
                                    border.width: 1.5
                                    border.color: noteRow.modelData.done ? root.pal.accent : root.pal.muted
                                    Text {
                                        visible: noteRow.modelData.done
                                        anchors.centerIn: parent
                                        text: "✓"
                                        color: root.pal.bg
                                        font.pixelSize: 11
                                        font.weight: Font.Bold
                                    }
                                }
                            }

                            // Text & date
                            ColumnLayout {
                                id: noteCol
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    Layout.fillWidth: true
                                    text: noteRow.modelData.text || ""
                                    color: noteRow.modelData.done ? root.pal.muted : root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                    font.strikeout: noteRow.modelData.done
                                    wrapMode: Text.WordWrap
                                }
                                Text {
                                    text: noteRow.modelData.date || ""
                                    color: Qt.alpha(root.pal.muted, 0.7)
                                    font.family: root.pal.uiFont
                                    font.pixelSize: 9
                                }
                            }

                            // Pin button
                            MouseArea {
                                Layout.preferredWidth: 26
                                Layout.preferredHeight: 26
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.pinNote(noteRow.modelData.id)
                                Text {
                                    anchors.centerIn: parent
                                    text: "★"
                                    color: noteRow.modelData.pinned ? "#f5a623" : Qt.alpha(root.pal.muted, 0.4)
                                    font.pixelSize: 15
                                }
                            }

                            // Copy button
                            MouseArea {
                                Layout.preferredWidth: 26
                                Layout.preferredHeight: 26
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Quickshell.execDetached(["wl-copy", noteRow.modelData.text || ""])
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: "📋"
                                    font.pixelSize: 12
                                    opacity: 0.65
                                }
                            }

                            // Delete button
                            MouseArea {
                                Layout.preferredWidth: 26
                                Layout.preferredHeight: 26
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.delNote(noteRow.modelData.id)
                                Text {
                                    anchors.centerIn: parent
                                    text: "✕"
                                    color: Qt.alpha(root.pal.muted, 0.6)
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                }
                            }
                        }
                    }

                    // Empty state
                    Item {
                        visible: root.filteredNotes.length === 0
                        width: listView.width
                        height: 200
                        Column {
                            anchors.centerIn: parent
                            spacing: 8
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "📝"
                                font.pixelSize: 32
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.search ? "No matching notes found" : "No notes yet"
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                                font.weight: Font.DemiBold
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.search ? "Try a different search query" : "Type above or enter 'notes : <text>' in the console"
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                            }
                        }
                    }
                }

                // Footer
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "Tip: Type 'notes : <text>' in any terminal or quick console."
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                    }
                    Item { Layout.fillWidth: true }
                    ActionChip {
                        pal: root.pal
                        label: "Clear completed"
                        visible: root.notes.some(function (n) { return n.done })
                        onClicked: root.act(["clear"])
                    }
                }
            }
        }
    }
}
