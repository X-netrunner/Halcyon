import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Clipboard history.   >clipboard in the launcher (also `halcyon clipboard`, and the IPC call `clipboard`).
// A panel on the side of the screen (same place and look as the new-note panel) that lists what you copied lately. Type to search,
// Up / Down and Enter, or click a row: it goes back on the clipboard with wl-copy and the panel leaves, ready to paste.
//
// AI (the sparkle on a text row): summarise or rewrite that entry with the local model (scripts/halcyon-ai.py clip); the answer
// shows in the panel, Copy puts it on the clipboard. Text read from a screenshot (Screenshot panel > Text) lands here too, so it works on that.
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

    // ---- where the panel opens: at the mouse pointer (like the Windows clipboard), or on the side of the screen when that is off / unknown
    property bool atCursor: opt.clipAtCursor !== false
    property real curX: -1                  // pointer position inside the monitor it is on (logical px); -1 = unknown
    property real curY: -1
    property string curScreen: ""           // that monitor's name, so the panel opens on the right screen
    property bool pending: false            // asked to open, waiting for the pointer position (a few ms)
    readonly property bool followCursor: atCursor && curX >= 0 && curY >= 0

    function show() {
        search = ""; kindFilter = "all"; note = ""; confirmClear = false; aiItem = null
        load()
        if (atCursor) {
            curX = -1; curY = -1; pending = true
            posProc.running = true
            posGuard.restart()
        } else open = true
    }
    function hide() { pending = false; open = false; confirmClear = false }
    function close() { hide() }
    function toggle() { if (open || pending) hide(); else show() }

    // hyprctl: the pointer in layout coordinates, minus the monitor it is over (x, y, scale) = the spot inside that monitor
    Process {
        id: posProc
        command: ["python3", "-c",
            "import json,subprocess as s\n" +
            "try:\n" +
            " c=json.loads(s.check_output(['hyprctl','cursorpos','-j'],timeout=2))\n" +
            " for m in json.loads(s.check_output(['hyprctl','monitors','-j'],timeout=2)):\n" +
            "  sc=m.get('scale') or 1\n" +
            "  w=m['width']/sc; h=m['height']/sc\n" +
            "  if m.get('transform',0)%2: w,h=h,w\n" +
            "  if m['x']<=c['x']<m['x']+w and m['y']<=c['y']<m['y']+h:\n" +
            "   print(m['name'],c['x']-m['x'],c['y']-m['y']); break\n" +
            "except Exception: pass\n"]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = text.trim().split(" ")
                if (p.length === 3 && !isNaN(parseFloat(p[1])) && !isNaN(parseFloat(p[2]))) {
                    root.curScreen = p[0]; root.curX = parseFloat(p[1]); root.curY = parseFloat(p[2])
                }
            }
        }
        onExited: { posGuard.stop(); if (root.pending) { root.pending = false; root.open = true } }
    }
    // safety net: if hyprctl hangs, the panel still opens (on its usual side)
    Timer { id: posGuard; interval: 600; onTriggered: { if (root.pending) { root.pending = false; root.open = true } } }

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

    // ---- AI on one entry (scripts/halcyon-ai.py clip summarise | rewrite | shorter | explain --id ID; explain: a copied error or log line)
    property var aiItem: null               // the entry the AI view is about (null = the list is shown)
    property string aiKind: ""
    property string aiOut: ""
    property bool aiOk: true
    readonly property string aiScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-ai.py"
    function aiOpen(it) { if (!it || it.image) return; aiItem = it; aiKind = ""; aiOut = ""; aiOk = true }
    function aiRun(kind) {
        if (!aiItem || aiProc.running) return
        aiKind = kind; aiOut = ""; aiOk = true
        aiProc.command = ["python3", aiScript, "clip", kind, "--id", String(aiItem.id), "--json"]
        aiProc.running = true
    }
    function aiCopy() {
        if (aiOut === "" || !aiOk) return
        Quickshell.execDetached(["wl-copy", aiOut])
        note = "Copied"
        leaveT.restart()
    }
    Process {
        id: aiProc
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                root.aiOk = !!d && d.ok === true
                root.aiOut = !d ? "No answer (is python3 there?)" : (d.ok ? d.text : d.error)
            }
        }
    }
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

    // what an entry is: the icon, the colour of its tile and the line under it follow from this
    property string kindFilter: "all"       // all | text | link | image
    function kindOf(e) {
        if (e.image) return "image"
        var t = String(e.text || "").trim()
        if (/^(https?:\/\/|www\.)\S+$/i.test(t)) return "link"
        if (/^#?[0-9a-f]{6}([0-9a-f]{2})?$/i.test(t) || /^#[0-9a-f]{3}$/i.test(t) || /^rgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*(,\s*[\d.]+\s*)?\)$/i.test(t)) return "colour"
        if (/^(~|\/)[^\s]*$/.test(t) && t.length > 1) return "path"
        if (/[{};]\s|=>|\bfunction\b|\bdef\b|^\$ |\bsudo\b|\|\s*\w+/.test(t)) return "code"
        return "text"
    }
    function kindGlyph(k) {
        return k === "image" ? 0xF021F : k === "link" ? 0xF0337 : k === "colour" ? 0xF03D8 : k === "path" ? 0xF024B : k === "code" ? 0xF0169 : 0xF09A8
    }
    function colourOf(t) {
        t = String(t).trim()
        if (/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(t)) t = "#" + t
        return t
    }
    function subOf(e, k) {
        if (k === "image") {
            var t = e.text || ""
            var a = t.indexOf("binary data"), b = t.lastIndexOf("]]")
            return "Picture" + ((a >= 0 && b > a) ? "  ·  " + t.substring(a + 11, b).trim() : "")
        }
        if (k === "link") { var m = /^(?:https?:\/\/)?(?:www\.)?([^\/?#]+)/i.exec(String(e.text).trim()); return "Link" + (m ? "  ·  " + m[1] : "") }
        if (k === "colour") return "Colour"
        if (k === "path") return "Path"
        if (k === "code") return "Command or code"
        var n = String(e.text || "").length
        return n > 120 ? Math.round(n / 5.5) + " words" : ""
    }

    readonly property var shown: {
        var q = search.trim().toLowerCase(), f = kindFilter
        return items.filter(function (e) {
            var k = root.kindOf(e)
            if (f === "image" && k !== "image") return false
            if (f === "link" && k !== "link") return false
            if (f === "text" && (k === "image" || k === "link")) return false
            if (!q) return true
            return e.image ? "image picture".indexOf(q) >= 0 : (e.text || "").toLowerCase().indexOf(q) >= 0
        })
    }
    readonly property bool anyPin: { for (var i = 0; i < items.length; i++) if (items[i].pin === true) return true; return false }
    readonly property bool anyImage: { for (var i = 0; i < items.length; i++) if (items[i].image) return true; return false }

    // what a row says: a picture entry reads "Image  ·  png 800x600" instead of cliphist's [[ binary data ... ]]
    function rowText(e) {
        if (!e.image) return e.text
        var t = e.text || ""
        var a = t.indexOf("binary data"), b = t.lastIndexOf("]]")
        var detail = (a >= 0 && b > a) ? t.substring(a + 11, b).trim() : ""
        return "Image" + (detail !== "" ? "   ·   " + detail : "")
    }

    // a small heading above a group of rows ("Pinned", "Recent")
    component GroupLabel: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.calm ? 11 : 10
        font.weight: Font.DemiBold
        font.letterSpacing: root.pal.calm ? 0.2 : (1.2)
        font.capitalization: root.pal.calm ? Font.MixedCase : Font.AllUppercase
    }
    // a quiet round icon button that appears on the row under the pointer
    component RowBtn: Rectangle {
        id: rb
        property int glyph: 0
        property bool lit: false
        signal clicked()
        width: 26; height: 26; radius: 13
        color: rbMa.containsMouse ? Qt.alpha(root.pal.text, 0.10) : "transparent"
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Text { anchors.centerIn: parent; text: String.fromCodePoint(rb.glyph); color: rb.lit ? root.pal.accent : (rbMa.containsMouse ? root.pal.text : root.pal.muted); font.family: root.pal.font; font.pixelSize: 14 }
        MouseArea { id: rbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rb.clicked() }
    }
    component FilterChip: Rectangle {
        id: fc
        property string key: ""
        property string label: ""
        readonly property bool on: root.kindFilter === key
        implicitWidth: fcT.implicitWidth + 22
        implicitHeight: 26
        radius: 13
        color: on ? Qt.alpha(root.pal.accent, 0.18) : (fcMa.containsMouse ? Qt.alpha(root.pal.text, 0.06) : "transparent")
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Text { id: fcT; anchors.centerIn: parent; text: fc.label; color: fc.on ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: fc.on ? Font.DemiBold : Font.Normal }
        MouseArea { id: fcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kindFilter = fc.key }
    }

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            screen: {
                if (root.curScreen !== "") {
                    for (var i = 0; i < Quickshell.screens.length; i++)
                        if (Quickshell.screens[i].name === root.curScreen) return Quickshell.screens[i]
                }
                return null
            }
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
                    width: 480
                    height: root.followCursor ? Math.min(qp.height - 24, 560)
                                              : Math.min(qp.height - root.pal.boxTop - root.pal.boxEdge, 560)
                    radius: root.pal.rXl
                    opacityBody: root.pal.solid ? 1 : 0.92
                    opacity: qp.reveal
                    // at the pointer: its top-left corner on the pointer, flipped to the other side when it would run off the screen, then kept on screen
                    readonly property real cx: {
                        var x = root.curX
                        if (x + width > qp.width - 12) x = root.curX - width
                        return Math.max(12, Math.min(x, qp.width - width - 12))
                    }
                    readonly property real cy: {
                        var y = root.curY
                        if (y + height > qp.height - 12) y = root.curY - height
                        return Math.max(12, Math.min(y, qp.height - height - 12))
                    }
                    x: root.followCursor ? cx
                       : (root.panelRight ? qp.width - width - 22 + (1 - qp.reveal) * width * 0.4
                                          : 22 - (1 - qp.reveal) * width * 0.4)
                    y: root.followCursor ? cy + (1 - qp.reveal) * 10
                       : (root.panelBottom ? qp.height - height - root.pal.boxEdge : root.pal.boxTop)
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    NoteStars {
                        anchors.fill: parent
                        anchors.margins: 1
                        pal: root.pal
                        opt: root.opt
                        running: root.stars && root.open
                        count: 22
                        opacity: 0.7
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 20
                        spacing: 14

                        // ---- header: the clipboard badge, the count (or what just happened), close
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            Rectangle {
                                width: 36; height: 36; radius: 12
                                color: Qt.alpha(root.note !== "" ? root.pal.good : root.pal.accent, 0.15)
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                Text {
                                    anchors.centerIn: parent
                                    text: String.fromCodePoint(root.note !== "" ? 0xF012C : 0xF0147)
                                    color: root.note !== "" ? root.pal.good : root.pal.accent
                                    font.family: root.pal.font
                                    font.pixelSize: 18
                                }
                            }
                            Column {
                                Layout.fillWidth: true
                                spacing: 1
                                Text { text: "Clipboard"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                                Text {
                                    text: root.note !== "" ? root.note : (root.total + (root.total === 1 ? " thing copied" : " things copied") + (root.anyPin ? "  ·  pins stay" : ""))
                                    color: root.note !== "" ? root.pal.good : root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                            }
                            RoundBtn { pal: root.pal; size: 30; glyph: String.fromCodePoint(0xF0156); onClicked: root.hide() }
                        }

                        // ---- search, then what kind of entry
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            visible: !root.aiItem
                            radius: 20
                            color: Qt.alpha(root.pal.surface, 0.7)
                            border.width: 1
                            border.color: sin.activeFocus ? root.pal.lineFocus : root.pal.lineSoft
                            Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                            Text {
                                id: sGlyph
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: String.fromCodePoint(0xF0349)
                                color: root.pal.muted
                                font.family: root.pal.font
                                font.pixelSize: 15
                            }
                            TextInput {
                                id: sin
                                anchors { fill: parent; leftMargin: 38; rightMargin: 14 }
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true
                                color: root.pal.text
                                selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                selectedTextColor: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                                onTextChanged: { root.search = text; list.currentIndex = 0 }
                                Keys.onPressed: e => {
                                    if (e.key === Qt.Key_Escape) { if (root.aiItem) root.aiItem = null; else root.hide(); e.accepted = true }
                                    else if (root.aiItem) { if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.aiCopy(); e.accepted = true } }
                                    else if (e.key === Qt.Key_Down) { if (list.currentIndex < root.shown.length - 1) list.currentIndex++; e.accepted = true }
                                    else if (e.key === Qt.Key_Up) { if (list.currentIndex > 0) list.currentIndex--; e.accepted = true }
                                    else if (e.key === Qt.Key_Tab) {
                                        var ks = ["all", "text", "link", "image"]
                                        root.kindFilter = ks[(ks.indexOf(root.kindFilter) + 1) % ks.length]; e.accepted = true
                                    }
                                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                        root.copyItem(root.shown[list.currentIndex]); e.accepted = true
                                    }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: sin.text.length === 0
                                    text: "Search what you copied"
                                    color: root.pal.muted
                                    font: sin.font
                                }
                            }
                        }
                        Row {
                            Layout.fillWidth: true
                            Layout.topMargin: -4
                            spacing: 2
                            visible: !root.aiItem && root.items.length > 3
                            FilterChip { key: "all"; label: "All" }
                            FilterChip { key: "text"; label: "Text" }
                            FilterChip { key: "link"; label: "Links" }
                            FilterChip { key: "image"; label: "Pictures"; visible: root.anyImage }
                        }

                        // the watchers are off, or the tools are missing: say so instead of an empty list
                        Rectangle {
                            Layout.fillWidth: true
                            visible: root.loaded && (!root.available || !root.watching)
                            implicitHeight: warnRow.implicitHeight + 20
                            radius: root.pal.rMd
                            color: Qt.alpha(root.pal.warn, 0.10)
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

                        // ---- the list: an icon tile per entry (a swatch for a colour, the picture itself for an image)
                        ListView {
                            id: list
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.shown.length > 0 && !root.aiItem
                            clip: true
                            spacing: 2
                            model: root.shown
                            currentIndex: 0
                            boundsBehavior: Flickable.StopAtBounds
                            highlightMoveDuration: 120
                            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                            Connections { target: root; function onKindFilterChanged() { list.currentIndex = 0 } }
                            highlight: Rectangle {
                                radius: root.pal.rMd
                                color: Qt.alpha(root.pal.accent, 0.11)
                            }

                            delegate: Item {
                                id: row
                                required property var modelData
                                required property int index
                                readonly property bool cur: ListView.isCurrentItem
                                readonly property string kind: root.kindOf(modelData)
                                readonly property bool pinned: modelData.pin === true
                                readonly property bool hasThumb: kind === "image" && (modelData.thumb || "") !== "" && thumbImg.status !== Image.Error
                                readonly property string sub: pinned ? "Pinned" + (root.subOf(modelData, kind) !== "" ? "  ·  " + root.subOf(modelData, kind) : "") : root.subOf(modelData, kind)
                                // "Pinned" above the first pin, "Recent" above the first entry after the pins
                                readonly property string group: {
                                    if (!root.anyPin || root.search.trim() !== "") return ""
                                    var prev = index > 0 ? root.shown[index - 1] : null
                                    if (pinned && !prev) return "Pinned"
                                    if (!pinned && (!prev || prev.pin === true)) return "Recent"
                                    return ""
                                }
                                width: ListView.view.width
                                height: (group !== "" ? 26 : 0) + body.height

                                GroupLabel {
                                    visible: row.group !== ""
                                    x: 6; y: 6
                                    text: row.group
                                }
                                Item {
                                    id: body
                                    y: row.group !== "" ? 26 : 0
                                    width: parent.width
                                    height: row.hasThumb ? 70 : (txt.lineCount > 1 || row.sub !== "" ? 54 : 44)

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: root.pal.rMd
                                        color: rowMa.containsMouse && !row.cur ? Qt.alpha(root.pal.text, 0.04) : "transparent"
                                    }

                                    // the tile: a tinted glyph, the colour itself, or the picture
                                    Rectangle {
                                        id: tile
                                        x: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: row.hasThumb ? 84 : 32
                                        height: row.hasThumb ? 54 : 32
                                        radius: row.hasThumb ? root.pal.rSm : 10
                                        clip: true
                                        color: row.kind === "colour" ? root.colourOf(row.modelData.text)
                                             : Qt.alpha(row.kind === "image" ? root.pal.accent2 : (row.pinned ? root.pal.accent : root.pal.text), row.pinned || row.kind === "image" ? 0.16 : 0.07)
                                        border.width: row.kind === "colour" ? 1 : 0
                                        border.color: Qt.alpha(root.pal.text, 0.25)
                                        Text {
                                            anchors.centerIn: parent
                                            visible: row.kind !== "colour" && !row.hasThumb
                                            text: String.fromCodePoint(row.pinned ? 0xF0403 : root.kindGlyph(row.kind))
                                            color: row.pinned ? root.pal.accent : (row.kind === "image" ? root.pal.accent2 : root.pal.muted)
                                            font.family: root.pal.font
                                            font.pixelSize: 15
                                        }
                                        Image {
                                            id: thumbImg
                                            anchors.fill: parent
                                            visible: row.hasThumb
                                            source: row.kind === "image" && (row.modelData.thumb || "") !== "" ? "file://" + row.modelData.thumb : ""
                                            sourceSize.width: 168
                                            sourceSize.height: 108
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            cache: false
                                        }
                                    }

                                    Column {
                                        anchors { left: tile.right; leftMargin: 12; right: acts.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                        spacing: 2
                                        Text {
                                            id: txt
                                            width: parent.width
                                            text: row.kind === "image" ? "Picture" : row.modelData.text
                                            elide: Text.ElideRight
                                            wrapMode: Text.Wrap
                                            maximumLineCount: row.sub === "" ? 2 : 1
                                            color: root.pal.text
                                            font.family: row.kind === "code" || row.kind === "path" || row.kind === "colour" ? root.pal.mono : root.pal.uiFont
                                            font.pixelSize: row.kind === "code" || row.kind === "path" ? root.pal.tCap + 1 : root.pal.tBody
                                        }
                                        Text {
                                            visible: row.sub !== ""
                                            width: parent.width
                                            text: row.kind === "image" ? row.sub.replace(/^Picture\s*·\s*/, "") : row.sub
                                            elide: Text.ElideRight
                                            color: row.pinned ? root.pal.accent : root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                    }

                                    Row {
                                        id: acts
                                        anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                        spacing: 0
                                        opacity: rowMa.containsMouse || row.cur ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
                                        RowBtn { visible: !row.modelData.image; glyph: 0xF0674; onClicked: root.aiOpen(row.modelData) }
                                        RowBtn { visible: !row.modelData.image; glyph: row.pinned ? 0xF0404 : 0xF0403; lit: row.pinned; onClicked: root.pinItem(row.modelData) }
                                        RowBtn { glyph: 0xF01B4; onClicked: root.deleteItem(row.modelData) }
                                    }
                                    MouseArea {
                                        id: rowMa
                                        anchors.fill: parent
                                        anchors.rightMargin: acts.width + 8          // the AI, pin and delete buttons keep their own clicks
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: list.currentIndex = row.index
                                        onClicked: root.copyItem(row.modelData)
                                    }
                                }
                            }
                        }

                        // an empty list says why (a sibling of the list, not inside it: a ListView would scroll it)
                        Column {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.shown.length === 0 && !root.aiItem && root.loaded && root.available
                            spacing: 6
                            topPadding: 60
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: String.fromCodePoint(0xF0147)
                                color: Qt.alpha(root.pal.muted, 0.6)
                                font.family: root.pal.font
                                font.pixelSize: 30
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: root.search.trim() !== "" || root.kindFilter !== "all" ? "Nothing copied matches that" : "Nothing copied yet"
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                            }
                        }

                        // ---- the AI view: one entry, what to do with it, the answer
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.aiItem !== null
                            spacing: 12
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: srcT.implicitHeight + 20
                                radius: root.pal.rMd
                                color: Qt.alpha(root.pal.surface, 0.6)
                                Text {
                                    id: srcT
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 12 }
                                    text: root.aiItem ? root.aiItem.text : ""
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    wrapMode: Text.Wrap
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 6
                                Repeater {
                                    model: [["summarise", "Summarise"], ["rewrite", "Rewrite clearly"], ["shorter", "Make it shorter"], ["explain", "Explain error"]]
                                    delegate: Chip {
                                        required property var modelData
                                        pal: root.pal; implicitHeight: 30
                                        label: modelData[1]
                                        on: root.aiKind === modelData[0]
                                        onClicked: root.aiRun(modelData[0])
                                    }
                                }
                            }
                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Row {
                                    x: 4
                                    height: parent.height
                                    spacing: 12
                                    Rectangle { width: 2; height: Math.min(parent.height, aiTxt.implicitHeight); radius: 1; color: !root.aiOk ? Qt.alpha(root.pal.warn, 0.6) : Qt.alpha(root.pal.accent, 0.45) }
                                    Flickable {
                                        id: aiFlick
                                        width: list.width - 18
                                        height: parent.height
                                        contentWidth: width
                                        contentHeight: aiTxt.implicitHeight
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds
                                        TextEdit {
                                            id: aiTxt
                                            width: aiFlick.width
                                            readOnly: true
                                            selectByMouse: true
                                            wrapMode: TextEdit.Wrap
                                            text: aiProc.running ? "Asking your local AI…" : (root.aiOut !== "" ? root.aiOut : "Pick what to do with it. The answer comes from your local model; nothing leaves this computer.")
                                            color: aiProc.running || root.aiOut === "" ? root.pal.muted : (root.aiOk ? root.pal.text : root.pal.warn)
                                            selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                        }
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                ActionChip { pal: root.pal; label: "Back"; implicitHeight: 30; onClicked: root.aiItem = null }
                                Item { Layout.fillWidth: true }
                                ActionChip { pal: root.pal; label: "Copy the answer"; on: true; implicitHeight: 30; disabled: aiProc.running || root.aiOut === "" || !root.aiOk; onClicked: root.aiCopy() }
                            }
                        }

                        // ---- footer: the keys, Clear history
                        RowLayout {
                            Layout.fillWidth: true
                            visible: !root.aiItem
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                text: "Enter copies  ·  Tab filters  ·  Esc closes"
                                elide: Text.ElideRight
                                color: Qt.alpha(root.pal.muted, 0.8)
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
