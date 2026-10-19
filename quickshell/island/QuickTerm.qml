import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

// Top-left pop-out console for one-shot commands (sysmode switches, ls, ip a, ...).
//
//  open     hover mode: touch the top-left corner.  click mode: click the corner.  Either way the console takes the keyboard
//           by itself (a moment after it pops out), so you can type at once even with a terminal open beside it, and it
//           keeps the keyboard while the pointer is over it.  SUPER+SHIFT+Enter opens it focused (and again closes it).
//  close    hover mode: move the pointer away.  click mode: click the corner again.  Esc always works.
//           Auto-hide on = it closes whenever the pointer leaves, in both modes (never while you have text typed).
//  idle     empty input and nothing run yet: shows the sysmode / honeypot status (`hx status`) as plain console lines;
//           they fade away the moment you type
//  run      Enter. Output streams in. Ctrl+C stops, Ctrl+L clears, Up/Down = history
//  complete Tab completes the word under the cursor: commands (and the console's own words) at the start of a command, folders after
//           cd, sysmode actions after sysmode / sm, files and folders everywhere else. One match completes it, several complete the
//           common start and list them; Tab again goes through them (Shift+Tab back), Esc closes the list. A greyed suggestion
//           from your history follows what you type: Right arrow (or End) takes it.
//  sudo     `sudo ...` and root sysmode actions (`sysmode stealth`, `sm lockdown`, or just `lockdown`) ask for your
//           password right in the console (masked) and feed it to sudo -S; nothing is stored or logged
//  TUIs     vim, htop, ssh, less ... need a real terminal, so they open in foot instead
//
// quickshell ipc -p ~/.config/Halcyon/quickshell/island call island quickterm
Scope {
    id: root
    property var pal
    property bool stars: true             // constellations in this box (Settings > Constellations)
    property int flyCount: 0              // moving stars drifting in this box (0 = none): set by shell.qml from Resource use
    property int flyLoop: 150000          // ms for one slow pass of them
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool clickMode: false
    property bool autoHide: false
    // the corner the console opens from (Desktop builder > Where the boxes open): tl (default) | bl | br
    property string spot: "tl"
    readonly property bool atRight: spot.charAt(1) === "r"
    readonly property bool atBottom: spot.charAt(0) === "b"

    readonly property int boxW: 520
    readonly property int maxOut: 400
    readonly property string sysmodeBin: "/usr/local/bin/sysmode"
    readonly property string hx: Quickshell.env("HOME") + "/.config/Halcyon/bin/hx"
    readonly property string rice: Quickshell.env("HOME") + "/.config/Halcyon"
    readonly property var halcyonNames: ["launcher", "settings", "notification-builder", "bar-builder", "desktop-builder", "widget-builder", "desktop-edit", "bar", "wallpaper-gallery", "startup-view", "notifications",
                                         "clear-notifications", "dnd", "cheatsheet", "power-menu", "quick-terminal", "overview", "gaming-mode", "caffeine",
                                         "lock", "theme", "reload", "notes", "notes-all", "screen-record", "extra-dim"]
    readonly property var halcyonCalls: ["launcher", "settings", "notifbuilder", "barbuilder", "desktopbuilder", "widgetbuilder", "desktopedit", "bar", "gallery", "startup", "notifcenter",
                                         "clearnotifs", "dnd", "cheatsheet", "power", "quickterm", "overview", "gaming", "caffeine",
                                         "lock", "theme", "reload", "notes", "notesAll", "record", "extradim"]
    readonly property var directCmds: ["bar-builder", "notification-builder", "desktop-builder", "widget-builder", "desktop-edit", "wallpaper-gallery", "startup-view"]
    readonly property string pwMarker: "SUDO_PW"
    readonly property var modes: ["secure", "stealth", "relaxed", "cyber", "lockdown"]   // "cyber" = old name of relaxed (the CLI still takes it)
    readonly property var rootless: ["status", "logs", "dossier", "verify", "check", "doctor", "help", "-h", "--help"]
    readonly property var tuis: ["vim", "nvim", "vi", "nano", "emacs", "htop", "btop", "top", "less", "more", "man", "ssh",
                                 "mosh", "tmux", "screen", "ncmpcpp", "mutt", "ranger", "yazi", "fzf", "python", "python3", "node", "irb"]
    readonly property var modeColor: pal.modeColor
    readonly property string mono: pal.mono

    property bool open: false
    property bool pinned: false                      // opened from the keyboard: stays until closed (unless auto-hide)
    property bool focused: false                     // box has the keyboard
    property bool grabKeys: false                    // first moments after taking the keyboard: Exclusive, then normal on-demand focus
    property bool zoneHover: false                   // the pointer is over the corner / box: keep the keyboard exclusively so a window under it cannot take it back
    readonly property real reveal: open ? 1 : 0
    readonly property bool shown: open

    // where the console box sits on the screen (the guided tour spotlights it)
    function tourRect(sw, sh) {
        var h = Math.min(520, 40 + body.implicitHeight + 76)
        return { x: atRight ? (sw || 1920) - 22 - boxW : 22,
                 y: atBottom ? (sh || 1080) - pal.boxEdge - h : pal.boxTop, w: boxW, h: h }
    }

    property string cwd: Quickshell.env("HOME")
    property var st: ({})
    property var history: []
    property int histIdx: -1
    property bool busy: false
    property bool askPass: false

    ListModel { id: out }

    // ---------- open / close ----------
    readonly property bool mayAutoClose: !askPass && input.text === "" && (autoHide || (!clickMode && !pinned))
    function setHover(on) {
        if (on) { closeT.stop(); if (!clickMode) { open = true; if (!focused) autoFocusT.restart() } }
        else { autoFocusT.stop(); if (mayAutoClose) { closeT.interval = 550; closeT.restart() } }
    }
    function cornerTap() { if (open) close(); else { closeT.stop(); open = true; takeFocus() } }
    function toggle() {
        if (open && focused) { close(); return }
        closeT.stop()
        open = true
        pinned = true
        takeFocus()
    }
    function takeFocus() {
        focused = true
        grabKeys = true
        grabT.restart()
        Qt.callLater(function () { input.forceActiveFocus() })
    }
    function run(cmd) {
        closeT.stop()
        open = true
        pinned = true
        takeFocus()
        submit(cmd)
    }
    // a command picked in the commands tree (CmdTree.qml): open the console with the text typed in, not run
    property string pendingText: ""
    function prefill(t) { pendingText = t; prefillT.restart() }
    Timer {
        id: prefillT
        interval: 120                     // the tree's window lets go of the keyboard first
        onTriggered: {
            closeT.stop()
            root.open = true
            root.pinned = true
            root.takeFocus()
            input.text = root.pendingText
            input.cursorPosition = input.text.length
        }
    }
    function close() {
        closeT.stop()
        if (askPass) cancelRun()
        focused = false
        open = false
        pinned = false
    }
    Timer { id: closeT; interval: 550; onTriggered: if (root.mayAutoClose) root.close() }
    // popped out by touching the corner: take the keyboard after a short beat (so just brushing past the corner steals nothing)
    Timer { id: autoFocusT; interval: 150; onTriggered: if (root.open && root.zoneHover && !root.focused) root.takeFocus() }
    // Exclusive only long enough to be granted the keyboard; after that it is on-demand, so clicking another
    // window or opening a terminal hands the keyboard straight to it and nothing stays stuck
    Timer { id: grabT; interval: 350; onTriggered: root.grabKeys = false }

    // a new window took the keyboard: let go, a click on the box takes it back
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "openwindow") root.focused = false
        }
    }

    // ---------- output ----------
    property var pend: []                 // lines waiting to be shown (flushed every 40 ms)
    function push(text, kind) {
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) pend.push({ t: lines[i], k: kind })
        if (!flushT.running) flushT.start()
    }
    function toEnd() { view.positionViewAtEnd() }
    function flushOut() {
        var p = pend
        pend = []
        if (p.length > maxOut) p = p.slice(p.length - maxOut)      // only the last maxOut lines could stay anyway
        for (var i = 0; i < p.length; i++) out.append(p[i])
        if (out.count > maxOut) out.remove(0, out.count - maxOut)
        Qt.callLater(toEnd)
    }
    Timer { id: flushT; interval: 40; onTriggered: root.flushOut() }
    function clearOut() { pend = []; out.clear() }
    function cancelRun() { askPass = false; runner.running = false }

    // ---------- running a command ----------
    function words(s) { return s.trim().split(/\s+/) }
    function sudoed(rest) { return "sudo -S -p $'" + pwMarker + "\\n' " + rest }

    // ai / advisor / notes are fish functions (config/fish/functions), and this console runs bash: call their scripts directly
    readonly property var pyTools: ({ ai: "halcyon-chat.py", advisor: "adaptive-advisor.py", notes: "halcyon-notes.py" })
    function pyLine(first, line) { return "python3 \"$HOME/.config/Halcyon/scripts/" + pyTools[first] + "\"" + line.trim().substring(first.length) }

    function ipcLine(call) { return "quickshell ipc -p '" + rice + "/quickshell/island' call island " + call }

    function prepare(line) {
        var w = words(line)
        var first = w[0]
        if (w.length === 1 && modes.indexOf(first) >= 0) { w = ["sysmode", first]; line = "sysmode " + first }
        if (first === "sm") { w[0] = "sysmode"; line = "sysmode" + line.trim().substring(2) }
        if (w[0] === "sysmode") {
            var action = w[1] || "status"
            var rest = line.trim().substring(7)
            var cmd = sysmodeBin + (rest.length ? rest : " status")
            return { cmd: rootless.indexOf(action) >= 0 ? cmd : sudoed(cmd), tui: false }
        }
        if (first === "hotspot-on" || first === "hotspot-off")
            return { cmd: "bash '" + rice + "/scripts/hotspot.sh' " + first.substring(8), tui: false }
        if (directCmds.indexOf(first) >= 0) return { cmd: ipcLine(halcyonCalls[halcyonNames.indexOf(first)]), tui: false }
        if (first === "halcyon") {
            var hi = halcyonNames.indexOf(w[1] || "")
            return { cmd: hi >= 0 ? ipcLine(halcyonCalls[hi]) : "echo 'halcyon <command>: " + halcyonNames.join(" | ") + "'", tui: false }
        }
        if (first === "sudo") return { cmd: sudoed(line.trim().substring(4).trim()), tui: false }
        if ((first === "python" || first === "python3") && w.length > 1) return { cmd: line, tui: false }
        if (first === "ai" && w.length > 1) return { cmd: pyLine(first, line), tui: false }
        if (first === "ai" && w.length === 1) return { cmd: pyLine(first, line), tui: true }
        if (first === "advisor" || first === "notes") return { cmd: pyLine(first, line), tui: false }
        return { cmd: line, tui: tuis.indexOf(first) >= 0 }
    }

    function submit(raw) {
        var line = raw.trim()
        if (line === "") return
        if (history[history.length - 1] !== line) history = history.concat([line]).slice(-100)
        histIdx = -1
        push(cwdLabel() + " ❯ " + line, "cmd")

        if (line === "clear" || line === "cls") { clearOut(); return }
        if (line === "exit" || line === "quit") { close(); return }
        if (line === "help") {
            push("sysmode: secure | stealth | relaxed | lockdown | status | logs | dossier [ip]   (sm = sysmode)\n" +
                 "ai <question> or ai /diag: local AI assistant.  notes <text>: quick notes.\n" +
                 "hotspot-on / hotspot-off: Wi-Fi.\n" +
                 "halcyon <command>, bar-builder, desktop-builder, widget-builder, desktop-edit, wallpaper-gallery ...: open windows.\n" +
                 "sudo works here: it asks for your password in this line.\n" +
                 "SUPER+ALT+/ lists every command.\n" +
                 "cd, clear, exit, Ctrl+C stop, Ctrl+L clear, Up/Down history, Tab completes. Anything else runs in bash.\n" +
                 "vim / htop / ssh / bare ai ... open in a real terminal.", "info")
            return
        }
        var cd = line.match(/^cd(?:\s+(.*))?$/)
        if (cd) { cdProc.target = (cd[1] || "~").trim(); cdProc.running = true; return }
        if (busy) { push("still running: Ctrl+C to stop it first", "err"); return }

        var p = prepare(line)
        if (p.tui) {
            Quickshell.execDetached({ command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "term-exec", "bash", "-c", "export PATH=\"$HOME/.local/bin:$HOME/.config/Halcyon/bin:$PATH\"; " + p.cmd + "; exec bash"], workingDirectory: cwd })
            push("opened in a terminal window", "info")
            return
        }
        runner.command = ["bash", "-c", "export PATH=\"$HOME/.local/bin:$HOME/.config/Halcyon/bin:$PATH\"; exec 2>&1; " + p.cmd]
        runner.running = true
    }
    function cwdLabel() {
        var home = Quickshell.env("HOME")
        var c = cwd.indexOf(home) === 0 ? "~" + cwd.substring(home.length) : cwd
        var parts = c.split("/")
        return parts.length > 2 ? "…/" + parts[parts.length - 1] : c
    }

    // ---------- tab completion + history suggestion ----------
    property var cands: []                     // the matches of the last Tab press
    property int candIdx: -1                   // the one inserted while going through them with Tab (-1 = none yet)
    property bool candOpen: false
    property string candBefore: ""             // the text before and after the word being completed
    property string candAfter: ""
    readonly property var consoleWords: ["help", "clear", "cls", "exit", "quit", "cd", "sm", "sysmode", "hotspot-on", "hotspot-off", "halcyon"].concat(modes).concat(directCmds)
    readonly property var sysActions: ["secure", "stealth", "relaxed", "cyber", "lockdown", "status", "logs", "dossier", "verify", "check", "doctor", "help"]
    readonly property var wrappers: ["sudo", "time", "env", "nohup", "exec", "command", "builtin"]

    // the greyed rest of an earlier command that starts like what is typed (Right arrow / End takes it)
    readonly property string ghost: {
        var t = input.text
        if (askPass || candOpen || t.length === 0 || input.cursorPosition !== t.length) return ""
        for (var i = history.length - 1; i >= 0; i--)
            if (history[i].length > t.length && history[i].indexOf(t) === 0) return history[i].slice(t.length)
        return ""
    }
    // at most 8 matches are listed, scrolled so the picked one stays in view
    readonly property var candWindow: {
        var n = cands.length, size = 8, st = 0, out = []
        if (n > size) st = Math.max(0, Math.min(n - size, (candIdx < 0 ? 0 : candIdx) - 3))
        for (var i = st; i < Math.min(n, st + size); i++) out.push({ t: cands[i], cur: i === candIdx, dim: false })
        if (n > st + size) out.push({ t: "… " + (n - st - size) + " more", cur: false, dim: true })
        return out
    }

    function escWord(c) { return c.replace(/([ !"#$&'()*;<>?\[\\\]`{|}])/g, "\\$1") }
    function closeComp() { cands = []; candIdx = -1; candOpen = false }
    function commonPrefix(a) {
        if (a.length === 0) return ""
        var p = a[0]
        for (var i = 1; i < a.length; i++) while (a[i].indexOf(p) !== 0) p = p.slice(0, -1)
        return p
    }
    function putWord(w, space) {
        var tail = candAfter
        if (space && tail.charAt(0) !== " ") w += " "
        input.text = candBefore + w + tail
        input.cursorPosition = (candBefore + w).length
    }
    function cycleComp(dir) {
        var n = cands.length
        candIdx = candIdx < 0 ? (dir > 0 ? 0 : n - 1) : (candIdx + dir + n) % n
        putWord(escWord(cands[candIdx]), false)
    }
    // Tab: work out which word is under the cursor and what kind of thing goes there
    function complete(back) {
        if (askPass) return
        if (candOpen && cands.length > 1) { cycleComp(back ? -1 : 1); return }
        var text = input.text
        var before = text.slice(0, input.cursorPosition)
        var word = before.match(/[^\s;|&]*$/)[0]
        var start = before.length - word.length
        var seg = before.slice(0, start).split(/[;|&]/).pop().trim()
        var toks = seg.length ? seg.split(/\s+/) : []
        while (toks.length > 0 && wrappers.indexOf(toks[0]) >= 0) toks.shift()
        var cmdPos = toks.length === 0
        var ctx = toks[0] || ""
        var plain = word.replace(/\\(.)/g, "$1")
        var mode = "file"
        if (cmdPos) mode = plain.indexOf("/") >= 0 ? "file" : "cmd"
        else if (ctx === "cd" || ctx === "pushd") mode = "dir"
        else if ((ctx === "sysmode" || ctx === "sm" || ctx === "halcyon") && toks.length === 1) mode = "sub"
        if (mode === "cmd" && plain === "") return                  // every command there is: not a useful list
        var job = { text: text, before: before.slice(0, start), after: text.slice(input.cursorPosition), plain: plain, mode: mode }
        if (mode === "sub") {
            var pool = ctx === "halcyon" ? halcyonNames : sysActions
            finishComp(job, pool.filter(function (a) { return a.indexOf(plain) === 0 }))
            return
        }
        compProc.job = job
        compProc.running = false
        compProc.command = ["bash", "-c", compScript, "_", cwd, mode, plain]
        compProc.running = true
    }
    function finishComp(job, list) {
        if (input.text !== job.text) return                           // typed on meanwhile: this answer is old
        var home = Quickshell.env("HOME"), seen = {}, out = []
        var all = list.concat(job.mode === "cmd" ? consoleWords.filter(function (w) { return w.indexOf(job.plain) === 0 }) : [])
        for (var i = 0; i < all.length; i++) {
            var c = all[i]
            if (c === "" || seen[c]) continue
            seen[c] = true
            if (job.plain.charAt(0) === "~" && c.indexOf(home) === 0) c = "~" + c.slice(home.length)
            out.push(c)
        }
        out.sort()
        if (out.length === 0) { closeComp(); return }
        candBefore = job.before
        candAfter = job.after
        if (out.length === 1) {
            putWord(escWord(out[0]), out[0].charAt(out[0].length - 1) !== "/")
            closeComp()
            return
        }
        var common = commonPrefix(out)
        cands = out
        candIdx = -1
        candOpen = true
        if (common.length > job.plain.length) putWord(escWord(common), false)
    }
    // $1 folder, $2 cmd | dir | file, $3 the start of the word ("~" is already $HOME); folders get a trailing /
    readonly property string compScript: "cd -- \"$1\" 2>/dev/null || exit 0; w=\"$3\"; case \"$w\" in '~'|'~/'*) w=\"$HOME${w#\\~}\";; esac; " +
        "case \"$2\" in cmd) compgen -c -- \"$w\" ;; dir) compgen -d -- \"$w\" | while IFS= read -r f; do printf '%s/\\n' \"$f\"; done ;; " +
        "*) compgen -f -- \"$w\" | while IFS= read -r f; do if [ -d \"$f\" ]; then printf '%s/\\n' \"$f\"; else printf '%s\\n' \"$f\"; fi; done ;; esac | sort -u | head -300"
    Process {
        id: compProc
        property var job: ({})
        stdout: StdioCollector {
            onStreamFinished: { var t = text.trim(); root.finishComp(compProc.job, t === "" ? [] : t.split("\n")) }
        }
    }

    Process {
        id: runner
        workingDirectory: root.cwd
        stdinEnabled: true
        onRunningChanged: { root.busy = running; if (!running) root.askPass = false }
        stdout: SplitParser {
            onRead: d => {
                var l = d.replace(/\r/g, "").replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, "")
                if (l === root.pwMarker) { root.askPass = true; root.takeFocus(); return }
                root.push(l, "out")
            }
        }
        onExited: (code, status) => {
            if (code !== 0) root.push("exit " + code + (code === 126 || code === 127 ? "  (not found / not allowed)" : ""), "err")
        }
    }
    Process {
        id: cdProc
        property string target: "~"
        workingDirectory: root.cwd
        command: ["bash", "-c", "cd -- \"${1/#\\~/$HOME}\" 2>&1 && pwd", "_", target]
        stdout: StdioCollector {
            onStreamFinished: {
                var t = text.trim()
                if (t.charAt(0) === "/") root.cwd = t.split("\n").pop()
                else if (t) root.push(t, "err")
            }
        }
    }

    // status feed: only while the box is showing
    Process {
        id: statusProc
        command: [root.hx, "status"]
        property string last: ""
        stdout: StdioCollector { onStreamFinished: { if (text === statusProc.last) return; statusProc.last = text; try { root.st = JSON.parse(text) } catch (e) {} } }
    }
    // 3 s while the idle status rows are what you see, a slow 15 s once the console holds output
    Timer { interval: out.count === 0 ? 3000 : 15000; running: root.shown; repeat: true; triggeredOnStart: true; onTriggered: if (!statusProc.running) statusProc.running = true }

    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function dot(on, label) {
        return "<font color='" + (on ? pal.good : pal.muted) + "'>" + (on ? "●" : "○") + "</font> " + esc(label)
    }
    function row(k, v) { return "<font color='" + pal.muted + "'>" + esc(k.padEnd(12, " ")) + "</font>" + v }
    readonly property var statusRows: {
        var s = st || {}
        var m = sysmode || s.mode || ""
        var mc = modeColor[m] || pal.muted
        var rd = !!s.readable
        var num = function (v) { return (v === undefined || v === null) ? "–" : String(v) }
        var rows = [
            row("sysmode", "<font color='" + mc + "'><b>" + esc(m !== "" ? m : "not set") + "</b></font>"),
            row("honeypot", dot(!!s.honeypot, s.honeypot ? "active" : "off")),
            row("ids", dot(!!s.ids, s.ids ? "active" : "off")),
            row("cowrie", dot(!!s.cowrie, s.cowrie ? "active" : "off")),
            row("decoy wifi", dot(!!s.decoyWifi, s.decoyWifi ? s.decoyWifi : "off")),
            "&nbsp;",
            row(">ids hit", ": " + num(s.idsAlerts)),
            row(">alerts", ": " + (rd ? num(s.today) + " today · " + num(s.alerts) + " total" : "–")),
            row(">attackers", ": " + (rd ? num(s.attackers) : "–"))
        ]
        if (s.last) {
            var ev = String(s.last)
            var i = ev.indexOf("] ")                 // drop the leading [timestamp]
            if (ev.charAt(0) === "[" && i > 0) ev = ev.substring(i + 2)
            rows.push(row(">last", ": " + esc(ev.slice(0, 52))))
        }
        if (!rd) rows.push("<font color='" + pal.muted + "'>log not readable as your user: <b>sudo sysmode logs</b></font>")
        return rows
    }

    readonly property bool wsHasFullscreen: {
        var w = Hyprland.workspaces.values
        for (var i = 0; i < w.length; i++) {
            if (w[i].focused && (w[i].hasfullscreen || w[i].hasFullscreen)) return true
        }
        return false
    }
    onWsHasFullscreenChanged: if (wsHasFullscreen && !pinned && open) close()

    property bool termLinger: false
    onOpenChanged: {
        if (open) { termLinger = true; termLingerT.stop() }
        else termLingerT.restart()
    }
    Timer { id: termLingerT; interval: 420; onTriggered: { root.termLinger = false; gc() } }

    PanelWindow {
        id: win
        anchors { top: !root.atBottom; bottom: root.atBottom; left: !root.atRight; right: root.atRight }
        // fixed size: resizing on open / close re-sends enter / leave and made the console open and close by itself (mask = click-through)
        implicitWidth: root.boxW + 60
        implicitHeight: 660
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-term"
        WlrLayershell.layer: WlrLayer.Top
        // Exclusive while the pointer is over the console (Hyprland's follow_mouse would otherwise hand the keyboard to the
        // terminal beside it); the moment the pointer leaves it is on-demand again, so clicking another window just works
        WlrLayershell.keyboardFocus: !root.focused ? WlrKeyboardFocus.None
                                   : ((root.grabKeys || root.zoneHover || root.askPass) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)

        mask: Region { item: zone }

        // ONE hover zone covers the corner trigger, the gap and the whole box, so moving from the corner onto the
        // box (or the box sliding in under a resting pointer) never counts as "left": no more flicker in and out
        Item {
            id: zone
            enabled: !root.wsHasFullscreen
            anchors.top: root.atBottom ? undefined : parent.top
            anchors.bottom: root.atBottom ? parent.bottom : undefined
            anchors.left: root.atRight ? undefined : parent.left
            anchors.right: root.atRight ? parent.right : undefined
            width: root.shown ? root.boxW + 40 : (root.clickMode ? 28 : (root.wsHasFullscreen ? 0 : 14))
            // top corner: down to the bottom of the box. bottom corner: the box's height plus its gaps (the box then sits on the bottom edge)
            height: root.shown ? (root.atBottom ? box.height + root.pal.boxEdge + 24 : box.y + box.height + 24) : (root.clickMode ? 28 : (root.wsHasFullscreen ? 0 : 14))
            HoverHandler { enabled: !root.wsHasFullscreen; onHoveredChanged: { root.zoneHover = hovered; root.setHover(hovered) } }

            // click mode: a faint tab marks the corner
            Rectangle {
                visible: root.clickMode && !root.shown
                x: root.atRight ? parent.width - 15 : 3; y: root.atBottom ? parent.height - 15 : 3; width: 12; height: 12; radius: 6
                color: Qt.alpha(root.pal.accent, 0.35)
            }
            Item {
                x: root.atRight ? parent.width - width : 0; y: root.atBottom ? parent.height - height : 0
                width: 20; height: 14
                TapHandler {
                    enabled: root.clickMode
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.cornerTap()
                }
            }

        Glass {
            id: box
            pal: root.pal
            // left corners: 22 px from the screen's left edge, sliding in from the left; right corners: 18 px into a zone that is 40 px wider
            // than the box = 22 px from the right edge, sliding in from the right. Top: 90 px down (under the bar) and slides down from the
            // top; bottom: 22 px up from the bottom edge and slides up from below.
            x: (root.atRight ? 18 + (1 - root.reveal) * (root.boxW * 0.5) : 22 - (1 - root.reveal) * (root.boxW * 0.5))
            y: root.atBottom ? (zone.height - root.pal.boxEdge - height + (1 - root.reveal) * (height + root.pal.boxEdge + 14))
                             : (root.pal.boxTop - (1 - root.reveal) * (height + root.pal.boxTop + 14))
            width: root.boxW
            height: Math.min(520, 40 + body.implicitHeight + 76)
            radius: root.pal.rLg
            opacityBody: 0.94
            opacity: Math.min(1, root.reveal * 1.6)
            visible: opacity > 0.01
            border.color: root.focused ? root.pal.lineFocus : Qt.alpha(root.pal.accent, 0.40)
            Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on y { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

            MouseArea {
                anchors.fill: parent
                onClicked: root.takeFocus()
            }

            // High-contrast background backing to ensure text is crisp and readable
            Rectangle {
                anchors.fill: parent
                radius: root.pal.rLg
                color: Qt.rgba(0, 0, 0, 0.45)
            }

            // hover mode: resting the pointer on the box itself (not just the corner) is enough to type, no click needed.
            // Leaving with an empty prompt closes it and hands the keyboard straight back.
            HoverHandler { onHoveredChanged: { if (hovered && root.open && !root.focused && !root.clickMode) dwellT.restart(); else dwellT.stop() } }
            Timer { id: dwellT; interval: 250; onTriggered: if (root.open && !root.focused) root.takeFocus() }

            // subtle constellation backing (toned down so text remains readable)
            Backdrop {
                visible: root.shown && root.stars
                anchors.fill: parent
                anchors.margins: 14
                pal: root.pal
                mode: root.sysmode
                avatarStars: root.starData
                profileStars: root.profileStars
                dots: 6
                artStrength: 0.25
                artFit: 0.95
                artShift: 90
            }
            BarStars { anchors.fill: parent; anchors.margins: 14; pal: root.pal; count: root.flyCount; loopMs: root.flyLoop; sizeScale: 1.3; active: root.shown; visible: root.shown && root.flyCount > 0 }


            // ---------- title line ----------
            Item {
                id: head
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 16 }
                height: 20
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "❯ halcyon"
                    color: root.pal.accent
                    font.family: root.mono
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.centerIn: parent
                    visible: root.busy
                    text: root.askPass ? "waiting for password" : "running · Ctrl+C"
                    color: root.pal.accent
                    font.family: root.mono
                    font.pixelSize: 11
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.sysmode !== "" ? root.sysmode : "no mode")
                    color: root.modeColor[root.sysmode] || root.pal.muted
                    font.family: root.mono
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }
            Rectangle { id: sep1; anchors { left: parent.left; right: parent.right; top: head.bottom; leftMargin: 20; rightMargin: 20; topMargin: 10 } height: 1; color: root.pal.lineSoft }

            // ---------- body: status when idle, output once you type / run ----------
            Item {
                id: body
                anchors { left: parent.left; right: parent.right; top: sep1.bottom; bottom: sep2.top; leftMargin: 20; rightMargin: 20; topMargin: 12; bottomMargin: 10 }
                readonly property bool idle: input.text === "" && out.count === 0 && !root.busy
                implicitHeight: idle ? statusCol.implicitHeight : Math.min(320, Math.max(40, view.contentHeight + 4))

                Column {
                    id: statusCol
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    spacing: 3
                    opacity: body.idle ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    Repeater {
                        model: root.statusRows
                        delegate: Text {
                            required property string modelData
                            width: statusCol.width
                            text: modelData
                            textFormat: Text.RichText
                            color: "#f3f4f6"
                            elide: Text.ElideRight
                            font.family: root.mono
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            lineHeight: 1.15
                            style: Text.Outline
                            styleColor: Qt.rgba(0, 0, 0, 0.70)
                        }
                    }
                    Text {
                        topPadding: 6
                        text: "type a command · secure · stealth · relaxed · lockdown"
                        color: Qt.alpha(root.pal.muted, 0.9)
                        font.family: root.mono
                        font.pixelSize: 10
                    }
                }

                ListView {
                    id: view
                    anchors.fill: parent
                    clip: true
                    model: out
                    opacity: body.idle ? 0 : 1
                    visible: opacity > 0.01
                    boundsBehavior: Flickable.StopAtBounds
                    TapHandler { onTapped: root.takeFocus() }
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    delegate: Text {
                        required property string t
                        required property string k
                        width: view.width
                        text: t === "" ? " " : t
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAnywhere
                        color: k === "cmd" ? root.pal.accent : k === "err" ? root.pal.bad : k === "info" ? Qt.lighter(root.pal.muted, 1.35) : "#f9fafb"
                        font.family: root.mono
                        font.pixelSize: 12
                        font.weight: k === "cmd" ? Font.DemiBold : Font.Normal
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.70)
                    }
                }
            }

            // ---------- the matches Tab found ----------
            Rectangle {
                id: compBox
                visible: root.candOpen && root.cands.length > 1
                z: 20
                anchors { left: parent.left; bottom: sep2.top; leftMargin: 20; bottomMargin: 6 }
                width: Math.min(parent.width - 40, compCol.implicitWidth + 16)
                height: compCol.implicitHeight + 12
                radius: root.pal.rSm
                color: Qt.alpha(root.pal.surface, 0.97)
                border.width: 1
                border.color: root.pal.line
                Column {
                    id: compCol
                    x: 8; y: 6
                    Repeater {
                        model: root.candWindow
                        delegate: Rectangle {
                            required property var modelData
                            width: compBox.width - 16
                            implicitWidth: ct.implicitWidth + 12
                            height: 19
                            radius: 5
                            color: modelData.cur ? Qt.alpha(root.pal.accent, 0.25) : "transparent"
                            Text {
                                id: ct
                                x: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 12
                                elide: Text.ElideRight
                                text: modelData.t
                                textFormat: Text.PlainText
                                color: modelData.cur ? root.pal.text : (modelData.dim ? Qt.alpha(root.pal.muted, 0.8) : root.pal.muted)
                                font.family: root.mono
                                font.pixelSize: 12
                                font.weight: modelData.cur ? Font.DemiBold : Font.Normal
                            }
                        }
                    }
                }
            }

            // ---------- input line ----------
            Rectangle { id: sep2; anchors { left: parent.left; right: parent.right; bottom: inputRow.top; leftMargin: 20; rightMargin: 20; bottomMargin: 8 } height: 1; color: root.pal.lineSoft }
            Item {
                id: inputRow
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 16 }
                height: 22

                TapHandler { onTapped: root.takeFocus() }
                Text {
                    id: prompt
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.askPass ? "[sudo] password ❯" : root.cwdLabel() + " ❯"
                    color: root.askPass ? root.pal.warn : root.pal.accent
                    font.family: root.mono
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.70)
                }
                TextInput {
                    id: input
                    anchors.left: prompt.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#ffffff"
                    selectionColor: Qt.alpha(root.pal.accent, 0.45)
                    font.family: root.mono
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    clip: true
                    echoMode: root.askPass ? TextInput.Password : TextInput.Normal
                    passwordCharacter: "•"
                    onTextEdited: { root.histIdx = -1; root.closeComp() }
                    // the field swallows the click, so ask for the keyboard here too (passive: the cursor still moves)
                    TapHandler { onTapped: root.takeFocus() }

                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Tab && !root.askPass) { root.complete(false); e.accepted = true }
                        else if (e.key === Qt.Key_Backtab && !root.askPass) { root.complete(true); e.accepted = true }
                        else if ((e.key === Qt.Key_Right || e.key === Qt.Key_End) && root.ghost !== "") {
                            text = text + root.ghost; cursorPosition = text.length; e.accepted = true
                        }
                        else if (e.key === Qt.Key_Escape && root.candOpen) { root.closeComp(); e.accepted = true }
                        else if (e.key === Qt.Key_Escape) {
                            if (root.askPass) { root.cancelRun(); text = "" } else root.close()
                            e.accepted = true
                        }
                        else if (e.key === Qt.Key_C && (e.modifiers & Qt.ControlModifier) && root.busy) { root.cancelRun(); text = ""; e.accepted = true }
                        else if (e.key === Qt.Key_L && (e.modifiers & Qt.ControlModifier)) { root.clearOut(); e.accepted = true }
                        else if (e.key === Qt.Key_U && (e.modifiers & Qt.ControlModifier)) { text = ""; e.accepted = true }
                        else if (!root.askPass && e.key === Qt.Key_Up && root.history.length) {
                            root.histIdx = root.histIdx < 0 ? root.history.length - 1 : Math.max(0, root.histIdx - 1)
                            text = root.history[root.histIdx]; cursorPosition = text.length; e.accepted = true
                        } else if (!root.askPass && e.key === Qt.Key_Down && root.histIdx >= 0) {
                            root.histIdx++
                            text = root.histIdx >= root.history.length ? "" : root.history[root.histIdx]
                            if (root.histIdx >= root.history.length) root.histIdx = -1
                            cursorPosition = text.length; e.accepted = true
                        }
                    }
                    onAccepted: {
                        var l = text
                        text = ""
                        if (root.askPass) { runner.write(l + "\n"); root.askPass = false; return }
                        root.submit(l)
                    }
                }
                // the grey rest of an earlier command (Right arrow / End takes it)
                Text {
                    anchors.left: input.left
                    anchors.leftMargin: input.contentWidth
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.ghost !== "" && input.contentWidth < input.width - 24
                    text: root.ghost
                    textFormat: Text.PlainText
                    color: Qt.alpha(root.pal.muted, 0.6)
                    font.family: root.mono
                    font.pixelSize: 13
                }
                Text {
                    anchors.left: prompt.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    visible: input.text === "" && !root.focused
                    text: "click here, or press SUPER+SHIFT+Enter, to type"
                    color: Qt.alpha(root.pal.muted, 0.7)
                    font.family: root.mono
                    font.pixelSize: 11
                }
            }
        }
        }
    }
}
