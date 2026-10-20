import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Clipboard history.   >clipboard in the launcher (also `halcyon clipboard`, and the IPC call `clipboard`).
// A panel on the side of the screen (same place and look as the new-note panel) that lists what you copied lately. Type to search,
// Up / Down and Enter, or click a row: it goes back on the clipboard with wl-copy and the panel leaves, ready to paste.
//
// Pin (the little pin on a row) keeps a text entry on top of the list; pins survive Clear history (scripts/halcyon-clip.py keeps their text
// in ~/.local/state/island/clip-pins.json, readable only by you; do not pin a password).
// There is NO watcher in here and none was added for it. The history is cliphist's, filled by the two small `wl-paste --watch`
// processes that Settings > Startup & background > Clipboard history already starts. scripts/clip-store.sh (what they run) keeps
// a copy out of the history when the app marks it as a secret (password managers do). This file only runs the one-shot
// scripts/halcyon-clip.py while the panel is open, and nothing at all while it is closed (LazyLoader, no surface, no timer).
Scope {
    id: root
    property var pal
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property var opt: ({})                  // the island's settings: the stars follow the Desktop builder's direction, speed and colour
    property string spot: "tl"              // where the pop-out console opens (the panel goes to the other side)
    property bool open: false

    property var items: []
    property int total: 0
    property bool available: true           // cliphist + wl-clipboard are installed
    property bool watching: true            // the watchers are running (Settings > Startup & background)
    property bool loaded: false
    property string search: ""
    property string note: ""                // "Copied" / "Cleared", for a moment
    property bool confirmClear: false       // the first press on Clear history only asks

    readonly property bool panelRight: spot.charAt(1) !== "r"
    readonly property bool panelBottom: spot.charAt(0) === "b"
    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-clip.py"

    function show() { search = ""; note = ""; confirmClear = false; open = true; load() }
    function hide() { open = false; confirmClear = false }
    function close() { hide() }
    function toggle() { if (open) hide(); else show() }

    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    // ---- reading the list
    property bool reloadAgain: false
    function load() {
        if (fetchProc.running) { reloadAgain = true; return }
        fetchProc.running = true
    }
    Process {
        id: fetchProc
        command: ["python3", root.script, "json", "80"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    root.items = d.items || []
                    root.total = d.total || 0
                    root.available = d.available !== false
                    root.watching = d.watching !== false
                    root.loaded = true
                } catch (e) { /* a failed read keeps the list that is shown */ }
            }
        }
        onExited: { if (root.reloadAgain) { root.reloadAgain = false; root.load() } }
    }

    // ---- changes (delete, clear, turn the watchers on) go through one queue, then the list is read again
    property var queue: []
    function act(cmd) {
        queue = queue.concat([cmd])
        if (!actProc.running) nextAct()
    }
    function nextAct() {
        if (queue.length === 0) { load(); return }
        var c = queue[0]
        queue = queue.slice(1)
        actProc.command = c
        actProc.running = true
    }
    Process { id: actProc; onExited: root.nextAct() }

    function copyItem(it) {
        if (!it) return
        // one-shot and detached: the panel can leave at once, the copy finishes by itself
        Quickshell.execDetached(["python3", root.script, "copy", String(it.id)])
        note = "Copied"
        confirmClear = false
        leaveT.restart()
    }
    Timer { id: leaveT; interval: 380; onTriggered: root.hide() }

    function deleteItem(it) { if (it) act(["python3", root.script, "delete", String(it.id)]) }
    function pinItem(it) { if (it && !it.image) act(["python3", root.script, it.pin === true ? "unpin" : "pin", String(it.id)]) }
    function clearAll() {
        if (!confirmClear) { confirmClear = true; confirmT.restart(); return }
        confirmClear = false
        items = items.filter(function (e) { return e.pin === true }); total = 0     // pins stay
        note = "Cleared"
        act(["python3", root.script, "clear"])
    }
    Timer { id: confirmT; interval: 4000; onTriggered: root.confirmClear = false }
    function turnOn() {
        act(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/startup-conf.sh", "set", "CLIPBOARD", "1"])
        watching = true
    }

    readonly property var shown: {
        var q = search.trim().toLowerCase()
        if (!q) return items
        return items.filter(function (e) { return e.image ? "image picture".indexOf(q) >= 0 : (e.text || "").toLowerCase().indexOf(q) >= 0 })
    }

    // what a row says: a picture entry reads "Image  ·  png 800x600" instead of cliphist's [[ binary data ... ]]
    function rowText(e) {
        if (!e.image) return e.text
        var t = e.text || ""
        var a = t.indexOf("binary data"), b = t.lastIndexOf("]]")
        var detail = (a >= 0 && b > a) ? t.substring(a + 11, b).trim() : ""
        return "Image" + (detail !== "" ? "   \u00b7   " + detail : "")
    }

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-clipboard"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // a click anywhere outside the panel closes it
            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { sin.forceActiveFocus() }) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: 520
                    height: Math.min(qp.height - root.pal.boxTop - root.pal.boxEdge, 520)
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
                        count: 30
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 20
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                color: root.note !== "" ? root.pal.good : root.pal.accent
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                            }
                            Text {
                                text: "Clipboard"
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tTitle
                                font.weight: Font.DemiBold
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.note !== "" ? root.note : (root.total + (root.total === 1 ? " entry" : " entries"))
                                color: root.note !== "" ? root.pal.good : root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                                font.weight: root.note !== "" ? Font.Medium : Font.Normal
                            }
                            RoundBtn {
                                pal: root.pal
                                size: 28
                                glyph: String.fromCodePoint(0xF0156)
                                onClicked: root.hide()
                            }
                        }

                        // search
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
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
                                clip: true
                                color: root.pal.text
                                selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                selectedTextColor: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody + 1
                                onTextChanged: { root.search = text; list.currentIndex = 0 }
                                Keys.onPressed: e => {
                                    if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                                    else if (e.key === Qt.Key_Down) { if (list.currentIndex < root.shown.length - 1) list.currentIndex++; e.accepted = true }
                                    else if (e.key === Qt.Key_Up) { if (list.currentIndex > 0) list.currentIndex--; e.accepted = true }
                                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                        root.copyItem(root.shown[list.currentIndex]); e.accepted = true
                                    }
                                }
                                Text {
                                    visible: sin.text.length === 0
                                    text: "Search what you copied"
                                    color: root.pal.muted
                                    font: sin.font
                                }
                            }
                        }

                        // the watchers are off, or the tools are missing: say so instead of an empty list
                        Rectangle {
                            Layout.fillWidth: true
                            visible: root.loaded && (!root.available || !root.watching)
                            implicitHeight: warnRow.implicitHeight + 20
                            radius: root.pal.rMd
                            color: Qt.alpha(root.pal.warn, 0.10)
                            border.width: 1
                            border.color: Qt.alpha(root.pal.warn, 0.35)
                            RowLayout {
                                id: warnRow
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 12 }
                                spacing: 10
                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    text: !root.available ? "The history needs cliphist and wl-clipboard. Install them and it fills by itself."
                                                          : "Clipboard history is off, so nothing new is saved."
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                ActionChip {
                                    visible: root.available && !root.watching
                                    pal: root.pal
                                    label: "Turn on"
                                    implicitHeight: 30
                                    onClicked: root.turnOn()
                                }
                            }
                        }

                        // the list
                        ListView {
                            id: list
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.shown.length > 0
                            clip: true
                            spacing: 4
                            model: root.shown
                            currentIndex: 0
                            boundsBehavior: Flickable.StopAtBounds
                            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                            delegate: Rectangle {
                                id: row
                                required property var modelData
                                required property int index
                                width: ListView.view.width - 8
                                height: 42
                                radius: root.pal.rSm
                                readonly property bool cur: ListView.isCurrentItem
                                color: rowMa.containsMouse || cur ? Qt.alpha(root.pal.accent, 0.14) : Qt.alpha(root.pal.surface, 0.55)
                                border.width: 1
                                border.color: cur ? Qt.alpha(root.pal.accent, 0.45) : root.pal.lineSoft
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }

                                RowLayout {
                                    anchors { fill: parent; leftMargin: 12; rightMargin: 8 }
                                    spacing: 10
                                    Rectangle {
                                        Layout.preferredWidth: 3
                                        Layout.preferredHeight: 14
                                        radius: 1.5
                                        color: row.modelData.pin === true ? root.pal.accent : (row.modelData.image ? root.pal.accent2 : Qt.alpha(root.pal.muted, 0.5))
                                    }
                                    Text {
                                        visible: row.modelData.pin === true
                                        text: String.fromCodePoint(0xF0403)
                                        color: root.pal.accent
                                        font.family: root.pal.font
                                        font.pixelSize: 14
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: root.rowText(row.modelData)
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        color: row.modelData.image ? root.pal.accent2 : root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                    }
                                    RoundBtn {
                                        visible: !row.modelData.image && (rowMa.containsMouse || row.cur)
                                        pal: root.pal
                                        size: 24
                                        glyph: String.fromCodePoint(row.modelData.pin === true ? 0xF0404 : 0xF0403)
                                        onClicked: root.pinItem(row.modelData)
                                    }
                                    RoundBtn {
                                        visible: rowMa.containsMouse || row.cur
                                        pal: root.pal
                                        size: 24
                                        glyph: String.fromCodePoint(0xF0156)
                                        onClicked: root.deleteItem(row.modelData)
                                    }
                                }
                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    anchors.rightMargin: 68            // the pin and delete buttons keep their own clicks
                                    hoverEnabled: true
                                    onEntered: list.currentIndex = row.index
                                    onClicked: root.copyItem(row.modelData)
                                }
                            }

                        }

                        // an empty list says why (a sibling of the list, not inside it: a ListView would scroll it)
                        Text {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.shown.length === 0
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: !root.loaded ? "" : (!root.available ? "" : (root.search.trim() !== "" ? "Nothing copied matches that" : "Nothing copied yet"))
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                text: "Enter copies   \u00b7   Pin keeps it on top   \u00b7   Esc closes   \u00b7   Password-manager copies are not kept"
                                elide: Text.ElideRight
                                color: Qt.alpha(root.pal.muted, 0.85)
                                font.family: root.pal.uiFont
                                font.pixelSize: 10
                            }
                            ActionChip {
                                pal: root.pal
                                label: root.confirmClear ? "Click again to clear" : "Clear history"
                                on: root.confirmClear
                                disabled: root.total === 0
                                implicitHeight: 30
                                onClicked: root.clearAll()
                            }
                        }
                    }
                }
            }
        }
    }
}
