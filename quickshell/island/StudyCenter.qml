import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Study Center.   >study in the launcher (also `island command study`, the IPC call `study`, `halcyon study`).
// Your files on the left (PDF, Word, PowerPoint, EPUB, notes, code, photos of pages), and four ways to learn from them:
//   Ask       a question in plain words; the answer comes only from the files, with the pages it used (click one to open it there)
//   Summary   a revision summary            Quiz   exam questions, the answer under each        Cards   flashcards, click to turn
// Everything goes through scripts/halcyon-study.py (the library in ~/.local/share/halcyon/study, the answers from the local
// Ollama model, nothing leaves the machine). Nothing runs while the window is closed (LazyLoader, no timers, no processes),
// except an answer that was still being written: it finishes and is there when you come back.
Scope {
    id: root
    property var pal
    property bool open: false
    property string tab: "ask"              // ask | summary | quiz | cards
    signal focusRequested(string what)      // the window's own fields take the keyboard (ids inside the LazyLoader are not reachable)

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-study.py"
    readonly property var exts: ["pdf", "docx", "pptx", "odt", "odp", "epub", "md", "markdown", "txt", "rst", "org", "tex", "csv",
        "html", "htm", "json", "py", "c", "cpp", "h", "java", "js", "ts", "rs", "go", "sh", "lua", "sql", "png", "jpg", "jpeg", "webp", "tif", "tiff"]

    // ---- library
    property var docs: []
    property bool loaded: false
    property string model: ""
    property var sel: ({})                  // id -> true; nothing picked = every file
    readonly property var selIds: { var o = []; for (var i = 0; i < docs.length; i++) if (sel[docs[i].id]) o.push(docs[i].id); return o }
    readonly property string scopeText: docs.length === 0 ? "no files yet"
        : (selIds.length === 0 ? (docs.length === 1 ? docs[0].name : (docs.length === 2 ? "both files" : "all " + docs.length + " files"))
        : (selIds.length === 1 ? nameOf(selIds[0]) : selIds.length + " files"))
    property string pickDir: ""
    property bool pickerOpen: false
    property string confirmRm: ""
    property string note: ""
    property bool noteBad: false

    // ---- ask
    property var msgs: []                   // { role: "you" | "ai", text, sources: [], live: bool, bad: bool }
    property string status: ""              // "looking through your files" ...

    // ---- summary / quiz / cards: the last result per tab
    property var made: ({ summary: null, quiz: null, cards: null })
    property string makeMode: ""            // the tab whose result is being written now
    property string makeMsg: ""
    property string pages: ""               // "3-9": only those pages
    property int cardIdx: 0
    property bool cardBack: false
    property var shown: ({})                // quiz: the answers turned over (index -> true)

    readonly property bool asking: askProc.running
    readonly property bool making: makeProc.running
    readonly property bool busy: asking || making || addProc.running

    function show(t) {
        if (t === "summary" || t === "quiz" || t === "cards" || t === "ask") tab = t
        open = true
        note = ""
        reload()
        if (tab !== "ask") loadSaved()
    }
    function hide() { open = false; pickerOpen = false; confirmRm = "" }
    function toggle() { if (open) hide(); else show("") }
    function setTab(t) {
        tab = t
        pickerOpen = false
        if (t !== "ask") loadSaved()
        Qt.callLater(function () { root.focusRequested(t === "ask" ? "ask" : "panel") })
    }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    function nameOf(id) { for (var i = 0; i < docs.length; i++) if (docs[i].id === id) return docs[i].name; return "" }
    function docOf(id) { for (var i = 0; i < docs.length; i++) if (docs[i].id === id) return docs[i]; return null }
    function flash(t, bad) { note = t; noteBad = bad === true; noteT.restart() }
    Timer { id: noteT; interval: 6000; onTriggered: root.note = "" }
    function docArgs() { return selIds.length > 0 ? ["--docs", selIds.join(",")] : [] }
    function toggleSel(id) {
        var c = {}
        for (var k in sel) if (sel[k]) c[k] = true
        if (c[id]) delete c[id]; else c[id] = true
        sel = c
        made = { summary: null, quiz: null, cards: null }
        if (tab !== "ask") loadSaved()
    }
    function selAll() { sel = ({}); made = { summary: null, quiz: null, cards: null }; if (tab !== "ask") loadSaved() }
    function glyphOf(ext) {
        if (ext === "pdf") return 0xF0226
        if (ext === "docx" || ext === "odt") return 0xF022C
        if (ext === "pptx" || ext === "odp") return 0xF0227
        if (ext === "epub") return 0xF00BE
        if (["png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp", "gif"].indexOf(ext) >= 0) return 0xF021F
        if (["md", "markdown", "txt", "rst", "org"].indexOf(ext) >= 0) return 0xF0219
        return 0xF022E
    }
    function unitText(d) { return d.unit === "image" ? "photo, read with OCR" : d.pages + " " + d.unit + (d.pages === 1 ? "" : "s") + (d.ocr ? ", read with OCR" : "") }

    // the model's text -> rich text: **bold**, `code`, "- " and "1." lists (with a hanging indent), ### headings, "Topic:" lines,
    // and the [file, page 3] notes in a quiet colour
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function inline(l) {
        return l.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<i>$2</i>")
                .replace(/`([^`]+)`/g, "<span style=\"font-family:'" + pal.mono + "'\">$1</span>")
                .replace(/\[([^\[\]]{2,90}(?:page|part|slide|image)[^\[\]]{0,20})\]/gi, "<span style=\"color:" + String(pal.muted) + "\">[$1]</span>")
    }
    function fmt(t) {
        var lines = esc(t).split("\n"), out = [], list = ""
        function close() { if (list !== "") { out.push("</" + list + ">"); list = "" } }
        function open(kind) { if (list !== kind) { close(); out.push("<" + kind + " style=\"margin-top:2px;margin-bottom:6px;margin-left:-14px\">"); list = kind } }
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]
            var h = /^\s*#{1,4}\s+(.*)$/.exec(l), bu = /^\s*[-*\u2022]\s+(.*)$/.exec(l), nu = /^\s*\d+[.)]\s+(.*)$/.exec(l)
            if (bu) { open("ul"); out.push("<li>" + inline(bu[1]) + "</li>"); continue }
            if (nu) { open("ol"); out.push("<li>" + inline(nu[1]) + "</li>"); continue }
            close()
            if (l.trim() === "") { out.push("<div style=\"font-size:6px\">&nbsp;</div>"); continue }
            if (h || (/[^:]{2,60}:\s*$/.test(l) && l.length < 70)) out.push("<div style=\"margin-top:6px\"><b>" + inline(h ? h[1] : l) + "</b></div>")
            else out.push("<div>" + inline(l) + "</div>")
        }
        close()
        return out.join("")
    }

    // ---------------------------------------------------------------- processes
    function reload() { if (!listProc.running) listProc.running = true }
    Process {
        id: listProc
        command: ["python3", root.script, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text)
                    root.docs = o.docs || []
                    root.model = o.model || ""
                    var c = {}
                    for (var k in root.sel) if (root.sel[k] && root.docOf(k)) c[k] = true
                    root.sel = c
                } catch (e) {}
                root.loaded = true
            }
        }
    }

    property var addQueue: []
    function addFile(path) {
        addQueue = addQueue.concat([path])
        if (!addProc.running) nextAdd()
        var d = path.lastIndexOf("/")
        if (d > 0) pickDir = path.substring(0, d)
    }
    function nextAdd() {
        if (addQueue.length === 0) return
        var p = addQueue[0]
        addQueue = addQueue.slice(1)
        addProc.command = ["python3", script, "add", "--json", p]
        addProc.running = true
    }
    Process {
        id: addProc
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                if (o.type === "progress") root.makeMsg = o.msg
                else if (o.type === "added") {
                    root.flash(o.again ? o.doc.name + " is already here" : "Added " + o.doc.name + "  ·  " + root.unitText(o.doc), false)
                    var c = {}
                    c[o.doc.id] = true
                    root.sel = c                        // a new file: the next question is about it
                } else if (o.type === "error") root.flash(o.error, true)
            }
        }
        onExited: { root.makeMsg = ""; root.reload(); root.nextAdd() }
    }
    function removeDoc(id) {
        confirmRm = ""
        Quickshell.execDetached(["python3", script, "remove", id])
        var c = {}
        for (var k in sel) if (sel[k] && k !== id) c[k] = true
        sel = c
        docs = docs.filter(function (d) { return d.id !== id })
        rmT.restart()
    }
    Timer { id: rmT; interval: 400; onTriggered: root.reload() }
    function openDoc(id, page) { Quickshell.execDetached(["python3", script, "open", id].concat(page ? [String(page)] : [])) }

    function ask(q) {
        q = String(q || "").trim()
        if (q === "" || asking) return
        if (docs.length === 0) { flash("Add a file first: the answers come from your files", true); return }
        var hist = []
        for (var i = 0; i + 1 < msgs.length; i++)
            if (msgs[i].role === "you" && msgs[i + 1].role === "ai" && !msgs[i + 1].bad) hist.push({ q: msgs[i].text, a: msgs[i + 1].text })
        hist = hist.slice(-3)
        msgs = msgs.concat([{ role: "you", text: q }, { role: "ai", text: "", sources: [], live: true, bad: false }])
        status = "looking through your files"
        askProc.command = ["python3", script, "ask", "--json"].concat(docArgs()).concat(["--history", JSON.stringify(hist), "--", q])
        askProc.running = true
    }
    function stopAsk() { if (askProc.running) askProc.signal(15) }
    function patchLast(f) {
        var m = msgs.slice()
        var l = m.length - 1
        if (l < 0 || m[l].role !== "ai") return
        var c = {}
        for (var k in m[l]) c[k] = m[l][k]
        f(c)
        m[l] = c
        msgs = m
    }
    property string pend: ""                // tokens not drawn yet: the answer grows a few times a second, not on every token
    Timer { id: flushT; interval: 70; onTriggered: root.flushPend() }
    function flushPend() { if (pend === "") return; var t = pend; pend = ""; patchLast(function (c) { c.text += t }) }
    Process {
        id: askProc
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                if (o.type === "progress") root.status = o.msg
                else if (o.type === "sources") root.patchLast(function (c) { c.sources = o.sources })
                else if (o.type === "tok") { root.status = ""; root.pend += o.t; if (!flushT.running) flushT.start() }
                else if (o.type === "error") { root.flushPend(); root.patchLast(function (c) { c.text = (c.text ? c.text + "\n\n" : "") + o.error; c.bad = true }) }
            }
        }
        onExited: {
            root.flushPend()
            root.status = ""
            root.patchLast(function (c) { c.live = false; if (c.text === "") { c.text = "Stopped."; c.bad = true } })
        }
    }
    function clearChat() { if (!asking) msgs = [] }

    function make(fresh) {
        if (making || docs.length === 0) return
        makeMode = tab
        makeMsg = "starting"
        var a = ["python3", script, "make", tab, "--json"].concat(docArgs())
        if (pages.trim() !== "") a = a.concat(["--pages", pages.trim()])
        if (tab !== "summary") a = a.concat(["--n", "10"])
        if (fresh) a.push("--fresh")
        makeProc.command = a
        makeProc.running = true
    }
    function setMade(mode, o) {
        var c = { summary: made.summary, quiz: made.quiz, cards: made.cards }
        c[mode] = o
        made = c
        if (mode === "cards") { cardIdx = 0; cardBack = false }
        if (mode === "quiz") shown = ({})
    }
    Process {
        id: makeProc
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                if (o.type === "progress") root.makeMsg = o.msg
                else if (o.type === "result") root.setMade(o.mode, o)
                else if (o.type === "error") root.flash(o.error, true)
            }
        }
        onExited: { root.makeMsg = ""; root.makeMode = "" }
    }
    function loadSaved() {
        if (docs.length === 0 && loaded) return
        var a = ["python3", script, "saved", tab, "--json"].concat(docArgs())
        if (pages.trim() !== "") a = a.concat(["--pages", pages.trim()])
        savedProc.mode = tab
        savedProc.command = a
        savedProc.running = true
    }
    Process {
        id: savedProc
        property string mode: ""
        stdout: StdioCollector {
            onStreamFinished: {
                try { var o = JSON.parse(text); if (o.type === "result") root.setMade(savedProc.mode, o) } catch (e) {}
            }
        }
    }
    function saveNote(t) {
        Quickshell.execDetached(["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "add", t])
        flash("Saved as a note (Super + N)", false)
    }
    function copy(t) { Quickshell.execDetached(["wl-copy", "--", t]); flash("Copied", false) }

    // ---------------------------------------------------------------- small pieces
    component Label: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
        font.weight: Font.DemiBold
        font.letterSpacing: root.pal.calm ? 0.2 : (0.9)
        font.capitalization: root.pal.calm ? Font.MixedCase : Font.AllUppercase
    }
    // the one filled button of a view
    component PrimaryBtn: Rectangle {
        id: pb
        property string label: ""
        property string glyph: ""
        property bool disabled: false
        signal clicked()
        implicitWidth: pbRow.implicitWidth + 30
        implicitHeight: 36
        radius: height / 2
        opacity: disabled ? 0.45 : 1
        color: pbMa.containsMouse && !disabled ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent
        scale: pbMa.pressed && !disabled ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 8
            Text { visible: pb.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: pb.glyph; color: root.pal.bg; font.family: root.pal.font; font.pixelSize: 15 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: pb.label; color: root.pal.bg; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
        }
        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: pb.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!pb.disabled) pb.clicked() }
    }
    // a quiet text button (Copy, Save as note, Clear)
    component LinkBtn: Rectangle {
        id: lb
        property string label: ""
        property string glyph: ""
        signal clicked()
        implicitWidth: lbRow.implicitWidth + 20
        implicitHeight: 30
        radius: 15
        color: lbMa.containsMouse ? Qt.alpha(root.pal.text, 0.07) : "transparent"
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Row {
            id: lbRow
            anchors.centerIn: parent
            spacing: 6
            Text { visible: lb.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: lb.glyph; color: lbMa.containsMouse ? root.pal.text : root.pal.muted; font.family: root.pal.font; font.pixelSize: 14 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: lb.label; color: lbMa.containsMouse ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
        }
        MouseArea { id: lbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: lb.clicked() }
    }
    component TabBtn: Rectangle {
        id: tb
        property string label: ""
        property string key: ""
        readonly property bool on: root.tab === key
        implicitWidth: tbTxt.implicitWidth + 30
        implicitHeight: 32
        radius: 16
        color: on ? Qt.alpha(root.pal.accent, 0.18) : (tbMa.containsMouse ? Qt.alpha(root.pal.text, 0.06) : "transparent")
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Text {
            id: tbTxt
            anchors.centerIn: parent
            text: tb.label
            color: tb.on ? root.pal.accent : root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
            font.weight: tb.on ? Font.DemiBold : Font.Medium
        }
        MouseArea { id: tbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setTab(tb.key) }
    }
    // a source under an answer: "page 14": opens the file there
    component SourceChip: Rectangle {
        id: sc
        property var src
        implicitWidth: scTxt.implicitWidth + 20
        implicitHeight: 24
        radius: 12
        color: scMa.containsMouse ? Qt.alpha(root.pal.accent, 0.16) : Qt.alpha(root.pal.surface, 0.7)
        border.width: 1
        border.color: scMa.containsMouse ? Qt.alpha(root.pal.accent, 0.4) : root.pal.lineSoft
        Text {
            id: scTxt
            anchors.centerIn: parent
            text: (root.selIds.length === 1 || root.docs.length === 1 ? "" : sc.src.name + "  ·  ") + (sc.src.unit === "image" ? "photo" : sc.src.unit + " " + sc.src.page)
            color: scMa.containsMouse ? root.pal.accent : root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap
            elide: Text.ElideMiddle
            width: Math.min(implicitWidth, 260)
        }
        MouseArea { id: scMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openDoc(sc.src.doc, sc.src.unit === "page" ? sc.src.page : 0) }
    }
    // the "working on it" line: three soft dots and what it is doing
    component Working: Row {
        id: wk
        property string text: ""
        spacing: 10
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            Repeater {
                model: 3
                delegate: Rectangle {
                    required property int index
                    width: 6; height: 6; radius: 3
                    color: root.pal.accent
                    opacity: 0.25 + 0.75 * Math.max(0, Math.sin((dots.t - index * 0.18) * Math.PI * 2))
                }
            }
        }
        Item {
            id: dots
            property real t: 0
            NumberAnimation on t { from: 0; to: 1; duration: 1300; loops: Animation.Infinite; running: wk.visible && root.open }
        }
        Text { anchors.verticalCenter: parent.verticalCenter; text: wk.text; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
    }

    // ================================================================ the window
    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-study"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { if (root.tab === "ask") askIn.forceActiveFocus(); else qp.forceActiveFocus() }) }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { if (root.pickerOpen) root.pickerOpen = false; else root.hide(); e.accepted = true }
                    else if (root.tab === "cards" && root.made.cards && (e.key === Qt.Key_Right || e.key === Qt.Key_Left)) {
                        var n = root.made.cards.items.length
                        root.cardIdx = (root.cardIdx + (e.key === Qt.Key_Right ? 1 : n - 1)) % n
                        root.cardBack = false
                        e.accepted = true
                    }
                    else if (root.tab === "cards" && (e.key === Qt.Key_Space || e.key === Qt.Key_Return)) { root.cardBack = !root.cardBack; e.accepted = true }
                }
                Connections {
                    target: root
                    function onFocusRequested(what) {
                        if (what === "ask") askIn.forceActiveFocus()
                        else if (what === "picker") picker.openAt(root.pickDir !== "" ? root.pickDir : Quickshell.env("HOME") + "/Downloads")
                        else qp.forceActiveFocus()
                    }
                }

                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: Math.min(1160, qp.width - 80)
                    height: Math.min(760, qp.height - 80)
                    radius: root.pal.rXl
                    opacityBody: 0.97
                    anchors.centerIn: parent
                    opacity: qp.reveal
                    scale: 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== the library
                        Item {
                            Layout.preferredWidth: 286
                            Layout.fillHeight: true
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 1
                                radius: root.pal.rXl
                                color: Qt.alpha(root.pal.surface, 0.35)
                                // only the left corners are round: the right edge meets the content
                                Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right } width: parent.radius; color: parent.color }
                            }
                            Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right; topMargin: 24; bottomMargin: 24 } width: 1; color: root.pal.lineSoft }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 22
                                spacing: 16

                                Row {
                                    spacing: 12
                                    Rectangle {
                                        width: 38; height: 38; radius: 12
                                        color: Qt.alpha(root.pal.accent, 0.14)
                                        Text {
                                            anchors.centerIn: parent
                                            text: String.fromCodePoint(0xF0474)
                                            color: root.pal.accent
                                            font.family: root.pal.font
                                            font.pixelSize: 20
                                            opacity: root.busy ? 0.4 + 0.6 * Math.abs(Math.sin(pulse.tp * Math.PI)) : 1
                                        }
                                        Item { id: pulse; property real tp: 0; NumberAnimation on tp { from: 0; to: 1; duration: 1100; loops: Animation.Infinite; running: root.busy && root.open } }
                                    }
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 1
                                        Text { text: "Study"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 3; font.weight: Font.DemiBold }
                                        Text { text: "on this computer" + (root.model !== "" ? "  ·  " + root.model : ""); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    Label { text: "Your files"; Layout.fillWidth: true }
                                    LinkBtn {
                                        visible: root.docs.length > 1 && root.selIds.length > 0
                                        label: "Use all"
                                        onClicked: root.selAll()
                                    }
                                }

                                ListView {
                                    id: docList
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.docs.length > 0
                                    clip: true
                                    spacing: 4
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.docs
                                    delegate: Rectangle {
                                        id: drow
                                        required property var modelData
                                        readonly property bool on: !!root.sel[modelData.id]
                                        readonly property bool rm: root.confirmRm === modelData.id
                                        width: docList.width
                                        height: 54
                                        radius: root.pal.rMd
                                        color: on ? Qt.alpha(root.pal.accent, 0.13) : (dMa.containsMouse ? Qt.alpha(root.pal.text, 0.05) : "transparent")
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        MouseArea { id: dMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleSel(drow.modelData.id) }
                                        Text {
                                            id: dg
                                            x: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: String.fromCodePoint(root.glyphOf(drow.modelData.ext))
                                            color: drow.on ? root.pal.accent : root.pal.muted
                                            font.family: root.pal.font
                                            font.pixelSize: 20
                                        }
                                        Column {
                                            anchors { left: dg.right; leftMargin: 12; right: dAct.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                            spacing: 2
                                            Text { width: parent.width; elide: Text.ElideRight; text: drow.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: drow.on ? Font.DemiBold : Font.Normal }
                                            Text { width: parent.width; elide: Text.ElideRight; text: drow.rm ? "Remove from the library?" : root.unitText(drow.modelData); color: drow.rm ? root.pal.warn : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                        }
                                        Row {
                                            id: dAct
                                            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                            spacing: 2
                                            visible: dMa.containsMouse || drow.rm || rmA.containsMouse || rmB.containsMouse
                                            Rectangle {
                                                width: 26; height: 26; radius: 13
                                                visible: drow.rm
                                                color: rmB.containsMouse ? Qt.alpha(root.pal.bad, 0.22) : "transparent"
                                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF012C); color: root.pal.bad; font.family: root.pal.font; font.pixelSize: 15 }
                                                MouseArea { id: rmB; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeDoc(drow.modelData.id) }
                                            }
                                            Rectangle {
                                                width: 26; height: 26; radius: 13
                                                color: rmA.containsMouse ? Qt.alpha(root.pal.text, 0.08) : "transparent"
                                                Text { anchors.centerIn: parent; text: String.fromCodePoint(drow.rm ? 0xF0156 : 0xF01B4); color: root.pal.muted; font.family: root.pal.font; font.pixelSize: 14 }
                                                MouseArea { id: rmA; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.confirmRm = drow.rm ? "" : drow.modelData.id }
                                            }
                                        }
                                    }
                                }

                                // no files yet
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.docs.length === 0
                                    Column {
                                        anchors.centerIn: parent
                                        width: parent.width - 8
                                        spacing: 8
                                        Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.loaded ? "Nothing here yet" : ""; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                        Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: "Add lecture slides, a PDF, your notes or a photo of a page. They stay on this computer."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; lineHeight: 1.25 }
                                    }
                                }

                                Working { visible: addProc.running; text: root.makeMsg !== "" ? root.makeMsg : "reading" ; Layout.fillWidth: true }

                                PrimaryBtn {
                                    Layout.fillWidth: true
                                    glyph: String.fromCodePoint(0xF0415)
                                    label: "Add files"
                                    onClicked: { root.pickerOpen = true; root.focusRequested("picker") }
                                }
                            }
                        }

                        // ======================== the work area
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.margins: 24
                            Layout.leftMargin: 28
                            spacing: 16

                            // tabs, then the close button
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                TabBtn { label: "Ask"; key: "ask" }
                                TabBtn { label: "Summary"; key: "summary" }
                                TabBtn { label: "Quiz"; key: "quiz" }
                                TabBtn { label: "Flashcards"; key: "cards" }
                                Item { Layout.fillWidth: true }
                                Text {
                                    Layout.maximumWidth: 380
                                    elide: Text.ElideRight
                                    text: root.note !== "" ? root.note : "About " + root.scopeText
                                    color: root.note !== "" ? (root.noteBad ? root.pal.bad : root.pal.accent) : root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                RoundBtn { pal: root.pal; size: 32; glyph: String.fromCodePoint(0xF0156); onClicked: root.hide() }
                            }

                            // ---------------- Ask
                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                visible: root.tab === "ask"

                                // before the first question: a calm greeting and a few ways to start
                                Column {
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: -40
                                    width: Math.min(520, parent.width - 40)
                                    spacing: 14
                                    visible: root.msgs.length === 0
                                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.docs.length === 0 ? "Add a file to begin" : "What would you like to understand?"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.Medium }
                                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; lineHeight: 1.3; text: root.docs.length === 0 ? "The answers come only from your own files, with the page each one is on." : "Answers come only from " + root.scopeText + ", with the pages they are on. Pick files on the left to narrow it down."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    Flow {
                                        width: parent.width
                                        spacing: 8
                                        visible: root.docs.length > 0
                                        Repeater {
                                            model: ["What is this about?", "Explain the main ideas simply", "What are the key definitions?", "What is most likely to come up in an exam?"]
                                            delegate: Rectangle {
                                                id: sug
                                                required property string modelData
                                                width: sugT.implicitWidth + 26; height: 32; radius: 16
                                                color: sugMa.containsMouse ? Qt.alpha(root.pal.accent, 0.14) : Qt.alpha(root.pal.surface, 0.7)
                                                border.width: 1
                                                border.color: sugMa.containsMouse ? Qt.alpha(root.pal.accent, 0.35) : root.pal.lineSoft
                                                Text { id: sugT; anchors.centerIn: parent; text: sug.modelData; color: sugMa.containsMouse ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                MouseArea { id: sugMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.ask(sug.modelData) }
                                            }
                                        }
                                    }
                                }

                                ListView {
                                    id: chat
                                    anchors { left: parent.left; right: parent.right; top: parent.top; bottom: askBar.top; bottomMargin: 14 }
                                    visible: root.msgs.length > 0
                                    clip: true
                                    spacing: 18
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.msgs
                                    onCountChanged: Qt.callLater(function () { chat.positionViewAtEnd() })
                                    onContentHeightChanged: if (root.asking) positionViewAtEnd()
                                    delegate: Item {
                                        id: mrow
                                        required property var modelData
                                        required property int index
                                        readonly property bool you: modelData.role === "you"
                                        property bool allSrc: false
                                        width: chat.width
                                        height: you ? youBox.height : aiCol.height
                                        // your question: a soft bubble on the right
                                        Rectangle {
                                            id: youBox
                                            visible: mrow.you
                                            anchors.right: parent.right
                                            width: Math.min(youT.implicitWidth + 32, parent.width * 0.75)
                                            height: youT.height + 20
                                            radius: 18
                                            color: Qt.alpha(root.pal.accent, 0.13)
                                            Text { id: youT; x: 16; y: 10; width: parent.width - 32; wrapMode: Text.Wrap; text: mrow.modelData.text; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        }
                                        // the answer: plain on the glass, a thin accent line beside it, the sources under it
                                        Column {
                                            id: aiCol
                                            visible: !mrow.you
                                            width: Math.min(parent.width, 760)
                                            spacing: 10
                                            Working { visible: mrow.modelData.live === true && mrow.modelData.text === ""; text: root.status !== "" ? root.status : "thinking" }
                                            Row {
                                                spacing: 14
                                                visible: mrow.modelData.text !== ""
                                                Rectangle { width: 2; height: aiT.height; radius: 1; color: mrow.modelData.bad ? Qt.alpha(root.pal.bad, 0.6) : Qt.alpha(root.pal.accent, 0.45) }
                                                Text {
                                                    id: aiT
                                                    width: aiCol.width - 16
                                                    wrapMode: Text.Wrap
                                                    textFormat: Text.RichText
                                                    text: root.fmt(mrow.modelData.text)
                                                    color: mrow.modelData.bad ? root.pal.bad : root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody + 1
                                                    lineHeight: 1.35
                                                }
                                            }
                                            Flow {
                                                width: parent.width
                                                leftPadding: 16
                                                spacing: 6
                                                visible: !mrow.modelData.live && (mrow.modelData.sources || []).length > 0 && !mrow.modelData.bad
                                                // three sources, the rest behind "+N more" (a broad question can draw on many pages)
                                                Repeater {
                                                    model: (mrow.modelData.sources || []).slice(0, mrow.allSrc ? 24 : 3)
                                                    delegate: SourceChip { required property var modelData; src: modelData }
                                                }
                                                LinkBtn {
                                                    visible: !mrow.allSrc && (mrow.modelData.sources || []).length > 3
                                                    label: "+" + ((mrow.modelData.sources || []).length - 3) + " more"
                                                    onClicked: mrow.allSrc = true
                                                }
                                                LinkBtn { label: "Copy"; glyph: String.fromCodePoint(0xF018F); onClicked: root.copy(mrow.modelData.text) }
                                                LinkBtn { label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(mrow.modelData.text) }
                                            }
                                        }
                                    }
                                }

                                // the question box
                                Rectangle {
                                    id: askBar
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    height: Math.max(50, askIn.contentHeight + 28)
                                    radius: 25
                                    color: Qt.alpha(root.pal.surface, 0.75)
                                    border.width: 1
                                    border.color: askIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                    Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                                    TextEdit {
                                        id: askIn
                                        anchors { left: parent.left; right: sendBtn.left; verticalCenter: parent.verticalCenter; leftMargin: 20; rightMargin: 10 }
                                        wrapMode: TextEdit.Wrap
                                        color: root.pal.text
                                        selectionColor: Qt.alpha(root.pal.accent, 0.4)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody + 1
                                        Keys.onPressed: e => {
                                            if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                                if (!root.asking && text.trim() !== "") { root.ask(text); text = "" }
                                                e.accepted = true
                                            } else if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: askIn.text.length === 0
                                            text: root.docs.length === 0 ? "Add a file on the left first" : "Ask about " + root.scopeText + "…"
                                            color: root.pal.muted
                                            font: askIn.font
                                        }
                                    }
                                    LinkBtn {
                                        anchors { right: sendBtn.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                                        visible: root.msgs.length > 0 && !root.asking && askIn.text.length === 0
                                        label: "New chat"
                                        onClicked: root.clearChat()
                                    }
                                    RoundBtn {
                                        id: sendBtn
                                        anchors { right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                                        pal: root.pal
                                        size: 34
                                        primary: true
                                        glyph: String.fromCodePoint(root.asking ? 0xF04DB : 0xF005D)
                                        enabledBtn: root.asking || askIn.text.trim() !== ""
                                        onClicked: { if (root.asking) root.stopAsk(); else if (askIn.text.trim() !== "") { root.ask(askIn.text); askIn.text = "" } }
                                    }
                                }
                            }

                            // ---------------- Summary / Quiz / Flashcards: one toolbar, then the result
                            RowLayout {
                                Layout.fillWidth: true
                                visible: root.tab !== "ask"
                                spacing: 10
                                Text {
                                    text: root.tab === "summary" ? "A revision summary" : (root.tab === "quiz" ? "Exam questions with answers" : "Flashcards to test yourself")
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tTitle
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                // pages: "3-9" = only those (handy for a chapter of a long book)
                                Rectangle {
                                    implicitWidth: 120; implicitHeight: 34; radius: 17
                                    color: Qt.alpha(root.pal.surface, 0.7)
                                    border.width: 1
                                    border.color: pgIn.activeFocus ? root.pal.lineFocus : root.pal.lineSoft
                                    TextInput {
                                        id: pgIn
                                        anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap + 1
                                        validator: RegularExpressionValidator { regularExpression: /\d{0,4}\s*-?\s*\d{0,4}/ }
                                        text: root.pages
                                        onTextEdited: { root.pages = text; savedT.restart() }
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: pgIn.text.length === 0; text: "All pages"; color: root.pal.muted; font: pgIn.font }
                                    }
                                    Timer { id: savedT; interval: 500; onTriggered: { root.setMade(root.tab, null); root.loadSaved() } }
                                }
                                PrimaryBtn {
                                    disabled: root.making || root.docs.length === 0
                                    label: root.made[root.tab] ? "Write again" : (root.tab === "summary" ? "Write summary" : (root.tab === "quiz" ? "Write questions" : "Make cards"))
                                    glyph: String.fromCodePoint(root.made[root.tab] ? 0xF0450 : 0xF0674)
                                    onClicked: root.make(!!root.made[root.tab])
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                visible: root.tab !== "ask"

                                // nothing made yet / being made
                                Column {
                                    anchors.centerIn: parent
                                    width: Math.min(460, parent.width - 40)
                                    spacing: 12
                                    visible: !root.made[root.tab]
                                    Working { anchors.horizontalCenter: parent.horizontalCenter; visible: root.making && root.makeMode === root.tab; text: root.makeMsg }
                                    Text {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.WordWrap
                                        lineHeight: 1.3
                                        visible: !(root.making && root.makeMode === root.tab)
                                        text: root.docs.length === 0 ? "Add a file first."
                                            : "Made from " + root.scopeText + (root.pages.trim() !== "" ? ", pages " + root.pages.trim() : "")
                                              + ", only from what the files say. A long book takes a few minutes: type a page range to do one chapter."
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                    }
                                    Text {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        visible: root.making && root.makeMode !== root.tab
                                        text: "Still writing the " + root.makeMode + "; this starts when it is done."
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
                                    }
                                }

                                // summary
                                Flickable {
                                    id: sumF
                                    anchors.fill: parent
                                    visible: root.tab === "summary" && !!root.made.summary
                                    clip: true
                                    contentHeight: sumCol.height + 20
                                    boundsBehavior: Flickable.StopAtBounds
                                    Column {
                                        id: sumCol
                                        width: Math.min(sumF.width, 780)
                                        spacing: 14
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            textFormat: Text.RichText
                                            text: root.made.summary ? root.fmt(root.made.summary.body || root.made.summary.text) : ""
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody + 1
                                            lineHeight: 1.4
                                        }
                                        Row {
                                            spacing: 4
                                            LinkBtn { label: "Copy"; glyph: String.fromCodePoint(0xF018F); onClicked: root.copy(root.made.summary.text) }
                                            LinkBtn { label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(root.made.summary.text) }
                                        }
                                    }
                                }

                                // quiz: the question, and its answer when you click it
                                ListView {
                                    id: quizL
                                    anchors.fill: parent
                                    visible: root.tab === "quiz" && !!root.made.quiz
                                    clip: true
                                    spacing: 10
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.made.quiz ? root.made.quiz.items : []
                                    footer: Row {
                                        topPadding: 10
                                        spacing: 4
                                        LinkBtn { label: "Show every answer"; onClicked: { var c = {}; for (var i = 0; i < quizL.count; i++) c[i] = true; root.shown = c } }
                                        LinkBtn { label: "Copy"; glyph: String.fromCodePoint(0xF018F); onClicked: root.copy(root.made.quiz.text) }
                                        LinkBtn { label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(root.made.quiz.text) }
                                    }
                                    delegate: Rectangle {
                                        id: qrow
                                        required property var modelData
                                        required property int index
                                        readonly property bool open: !!root.shown[index]
                                        width: Math.min(quizL.width, 780)
                                        height: qCol.height + 30
                                        radius: root.pal.rLg
                                        color: qMa.containsMouse ? Qt.alpha(root.pal.surface, 0.85) : Qt.alpha(root.pal.surface, 0.55)
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        MouseArea { id: qMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { var c = {}; for (var k in root.shown) c[k] = root.shown[k]; c[qrow.index] = !qrow.open; root.shown = c } }
                                        Column {
                                            id: qCol
                                            x: 20; y: 15
                                            width: parent.width - 40
                                            spacing: 10
                                            Row {
                                                width: parent.width
                                                spacing: 12
                                                Text { text: (qrow.index + 1) + "."; color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                                Text { width: parent.width - 40; wrapMode: Text.Wrap; text: qrow.modelData.q; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium; lineHeight: 1.25 }
                                            }
                                            Text {
                                                width: parent.width
                                                leftPadding: 26
                                                wrapMode: Text.Wrap
                                                text: qrow.open ? qrow.modelData.a : "Show the answer"
                                                color: qrow.open ? root.pal.text : root.pal.muted
                                                opacity: qrow.open ? 0.9 : 0.8
                                                font.family: root.pal.uiFont
                                                font.pixelSize: qrow.open ? root.pal.tBody : root.pal.tCap + 1
                                                lineHeight: 1.3
                                            }
                                        }
                                    }
                                }

                                // flashcards: one at a time, click (or Space) to turn it, arrows for the next
                                Item {
                                    anchors.fill: parent
                                    visible: root.tab === "cards" && !!root.made.cards && root.made.cards.items.length > 0
                                    readonly property var cur: root.made.cards && root.made.cards.items.length > 0 ? root.made.cards.items[Math.min(root.cardIdx, root.made.cards.items.length - 1)] : null
                                    id: cardsV
                                    Rectangle {
                                        id: card
                                        anchors.centerIn: parent
                                        anchors.verticalCenterOffset: -24
                                        width: Math.min(560, parent.width - 40)
                                        height: Math.min(320, parent.height - 110)
                                        radius: root.pal.rXl
                                        color: root.cardBack ? Qt.alpha(root.pal.accent, 0.12) : Qt.alpha(root.pal.surface, 0.8)
                                        border.width: 1
                                        border.color: root.cardBack ? Qt.alpha(root.pal.accent, 0.35) : root.pal.lineSoft
                                        Behavior on color { ColorAnimation { duration: root.pal.dMed } }
                                        transform: Rotation {
                                            origin.x: card.width / 2; origin.y: card.height / 2
                                            axis { x: 0; y: 1; z: 0 }
                                            angle: flip.a
                                        }
                                        Item {
                                            id: flip
                                            property real a: 0
                                            SequentialAnimation {
                                                id: flipAnim
                                                NumberAnimation { target: flip; property: "a"; to: 90; duration: root.pal.dFast; easing.type: Easing.InSine }
                                                ScriptAction { script: flip.face = root.cardBack }
                                                NumberAnimation { target: flip; property: "a"; from: -90; to: 0; duration: root.pal.dFast; easing.type: Easing.OutSine }
                                            }
                                            property bool face: false
                                            Connections {
                                                target: root
                                                function onCardBackChanged() { flipAnim.restart() }
                                                function onCardIdxChanged() { flip.face = root.cardBack }
                                            }
                                        }
                                        Label { anchors { top: parent.top; left: parent.left; margins: 20 } text: flip.face ? "Answer" : "Question" }
                                        Text {
                                            anchors.centerIn: parent
                                            width: parent.width - 64
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.Wrap
                                            text: cardsV.cur ? (flip.face ? cardsV.cur.a : cardsV.cur.q) : ""
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: flip.face ? root.pal.tTitle + 1 : root.pal.tDisplay
                                            font.weight: flip.face ? Font.Normal : Font.Medium
                                            lineHeight: 1.3
                                            fontSizeMode: Text.Fit
                                            height: parent.height - 70
                                            verticalAlignment: Text.AlignVCenter
                                            minimumPixelSize: 12
                                        }
                                        Text {
                                            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 16 }
                                            text: flip.face ? "click for the question" : "click to see the answer"
                                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                        }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.cardBack = !root.cardBack }
                                    }
                                    Row {
                                        anchors { top: card.bottom; topMargin: 20; horizontalCenter: parent.horizontalCenter }
                                        spacing: 14
                                        RoundBtn { pal: root.pal; size: 34; glyph: String.fromCodePoint(0xF0141); onClicked: { var n = root.made.cards.items.length; root.cardIdx = (root.cardIdx + n - 1) % n; root.cardBack = false } }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: (root.cardIdx + 1) + " / " + (root.made.cards ? root.made.cards.items.length : 0); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        RoundBtn { pal: root.pal; size: 34; glyph: String.fromCodePoint(0xF0142); onClicked: { root.cardIdx = (root.cardIdx + 1) % root.made.cards.items.length; root.cardBack = false } }
                                        LinkBtn {
                                            anchors.verticalCenter: parent.verticalCenter
                                            label: "Shuffle"; glyph: String.fromCodePoint(0xF049D)
                                            onClicked: {
                                                var it = root.made.cards.items.slice()
                                                for (var i = it.length - 1; i > 0; i--) { var j = Math.floor(Math.random() * (i + 1)); var t = it[i]; it[i] = it[j]; it[j] = t }
                                                var c = {}
                                                for (var k in root.made.cards) c[k] = root.made.cards[k]
                                                c.items = it
                                                root.setMade("cards", c)
                                            }
                                        }
                                        LinkBtn { anchors.verticalCenter: parent.verticalCenter; label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(root.made.cards.text) }
                                    }
                                }
                            }
                        }
                    }

                    // the file browser lives inside the window (a file-chooser window would open under this overlay)
                    ExePicker {
                        id: picker
                        anchors.fill: parent
                        pal: root.pal
                        exts: root.exts
                        noun: "study"
                        fileGlyph: 0xF0214
                        title: "Add a file to study"
                        onPicked: path => { root.pickerOpen = false; picker.open = false; root.addFile(path); qp.forceActiveFocus() }
                        onCancelled: { root.pickerOpen = false; picker.open = false; qp.forceActiveFocus() }
                    }
                }
            }
        }
    }
}
