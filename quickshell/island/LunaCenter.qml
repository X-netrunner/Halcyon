import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Luna.   >luna in the launcher (also `island command luna`, the IPC call `luna`, `halcyon luna`).
// Your conversations with Luna, the local assistant (install.sh --luna), one saved session each. Open an old one and carry on where it
// stopped: Luna gets that conversation's own memory back. While she works you see what she is doing (the tools she runs) and, if you
// want, her reasoning. Everything goes through scripts/halcyon-luna.py (sessions in ~/.local/share/halcyon/luna) and her `--stdio` mode;
// nothing leaves the machine. Nothing runs while the window is closed (LazyLoader, no timers, no processes), except an answer that was
// still being written: it finishes and is there when you come back.
Scope {
    id: root
    property var pal
    property bool open: false
    signal scrollEnd()                      // the chat jumps to the newest message and follows it again
    signal focusRequested(string what)      // the window's own field takes the keyboard (ids inside the LazyLoader are not reachable)
    property bool consoleOpen: false        // kept for the same wiring as the other centers (shell.qml)

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-luna.py"

    // ---- state
    property var sessions: []               // { id, title, updated, count, preview }
    property string cur: ""                 // the open session ("" = a new chat, made when you send the first message)
    // the open chat, as a ListModel changed in place (a plain array that is replaced on every word of her reasoning rebuilt every row
    // and made the whole window flicker): { role: "you" | "luna" | "sys", text, mname, secs, think, live, bad, toolsJson }
    ListModel { id: mm }
    readonly property int msgCount: mm.count
    function mrec(o) { return { role: o.role, text: o.text || "", mname: o.model || "", secs: o.secs || 0, think: o.think || "", live: o.live === true, bad: o.bad === true, toolsJson: JSON.stringify(o.tools || []) } }
    function setMsgs(arr) { mm.clear(); for (var i = 0; i < arr.length; i++) mm.append(mrec(arr[i])) }
    function pushMsg(o) { mm.append(mrec(o)) }
    property bool ok: true                  // Luna installed and the AI on
    property string problem: ""
    property string status: ""              // what she is doing right now
    property int secs: 0
    property string confirmDel: ""
    property string renaming: ""
    property string note: ""
    readonly property bool busy: chatProc.running || newProc.running
    Timer { interval: 1000; repeat: true; running: root.busy; onTriggered: root.secs++ }

    function show() {
        open = true
        note = ""
        call("prefs", ["pref"])
        call("stats", ["stats"])
        check()
        reload(true)
    }
    function hide() { open = false; confirmDel = ""; renaming = ""; keyOpen = ""; modelMenu = ""; view = "chat" }
    function toggle() { if (open) hide(); else show() }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }
    function flash(t) { note = t; noteT.restart() }
    Timer { id: noteT; interval: 5000; onTriggered: root.note = "" }
    function shortName(n) { n = String(n || ""); n = n.replace(/:latest$/, ""); var i = n.lastIndexOf("/"); return i >= 0 ? n.substring(i + 1) : n }
    function ago(ts) {
        var d = Math.max(0, Date.now() / 1000 - ts)
        if (d < 90) return "now"
        if (d < 5400) return Math.round(d / 60) + " min"
        if (d < 129600) return Math.round(d / 3600) + " h"
        return Math.round(d / 86400) + " d"
    }

    // the model's text -> rich text: **bold**, `code`, lists, headings (the same small subset the Study Center draws)
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function inline(l) {
        return l.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<i>$2</i>")
                .replace(/`([^`]+)`/g, "<span style=\"font-family:'" + pal.mono + "'\">$1</span>")
    }
    function fmt(t) {
        var lines = esc(t).split("\n"), out = [], list = ""
        function close() { if (list !== "") { out.push("</" + list + ">"); list = "" } }
        function opn(kind) { if (list !== kind) { close(); out.push("<" + kind + " style=\"margin-top:2px;margin-bottom:6px;margin-left:-14px\">"); list = kind } }
        var code = false
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]
            if (/^\s*```/.test(l)) { close(); code = !code; out.push(code ? "<pre style=\"font-family:'" + pal.mono + "'\">" : "</pre>"); continue }
            if (code) { out.push(l + "\n"); continue }
            var h = /^\s*#{1,4}\s+(.*)$/.exec(l), bu = /^\s*[-*•]\s+(.*)$/.exec(l), nu = /^\s*\d+[.)]\s+(.*)$/.exec(l)
            if (bu) { opn("ul"); out.push("<li>" + inline(bu[1]) + "</li>"); continue }
            if (nu) { opn("ol"); out.push("<li>" + inline(nu[1]) + "</li>"); continue }
            close()
            if (l.trim() === "") { out.push("<div style=\"font-size:6px\">&nbsp;</div>"); continue }
            if (h) out.push("<div style=\"margin-top:6px\"><b>" + inline(h[1]) + "</b></div>")
            else out.push("<div>" + inline(l) + "</div>")
        }
        if (code) out.push("</pre>")
        close()
        return out.join("")
    }


    // ---- Luna's settings (the terminal UI's, as a page), her models, her API keys
    property string view: "chat"            // chat | settings
    property var cfg: null                  // { categories: [{ name, items: [{ key, label, kind, value, options }] }], keys: [{ name, label, help, set }] }
    property var installed: []              // [{ name, gb }]
    property var roles: ({})                // { model, fast, deep, security }
    property bool reachable: true
    property string role: "model"           // kept for /model
    property bool auto: true                // Luna picks the model per question
    property string page: "models"          // the settings page that is open
    property string modelMenu: ""           // the open model menu ("" = none)
    property var stats: ({ n: 0, avg: 0, median: 0, models: [] })
    function fmtSecs(x) { x = Number(x) || 0; return x < 90 ? Math.round(x) + " s" : (x / 60).toFixed(1) + " min" }
    property var gate: ({ state: "", requested: false, key: false, effective: false })
    property var prefs: ({ liveThink: false, notifyDone: true, speakReplies: false })
    property var voiceInfo: ({ ok: false, mode: "", missing: [] })
    property bool voiceKnown: false
    function clean(n) { return String(n || "").replace(/^[^A-Za-z]+/, "") }
    readonly property var refusalKeys: ["llm.security_unrestricted", "llm.security_retry_on_refusal"]
    function itemPage(cat, key) { return refusalKeys.indexOf(key) >= 0 ? "refusal" : (clean(cat) === "AI & Models" ? "models" : clean(cat)) }
    function catShows(c) {
        for (var i = 0; i < c.items.length; i++) { var it = c.items[i]; if (!(it.kind === "value" && !it.options) && itemPage(c.name, it.key) === page) return true }
        return false
    }
    readonly property var pages: {
        var p = [["models", "Models"]], c = cfg ? cfg.categories : []
        for (var i = 0; i < c.length; i++) if (clean(c[i].name) !== "AI & Models") p.push([clean(c[i].name), clean(c[i].name)])
        p.push(["refusal", "No-refusal mode"], ["window", "This window"], ["keys", "API keys"])
        return p
    }
    function pageTitle() { for (var i = 0; i < pages.length; i++) if (pages[i][0] === page) return pages[i][1]; return "Settings" }
    function modelOpts(withAuto) {
        var o = withAuto ? [{ id: "__auto", text: "Auto", sub: "Luna picks for each question" }] : []
        for (var i = 0; i < installed.length; i++) o.push({ id: installed[i].name, text: shortName(installed[i].name), sub: installed[i].gb + " GB" })
        return o
    }
    function setPref(k, v) { call("prefs", ["pref", k, v ? "on" : "off"]) }
    // Pop out: this window becomes an ordinary window on the workspace you are on (Settings > Workspaces & windows > Halcyon windows)
    function setWindowMode(m) {
        Quickshell.execDetached(["quickshell", "ipc", "-p", Quickshell.env("HOME") + "/.config/Halcyon/quickshell/island", "call", "island", "setopt", "windowMode", JSON.stringify(m)])
    }
    function termRun(cmd) { Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "term-exec", "bash", "-c", cmd + "; echo; read -n1 -s -r -p 'Press any key to close'"]) }
    // the end of her reasoning, for the live view
    function tail(t) { t = String(t || ""); if (t.length <= 700) return t; t = t.substring(t.length - 700); var i = t.indexOf(" "); return "…" + (i > 0 ? t.substring(i) : t) }
    property string keyOpen: ""             // the key being pasted
    property string keyMsg: ""
    readonly property var roleNames: [["model", "Main"], ["fast", "Fast"], ["deep", "Deep"], ["security", "Security"]]
    function openSettings() { view = "settings"; modelMenu = ""; loadSettings() }
    function showSettings() { show(); openSettings() }
    function loadSettings() { call("settings", ["settings"]); call2("models", ["models"]); call("prefs", ["pref"]); call("gate", ["gate"]); call("voice", ["voice"]) }
    function call(what, args) {
        if (callProc.running) { callQ = callQ.concat([[what, args]]); return }
        callProc.what = what
        callProc.command = ["python3", script].concat(args)
        callProc.running = true
    }
    function call2(what, args) { call(what, args) }
    property var callQ: []
    Process {
        id: callProc
        property string what: ""
        stdout: StdioCollector {
            onStreamFinished: {
                var o = null
                try { o = JSON.parse(text) } catch (e) { o = null }
                var w = callProc.what
                if (o === null) { if (w === "settings") root.note = "Luna did not answer"; }
                else if (o.type === "error") { root.flash(o.error); if (w === "keysave") root.keyMsg = o.error }
                else if (o.type === "settings") { root.cfg = o; root.roles = o.models || root.roles; if (o.auto !== undefined) root.auto = o.auto === true }
                else if (o.type === "models") { root.installed = o.installed || []; root.roles = o.roles || root.roles; root.reachable = o.reachable === true; if (o.auto !== undefined) root.auto = o.auto === true }
                else if (o.type === "prefs") root.prefs = { liveThink: o.liveThink === true, notifyDone: o.notifyDone === true, speakReplies: o.speakReplies === true }
                else if (o.type === "voice") { root.voiceInfo = o; root.voiceKnown = true }
                else if (o.type === "gate") root.gate = o
                else if (o.type === "stats") root.stats = o
                else if (o.type === "saved") { root.flash("Saved"); root.loadSettings() }
                else if (o.type === "key_saved") { root.keyOpen = ""; root.keyMsg = ""; root.flash("Key saved in " + (o.where === "keyring" ? "the keyring" : "Luna's secrets file")); root.loadSettings() }
                else if (o.type === "control") { root.addSys(o.text) }
            }
        }
        onExited: { if (root.callQ.length > 0) { var n = root.callQ[0]; root.callQ = root.callQ.slice(1); root.call(n[0], n[1]) } }
    }
    function setSetting(key, value) { call("set", ["set", key, JSON.stringify(value)]) }
    function pickModel(name, r) { modelMenu = ""; call("model", ["model", name, r]) }
    Process {
        id: keyProc
        stdinEnabled: true
        stdout: StdioCollector {
            onStreamFinished: {
                var o = null
                try { o = JSON.parse(text) } catch (e) { o = null }
                if (o && o.type === "key_saved") { root.keyOpen = ""; root.keyMsg = ""; root.flash("Key saved in " + (o.where === "keyring" ? "the keyring" : "Luna's secrets file")); root.loadSettings() }
                else root.keyMsg = o && o.error ? o.error : "That did not work."
            }
        }
    }
    function saveKey(name, value) {
        value = String(value || "").trim()
        if (value === "" || keyProc.running) return
        keyMsg = ""
        keyProc.command = ["python3", script, "key", name]
        keyProc.running = true
        keyProc.write(value + "\n")         // on stdin: a key in the command line would show in `ps`
    }

    // ---- slash commands (the terminal UI's, for the ones that make sense in a window)
    readonly property var slashCmds: [
        { c: "/model", d: "Switch Luna's model: /model NAME (or see the list)" },
        { c: "/settings", d: "Luna's settings, keys and models" },
        { c: "/keys", d: "Paste an API key" },
        { c: "/status", d: "Halcyon at a glance: firewall, antivirus, AI, GPU" },
        { c: "/new", d: "Start a new chat" },
        { c: "/clear", d: "Empty this chat and Luna's memory of it" },
        { c: "/delete", d: "Delete this chat (type it twice)" },
        { c: "/test-model", d: "Is Ollama answering, and which models does Luna use" },
        { c: "/help", d: "These commands" },
        { c: "/exit", d: "Close this window" }
    ]
    function addSys(t) { pushMsg({ role: "sys", text: String(t) }) }
    // true when the text was a command (nothing goes to the model)
    function runSlash(raw) {
        var t = String(raw).trim()
        if (t.charAt(0) !== "/") return false
        var parts = t.split(/\s+/), c = parts[0].toLowerCase(), arg = parts.slice(1).join(" ")
        if (c === "/model" || c === "/models") {
            if (arg === "" || c === "/models") { openSettings(); role = "model"; return true }
            call("model", ["model", arg, "model"]); addSys("Switching Luna's main model to " + arg + "…"); return true
        }
        if (c === "/settings" || c === "/config") { openSettings(); return true }
        if (c === "/keys") { openSettings(); return true }
        if (c === "/status") { addSys("Looking…"); call("control", ["control", "info", "overview"]); return true }
        if (c === "/new") { newChat(); return true }
        if (c === "/clear") { if (cur !== "") { Quickshell.execDetached(["python3", script, "clear", cur]) } mm.clear(); reload(false); return true }
        if (c === "/delete") {
            if (cur === "") { addSys("There is no saved chat open to delete."); return true }
            if (busy) { addSys("Luna is still answering. Stop her first, then delete the chat."); return true }
            if (delAsk !== cur) { delAsk = cur; addSys("Type /delete again to delete this chat for good."); return true }
            delAsk = ""; removeSession(cur); return true
        }
        if (c === "/test-model") { addSys("Asking Ollama…"); call("models", ["models"]); testing = true; return true }
        if (c === "/help") { addSys(slashCmds.map(function (x) { return x.c + "   " + x.d }).join("\n")); return true }
        if (c === "/exit" || c === "/quit") { hide(); return true }
        addSys("Unknown command " + c + ". Type /help.")
        return true
    }
    property string delAsk: ""             // the chat /delete waits to confirm
    property bool testing: false
    onInstalledChanged: if (testing) { testing = false; addSys(reachable ? "Ollama answers. Luna's main model: " + (roles.model || "?") + (roles.fast ? ", fast: " + roles.fast : "") + (roles.deep ? ", deep: " + roles.deep : "") + (roles.security ? ", security: " + roles.security : "") + ". " + installed.length + " models installed." : "Ollama is not answering. Start it with: systemctl --user start ollama (or sudo systemctl start ollama).") }
    readonly property var slashHits: {
        var t = String(askText).trim()
        if (t.charAt(0) !== "/" || t.indexOf(" ") >= 0) return []
        return slashCmds.filter(function (x) { return x.c.indexOf(t.toLowerCase()) === 0 })
    }
    property string askText: ""
    property int slashSel: 0
    onAskTextChanged: slashSel = 0

    // ---- is Luna there
    function check() { if (!statusProc.running) statusProc.running = true }
    Process {
        id: statusProc
        command: ["python3", root.script, "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text)
                    root.ok = o.ok === true
                    root.problem = o.installed === false ? "Luna is not installed. Run ./install.sh --luna, then open this again." : (o.old === true ? "This Luna is older than the window. Update Luna (./install.sh --luna, or rebuild it from github.com/X-netrunner/LUNA-AI) and open this again." : (o.blocked || ""))
                } catch (e) { root.ok = false; root.problem = "No answer from halcyon-luna.py (is python3 there?)" }
            }
        }
    }

    // ---- the sessions
    function reload(openLast) {
        listProc.openLast = openLast === true
        if (!listProc.running) listProc.running = true
    }
    Process {
        id: listProc
        property bool openLast: false
        command: ["python3", root.script, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.sessions = JSON.parse(text).sessions || []
                    // opening the window carries on with the newest session, unless one is already open or being written
                    if (listProc.openLast && root.cur === "" && root.msgCount === 0 && !root.busy && root.sessions.length > 0)
                        root.openSession(root.sessions[0].id)
                } catch (e) {}
            }
        }
    }
    function openSession(id) {
        if (busy || id === cur) return
        cur = id; mm.clear(); confirmDel = ""; renaming = ""; delAsk = ""
        showProc.command = ["python3", script, "show", id, "--json"]
        showProc.running = true
        Qt.callLater(function () { root.focusRequested("ask") })
    }
    Process {
        id: showProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var t = JSON.parse(text).turns || [], m = []
                    for (var i = 0; i < t.length; i++)
                        m.push({ role: t[i].role, text: t[i].text || "", tools: t[i].tools || [], model: t[i].model || "", secs: t[i].secs || 0,
                                 think: t[i].thinking || "", live: false, bad: t[i].bad === true })
                    root.setMsgs(m)
                } catch (e) {}
            }
        }
    }
    function newChat() { if (busy) return; delAsk = ""; cur = ""; mm.clear(); confirmDel = ""; renaming = ""; Qt.callLater(function () { root.focusRequested("ask") }) }
    function removeSession(id) {
        confirmDel = ""
        Quickshell.execDetached(["python3", script, "delete", id])
        sessions = sessions.filter(function (s) { return s.id !== id })
        if (cur === id) { cur = ""; mm.clear() }
        relT.restart()
    }
    function renameSession(id, title) {
        renaming = ""
        title = String(title || "").trim()
        if (title === "") return
        Quickshell.execDetached(["python3", script, "rename", id, title])
        sessions = sessions.map(function (s) { if (s.id === id) { var c = {}; for (var k in s) c[k] = s[k]; c.title = title; return c } return s })
    }
    Timer { id: relT; interval: 400; onTriggered: root.reload(false) }

    // ---- a turn
    function send(q) {
        q = String(q || "").trim()
        if (q === "") return
        if (runSlash(q)) return
        if (busy) return
        if (!ok) { flash(problem !== "" ? problem : "Luna is not available."); return }
        pushMsg({ role: "you", text: q })
        pushMsg({ role: "luna", live: true })
        scrollEnd()
        status = "thinking"
        secs = 0
        if (cur === "") { newProc.question = q; newProc.running = true }
        else startChat(q)
    }
    function startChat(q) {
        chatProc.command = ["python3", script, "chat", cur, "--json", "--", q]
        chatProc.running = true
    }
    function stop() { if (chatProc.running) chatProc.signal(15) }
    Process {
        id: newProc
        property string question: ""
        command: ["python3", root.script, "new", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.cur = JSON.parse(text).id; root.startChat(newProc.question) }
                catch (e) { root.patchLast(function (c) { c.text = "Could not start a chat."; c.bad = true; c.live = false }) }
            }
        }
    }
    // change the last (Luna's) row in place; f gets a plain copy: { text, think, tools, model, secs, live, bad }
    function patchLast(f) {
        var i = mm.count - 1
        if (i < 0) return
        var r = mm.get(i)
        if (r.role !== "luna") return
        var c = { text: r.text, think: r.think, tools: JSON.parse(r.toolsJson), model: r.mname, secs: r.secs, live: r.live, bad: r.bad }
        f(c)
        mm.set(i, { text: c.text, think: c.think, toolsJson: JSON.stringify(c.tools), mname: c.model, secs: c.secs, live: c.live, bad: c.bad })
    }
    function thinkMore(d) { var i = mm.count - 1; if (i >= 0 && mm.get(i).role === "luna") mm.setProperty(i, "think", mm.get(i).think + d) }
    Process {
        id: chatProc
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                if (o.type === "activity") {
                    if (o.kind === "tool_start") {
                        root.status = "running " + o.name + (o.summary && o.summary !== o.name ? ": " + o.summary : "")
                        root.patchLast(function (c) { c.tools = c.tools.concat([{ name: o.name, summary: o.summary || "" }]) })
                    } else if (o.kind === "step") root.status = "thinking"
                } else if (o.type === "thinking") root.thinkMore(o.delta)
                else if (o.type === "reply") {
                    root.patchLast(function (c) { c.text = o.text; c.model = o.model || ""; c.secs = o.secs || 0; c.live = false })
                    if (root.prefs.speakReplies && o.text) root.speak(o.text)
                }
                else if (o.type === "error") root.patchLast(function (c) { c.text = o.error; c.bad = true; c.live = false })
            }
        }
        onExited: {
            root.status = ""
            root.patchLast(function (c) { if (c.live) { c.live = false; if (c.text === "") { c.text = "Stopped."; c.bad = true } } })
            root.check()
            root.reload(false)
            root.call("stats", ["stats"])
            if (!root.open && root.prefs.notifyDone && mm.count > 0) {
                var l = mm.get(mm.count - 1)
                if (l.role === "luna" && l.text !== "" && !l.bad) Quickshell.execDetached(["notify-send", "-a", "Luna", "Luna has answered", String(l.text).replace(/\s+/g, " ").substring(0, 140)])
            }
        }
    }
    // read an answer aloud (Luna's own voice; the answer goes in on stdin)
    Process {
        id: speakProc
        stdinEnabled: true
        stdout: StdioCollector {
            onStreamFinished: {
                try { var o = JSON.parse(text); if (o.type === "error") root.flash(o.error) } catch (e) {}
            }
        }
    }
    function speak(t) {
        if (speakProc.running) return
        speakProc.command = ["python3", script, "speak"]
        speakProc.running = true
        speakProc.write(String(t).replace(/\s+/g, " ") + "\n")
    }
    function copy(t) { Quickshell.execDetached(["wl-copy", "--", t]); flash("Copied") }
    function saveNote(t) {
        Quickshell.execDetached(["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "add", t])
        flash("Saved as a note (Super + N)")
    }

    // ---------------------------------------------------------------- small pieces
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
    component PrimaryBtn: Rectangle {
        id: pb
        property string label: ""
        property string glyph: ""
        signal clicked()
        implicitWidth: pbRow.implicitWidth + 30
        implicitHeight: 36
        radius: height / 2
        color: pbMa.containsMouse ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent
        scale: pbMa.pressed ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 8
            Text { visible: pb.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: pb.glyph; color: root.pal.bg; font.family: root.pal.font; font.pixelSize: 15 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: pb.label; color: root.pal.bg; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
        }
        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked() }
    }
    // Luna's mark is Halcyon's own sparkle (the splash's four-point star with its two companions). It turns and breathes while she
    // works and sits still when she has answered.
    component Spark: Canvas {
        id: sk
        property bool spin: false
        property bool bad: false
        property real t: 0
        readonly property int q: spin ? Math.round(t * 36) % 36 : 0
        implicitWidth: 24
        implicitHeight: 24
        renderTarget: Canvas.FramebufferObject
        onQChanged: requestPaint()
        onWidthChanged: requestPaint()
        Connections { target: root.pal; function onAccentChanged() { sk.requestPaint() } }
        NumberAnimation on t { from: 0; to: 1; duration: 2400; loops: Animation.Infinite; running: sk.spin && root.open }
        onPaint: {
            var c = getContext("2d"), w = width, ph = q / 36
            c.reset()
            c.translate(w / 2, w / 2)
            var a1 = bad ? root.pal.bad : root.pal.accent, a2 = bad ? root.pal.bad : root.pal.accent2
            var breathe = spin ? 1 + 0.12 * Math.sin(ph * Math.PI * 2) : 1
            var R = w * 0.40 * breathe
            function rgba(col, a) { return Qt.rgba(col.r, col.g, col.b, a) }
            function star(rv, rh, k) {
                var cc = Math.min(rv, rh) * k
                c.beginPath()
                c.moveTo(0, -rv); c.quadraticCurveTo(cc, -cc, rh, 0); c.quadraticCurveTo(cc, cc, 0, rv)
                c.quadraticCurveTo(-cc, cc, -rh, 0); c.quadraticCurveTo(-cc, -cc, 0, -rv); c.closePath()
            }
            var hg = c.createRadialGradient(0, 0, 0, 0, 0, w * 0.5)
            hg.addColorStop(0, rgba(a1, spin ? 0.34 : 0.2)); hg.addColorStop(1, rgba(a2, 0))
            c.fillStyle = hg
            c.beginPath(); c.arc(0, 0, w * 0.5, 0, 6.2832); c.fill()
            c.save()
            c.rotate(ph * Math.PI / 2)
            var fg = c.createLinearGradient(-R, -R, R, R)
            fg.addColorStop(0, rgba(a1, 1)); fg.addColorStop(1, rgba(a2, 1))
            c.fillStyle = fg
            star(R, R * 0.84, 0.11); c.fill()
            var cg = c.createRadialGradient(0, 0, 0, 0, 0, R * 0.4)
            cg.addColorStop(0, Qt.rgba(1, 1, 1, 0.9)); cg.addColorStop(1, Qt.rgba(1, 1, 1, 0))
            c.fillStyle = cg
            c.beginPath(); c.arc(0, 0, R * 0.4, 0, 6.2832); c.fill()
            c.restore()
            if (w >= 20) {
                var tw = spin ? 0.5 + 0.5 * Math.sin(ph * Math.PI * 4) : 1
                c.fillStyle = rgba(a2, 0.55 + 0.4 * tw)
                c.save(); c.translate(w * 0.36, -w * 0.34); star(w * 0.1 * (0.8 + 0.2 * tw), w * 0.085 * (0.8 + 0.2 * tw), 0.12); c.fill(); c.restore()
            }
        }
    }
    component Sw: Rectangle {
        id: sw
        property bool on: false
        signal toggled(bool v)
        width: 42; height: 24; radius: 12
        color: on ? root.pal.accent : Qt.alpha(root.pal.text, 0.18)
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Rectangle {
            width: 18; height: 18; radius: 9; y: 3
            x: sw.on ? 21 : 3
            color: sw.on ? root.pal.bg : root.pal.text
            Behavior on x { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sw.toggled(!sw.on) }
    }
    // a menu: one line that shows the choice, the list opens right under it
    component Pick: Column {
        id: pk
        property string key: ""
        property string title: ""
        property string current: ""
        property string chosen: ""
        property var options: []
        signal picked(string id)
        readonly property bool opened: root.modelMenu === key
        spacing: 4
        Rectangle {
            width: parent.width; height: 42; radius: 21
            color: pkMa.containsMouse || pk.opened ? Qt.alpha(root.pal.text, 0.09) : Qt.alpha(root.pal.text, 0.05)
            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
            Text { anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter } text: pk.title; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
            Row {
                anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                spacing: 8
                Text { anchors.verticalCenter: parent.verticalCenter; text: pk.current; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                Text { anchors.verticalCenter: parent.verticalCenter; text: String.fromCodePoint(pk.opened ? 0xF0143 : 0xF0140); color: root.pal.muted; font.family: root.pal.font; font.pixelSize: 15 }
            }
            MouseArea { id: pkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.modelMenu = pk.opened ? "" : pk.key }
        }
        Rectangle {
            visible: pk.opened
            width: parent.width
            height: Math.min(pkList.contentHeight, 238) + 12
            radius: 18
            color: Qt.alpha(root.pal.surface, 1)
            border.width: 1
            border.color: root.pal.lineSoft
            ListView {
                id: pkList
                anchors { fill: parent; margins: 6 }
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: pk.options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: modelData.id === pk.chosen
                    width: pkList.width; height: 34; radius: 12
                    color: on ? Qt.alpha(root.pal.accent, 0.18) : (oMa2.containsMouse ? Qt.alpha(root.pal.text, 0.07) : "transparent")
                    Text { anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter } text: modelData.text; color: on ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: on ? Font.DemiBold : Font.Normal }
                    Text { anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter } text: modelData.sub || ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                    MouseArea { id: oMa2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pk.picked(modelData.id) }
                }
            }
        }
    }
    component Working: Row {
        id: wk
        property string text: ""
        Text { anchors.verticalCenter: parent.verticalCenter; text: wk.text; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; elide: Text.ElideRight; width: Math.min(implicitWidth, 520) }
    }

    // ================================================================ the window
    LazyLoader {
        active: root.open || root.linger
        Host {
            id: win
            desktop: root.pal.deskWin
            title: "Luna"
            namespace: "island-luna"
            keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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
                Component.onCompleted: { ready = true; Qt.callLater(function () { askIn.forceActiveFocus() }) }
                Keys.onEscapePressed: if (!win.desktop) root.hide()
                Connections {
                    target: root
                    function onFocusRequested(what) { askIn.forceActiveFocus() }
                }

                Rectangle { visible: !win.desktop; anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: win.desktop ? qp.width : Math.min(1100, qp.width - 80)
                    height: win.desktop ? qp.height : Math.min(740, qp.height - 80)
                    radius: win.desktop ? 0 : root.pal.rXl
                    opacityBody: 0.97
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                    anchors.centerIn: parent
                    opacity: win.desktop ? 1 : qp.reveal
                    scale: win.desktop ? 1 : 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== the sessions
                        Item {
                            Layout.preferredWidth: 270
                            Layout.fillHeight: true
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
                                visible: root.view === "chat"
                                anchors.fill: parent
                                anchors.margins: 20
                                anchors.rightMargin: 21
                                spacing: 14

                                Row {
                                    spacing: 10
                                    Spark { anchors.verticalCenter: parent.verticalCenter; width: 26; height: 26; spin: root.busy }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Luna"
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tTitle + 2
                                        font.weight: Font.DemiBold
                                    }
                                }
                                PrimaryBtn {
                                    Layout.fillWidth: true
                                    label: "New chat"
                                    glyph: String.fromCodePoint(0xF0415)
                                    onClicked: root.newChat()
                                }

                                ListView {
                                    id: slist
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 2
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.sessions
                                    delegate: Rectangle {
                                        id: srow
                                        required property var modelData
                                        readonly property bool active: modelData.id === root.cur
                                        readonly property bool editing: root.renaming === modelData.id
                                        width: slist.width
                                        height: 52
                                        radius: 14
                                        color: active ? Qt.alpha(root.pal.accent, 0.16) : (rowMa.containsMouse ? Qt.alpha(root.pal.text, 0.06) : "transparent")
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openSession(srow.modelData.id) }
                                        Column {
                                            anchors { left: parent.left; right: acts.left; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 6 }
                                            spacing: 3
                                            Text {
                                                visible: !srow.editing
                                                width: parent.width
                                                text: srow.modelData.title
                                                elide: Text.ElideRight
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                font.weight: srow.active ? Font.DemiBold : Font.Normal
                                            }
                                            TextInput {
                                                id: renIn
                                                visible: srow.editing
                                                width: parent.width
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                selectByMouse: true
                                                onVisibleChanged: if (visible) { text = srow.modelData.title; forceActiveFocus(); selectAll() }
                                                Keys.onReturnPressed: root.renameSession(srow.modelData.id, text)
                                                Keys.onEscapePressed: root.renaming = ""
                                            }
                                            Text {
                                                width: parent.width
                                                text: root.ago(srow.modelData.updated) + (srow.modelData.preview ? "  ·  " + srow.modelData.preview : "")
                                                elide: Text.ElideRight
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap
                                            }
                                        }
                                        Row {
                                            id: acts
                                            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                                            spacing: 2
                                            visible: rowMa.containsMouse || actMa1.containsMouse || actMa2.containsMouse || root.confirmDel === srow.modelData.id
                                            Rectangle {
                                                width: 26; height: 26; radius: 13
                                                visible: root.confirmDel !== srow.modelData.id
                                                color: actMa1.containsMouse ? Qt.alpha(root.pal.text, 0.1) : "transparent"
                                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF03EB); color: root.pal.muted; font.family: root.pal.font; font.pixelSize: 13 }
                                                MouseArea { id: actMa1; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.renaming = srow.modelData.id }
                                            }
                                            Rectangle {
                                                width: root.confirmDel === srow.modelData.id ? 62 : 26; height: 26; radius: 13
                                                color: root.confirmDel === srow.modelData.id ? Qt.alpha(root.pal.bad, 0.2) : (actMa2.containsMouse ? Qt.alpha(root.pal.text, 0.1) : "transparent")
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.confirmDel === srow.modelData.id ? "Delete?" : String.fromCodePoint(0xF01B4)
                                                    color: root.confirmDel === srow.modelData.id ? root.pal.bad : root.pal.muted
                                                    font.family: root.confirmDel === srow.modelData.id ? root.pal.uiFont : root.pal.font
                                                    font.pixelSize: root.confirmDel === srow.modelData.id ? root.pal.tCap : 13
                                                }
                                                MouseArea {
                                                    id: actMa2
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: { if (root.confirmDel === srow.modelData.id) root.removeSession(srow.modelData.id); else root.confirmDel = srow.modelData.id }
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.sessions.length === 0
                                        text: "No chats yet"
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: root.stats.n > 0
                                    wrapMode: Text.Wrap
                                    text: "Answers take " + root.fmtSecs(root.stats.avg) + " on average" + (root.stats.n > 1 ? "  ·  " + root.stats.n + " answers" : "")
                                    color: Qt.alpha(root.pal.muted, 0.9)
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                            }

                            // the settings pages take the place of the chats while Settings is open
                            ColumnLayout {
                                visible: root.view === "settings"
                                anchors.fill: parent
                                anchors.margins: 20
                                anchors.rightMargin: 21
                                spacing: 14
                                Text { text: "Settings"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 2; font.weight: Font.DemiBold }
                                PrimaryBtn { Layout.fillWidth: true; label: "Back to chat"; glyph: String.fromCodePoint(0xF0141); onClicked: root.view = "chat" }
                                Flickable {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    contentHeight: pageCol.height
                                    boundsBehavior: Flickable.StopAtBounds
                                    Column {
                                        id: pageCol
                                        width: parent.width
                                        spacing: 2
                                        Repeater {
                                            model: root.pages
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool active: root.page === modelData[0]
                                                width: pageCol.width; height: 42; radius: 14
                                                color: active ? Qt.alpha(root.pal.accent, 0.16) : (pgMa.containsMouse ? Qt.alpha(root.pal.text, 0.06) : "transparent")
                                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                                Text { anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter } text: modelData[1]; color: active ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: active ? Font.DemiBold : Font.Normal }
                                                MouseArea { id: pgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.page = modelData[0]; root.modelMenu = ""; root.keyOpen = "" } }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ======================== the chat
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: root.view === "settings" ? root.pageTitle() : root.cur === "" ? "New chat" : (function () { for (var i = 0; i < root.sessions.length; i++) if (root.sessions[i].id === root.cur) return root.sessions[i].title; return "Chat" })()
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tTitle
                                        font.weight: Font.DemiBold
                                    }
                                    Text {
                                        visible: root.note !== ""
                                        text: root.note
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap + 1
                                    }
                                    LinkBtn {
                                        visible: root.view !== "settings"
                                        label: root.pal.deskWin ? "Back to overlay" : "Pop out"
                                        glyph: String.fromCodePoint(root.pal.deskWin ? 0xF0141 : 0xF03CC)
                                        onClicked: root.setWindowMode(root.pal.deskWin ? "overlay" : "desktop")
                                    }
                                    LinkBtn {
                                        visible: root.view !== "settings"
                                        label: root.view === "settings" ? "Back to chat" : "Settings"
                                        glyph: String.fromCodePoint(root.view === "settings" ? 0xF0141 : 0xF0493)
                                        onClicked: { if (root.view === "settings") root.view = "chat"; else root.openSettings() }
                                    }
                                    LinkBtn { label: "Close"; glyph: String.fromCodePoint(0xF0156); onClicked: root.hide() }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: !root.ok && root.problem !== ""
                                    implicitHeight: probT.implicitHeight + 24
                                    radius: 14
                                    color: Qt.alpha(root.pal.warn, 0.14)
                                    Text { id: probT; x: 16; y: 12; width: parent.width - 32; wrapMode: Text.Wrap; text: root.problem; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                }


                                // ============ settings: one page at a time (the list is on the left)
                                Flickable {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.view === "settings"
                                    clip: true
                                    contentHeight: setCol.height + 20
                                    boundsBehavior: Flickable.StopAtBounds
                                    Column {
                                        id: setCol
                                        width: Math.min(parent.width, 640)
                                        spacing: 22

                                        // ---- models: Auto, or one model for everything
                                        Column {
                                            visible: root.page === "models"
                                            width: parent.width
                                            spacing: 10
                                            Pick {
                                                width: parent.width
                                                key: "main"
                                                title: "Model"
                                                current: root.auto ? "Auto" : root.shortName(root.roles.model || "")
                                                chosen: root.auto ? "__auto" : (root.roles.model || "")
                                                options: root.modelOpts(true)
                                                onPicked: id => {
                                                    root.modelMenu = ""
                                                    if (id === "__auto") root.setSetting("llm.auto_route", true)
                                                    else { root.pickModel(id, "model"); root.setSetting("llm.auto_route", false) }
                                                }
                                            }
                                            Text {
                                                visible: !root.pal.hideHints
                                                width: parent.width
                                                wrapMode: Text.Wrap
                                                text: root.auto ? "Luna chooses for each question: fast for greetings, main for most things, deep for code, security for security work." : "Every question goes to this one model."
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                            Text {
                                                visible: !root.reachable
                                                width: parent.width
                                                wrapMode: Text.Wrap
                                                text: "Ollama is not answering. Start it, then open Settings again."
                                                color: root.pal.bad
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                            Text {
                                                visible: root.stats.n > 0
                                                width: parent.width
                                                wrapMode: Text.Wrap
                                                text: "Average answer " + root.fmtSecs(root.stats.avg) + ", typical " + root.fmtSecs(root.stats.median) + ". " + root.stats.models.map(function (m) { return root.shortName(m.name) + " " + root.fmtSecs(m.avg) + " (" + m.n + ")" }).join("  ·  ")
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                            Column {
                                                visible: root.auto
                                                width: parent.width
                                                spacing: 8
                                                topPadding: 8
                                                Repeater {
                                                    model: root.roleNames
                                                    delegate: Pick {
                                                        required property var modelData
                                                        width: setCol.width
                                                        key: modelData[0]
                                                        title: modelData[1]
                                                        current: root.roles[modelData[0]] ? root.shortName(root.roles[modelData[0]]) : "not set"
                                                        chosen: root.roles[modelData[0]] || ""
                                                        options: root.modelOpts(false)
                                                        onPicked: id => root.pickModel(id, modelData[0])
                                                    }
                                                }
                                            }
                                        }

                                        // ---- voice: can she speak, and read answers aloud
                                        Column {
                                            visible: root.page === "Voice & Audio"
                                            width: parent.width
                                            spacing: 12
                                            Rectangle {
                                                width: parent.width
                                                height: vRow.implicitHeight + 28
                                                radius: 18
                                                color: root.voiceKnown && root.voiceInfo.ok ? Qt.alpha(root.pal.good, 0.14) : Qt.alpha(root.pal.text, 0.06)
                                                Column {
                                                    id: vRow
                                                    x: 18; y: 14
                                                    width: parent.width - 36
                                                    spacing: 4
                                                    Text { text: !root.voiceKnown ? "Checking her voice" : (root.voiceInfo.ok ? "Luna can speak" : (root.voiceInfo.mode === "off" ? "Her voice is off" : "Luna cannot speak yet")); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                                                    Text {
                                                        visible: root.voiceKnown && !root.voiceInfo.ok
                                                        width: parent.width
                                                        wrapMode: Text.Wrap
                                                        text: root.voiceInfo.mode === "off" ? "Set Voice Mode below to basic." : "She needs " + (root.voiceInfo.missing || []).join(", ") + "."
                                                        color: root.pal.muted
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tCap + 1
                                                    }
                                                }
                                            }
                                            Flow {
                                                width: parent.width
                                                spacing: 8
                                                PrimaryBtn { visible: root.voiceKnown && !root.voiceInfo.ok && root.voiceInfo.mode !== "off"; label: "Set up her voice"; onClicked: root.termRun("bash ~/.config/Halcyon/scripts/luna-voice-setup.sh") }
                                                LinkBtn { label: "Check again"; onClicked: root.call("voice", ["voice"]) }
                                            }
                                            Item {
                                                width: parent.width; height: 40
                                                Text { anchors { left: parent.left; verticalCenter: parent.verticalCenter } text: "Read her answers aloud"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                                Sw { anchors { right: parent.right; verticalCenter: parent.verticalCenter } on: root.prefs.speakReplies === true; onToggled: v => root.setPref("speakReplies", v) }
                                            }
                                        }

                                        // ---- no refusal: the state, the two models that serve it, how to change it
                                        Column {
                                            visible: root.page === "refusal"
                                            width: parent.width
                                            spacing: 12
                                            Rectangle {
                                                width: parent.width
                                                height: gateRow.implicitHeight + 28
                                                radius: 18
                                                color: root.gate.effective ? Qt.alpha(root.pal.good, 0.14) : Qt.alpha(root.pal.text, 0.06)
                                                Column {
                                                    id: gateRow
                                                    x: 18; y: 14
                                                    width: parent.width - 36
                                                    spacing: 4
                                                    Text { text: root.gate.effective ? "No-refusal mode is on" : "No-refusal mode is off"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                                                    Text {
                                                        width: parent.width
                                                        wrapMode: Text.Wrap
                                                        text: root.gate.effective ? "Security questions go to " + (root.roles.security_nr ? root.shortName(root.roles.security_nr) : "your security model") + ", which has its refusals removed in the weights."
                                                              : (!root.gate.key ? "There is no developer key yet. Create one, then unlock." : (root.gate.requested ? "It is requested but locked. Unlock it with your developer key." : "Unlock it with your developer key to turn it on."))
                                                        color: root.pal.muted
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tCap + 1
                                                    }
                                                }
                                            }
                                            Flow {
                                                width: parent.width
                                                spacing: 8
                                                PrimaryBtn { visible: !root.gate.key; label: "Create a developer key"; onClicked: root.termRun("luna --gen-dev-key") }
                                                PrimaryBtn { visible: root.gate.key && !root.gate.effective; label: "Unlock"; onClicked: root.termRun("luna --unlock-security") }
                                                LinkBtn { visible: root.gate.effective; label: "Lock again"; onClicked: { root.termRun("luna --lock-security"); root.flash("Locking in the terminal") } }
                                                LinkBtn { label: "Check again"; onClicked: root.call("gate", ["gate"]) }
                                            }
                                            Pick {
                                                width: parent.width
                                                key: "security_nr"
                                                title: "Security model, no refusal"
                                                current: root.roles.security_nr ? root.shortName(root.roles.security_nr) : "not set"
                                                chosen: root.roles.security_nr || ""
                                                options: root.modelOpts(false)
                                                onPicked: id => root.pickModel(id, "security_nr")
                                            }
                                            Pick {
                                                width: parent.width
                                                key: "deep_fallback"
                                                title: "Code model if the deep one refuses"
                                                current: root.roles.deep_fallback ? root.shortName(root.roles.deep_fallback) : "not set"
                                                chosen: root.roles.deep_fallback || ""
                                                options: root.modelOpts(false)
                                                onPicked: id => root.pickModel(id, "deep_fallback")
                                            }
                                            Text {
                                                visible: !root.pal.hideHints
                                                width: parent.width
                                                wrapMode: Text.Wrap
                                                text: "Pull one with ollama pull NAME, for example an abliterated build, and it appears in the menus. Only the security model is switched by the developer key; the code model is a plain fallback."
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                        }

                                        // ---- this window
                                        Column {
                                            visible: root.page === "window"
                                            width: parent.width
                                            spacing: 6
                                            Repeater {
                                                model: [["liveThink", "Show her thinking while she works"], ["notifyDone", "Tell me when she answers while this window is closed"]]
                                                delegate: Item {
                                                    required property var modelData
                                                    width: setCol.width; height: 40
                                                    Text { anchors { left: parent.left; verticalCenter: parent.verticalCenter; right: wsw.left; rightMargin: 12 } elide: Text.ElideRight; text: modelData[1]; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                                    Sw { id: wsw; anchors { right: parent.right; verticalCenter: parent.verticalCenter } on: root.prefs[modelData[0]] === true; onToggled: v => root.setPref(modelData[0], v) }
                                                }
                                            }
                                        }

                                        // ---- Luna's own switches (the terminal UI's), the ones that belong on this page
                                        Column {
                                            visible: root.page !== "keys" && root.page !== "window"
                                            width: parent.width
                                            spacing: 4
                                            Repeater {
                                                model: root.cfg ? root.cfg.categories : []
                                                delegate: Column {
                                                    id: catCol
                                                    required property var modelData
                                                    visible: root.catShows(modelData)
                                                    width: setCol.width
                                                    spacing: 4
                                                    Repeater {
                                                        model: catCol.modelData.items
                                                        delegate: Item {
                                                            id: setRow
                                                            required property var modelData
                                                            readonly property bool hidden: (modelData.kind === "value" && !modelData.options) || modelData.key === "llm.auto_route" || root.itemPage(catCol.modelData.name, modelData.key) !== root.page
                                                            visible: !hidden
                                                            width: catCol.width
                                                            height: hidden ? 0 : 38
                                                            Text {
                                                                anchors { left: parent.left; verticalCenter: parent.verticalCenter; right: ctl.left; rightMargin: 12 }
                                                                elide: Text.ElideRight
                                                                text: setRow.modelData.label
                                                                color: root.pal.text
                                                                font.family: root.pal.uiFont
                                                                font.pixelSize: root.pal.tBody
                                                            }
                                                            Sw {
                                                                id: ctl
                                                                visible: setRow.modelData.kind === "toggle"
                                                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                                on: setRow.modelData.value === true
                                                                onToggled: v => root.setSetting(setRow.modelData.key, v)
                                                            }
                                                            // a value that has a few choices (voice) or a gate the developer key controls
                                                            Row {
                                                                visible: setRow.modelData.kind !== "toggle"
                                                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                                spacing: 6
                                                                Repeater {
                                                                    model: setRow.modelData.kind === "value" && setRow.modelData.options ? setRow.modelData.options : []
                                                                    delegate: Rectangle {
                                                                        required property var modelData
                                                                        readonly property bool on: setRow.modelData.value === modelData
                                                                        width: oT.implicitWidth + 20; height: 28; radius: 14
                                                                        color: on ? Qt.alpha(root.pal.accent, 0.2) : (oMa.containsMouse ? Qt.alpha(root.pal.text, 0.07) : "transparent")
                                                                        Text { id: oT; anchors.centerIn: parent; text: modelData; color: on ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                                        MouseArea { id: oMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setSetting(setRow.modelData.key, modelData) }
                                                                    }
                                                                }
                                                                Text {
                                                                    visible: setRow.modelData.kind === "gate"
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    text: (String(setRow.modelData.value).toUpperCase() === "ON" || String(setRow.modelData.value).toLowerCase() === "unlocked") ? "on" : "locked"
                                                                    color: root.pal.muted
                                                                    font.family: root.pal.uiFont
                                                                    font.pixelSize: root.pal.tBody
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // ---- API keys: paste, Luna stores it
                                        Column {
                                            visible: root.page === "keys"
                                            width: parent.width
                                            spacing: 8
                                            Repeater {
                                                model: root.cfg ? root.cfg.keys : []
                                                delegate: Column {
                                                    id: keyCol
                                                    required property var modelData
                                                    width: setCol.width
                                                    spacing: 6
                                                    Item {
                                                        width: parent.width
                                                        height: 36
                                                        Row {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            spacing: 10
                                                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: keyCol.modelData.set ? root.pal.good : Qt.alpha(root.pal.muted, 0.6) }
                                                            Text { text: keyCol.modelData.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; text: keyCol.modelData.set ? "saved" : "not set"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                        }
                                                        LinkBtn {
                                                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                            label: root.keyOpen === keyCol.modelData.name ? "Cancel" : (keyCol.modelData.set ? "Replace" : "Paste key")
                                                            onClicked: { root.keyMsg = ""; root.keyOpen = root.keyOpen === keyCol.modelData.name ? "" : keyCol.modelData.name }
                                                        }
                                                    }
                                                    Column {
                                                        visible: root.keyOpen === keyCol.modelData.name
                                                        width: parent.width
                                                        spacing: 6
                                                        Text { width: parent.width; wrapMode: Text.Wrap; text: keyCol.modelData.help; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                        Rectangle {
                                                            width: parent.width
                                                            height: 42
                                                            radius: 21
                                                            color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.75))
                                                            border.width: keyIn.activeFocus ? 1 : 0
                                                            border.color: root.pal.lineFocus
                                                            TextInput {
                                                                id: keyIn
                                                                anchors { left: parent.left; right: saveBtn.left; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 10 }
                                                                echoMode: TextInput.Password
                                                                color: root.pal.text
                                                                font.family: root.pal.uiFont
                                                                font.pixelSize: root.pal.tBody
                                                                clip: true
                                                                onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
                                                                Keys.onReturnPressed: root.saveKey(keyCol.modelData.name, text)
                                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: keyIn.text.length === 0; text: "Paste it here, then Enter"; color: root.pal.muted; font: keyIn.font }
                                                            }
                                                            PrimaryBtn {
                                                                id: saveBtn
                                                                anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                                                                height: 34
                                                                label: "Save"
                                                                onClicked: root.saveKey(keyCol.modelData.name, keyIn.text)
                                                            }
                                                        }
                                                        Text { visible: root.keyMsg !== ""; width: parent.width; wrapMode: Text.Wrap; text: root.keyMsg; color: root.pal.bad; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                    }
                                                }
                                            }
                                            Text { width: parent.width; wrapMode: Text.Wrap; text: "Keys are kept in your system keyring. luna.toml only says keyring:NAME."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                        }
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.view === "chat"

                                    Column {
                                        anchors.centerIn: parent
                                        visible: root.msgCount === 0
                                        width: Math.min(parent.width, 560)
                                        spacing: 10
                                        Spark { anchors.horizontalCenter: parent.horizontalCenter; width: 64; height: 64 }
                                        Item { width: 1; height: 6 }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Ask Luna anything"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 2; font.weight: Font.DemiBold }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "She runs on this machine. Chats are saved on the left."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        Item { width: 1; height: 8 }
                                        Flow {
                                            width: parent.width
                                            spacing: 8
                                            layoutDirection: Qt.LeftToRight
                                            Repeater {
                                                model: ["Is my firewall running?", "Is my antivirus scanning?", "Give me an overview of this machine"]
                                                delegate: Rectangle {
                                                    required property string modelData
                                                    width: sgT.implicitWidth + 28; height: 34; radius: 17
                                                    color: sgMa.containsMouse ? Qt.alpha(root.pal.accent, 0.16) : Qt.alpha(root.pal.text, 0.05)
                                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                                    Text { id: sgT; anchors.centerIn: parent; text: modelData; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                    MouseArea { id: sgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.send(modelData) }
                                                }
                                            }
                                        }
                                    }

                                    ListView {
                                        id: chat
                                        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: askBar.top; bottomMargin: 14 }
                                        visible: root.msgCount > 0
                                        clip: true
                                        spacing: 18
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: mm
                                        property bool follow: true      // stays at the end while she writes, unless you scrolled up
                                        onCountChanged: Qt.callLater(function () { if (chat.follow) chat.positionViewAtEnd() })
                                        onContentHeightChanged: if (follow && root.busy) positionViewAtEnd()
                                        onMovementStarted: follow = false
                                        Connections { target: root; function onScrollEnd() { chat.follow = true; chat.positionViewAtEnd() } }
                                        onAtYEndChanged: if (atYEnd) follow = true
                                        delegate: Item {
                                            id: mrow
                                            required property int index
                                            required property string role
                                            required property string text
                                            required property string mname
                                            required property int secs
                                            required property string think
                                            required property bool live
                                            required property bool bad
                                            required property string toolsJson
                                            readonly property var modelData: ({ role: role, text: text, model: mname, secs: secs, think: think, live: live, bad: bad, tools: JSON.parse(toolsJson) })
                                            readonly property bool you: role === "you"
                                            readonly property bool sys: modelData.role === "sys"
                                            property bool showThink: false
                                            property bool showTools: false
                                            width: chat.width
                                            height: you ? youBox.height : (sys ? sysBox.height : aiCol.height)
                                            Rectangle {
                                                id: youBox
                                                visible: mrow.you
                                                anchors.right: parent.right
                                                width: Math.min(youT.implicitWidth + 32, parent.width * 0.75)
                                                height: youT.height + 20
                                                radius: 18
                                                color: Qt.alpha(root.pal.accent, 0.13)
                                                Text { id: youT; x: 16; y: 10; width: parent.width - 32; wrapMode: Text.Wrap; text: mrow.modelData.text; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; lineHeight: 1.3 }
                                            }
                                            Rectangle {
                                                id: sysBox
                                                visible: mrow.sys
                                                width: Math.min(parent.width, 640)
                                                height: sysT.height + 20
                                                radius: 14
                                                color: Qt.alpha(root.pal.text, 0.05)
                                                Text { id: sysT; x: 14; y: 10; width: parent.width - 28; wrapMode: Text.Wrap; text: mrow.modelData.text; color: root.pal.muted; font.family: root.pal.mono; font.pixelSize: root.pal.tCap + 1; lineHeight: 1.25 }
                                            }
                                            HoverHandler { id: mHover }
                                            Row {
                                                id: aiCol
                                                visible: !mrow.you && !mrow.sys
                                                width: Math.min(parent.width, 780)
                                                spacing: 14
                                                Spark {
                                                    y: 1
                                                    spin: mrow.modelData.live === true
                                                    bad: mrow.modelData.bad === true
                                                }
                                                Column {
                                                    id: aiBody
                                                    width: aiCol.width - 36
                                                    spacing: 8
                                                    Working {
                                                        visible: mrow.modelData.live === true && mrow.modelData.text === ""
                                                        height: 28
                                                        text: root.status + "  ·  " + root.secs + " s"
                                                    }
                                                    Text {
                                                        visible: mrow.modelData.live === true && root.prefs.liveThink && (mrow.modelData.think || "") !== ""
                                                        width: parent.width
                                                        wrapMode: Text.Wrap
                                                        maximumLineCount: 9
                                                        text: root.tail(mrow.modelData.think)
                                                        color: Qt.alpha(root.pal.muted, 0.9)
                                                        font.family: root.pal.uiFont
                                                        font.italic: true
                                                        font.pixelSize: root.pal.tCap + 1
                                                        lineHeight: 1.3
                                                    }
                                                    Text {
                                                        id: aiT
                                                        visible: mrow.modelData.text !== ""
                                                        width: parent.width
                                                        wrapMode: Text.Wrap
                                                        textFormat: Text.RichText
                                                        text: root.fmt(mrow.modelData.text)
                                                        color: mrow.modelData.bad ? root.pal.bad : root.pal.text
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tBody + 1
                                                        lineHeight: 1.4
                                                    }
                                                    Row {
                                                        spacing: 4
                                                        visible: !mrow.modelData.live && !mrow.modelData.bad
                                                        Text {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            visible: (mrow.modelData.model || "") !== ""
                                                            text: root.shortName(mrow.modelData.model) + (mrow.modelData.secs ? "  ·  " + mrow.modelData.secs + " s" : "")
                                                            color: Qt.alpha(root.pal.muted, 0.8)
                                                            font.family: root.pal.uiFont
                                                            font.pixelSize: root.pal.tCap
                                                            rightPadding: 6
                                                        }
                                                        // the actions come in on hover (and stay while a panel is open) so a long chat stays quiet
                                                        Row {
                                                            spacing: 4
                                                            opacity: (mHover.hovered || mrow.showTools || mrow.showThink || mrow.index === root.msgCount - 1) ? 1 : 0
                                                            Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
                                                            LinkBtn { visible: (mrow.modelData.tools || []).length > 0; label: (mrow.showTools ? "Hide " : "") + (mrow.modelData.tools || []).length + (((mrow.modelData.tools || []).length === 1) ? " tool used" : " tools used"); onClicked: mrow.showTools = !mrow.showTools }
                                                            LinkBtn { visible: (mrow.modelData.think || "") !== ""; label: mrow.showThink ? "Hide the reasoning" : "Show the reasoning"; onClicked: mrow.showThink = !mrow.showThink }
                                                            LinkBtn { label: "Read aloud"; glyph: String.fromCodePoint(0xF057E); onClicked: root.speak(mrow.modelData.text) }
                                                            LinkBtn { label: "Copy"; glyph: String.fromCodePoint(0xF018F); onClicked: root.copy(mrow.modelData.text) }
                                                            LinkBtn { label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(mrow.modelData.text) }
                                                        }
                                                    }
                                                    Column {
                                                        visible: mrow.showTools
                                                        width: parent.width
                                                        spacing: 3
                                                        Repeater {
                                                            model: mrow.modelData.tools || []
                                                            delegate: Text {
                                                                required property var modelData
                                                                width: aiBody.width
                                                                elide: Text.ElideRight
                                                                text: modelData.name + (modelData.summary && modelData.summary !== modelData.name ? ": " + modelData.summary : "")
                                                                color: root.pal.muted
                                                                font.family: root.pal.mono
                                                                font.pixelSize: root.pal.tCap
                                                            }
                                                        }
                                                    }
                                                    Text {
                                                        visible: mrow.showThink
                                                        width: parent.width
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
                                    }

                                    Rectangle {
                                        visible: root.slashHits.length > 0
                                        anchors { left: parent.left; right: parent.right; bottom: askBar.top; bottomMargin: 8 }
                                        height: slashCol.height + 16
                                        radius: 16
                                        z: 5
                                        color: Qt.alpha(root.pal.surface, 1)
                                        border.width: 1
                                        border.color: root.pal.line
                                        Column {
                                            id: slashCol
                                            x: 8; y: 8
                                            width: parent.width - 16
                                            Repeater {
                                                model: root.slashHits
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    width: slashCol.width
                                                    height: 30
                                                    radius: 10
                                                    required property int index
                                                    color: shMa.containsMouse || index === root.slashSel ? Qt.alpha(root.pal.accent, 0.18) : "transparent"
                                                    Row {
                                                        anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 10 }
                                                        spacing: 12
                                                        Text { text: modelData.c; color: root.pal.accent; font.family: root.pal.mono; font.pixelSize: root.pal.tBody; width: 100 }
                                                        Text { text: modelData.d; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                    }
                                                    MouseArea { id: shMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { askIn.text = modelData.c + " "; askIn.cursorPosition = askIn.text.length; askIn.forceActiveFocus() } }
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: askBar
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                        height: Math.min(160, Math.max(50, askIn.contentHeight + 28))
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
                                            onTextChanged: root.askText = text
                                            Keys.onPressed: e => {
                                                if (root.slashHits.length > 0) {
                                                    if (e.key === Qt.Key_Down) { root.slashSel = (root.slashSel + 1) % root.slashHits.length; e.accepted = true; return }
                                                    if (e.key === Qt.Key_Up) { root.slashSel = (root.slashSel + root.slashHits.length - 1) % root.slashHits.length; e.accepted = true; return }
                                                    if (e.key === Qt.Key_Tab) { text = root.slashHits[Math.min(root.slashSel, root.slashHits.length - 1)].c + " "; cursorPosition = text.length; e.accepted = true; return }
                                                }
                                                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                                    if (!root.busy && text.trim() !== "") { root.send(text); text = "" }
                                                    e.accepted = true
                                                } else if (e.key === Qt.Key_Escape && !win.desktop) { root.hide(); e.accepted = true }
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: askIn.text.length === 0
                                                text: "Message Luna, or type / for commands"
                                                color: root.pal.muted
                                                font: askIn.font
                                            }
                                        }
                                        RoundBtn {
                                            id: sendBtn
                                            anchors { right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                                            pal: root.pal
                                            size: 34
                                            primary: true
                                            glyph: String.fromCodePoint(root.busy ? 0xF04DB : 0xF005D)
                                            enabledBtn: root.busy || askIn.text.trim() !== ""
                                            onClicked: { if (root.busy) root.stop(); else if (askIn.text.trim() !== "") { root.send(askIn.text); askIn.text = "" } }
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
