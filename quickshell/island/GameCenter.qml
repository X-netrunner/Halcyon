import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Wayland
import Quickshell.Hyprland

// Game Center.   >gamecenter in the launcher (also `island command gamecenter`, and the IPC calls `gamecenter` / `gamecenterpage`).
// One window for the game launcher (scripts: none, everything goes through the `hgl` binary, see docs/games.md):
//   Library   a grid of cover art, last played first. Type to search, arrows move, Enter plays. The drawer on the right is the
//             game's profile: Proton version, gamescope preset, wrappers, Halcyon's lean mode, Wayland, and under "Advanced" the
//             launch options, environment variables, prefix tools, the newest log and the crash check.
//             Add game opens a .exe browser inside the window (ExePicker.qml); the path can also be pasted.
//   Stores    Epic (legendary) and GOG (gogdl): log in, see what you own, install, read what is installed, fetch cover art.
//   Runtimes  the Proton versions games run on (install, default, roll back, remove, clean up, show in Steam).
//   Doctor    what the system still needs for games (Vulkan, 32-bit libraries, umu, gamemode ...).
// It reads `hgl list --json`, `hgl proton list --json`, `hgl doctor --json` and `hgl triage <id> --json`, and changes things with
// `hgl set / add / import / remove / proton ... / fix`. Nothing runs while the window is closed (LazyLoader, no timers, no processes).
// Anything that needs a password or shows long output (installing packages) goes to the pop-out console; the window closes first,
// because it holds the keyboard.
Scope {
    id: root
    property var pal
    property string hgl: ""                 // the hgl binary (shell.qml gives the path)
    property string runningId: ""           // the game that runs now (shell.qml), "" = none
    property bool open: false
    property string tab: "library"          // library | stores | runtimes | doctor
    signal launchRequested(string id)
    signal stopRequested()
    signal consoleRequested(string cmd)
    signal focusRequested(string what)      // the window's own fields take the keyboard (ids inside the LazyLoader are not reachable from here)

    // ---- state
    property var games: []
    property bool gamesLoaded: false
    property var runtimes: []
    property bool steamLink: false
    property var checks: []
    property bool checksLoaded: false
    property string filter: "all"           // all | steam | epic | gog | exe
    property string search: ""
    property string selId: ""
    property bool addOpen: false
    property string addPath: ""
    property string addName: ""
    property bool pickerOpen: false
    property string exeDir: ""              // the folder the .exe browser opens in (the last one you picked from)
    property bool advOpen: false            // the drawer's "Advanced" section
    property bool protonOpen: false
    property bool logOpen: false
    property string logText: ""
    property string logPath: ""
    property var findings: []
    property bool triaged: false
    property var lastSession: null
    property bool confirmRemove: false
    property bool busy: false
    property string note: ""
    property bool noteBad: false

    readonly property string home: Quickshell.env("HOME")

    // ---- open / close
    function show(t) {
        tab = (t === "runtimes" || t === "doctor" || t === "stores") ? t : "library"
        search = ""; note = ""; protonOpen = false; logOpen = false; confirmRemove = false; pickerOpen = false
        open = true
        reloadAll()
        if (tab === "doctor") loadChecks()
        if (tab === "stores") loadStores()
        Qt.callLater(function () { root.focusRequested(root.tab === "library" ? "search" : "panel") })
    }
    function hide() { open = false; confirmRemove = false; pickerOpen = false }
    function close() { hide() }
    function toggle() { if (open) hide(); else show("library") }
    function showAdd() { show("library"); browseExe() }
    function setTab(t) {
        tab = t
        pickerOpen = false
        if (t === "doctor" && !checksLoaded) loadChecks()
        if (t === "stores") loadStores()
        Qt.callLater(function () { root.focusRequested(root.tab === "library" ? "search" : "panel") })
    }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    // the game started or ended (shell.qml): read the library again so the badges and play times are right
    onRunningIdChanged: {
        if (runningId === "") endedT.restart()           // last-session.json is written as hgl finishes: read it a moment later
        if (open) reloadAll()
    }
    Timer { id: endedT; interval: 900; onTriggered: { root.loadSession(); endedRead.restart() } }
    Timer { id: endedRead; interval: 400; onTriggered: root.launchEnded() }

    function flash(t, bad) { note = t; noteBad = bad === true; noteT.restart() }
    Timer { id: noteT; interval: 5000; onTriggered: root.note = "" }

    // ---- small helpers
    function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    function fmtTime(secs) {
        var s = Math.max(0, Math.floor(secs || 0)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
        if (s === 0) return "Not played yet"
        if (h > 0) return h + " h " + m + " min"
        return Math.max(1, m) + " min"
    }
    function fmtAgo(ts) {
        if (!ts || ts <= 0) return "never"
        var d = Math.max(0, Date.now() / 1000 - ts)
        if (d < 3600) return Math.max(1, Math.floor(d / 60)) + " min ago"
        if (d < 86400) return Math.floor(d / 3600) + " h ago"
        if (d < 86400 * 60) return Math.floor(d / 86400) + " days ago"
        return Math.floor(d / 86400 / 30) + " months ago"
    }
    function srcLabel(s) { return s === "steam" ? "Steam" : (s === "epic" ? "Epic" : (s === "gog" ? "GOG" : (s === "flatpak" ? "Flatpak" : "Windows"))) }
    // runs through Proton (a prefix, wrappers, gamescope); Steam and Flatpak games start their own way
    function isWine(g) { return g !== null && g !== undefined && g.source !== "steam" && g.source !== "flatpak" }
    function refreshLibrary() {
        act([hgl, "import", "flatpak"], "")
        act([hgl, "import", "steam"], "Library refreshed")
    }
    function lastLine(t) {
        var l = String(t || "").trim().split("\n")
        return l[l.length - 1].replace(/^hgl:\s*/, "")
    }
    function expandPath(p) {
        var s = String(p || "").trim()
        if (s.length > 1 && ((s[0] === '"' && s[s.length - 1] === '"') || (s[0] === "'" && s[s.length - 1] === "'"))) s = s.substring(1, s.length - 1)
        if (s.indexOf("file://") === 0) s = decodeURIComponent(s.substring(7))
        if (s === "~") s = home
        else if (s.indexOf("~/") === 0) s = home + s.substring(1)
        return s
    }
    function prettyPath(p) { return p.indexOf(home + "/") === 0 ? "~" + p.substring(home.length) : p }
    // a name from the folders around the .exe: ~/Games/Hollow Knight/hollow_knight.exe -> "Hollow Knight",
    // .../Hades/x64/Hades.exe -> "Hades" (folders like bin, x64, Win64, Binaries are skipped)
    function guessName(p) {
        var parts = String(p).split("/").filter(function (s) { return s !== "" })
        var exe = (parts.pop() || "").replace(/\.exe$/i, "")
        var skip = /^(bin(aries)?|win(32|64|dows)?|x(86|64)|x86_64|amd64|game|games|shipping|retail|release|program files( \(x86\))?|drive_c|downloads|desktop|halcyon|epic|gog|heroic)$/i
        while (parts.length > 0) {
            var d = parts.pop()
            if (parts.length > 0 && parts[parts.length - 1] === "home") break        // reached /home/<user>
            if (!skip.test(d)) return d
        }
        return exe
    }

    // ---- the .exe browser (ExePicker.qml, inside the window)
    function browseExe() { pickerOpen = true; Qt.callLater(function () { root.focusRequested("picker") }) }
    function exePicked(p) {
        pickerOpen = false
        addOpen = true
        addPath = p
        exeDir = p.substring(0, p.lastIndexOf("/"))
        addName = guessName(p)
        Qt.callLater(function () { root.focusRequested("addname") })
    }

    // ---- what is shown
    // the filter chips only offer the stores you have games from
    readonly property var sources: {
        var seen = []
        for (var i = 0; i < games.length; i++) if (seen.indexOf(games[i].source) < 0) seen.push(games[i].source)
        return ["steam", "epic", "gog", "flatpak", "exe"].filter(function (s) { return seen.indexOf(s) >= 0 })
    }
    onSourcesChanged: if (filter !== "all" && sources.indexOf(filter) < 0) filter = "all"
    readonly property var shown: {
        var s = search.trim().toLowerCase()
        return games.filter(function (g) {
            if (filter !== "all" && g.source !== filter) return false
            return s === "" || (g.name || "").toLowerCase().indexOf(s) >= 0
        })
    }
    readonly property var sel: {
        for (var i = 0; i < games.length; i++) if (games[i].id === selId) return games[i]
        return null
    }
    readonly property bool selRunning: sel !== null && sel.id === runningId
    readonly property var defaultRuntime: {
        for (var i = 0; i < runtimes.length; i++) if (runtimes[i]["default"] === true) return runtimes[i]
        return null
    }
    function runtimeFor(name) {
        for (var i = 0; i < runtimes.length; i++) if (runtimes[i].name === name) return runtimes[i]
        return defaultRuntime
    }

    // ---- reading (one-shot processes, only while the window is open)
    function reloadAll() { loadGames(); loadRuntimes(); loadSession(); loadSuggest() }
    function loadGames() { if (!gamesProc.running) gamesProc.running = true }
    function loadRuntimes() { if (!rtProc.running) rtProc.running = true; if (!linkProc.running) linkProc.running = true }
    function loadChecks() { if (!docProc.running) docProc.running = true }
    function loadSession() { if (!sessProc.running) sessProc.running = true }
    function loadTriage() {
        if (!sel || triageProc.running) return
        triageProc.command = [hgl, "triage", sel.id, "--json"]
        triageProc.running = true
    }
    // what this machine's class suggests for the selected game (`hgl suggest <id> --json`: the class, the changes, in-game settings)
    property var suggestion: null
    property bool tipsOpen: false
    function loadSuggest() {
        if (!sel || sugProc.running) return
        sugProc.command = [hgl, "suggest", sel.id, "--json"]
        sugProc.running = true
    }
    function applySuggest() { if (sel) act([hgl, "suggest", sel.id, "--apply"], "Suggested settings applied") }
    // one line per change; the three PRIME variables are one thing to the player
    readonly property var sugRows: {
        if (!suggestion) return []
        var out = [], prime = false
        ;(suggestion.changes || []).forEach(function (c) {
            if (/^env\.(__NV_PRIME_RENDER_OFFLOAD|__VK_LAYER_NV_optimus|__GLX_VENDOR_LIBRARY_NAME)$/.test(c.key)) {
                if (!prime) out.push({ t: "Run on the NVIDIA card", d: c.why })
                prime = true
            }
            else if (c.key === "env.PROTON_ENABLE_NVAPI") out.push({ t: "DLSS and Reflex (NVAPI)", d: c.why })
            else if (c.key === "gamescope") out.push({ t: c.value === "" ? "Gamescope off" : "Gamescope: 720p upscaled with FSR", d: c.why })
            else if (c.key === "wrappers") out.push({ t: "Wrappers: " + c.value.split(",").join(", "), d: c.why })
            else if (c.key === "lean") out.push({ t: "Lean island on", d: c.why })
            else out.push({ t: c.key + " = " + c.value, d: c.why })
        })
        return out
    }
    function loadLog() {
        if (!sel || logProc.running) return
        logProc.command = [hgl, "logs", sel.id]
        logProc.running = true
    }

    Process {
        id: gamesProc
        command: [root.hgl, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var l = JSON.parse(text)
                    root.games = Array.isArray(l) ? l : []
                    root.gamesLoaded = true
                    var ok = false
                    for (var i = 0; i < root.games.length; i++) if (root.games[i].id === root.selId) ok = true
                    if (!ok) {
                        var pick = root.runningId !== "" ? root.runningId : (root.games.length > 0 ? root.games[0].id : "")
                        root.selId = pick
                    }
                    root.syncInputs()
                } catch (e) { /* a failed read keeps the list that is shown */ }
            }
        }
    }
    Process {
        id: rtProc
        command: [root.hgl, "proton", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { var l = JSON.parse(text); root.runtimes = Array.isArray(l) ? l : [] } catch (e) { root.runtimes = [] }
            }
        }
    }
    Process {
        id: linkProc
        command: [root.hgl, "config", "steam_link"]
        stdout: StdioCollector { onStreamFinished: root.steamLink = text.trim() === "1" }
    }
    Process {
        id: docProc
        command: [root.hgl, "doctor", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { var l = JSON.parse(text); root.checks = Array.isArray(l) ? l : []; root.checksLoaded = true } catch (e) { /* keep */ }
            }
        }
    }
    Process {
        id: sessProc
        command: ["sh", "-c", "cat \"${XDG_STATE_HOME:-$HOME/.local/state}/Halcyon/hgl/last-session.json\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.lastSession = JSON.parse(text) } catch (e) { root.lastSession = null } }
        }
    }
    Process {
        id: triageProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { var d = JSON.parse(text); root.findings = d.findings || []; root.triaged = true } catch (e) { root.findings = []; root.triaged = true }
            }
        }
    }
    Process {
        id: sugProc
        stdout: StdioCollector {
            onStreamFinished: { try { var d = JSON.parse(text); if (root.sel) root.suggestion = d } catch (e) { root.suggestion = null } }
        }
    }
    Process {
        id: logProc
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.split("\n")
                root.logPath = lines.length > 0 ? lines[0] : ""
                root.logText = lines.slice(1).slice(-60).join("\n")
            }
        }
    }

    // ---- stores: Epic (legendary) and GOG (gogdl). Status is cheap; the library of what you own is read only when you ask (it goes online)
    property var epicSt: ({ installed: false, loggedIn: false, account: "" })
    property var gogSt: ({ installed: false, loggedIn: false, url: "" })
    property var epicList: []
    property var gogList: []
    property bool epicListed: false
    property bool gogListed: false
    property string storeErr: ""
    property bool storeBusy: false
    property string gogAddr: ""
    function loadStores() { if (!epicStProc.running) epicStProc.running = true; if (!gogStProc.running) gogStProc.running = true }
    function loadEpicList() { if (epicListProc.running) return; storeErr = ""; storeBusy = true; epicListProc.running = true }
    function loadGogList() { if (gogListProc.running) return; storeErr = ""; storeBusy = true; gogListProc.running = true }
    function gogLogin() {
        var a = gogAddr.trim()
        if (a === "") { flash("Paste the address you land on after signing in to GOG", true); return }
        act([hgl, "gog", "login", a], "Logged in to GOG")
        gogAddr = ""
        Qt.callLater(function () { root.loadStores() })
    }
    Process {
        id: epicStProc
        command: [root.hgl, "epic", "status", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.epicSt = JSON.parse(text) } catch (e) { /* keep */ } } }
    }
    Process {
        id: gogStProc
        command: [root.hgl, "gog", "status", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.gogSt = JSON.parse(text) } catch (e) { /* keep */ } } }
    }
    Process {
        id: epicListProc
        command: [root.hgl, "epic", "list", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.epicList = JSON.parse(text); root.epicListed = true } catch (e) { /* keep */ } } }
        stderr: StdioCollector { onStreamFinished: root.storeErr = text.trim() }
        onExited: code => { root.storeBusy = false; if (code !== 0) root.flash(root.storeErr !== "" ? root.lastLine(root.storeErr) : "Could not read the Epic library", true) }
    }
    Process {
        id: gogListProc
        command: [root.hgl, "gog", "list", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.gogList = JSON.parse(text); root.gogListed = true } catch (e) { /* keep */ } } }
        stderr: StdioCollector { onStreamFinished: root.storeErr = text.trim() }
        onExited: code => { root.storeBusy = false; if (code !== 0) root.flash(root.storeErr !== "" ? root.lastLine(root.storeErr) : "Could not read the GOG library", true) }
    }

    // ---- changing things: one queue, then the library is read again
    property var queue: []
    property var curAct: ({ ok: "" })
    property int lastCode: 0
    property string actErr: ""
    function act(cmd, okNote, afterTriage) {
        queue = queue.concat([{ cmd: cmd, ok: okNote || "", triage: afterTriage === true }])
        if (!actProc.running && !settleT.running) nextAct()
    }
    function nextAct() {
        if (queue.length === 0) { busy = false; reloadAll(); return }
        curAct = queue[0]
        queue = queue.slice(1)
        busy = true
        actErr = ""
        actProc.command = curAct.cmd
        actProc.running = true
    }
    Process {
        id: actProc
        stderr: StdioCollector { onStreamFinished: root.actErr = text.trim() }
        onExited: code => { root.lastCode = code; settleT.restart() }
    }
    Timer {
        id: settleT
        interval: 160
        onTriggered: {
            if (root.lastCode !== 0) root.flash(root.actErr !== "" ? root.lastLine(root.actErr) : "That did not work", true)
            else if (root.curAct.ok !== "") root.flash(root.curAct.ok, false)
            if (root.curAct.triage) root.loadTriage()
            root.nextAct()
        }
    }
    function setKey(key, val, okNote) {
        if (!sel) return
        act([hgl, "set", sel.id, key, val], okNote || "")
    }
    function runInConsole(cmd) { hide(); consoleRequested(cmd) }

    // the text boxes of the drawer keep what you type while the list refreshes: they are only filled when the game changes
    property string argsSeed: ""
    property int argsSeedN: 0
    function syncInputs() {
        argsSeed = sel ? (sel.args || "") : ""
        argsSeedN++
    }
    onSelIdChanged: {
        protonOpen = false; logOpen = false; logText = ""; findings = []; triaged = false; confirmRemove = false
        suggestion = null
        syncInputs()
        // `sel` follows selId only after this handler: read it a moment later
        Qt.callLater(function () {
            root.loadSuggest()
            if (root.sel && root.sel.lastExit !== null && root.sel.lastExit !== 0) root.loadTriage()
        })
    }

    // ---- the drawer's toggles
    readonly property var toggleDefs: [
        { k: "gamemode", t: "Gamemode", d: "Asks the system for its performance mode while the game runs", wrapper: true },
        { k: "mangohud", t: "MangoHud", d: "FPS and temperature overlay", wrapper: true },
        { k: "lean", t: "Lean island", d: "Halcyon pauses its feeds, widgets and animations while this game runs", wrapper: false },
        { k: "wayland", t: "Wayland mode", d: "Off is safer: most games still run best through XWayland", wrapper: false }
    ]
    function toggleOn(def) {
        if (!sel) return false
        if (def.wrapper) return (sel.wrappers || []).indexOf(def.k) >= 0
        return sel[def.k] === true
    }
    function flip(def) {
        if (!sel) return
        if (def.wrapper) {
            var cur = (sel.wrappers || []).slice(), i = cur.indexOf(def.k)
            if (i >= 0) cur.splice(i, 1); else cur.push(def.k)
            setKey("wrappers", cur.join(","))
        } else {
            setKey(def.k, toggleOn(def) ? "off" : "on")
        }
    }
    readonly property var scopes: [
        { v: "", t: "Off" }, { v: "native", t: "Native" }, { v: "1080p", t: "1080p" },
        { v: "1440p", t: "1440p" }, { v: "fsr1080", t: "FSR 1080p" }, { v: "fsr1440", t: "FSR 1440p" }
    ]
    readonly property var presetValues: ["", "native", "1080p", "1440p", "fsr1080", "fsr1440"]

    function addGame() {
        var p = expandPath(addPath)
        if (p === "") { flash("Paste the path of the game's .exe first", true); return }
        var cmd = [hgl, "add", p]
        if (addName.trim() !== "") cmd = cmd.concat(["--name", addName.trim()])
        act(cmd, "Added to the library")
        addOpen = false; addPath = ""; addName = ""
    }
    function prefixFolder() {
        if (!isWine(sel)) return
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && xdg-open \"$1\"", "sh", sel.prefix])
    }
    function wineSettings() {
        if (!isWine(sel)) return
        var rt = runtimeFor(sel.proton)
        if (!rt) { flash("Install a Proton version first (the Proton tab)", true); return }
        runInConsole("WINEPREFIX=" + q(sel.prefix) + " PROTONPATH=" + q(rt.path) + " GAMEID=umu-0 umu-run winecfg")
    }
    // ---- after Play: the window stays and says what is going on (hgl's own output and the game's log, in words) until the game's
    // window appears; a game that closes within a minute brings the window back with what its log says
    property string launchId: ""
    property string phase: ""               // "" | starting | running | ended | failed
    property string phaseText: ""
    property string launchLog: ""           // the end of the game's log, without the noise
    readonly property string launchOut: Quickshell.env("XDG_RUNTIME_DIR") + "/hgl-launch.out"     // shell.qml sends `hgl run` here
    function playSel() {
        if (!sel) return
        if (selRunning) { stopRequested(); return }
        if (runningId !== "") { flash("Another game is running: stop it first", true); return }
        launchId = sel.id
        phase = "starting"
        phaseText = "Starting " + sel.name + "\u2026"
        launchLog = ""
        launchRequested(sel.id)
        pollT.restart()
    }
    Timer { id: pollT; interval: 1000; repeat: true; running: root.phase === "starting"; onTriggered: if (!pollProc.running) pollProc.running = true }
    Process {
        id: pollProc
        command: ["sh", "-c", "cat \"$1\" 2>/dev/null; echo '@@LOG@@'; L=$(sed -n 's/^log: //p' \"$1\" 2>/dev/null | head -n 1); " +
                  "[ -f \"$L\" ] && grep -avE 'gamemodeauto|^(env|cwd|cmd): |^hgl [0-9]|=== game output' \"$L\" | tail -n 40", "sh", root.launchOut]
        stdout: StdioCollector { onStreamFinished: root.readLaunch(text) }
    }
    function readLaunch(t) {
        var parts = t.split("@@LOG@@"), outText = parts[0], log = (parts[1] || "").trim()
        var err = outText.split("\n").filter(function (l) { return l.indexOf("hgl: ") === 0 })
        if (err.length > 0 && phase === "starting") {
            phase = "failed"
            phaseText = err[err.length - 1].substring(5)
        }
        var lines = log === "" ? [] : log.split("\n")
        launchLog = lines.filter(function (l) { return !/^(ProtonFixes\[\d+\] INFO|INFO: )/.test(l) }).slice(-8).join("\n")
        if (phase !== "starting") return
        var g = null
        for (var i = 0; i < games.length; i++) if (games[i].id === launchId) g = games[i]
        var name = g ? g.name : "the game"
        if (/Downloading steamrt|please wait/i.test(log) && !/ntsync|Executable is|launching with/i.test(log))
            phaseText = "Downloading the Steam Runtime. First start only: a few minutes"
        else if (/Upgrading prefix|Creating prefix|wineboot/i.test(log) && !/Executable is|launching with/i.test(log))
            phaseText = "Setting up " + name + "'s Windows folder. First start only"
        else if (/Executable is|launching with|ntsync/i.test(log))
            phaseText = "Opening " + name + "\u2026"
    }
    // the game's window appeared: get out of the way
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "openwindow" && root.phase === "starting" && root.runningId === root.launchId) { root.phase = "running"; root.hide() }
        }
    }
    // the game ended: a short session that you did not stop yourself is worth saying something about
    function launchEnded() {
        if (launchId === "" || (phase !== "starting" && phase !== "running")) return
        var ls = lastSession
        if (!ls || ls.id !== launchId) return
        var stopped = ls.exit === 143 || ls.exit === 130 || ls.exit === 137
        if (ls.playedSecs >= 60 || stopped) { phase = ""; return }
        var name = ls.name || "The game"
        phase = "ended"
        phaseText = name + " closed after " + Math.max(1, ls.playedSecs) + " s" + (ls.exit !== null && ls.exit !== 0 ? " (code " + ls.exit + ")" : "")
        pollProc.running = true
        if (!open) { show("library") }
        selId = launchId
        Qt.callLater(function () { root.loadTriage() })
    }
    function fixFinding(f) {
        if (!sel) return
        if (f.fix === "doctor") runInConsole(hgl + " fix " + q(sel.id) + " " + q(f.id))
        else act([hgl, "fix", sel.id, f.id, "--yes"], "Fixed: " + f.title, true)
    }

    // ---------------------------------------------------------------- small pieces
    // the one filled button of a view (Add game, Play)
    component PrimaryBtn: Rectangle {
        id: pb
        property string label: ""
        property string glyph: ""
        property bool danger: false
        property bool disabled: false
        signal clicked()
        implicitWidth: pbRow.implicitWidth + 32
        implicitHeight: 38
        radius: height / 2
        opacity: disabled ? 0.45 : 1
        color: danger ? Qt.alpha(root.pal.bad, pbMa.containsMouse ? 0.30 : 0.18)
                      : (pbMa.containsMouse && !disabled ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent)
        scale: pbMa.pressed && !disabled ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 8
            Text {
                visible: pb.glyph !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: pb.glyph
                color: pb.danger ? root.pal.bad : root.pal.bg
                font.family: root.pal.font
                font.pixelSize: pb.height * 0.42
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pb.label
                color: pb.danger ? root.pal.bad : root.pal.bg
                font.family: root.pal.uiFont
                font.pixelSize: pb.height >= 44 ? root.pal.tTitle : root.pal.tBody
                font.weight: Font.DemiBold
            }
        }
        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: pb.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!pb.disabled) pb.clicked() }
    }
    // a tab of the header's segmented control
    component TabBtn: Rectangle {
        id: tb
        property string label: ""
        property string key: ""
        readonly property bool on: root.tab === key
        implicitWidth: tbTxt.implicitWidth + 30
        implicitHeight: 32
        radius: 16
        color: on ? root.pal.accent : (tbMa.containsMouse ? Qt.alpha(root.pal.text, 0.07) : "transparent")
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Text {
            id: tbTxt
            anchors.centerIn: parent
            text: tb.label
            color: tb.on ? root.pal.bg : root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
            font.weight: tb.on ? Font.DemiBold : Font.Medium
        }
        MouseArea { id: tbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setTab(tb.key) }
    }
    // a heading inside the drawer
    component SectionTitle: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
        font.weight: Font.DemiBold
        font.letterSpacing: root.pal.calm ? 0.2 : (0.8)
        font.capitalization: root.pal.calm ? Font.MixedCase : Font.AllUppercase
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
            WlrLayershell.namespace: "island-games"
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
                Component.onCompleted: {
                    ready = true; argsIn.text = root.argsSeed
                    Qt.callLater(function () { if (root.pickerOpen) root.focusRequested("picker"); else if (root.tab === "library") sin.forceActiveFocus(); else qp.forceActiveFocus() })
                }
                Keys.onEscapePressed: root.hide()
                Connections {
                    target: root
                    function onFocusRequested(what) {
                        if (what === "picker") picker.openAt(root.exeDir)
                        else if (what === "addname") { addNameIn.forceActiveFocus(); addNameIn.selectAll() }
                        else if (what === "search") sin.forceActiveFocus()
                        else qp.forceActiveFocus()
                    }
                    function onArgsSeedNChanged() { if (!argsIn.activeFocus) argsIn.text = root.argsSeed }
                }

                // dim the desktop: the window reads as one thing, and the text behind it stops showing through
                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: Math.min(1180, qp.width - 80)
                    height: Math.min(740, qp.height - 80)
                    radius: root.pal.rXl
                    opacityBody: 0.97
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                    anchors.centerIn: parent
                    opacity: qp.reveal
                    scale: 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 18

                        // ---- header: badge + title + state on the left, the tabs in the middle, close on the right
                        // Centred titles: the badge and title in the middle on top, the tabs on a line under them
                        Item {
                            id: gcHead
                            readonly property bool centred: root.pal.centerTitles
                            Layout.fillWidth: true
                            implicitHeight: centred ? 42 + 50 : 42
                            Row {
                                x: gcHead.centred ? (parent.width - width) / 2 : 0
                                y: gcHead.centred ? 0 : (parent.height - height) / 2
                                spacing: 12
                                Rectangle {
                                    width: 40; height: 40; radius: 13
                                    color: Qt.alpha(root.noteBad ? root.pal.bad : root.pal.accent, 0.16)
                                    border.width: 1
                                    border.color: Qt.alpha(root.noteBad ? root.pal.bad : root.pal.accent, 0.35)
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Text {
                                        anchors.centerIn: parent
                                        text: String.fromCodePoint(0xF0297)
                                        color: root.noteBad ? root.pal.bad : root.pal.accent
                                        font.family: root.pal.font
                                        font.pixelSize: 21
                                        opacity: root.busy ? 0.35 + 0.65 * Math.abs(Math.sin(pulse.tp * Math.PI)) : 1
                                    }
                                    Item {
                                        id: pulse
                                        property real tp: 0
                                        NumberAnimation on tp { from: 0; to: 1; duration: 900; loops: Animation.Infinite; running: root.busy }
                                    }
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1
                                    Text {
                                        x: gcHead.centred ? (parent.width - width) / 2 : 0
                                        text: "Game Center"
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tTitle + 3
                                        font.weight: Font.DemiBold
                                    }
                                    Text {
                                        width: Math.min(implicitWidth, gcHead.centred ? gcHead.width - 120 : tabs.x - 70)
                                        x: gcHead.centred ? (parent.width - width) / 2 : 0
                                        horizontalAlignment: gcHead.centred ? Text.AlignHCenter : Text.AlignLeft
                                        wrapMode: Text.Wrap
                                        text: root.note !== "" ? root.note
                                            : (root.busy ? "Working. Big downloads can take a few minutes"
                                            : (root.runningId !== "" ? "A game is running"
                                            : (root.games.length === 0 ? "Your library is empty" : root.games.length + (root.games.length === 1 ? " game" : " games") + " in your library")))
                                        color: root.noteBad ? root.pal.bad : (root.note !== "" ? root.pal.good : root.pal.muted)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap + 1
                                    }
                                }
                            }
                            Rectangle {
                                id: tabs
                                x: (parent.width - width) / 2
                                y: gcHead.centred ? parent.height - height : (parent.height - height) / 2
                                width: tabRow.implicitWidth + 8
                                height: 40
                                radius: 20
                                color: Qt.alpha(root.pal.surface, 0.8)
                                border.width: root.pal.calm ? 0 : 1
                                border.color: root.pal.lineSoft
                                Row {
                                    id: tabRow
                                    anchors.centerIn: parent
                                    spacing: 2
                                    TabBtn { label: "Library"; key: "library" }
                                    TabBtn { label: "Stores"; key: "stores" }
                                    TabBtn { label: "Proton"; key: "runtimes" }
                                    TabBtn { label: "Doctor"; key: "doctor" }
                                }
                            }
                            RoundBtn { anchors { right: parent.right; verticalCenter: parent.verticalCenter } pal: root.pal; size: 34; glyph: String.fromCodePoint(0xF0156); onClicked: root.hide() }
                        }

                        // ================= Library
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "library"
                            spacing: 18

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 12

                                // search, store filter, Read Steam, Add game
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 38
                                        radius: 19
                                        color: Qt.alpha(root.pal.surface, 0.8)
                                        border.width: 1
                                        border.color: sin.activeFocus ? Qt.alpha(root.pal.accent, 0.7) : root.pal.lineSoft
                                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                                        Text {
                                            id: sGlyph
                                            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                                            text: String.fromCodePoint(0xF0349)
                                            color: root.pal.muted
                                            font.family: root.pal.font
                                            font.pixelSize: 15
                                        }
                                        TextInput {
                                            id: sin
                                            anchors { left: sGlyph.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 10; rightMargin: 14 }
                                            verticalAlignment: TextInput.AlignVCenter
                                            clip: true
                                            color: root.pal.text
                                            selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                            selectedTextColor: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody + 1
                                            onTextChanged: { root.search = text; grid.currentIndex = 0; grid.pick() }
                                            Keys.onPressed: e => {
                                                var n = root.shown.length
                                                if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                                                else if (e.key === Qt.Key_Right) { if (grid.currentIndex < n - 1) { grid.currentIndex++; grid.pick() } e.accepted = true }
                                                else if (e.key === Qt.Key_Left) { if (grid.currentIndex > 0) { grid.currentIndex--; grid.pick() } e.accepted = true }
                                                else if (e.key === Qt.Key_Down) { grid.currentIndex = Math.min(n - 1, grid.currentIndex + grid.cols); grid.pick(); e.accepted = true }
                                                else if (e.key === Qt.Key_Up) { grid.currentIndex = Math.max(0, grid.currentIndex - grid.cols); grid.pick(); e.accepted = true }
                                                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { grid.pick(); root.playSel(); e.accepted = true }
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: sin.text.length === 0
                                                text: "Search your games"
                                                color: root.pal.muted
                                                font: sin.font
                                            }
                                        }
                                    }
                                    Chip { pal: root.pal; implicitHeight: 38; visible: root.sources.length > 1; label: "All"; on: root.filter === "all"; onClicked: root.filter = "all" }
                                    Repeater {
                                        model: root.sources.length > 1 ? root.sources : []
                                        delegate: Chip {
                                            required property var modelData
                                            pal: root.pal
                                            implicitHeight: 38
                                            label: root.srcLabel(modelData)
                                            on: root.filter === modelData
                                            onClicked: root.filter = modelData
                                        }
                                    }
                                    ActionChip {
                                        pal: root.pal
                                        implicitHeight: 38
                                        glyph: String.fromCodePoint(0xF0450)
                                        label: "Refresh"
                                        disabled: root.busy
                                        onClicked: root.refreshLibrary()
                                    }
                                    PrimaryBtn { glyph: String.fromCodePoint(0xF0415); label: "Add game"; onClicked: root.browseExe() }
                                }

                                // the .exe that was picked (or pasted): name it, add it
                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: root.addOpen
                                    implicitHeight: 64
                                    radius: root.pal.rLg
                                    color: Qt.alpha(root.pal.accent, 0.07)
                                    border.width: 1
                                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 14; rightMargin: 12 }
                                        spacing: 10
                                        Rectangle {
                                            width: 38; height: 38; radius: 12
                                            color: Qt.alpha(root.pal.accent, 0.16)
                                            Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF0297); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 19 }
                                        }
                                        // the path: shown short, editable (paste one here, ~ works)
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 38
                                            radius: root.pal.rSm
                                            color: Qt.alpha(root.pal.bg, 0.55)
                                            border.width: 1
                                            border.color: addPathIn.activeFocus ? Qt.alpha(root.pal.accent, 0.7) : root.pal.lineSoft
                                            TextInput {
                                                id: addPathIn
                                                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                                verticalAlignment: TextInput.AlignVCenter
                                                clip: true
                                                text: activeFocus ? root.addPath : root.prettyPath(root.addPath)
                                                color: root.pal.text
                                                selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                onTextEdited: root.addPath = root.expandPath(text)
                                                Keys.onEscapePressed: { root.addOpen = false; sin.forceActiveFocus() }
                                                Keys.onReturnPressed: root.addGame()
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: addPathIn.text.length === 0; text: "Path of the game's .exe"; color: root.pal.muted; font: addPathIn.font }
                                            }
                                        }
                                        ActionChip { pal: root.pal; implicitHeight: 38; glyph: String.fromCodePoint(0xF024B); label: "Browse"; onClicked: root.browseExe() }
                                        Rectangle {
                                            Layout.preferredWidth: 220
                                            Layout.preferredHeight: 38
                                            radius: root.pal.rSm
                                            color: Qt.alpha(root.pal.bg, 0.55)
                                            border.width: 1
                                            border.color: addNameIn.activeFocus ? Qt.alpha(root.pal.accent, 0.7) : root.pal.lineSoft
                                            TextInput {
                                                id: addNameIn
                                                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                                verticalAlignment: TextInput.AlignVCenter
                                                clip: true
                                                text: root.addName
                                                color: root.pal.text
                                                selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                onTextChanged: root.addName = text
                                                Keys.onEscapePressed: { root.addOpen = false; sin.forceActiveFocus() }
                                                Keys.onReturnPressed: root.addGame()
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: addNameIn.text.length === 0; text: "Name"; color: root.pal.muted; font: addNameIn.font }
                                            }
                                        }
                                        PrimaryBtn { label: "Add"; disabled: root.busy || root.addPath === ""; onClicked: root.addGame() }
                                        RoundBtn { pal: root.pal; size: 30; glyph: String.fromCodePoint(0xF0156); onClicked: { root.addOpen = false; sin.forceActiveFocus() } }
                                    }
                                }

                                // the grid: covers, the name over the bottom of the art
                                GridView {
                                    id: grid
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.shown.length > 0
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.shown
                                    readonly property int cols: Math.max(1, Math.floor(width / 172))
                                    cellWidth: Math.floor(width / cols)
                                    cellHeight: Math.round(cellWidth * 1.42)
                                    currentIndex: 0
                                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)
                                    function pick() {
                                        var g = root.shown[currentIndex]
                                        if (g) root.selId = g.id
                                    }

                                    delegate: Item {
                                        id: cell
                                        required property var modelData
                                        required property int index
                                        width: grid.cellWidth
                                        height: grid.cellHeight
                                        readonly property bool cur: root.selId === modelData.id
                                        readonly property bool playing: root.runningId === modelData.id
                                        readonly property bool hasArt: img.status === Image.Ready && !img.small

                                        ClippingRectangle {
                                            id: card
                                            anchors.fill: parent
                                            anchors.margins: 7
                                            radius: root.pal.rLg
                                            color: Qt.alpha(root.pal.surface, 0.9)
                                            scale: cardMa.pressed ? 0.97 : (cardMa.containsMouse ? 1.02 : 1)
                                            z: cardMa.containsMouse ? 2 : 0
                                            Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

                                            // no cover: a soft gradient with the first letter (an .exe icon sits small in the middle)
                                            Rectangle {
                                                anchors.fill: parent
                                                visible: !cell.hasArt
                                                gradient: Gradient {
                                                    GradientStop { position: 0; color: Qt.alpha(root.pal.accent, 0.22) }
                                                    GradientStop { position: 1; color: Qt.alpha(root.pal.accent2, 0.06) }
                                                }
                                            }
                                            Text {
                                                anchors.centerIn: parent
                                                anchors.verticalCenterOffset: -20
                                                visible: img.status !== Image.Ready
                                                text: (cell.modelData.name || "?").charAt(0).toUpperCase()
                                                color: Qt.alpha(root.pal.accent, 0.6)
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 58
                                                font.weight: Font.DemiBold
                                            }
                                            Image {
                                                id: img
                                                // an icon taken out of an .exe is small and square: show it whole instead of stretching it
                                                readonly property bool small: implicitWidth < 300 || implicitHeight < 150 || String(source).indexOf("/icons/") >= 0
                                                anchors.fill: parent
                                                anchors.margins: small ? 40 : 0
                                                anchors.bottomMargin: small ? 70 : 0
                                                source: cell.modelData.cover && cell.modelData.cover !== "" ? "file://" + cell.modelData.cover : ""
                                                sourceSize.width: 600
                                                sourceSize.height: 600
                                                fillMode: small ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                asynchronous: true
                                                cache: false
                                                opacity: status === Image.Ready ? 1 : 0
                                                Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }
                                            }
                                            // the name, over a shade at the bottom of the art
                                            Rectangle {
                                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                                height: 84
                                                gradient: Gradient {
                                                    GradientStop { position: 0; color: Qt.alpha(root.pal.bg, 0) }
                                                    GradientStop { position: 0.55; color: Qt.alpha(root.pal.bg, 0.78) }
                                                    GradientStop { position: 1; color: Qt.alpha(root.pal.bg, 0.94) }
                                                }
                                            }
                                            Column {
                                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 12; rightMargin: 12; bottomMargin: 10 }
                                                spacing: 1
                                                Text {
                                                    width: parent.width
                                                    elide: Text.ElideRight
                                                    text: cell.modelData.name
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                    font.weight: Font.DemiBold
                                                }
                                                Text {
                                                    width: parent.width
                                                    elide: Text.ElideRight
                                                    text: root.srcLabel(cell.modelData.source) + "  ·  " + root.fmtTime(cell.modelData.playtime)
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                            }
                                            // status: playing now / needs attention
                                            Rectangle {
                                                anchors { left: parent.left; top: parent.top; margins: 8 }
                                                visible: cell.playing || cell.modelData.status === "attention"
                                                height: 22
                                                width: stTxt.implicitWidth + 18
                                                radius: 11
                                                color: Qt.alpha(root.pal.bg, 0.85)
                                                border.width: 1
                                                border.color: cell.playing ? Qt.alpha(root.pal.accent, 0.6) : Qt.alpha(root.pal.warn, 0.6)
                                                Text {
                                                    id: stTxt
                                                    anchors.centerIn: parent
                                                    text: cell.playing ? "Playing" : "Needs attention"
                                                    color: cell.playing ? root.pal.accent : root.pal.warn
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: 10
                                                    font.weight: Font.DemiBold
                                                }
                                            }
                                            // hover: a play button in the corner
                                            Rectangle {
                                                anchors { right: parent.right; top: parent.top; margins: 8 }
                                                width: 34; height: 34; radius: 17
                                                visible: cardMa.containsMouse
                                                color: root.pal.accent
                                                Text {
                                                    anchors.centerIn: parent
                                                    anchors.horizontalCenterOffset: cell.playing ? 0 : 1
                                                    text: String.fromCodePoint(cell.playing ? 0xF04DB : 0xF040A)
                                                    color: root.pal.bg
                                                    font.family: root.pal.font
                                                    font.pixelSize: 17
                                                }
                                            }
                                            // the ring: accent on the selected game
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: card.radius
                                                color: "transparent"
                                                border.width: cell.cur ? 2 : 1
                                                border.color: cell.cur ? root.pal.accent : (cardMa.containsMouse ? Qt.alpha(root.pal.accent, 0.4) : root.pal.lineSoft)
                                                Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                                            }
                                            MouseArea {
                                                id: cardMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: m => {
                                                    grid.currentIndex = cell.index; root.selId = cell.modelData.id; sin.forceActiveFocus()
                                                    if (m.x > width - 46 && m.y < 46) root.playSel()        // the corner play button
                                                }
                                                onDoubleClicked: { grid.currentIndex = cell.index; root.selId = cell.modelData.id; root.playSel() }
                                            }
                                            // favourite: always shown when starred, on hover otherwise (favourites come first here and in >game)
                                            Rectangle {
                                                anchors { right: parent.right; top: parent.top; margins: 8; rightMargin: cardMa.containsMouse || favMa.containsMouse ? 48 : 8 }
                                                width: 30; height: 30; radius: 15
                                                visible: cell.modelData.fav || cardMa.containsMouse || favMa.containsMouse
                                                color: Qt.alpha(root.pal.bg, favMa.containsMouse ? 0.92 : 0.72)
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: String.fromCodePoint(cell.modelData.fav ? 0xF04CE : 0xF04D2)
                                                    color: cell.modelData.fav ? root.pal.accent : root.pal.text
                                                    font.family: root.pal.font
                                                    font.pixelSize: 15
                                                }
                                                MouseArea {
                                                    id: favMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.act([root.hgl, "set", cell.modelData.id, "fav", cell.modelData.fav ? "off" : "on"], "")
                                                }
                                            }
                                        }
                                    }
                                }

                                // nothing to show
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.shown.length === 0
                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 14
                                        width: Math.min(440, parent.width - 40)
                                        Rectangle {
                                            visible: root.gamesLoaded && root.games.length === 0
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 76; height: 76; radius: 24
                                            color: Qt.alpha(root.pal.accent, 0.12)
                                            border.width: 1
                                            border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.3)
                                            Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF0297); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 38 }
                                        }
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.Wrap
                                            text: !root.gamesLoaded ? "Reading your library" : (root.games.length === 0 ? "No games yet" : "No game matches that")
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tTitle + 3
                                            font.weight: Font.DemiBold
                                        }
                                        Text {
                                            visible: root.gamesLoaded && root.games.length === 0
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            wrapMode: Text.Wrap
                                            text: "Add a Windows game, or find your Steam and Flatpak games."
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                            lineHeight: 1.15
                                        }
                                        Row {
                                            visible: root.gamesLoaded && root.games.length === 0
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            spacing: 10
                                            PrimaryBtn { glyph: String.fromCodePoint(0xF0415); label: "Add a Windows game"; onClicked: root.browseExe() }
                                            ActionChip { pal: root.pal; implicitHeight: 38; glyph: String.fromCodePoint(0xF0450); label: "Find my games"; onClicked: root.refreshLibrary() }
                                        }
                                    }
                                }
                            }

                            // ---- the drawer: the selected game
                            ClippingRectangle {
                                id: drawer
                                Layout.preferredWidth: 360
                                Layout.fillHeight: true
                                visible: root.sel !== null
                                radius: root.pal.rLg
                                color: Qt.alpha(root.pal.surface, 0.55)

                                Flickable {
                                    id: dflick
                                    anchors.fill: parent
                                    clip: true
                                    contentWidth: width
                                    // dcol starts under the cover: without dcol.y the last rows (Wayland mode, Remove) could not be scrolled to
                                    contentHeight: dcol.y + dcol.implicitHeight + 18
                                    boundsBehavior: Flickable.StopAtBounds

                                    // the cover, faded into the drawer, with the name over it
                                    Rectangle {
                                        id: hero
                                        x: 0; y: 0
                                        width: dflick.width
                                        height: heroImg.visible ? 150 : 96         // no cover: just room for the name
                                        color: Qt.alpha(root.pal.accent, 0.10)
                                        Image {
                                            id: heroImg
                                            anchors.fill: parent
                                            source: root.sel && root.sel.cover && root.sel.cover !== "" ? "file://" + root.sel.cover : ""
                                            sourceSize.width: 720
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            cache: false
                                            visible: status === Image.Ready && implicitWidth >= 300 && String(source).indexOf("/icons/") < 0
                                        }
                                        Rectangle {
                                            anchors.fill: parent
                                            gradient: Gradient {
                                                GradientStop { position: 0; color: Qt.alpha(root.pal.bg, 0.05) }
                                                GradientStop { position: 0.6; color: Qt.alpha(root.pal.bg, 0.55) }
                                                GradientStop { position: 1; color: Qt.alpha(root.pal.surface, 1) }
                                            }
                                        }
                                        Column {
                                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 18; rightMargin: 18; bottomMargin: 8 }
                                            spacing: 2
                                            Text {
                                                width: parent.width
                                                elide: Text.ElideRight
                                                text: root.sel ? root.sel.name : ""
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tDisplay
                                                font.weight: Font.DemiBold
                                            }
                                            Text {
                                                width: parent.width
                                                wrapMode: Text.Wrap
                                                text: root.sel ? root.srcLabel(root.sel.source) + "  ·  " + root.fmtTime(root.sel.playtime) + "  ·  played " + root.fmtAgo(root.sel.lastPlayed) : ""
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                        }
                                    }

                                    Column {
                                        id: dcol
                                        x: 18
                                        y: hero.height + 6
                                        width: dflick.width - 36
                                        spacing: 16

                                        // what is happening with this game right now (after Play)
                                        Rectangle {
                                            id: launchCard
                                            readonly property bool here: root.sel !== null && root.launchId === root.sel.id && root.phase !== ""
                                            readonly property bool bad: root.phase === "ended" || root.phase === "failed"
                                            width: parent.width
                                            visible: here
                                            implicitHeight: lcCol.implicitHeight + 24
                                            radius: root.pal.rMd
                                            color: Qt.alpha(bad ? root.pal.warn : root.pal.accent, 0.10)
                                            border.width: 1
                                            border.color: Qt.alpha(bad ? root.pal.warn : root.pal.accent, 0.35)
                                            Column {
                                                id: lcCol
                                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                                spacing: 8
                                                Row {
                                                    width: parent.width
                                                    spacing: 10
                                                    Rectangle {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: 8; height: 8; radius: 4
                                                        color: launchCard.bad ? root.pal.warn : root.pal.accent
                                                        opacity: root.phase === "starting" ? 0.35 + 0.65 * Math.abs(Math.sin(lpulse.tp * Math.PI)) : 1
                                                        Item {
                                                            id: lpulse
                                                            property real tp: 0
                                                            NumberAnimation on tp { from: 0; to: 1; duration: 1100; loops: Animation.Infinite; running: root.phase === "starting" }
                                                        }
                                                    }
                                                    Text {
                                                        width: parent.width - 18
                                                        wrapMode: Text.Wrap
                                                        text: root.phase === "running" ? "Running" : root.phaseText
                                                        color: root.pal.text
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tBody
                                                        font.weight: Font.Medium
                                                    }
                                                }
                                                Text {
                                                    width: parent.width
                                                    visible: root.phase === "starting"
                                                    wrapMode: Text.Wrap
                                                    text: "This window steps aside when the game opens."
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                                Text {
                                                    width: parent.width
                                                    visible: launchCard.bad && root.launchLog !== ""
                                                    text: "What the log says last:"
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                                Rectangle {
                                                    width: parent.width
                                                    visible: launchCard.bad && root.launchLog !== ""
                                                    implicitHeight: llTxt.implicitHeight + 16
                                                    radius: root.pal.rSm
                                                    color: Qt.alpha(root.pal.bg, 0.6)
                                                    Text {
                                                        id: llTxt
                                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                                                        wrapMode: Text.WrapAnywhere
                                                        text: root.launchLog
                                                        color: root.pal.muted
                                                        font.family: root.pal.font
                                                        font.pixelSize: 10
                                                    }
                                                }
                                                Flow {
                                                    width: parent.width
                                                    spacing: 6
                                                    visible: launchCard.bad
                                                    ActionChip { pal: root.pal; implicitHeight: 30; label: "Full log"; onClicked: { root.advOpen = true; root.logOpen = true; root.loadLog() } }
                                                    ActionChip { pal: root.pal; implicitHeight: 30; label: "Dismiss"; onClicked: root.phase = "" }
                                                }
                                            }
                                        }
                                        PrimaryBtn {
                                            width: parent.width
                                            implicitHeight: 46
                                            readonly property bool starting: root.phase === "starting" && root.sel !== null && root.launchId === root.sel.id
                                            glyph: String.fromCodePoint(root.selRunning ? 0xF04DB : 0xF040A)
                                            label: root.selRunning ? "Stop" : (starting ? "Starting\u2026" : ((root.phase === "ended" || root.phase === "failed") && root.sel && root.launchId === root.sel.id ? "Try again" : "Play"))
                                            danger: root.selRunning
                                            disabled: starting && !root.selRunning
                                            onClicked: root.playSel()
                                        }
                                        // a known problem with this game (fixes.db)
                                        Rectangle {
                                            width: parent.width
                                            visible: root.sel !== null && (root.sel.known || "") !== ""
                                            implicitHeight: knownTxt.implicitHeight + 20
                                            radius: root.pal.rMd
                                            color: Qt.alpha(root.pal.accent, 0.08)
                                            border.width: 1
                                            border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                                            Text {
                                                id: knownTxt
                                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 12 }
                                                wrapMode: Text.Wrap
                                                text: root.sel ? (root.sel.known || "") : ""
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                        }
                                        // why it is not ready
                                        Rectangle {
                                            width: parent.width
                                            visible: root.sel !== null && root.sel.status === "attention"
                                            implicitHeight: attTxt.implicitHeight + 20
                                            radius: root.pal.rMd
                                            color: Qt.alpha(root.pal.warn, 0.10)
                                            border.width: 1
                                            border.color: Qt.alpha(root.pal.warn, 0.35)
                                            Text {
                                                id: attTxt
                                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 12 }
                                                wrapMode: Text.Wrap
                                                text: root.sel ? (root.sel.statusReason || "Needs attention") + (attMa.enabled ? "  " + String.fromCodePoint(0xF0142) : "") : ""
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap + 1
                                            }
                                            // "... (Doctor)" / "... (Runtimes)": a click opens that tab
                                            MouseArea {
                                                id: attMa
                                                readonly property string to: !root.sel ? "" : (/Doctor/.test(root.sel.statusReason || "") ? "doctor" : (/Runtimes|Proton/.test(root.sel.statusReason || "") ? "runtimes" : ""))
                                                anchors.fill: parent
                                                enabled: to !== ""
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.setTab(to)
                                            }
                                        }
                                        // what the crash check found (it runs by itself when the last exit was not clean)
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            visible: root.triaged && root.findings.length === 0
                                            text: "No known problem in the newest log."
                                            color: root.pal.good
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap + 1
                                        }
                                        Repeater {
                                            model: root.findings
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: parent.width
                                                implicitHeight: fcol.implicitHeight + 20
                                                radius: root.pal.rMd
                                                color: Qt.alpha(root.pal.warn, 0.10)
                                                border.width: 1
                                                border.color: Qt.alpha(root.pal.warn, 0.35)
                                                Column {
                                                    id: fcol
                                                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                                                    spacing: 6
                                                    Text { width: parent.width; wrapMode: Text.Wrap; text: modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                    Text { width: parent.width; wrapMode: Text.Wrap; text: modelData.detail; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                    ActionChip {
                                                        visible: modelData.fix !== "hint"
                                                        pal: root.pal
                                                        implicitHeight: 30
                                                        label: modelData.fixLabel !== "" ? "Fix it: " + modelData.fixLabel : "Fix it"
                                                        maxLabel: 280
                                                        disabled: root.busy
                                                        onClicked: root.fixFinding(modelData)
                                                    }
                                                }
                                            }
                                        }
                                        // the last session, when it was this game
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            visible: root.sel !== null && root.lastSession !== null && root.lastSession.id === root.sel.id
                                            text: root.lastSession ? "Last session " + root.fmtTime(root.lastSession.playedSecs) + ". Halcyon used " + Number(root.lastSession.haCpuAvg).toFixed(1) + "% of one core and " + Math.round(root.lastSession.haRamAvgMB) + " MB of memory meanwhile." : ""
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap + 1
                                        }

                                        // ---- suggested for this PC: its class (hgl class), what hgl would change, what to set in the game
                                        Rectangle {
                                            width: parent.width
                                            visible: root.suggestion !== null
                                            implicitHeight: sugCol.implicitHeight + 24
                                            radius: root.pal.rMd
                                            color: Qt.alpha(root.pal.accent, 0.07)
                                            border.width: 1
                                            border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.25)
                                            Column {
                                                id: sugCol
                                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                                spacing: 10
                                                Item {
                                                    width: parent.width
                                                    height: 26
                                                    SectionTitle { anchors.verticalCenter: parent.verticalCenter; text: "For your PC" }
                                                    Rectangle {
                                                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                        height: 24
                                                        width: clsTxt.implicitWidth + 18
                                                        radius: 12
                                                        color: Qt.alpha(root.pal.accent, 0.18)
                                                        Text {
                                                            id: clsTxt
                                                            anchors.centerIn: parent
                                                            text: root.suggestion ? "Class " + root.suggestion.machine["class"] + "  ·  " + root.suggestion.machine.label : ""
                                                            color: root.pal.accent
                                                            font.family: root.pal.uiFont
                                                            font.pixelSize: root.pal.tCap
                                                            font.weight: Font.DemiBold
                                                        }
                                                    }
                                                }
                                                Text {
                                                    width: parent.width
                                                    wrapMode: Text.Wrap
                                                    text: root.suggestion ? (root.suggestion.machine.why || []).join(" · ") : ""
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                                Repeater {
                                                    model: root.sugRows
                                                    delegate: Column {
                                                        required property var modelData
                                                        width: parent.width
                                                        spacing: 1
                                                        Text { width: parent.width; wrapMode: Text.Wrap; text: modelData.t; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                        Text { width: parent.width; wrapMode: Text.Wrap; text: modelData.d; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                    }
                                                }
                                                // which Proton (hgl suggest: GE-Proton by default; installing is a download, so it is its own button)
                                                Column {
                                                    width: parent.width
                                                    spacing: 6
                                                    visible: root.suggestion !== null && root.suggestion.proton !== null && root.suggestion.proton !== undefined
                                                    readonly property var tip: visible ? root.suggestion.proton : ({})
                                                    Text { width: parent.width; wrapMode: Text.Wrap; text: parent.tip.action === "install" ? "Proton" : "Proton \u2713"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                    Text { width: parent.width; wrapMode: Text.Wrap; text: parent.tip.why || ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                    ActionChip {
                                                        visible: parent.tip.action === "install"
                                                        pal: root.pal
                                                        implicitHeight: 30
                                                        glyph: String.fromCodePoint(0xF01DA)
                                                        label: parent.tip.family === "cachyos" ? "Install Proton-CachyOS" : "Install GE-Proton"
                                                        disabled: root.busy
                                                        onClicked: root.act([root.hgl, "proton", "install", "latest", "--family", parent.tip.family], "Proton installed")
                                                    }
                                                    Text { width: parent.width; wrapMode: Text.Wrap; visible: (parent.tip.alt || "") !== ""; text: parent.tip.alt || ""; color: Qt.alpha(root.pal.muted, 0.8); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                }
                                                PrimaryBtn {
                                                    visible: root.sugRows.length > 0
                                                    implicitHeight: 34
                                                    glyph: String.fromCodePoint(0xF012C)
                                                    label: root.sugRows.length === 1 ? "Apply it" : "Apply these " + root.sugRows.length
                                                    disabled: root.busy || root.selRunning
                                                    onClicked: root.applySuggest()
                                                }
                                                Text {
                                                    visible: root.sugRows.length === 0
                                                    width: parent.width
                                                    wrapMode: Text.Wrap
                                                    text: "\u2713  Halcyon's side is already set up for this PC."
                                                    color: root.pal.good
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap + 1
                                                }
                                                // in-game settings: hgl cannot reach the game's own menu, so they are listed to set once
                                                Rectangle {
                                                    width: parent.width
                                                    height: 30
                                                    radius: root.pal.rSm
                                                    color: tipsMa.containsMouse ? Qt.alpha(root.pal.text, 0.05) : "transparent"
                                                    Text {
                                                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                                                        text: "In the game's settings"
                                                        color: root.pal.text
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tCap + 1
                                                        font.weight: Font.Medium
                                                    }
                                                    Text {
                                                        anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                                                        text: String.fromCodePoint(root.tipsOpen ? 0xF0143 : 0xF0140)
                                                        color: root.pal.muted
                                                        font.family: root.pal.font
                                                        font.pixelSize: 14
                                                    }
                                                    MouseArea { id: tipsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tipsOpen = !root.tipsOpen }
                                                }
                                                Repeater {
                                                    model: root.tipsOpen && root.suggestion ? root.suggestion.inGame : []
                                                    delegate: Text {
                                                        required property var modelData
                                                        width: parent.width
                                                        wrapMode: Text.Wrap
                                                        text: "\u2022  " + modelData
                                                        color: root.pal.muted
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tCap + 1
                                                        lineHeight: 1.1
                                                    }
                                                }
                                            }
                                        }

                                        // ---- runs with: Proton and gamescope (Steam sets these itself)
                                        Column {
                                            width: parent.width
                                            spacing: 8
                                            visible: root.isWine(root.sel)
                                            SectionTitle { text: "Runs with" }
                                            Rectangle {
                                                width: parent.width
                                                height: 38
                                                radius: root.pal.rSm
                                                color: protonMa.containsMouse ? Qt.alpha(root.pal.bg, 0.7) : Qt.alpha(root.pal.bg, 0.5)
                                                border.width: 1
                                                border.color: root.protonOpen ? root.pal.accent : root.pal.lineSoft
                                                Text {
                                                    id: protonLbl
                                                    anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
                                                    text: "Proton"
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap + 1
                                                }
                                                Text {
                                                    anchors { left: protonLbl.right; right: chev.left; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 8 }
                                                    horizontalAlignment: Text.AlignRight
                                                    elide: Text.ElideRight
                                                    text: !root.sel ? "" : (root.sel.proton !== "" ? root.sel.proton : "Default" + (root.defaultRuntime ? " (" + root.defaultRuntime.name + ")" : " (none installed)"))
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                }
                                                Text {
                                                    id: chev
                                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 12 }
                                                    text: String.fromCodePoint(root.protonOpen ? 0xF0143 : 0xF0140)
                                                    color: root.pal.muted
                                                    font.family: root.pal.font
                                                    font.pixelSize: 14
                                                }
                                                MouseArea { id: protonMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.protonOpen = !root.protonOpen }
                                            }
                                            Column {
                                                width: parent.width
                                                spacing: 2
                                                visible: root.protonOpen
                                                Repeater {
                                                    model: [{ name: "", label: "Default" }].concat(root.runtimes.map(function (r) { return { name: r.name, label: r.name } }))
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width
                                                        height: 32
                                                        radius: root.pal.rSm
                                                        color: optMa.containsMouse ? Qt.alpha(root.pal.accent, 0.14) : "transparent"
                                                        Text {
                                                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                                                            elide: Text.ElideRight
                                                            text: modelData.label + (root.sel && root.sel.proton === modelData.name ? "   ✓" : "")
                                                            color: root.pal.text
                                                            font.family: root.pal.uiFont
                                                            font.pixelSize: root.pal.tBody
                                                        }
                                                        MouseArea {
                                                            id: optMa
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: { root.protonOpen = false; root.setKey("proton", modelData.name) }
                                                        }
                                                    }
                                                }
                                                Text {
                                                    visible: root.runtimes.length === 0
                                                    width: parent.width
                                                    wrapMode: Text.Wrap
                                                    text: "No Proton installed yet. Open the Proton tab and install one."
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap + 1
                                                }
                                            }
                                            Text { text: "Gamescope"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; topPadding: 4 }
                                            Flow {
                                                width: parent.width
                                                spacing: 6
                                                Repeater {
                                                    model: root.scopes
                                                    delegate: Chip {
                                                        required property var modelData
                                                        pal: root.pal
                                                        implicitHeight: 30
                                                        padX: 12
                                                        label: modelData.t
                                                        on: root.sel !== null && root.sel.gamescope === modelData.v
                                                        onClicked: root.setKey("gamescope", modelData.v)
                                                    }
                                                }
                                            }
                                            Text {
                                                visible: root.sel !== null && root.presetValues.indexOf(root.sel.gamescope) < 0
                                                width: parent.width
                                                wrapMode: Text.Wrap
                                                text: root.sel ? "Custom options: " + root.sel.gamescope : ""
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap
                                            }
                                        }

                                        // ---- while playing: wrappers and modes
                                        Column {
                                            width: parent.width
                                            spacing: 12
                                            SectionTitle { text: "While playing" }
                                            Repeater {
                                                model: root.toggleDefs
                                                delegate: RowLayout {
                                                    required property var modelData
                                                    // Wayland mode and the wrappers apply to games Halcyon starts itself, not to Steam's own launch
                                                    visible: root.isWine(root.sel) || modelData.k === "lean"
                                                    width: parent.width
                                                    height: visible ? implicitHeight : 0
                                                    spacing: 10
                                                    Column {
                                                        Layout.fillWidth: true
                                                        spacing: 1
                                                        Text { text: modelData.t; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                        Hint { pal: root.pal; width: parent.width; text: modelData.d }
                                                    }
                                                    Toggle { pal: root.pal; on: root.toggleOn(modelData); busy: root.busy; onToggled: root.flip(modelData) }
                                                }
                                            }
                                        }

                                        // ---- advanced: folded away, it is rarely needed
                                        Rectangle {
                                            width: parent.width
                                            height: 36
                                            radius: root.pal.rSm
                                            color: advMa.containsMouse ? Qt.alpha(root.pal.text, 0.05) : "transparent"
                                            SectionTitle { anchors { left: parent.left; verticalCenter: parent.verticalCenter } text: "Advanced" }
                                            Text {
                                                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                                text: String.fromCodePoint(root.advOpen ? 0xF0143 : 0xF0140)
                                                color: root.pal.muted
                                                font.family: root.pal.font
                                                font.pixelSize: 14
                                            }
                                            MouseArea { id: advMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.advOpen = !root.advOpen }
                                        }
                                        Column {
                                            width: parent.width
                                            spacing: 16
                                            visible: root.advOpen

                                            // launch options
                                            Column {
                                                width: parent.width
                                                spacing: 6
                                                Text { text: "Launch options"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                Rectangle {
                                                    width: parent.width
                                                    height: 36
                                                    radius: root.pal.rSm
                                                    color: Qt.alpha(root.pal.bg, 0.55)
                                                    border.width: 1
                                                    border.color: argsIn.activeFocus ? root.pal.accent : root.pal.lineSoft
                                                    TextInput {
                                                        id: argsIn
                                                        anchors.fill: parent
                                                        anchors.leftMargin: 12
                                                        anchors.rightMargin: 12
                                                        verticalAlignment: TextInput.AlignVCenter
                                                        clip: true
                                                        color: root.pal.text
                                                        selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tBody
                                                        Keys.onEscapePressed: { argsIn.text = root.sel ? root.sel.args : ""; sin.forceActiveFocus() }
                                                        Keys.onReturnPressed: { if (root.sel && argsIn.text !== root.sel.args) root.setKey("args", argsIn.text, "Saved"); sin.forceActiveFocus() }
                                                        onActiveFocusChanged: if (!activeFocus && root.sel && text !== root.sel.args) root.setKey("args", text, "Saved")
                                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: argsIn.text.length === 0; text: "-windowed -nointro"; color: root.pal.muted; font: argsIn.font }
                                                    }
                                                }
                                            }

                                            // environment variables
                                            Column {
                                                width: parent.width
                                                spacing: 6
                                                visible: root.sel !== null && root.sel.source !== "steam"
                                                Text { text: "Environment variables"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                Repeater {
                                                    model: root.sel ? Object.keys(root.sel.env || {}) : []
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width
                                                        height: 30
                                                        radius: root.pal.rSm
                                                        color: Qt.alpha(root.pal.bg, 0.4)
                                                        Text {
                                                            anchors { left: parent.left; right: rm.left; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 6 }
                                                            elide: Text.ElideRight
                                                            text: modelData + "=" + (root.sel ? root.sel.env[modelData] : "")
                                                            color: root.pal.text
                                                            font.family: root.pal.font
                                                            font.pixelSize: root.pal.tCap + 1
                                                        }
                                                        RoundBtn { id: rm; anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 3 } pal: root.pal; size: 24; glyph: String.fromCodePoint(0xF0156); onClicked: root.setKey("env." + modelData, "") }
                                                    }
                                                }
                                                RowLayout {
                                                    width: parent.width
                                                    spacing: 6
                                                    Rectangle {
                                                        Layout.preferredWidth: 110
                                                        Layout.preferredHeight: 32
                                                        radius: root.pal.rSm
                                                        color: Qt.alpha(root.pal.bg, 0.55)
                                                        border.width: 1
                                                        border.color: envName.activeFocus ? root.pal.accent : root.pal.lineSoft
                                                        TextInput {
                                                            id: envName
                                                            anchors.fill: parent
                                                            anchors.leftMargin: 10
                                                            anchors.rightMargin: 10
                                                            verticalAlignment: TextInput.AlignVCenter
                                                            clip: true
                                                            color: root.pal.text
                                                            font.family: root.pal.font
                                                            font.pixelSize: root.pal.tCap + 1
                                                            Keys.onEscapePressed: sin.forceActiveFocus()
                                                            Keys.onReturnPressed: envVal.forceActiveFocus()
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: envName.text.length === 0; text: "NAME"; color: root.pal.muted; font: envName.font }
                                                        }
                                                    }
                                                    Rectangle {
                                                        Layout.fillWidth: true
                                                        Layout.preferredHeight: 32
                                                        radius: root.pal.rSm
                                                        color: Qt.alpha(root.pal.bg, 0.55)
                                                        border.width: 1
                                                        border.color: envVal.activeFocus ? root.pal.accent : root.pal.lineSoft
                                                        TextInput {
                                                            id: envVal
                                                            anchors.fill: parent
                                                            anchors.leftMargin: 10
                                                            anchors.rightMargin: 10
                                                            verticalAlignment: TextInput.AlignVCenter
                                                            clip: true
                                                            color: root.pal.text
                                                            font.family: root.pal.font
                                                            font.pixelSize: root.pal.tCap + 1
                                                            Keys.onEscapePressed: sin.forceActiveFocus()
                                                            Keys.onReturnPressed: { if (envName.text.trim() !== "") { root.setKey("env." + envName.text.trim(), envVal.text); envName.text = ""; envVal.text = "" } }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: envVal.text.length === 0; text: "value"; color: root.pal.muted; font: envVal.font }
                                                        }
                                                    }
                                                    ActionChip {
                                                        pal: root.pal
                                                        implicitHeight: 32
                                                        label: "Add"
                                                        disabled: envName.text.trim() === ""
                                                        onClicked: { root.setKey("env." + envName.text.trim(), envVal.text); envName.text = ""; envVal.text = "" }
                                                    }
                                                }
                                            }

                                            // prefix tools, logs, crash check
                                            Column {
                                                width: parent.width
                                                spacing: 8
                                                Text { text: "Tools"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                                Flow {
                                                    width: parent.width
                                                    spacing: 6
                                                    ActionChip { pal: root.pal; implicitHeight: 32; visible: root.isWine(root.sel); label: "Prefix folder"; onClicked: root.prefixFolder() }
                                                    ActionChip { pal: root.pal; implicitHeight: 32; visible: root.isWine(root.sel); label: "Wine settings"; onClicked: root.wineSettings() }
                                                    ActionChip { pal: root.pal; implicitHeight: 32; label: root.logOpen ? "Hide log" : "Show log"; onClicked: { root.logOpen = !root.logOpen; if (root.logOpen) root.loadLog() } }
                                                    ActionChip { pal: root.pal; implicitHeight: 32; label: "Check last run"; onClicked: root.loadTriage() }
                                                }
                                                Rectangle {
                                                    width: parent.width
                                                    height: 170
                                                    visible: root.logOpen
                                                    radius: root.pal.rSm
                                                    color: Qt.alpha(root.pal.bg, 0.6)
                                                    border.width: root.pal.calm ? 0 : 1
                                                    border.color: root.pal.lineSoft
                                                    Flickable {
                                                        id: logFlick
                                                        anchors.fill: parent
                                                        anchors.margins: 8
                                                        clip: true
                                                        contentWidth: width
                                                        contentHeight: logTxt.implicitHeight
                                                        boundsBehavior: Flickable.StopAtBounds
                                                        onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
                                                        Text {
                                                            id: logTxt
                                                            width: logFlick.width
                                                            wrapMode: Text.WrapAnywhere
                                                            text: root.logText !== "" ? root.logText : "No log yet. The newest one shows here after the game has run."
                                                            color: root.pal.muted
                                                            font.family: root.pal.font
                                                            font.pixelSize: 10
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // remove: always at the bottom of the drawer, not folded into Advanced (two clicks; the game's files stay)
                                        ActionChip {
                                            pal: root.pal
                                            implicitHeight: 32
                                            label: root.confirmRemove ? "Click again to remove" : "Remove from library"
                                            on: root.confirmRemove
                                            disabled: root.selRunning
                                            onClicked: {
                                                if (!root.confirmRemove) { root.confirmRemove = true; removeT.restart(); return }
                                                root.confirmRemove = false
                                                if (root.sel) root.act([root.hgl, "remove", root.sel.id], "Removed from the library")
                                            }
                                        }
                                        Timer { id: removeT; interval: 4000; onTriggered: root.confirmRemove = false }
                                    }
                                }
                                // where you are in the drawer: shows only when it is taller than the window
                                Rectangle {
                                    visible: dflick.contentHeight > dflick.height + 1
                                    x: parent.width - 6
                                    y: 8 + dflick.visibleArea.yPosition * (parent.height - 16)
                                    width: 3
                                    height: Math.max(24, dflick.visibleArea.heightRatio * (parent.height - 16))
                                    radius: 1.5
                                    color: Qt.alpha(root.pal.text, dflick.moving ? 0.35 : 0.16)
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                Rectangle { anchors.fill: parent; radius: drawer.radius; color: "transparent"; border.width: 1; border.color: root.pal.lineSoft }
                            }
                        }

                        // ================= Runtimes
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "runtimes"
                            spacing: 12

                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: "Proton runs Windows games. The newest three of each kind are kept."
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                ActionChip { pal: root.pal; label: "Install GE-Proton"; disabled: root.busy; onClicked: root.act([root.hgl, "proton", "install", "latest"], "GE-Proton installed") }
                                ActionChip { pal: root.pal; label: "Install Proton-CachyOS"; disabled: root.busy; onClicked: root.act([root.hgl, "proton", "install", "latest", "--family", "cachyos"], "Proton-CachyOS installed") }
                                ActionChip { pal: root.pal; label: "Roll back the default"; disabled: root.busy || root.runtimes.length < 2; onClicked: root.act([root.hgl, "proton", "rollback"], "Default rolled back") }
                                ActionChip { pal: root.pal; label: "Remove old versions"; disabled: root.busy; onClicked: root.act([root.hgl, "proton", "prune"], "Old versions removed") }
                                Chip {
                                    pal: root.pal
                                    implicitHeight: 36
                                    label: "Show in Steam"
                                    on: root.steamLink
                                    onClicked: root.act(root.steamLink ? [root.hgl, "proton", "link-steam", "--off"] : [root.hgl, "proton", "link-steam"], root.steamLink ? "Removed from Steam" : "Linked. Restart Steam to see them")
                                }
                            }
                            ListView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 6
                                boundsBehavior: Flickable.StopAtBounds
                                model: root.runtimes
                                delegate: Rectangle {
                                    id: rrow
                                    required property var modelData
                                    width: ListView.view.width
                                    height: 54
                                    radius: root.pal.rMd
                                    color: Qt.alpha(root.pal.surface, 0.7)
                                    border.width: 1
                                    border.color: modelData["default"] ? Qt.alpha(root.pal.accent, 0.45) : root.pal.lineSoft
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 16; rightMargin: 12 }
                                        spacing: 10
                                        Column {
                                            Layout.fillWidth: true
                                            spacing: 1
                                            Text { width: parent.width; elide: Text.ElideRight; text: rrow.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                            Text {
                                                width: parent.width
                                                elide: Text.ElideRight
                                                text: rrow.modelData.family + (rrow.modelData["default"] ? "  ·  default for new games" : "") + (rrow.modelData.pinned ? "  ·  a game is pinned to it" : "")
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap
                                            }
                                        }
                                        ActionChip { pal: root.pal; implicitHeight: 30; label: "Make default"; visible: !rrow.modelData["default"]; disabled: root.busy; onClicked: root.act([root.hgl, "proton", "default", rrow.modelData.name], "Default: " + rrow.modelData.name) }
                                        ActionChip { pal: root.pal; implicitHeight: 30; label: "Remove"; visible: !rrow.modelData["default"] && !rrow.modelData.pinned; disabled: root.busy; onClicked: root.act([root.hgl, "proton", "remove", rrow.modelData.name], "Removed " + rrow.modelData.name) }
                                    }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: root.runtimes.length === 0
                                    text: "No Proton installed yet. Install GE-Proton above."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                }
                            }
                        }

                        // ================= Stores
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "stores"
                            spacing: 12

                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: "Epic needs legendary, GOG needs gogdl (see Doctor). Installs run in the console."
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                ActionChip { pal: root.pal; label: "Get cover art"; disabled: root.busy; onClicked: root.act([root.hgl, "art"], "Cover art updated") }
                                Text {
                                    height: 36
                                    verticalAlignment: Text.AlignVCenter
                                    text: "Art for .exe games needs a SteamGridDB key: hgl config steamgriddb_key <key>"
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 14

                                // ---- Epic
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: root.pal.rLg
                                    color: Qt.alpha(root.pal.surface, 0.55)
                                    border.width: root.pal.calm ? 0 : 1
                                    border.color: root.pal.lineSoft
                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 14
                                        spacing: 10
                                        Text { text: "Epic Games"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                                        Text {
                                            Layout.fillWidth: true
                                            wrapMode: Text.Wrap
                                            text: !root.epicSt.installed ? "legendary is not installed" : (root.epicSt.loggedIn ? "Logged in as " + root.epicSt.account : "Not logged in")
                                            color: root.epicSt.loggedIn ? root.pal.good : root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                        }
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "Log in"; visible: root.epicSt.installed && !root.epicSt.loggedIn; onClicked: root.runInConsole(root.hgl + " epic login") }
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "Log out"; visible: root.epicSt.loggedIn; disabled: root.busy; onClicked: root.act([root.hgl, "epic", "logout"], "Logged out of Epic", false) }
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "My library"; visible: root.epicSt.loggedIn; disabled: root.storeBusy; onClicked: root.loadEpicList() }
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "Read installed"; visible: root.epicSt.installed; disabled: root.busy; onClicked: root.act([root.hgl, "import", "epic"], "Epic games read") }
                                        }
                                        ListView {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            clip: true
                                            spacing: 6
                                            boundsBehavior: Flickable.StopAtBounds
                                            model: root.epicList
                                            delegate: Rectangle {
                                                id: erow
                                                required property var modelData
                                                width: ListView.view.width
                                                height: 44
                                                radius: root.pal.rMd
                                                color: Qt.alpha(root.pal.bg, 0.45)
                                                RowLayout {
                                                    anchors { fill: parent; leftMargin: 12; rightMargin: 10 }
                                                    spacing: 8
                                                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: erow.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                                    Text { visible: erow.modelData.installed; text: "installed"; color: root.pal.good; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                    ActionChip { pal: root.pal; implicitHeight: 28; label: "Install"; visible: !erow.modelData.installed; onClicked: root.runInConsole(root.hgl + " epic install " + root.q(erow.modelData.app)) }
                                                }
                                            }
                                            Text {
                                                anchors.centerIn: parent
                                                visible: root.epicList.length === 0
                                                text: root.epicListed ? "Nothing in your Epic library" : (root.epicSt.loggedIn ? "Press My library to read what you own" : "")
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                            }
                                        }
                                    }
                                }

                                // ---- GOG
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: root.pal.rLg
                                    color: Qt.alpha(root.pal.surface, 0.55)
                                    border.width: root.pal.calm ? 0 : 1
                                    border.color: root.pal.lineSoft
                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 14
                                        spacing: 10
                                        Text { text: "GOG"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                                        Text {
                                            Layout.fillWidth: true
                                            wrapMode: Text.Wrap
                                            text: !root.gogSt.installed ? "gogdl is not installed (games you installed some other way can still be read)" : (root.gogSt.loggedIn ? "Logged in" : "Not logged in: open the sign-in page, then paste the address you land on")
                                            color: root.gogSt.loggedIn ? root.pal.good : root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                        }
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "Open sign-in page"; visible: root.gogSt.installed && !root.gogSt.loggedIn; onClicked: Quickshell.execDetached(["xdg-open", root.gogSt.url]) }
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "My library"; visible: root.gogSt.loggedIn; disabled: root.storeBusy; onClicked: root.loadGogList() }
                                            ActionChip { pal: root.pal; implicitHeight: 32; label: "Read installed"; disabled: root.busy; onClicked: root.act([root.hgl, "import", "gog"], "GOG games read") }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            visible: root.gogSt.installed && !root.gogSt.loggedIn
                                            spacing: 8
                                            Rectangle {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: 34
                                                radius: root.pal.rSm
                                                color: Qt.alpha(root.pal.bg, 0.55)
                                                border.width: 1
                                                border.color: gogIn.activeFocus ? root.pal.accent : root.pal.lineSoft
                                                TextInput {
                                                    id: gogIn
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 12
                                                    anchors.rightMargin: 12
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    clip: true
                                                    text: root.gogAddr
                                                    color: root.pal.text
                                                    selectionColor: Qt.alpha(root.pal.accent, 0.45)
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                    onTextChanged: root.gogAddr = text
                                                    Keys.onReturnPressed: root.gogLogin()
                                                    Keys.onEscapePressed: root.hide()
                                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: gogIn.text.length === 0; text: "Paste the address (it contains code=)"; color: root.pal.muted; font: gogIn.font }
                                                }
                                            }
                                            ActionChip { pal: root.pal; implicitHeight: 34; label: "Log in"; disabled: root.busy; onClicked: root.gogLogin() }
                                        }
                                        ListView {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            clip: true
                                            spacing: 6
                                            boundsBehavior: Flickable.StopAtBounds
                                            model: root.gogList
                                            delegate: Rectangle {
                                                id: grow
                                                required property var modelData
                                                width: ListView.view.width
                                                height: 44
                                                radius: root.pal.rMd
                                                color: Qt.alpha(root.pal.bg, 0.45)
                                                RowLayout {
                                                    anchors { fill: parent; leftMargin: 12; rightMargin: 10 }
                                                    spacing: 8
                                                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: grow.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                                    Text { visible: grow.modelData.installed; text: "installed"; color: root.pal.good; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                    ActionChip { pal: root.pal; implicitHeight: 28; label: "Install"; visible: !grow.modelData.installed && root.gogSt.installed; onClicked: root.runInConsole(root.hgl + " gog install " + root.q(grow.modelData.id) + " --title " + root.q(grow.modelData.title)) }
                                                }
                                            }
                                            Text {
                                                anchors.centerIn: parent
                                                visible: root.gogList.length === 0
                                                text: root.gogListed ? "Nothing in your GOG library" : (root.gogSt.loggedIn ? "Press My library to read what you own" : "")
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ================= Doctor
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "doctor"
                            spacing: 12

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    text: "What games need. Fixing opens the console (it asks for your password)."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                }
                                ActionChip { pal: root.pal; label: "Check again"; onClicked: root.loadChecks() }
                                ActionChip { pal: root.pal; label: "Fix what is missing"; onClicked: root.runInConsole(root.hgl + " doctor --fix") }
                            }
                            ListView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 6
                                boundsBehavior: Flickable.StopAtBounds
                                model: root.checks
                                delegate: Rectangle {
                                    id: crow
                                    required property var modelData
                                    width: ListView.view.width
                                    implicitHeight: ccol.implicitHeight + 20
                                    height: implicitHeight
                                    radius: root.pal.rMd
                                    color: Qt.alpha(root.pal.surface, 0.7)
                                    border.width: root.pal.calm ? 0 : 1
                                    border.color: root.pal.lineSoft
                                    Rectangle {
                                        id: cdot
                                        anchors { left: parent.left; top: parent.top; leftMargin: 16; topMargin: 17 }
                                        width: 9; height: 9; radius: 5
                                        color: crow.modelData.level === "ok" ? root.pal.good : (crow.modelData.level === "warn" ? root.pal.warn : root.pal.bad)
                                    }
                                    Column {
                                        id: ccol
                                        anchors { left: cdot.right; right: parent.right; top: parent.top; leftMargin: 12; rightMargin: 16; topMargin: 10 }
                                        spacing: 2
                                        Text {
                                            width: parent.width
                                            text: crow.modelData.label + (crow.modelData.optional && !/optional/i.test(crow.modelData.label) ? "  (optional)" : "")
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                            font.weight: Font.Medium
                                        }
                                        Text { width: parent.width; wrapMode: Text.Wrap; text: crow.modelData.detail; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            visible: crow.modelData.manual !== null && crow.modelData.manual !== undefined && crow.modelData.level !== "ok"
                                            text: crow.modelData.manual ? "By hand: " + crow.modelData.manual : ""
                                            color: root.pal.warn
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap + 1
                                        }
                                    }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: root.checks.length === 0
                                    text: root.checksLoaded ? "Nothing to report." : "Checking your system"
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                }
                            }
                        }
                    }
                }

                // Add game: the .exe browser, over the window (ExePicker.qml)
                ExePicker {
                    id: picker
                    anchors.fill: parent
                    pal: root.pal
                    onPicked: path => root.exePicked(path)
                    onCancelled: { root.pickerOpen = false; sin.forceActiveFocus() }
                }
                Connections {
                    target: root
                    function onPickerOpenChanged() { if (!root.pickerOpen) picker.open = false }
                }
            }
        }
    }
}
