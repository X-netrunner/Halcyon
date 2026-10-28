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
    readonly property bool asWindow: open && pal.deskWin        // an ordinary window (Settings > Halcyon windows): Super+Q and opening another centre leave it alone (shell.qml)
    property string tab: "ask"              // ask | summary | quiz | cards
    signal focusRequested(string what)      // the window's own fields take the keyboard (ids inside the LazyLoader are not reachable)
    signal consoleRequested(string cmd)     // a model download runs in the pop-out console (it shows the progress)
    property bool consoleOpen: false        // the pop-out console has the keyboard (shell.qml)

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
    property var msgs: []                   // { role: "you" | "ai", text, sources: [], live, bad, model, secs, why, route, think }
    property int askSecs: 0                 // how long the answer being written has taken so far
    Timer { interval: 1000; repeat: true; running: root.asking; onTriggered: root.askSecs++ }

    // ---- the Study Center's own model (halcyon-study.py models / use): Auto routes each question, or one you pick
    property var models: []
    property var suggest: []
    property string choice: "auto"
    property string reason: "auto"          // step-by-step thinking: auto | always | never
    property string prefer: "balanced"      // what Auto favours: balanced | quality | speed
    property string autoFast: ""
    property string autoDeep: ""
    property real vram: 0
    property real ram: 0
    property bool modelsOk: true
    property bool modelsOpen: false
    readonly property string choiceLabel: choice === "auto" ? "Auto" : shortName(choice)
    function shortName(n) { n = String(n || ""); n = n.replace(/:latest$/, ""); var i = n.lastIndexOf("/"); return i >= 0 ? n.substring(i + 1) : n }
    function loadModels() { if (!modelsProc.running) modelsProc.running = true }
    Process {
        id: modelsProc
        command: ["python3", root.script, "models", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text)
                    root.modelsOk = o.ok !== false
                    root.models = o.models || []
                    root.suggest = o.suggest || []
                    root.choice = o.choice || "auto"
                    root.reason = o.reason || "auto"
                    root.prefer = o.prefer || "balanced"
                    root.autoFast = o.auto ? (o.auto.fast || "") : ""
                    root.autoDeep = o.auto ? (o.auto.deep || "") : ""
                    root.vram = o.vram || 0
                    root.ram = o.ram || 0
                } catch (e) {}
            }
        }
    }
    Process { id: useProc; onExited: root.loadModels() }
    function useModel(args) {
        if (useProc.running) return
        useProc.command = ["python3", script, "use"].concat(args)
        useProc.running = true
    }
    function pickModel(n) { choice = n; useModel([n]) }
    function setReason(r) { reason = r; useModel(["--reason", r]) }
    function setPrefer(p) { prefer = p; useModel(["--prefer", p]) }
    function pull(n) { consoleRequested("ollama pull " + n) }    // the window stays; the console opens over it

    // ---- the saved conversation: shown again when the window opens
    Process {
        id: chatProc
        command: ["python3", root.script, "chat", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.msgs.length > 0 || root.asking) return
                try {
                    var t = JSON.parse(text).turns || [], m = []
                    for (var i = 0; i < t.length; i++) {
                        m.push({ role: "you", text: t[i].q })
                        m.push({ role: "ai", text: t[i].a || "", sources: t[i].sources || [], live: false, bad: false, model: t[i].model || "", secs: t[i].secs || 0, why: "", route: "", think: "" })
                    }
                    root.msgs = m
                } catch (e) {}
            }
        }
    }
    property string status: ""              // "looking through your files" ...

    // ---- summary / quiz / cards: the last result per tab
    property var made: ({ summary: null, quiz: null, cards: null })
    property string makeMode: ""            // the tab whose result is being written now
    property string makeMsg: ""
    property string pages: ""               // "3-9": only those pages
    property int cardIdx: 0
    property bool cardBack: false
    property var shown: ({})                // quiz: the answers turned over (index -> true)
    property var grades: ({})               // quiz: your own answers, marked (index -> { verdict, feedback })
    property int gradingIdx: -1
    property var known: ({})                // flashcards you knew (index -> true): they leave the round
    readonly property int knownCount: { var n = 0; for (var k in known) if (known[k]) n++; return n }
    function grade(i, mine) {
        var it = made.quiz ? made.quiz.items[i] : null
        if (!it || String(mine).trim() === "" || gradeProc.running) return
        gradingIdx = i
        gradeProc.command = ["python3", script, "grade", "--json", "--q", it.q, "--key", it.a, "--mine", String(mine)]
        gradeProc.running = true
    }
    Process {
        id: gradeProc
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                var c = {}
                for (var k in root.grades) c[k] = root.grades[k]
                if (o.type === "graded") c[root.gradingIdx] = { verdict: o.verdict, feedback: o.feedback }
                else if (o.type === "error") c[root.gradingIdx] = { verdict: "error", feedback: o.error }
                root.grades = c
            }
        }
        onExited: root.gradingIdx = -1
    }
    // the next card you do not know yet (wrapping round); -1 when you know them all
    function nextCard(step) {
        var it = made.cards ? made.cards.items : []
        for (var d = 1; d <= it.length; d++) {
            var j = ((cardIdx + step * d) % it.length + it.length) % it.length
            if (!known[j]) return j
        }
        return -1
    }
    function markCard(knew) {
        var c = {}
        for (var k in known) c[k] = known[k]
        if (knew) c[cardIdx] = true
        known = c
        var n = nextCard(1)
        cardBack = false
        if (n >= 0) cardIdx = n
    }

    readonly property bool asking: askProc.running
    readonly property bool making: makeProc.running
    readonly property bool busy: asking || making || addProc.running

    function show(t) {
        if (t === "summary" || t === "quiz" || t === "cards" || t === "ask") tab = t
        open = true
        note = ""
        reload()
        loadModels()
        if (msgs.length === 0 && !chatProc.running) chatProc.running = true
        if (tab !== "ask") loadSaved()
    }
    function hide() { open = false; pickerOpen = false; confirmRm = ""; modelsOpen = false }
    function toggle() { if (open) hide(); else show("") }
    function setTab(t) {
        tab = t
        pickerOpen = false
        if (t !== "ask") loadSaved()
        Qt.callLater(function () { root.focusRequested(t === "ask" ? "ask" : "panel") })
    }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: (root.pal ? root.pal.dMed : 300) + 80; onTriggered: root.linger = false }

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
                .replace(/\[([^\[\]]{2,90}(?:page|part|slide|image)[^\[\]]{0,20})\]/gi, "<span style=\"color:" + String(pal.muted) + "\"><small>[$1]</small></span>")
    }
    // a line that is only a source label ("[Notes, part 4]", also when the model bolded it): a small accent label that opens the paragraph under it
    function srcLabel(l) {
        var m = /^\s*(?:\*\*|__)?\s*\[([^\[\]]{2,90}(?:page|part|slide|image)[^\[\]]{0,20})\]\s*:?\s*(?:\*\*|__)?\s*$/i.exec(l)
        return m ? m[1] : ""
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
            var sl = srcLabel(l)
            if (sl !== "") { out.push("<div style=\"margin-top:10px;margin-bottom:1px\"><span style=\"color:" + String(pal.accent) + "\"><small><b>" + sl + "</b></small></span></div>"); continue }
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

    // model: "" = Auto / the picked one, "best" = the best model (the "Ask the best model" link under a quick answer)
    function ask(q, model) {
        q = String(q || "").trim()
        if (q === "" || asking) return
        if (docs.length === 0) { flash("Add a file first: the answers come from your files", true); return }
        var hist = []
        for (var i = 0; i + 1 < msgs.length; i++)
            if (msgs[i].role === "you" && msgs[i + 1].role === "ai" && !msgs[i + 1].bad) hist.push({ q: msgs[i].text, a: msgs[i + 1].text, model: msgs[i + 1].model || "" })
        hist = hist.slice(-3)
        msgs = msgs.concat([{ role: "you", text: q }, { role: "ai", text: "", sources: [], live: true, bad: false, model: "", secs: 0, why: "", route: "", think: "" }])
        status = "looking through your files"
        askSecs = 0
        askProc.command = ["python3", script, "ask", "--json"].concat(docArgs()).concat(["--history", JSON.stringify(hist)])
                          .concat(model ? ["--model", model] : []).concat(["--", q])
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
                else if (o.type === "model") root.patchLast(function (c) { c.model = o.model; c.why = o.why; c.route = o.route })
                else if (o.type === "think") { root.status = "thinking it through"; root.patchLast(function (c) { c.think += o.t }) }
                else if (o.type === "reset") { root.pend = ""; root.patchLast(function (c) { c.text = o.text }) }
                else if (o.type === "done") root.patchLast(function (c) { c.secs = o.secs || root.askSecs })
                else if (o.type === "error") { root.flushPend(); root.patchLast(function (c) { c.text = (c.text ? c.text + "\n\n" : "") + o.error; c.bad = true }) }
            }
        }
        onExited: {
            root.flushPend()
            root.status = ""
            root.patchLast(function (c) { c.live = false; if (c.text === "") { c.text = "Stopped."; c.bad = true } })
        }
    }
    function clearChat() { if (asking) return; msgs = []; Quickshell.execDetached(["python3", script, "chat", "--clear"]) }

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
        if (mode === "cards") { cardIdx = 0; cardBack = false; known = ({}) }
        if (mode === "quiz") { shown = ({}); grades = ({}) }
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
        border.width: root.pal.zen && !(scMa.containsMouse) ? 0 : 1
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
        Host {
            id: win
            desktop: root.pal.deskWin
            title: "Study"
            deskWidth: 1160
            deskHeight: 760
            namespace: "island-study"
            // while the console is up (a command this window sent) it has the keyboard; this window stays open behind it
            keyboardFocus: (root.open && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            onCloseRequested: root.hide()

            MouseArea { anchors.fill: parent; enabled: !win.desktop; onClicked: root.hide() }

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
                    if (e.key === Qt.Key_Escape) { if (root.pickerOpen) root.pickerOpen = false; else if (root.modelsOpen) root.modelsOpen = false; else root.hide(); e.accepted = true }
                    else if (root.tab === "cards" && root.made.cards && (e.key === Qt.Key_Right || e.key === Qt.Key_Left)) {
                        var nx = root.nextCard(e.key === Qt.Key_Right ? 1 : -1)
                        if (nx >= 0) root.cardIdx = nx
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

                Rectangle { visible: !win.desktop; anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: win.desktop ? qp.width : Math.min(1160, qp.width - 80)
                    height: win.desktop ? qp.height : Math.min(760, qp.height - 80)
                    radius: win.desktop ? 0 : root.pal.rXl
                    opacityBody: 0.97
                    anchors.centerIn: parent
                    opacity: win.desktop ? 1 : qp.reveal
                    scale: win.desktop ? 1 : 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== the library
                        Item {
                            Layout.preferredWidth: 286
                            Layout.fillHeight: true
                            // only the left corners are round: the right edge meets the content. One shape, wider than the item and clipped, so
                            // the translucent colour is painted once (a second patch over the right edge made a darker band down the middle)
                            Item {
                                anchors.fill: parent
                                anchors.margins: 1
                                clip: true
                                Rectangle {
                                    width: parent.width + root.pal.rXl
                                    height: parent.height
                                    radius: root.pal.rXl
                                    color: root.pal.box(Qt.alpha(root.pal.surface, 0.35))
                                }
                            }
                            Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right; topMargin: 24; bottomMargin: 24 } width: 1; color: root.pal.lineSoft }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 22
                                anchors.rightMargin: 23                // 22 + the 1 px line on the sidebar's edge
                                spacing: 16

                                Row {
                                    Layout.fillWidth: true
                                    Layout.maximumWidth: 242
                                    spacing: 12
                                    Rectangle {
                                        visible: !root.pal.zen          // the new style: no icon tile in the header
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
                                        width: parent.width - 50                      // what is left of the sidebar after the icon: the lines below wrap instead of running off the edge
                                        spacing: 1
                                        Text { width: parent.width; elide: Text.ElideRight; horizontalAlignment: root.pal.centred ? Text.AlignHCenter : Text.AlignLeft; text: "Study"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 3; font.weight: Font.DemiBold }
                                        Text { width: parent.width; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; horizontalAlignment: root.pal.centred ? Text.AlignHCenter : Text.AlignLeft; text: "on this computer  ·  " + (root.choice === "auto" ? (root.autoDeep !== "" ? "Auto, up to " + root.shortName(root.autoDeep) : "Auto") : root.shortName(root.choice)); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
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
                                    Layout.maximumWidth: 242
                                    Layout.alignment: Qt.AlignHCenter
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
                                // the model: Auto (smart routing) or the one picked; a click opens the model sheet
                                Rectangle {
                                    implicitWidth: mcRow.implicitWidth + 24
                                    implicitHeight: 30
                                    radius: 15
                                    color: root.modelsOpen ? Qt.alpha(root.pal.accent, 0.16) : (mcMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Row {
                                        id: mcRow
                                        anchors.centerIn: parent
                                        spacing: 7
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: String.fromCodePoint(0xF06A9); color: root.modelsOpen ? root.pal.accent : root.pal.muted; font.family: root.pal.font; font.pixelSize: 14 }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.choiceLabel; color: root.modelsOpen ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.Medium }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: String.fromCodePoint(root.modelsOpen ? 0xF0143 : 0xF0140); color: root.pal.muted; font.family: root.pal.font; font.pixelSize: 13 }
                                    }
                                    MouseArea { id: mcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.modelsOpen = !root.modelsOpen; if (root.modelsOpen) root.loadModels() } }
                                }
                                Text {
                                    Layout.maximumWidth: 320
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
                                                border.width: root.pal.zen && !(sugMa.containsMouse) ? 0 : 1
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
                                    model: root.msgs.length         // a number: an array replaced for every streamed chunk would rebuild every bubble (the flicker)
                                    onCountChanged: Qt.callLater(function () { chat.positionViewAtEnd() })
                                    onContentHeightChanged: if (root.asking) positionViewAtEnd()
                                    delegate: Item {
                                        id: mrow
                                        required property int index
                                        readonly property var modelData: root.msgs[index] || ({ role: "ai", text: "", sources: [], live: false, bad: false })
                                        readonly property bool you: modelData.role === "you"
                                        property bool allSrc: false
                                        property bool showThink: false
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
                                            SelText { id: youT; x: 16; y: 10; width: parent.width - 32; wrapMode: TextEdit.Wrap; text: mrow.modelData.text; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        }
                                        // the answer: plain on the glass, a thin accent line beside it, the sources under it
                                        Column {
                                            id: aiCol
                                            visible: !mrow.you
                                            width: Math.min(parent.width, 760)
                                            spacing: 10
                                            Working {
                                                visible: mrow.modelData.live === true && mrow.modelData.text === ""
                                                text: (root.status !== "" ? root.status.replace(/ (with|using) \S+$/, "") : "thinking") + (mrow.modelData.model ? "  \u00b7  " + root.shortName(mrow.modelData.model) : "") + (root.askSecs > 2 ? "  \u00b7  " + root.askSecs + " s" : "")
                                            }
                                            Row {
                                                spacing: 14
                                                visible: mrow.modelData.text !== ""
                                                Rectangle { width: 2; height: aiT.height; radius: 1; color: mrow.modelData.bad ? Qt.alpha(root.pal.bad, 0.6) : Qt.alpha(root.pal.accent, 0.45) }
                                                SelText {
                                                    id: aiT
                                                    width: aiCol.width - 16
                                                    wrapMode: TextEdit.Wrap
                                                    textFormat: TextEdit.RichText
                                                    text: root.fmt(mrow.modelData.text)
                                                    color: mrow.modelData.bad ? root.pal.bad : root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody + 1
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
                                            // which model wrote it, and how long it took; a quick answer can be asked again of the best model
                                            Row {
                                                leftPadding: 16
                                                spacing: 4
                                                visible: !mrow.modelData.live && !mrow.modelData.bad && (mrow.modelData.model || "") !== ""
                                                Text {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: root.shortName(mrow.modelData.model) + (mrow.modelData.secs ? "  \u00b7  " + mrow.modelData.secs + " s" : "") + (mrow.modelData.why ? "  \u00b7  " + mrow.modelData.why : "")
                                                    color: Qt.alpha(root.pal.muted, 0.8)
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                    rightPadding: 6
                                                }
                                                LinkBtn {
                                                    visible: mrow.modelData.route === "quick" && root.autoDeep !== "" && root.autoDeep !== mrow.modelData.model && mrow.index === root.msgs.length - 1
                                                    label: "Ask the best model"
                                                    glyph: String.fromCodePoint(0xF0674)
                                                    onClicked: root.ask(root.msgs[mrow.index - 1].text, "best")
                                                }
                                                LinkBtn {
                                                    visible: (mrow.modelData.think || "") !== ""
                                                    label: mrow.showThink ? "Hide the reasoning" : "Show the reasoning"
                                                    onClicked: mrow.showThink = !mrow.showThink
                                                }
                                            }
                                            Text {
                                                visible: mrow.showThink
                                                width: parent.width
                                                leftPadding: 16
                                                wrapMode: Text.Wrap
                                                text: mrow.modelData.think || ""
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                                lineHeight: 1.3
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
                                    color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.75))
                                    border.width: root.pal.zen && !askIn.activeFocus ? 0 : 1
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
                                            } else if (e.key === Qt.Key_Escape) { if (root.modelsOpen) root.modelsOpen = false; else root.hide(); e.accepted = true }
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
                                    color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.7))
                                    border.width: root.pal.zen && !pgIn.activeFocus ? 0 : 1
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
                                            // try it yourself: type an answer, Enter, and the model marks it
                                            Rectangle {
                                                x: 26
                                                width: parent.width - 26
                                                height: 36
                                                radius: 18
                                                color: root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.bg, 0.45)
                                                border.width: mineIn.activeFocus ? 1 : 0
                                                border.color: root.pal.lineFocus
                                                TextInput {
                                                    id: mineIn
                                                    anchors { left: parent.left; right: chk.left; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 8 }
                                                    clip: true
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap + 1
                                                    selectionColor: Qt.alpha(root.pal.accent, 0.4)
                                                    onAccepted: root.grade(qrow.index, text)
                                                    Keys.onEscapePressed: { if (text !== "") text = ""; else focus = false }
                                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: mineIn.text.length === 0; text: "Your answer, then Enter: it gets marked"; color: Qt.alpha(root.pal.muted, 0.85); font: mineIn.font }
                                                }
                                                LinkBtn {
                                                    id: chk
                                                    anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                                                    visible: mineIn.text.trim() !== ""
                                                    label: root.gradingIdx === qrow.index ? "Marking\u2026" : "Check"
                                                    onClicked: root.grade(qrow.index, mineIn.text)
                                                }
                                            }
                                            Row {
                                                x: 26
                                                width: parent.width - 26
                                                spacing: 10
                                                readonly property var g: root.grades[qrow.index] || null
                                                visible: g !== null
                                                Text {
                                                    text: !parent.g ? "" : (parent.g.verdict === "right" ? "\u2713  Right" : (parent.g.verdict === "partly" ? "\u2248  Partly" : (parent.g.verdict === "error" ? "" : "\u2715  Not quite")))
                                                    color: !parent.g ? root.pal.muted : (parent.g.verdict === "right" ? root.pal.good : (parent.g.verdict === "partly" ? root.pal.warn : root.pal.bad))
                                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.DemiBold
                                                }
                                                Text {
                                                    width: parent.width - 100
                                                    wrapMode: Text.Wrap
                                                    text: parent.g ? parent.g.feedback : ""
                                                    color: parent.g && parent.g.verdict === "error" ? root.pal.bad : root.pal.text
                                                    opacity: 0.85
                                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; lineHeight: 1.25
                                                }
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
                                        border.width: root.pal.zen && !(root.cardBack) ? 0 : 1
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
                                    // turned over: did you know it? Known cards leave the round, the others come back
                                    Row {
                                        id: judgeRow
                                        anchors { top: card.bottom; topMargin: 16; horizontalCenter: parent.horizontalCenter }
                                        spacing: 10
                                        opacity: root.cardBack ? 1 : 0
                                        visible: opacity > 0.01
                                        Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
                                        ActionChip { pal: root.pal; implicitHeight: 34; glyph: String.fromCodePoint(0xF0450); label: "Again"; onClicked: root.markCard(false) }
                                        ActionChip { pal: root.pal; implicitHeight: 34; glyph: String.fromCodePoint(0xF012C); label: "Knew it"; on: true; onClicked: root.markCard(true) }
                                    }
                                    // all known: a quiet well done
                                    Rectangle {
                                        anchors.fill: card
                                        radius: card.radius
                                        visible: root.made.cards && root.knownCount >= root.made.cards.items.length && root.made.cards.items.length > 0
                                        color: Qt.alpha(root.pal.bg, 0.94)
                                        MouseArea { anchors.fill: parent }
                                        Column {
                                            anchors.centerIn: parent
                                            spacing: 12
                                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: String.fromCodePoint(0xF04CE); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 34 }
                                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "You knew all " + (root.made.cards ? root.made.cards.items.length : 0); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 2; font.weight: Font.Medium }
                                            ActionChip { anchors.horizontalCenter: parent.horizontalCenter; pal: root.pal; label: "Go round again"; onClicked: { root.known = ({}); root.cardIdx = 0; root.cardBack = false } }
                                        }
                                    }
                                    Row {
                                        anchors { top: judgeRow.bottom; topMargin: 14; horizontalCenter: parent.horizontalCenter }
                                        spacing: 14
                                        RoundBtn { pal: root.pal; size: 34; glyph: String.fromCodePoint(0xF0141); onClicked: { var n = root.nextCard(-1); if (n >= 0) root.cardIdx = n; root.cardBack = false } }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: (root.cardIdx + 1) + " / " + (root.made.cards ? root.made.cards.items.length : 0) + (root.knownCount > 0 ? "  \u00b7  " + root.knownCount + " known" : ""); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        RoundBtn { pal: root.pal; size: 34; glyph: String.fromCodePoint(0xF0142); onClicked: { var n = root.nextCard(1); if (n >= 0) root.cardIdx = n; root.cardBack = false } }
                                        LinkBtn {
                                            anchors.verticalCenter: parent.verticalCenter
                                            label: "Shuffle"; glyph: String.fromCodePoint(0xF049D)
                                            onClicked: {
                                                var it = root.made.cards.items.slice()
                                                for (var i = it.length - 1; i > 0; i--) { var j = Math.floor(Math.random() * (i + 1)); var t = it[i]; it[i] = it[j]; it[j] = t }
                                                var c = {}
                                                for (var k in root.made.cards) c[k] = root.made.cards[k]
                                                c.items = it
                                                root.setMade("cards", c)          // (a shuffle also starts the round again)
                                            }
                                        }
                                        LinkBtn { anchors.verticalCenter: parent.verticalCenter; label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(root.made.cards.text) }
                                    }
                                }
                            }
                        }
                    }

                    // ---- the model sheet: Auto and how it routes, every installed model with how it runs here, what to download
                    MouseArea { anchors.fill: parent; visible: root.modelsOpen; onClicked: root.modelsOpen = false }
                    Glass {
                        id: sheet
                        pal: root.pal
                        visible: opacity > 0.01
                        opacity: root.modelsOpen ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
                        anchors { top: parent.top; right: parent.right; bottom: parent.bottom; topMargin: 70; rightMargin: 24; bottomMargin: 24 }
                        width: 440
                        radius: root.pal.rLg
                        opacityBody: 0.98
                        MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }
                        Flickable {
                            id: shF
                            anchors.fill: parent
                            anchors.margins: 20
                            clip: true
                            contentHeight: shCol.height
                            boundsBehavior: Flickable.StopAtBounds
                            Column {
                                id: shCol
                                width: shF.width
                                spacing: 14
                                Column {
                                    width: parent.width
                                    spacing: 3
                                    Text { text: "Model for studying"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                                    Text {
                                        width: parent.width; wrapMode: Text.Wrap
                                        text: (root.vram > 0 ? root.vram + " GB graphics memory, " : "No graphics memory found, ") + root.ram + " GB RAM. Only the Study Center uses this; the rest of Halcyon keeps its own model."
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; lineHeight: 1.25
                                    }
                                }
                                Text { visible: !root.modelsOk; width: parent.width; wrapMode: Text.Wrap; text: "Ollama is not running, so the models cannot be listed. Start it with: systemctl --user start ollama"; color: root.pal.warn; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }

                                // Auto
                                Rectangle {
                                    width: parent.width
                                    height: autoCol.height + 24
                                    radius: root.pal.rMd
                                    color: root.choice === "auto" ? Qt.alpha(root.pal.accent, 0.14) : (autoMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                    MouseArea { id: autoMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickModel("auto") }
                                    Column {
                                        id: autoCol
                                        x: 14; y: 12
                                        width: parent.width - 28
                                        spacing: 4
                                        Text { text: "Auto  \u00b7  smart routing" + (root.choice === "auto" ? "   \u2713" : ""); color: root.choice === "auto" ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                        Text {
                                            width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.25
                                            text: root.autoDeep === "" ? "No model to route to yet." : (root.autoFast === root.autoDeep
                                                ? "Every question goes to " + root.shortName(root.autoDeep) + "."
                                                : "Quick lookups go to " + root.shortName(root.autoFast) + " (seconds). Explanations, reasoning, summaries, quizzes and cards go to " + root.shortName(root.autoDeep) + ". A follow-up stays with the model of the conversation.")
                                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
                                        }
                                    }
                                }
                                // what Auto favours
                                Column {
                                    width: parent.width
                                    spacing: 6
                                    Text { text: "Auto favours"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                    Row {
                                        spacing: 6
                                        Repeater {
                                            model: [["balanced", "Balance"], ["quality", "Best answers"], ["speed", "Speed"]]
                                            delegate: Chip { required property var modelData; pal: root.pal; implicitHeight: 30; label: modelData[1]; on: root.prefer === modelData[0]; onClicked: root.setPrefer(modelData[0]) }
                                        }
                                    }
                                    Text {
                                        width: parent.width; wrapMode: Text.Wrap
                                        text: root.prefer === "quality" ? "The best model you have, even when an answer takes a few minutes." : (root.prefer === "speed" ? "Only models that answer within seconds." : "A slow model only when it is clearly better.")
                                        color: Qt.alpha(root.pal.muted, 0.85); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                }
                                // step-by-step thinking
                                Column {
                                    width: parent.width
                                    spacing: 6
                                    Text { text: "Think step by step"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                    Row {
                                        spacing: 6
                                        Repeater {
                                            model: [["auto", "For maths and proofs"], ["always", "Always"], ["never", "Never"]]
                                            delegate: Chip { required property var modelData; pal: root.pal; implicitHeight: 30; label: modelData[1]; on: root.reason === modelData[0]; onClicked: root.setReason(modelData[0]) }
                                        }
                                    }
                                    Text {
                                        width: parent.width; wrapMode: Text.Wrap
                                        text: "Models that can think (qwen3) work the answer out first: better for calculations, slower. The reasoning stays hidden under the answer."
                                        color: Qt.alpha(root.pal.muted, 0.85); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                }

                                Text { text: "Installed"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; topPadding: 4 }
                                Repeater {
                                    model: root.models
                                    delegate: Rectangle {
                                        id: mr
                                        required property var modelData
                                        readonly property bool on: root.choice === modelData.name
                                        width: shCol.width
                                        height: mrCol.height + 20
                                        radius: root.pal.rMd
                                        opacity: modelData.usable ? 1 : 0.45
                                        color: on ? Qt.alpha(root.pal.accent, 0.14) : (mrMa.containsMouse && modelData.usable ? root.pal.fillHover : "transparent")
                                        MouseArea { id: mrMa; anchors.fill: parent; hoverEnabled: true; enabled: mr.modelData.usable; cursorShape: Qt.PointingHandCursor; onClicked: root.pickModel(mr.modelData.name) }
                                        Column {
                                            id: mrCol
                                            x: 14; y: 10
                                            width: parent.width - 28
                                            spacing: 4
                                            Row {
                                                width: parent.width
                                                spacing: 8
                                                Text { width: Math.min(implicitWidth, parent.width - 150); elide: Text.ElideRight; text: root.shortName(mr.modelData.name) + (mr.on ? "  \u2713" : ""); color: mr.on ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                // quality as five soft dots
                                                Row {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: 3
                                                    Repeater { model: 5; delegate: Rectangle { required property int index; width: 6; height: 6; radius: 3; color: index < Math.round(mr.modelData.quality / 2) ? root.pal.accent : Qt.alpha(root.pal.text, 0.14) } }
                                                }
                                                Text {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: mr.modelData.name === root.autoDeep ? "Auto: explanations" : (mr.modelData.name === root.autoFast ? "Auto: lookups" : "")
                                                    color: root.pal.accent2; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                                }
                                            }
                                            Text {
                                                width: parent.width; wrapMode: Text.Wrap
                                                text: mr.modelData.size + " GB  \u00b7  " + mr.modelData.speedNote + "\n" + mr.modelData.note
                                                color: mr.modelData.speed === "fast" ? root.pal.muted : (mr.modelData.speed === "slow" ? Qt.alpha(root.pal.warn, 0.9) : root.pal.muted)
                                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; lineHeight: 1.25
                                            }
                                        }
                                    }
                                }

                                Text { visible: root.suggest.length > 0; text: "Worth downloading"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; topPadding: 4 }
                                Repeater {
                                    model: root.suggest
                                    delegate: Item {
                                        id: sg
                                        required property var modelData
                                        width: shCol.width
                                        height: sgCol.height + 16
                                        Column {
                                            id: sgCol
                                            x: 14; y: 8
                                            width: parent.width - 120
                                            spacing: 3
                                            Text { text: sg.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                            Text { width: parent.width; wrapMode: Text.Wrap; text: sg.modelData.size + " GB  \u00b7  " + sg.modelData.speedNote + "\n" + sg.modelData.note; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; lineHeight: 1.25 }
                                        }
                                        ActionChip { anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter } pal: root.pal; implicitHeight: 30; label: "Download"; onClicked: root.pull(sg.modelData.name) }
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
