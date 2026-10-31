import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "DeskSpots.js" as DS
import "BarLayout.js" as BL

// Rice settings: one centred window, blurred backdrop, "node" cards in the same look as the SUPER+TAB tree.
// Everything here is applied live and remembered (settings.json); Hyprland values are re-applied when the island starts.
//   Esc or a click outside closes it.   Open: gear in the utilities panel, `>settings`, SUPER+I.
Scope {
    id: root
    readonly property var settingsScope: root
    property var pal
    property string sysmode: ""
    property bool open: false
    // the window stays a moment after it closes, so its fade-out plays (it used to vanish at once)
    property bool linger: false
    Connections { target: root; function onOpenChanged() { if (!root.open) { root.linger = true; lingerT.restart() } } }
    Timer { id: lingerT; interval: (root.pal ? root.pal.dMed : 300) + 80; onTriggered: root.linger = false }
    property bool consoleOpen: false
    // the island's own picture picker over the Settings window (SetProfile's Browse): browseImage(start, function (path) {})
    property bool imgPickOpen: false
    property string imgPickStart: ""
    property var imgPickCb: null
    function browseImage(start, cb) { imgPickStart = start; imgPickCb = cb; imgPickOpen = true }

    // state (owned by shell.qml)
    property bool autoHide: false
    property bool clickMode: false
    property bool dnd: false
    property bool gaming: false
    property bool profileStars: true
    property var starData: null
    property real glassShift: 0
    property real motion: 1
    property int rounding: 18
    property int gaps: 8
    property bool blur: true
    property bool shadows: true
    property bool hyprAnim: true
    property int notifHistoryMax: 30
    property int notifMax: 5
    property bool compactSpecial: true
    property bool routeApps: true
    property bool routeShow: false
    property bool clock24: false
    property bool growthOn: true
    property double growthMin: 0
    property bool superTap: true
    property bool termFollow: true
    property real colorBoost: 1.0
    property real growthFullMin: 4320
    readonly property real growth: Math.min(1, growthMin / growthFullMin)
    property int idleLock: 5
    property int idleSleep: 30
    property int idleDim: 3
    property bool osdOn: true
    property string theme: "dark"          // dark | light
    property bool compactWs: true          // windows on workspace 3 move to 1 when nothing is before them
    property string hoverAction: "none"    // what hovering the bar does: none | perf | media | stats
    property string barScroll: "medium"    // how far you scroll / swipe on the bar to change page: low | medium | high
    property real scrollTouch: 0.3         // Hyprland touchpad scroll_factor
    property real scrollMouse: 1.0         // Hyprland (mouse wheel) scroll_factor
    property string barPadding: "normal"   // low | normal | high (bar height, distance from the top, side padding)
    property string powerMgr: "halcyon"    // halcyon | power-profiles-daemon | tlp | auto-cpufreq | tuned
    property var env: null                 // the shell (shell.qml): the Widget builder previews the widgets with its live feeds
    signal editOnDesktop(string which)        // "desktop" or "lock": place the widgets of that screen (shell.qml opens the desktop editor on it)
    property string wallpaperPath: ""      // the wallpaper in use (shell.qml): the Desktop builder's little preview shows it
    property bool borderAsk: false          // the bar was just turned off while the screen border is on: asks whether to turn the border off too
    property var opt: ({})                 // the extra settings (shell.qml "opt"): colour cycling, workspaces, clock, popups ...
    property bool avAiOn: false              // AI review of antivirus alerts is on (shell.qml reads it from scripts/antivirus-ai.sh)
    property var hyCur: ({})               // Hyprland values as they are now (shell.qml): where the sliders start

    // ---- Tools: what is switched on right now (scripts/tool-state.sh), so a switch always shows the truth
    property var tools: ({ nightlight: false, nightlightOk: true, touchpad: true, gestures: true, wifips: false, wifiOk: true, temp: 4000 })
    property string toolPending: ""
    readonly property var toolActions: ({ nightlight: "nightlight", touchpad: "touchpad", gestures: "gestures", wifips: "wifi-powersave" })
    function toolFlip(k) {
        noteUse(k)
        var t = JSON.parse(JSON.stringify(tools))
        t[k] = !t[k]
        tools = t                       // show it at once; the real state is read again below
        toolPending = k
        action(toolActions[k])
        toolAgain.restart()
    }
    Timer { id: toolAgain; interval: 1000; onTriggered: { root.toolPending = ""; if (!toolProc.running) toolProc.running = true } }
    Timer { interval: 3000; running: root.open; repeat: true; triggeredOnStart: true; onTriggered: if (!toolProc.running) toolProc.running = true }
    Process {
        id: toolProc
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/tool-state.sh"]
        stdout: StdioCollector { onStreamFinished: { if (root.toolPending !== "") return; try { root.tools = JSON.parse(text) } catch (e) {} } }
    }

    // ---- Startup & background (scripts/startup-conf.sh): tray applets, polkit agent, GPU. Keys \"st:NAME\" in the tree below.
    property var startup: ({ NM_APPLET: false, BLUEMAN: false, POLKIT: "auto", GPU: "igpu", FILE_ICONS: "medium", CLIPBOARD: true, GESTURES: true, AUDIO_FOCUS: true, AUDIO_RESUME: true, AUDIO_DELAY: "2", PORTAL: "login", has: ({ nm: true, blueman: true, hyprpolkit: true, gnome: true, kde: true, nvidia: false, safety: false }) })
    property string startupNote: ""        // "applies at the next login" hint after changing the agent or the GPU
    readonly property string startupScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/startup-conf.sh"
    // every change in the tree goes through here: "st:" values are written by the script, everything else goes to shell.qml
    // ---- Often used (top of Discover): how often each row was changed (opt.setUse = { key or "act:<id>": count }); the most used rows
    // are listed there. A slider dragged or the same row clicked again within 3 s counts once.
    property string _lastUse: ""
    property double _lastUseMs: 0
    function noteUse(key) {
        if (typeof key !== "string" || key === "" || key.indexOf("pair:") === 0) return
        var now = Date.now()
        if (key === _lastUse && now - _lastUseMs < 3000) { _lastUseMs = now; return }
        _lastUse = key; _lastUseMs = now
        var u = {}, src = opt && opt.setUse ? opt.setUse : {}
        for (var k in src) u[k] = src[k]
        u[key] = (u[key] || 0) + 1
        setting("opt:setUse", u)
    }
    Connections { target: root; function onAction(id) { root.noteUse("act:" + id) } }
    readonly property int oftenMax: 8
    // the rows of "Often used": the original rows (any `when` still applies), most used first
    readonly property var oftenItems: {
        var u = opt && opt.setUse ? opt.setUse : {}, all = []
        for (var g = 0; g < groups.length; g++) {
            if (groups[g].id === "often") continue
            for (var i = 0; i < groups[g].items.length; i++) {
                var it = groups[g].items[i]
                var k = it.type === "action" ? "act:" + it.id : it.key
                if (!k || !(u[k] >= 1) || it.type === "custom") continue
                var c = {}
                for (var x in it) c[x] = it[x]
                delete c.adv
                c.desc = groups[g].title + (it.desc ? " · " + it.desc : "")         // where it lives
                all.push({ n: u[k], it: c })
            }
        }
        all.sort(function (a, b) { return b.n - a.n })
        var out = []
        for (var j = 0; j < all.length && j < oftenMax; j++) out.push(all[j].it)
        return out
    }
    function change(key, v) {
        noteUse(key)
        if (key === "opt:barStyle" && v === "off" && root.opt && root.opt.frame === true) {      // the border is part of the bar's look: ask, do not decide
            setting(key, v)
            borderAsk = true
            return
        }
        if (typeof key === "string" && key.indexOf("pair:") === 0) {
            var pr = pairs[key.substring(5)]
            for (var i = 0; i < pr.length; i++) setting("opt:" + pr[i], v)
            return
        }
        if (typeof key === "string" && key.indexOf("bl:") === 0) {       // one field of the bar's layout; BarLayout.js keeps the rest of it as it is
            var bk = key.substring(3)
            var b0 = BL.normalize(opt ? opt.barLayout : null)
            var b1 = bk === "shape" ? BL.setShape(b0, v) : bk === "side" ? BL.setSide(b0, v) : bk === "rstyle" ? BL.setRStyle(b0, v)
                   : bk === "caps" ? BL.setCaps(b0, v) : bk === "spMode" ? BL.setSpMode(b0, v) : null
            if (b1) setting("opt:barLayout", b1)
            return
        }
        if (typeof key === "string" && key.indexOf("fc:") === 0) {
            var fk = key.substring(3)
            var fc = JSON.parse(JSON.stringify(focusConf))
            fc[fk] = v
            focusConf = fc
            Quickshell.execDetached(["bash", focusScript, "set", fk, (v === true ? "1" : v === false ? "0" : String(v))])
            focusAgain.restart()
            return
        }
        if (typeof key === "string" && key.indexOf("rmwhen:") === 0) {     // "off" = reminder off; else it is on with that interval
            var rw = key.substring(7)                                       // BACKUP | SAFETY
            if (rw === "SAFETY" && !(startup.has && startup.has.safety)) return
            if (v === "off") { change("rm:" + rw + "_REMIND", false); return }
            var wasOn = !!(remind && remind[rw + "_REMIND"])
            var rcw = JSON.parse(JSON.stringify(remind))
            rcw[rw + "_EVERY"] = v
            rcw[rw + "_REMIND"] = true
            remind = rcw
            // one shell, so the two writes of the script never overlap; turning it on again only when it was off keeps the running count
            Quickshell.execDetached(["bash", "-c", "bash \"$1\" set \"$2\" \"$3\"" + (wasOn ? "" : " && bash \"$1\" set \"$4\" 1"), "x", remindScript, rw + "_EVERY", String(v), rw + "_REMIND"])
            remindAgain.restart()
            return
        }
        if (typeof key === "string" && key.indexOf("rm:") === 0) {
            var rk = key.substring(3)
            if (rk.indexOf("SAFETY") === 0 && !(startup.has && startup.has.safety)) return       // the safety check is not installed
            var rc = JSON.parse(JSON.stringify(remind))
            rc[rk] = v
            remind = rc
            Quickshell.execDetached(["bash", remindScript, "set", rk, (v === true ? "1" : v === false ? "0" : String(v))])
            remindAgain.restart()
            return
        }
        if (typeof key === "string" && key.indexOf("fx:") === 0) {
            if (key === "fx:profile" && !fxConf.safe) {
                var fc2 = JSON.parse(JSON.stringify(fxConf))
                fc2.profile = v                                 // show it at once; the real state is read again below
                fxConf = fc2
                setting("fxProfile", v)
                fxAgain.restart()
            }
            return
        }
        if (key === "ai:enabled") {                      // the master AI switch (scripts/ai-models.py master on|off)
            var aiNow = JSON.parse(JSON.stringify(ai))
            aiNow.enabled = (v === true)
            ai = aiNow                                   // show it at once; the real state is read again below
            Quickshell.execDetached(["python3", aiScript, "master", v === true ? "on" : "off"])
            aiAgain.restart()
            notesAgain.restart()
            return
        }
        if (typeof key === "string" && key.indexOf("nt:") === 0) {
            var nk = key.substring(3)
            var ncf = JSON.parse(JSON.stringify(notesConf))
            ncf[nk] = v
            notesConf = ncf                                // show it at once; the real state is read again below
            Quickshell.execDetached(["python3", notesScript, "set", nk, (v === true ? "1" : v === false ? "0" : String(v))])
            notesAgain.restart()
            return
        }
        if (typeof key === "string" && key.indexOf("gr:") === 0) {
            var gk = key.substring(3)
            var gc = JSON.parse(JSON.stringify(greeting))
            gc[gk] = v
            greeting = gc                                  // show it at once
            Quickshell.execDetached(["bash", greetScript, "set", gk, String(v)])
            return
        }
        if (typeof key === "string" && key.indexOf("st:") === 0) {
            var k = key.substring(3)
            if (k === "ANTIVIRUS") { root.action("antivirus-select:" + String(v)); startupAgain.restart(); return }   // root: shell.qml runs it in the console
            var st = JSON.parse(JSON.stringify(startup))
            st[k] = v
            startup = st                                   // show it at once; the real state is read again below
            Quickshell.execDetached(["bash", startupScript, "set", k, (v === true ? "1" : v === false ? "0" : String(v))])
            if (k === "POLKIT" || k === "GPU" || k === "PORTAL") startupNote = "Applies the next time you log in."
            startupAgain.restart()
            return
        }
        setting(key, v)
    }
    Timer { id: startupAgain; interval: 900; onTriggered: if (!startupProc.running) startupProc.running = true }
    Process {
        id: startupProc
        command: ["bash", root.startupScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.startup = JSON.parse(text) } catch (e) {} } }
    }

    // ---- Notes (scripts/halcyon-notes.py): should the local Ollama model sort new notes into tasks? Keys "nt:NAME" in the tree below.
    property var notesConf: ({ NOTES_SUMMARY: false, NOTES_OCR: true, NOTES_VLM: false, tesseract: null, vlmModel: "", NOTES_AI: false, NOTES_OVERVIEW: false, NOTES_AI_MODE: "ask", NOTES_NUDGE_HOURS: "3", NOTES_NUDGE_MAX: "4", ollama: null, model: "" })
    readonly property string notesScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py"
    Timer { id: notesAgain; interval: 900; onTriggered: if (!notesProc.running) notesProc.running = true }
    Process {
        id: notesProc
        command: ["python3", root.notesScript, "conf"]
        stdout: StdioCollector { onStreamFinished: { try { root.notesConf = JSON.parse(text) } catch (e) {} } }
    }

    // ---- Profiles and Safe mode (scripts/halcyon-fx.py). Keys "fx:NAME" in the tree below; the choice itself is made by shell.qml (fxProfile).
    property var fxConf: ({ profile: "custom", safe: false })
    readonly property string fxScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-fx.py"
    Timer { id: fxAgain; interval: 1800; onTriggered: if (!fxProc.running) fxProc.running = true }
    Process {
        id: fxProc
        command: ["python3", root.fxScript, "status", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.fxConf = JSON.parse(text) } catch (e) {} } }
    }
    Connections { target: root; function onOpenChanged() { if (root.open && !fxProc.running) fxProc.running = true } }

    // ---- Terminal greeting (scripts/greeting-conf.sh): which logo the fish greeting shows. Keys "gr:LOGO" in the tree below.
    // The buttons (paste / edit / preview) are handled in shell.qml; this window only re-reads the choice afterwards, because
    // pasting or editing switches the greeting to "custom".
    property var greeting: ({ LOGO: "adaptive", custom: false })
    readonly property string greetScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/greeting-conf.sh"
    Timer { id: greetAgain; interval: 900; onTriggered: if (!greetProc.running) greetProc.running = true }
    Process {
        id: greetProc
        command: ["bash", root.greetScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.greeting = JSON.parse(text) } catch (e) {} } }
    }
    Connections {
        target: root
        function onAction(id) {
            if (id.indexOf("greeting-") === 0) greetAgain.restart()
            if (id === "fx-safe-on" || id === "fx-safe-off") {       // the button that no longer applies goes away at once; the real state is read again a moment later
                var fcs = JSON.parse(JSON.stringify(root.fxConf))
                fcs.safe = (id === "fx-safe-on")
                root.fxConf = fcs
                fxAgain.interval = 2600; fxAgain.restart()
            }
        }
    }

    // ---- Backup / safety-check reminders (scripts/remind.sh): keys "rm:NAME" in the tree below. The automatic safety-check run
    // (root, behind your sudo password) is the custom leaf at the end of Settings > Security; its state comes in as remind.auto.
    property var remind: ({ BACKUP_REMIND: false, BACKUP_EVERY: "7", BACKUP_DAYS: 14, SAFETY_REMIND: false, SAFETY_EVERY: "30", SAFETY_DAYS: 14, backupAgo: "never", safetyAgo: "never", auto: ({ on: false, days: 0, every: "custom" }) })
    readonly property string remindScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/remind.sh"
    readonly property string autoScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/safety-auto.sh"
    Timer { id: remindAgain; interval: 700; onTriggered: if (!remindProc.running) remindProc.running = true }
    Timer { interval: 30000; running: root.open; repeat: true; onTriggered: if (!remindProc.running) remindProc.running = true }   // keeps the scan clock honest while Settings is open
    Process {
        id: remindProc
        command: ["bash", root.remindScript, "conf"]
        stdout: StdioCollector { onStreamFinished: { try { root.remind = JSON.parse(text) } catch (e) {} } }
    }

    // ---- Timelines elsewhere (scripts/timeline.py): when the wallpaper last changed, when the system was last updated and the
    // Focus streak. It only READS files that already exist and prints one line of JSON; it runs while Settings is open (at
    // open, every 60 s, and a moment after the wallpaper changes) and never while it is closed.
    property var tl: ({})
    readonly property string timelineScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/timeline.py"
    Timer { id: tlAgain; interval: 1500; onTriggered: if (!tlProc.running) tlProc.running = true }
    Timer { interval: 60000; running: root.open; repeat: true; onTriggered: if (!tlProc.running) tlProc.running = true }
    onWallpaperPathChanged: if (root.open) tlAgain.restart()
    Process {
        id: tlProc
        command: ["python3", root.timelineScript, "conf"]
        stdout: StdioCollector { onStreamFinished: { try { root.tl = JSON.parse(text) } catch (e) {} } }
    }

    // ---- Focus mode (scripts/focus.sh): options are keys "fc:NAME" in the tree below; the block list is the custom leaf at the end
    property var focusConf: ({ LENGTH: 25, POMODORO: false, BREAK: 5, LONG_BREAK: 15, CYCLES: 4, DND: true, CAFFEINE: true, BLOCK: true, CLOSE_RUNNING: true, BREAK_FREE: true, apps: [] })
    property var focusApps: ({ blocked: [], open: [] })
    readonly property string focusScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/focus.sh"
    signal focusOptionsChanged()              // shell.qml reloads what the utilities box shows
    function focusLoad() { if (!focusConfProc.running) focusConfProc.running = true; if (!focusAppsProc.running) focusAppsProc.running = true }
    function focusApp(what, cls) {         // block | unblock; cls may be one class or a list of them (one call, one write)
        Quickshell.execDetached(["bash", focusScript, what].concat(cls))
        focusAgain.restart()
    }
    Timer { id: focusAgain; interval: 500; onTriggered: { root.focusLoad(); root.focusOptionsChanged() } }
    Timer { interval: 4000; running: root.open && !root.collapsed.focus; repeat: true; onTriggered: if (!focusAppsProc.running) focusAppsProc.running = true }
    Process {
        id: focusConfProc
        command: ["bash", root.focusScript, "conf"]
        stdout: StdioCollector { onStreamFinished: { try { root.focusConf = JSON.parse(text) } catch (e) {} } }
    }
    Process {
        id: focusAppsProc
        command: ["bash", root.focusScript, "apps"]
        stdout: StdioCollector { onStreamFinished: { try { root.focusApps = JSON.parse(text) } catch (e) {} } }
    }

    // ---- AI advisor model (scripts/ai-models.py): what is installed, the online catalog, the download in progress
    property var ai: ({ enabled: true, installed: [], catalog: [], current: "", pull: null, running: true, ollama: true, source: "", hw: ({}), envOverride: false })
    readonly property string aiScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/ai-models.py"
    function aiLoad(refresh) {
        aiProc.command = ["python3", aiScript, "list"].concat(refresh ? ["--refresh"] : [])
        if (!aiProc.running) aiProc.running = true
    }
    function aiUse(name) {                                  // an installed model: switch at once
        Quickshell.execDetached(["python3", aiScript, "use", name])
        var a = JSON.parse(JSON.stringify(ai)); a.current = name; ai = a
        aiAgain.restart()
    }
    function aiPull(name) {                                 // an online one: download it, and switch to it when it is there
        Quickshell.execDetached(["python3", aiScript, "pull", name, "--use"])
        var a = JSON.parse(JSON.stringify(ai)); a.pull = { name: name, pct: 0, status: "starting", done: false, error: "" }; ai = a
        aiAgain.restart()
    }
    function aiCancel() { Quickshell.execDetached(["python3", aiScript, "cancel"]); aiAgain.restart() }
    function aiRemove(name) { Quickshell.execDetached(["python3", aiScript, "rm", name]); aiAgain.restart() }
    Timer { id: aiAgain; interval: 900; onTriggered: root.aiLoad(false) }
    Timer {                                                 // while a download runs: its progress, once a second
        interval: 1000; repeat: true
        running: root.open && !!root.ai.pull && !root.ai.pull.done
        onTriggered: if (!aiPullProc.running) aiPullProc.running = true
    }
    Process {
        id: aiProc
        stdout: StdioCollector { onStreamFinished: { try { root.ai = JSON.parse(text) } catch (e) {} } }
    }
    Process {
        id: aiPullProc
        command: ["python3", root.aiScript, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text), a = JSON.parse(JSON.stringify(root.ai))
                    a.pull = d.name ? d : null
                    root.ai = a
                    if (d.done) root.aiLoad(false)          // finished: the installed list and the model in use changed
                } catch (e) {}
            }
        }
    }

    // ---- options that exist twice (island AND notch): ONE entry in the tree writes both. Keys "pair:NAME".
    readonly property var pairs: ({
        ws: ["islWs", "notchWs"], wsMin: ["islWsMin", "notchWsMin"], specials: ["islSpecials", "notchSpecials"],
        viz: ["islViz", "notchViz"], time: ["islTime", "notchTime"], date: ["clockDate", "notchDate"],
        combo: ["islCombo", "notchCombo"], wifi: ["islWifi", "notchWifi"], wifiStyle: ["islWifiStyle", "notchWifiStyle"],
        bt: ["islBtMode", "notchBtMode"], bat: ["islBat", "notchBat"], batPct: ["islBatPct", "notchBatPct"],
        caffeine: ["islCaffeine", "notchCaffeine"], spacing: ["islSpacing", "notchSpacing"]
    })

    // default apps (scripts/apps.sh): what is installed per kind, and the one in use
    property var apps: ({ terminal: [], browser: [], files: [], editor: [], music: [], chat: [], current: ({ terminal: "", browser: "", files: "", editor: "", music: "", chat: "" }) })
    readonly property string appsScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh"
    function setApp(kind, id) {
        Quickshell.execDetached(["bash", appsScript, "set", kind, id])
        var a = JSON.parse(JSON.stringify(apps))
        a.current[kind] = id
        apps = a                     // show it at once; the list is re-read below
        appsAgain.restart()
    }
    // a website as a chat app (scripts/apps.sh add-web): it is chosen at once, and SUPER+D opens it in your browser
    function addWebApp(name, url) {
        Quickshell.execDetached(["bash", appsScript, "add-web", name, url])
        appsAgain.restart()
    }
    function removeWebApp(id) {
        Quickshell.execDetached(["bash", appsScript, "remove-web", id])
        appsAgain.restart()
    }
    // wallpaper folder (scripts/wallpapers.sh): the folder, the wallpaper in use, every image in it
    property var wp: ({ dir: "", current: "", files: [] })
    property string wpText: ""
    readonly property string wpScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/wallpapers.sh"
    function wpAct(a) {
        if (a === "wallpaper" || a === "wallpaper-back" || a === "wallpaper-keep") { action(a); return }     // handled by the shell (Wallpaper.qml)
        // the file manager / picker window opens below this overlay, so get out of its way first
        if (a === "open" || a === "add" || a === "choose-dir") hide()
        Quickshell.execDetached(["bash", wpScript, a])
        wpAgain.restart()
    }
    function pickWallpaper(path) {
        var d = JSON.parse(JSON.stringify(wp))
        d.current = path
        wp = d                           // show the choice at once; the list is re-read below
        wallpaperSet(path)
        wpAgain.restart()
    }
    // the colours of every wallpaper (scripts/wallpapers.sh colors): { path: ["#accent", "#accent2", ...] }, read while the gallery is open
    property var wpColors: ({})
    property var wpColorsNew: ({})
    Timer {
        id: wpColorFlush
        interval: 120
        onTriggered: { root.wpColors = Object.assign({}, root.wpColors, root.wpColorsNew); root.wpColorsNew = ({}) }
    }
    Process {
        id: wpColorProc
        command: ["bash", root.wpScript, "colors"]
        stdout: SplitParser {
            onRead: line => {
                var i = line.indexOf("\t")
                if (i <= 0) return
                try { root.wpColorsNew[line.substring(0, i)] = JSON.parse(line.substring(i + 1)) } catch (e) { return }
                wpColorFlush.restart()
            }
        }
    }
    onGalleryOpenChanged: {
        if (galleryOpen) { galleryUnload.stop(); galleryLoaded = true; if (!wpColorProc.running) wpColorProc.running = true }
        else galleryUnload.restart()
    }
    Timer { id: wpAgain; interval: 1500; onTriggered: if (!wpProc.running) wpProc.running = true }
    Timer { id: wpPoll; interval: 4000; running: root.open || root.galleryOpen; repeat: true; triggeredOnStart: true; onTriggered: if (!wpProc.running) wpProc.running = true }
    Process {
        id: wpProc
        command: ["bash", root.wpScript, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.wpText) return          // nothing changed: keep the thumbnails as they are
                root.wpText = text
                try { root.wp = JSON.parse(text) } catch (e) {}
                if (root.galleryOpen && !wpColorProc.running) wpColorProc.running = true      // new pictures: read their colours
            }
        }
    }

    Timer { id: appsAgain; interval: 600; onTriggered: if (!appsProc.running) appsProc.running = true }
    Process {
        id: appsProc
        command: ["bash", root.appsScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.apps = JSON.parse(text) } catch (e) {} } }
    }

    // your own command per special workspace (scripts/special.sh): { special, music, communication, sysmon }, "" = the default
    property var specialCmds: ({})
    readonly property string specialScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/special.sh"
    function setSpecial(id, cmd) {
        var m = JSON.parse(JSON.stringify(specialCmds))
        m[id] = cmd
        specialCmds = m
        Quickshell.execDetached(["bash", specialScript, "set", id, cmd])
    }
    Process {
        id: specialProc
        command: ["bash", root.specialScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.specialCmds = JSON.parse(text) } catch (e) {} } }
    }

    // ---- Touchpad gestures + mouse buttons (scripts/input-conf.sh). The choices are ~/.local/state/island/gestures.conf, which
    // hyprland/gestures.lua and hyprland/mouse.lua read; a change goes to the file and Hyprland reloads (shell.qml batches it).
    // Gesture ids: g3-left ... g4-pinchout (3 / 4 fingers); mouse button ids: m274 ... m279.
    property var inputConf: ({ gestures: ({}), mouse: ({}), mice: [] })
    property string inputRaw: ""
    property int inputUsers: 0              // editors on screen right now (the mouse is only looked for while there is one)
    property bool inputBusy: false          // a change is on its way: do not read the old state back over it
    readonly property string inputScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/input-conf.sh"
    function ac(id, t, g) { return { id: id, t: t, g: g } }
    readonly property var commonActions: [
        ac("ws-next", "Next workspace", "Workspaces"), ac("ws-prev", "Previous workspace", "Workspaces"),
        ac("overview", "Workspace tree", "Workspaces"), ac("scratch", "Scratch workspace", "Workspaces"),
        ac("music", "Music", "Workspaces"), ac("comm", "Communication", "Workspaces"),
        ac("sysmon", "System monitor", "Workspaces"), ac("todo", "Calendar", "Island"),
        ac("fullscreen", "Fullscreen", "Windows"), ac("float", "Floating on / off", "Windows"), ac("pin", "Pin window", "Windows"),
        ac("close", "Close window", "Windows"), ac("focus-left", "Focus the window on the left", "Windows"), ac("focus-right", "Focus the window on the right", "Windows"),
        ac("launcher", "App launcher", "Island"), ac("settings", "Settings", "Island"), ac("cheatsheet", "Shortcuts", "Island"),
        ac("notifcenter", "Notification centre", "Island"), ac("quickterm", "Quick console", "Island"),
        ac("dnd", "Do not disturb", "Island"), ac("focus", "Focus mode", "Island"), ac("gaming", "Gaming mode", "Island"), ac("caffeine", "Keep the screen awake", "Island"),
        ac("lock", "Lock the screen", "System"), ac("sleep", "Sleep", "System"), ac("screenshot", "Screenshot of an area", "System"),
        ac("playpause", "Play / pause", "Sound and light"), ac("nexttrack", "Next track", "Sound and light"), ac("prevtrack", "Previous track", "Sound and light"),
        ac("volup", "Volume up", "Sound and light"), ac("voldown", "Volume down", "Sound and light"), ac("mute", "Mute", "Sound and light"),
        ac("brightup", "Brighter", "Sound and light"), ac("brightdown", "Dimmer", "Sound and light"),
        ac("terminal", "Terminal", "Apps"), ac("browser", "Browser", "Apps"), ac("files", "File manager", "Apps"), ac("editor", "Code editor", "Apps"),
        ac("app", "Open an app…", "Apps"), ac("cmd", "Run a command…", "Apps")
    ]
    readonly property var gestureActions: [ac("none", "Nothing: apps get the gesture", "Off")].concat(commonActions)
    readonly property var mouseActions: [ac("none", "Default: the app handles the button", "Off")].concat(commonActions,
        [ac("drag", "Move a window while held", "Mouse"), ac("resize", "Resize a window while held", "Mouse")])
    property double inputLast: 0
    // not more than once every 2 s once there is something to show (the editors are created again whenever a search brings them up)
    function inputLoad() {
        if (inputBusy || inputProc.running) return
        if (inputRaw !== "" && Date.now() - inputLast < 2000) return
        inputLast = Date.now()
        inputProc.running = true
    }
    function setInput(id, act, cmd) {
        var c = JSON.parse(JSON.stringify(inputConf))
        var tbl = id.charAt(0) === "g" ? c.gestures : c.mouse
        tbl[id] = { a: act, c: (act === "app" || act === "cmd") ? (cmd || "") : "" }
        inputConf = c
        inputBusy = true
        Quickshell.execDetached(["bash", inputScript, "set", id, act, cmd || ""])
        root.action("hypr-reload")          // only gestures / buttons that do something are registered, so Hyprland has to read the file again
        inputDone.restart()
    }
    function resetInput(what) { inputBusy = true; inputResetProc.what = what; inputResetProc.running = true }
    Timer { id: inputDone; interval: 3000; onTriggered: { root.inputBusy = false; root.inputLoad() } }
    Timer { interval: 4000; running: root.open && root.inputUsers > 0; repeat: true; onTriggered: root.inputLoad() }
    Process {
        id: inputProc
        command: ["bash", root.inputScript, "conf"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.inputBusy || text === root.inputRaw) return
                try { root.inputConf = JSON.parse(text); root.inputRaw = text } catch (e) {}
            }
        }
    }
    Process {
        id: inputResetProc
        property string what: "all"
        command: ["bash", root.inputScript, "reset", what]
        onExited: { root.action("hypr-reload"); inputDone.restart(); root.inputRaw = "" }
    }

    signal setting(string key, var value)
    signal wallpaperSet(string path)  // a thumbnail was clicked
    signal action(string id)          // wallpaper | config | cheatsheet | reload

    // show("focus") opens Settings with only that group unfolded (the utilities box's "Blocked apps" button uses it)
    property string pendingGroup: ""
    function unfoldOnly(id) {
        page = pageOf(id)
        setAll(true)
        var c = {}
        for (var k in collapsed) if (k !== id) c[k] = collapsed[k]
        collapsed = c
        section = ""
    }
    function show(group) {
        if (group) { if (open) unfoldOnly(group); else pendingGroup = group }
        open = true
    }
    // The Wallpaper Gallery lives inside the window below, which only exists while Settings is open, and ids inside that window are
    // not visible from here. So whether the gallery is open is kept up here, and the gallery follows it.
    property bool galleryOpen: false
    property bool galleryLoaded: false          // the gallery window exists (a moment longer than galleryOpen, so it can fade out)
    Timer { id: galleryUnload; interval: 320; onTriggered: { root.galleryLoaded = false; settingsGc.restart() } }
    function openGallery() { galleryOpen = true }      // its own window: no need to go through Settings
    // the Bar builder window works the same way (Settings > Bar style > Bar builder > "Open the bar builder")
    property bool builderOpen: false
    property bool builderLoaded: false
    Timer { id: builderUnload; interval: 320; onTriggered: { root.builderLoaded = false; settingsGc.restart() } }
    Timer { id: settingsGc; interval: 2500; onTriggered: gc() }
    onBuilderOpenChanged: { if (builderOpen) { builderUnload.stop(); builderLoaded = true } else builderUnload.restart() }
    function openBuilder() { builderOpen = true }
    // the notification box builder window (Settings > Panels & notifications > Notification box builder)
    function openNotifBuilder() { nbOpen = true }
    // the desktop builder window (Settings > Appearance > Desktop builder): wallpaper on / off + blur, moving stars, the corner each box opens from
    function openDesktopBuilder(target) { dbTarget = (target === "lock") ? "lock" : "desktop"; dbOpen = true }
    property string dbTarget: "desktop"        // which screen the desktop builder builds: "desktop" or "lock"
    // the widget builder window (Settings > Appearance > Widget builder): one widget at a time, its layout and look
    property bool wbOpen: false
    property bool wbLoaded: false
    property string wbPick: ""
    Timer { id: wbUnload; interval: 320; onTriggered: { root.wbLoaded = false; settingsGc.restart() } }
    onWbOpenChanged: { if (wbOpen) { wbUnload.stop(); wbLoaded = true } else wbUnload.restart() }
    property string wbTarget: "desktop"        // which screen's widgets the builder shapes: "desktop" or "lock"
    function openWidgetBuilder(uid, target) { wbPick = uid; wbTarget = (target === "lock") ? "lock" : "desktop"; wbOpen = true }
    property bool dbOpen: false
    property bool dbLoaded: false
    Timer { id: dbUnload; interval: 320; onTriggered: { root.dbLoaded = false; settingsGc.restart() } }
    onDbOpenChanged: { if (dbOpen) { dbUnload.stop(); dbLoaded = true } else dbUnload.restart() }
    property bool nbOpen: false
    property bool nbLoaded: false
    Timer { id: nbUnload; interval: 320; onTriggered: { root.nbLoaded = false; settingsGc.restart() } }
    onNbOpenChanged: { if (nbOpen) { nbUnload.stop(); nbLoaded = true } else nbUnload.restart() }
    // the Startup & processes window (StartupWindow.qml): what starts with the desktop and what is running, with RAM and CPU
    property bool startupOpen: false
    property bool startupLoaded: false
    Timer { id: startupUnload; interval: 320; onTriggered: { root.startupLoaded = false; settingsGc.restart() } }
    onStartupOpenChanged: { if (startupOpen) { startupUnload.stop(); startupLoaded = true } else startupUnload.restart() }
    function openStartup() { startupOpen = true }
    function hide() { galleryOpen = false; builderOpen = false; nbOpen = false; dbOpen = false; wbOpen = false; startupOpen = false; open = false }
    function toggle() { open = !open }

    component SChip: Chip { maxLabel: 1000 }

    // ======================================================================== the tree
    // group { id, title, items[] }.  item types:
    //   toggle  { key, label, desc }                         a switch
    //   tool    { key, label, desc }                         a switch for something a script owns (shows its real state)
    //   seg     { key, label, desc, opts: [{v, t}] }         pick one
    //   slider  { key, label, desc, min, max, step, ... }    drag
    //   action  { id, label, btn, done, desc }               a button that does something
    //   acts    { label, desc, btns: [{id, btn, done, close}] }  several buttons in one row (Backup: whole system / home folder)
    //   chips   { label, desc, opts: [ch(key, text, when)] } several on / off switches in one row (each chip flips its key)
    //   custom  { name }                                     wallpaper picker, default apps, special workspace commands, constellations, colour swatches
    // key: "theme" = a property of this window, "opt:x" / "hy:x" = shell.qml's opt / Hyprland values
    function o(v, t) { return { v: v, t: t } }
    function ch(k, t, w) { return { k: k, t: t, when: w } }        // one chip of a "chips" row: a switch (key k) with an optional when
    // the custom leaves live in their own files (Set*.qml); this maps an item's `name` to the Component that makes one
    function leafComp(name) {
        switch (name) {
        case "wallpaper": return cWallpaper
        case "gestures": return cGestures
        case "mouseButtons": return cMouseButtons
        case "apps": return cApps
        case "specialCmds": return cSpecialCmds
        case "focusApps": return cFocusApps
        case "dayClock": return cDayClock
        case "wallClock": return cWallClock
        case "profile": return cProfile
        case "liveWalls": return cLiveWalls
        case "focusClock": return cFocusClock
        case "safetyAuto": return cSafetyAuto
        case "counterScan": return cCounterScan
        case "desktopBuilder": return cDesktopBuilder
        case "widgetBuilder": return cWidgetBuilder
        case "notifBuilder": return cNotifBuilder
        case "barBuilder": return cBarBuilder
        case "aiModel": return cAiModel
        case "voiceKey": return cVoiceKey
        case "discover": return cDiscover
        case "growth": return cGrowth
        default: return cSwatches
        }
    }
    function remindRefresh() { remindAgain.restart() }        // for SetSafetyAuto: look at the scan state again a moment after a change
    // Backup and Safety-check reminders share one shape: how often + a custom number of days (shown only for "Custom")
    function remindRows(rw, label, desc, needs) {
        var opts = [o("off", "Off"), o("1", "Day"), o("7", "Week"), o("30", "Month"), o("90", "3 months"), o("custom", "Custom")]
        return [
            { type: "seg", adv: true, key: "rmwhen:" + rw, needs: needs, label: label, desc: desc, opts: opts },
            { type: "slider", adv: true, key: "rm:" + rw + "_DAYS", needs: needs, label: "Custom: every how many days", min: 1, max: 365, step: 1, unit: " days", glyph: 0xF0E17, when: "rmwhen:" + rw + "=custom" }
        ]
    }

    // Sections (the tabs) and groups: eight sections, 35 groups, none longer than ~10 visible rows. A group that grew past that was split
    // by topic (Bar -> Bar + Bar behaviour, Effects -> Transparency & blur + Motion & dimming, Notifications -> Notifications + Edge boxes,
    // Mouse -> Mouse & touchpad + Keyboard & launcher, Performance -> Performance & memory + Tree view). Night light lives in Colours,
    // Rice in Apps. Items marked adv: true sit behind each group's "Advanced" row
    // (a search or the header switch shows them all). The two reminder blocks of Backup / Safety come from remind() below.
    readonly property var groups: [
        { id: "often", title: "Often used", section: "Discover", items: [] },       // filled from oftenItems (groupsNow): the rows you change most
        { id: "discover", title: "What Halcyon can do", section: "Discover", items: [
            { type: "action", id: "tour-replay", label: "Guided tour", btn: "Start", done: "", desc: "A minute's walk round the desktop, with a few things to try. Also >tour in the launcher." },
            { type: "custom", name: "discover" }
        ] },
        { id: "look", title: "Look", section: "Appearance", items: [
            { type: "seg", key: "opt:keysStyle", label: "Shortcuts layout", desc: "Tree: every shortcut on a branching tree. Pages: a menu of groups on the left and one group at a time. Same shortcuts in both; the chip in the Shortcuts header switches too.", opts: [o("tree", "Tree"), o("pages", "Pages")] },
            { type: "seg", key: "opt:settingsStyle", label: "Settings layout", desc: "Tree: the branching view. Pages: a menu on the left and one page at a time. Same settings in both.", opts: [o("tree", "Tree"), o("pages", "Pages")] },
            { type: "seg", key: "opt:uiStyle", label: "Interface", desc: "New: one quiet pane, no outlines, pill buttons, the main action in solid accent and no explanations (ask > instead). Legacy: the first calm look, with a hairline around every box. Classic: the original, with the glass sheen and accent outlines.", opts: [o("new", "New"), o("legacy", "Legacy"), o("classic", "Classic")] },
            { type: "toggle", key: "opt:hideHints", label: "Hide explanations", desc: "Once you know your way around: the explanations under settings, the key hints at the bottom of the boxes and the help lines in widgets shrink to a small ? on the side. Hover it (or click it here) to read them again." },
            { type: "seg", key: "theme", label: "Theme", desc: "Island, panels, lock screen, window borders and apps (GTK / Qt) follow it. Colours still come from the wallpaper.", opts: [o("dark", "Dark"), o("light", "Light")] },
            { type: "toggle", key: "opt:boxShadow", label: "Soft shadow around boxes", desc: "The faint dark glow the notification box, utility box, console and the windows cast on the wallpaper. Off = none; the boxes keep their frosted glass." },
            { type: "seg", key: "opt:surface", label: "Box background", desc: "What every box, the bar and this window are filled with. Wallpaper tint: dark, coloured by the wallpaper and a little see-through. Match wallpaper accent: the same, but the boxes and their outlines take the accent colour of the wallpaper clearly (and follow it while the accent cycles). Matte black: dark grey, solid. Pitch black: true black, solid (best on OLED). The little stars and drifting dots turn up their brightness and keep the accent colour so they still show on black. Dark theme only.", opts: [o("tint", "Wallpaper tint"), o("match", "Match accent"), o("matte", "Matte black"), o("black", "Pitch black")], when: "theme=dark" },
            { type: "slider", key: "rounding", label: "Corner rounding", desc: "Window corners", min: 0, max: 28, step: 1, unit: " px", glyph: 0xF0A39 },
            { type: "slider", key: "gaps", label: "Gaps", desc: "Between windows (the outer gap is double)", min: 0, max: 20, step: 1, unit: " px", glyph: 0xF0B36 },
            { type: "slider", adv: true, key: "hy:borderSize", def: 2, label: "Border width", min: 0, max: 6, step: 1, unit: " px" },
            { type: "toggle", key: "opt:accentBorder", label: "Accent colour on the focused window", desc: "A thin border in the wallpaper's accent colour around the window you are using. Off = the neutral white hairline." },
            { type: "action", adv: true, id: "reset-look", label: "Look values", btn: "Back to the config files", done: "Reset", desc: "Forgets every window / look value changed here; hyprland/*.lua rules again." }
        ] },
        { id: "profile", title: "Profile", section: "Appearance", items: [
            { type: "custom", name: "profile", label: "Profile", btn: "name avatar picture face profile overview constellation" }
        ] },
        { id: "colours", title: "Colours & night light", section: "Appearance", items: [
            { type: "custom", name: "swatches" },
            { type: "seg", key: "opt:accentMode", label: "Accent colour", desc: "Fixed: the wallpaper's strongest colour. Cycle: the accent drifts slowly through every colour the wallpaper has, e.g. red, then purple, then back.", opts: [o("fixed", "Fixed"), o("cycle", "Cycle through the wallpaper")] },
            { type: "seg", key: "opt:cycleSecs", label: "Time per colour", desc: "How long the accent takes to go from one wallpaper colour to the next", opts: [o(10, "10 s"), o(20, "20 s"), o(30, "30 s"), o(60, "1 min"), o(120, "2 min"), o(300, "5 min")], when: "opt:accentMode=cycle" },
            { type: "slider", key: "colorBoost", label: "Colour intensity", desc: "How strongly the wallpaper's colour shows in the accent. 100 % is natural.", min: 0.5, max: 1.5, step: 0.05, scale: 100, unit: " %", glyph: 0xF03D8 },
            { type: "toggle", key: "termFollow", label: "Terminals follow the wallpaper" },
            { type: "seg", adv: true, key: "opt:termMode", label: "Terminal colours", desc: "Spectrum: red, green, blue, magenta ... each come from a colour the wallpaper really has. Accent: everything is pulled towards the one accent.", opts: [o("spectrum", "Spectrum"), o("accent", "One accent")], when: "termFollow=true" },
            { type: "toggle", adv: true, key: "opt:termDrift", label: "Open terminals cycle too", desc: "Cursor, blue and magenta follow the accent while it cycles (repainted every few seconds).", when: "termFollow=true" },
            { type: "action", adv: true, id: "termcolors", label: "Repaint terminals", btn: "Repaint now", done: "Repainted" },
            { type: "tool", key: "nightlight", label: "Night light", desc: "Warmer screen colours (hyprsunset)." },
            { type: "slider", adv: true, key: "opt:nightTemp", def: 4000, label: "Night light warmth", desc: "Lower is warmer", min: 2500, max: 6500, step: 100, unit: " K" }
        ] },
        { id: "wallpaper", title: "Wallpaper", section: "Appearance", items: [
            { type: "custom", name: "wallClock" },
            { type: "seg", key: "opt:deskLive", label: "Live wallpaper", desc: "A moving wallpaper instead of the picture (Super + Alt + W switches it). Halcyon sky is the login splash kept as your wallpaper; your own videos and GIFs go in ~/Pictures/Wallpapers/live. It pauses under fullscreen windows, while a game runs, while the screen is locked and during Focus with quiet visuals. Choosing a picture switches it off.", opts: [o("off", "Off: a picture"), o("on", "On")] },
            { type: "custom", name: "liveWalls", label: "Live wallpapers", btn: "live video gif animated halcyon sky" },
            { type: "toggle", adv: true, key: "opt:deskLiveWord", label: "HALCYON under the sparkle", when: "opt:deskLivePick=sky" },
            { type: "custom", name: "wallpaper" },
            { type: "seg", key: "opt:wpSource", label: "Source", desc: "Local: only your folder. Online: a fresh picture from Wallhaven (safe-for-work) in the category below, cached on disk. Mixed: either one. No network = your folder.", opts: [o("local", "Local"), o("online", "Online"), o("mixed", "Mixed")] },
            { type: "seg", key: "opt:wpCat", label: "Online category", desc: "What \"Next wallpaper\" and the timer fetch. Anime = characters, Anime art = anime-style scenery. Random picks a category each time. Search… uses your own word (the box below).", opts: [o("nature", "Nature"), o("movies", "Movies"), o("anime", "Anime"), o("anime-art", "Anime art"), o("space", "Space"), o("city", "City"), o("minimal", "Minimal"), o("cars", "Cars"), o("random", "Random"), o("custom", "Search…")], when: "opt:wpSource=online|mixed" },
            { type: "seg", key: "opt:wpEvery", label: "Change it by itself", desc: "A new random wallpaper from the folder; the island's colours follow each one.", opts: [o(0, "Never"), o(5, "5 min"), o(15, "15 min"), o(30, "30 min"), o(60, "1 hour")] },
            { type: "toggle", key: "opt:wpBootNew", label: "New wallpaper each boot", desc: "Off: the wallpaper you chose stays after a reboot. On: a random one from the folder at every boot." }
        ] },
        { id: "glass", title: "Transparency & blur", section: "Appearance", items: [
            { type: "slider", key: "glassShift", label: "Transparency", desc: "Of the island, panels and overlays", min: -0.15, max: 0.05, step: 0.01, scale: 100, signed: true, glyph: 0xF0335 },
            { type: "slider", adv: true, key: "opt:settingsGlass", def: 0.72, label: "Settings window opacity", desc: "Lower = more see-through: the blurred wallpaper and windows show through the Settings window.", min: 0.35, max: 1, step: 0.01, scale: 100, unit: " %", glyph: 0xF0335 },
            { type: "slider", adv: true, key: "hy:inactiveOpacity", def: 1, label: "Unfocused window opacity", desc: "Below 100 % windows you are not using turn see-through", min: 0.5, max: 1, step: 0.05, scale: 100, unit: " %" },
            { type: "toggle", key: "blur", label: "Blur" },
            { type: "slider", key: "hy:blurSize", def: 8, label: "Blur strength", min: 1, max: 16, step: 1, when: "blur=true" },
            { type: "slider", adv: true, key: "hy:blurPasses", def: 2, label: "Blur quality", desc: "More passes look smoother and cost more GPU", min: 1, max: 5, step: 1, when: "blur=true" },
            { type: "toggle", key: "shadows", label: "Shadows" },
        ] },
        { id: "motion", title: "Motion & dimming", section: "Appearance", items: [
            { type: "seg", key: "motion", label: "Island animations", opts: [o(0, "Off"), o(0.5, "Fast"), o(1, "Normal")] },
            { type: "toggle", key: "hyprAnim", label: "Window animations" },
            { type: "toggle", adv: true, key: "hy:resizeAnim", label: "Animate window resizing", desc: "Off: a window follows the pointer at once while you drag its edge (lighter with blur on). The Low resource preset turns it off" },
            { type: "toggle", key: "hy:dimInactive", label: "Dim unfocused windows" },
            { type: "slider", key: "hy:dimStrength", def: 0.3, label: "Dim amount", min: 0, max: 0.8, step: 0.05, scale: 100, unit: " %", when: "hy:dimInactive=true|1" },
            { type: "toggle", key: "opt:extraDim", label: "Extra dim mode", desc: "Drops the display brightness to minimum (1%) for nighttime comfort without losing color fidelity. You can also toggle it from the utilities panel or with Super + Alt + D." }
        ] },
        { id: "growth", title: "Constellations & Stars", section: "Stars & splash", items: [
            { type: "seg", key: "opt:dialogStarStyle", label: "Dialog stars effect (Battery saver)", desc: "Choose whether Settings, Display Switcher, Cheatsheet and dialogs use lightweight Moving Stars (drifting particles with tails, saving significant CPU/GPU and battery), Constellations (connected geometric nodes), Both, or Off.", opts: [o("moving", "Moving Stars (Lightweight)"), o("constellations", "Constellations"), o("both", "Both"), o("none", "Off")] },
            { type: "toggle", key: "opt:starsBar", label: "Moving stars in bars", desc: "A handful of tiny stars flying slowly across the bar (island, notch and custom bar), the bar builder and the wallpaper picker. Independent of the constellation switches below. Very light: they stand still while the bar is hidden or a page is open." },
            { type: "toggle", key: "opt:stars", label: "Constellations in the boxes", desc: "The drifting dots and lines behind the Settings, notification centre, cheat sheet, power menu and console (the lock and login screens have their own switch in Settings > Lock screen). Off = none in these, whatever the switches below say (the moving stars above are separate)." },
            { type: "chips", adv: true, label: "Show the constellations in", desc: "Pick the boxes that get them. (Needs the master switch above.)", opts: [ch("opt:starsSettings", "Settings"), ch("opt:starsNotifs", "Notification centre"), ch("opt:starsCheatsheet", "Cheat sheet"), ch("opt:starsCalendar", "Calendar"), ch("opt:starsPower", "Power menu"), ch("opt:starsTerm", "Console")], when: "opt:stars=true", soft: true },
            { type: "toggle", adv: true, key: "profileStars", label: "Profile picture constellation", when: "opt:stars=true||opt:treeConst=full|corner", soft: true, why: "Turn on \u201cConstellations in the boxes\u201d (or show the tree view constellation) to change this." },
            { type: "custom", adv: true, name: "growth" }
        ] },
        { id: "signature", title: "Splash, sky & time of day", section: "Stars & splash", items: [
            { type: "toggle", key: "opt:splashUnlock", def: true, label: "Splash when you unlock", desc: "The stars rush out again for about 2 seconds over your desktop right after you unlock the screen (the lock screen that is also your login does not repeat it). It never takes a click or a key. Needs the Splash animation switch (Lock screen). Not shown in Gaming mode or when motion is off.", when: "opt:splash=true" },
            { type: "toggle", key: "opt:splashShutdown", def: true, label: "Goodbye splash when you shut down", desc: "Shut down or Restart (power menu, launcher) first draws the stars back into the centre while the sparkle folds shut, about 2.4 seconds, and then goes. A click or a key skips straight to the end; the machine always goes down within about 5 seconds even if the animation fails. Needs the Splash animation switch (Lock screen). Not shown in Gaming mode or when motion is off.", when: "opt:splash=true" },
            { type: "slider", adv: true, key: "opt:splashAwayMin", def: 60, label: "Only after being away", desc: "The login and unlock splashes play only when you were locked, logged out or powered off at least this long. Shorter breaks go straight to the password or the desktop. 0 = every time.", min: 0, max: 240, step: 5, unit: " min", glyph: 0xF0954 },
            { type: "slider", adv: true, key: "opt:splashDim", def: 0.75, label: "Darken the screen during the splash", desc: "A dark veil under the stars, so the sparkle and the word stand out on a light theme or over a bright wallpaper (the unlock splash plays over your desktop). 0 % = no veil.", min: 0, max: 0.9, step: 0.05, scale: 100, unit: " %", when: "opt:splash=true" },
            { type: "toggle", key: "opt:splashSound", def: false, label: "Sounds with the splash", desc: "Calm, spacious sounds: a slow swell that opens up when you log in, a short warm one on unlock, and one that settles on shutdown. Nothing rings. With the boot splash (Plymouth) installed, they play under it too (press its Install / update once)." },
            { type: "action", id: "splash-sound-preview", label: "Hear the login sound", btn: "Play", done: "", desc: "Plays it once, whether the switch above is on or not." },
            { type: "action", adv: true, id: "splash-unlock-preview", label: "Unlock splash", btn: "Play it now", done: "", desc: "Plays the unlock animation once over what is on screen. It does not lock anything." },
            { type: "action", adv: true, id: "splash-shutdown-preview", label: "Goodbye splash", btn: "Play it now", done: "", desc: "Plays the shutdown animation once. It does NOT shut the computer down: a click, a key or a few seconds gives the screen back." },
            { type: "action", id: "plymouth-install", label: "Boot splash (Plymouth)", btn: "Install / update", done: "", desc: "The same stars and sparkle while Arch boots, before you log in (and when it shuts down). Opens a terminal: it needs your sudo password, installs plymouth if missing, adds it to mkinitcpio, adds `quiet splash` to your boot entry and rebuilds the initramfs. Uses your current accent colours. Also `halcyon-plymouth.sh install`." },
            { type: "action", adv: true, id: "plymouth-remove", label: "Boot splash off", btn: "Remove", done: "", desc: "Takes the Halcyon boot splash out again: plymouth is dropped from mkinitcpio, `splash` from the boot entry, and the initramfs is rebuilt (the plymouth package stays installed). Also `halcyon-plymouth.sh remove`." },
            { type: "toggle", key: "opt:todOn", def: false, label: "Time-of-day wallpaper", desc: "A soft colour wash over the wallpaper that follows the sun: blue at night, rose at dawn, clear around noon, amber in the golden hour, magenta at dusk. Your picture and the colours taken from it are not changed; switching this off gives the plain wallpaper back at once. It updates once a minute while it is on." },
            { type: "slider", adv: true, key: "opt:todStrength", def: 60, label: "Time-of-day strength", desc: "How strong the wash and the night dimming are. 100 % is full dusk orange and deep night blue.", min: 0, max: 100, step: 5, unit: " %", when: "opt:todOn=true" },
            { type: "action", id: "sky-open", label: "Weekly sky", btn: "Open it", done: "", desc: "Your week as stars: one for every focus session, every note you ticked off and every calendar event that has happened. Stars of one day are joined into a constellation. Save picture writes a PNG (or SVG) to ~/Pictures/Halcyon to share. Also `>weekly sky` and `halcyon weekly-sky`." }
        ] },
        { id: "greeting", title: "Terminal greeting", section: "Stars & splash", items: [
            { type: "seg", key: "gr:LOGO", label: "Logo in new terminals", desc: "Adaptive: the logo of the system you are on (Arch family, BlackArch or Kali; any other system gets a Linux penguin). Pick one to always show that logo instead. Custom: your own ASCII art (below). Info only: no logo, just the system lines. Off: no greeting. Applies to terminals you open from now on.", opts: [o("adaptive", "Adaptive"), o("arch", "Arch"), o("blackarch", "BlackArch"), o("kali", "Kali"), o("linux", "Linux"), o("custom", "Custom"), o("none", "Info only"), o("off", "Off")] },
            { type: "acts", label: "Your own ASCII art", desc: "Copy some ASCII art, then Paste from clipboard: it is saved and the greeting switches to Custom. Edit file opens it in your editor. Write @C1@ (accent colour) or @C2@ (grey) in the text to colour parts of it; colour codes that are already in the text keep working. Up to 40 rows. Preview shows the greeting in a terminal.", btns: [{ id: "greeting-paste", btn: "Paste from clipboard", done: "Saved" }, { id: "greeting-edit", btn: "Edit file", done: "", close: true }, { id: "greeting-preview", btn: "Preview", done: "" }] }
        ] },
        { id: "bar", title: "Bar", section: "Bar & panels", items: [
            { type: "seg", drop: true, key: "opt:barStyle", label: "Style", desc: "Island: the floating pill (default). Notch: a bar that hangs from the top edge of the screen with flared corners; workspaces on the left, time in the middle, Wi-Fi, Bluetooth and battery on the right. Rail: a strip along the whole edge (the Caelestia-style side bar) with an optional capsule behind every widget. Custom: you choose the shape (Notch, Island or Rail), what is on the bar, where it goes and how much padding it has (the rows below, and the Bar builder window). Off: no bar at all, put clock, workspaces, stats and the rest on the desktop as widgets (Widget builder); the launcher and the pages still open from the top edge. Everything else (pages, launcher, panels) works the same in all of them.", opts: [o("island", "Island"), o("notch", "Notch"), o("rail", "Rail"), o("custom", "Custom"), o("off", "Off")] },
            { type: "seg", drop: true, key: "bl:shape", label: "Shape", desc: "The shape of a Custom bar: Notch (hangs from the top edge, flared corners), Island (a floating pill) or Rail (a strip along an edge of the screen).", opts: [o("notch", "Notch"), o("island", "Island"), o("rail", "Rail")], when: "opt:barStyle=custom" },
            { type: "seg", drop: true, key: "bl:side", label: "Screen edge", desc: "Which edge of the screen the bar sits on. A bar that is not on the top edge leaves the top free: the pages and the launcher still hang from it.", opts: [o("top", "Top"), o("bottom", "Bottom"), o("left", "Left"), o("right", "Right")], when: "opt:barStyle=rail||opt:barStyle=custom" },
            { type: "seg", drop: true, key: "bl:rstyle", label: "Rail look", desc: "Capsules: a strip along the whole edge with a soft capsule per group. Floating pill: one detached, fully rounded rail. Bare icons: no background at all, the icons sit on the desktop. Split islands: three separate pills (top, middle, bottom).", opts: [o("capsules", "Capsules"), o("pill", "Floating pill"), o("bare", "Bare icons"), o("split", "Split islands")], when: "bl:isRail=true" },
            { type: "toggle", key: "bl:caps", label: "Capsule behind every widget", desc: "Only for the Capsules look: a soft capsule behind each group of widgets. Off: the strip alone.", when: "bl:isRail=true&bl:rstyle=capsules" },
            { type: "seg", drop: true, key: "bl:spMode", label: "Special workspaces", desc: "Beside: their own icons next to the workspaces (the old way). Over workspaces: shown on top of the workspaces, and only while one of them is open (SUPER+S ...).", opts: [o("bar", "Beside"), o("over", "Over workspaces")], when: "opt:barStyle=rail||opt:barStyle=custom" },
            { type: "seg", key: "barPadding", label: "Bar size and padding", desc: "How tall the bar is. Island: also how far it floats from the top edge and the space at its sides.", opts: [o("low", "Low"), o("normal", "Normal"), o("high", "High")] },
            { type: "seg", adv: true, key: "pair:spacing", label: "Bar spacing", desc: "Compact: everything close together. Spacious: roomier gaps and padding, with the time always dead centre. (Bar size and padding above is the bar's height and its distance from the edge.)", opts: [o("compact", "Compact"), o("spacious", "Spacious")] },
            { type: "custom", name: "barBuilder" }
        ] },
        { id: "barwidgets", title: "Bar contents", section: "Bar & panels", items: [
            { type: "chips", drop: true, label: "Show in the bar", desc: "Special icons: scratch, music, monitor ... (only the ones that exist). Music bars: only while something plays. Battery % needs the battery or the combined icon.", opts: [ch("pair:ws", "Workspaces", "opt:barStyle=island|notch"), ch("pair:specials", "Special icons", "opt:barStyle=island|notch"), ch("pair:viz", "Music bars", "opt:barStyle=island|notch"), ch("pair:wifi", "Wi-Fi", "opt:barStyle=island|notch"), ch("pair:bat", "Battery", "opt:barStyle=island|notch"), ch("pair:batPct", "Battery %"), ch("pair:caffeine", "Caffeine icon", "opt:barStyle=island|notch")] },
            { type: "seg", key: "opt:islWsLook", label: "Workspace look", desc: "Numbers: the island's own 1 2 3 ... with a sliding pill. Capsules: the notch look, small vertical capsules, the current one big and vivid.", opts: [o("numbers", "Numbers"), o("capsules", "Capsules")], when: "opt:barStyle=island" },
            { type: "toggle", key: "pair:combo", label: "Combined status icon", desc: "Wi-Fi, battery and Bluetooth in one round icon: Wi-Fi in the middle (lit by the signal), the battery as a ring around it, and a dot under it for each connected Bluetooth device. Off: three separate icons.", when: "opt:barStyle=island|notch" },
            { type: "seg", drop: true, adv: true, key: "pair:wsMin", label: "Capsules always shown", desc: "Workspaces 1 to N are always drawn as capsules (empty ones dim, ones with windows faded, the current one big and vivid). More show up when you use them. The notch always draws capsules; the island only with the capsule look.", opts: [o(3, "3"), o(4, "4"), o(5, "5"), o(6, "6"), o(8, "8")] },
            { type: "seg", adv: true, key: "opt:notchSpecialsSide", label: "Special icons side", desc: "Auto: when the clock is kept centred, the icons go to whichever side has free room, so the bar does not grow. Left / Right: always that side of the clock.", opts: [o("auto", "Auto"), o("left", "Left"), o("right", "Right")], when: "opt:barStyle=notch&pair:specials=true" },
            { type: "seg", adv: true, key: "opt:viz", label: "Music bars quality", desc: "Full: the six bars move at 30 fps. Light: the same bars at 15 fps, about half the work. Off: the bars stay flat and the visualizer program (cava) is not started. Applies at once.", opts: [o("full", "Full"), o("light", "Light"), o("off", "Off")] },
            { type: "seg", adv: true, key: "pair:wifiStyle", label: "Wi-Fi look", desc: "Symbol is the classic icon. Bars and dots light up with the signal strength. (Not used by the combined icon.)", opts: [o("symbol", "Symbol"), o("bars", "Bars"), o("dots", "Dots")], when: "pair:combo=false||opt:barStyle=custom||opt:barStyle=rail" },
            { type: "seg", adv: true, key: "pair:bt", label: "Bluetooth", desc: "Connected: only while a device is connected. Always: whenever Bluetooth is on. In the combined icon these are the dots under the ring.", opts: [o("off", "Never"), o("connected", "When connected"), o("on", "Always")] },
            { type: "seg", adv: true, key: "opt:notchAccent", label: "Notch accent colour", desc: "Colour of the workspace capsules, Wi-Fi, Bluetooth and battery. Vivid: the wallpaper's accent made clearer and more saturated. Theme: the same soft accent as the island. Second: the wallpaper's second colour.", opts: [o("vivid", "Vivid"), o("theme", "Theme"), o("accent2", "Second")], when: "opt:barStyle=notch|custom|rail" },
            { type: "seg", adv: true, key: "opt:bgWhere", label: "Background apps dot", desc: "Where the dot that says apps are running in the background is shown. The box with the apps opens bottom-left (on the bar, click the icon to open it); on a rail the icon above the clock opens it as a menu next to the rail instead.", opts: [o("corner", "Corner"), o("bar", "Bar")] }
        ] },
        { id: "frame", title: "Screen border", section: "Bar & panels", items: [
            { type: "toggle", key: "opt:frame", label: "Border around the screen", desc: "A frame all around the screen, in the same colour as the bar. The Notch bar and the pages that drop from it are part of its top edge, and the notifications, utilities box, console, app menu and the other boxes slide out from under it. Windows stop at its inner edge." },
            { type: "slider", key: "opt:frameW", def: 12, label: "Border thickness", min: 4, max: 28, step: 1, unit: " px", when: "opt:frame=true" },
            { type: "slider", key: "opt:frameR", def: 22, label: "Border inner corners", desc: "How round the screen's corners are inside the border.", min: 0, max: 40, step: 1, unit: " px", when: "opt:frame=true" }
        ] },
        { id: "barbehave", title: "Bar behaviour", section: "Bar & panels", items: [
            { type: "seg", key: "opt:dropDown", label: "Drag the bar down", desc: "Pull the bar down (or use the little handle under the open page) to get the utilities box inside the bar. Swipe pages: the notifications are the next page to the right. Swipe sideways, tap the arrows or the tabs, or press Left / Right (click the box once first). Side by side: the notifications sit next to the utilities box. Drag up, or tap the handle, to go back. While this is on, the corner utilities box and the right-edge notification box are switched off. Off: the boxes stay in their corners.", opts: [o("off", "Off"), o("stack", "Swipe pages"), o("side", "Side by side")] },
            { type: "toggle", key: "autoHide", label: "Auto-hide the bar" },
            { type: "seg", drop: true, key: "hoverAction", label: "When you hover the bar", desc: "Stats: CPU, memory and temperature slide out. Performance / Media: that page opens by itself.", opts: [o("none", "Nothing"), o("stats", "Live stats"), o("perf", "Performance"), o("media", "Media")] },
            { type: "seg", adv: true, key: "barScroll", label: "Scroll / swipe on the bar to change page", opts: [o("low", "Long swipe"), o("medium", "Medium"), o("high", "Sensitive")] },
            { type: "seg", adv: true, drop: true, key: "opt:scrollLinger", label: "Page stays after scrolling", desc: "When you open the performance / media page by scrolling or two-finger swiping the bar, how long it stays after the pointer leaves the bar.", opts: [o(1500, "Short"), o(3000, "Normal"), o(6000, "Long"), o(12000, "Very long")] },
            { type: "seg", drop: true, key: "opt:perfLook", label: "Performance tab look", desc: "How the Performance tab is drawn, on every bar (rail dashboard, island and notch page). Auto: Sky beside a rail, Classic on the island and the notch. Classic: rings, spec rows and disk bars. Sky: a constellation, every part a star, the battery is Halcyon's star. Orbit: four rings round one centre. Pulse: five lanes with a glowing wave each, the battery a tank of light. Tiles: a bento of soft tiles, a gauge, blocks, a dot ring, a donut and two network waves. Sea: a calm sea with a buoy for each part, a sun on the light theme and a moon and stars on the dark one (also the battery). Forecast: one short sentence (All calm, Getting busy, Running hot), the temperature and five tiles with a bar each. Radar: a pentagon of the five parts with the last minute's average as a dashed shape behind it. Cockpit: instruments, a big CPU dial with a temperature arc, four small rings and a row of indicator lamps. Recorder: the last five minutes on one graph, with the power and sysmode changes marked; rest the pointer on it to read the values. Editorial: one huge number, the load of the busiest part, with a quiet table of the rest beside it. Stars: six live four-point stars that drift and twinkle, brighter and bigger with more load, dimmer with less. Same numbers in all of them.", opts: [o("auto", "Auto"), o("sky", "Sky"), o("orbit", "Orbit"), o("pulse", "Pulse"), o("tiles", "Tiles"), o("sea", "Sea"), o("forecast", "Forecast"), o("radar", "Radar"), o("cockpit", "Cockpit"), o("recorder", "Recorder"), o("editorial", "Editorial"), o("stars", "Stars"), o("classic", "Classic")] },
            { type: "seg", adv: true, drop: true, key: "opt:pageClose", label: "Performance / media page closes", desc: "How long the page stays after the pointer leaves the bar. Instant folds back at once.", opts: [o(150, "Instant"), o(600, "Fast"), o(1500, "Normal"), o(4000, "Slow")], when: "hoverAction=perf|media" },
        ] },
        { id: "clock", title: "Clock", section: "Bar & panels", items: [
            { type: "seg", key: "clock24", label: "Time format", opts: [o(false, "12 hour"), o(true, "24 hour")] },
            { type: "chips", label: "Show in the clock", desc: "Time and date are separate: show either, both or neither. Seconds: middle-click the time in the bar. Right-click it to switch 12 / 24 hour.", opts: [ch("pair:time", "Time"), ch("pair:date", "Day and date"), ch("opt:clockSeconds", "Seconds")] },
            { type: "seg", adv: true, key: "opt:clockAlign", label: "Centre the", desc: "Colon: the \":\" sits exactly on the screen's centre line (over a centre webcam). Whole text: the time including AM / PM is centred.", opts: [o("colon", "Colon"), o("text", "Whole text")] },
            { type: "seg", adv: true, key: "opt:clockNudge", label: "Nudge the clock", desc: "Extra pixels to the right (or left) on top of the above, for a screen or webcam that sits a little off.", opts: [o(-4, "4 left"), o(-2, "2 left"), o(0, "None"), o(2, "2 right"), o(4, "4 right"), o(6, "6 right")] }
        ] },
        { id: "notifications", title: "Notifications", section: "Bar & panels", items: [
            { type: "chips", label: "Quiet", desc: "Do not disturb: no popups, everything is still kept in the centre. Errors only: Wi-Fi and Bluetooth only tell you when connecting fails (wrong password, device out of range ...).", opts: [ch("dnd", "Do not disturb"), ch("opt:connErrOnly", "Wi-Fi & Bluetooth: errors only")] },
            { type: "chips", label: "Wi-Fi details", desc: "While a Wi-Fi network connects, the utilities box lists each step as it happens: finding the network, authenticating, asking the router for an IP address, the gateway and DNS you got, and whether the internet is reachable. A failure says why (wrong password, out of range, no IP).", opts: [ch("opt:wifiVerbose", "Show each connection step")] },
            { type: "seg", adv: true, key: "opt:notifSpot", label: "Notification trigger spot", desc: "Where you touch (or click) to open the notification centre. Right edge: a strip on the right edge of the screen, upper part. Top-right corner: a small spot in the very corner. The centre itself slides out in the same place either way. Hover or click: see Edge boxes below.", opts: [o("edge", "Right edge"), o("corner", "Top-right corner")] },
            { type: "seg", key: "opt:notifStyle", label: "Notification style", desc: "How the notification centre lists what you got. Stack: one card each. Timeline: a thin rail with a dot per notification, under Just now / Earlier today / Yesterday. Grouped by app: one card per app with its notifications inside.", opts: [o("stack", "Stack"), o("timeline", "Timeline"), o("grouped", "Grouped by app")] },
            { type: "custom", name: "notifBuilder" },
            { type: "seg", adv: true, key: "opt:notifIcon", label: "Notification picture", desc: "Profile picture: your picture, with the app's icon as a small badge. App icon: only the app's own icon. No profile picture found? The app icon is used.", opts: [o("pfp", "Profile picture"), o("app", "App icon")] },
            { type: "seg", adv: true, key: "notifMax", label: "Popups on screen at once", desc: "When it is full the oldest goes.", opts: [o(1, "1"), o(2, "2"), o(3, "3"), o(5, "5"), o(8, "8")] },
            { type: "seg", adv: true, key: "opt:toastSecs", label: "How long a popup stays", desc: "Urgent ones follow their own setting below.", opts: [o(0, "App decides"), o(3, "3 s"), o(5, "5 s"), o(8, "8 s"), o(12, "12 s")] },
            { type: "seg", adv: true, key: "opt:critSecs", label: "Urgent popups", desc: "Browsers and some apps mark a notification urgent so it would stay for ever. It now hides after this long; it always stays in the notification centre until you remove it.", opts: [o(15, "15 s"), o(30, "30 s"), o(60, "1 min"), o(0, "Wait for a click")] },
            { type: "toggle", key: "opt:dndFullscreen", label: "Quiet while a window is fullscreen", desc: "Popups stay away while a video, game or presentation is fullscreen; they are still kept in the notification centre. Halcyon's own timers and reminders still show, and so do urgent ones. Do not disturb itself is not touched." },
            { type: "seg", adv: true, key: "notifHistoryMax", label: "Notifications the centre keeps", opts: [o(10, "10"), o(20, "20"), o(30, "30"), o(50, "50"), o(100, "100")] },
        ] },
        { id: "osd", title: "Edge boxes & volume bar", section: "Bar & panels", items: [
            { type: "seg", key: "clickMode", label: "Edge boxes (notifications, console, utilities)", opts: [o(false, "Hover"), o(true, "Click")] },
            { type: "toggle", key: "osdOn", label: "Volume / brightness bar", desc: "Slides up from the bottom whenever volume, brightness or the keyboard light changes." },
            { type: "seg", key: "opt:osdHold", label: "How long that bar stays", opts: [o(1000, "Short"), o(1700, "Normal"), o(3000, "Long")], when: "osdOn=true" },
        ] },
        { id: "utilbox", title: "Utilities box", section: "Bar & panels", items: [
            { type: "seg", key: "opt:utilStyle", label: "Utilities box layout", desc: "Tiles: icon tiles, a connected Wi-Fi shows its signal as five stars, Bluetooth its battery, the hotspot its devices. Split: two tall sliders (volume, brightness) beside round buttons. Classic: the old pills with words. Power modes are icons in the first two; hover one for its name.", opts: [o("tiles", "Tiles"), o("split", "Split"), o("classic", "Classic")] },
            { type: "seg", adv: true, key: "opt:utilBtShow", label: "Bluetooth tile shows", desc: "For the connected device: its battery as five stars, or as a percentage.", opts: [o("stars", "Stars"), o("percent", "Percent")], when: "opt:utilStyle=tiles|undefined" },
            { type: "chips", label: "Take out of the box", desc: "Switch a thing ON to remove it from the utilities box (bottom-right corner, and the box that drops out of the bar). Switch it OFF to bring it back. Nothing is switched off, only hidden: Wi-Fi, Bluetooth, caffeine, recording and the rest still work from their shortcuts and the Settings. The Settings button and the power button stay, so you can always get back here.", opts: [ch("opt:uHideWifi", "Wi-Fi"), ch("opt:uHideBt", "Bluetooth"), ch("opt:uHideAudio", "Sound output"), ch("opt:uHideHotspot", "Hotspot"), ch("opt:uHideAirplane", "Airplane"), ch("opt:uHideCharge", "Charge limit (laptops)"), ch("opt:uHideMic", "Microphone"), ch("opt:uHideVolume", "Volume slider"), ch("opt:uHideBright", "Brightness slider"), ch("opt:uHideExtraDim", "Extra dim"), ch("opt:uHidePower", "Power mode"), ch("opt:uHideCaffeine", "Caffeine"), ch("opt:uHideRecord", "Record"), ch("opt:uHideFocus", "Focus")] }
        ] },
        { id: "desktop", title: "Desktop builder", section: "Desktop", items: [
            { type: "custom", name: "desktopBuilder" }
        ] },
        { id: "widgets", title: "Widget builder", section: "Desktop", items: [
            { type: "seg", key: "opt:widgetDim", label: "Dim the wallpaper", desc: "Darkens the wallpaper so your desktop widgets stay readable on light or busy pictures. Whole wallpaper: evenly everywhere (the default). Behind widgets only: a soft shade where a widget sits on a bright or busy part (Auto) or behind every widget; the rest of the picture keeps its full brightness, but neighbouring widgets can look uneven. The text colour follows the shade.", opts: [o("off", "Off"), o("wall", "Whole wallpaper"), o("auto", "Behind widgets: auto"), o("widgets", "Behind every widget")] },
            { type: "slider", key: "opt:widgetDimAmt", def: 0.35, label: "How dark", min: 0.1, max: 0.8, step: 0.05, scale: 100, unit: " %", when: "opt:widgetDim=auto|widgets|wall" },
            { type: "toggle", key: "opt:widgetHalo", label: "Soft halo behind widget text", desc: "A faint dark glow behind the words of box-less desktop widgets, only where the wallpaper behind them is busy. Off = never, for every widget." },
            { type: "slider", key: "opt:widgetReadability", label: "Widget text readability", desc: "Added to every widget's own Readability setting: a stronger outline and a lighter text colour. 0 = each widget as you set it.", min: -30, max: 40, step: 5, def: 0, unit: " %", glyph: 0xF0A39 },
            { type: "custom", name: "widgetBuilder" }
        ] },
        { id: "workspaces", title: "Workspaces & windows", section: "Desktop", items: [
            { type: "seg", key: "opt:tilingLayout", label: "Tiling layout", desc: "Dwindle: automatic binary tree tiling. Scrolling: horizontal column ribbon (Niri style). Off: every window floats freely at its own size (no tiling).", opts: [o("dwindle", "Dwindle"), o("scrolling", "Scrolling"), o("off", "Off (floating)")] },
            { type: "seg", key: "opt:windowMode", label: "Halcyon windows", desc: "Overlay: Luna and the other windows open above everything with a dimmed backdrop. Desktop: they open as ordinary windows on the workspace, next to your apps (tiled or floating, as you chose above). Applies the next time a window opens.", opts: [o("overlay", "Overlay"), o("desktop", "On the desktop")] },
            { type: "chips", label: "Behaviour", desc: "Compact: empty workspace gaps are automatically closed with smooth animations (windows move to fill free lower workspaces). Compact special: scratch / music / communication / monitor / tasks windows are smaller. Jump: go to a window that asks for attention. Send: Spotify / Discord open on their own workspace. Show: bring that workspace into view when one opens (off = it moves quietly).", opts: [ch("compactWs", "Keep workspaces compact"), ch("compactSpecial", "Compact special workspaces"), ch("hy:focusOnActivate", "Jump to a window that asks for attention"), ch("routeApps", "Send Spotify / Discord to their workspace"), ch("routeShow", "Show that workspace when the app opens")] },
            { type: "seg", adv: true, key: "opt:wsEnd", label: "Next workspace, from the last one", desc: "With workspaces 1 and 2, going next from 2 opens a new workspace 3 (never from an empty one).", opts: [o("new", "Open a new one"), o("wrap", "Go back to 1"), o("stay", "Stay")] },
            { type: "seg", adv: true, key: "opt:wsStart", label: "Previous workspace, from the first one", desc: "Wrap: from 1 you land on the highest workspace.", opts: [o("wrap", "Jump to the last"), o("stay", "Stay")] },
            { type: "seg", adv: true, key: "opt:wsMax", label: "Never open more than", opts: [o(3, "3"), o(4, "4"), o(5, "5"), o(6, "6"), o(9, "9"), o(10, "10")] },
            { type: "toggle", adv: true, key: "opt:wsInvert", label: "Invert workspace scrolling", desc: "Flips the direction when you scroll through workspaces with the mouse wheel / two-finger scroll over the workspace numbers in the bar (the 4 finger swipe has its own option above). Off: scroll down / swipe right = next workspace.", },
            { type: "custom", adv: true, name: "specialCmds" }
        ] },
        { id: "focus", title: "Focus mode", section: "Productivity", items: [
            { type: "custom", name: "focusClock" },
            { type: "seg", key: "fc:LENGTH", label: "Session length", desc: "Start it from the utilities box (bottom-right corner, Focus) or SUPER+ALT+F. A timer runs, Do not disturb is on and the apps below are kept closed. When it ends everything goes back to how it was.", opts: [o(15, "15"), o(25, "25"), o(45, "45"), o(50, "50"), o(60, "60"), o(90, "90")] },
            { type: "chips", label: "While focusing", desc: "Pomodoro: work, a short break, work again ... with a long break after the last round (a reminder at every change, even with Do not disturb on). Do not disturb: popups muted, urgent ones get through. Awake: no dimming, lock or sleep. Close blocked apps: windows of the apps in the list below are closed the moment they open (a normal close request, never a kill).", opts: [ch("fc:POMODORO", "Pomodoro"), ch("fc:DND", "Do not disturb"), ch("fc:CAFFEINE", "Keep the screen awake"), ch("fc:BLOCK", "Close blocked apps")] },
            { type: "seg", key: "fc:BREAK", label: "Short break (minutes)", opts: [o(3, "3"), o(5, "5"), o(10, "10")], when: "fc:POMODORO=true" },
            { type: "seg", key: "fc:LONG_BREAK", label: "Long break (minutes)", opts: [o(10, "10"), o(15, "15"), o(20, "20"), o(30, "30")], when: "fc:POMODORO=true" },
            { type: "seg", key: "fc:CYCLES", label: "Rounds", opts: [o(2, "2"), o(3, "3"), o(4, "4"), o(6, "6")], when: "fc:POMODORO=true" },
            { type: "toggle", adv: true, key: "fc:CLOSE_RUNNING", label: "Also close the ones already open", desc: "When a session starts. Off: only apps opened during the session are closed.", when: "fc:BLOCK=true" },
            { type: "toggle", adv: true, key: "fc:BREAK_FREE", label: "Allow blocked apps in breaks", desc: "Pomodoro breaks and Pause lift the block.", when: "fc:BLOCK=true&fc:POMODORO=true" },
            { type: "custom", name: "focusApps" }
        ] },
        { id: "calendar", title: "Calendar", section: "Productivity", items: [
            { type: "toggle", key: "opt:calOn", label: "Calendar", desc: "Master switch. Off: Super + R, the clock click, the reminders, nagging and auto Focus mode are all off and nothing is synced. Connect your Google Calendar once from the calendar itself (Super + R)." },
            { type: "toggle", key: "opt:calClock", label: "Clock click", desc: "A left click on the time in the bar drops the calendar out of the bar (the pill in the island style, the notch in the notch style). Off: the click does what it did before. Click the time again to close it.", when: "opt:calOn=true" },
            { type: "toggle", key: "opt:calNotify", label: "Reminder notifications", desc: "A notification before an event starts and when it starts. When they come is set in the calendar itself (Super + R, the gear). Nagging below needs this on.", when: "opt:calOn=true" },
            { type: "seg", adv: true, key: "opt:calTasks", label: "What counts as a task", desc: "A task can be nagged and can start Focus mode. Events I mark: press Task on an event's row, then tick it off with the round check when you have done it. Every event: all timed events are tasks.", opts: [o("marked", "Events I mark"), o("all", "Every event")], when: "opt:calOn=true" },
            { type: "toggle", key: "opt:calFocus", label: "Auto Focus mode", desc: "When a task starts, Focus mode starts by itself and lasts until the task ends (Focus mode settings above: Do not disturb, blocked apps ...). Ticking the task off early ends it. It never touches a session you started yourself, and events shorter than 10 minutes are skipped.", when: "opt:calOn=true" },
            { type: "toggle", key: "opt:calNag", label: "Keep reminding until it is done", desc: "From the moment a task starts you get an urgent notification again and again, each replacing the last, until you press Done on it or tick the task off in the calendar. It is only a notification: nothing is blocked.", when: "opt:calOn=true&opt:calNotify=true" },
            { type: "seg", adv: true, key: "opt:calNagEvery", label: "Nag every", opts: [o(2, "2 min"), o(5, "5 min"), o(10, "10 min"), o(15, "15 min"), o(30, "30 min")], when: "opt:calOn=true&opt:calNotify=true&opt:calNag=true" },
            { type: "seg", adv: true, key: "opt:calNagGiveUp", label: "Give up", desc: "How long after the task has ended it still nags.", opts: [o(60, "After 1 h"), o(180, "After 3 h"), o(720, "After 12 h"), o(4320, "After 3 days")], when: "opt:calOn=true&opt:calNotify=true&opt:calNag=true" }
        ] },
        { id: "notes", title: "Notes", section: "Productivity", items: [
            { type: "custom", name: "voiceKey", label: "Voice note hotkey" },
            { type: "toggle", adv: true, soft: true, when: "ai:enabled=true", key: "nt:NOTES_SUMMARY", label: "Full summary of long notes", desc: "A note of 150 words or more gets a full summary under it by itself: one sentence with the main point and then every important point as its own line. It has no length limit (a very long note is read in pieces and nothing is cut off), and every line is checked against the note, so a line the note does not support is left out. The short Overview is separate. For any note, press Summarise on its row." },
            { type: "toggle", soft: true, key: "nt:NOTES_OCR", label: "Read the text in pictures", desc: "A picture you paste into a note is read in the background with tesseract (offline, on this computer): the text in it shows under the picture, can be copied, and is found by the search box. It only copies what is there, it cannot invent anything. Needs: sudo pacman -S tesseract tesseract-data-eng" },
            { type: "toggle", soft: true, when: "ai:enabled=true", key: "nt:NOTES_VLM", label: "Describe pictures (vision model)", desc: "Adds a Describe button to picture notes: a local vision model in Ollama writes one or two sentences about the picture. Only when you press it, never by itself; the model is unloaded right after. Small models can be wrong, so a sentence with a number that is not in the picture's own text is dropped. Install it once with: ollama pull qwen2.5vl:3b (another one: notes set NOTES_VLM_MODEL name)." },
            { type: "toggle", soft: true, when: "ai:enabled=true", key: "nt:NOTES_OVERVIEW", label: "AI overview under every note", desc: "In the background your local Ollama model writes a short overview under each note you save, task or not: one sentence for a short note, a short intro and a few bullet points for a longer one (a pasted article, say). The Think button on a note writes it again. Nothing is sent anywhere (the model runs on this PC); if Ollama is not running the note is simply saved. Off by default." },
            { type: "toggle", soft: true, when: "ai:enabled=true", key: "nt:NOTES_AI", label: "Sort new notes into tasks", desc: "Super + N saves a note at once, as always. In the background your local Ollama model then decides whether it is a task: \"call mom at 6\" becomes a task due 18:00, \"idea: dark theme for the lock screen\" stays a plain note. The model's short comment (what it decided and why) shows right under the note in the All notes window, and Think on a note asks it again. Tasks show under Tasks, and a task with a time sends a notification when it is due. Off by default; nothing is sent anywhere (the model runs on this PC) and if Ollama is not running the note is simply saved." },
            { type: "seg", adv: true, key: "nt:NOTES_AI_MODE", label: "When the model thinks it is a task", desc: "Ask me: the note shows \"Make task / Keep as note\" in the All notes window. Automatically: it just becomes a task (you can turn it back with Note on its row).", opts: [o("ask", "Ask me first"), o("auto", "Do it automatically")], when: "ai:enabled=true&nt:NOTES_AI=true" },
            { type: "seg", adv: true, key: "nt:NOTES_NUDGE_HOURS", label: "Later today: nudge every", desc: "Press Remind > Later today on a task (or the AI sees \"later\" in a note) and Halcyon sends a quiet notification every few hours during the rest of that day, until you tick the task off, it has nudged the most times below, or the day ends. Nothing at night (09:00 to 21:00 by default; change it with: notes set NOTES_NUDGE_FROM / NOTES_NUDGE_TO). It never nags: a task that is done or deleted is left alone.", opts: [o("1", "1 h"), o("2", "2 h"), o("3", "3 h"), o("4", "4 h"), o("6", "6 h")] },
            { type: "seg", adv: true, key: "nt:NOTES_NUDGE_MAX", label: "Later today: at most", desc: "The most nudges one task gets in a day.", opts: [o("2", "2"), o("3", "3"), o("4", "4"), o("6", "6")] }
        ] },
        { id: "recording", title: "Screen & audio recording", section: "Productivity", items: [
            { type: "seg", key: "opt:recKind", label: "What to record", desc: "Screen: a video of the whole screen. Audio only: just sound, saved as an .m4a file. Start and stop with Super + Alt + R, the Record button in the utilities box, or the button below.", opts: [o("screen", "Screen video"), o("audio", "Audio only")] },
            { type: "seg", key: "opt:recAudio", label: "Sound", desc: "Desktop sound is whatever you hear (music, calls, videos). Microphone is the default microphone. Both mixes the two into one track. Sound is recorded with ffmpeg and joined to the video when you stop, so it needs ffmpeg and PipeWire (or PulseAudio).", opts: [o("none", "None"), o("system", "Desktop sound"), o("mic", "Microphone"), o("both", "Both")], when: "opt:recKind=screen" },
            { type: "seg", key: "opt:recAudio", label: "Sound source", desc: "Desktop sound is whatever you hear (music, calls, videos). Microphone is the default microphone. Both mixes the two into one track. Needs ffmpeg and PipeWire (or PulseAudio).", opts: [o("system", "Desktop sound"), o("mic", "Microphone"), o("both", "Both")], when: "opt:recKind=audio" },
            { type: "acts", label: "Recordings", desc: "Everything is saved in ~/Videos/Recordings (video as recording_<date>.mp4, sound as audio_<date>.m4a). A different folder: write its path in ~/.local/state/island/rec-dir. A change here applies from the next recording; one that is running is not touched.", btns: [{ id: "rec-toggle", btn: "Start / stop", done: "" }, { id: "rec-last", btn: "Play the latest", done: "" }, { id: "rec-open", btn: "Open the folder", done: "" }] }
        ] },
        { id: "ai", title: "AI helpers", section: "Productivity", items: [
            { type: "toggle", key: "ai:enabled", def: true, label: "AI features", desc: "The master switch for everything that asks a local AI model: the notes overview, task sorting and Organise, the `ai` chat, >ask and >do in the launcher, the clipboard and lyrics helpers, the error explainer, the AI / LLM advisor and the model list below. Off: none of it runs and nothing asks Ollama anything; your notes, settings and downloaded models stay as they are. Ollama itself is not stopped (other programs may use it)." },
            { type: "custom", name: "aiModel", when: "ai:enabled=true", label: "AI advisor model" },
            { type: "toggle", key: "opt:aiBriefCard", def: true, label: "Daily brief card", desc: "Once a day, the first time you use the desktop, a notification sums up your tasks (what is overdue and due today), your notes and your Focus streak. The local AI words it; with AI off it is written plainly from the same facts. The same brief is a desktop widget too (Widget builder > Daily brief). Terminal: halcyon ai brief." },
            { type: "toggle", key: "opt:unusedRemind", def: true, label: "Monthly unused-apps reminder", desc: "Once a month, a notification when there are programs or background services you have not used for 30 days (Startup & processes > Unused has the list). Nothing is removed by itself." },
            { type: "toggle", key: "opt:aiExplain", def: true, when: "ai:enabled=true", label: "Explain errors", desc: "When a Halcyon service fails, or the island logs a new QML error, the local AI reads the log (and the code at that line) and a notification says what went wrong and the likely fix. Each error is explained once. Nothing leaves this computer. Any time: halcyon ai explain last, and halcyon ai explain show for the full last answer." },
        ] },
        { id: "mouse", title: "Mouse & touchpad", section: "Input & power", items: [
            { type: "slider", key: "scrollMouse", label: "Mouse wheel scroll speed", desc: "In every app. Higher is faster.", min: 0.25, max: 3, step: 0.05, dec: 2, unit: "×", glyph: 0xF037D },
            { type: "slider", key: "hy:sensitivity", def: 0, label: "Pointer speed", min: -1, max: 1, step: 0.1, dec: 1, signed: true },
            { type: "tool", key: "touchpad", label: "Touchpad" },
            { type: "chips", label: "Touchpad behaviour", desc: "", opts: [ch("hy:naturalScroll", "Natural scrolling"), ch("hy:tapToClick", "Tap to click"), ch("hy:disableTyping", "Pause while typing")] },
            { type: "slider", key: "scrollTouch", label: "Touchpad scroll speed", min: 0.1, max: 1.5, step: 0.05, dec: 2, unit: "×", glyph: 0xF037D },
            { type: "seg", adv: true, key: "hy:accelProfile", label: "Pointer acceleration", desc: "Flat = the pointer moves exactly as far as your hand does.", opts: [o("adaptive", "Adaptive"), o("flat", "Flat")] },
            { type: "toggle", adv: true, key: "hy:leftHanded", label: "Left-handed buttons" },
            { type: "seg", adv: true, key: "hy:followMouse", label: "Focus follows the pointer", opts: [o(0, "Click to focus"), o(1, "Hover"), o(2, "Hover, no raise")] },
            { type: "toggle", adv: true, key: "st:GESTURES", label: "Edge gestures", desc: "Slide along a touchpad edge: right = volume, top = brightness, left = previous / next track. Off stops the helper at once (and it stays off after login); the normal touchpad keeps working. SUPER+ALT+G only mutes them for a moment." },
        ] },
        { id: "keyboard", title: "Keyboard & launcher", section: "Input & power", items: [
            { type: "toggle", key: "superTap", label: "Tap Super to open the launcher" },
            { type: "seg", key: "opt:launchSpeed", label: "Launcher speed", desc: "How fast the launcher grows out of the bar. Tapping Super opens it when the key comes UP: the desktop cannot tell a lone tap from the start of Super+T until then, so opening on the press would make every Super shortcut flash the launcher. What can be cut is the animation after that: Quick is about half the time, Instant is a short snap.", opts: [o("normal", "Normal"), o("quick", "Quick"), o("instant", "Instant")], when: "superTap=true" },
            { type: "slider", adv: true, key: "hy:repeatDelay", def: 600, label: "Key repeat delay", min: 150, max: 800, step: 10, unit: " ms" },
            { type: "slider", adv: true, key: "hy:repeatRate", def: 25, label: "Key repeat speed", min: 5, max: 70, step: 1, unit: "/s" }
        ] },
        // btn = words the search should find (these two groups are one custom editor each),
        { id: "gestures", title: "Touchpad gestures", section: "Input & power", items: [
            { type: "custom", name: "gestures", btn: "swipe pinch three four fingers 3 4 finger multitouch workspace" }
        ] },
        { id: "mousebtn", title: "Mouse buttons", section: "Input & power", items: [
            { type: "custom", name: "mouseButtons", btn: "mouse back forward side button middle click extra thumb gaming" }
        ] },
        { id: "power", title: "Power & sleep", section: "Input & power", items: [
            { type: "seg", key: "powerMgr", label: "Power manager", desc: "Which program controls CPU power. Only one runs at a time; the others are stopped. Halcyon Auto drives power-profiles-daemon by itself.", opts: [o("halcyon", "Halcyon Auto"), o("power-profiles-daemon", "power-profiles-daemon"), o("tlp", "TLP"), o("auto-cpufreq", "auto-cpufreq"), o("tuned", "Tuned")] },
            { type: "seg", key: "idleDim", label: "Dim the screen and keyboard light after", opts: [o(0, "Never"), o(1, "1 min"), o(2, "2 min"), o(3, "3 min"), o(5, "5 min"), o(10, "10 min")] },
            { type: "seg", key: "idleLock", label: "Lock the screen after", opts: [o(0, "Never"), o(2, "2 min"), o(5, "5 min"), o(10, "10 min"), o(15, "15 min"), o(30, "30 min")] },
            { type: "seg", key: "idleSleep", label: "Go to sleep after", desc: "Counted from when you last touched the computer. Caffeine stops all three. Needs hypridle.", opts: [o(0, "Never"), o(15, "15 min"), o(30, "30 min"), o(60, "1 h"), o(120, "2 h"), o(240, "4 h")] },
            { type: "tool", adv: true, key: "wifips", label: "Wi-Fi power saving", desc: "On saves battery. Off gives the lowest latency (Gaming mode switches it off by itself)." }
        ] },
        { id: "lockscreen", title: "Lock screen", section: "Input & power", items: [
            { type: "seg", key: "opt:lockMode", label: "After sleep: what you see", desc: "Login-screen look: the same screen as the login manager, with NO widgets. Lock screen: the full lock screen, where your widgets, the media card, Wi-Fi and battery can show. Widgets only ever exist on the lock screen.", opts: [o("lock", "Lock screen"), o("login", "Login-screen look")] },
            { type: "seg", key: "opt:lockBg", label: "Lock screen background", desc: "Halcyon sky: the splash's stars keep drifting behind the clock, so the login splash flows straight into the lock screen. Solid: the plain colour of your theme. Blurred wallpaper: your current wallpaper, blurred, behind the clock and the password box. The wallpaper is only loaded while the screen is locked and let go when you unlock. If the picture cannot be read, the plain colour stays; the password box is never affected.", opts: [o("solid", "Solid colour"), o("wallpaper", "Blurred wallpaper"), o("sky", "Halcyon sky")] },
            { type: "slider", adv: true, key: "opt:lockBlur", def: 40, label: "Lock screen blur", desc: "How strongly the wallpaper is blurred.", min: 4, max: 64, step: 2, unit: "", when: "opt:lockBg=wallpaper" },
            { type: "slider", adv: true, key: "opt:lockTint", def: 0.55, label: "Lock screen tint", desc: "How much of the theme colour covers the wallpaper. 0 % = the wallpaper as it is, 100 % = no wallpaper visible.", min: 0, max: 0.95, step: 0.05, scale: 100, unit: " %", when: "opt:lockBg=wallpaper" },
            { type: "toggle", key: "opt:starsLock", def: true, label: "Constellation on the lock and login screens", desc: "Your picture as stars, the drifting dots and the moving stars behind the clock. One switch for both screens: off here turns them off on the lock screen AND the login screen." },
            { type: "toggle", key: "opt:lockWidgets", def: false, when: "opt:lockMode=lock|undefined", label: "Lock screen widgets", desc: "(Lock screen only: not on the login-screen look or the login manager.) Show the battery, the Wi-Fi name, how many notifications are waiting (only the number, never what they say) and a media card with previous / play / next on the lock screen. Off: just the clock and the password. Your own widgets for this screen (clock styles, system usage, weather ...): Widget builder > Lock screen." },
            { type: "toggle", adv: true, key: "opt:lockSwitch", def: false, when: "opt:lockMode=lock|undefined", label: "Switch user button", desc: "(Lock screen only.) A Switch user button on the lock screen: jump to another user who is already logged in, or open a login screen for someone else. This screen stays locked while you are away, and needs your password when you come back." },
            { type: "toggle", key: "opt:splash", def: true, label: "Splash animation", desc: "The master switch for every splash (moving stars and the Halcyon sparkle): on the lock screen, at login, on unlock and on shutdown. Off = none of them play. Each one also has its own switch below and in Appearance > Splash, sky & time of day. Never shown when motion is switched off (Gaming mode). The boot splash (Plymouth) is separate: Appearance > Splash, sky & time of day." },
            { type: "toggle", key: "opt:splashLock", def: true, label: "Splash on the lock screen", desc: "About 3.5 seconds on the lock screen when it is also your login screen (Lock screen > lock screen as login). The screen is already locked while it plays, and a click or any key skips it.", when: "opt:splash=true" },
            { type: "toggle", adv: true, key: "opt:splashStart", def: true, label: "Splash at login (no lock-screen login)", desc: "For people who log in through a login manager (sddm, gdm ...): play the splash once when the desktop starts, not again when the island is restarted. Not played in Gaming mode or when motion is off.", when: "opt:splash=true" },
            { type: "action", id: "splash-preview", label: "Splash", btn: "Play it now", done: "", desc: "Plays the splash once, full screen. A click, Esc or any key ends it. Also `halcyon splash`." },
        ] },
        { id: "loginscreen", title: "Login screen", section: "Input & power", items: [
            { type: "seg", key: "opt:loginMode", label: "At boot: how you log in", desc: "Halcyon login manager: greetd + Halcyon's own login screen (pretty, locked down, NO widgets). Auto-login + lock screen: tty1 logs you in and Halcyon starts locked (the lock screen can show widgets). Pick one, then press Apply. Takes effect at the next boot; Ctrl+Alt+F2 is always a plain text login.", opts: [o("keep", "Keep as is"), o("greeter", "Login manager"), o("lock", "Auto-login + lock")] },
            { type: "action", id: "login-apply", label: "Apply the boot choice", btn: "Apply", done: "", desc: "Opens a terminal and sets up what you picked above (asks for your sudo password once). Your old login manager is only switched off and can be put back." },
            { type: "action", id: "greeter-preview", label: "Login screen", btn: "Preview", done: "", desc: "Opens the login screen as a window on your desktop. Nothing is logged in: type  preview  and Enter to close it." },
            { type: "seg", adv: true, key: "opt:greeterBg", label: "Login screen background", desc: "Same as lock screen: the login screen copies the lock screen's background (Settings > Lock screen: wallpaper, solid or sky; sky shows as solid here), blur and tint. Or force the blurred wallpaper, or the plain theme colour.", opts: [o("lock", "Same as lock"), o("wallpaper", "Wallpaper"), o("solid", "Solid")] },
            { type: "toggle", adv: true, key: "opt:greeterAvatar", def: true, label: "Login screen profile picture", desc: "Your picture in its ring above the name. Off: just the name and the password box. (The picture as a constellation is part of the constellation switch.)" },
            { type: "toggle", adv: true, key: "opt:greeterClock", def: true, label: "Login screen clock", desc: "The big clock and date on the login screen." },
            { type: "toggle", adv: true, key: "opt:greeterSeconds", def: false, label: "Login screen clock seconds", desc: "Show seconds in the login screen clock." },
            { type: "toggle", adv: true, key: "opt:greeterBattery", def: false, label: "Login screen battery", desc: "The battery level in the top right corner of the login screen." },
            { type: "toggle", adv: true, key: "opt:greeterWifi", def: false, label: "Login screen Wi-Fi name", desc: "The name of the Wi-Fi network you are on, top right on the login screen." },
            { type: "toggle", adv: true, key: "opt:greeterPower", def: true, label: "Login screen power buttons", desc: "Sleep / Restart / Shut down, bottom right." },
            { type: "toggle", adv: true, key: "opt:greeterSession", def: true, label: "Login screen desktop chooser", desc: "The desktop (session) chip bottom left: click it to pick Halcyon, Hyprland, Plasma ... (Tab changes it too)." },
        ] },
        { id: "performance", title: "Performance & memory", section: "Performance", items: [
            { type: "seg", key: "opt:resMode", label: "Resource use", desc: "One switch for how much RAM, CPU and GPU the desktop may use. Low: no blur, shadows or window animations, still stars (no moving stars in the bar), 30 fps, small notification lists, light music bars. Medium: light blur, no shadows, 60 fps. (How often the readers look again is separate: Update speed.) High: everything on, as designed. It sets the options on this page and in Effects and Constellations in one go; you can still change any of them afterwards. It never touches the startup items or the GPU below (those need a new login).", opts: [o("low", "Low"), o("medium", "Medium"), o("high", "High")] },
            { type: "toggle", key: "opt:autoLowBat", def: false, label: "Low preset on battery", desc: "Unplug the charger and Resource use switches to Low by itself; plug it in again and your previous preset comes back (only if you did not pick another one meanwhile). Off by default." },
            { type: "toggle", adv: true, key: "opt:focusQuiet", def: true, label: "Quiet visuals during Focus", desc: "While a Focus work session runs, the music bars stop and a video wallpaper is frozen (it resumes when the session ends or goes on break), so Focus also saves GPU and battery." },
            { type: "seg", key: "opt:limMode", label: "Limits", desc: "Manual: you set the two limits below. Adaptive: Halcyon measures its own RAM and CPU use every 5 minutes while the desktop runs (not while Gaming mode is on), and after 3 days sets the limits itself, a little above what is normal for you (the busy 5 % of the time plus headroom). It keeps adjusting over the last 14 days. Until it has learned, the manual limits apply. It only measures and advises, like the manual limits.", opts: [o("manual", "Manual"), o("auto", "Adaptive")] },
            { type: "acts", adv: true, label: "Adaptive limits", desc: "Start learning again from zero, for example after a big change to the setup.", btns: [{ id: "adapt-reset", btn: "Forget what it learned", done: "Learning again" }], when: "opt:limMode=auto" },
            { type: "slider", key: "opt:limRam", def: 600, when: "opt:limMode=manual", label: "Halcyon RAM limit", desc: "How much memory all of Halcyon together (Hyprland, the island with its helpers, the daemons) should stay under. Above it, Startup & processes > Health shows the likely causes and what to do. It only measures and advises: nothing is changed or stopped by itself.", min: 300, max: 1500, step: 50, unit: " MB" },
            { type: "slider", key: "opt:limCpu", def: 10, when: "opt:limMode=manual", label: "Halcyon CPU limit", desc: "The share of the whole processor all of Halcyon together should stay under. Flagged in Startup & processes > Health after two readings in a row over it (5 s apart), so a short burst does not count.", min: 3, max: 30, step: 1, unit: " %" },
            { type: "toggle", key: "gaming", label: "Gaming mode", desc: "CPU / GPU at full speed, turbo on, Wi-Fi power saving off, effects off, Caffeine and Do not disturb on, background helpers stopped. SUPER+F10." },
            { type: "seg", key: "opt:bgRefresh", label: "Update speed", desc: "How often the always-on readers (CPU, battery, Wi-Fi and Bluetooth state) look again while nothing needs fresh numbers. It is its own choice, the Resource use presets do not touch it, so you can have low RAM and CPU use and still live numbers. High: every 2 s / 4 s (live). Medium: 5 s / 10 s. Low: 10 s / 20 s (fewest wake-ups). Adaptive: live on the mains, slower on battery, slowest while the machine is busy (a game, a build) or the battery is nearly empty. It also learns from you: if your Wi-Fi and Bluetooth hardly ever change (after 3 days of use), their background look is stretched up to 4 times more, and it is live again for 5 minutes after any change. The performance page and the bar's CPU / RAM / TEMP row always stay at the live pace, and the Wi-Fi and Bluetooth label updates the moment you connect.", opts: [o("normal", "High"), o("relaxed", "Medium"), o("slow", "Low"), o("auto", "Adaptive")] },
            { type: "acts", adv: true, label: "Update speed, learned habits", desc: "Adaptive keeps a small count of how often your Wi-Fi / Bluetooth state really changed in the last 14 days (a file of day and time numbers, nothing else: no network names). Forget it to start learning again.", btns: [{ id: "netlearn-reset", btn: "Forget what it learned", done: "Learning again" }], when: "opt:bgRefresh=auto" },
            { type: "acts", adv: true, label: "Memory", desc: "Show what uses my RAM: opens the console with the memory use of every Halcyon process (scripts/halcyon-mem.sh). Detect RAM: asks for your password once to read the memory type and speed.", btns: [{ id: "mem-report", btn: "Show what uses my RAM", done: "Opening…" }, { id: "detect-ram", btn: "Detect RAM", done: "Asking…" }] }
        ] },
        { id: "treeview", title: "Tree view & constellations", section: "Performance", items: [
            { type: "seg", key: "opt:perf", label: "Tree view & constellation quality", desc: "High: everything moves (twinkling stars, travelling lights, floating dots). Medium: fewer twinkles and lights. Low: still stars, no lights or floating dots, the lightest. Lower also gives your picture constellation fewer stars.", opts: [o("low", "Low"), o("medium", "Medium"), o("high", "High")] },
            { type: "seg", key: "opt:fps", label: "Tree view & constellation frame rate", desc: "How often they update. Max follows your screen and is the smoothest. Lower numbers use less CPU / GPU but look less smooth.", opts: [o(0, "Max"), o(60, "60"), o(30, "30"), o(20, "20"), o(15, "15")] },
            { type: "seg", key: "opt:treeConst", label: "Tree view constellation", desc: "Full: the big constellation behind the tree. Corner: the same constellation made small and tucked into a screen corner, out of the way of the tree. Off: no constellation in the tree at all (the lightest).", opts: [o("full", "Full"), o("corner", "Small, in a corner"), o("off", "Off")] },
            { type: "seg", adv: true, key: "opt:treeConstCorner", when: "opt:treeConst=corner", soft: true, label: "Constellation corner", desc: "Which corner the small constellation sits in.", opts: [o("tl", "Top-left"), o("tr", "Top-right"), o("bl", "Bottom-left"), o("br", "Bottom-right")] },
            { type: "slider", adv: true, key: "opt:treeConstSize", def: 30, when: "opt:treeConst=corner", soft: true, label: "Small constellation size", desc: "How much of the screen the small constellation takes (a share of the tree's width and height).", min: 15, max: 50, step: 5, unit: " %" },
            { type: "seg", adv: true, key: "opt:treeDots", label: "Floating dots in the tree", desc: "Where the drifting dots gather. By load: more dots circle the workspaces and windows that use the most CPU and memory, and they glide over as the load changes. Even: spread over the whole screen. Off: none. (Quality Low shows none either way.)", opts: [o("load", "By load"), o("even", "Even"), o("off", "Off")] },
            { type: "seg", adv: true, key: "opt:lines", label: "Line drawing", desc: "Who draws the constellation lines and the tree branches. GPU: plain quads and a small shader, nothing is built on the CPU, so they appear at once. CPU: the old path drawing (slower to appear, but needs nothing extra). GPU branches need qt6-shadertools (qsb); without it they use CPU. Gaming mode always uses the lightest settings.", opts: [o("gpu", "GPU"), o("cpu", "CPU")] },
        ] },
        { id: "profiles", title: "Profiles & safe mode", section: "Performance", items: [
            { type: "seg", key: "fx:profile", label: "Profile", desc: "One switch for stars, blur, island motion, screen brightness and the top bar. Work: no stars, blur on, fast motion. Gaming: no stars, no blur, no motion, top bar off. Battery: no stars, no blur, fast motion, brightness 40 %. Night: stars on, brightness 15 %. Custom is your own setup: it is saved when you leave it and comes back when you pick Custom again. Terminal: halcyon profile <name>. To change what a profile does, edit ~/.local/state/island/profiles.json (halcyon profile --help).", opts: [o("custom", "Custom"), o("work", "Work"), o("gaming", "Gaming"), o("battery", "Battery"), o("night", "Night")] },
            { type: "acts", label: "Safe mode", desc: "If the desktop is slow, flickers or will not draw properly: turns off blur, shadows, window animations, stars, island motion and the other heavy effects, and reloads the island. Your values are saved first and Back to normal restores them. It also works from a terminal when the island is unusable: halcyon safe-mode, then halcyon safe-mode back. Shortcut: Super + Alt + F12 (on / off).", btns: [{ id: "fx-safe-on", btn: "Turn on safe mode", done: "Reloading...", when: "fx:safe=false" }, { id: "fx-safe-off", btn: "Back to normal", done: "Restoring...", when: "fx:safe=true" }] }
        ] },
        { id: "suggestions", title: "Optimization & Suggestions", section: "Performance", items: [
            { type: "acts", label: "Recommended Sweet Spot (Aesthetic + Speed)", desc: "Optimizes performance without compromising visual fidelity: applies 60 fps, 2-pass blur (size 5), disables window shadows and moving bar star particles, enables lazy-loading & automatic memory cleanup. Saves ~50-80 MB RAM and keeps idle CPU <0.5%.", btns: [{ id: "opt-sweet-spot", btn: "Apply Sweet Spot", done: "Applied!" }] },
            { type: "acts", label: "Adaptive System Advisor", desc: "Analyzes your actual battery status, memory pressure, active workloads, and application launch habits to generate personalized tuning advice in the console (scripts/adaptive-advisor.py).", btns: [
                { id: "opt-adaptive-advisor", btn: "Analyze My Setup", done: "Opening…" },
                { id: "opt-llm-advisor", btn: "AI / LLM Advisor (Experimental)", done: "Analyzing…" }
            ] },
            { type: "toggle", key: "opt:lazyLoad", def: true, label: "Aggressive Memory Freeing & Lazy Loading", desc: "Frees the memory of a dialog soon after it closes (a garbage collection pass), and lets the local AI model (2 to 3 GB) go 3 minutes after the last answer instead of 30 (1 minute for the small helpers, 10 s for notes). Every dialog builds only the view you are looking at either way. On automatically in Low and Medium resource use." },
            { type: "acts", label: "Live Memory Trimming", desc: "Triggers immediate garbage collection across Quickshell's JavaScript heap and flushes cached texture buffers back to the OS.", btns: [{ id: "opt-trim-mem", btn: "Trim Memory Now", done: "Trimmed!" }] }
        ] },
        { id: "sysoptions", title: "System preferences & timeouts", section: "System", items: [
            { type: "action", id: "cheatsheet", label: "Settings shortcut", btn: "View shortcuts", desc: "Super + I opens Settings directly (Super + F11 also works as a legacy fallback). Tap Super opens the application launcher." },
            { type: "seg", key: "opt:cornerTimeout", label: "Corner utilities menu timeout", desc: "How long the bottom-right corner pin / quick utilities overlay remains open after interaction.", opts: [o(3000, "3 s"), o(6000, "6 s"), o(10000, "10 s")] },
            { type: "acts", label: "Login manager & tty1 autologin", desc: "Check or configure automatic login directly into Hyprland without a display manager prompt (scripts/login-status.sh).", btns: [
                { id: "login-status", btn: "Check Status", done: "" },
                { id: "login-enable-lock", btn: "Setup tty1 Autologin", done: "Opening…" },
                { id: "login-remove-lock", btn: "Remove tty1 Autologin", done: "Opening…" }
            ] }
        ] },
        { id: "startup", title: "Startup & background", section: "System", items: [
            { type: "action", id: "startup-view", label: "Startup & processes", btn: "Open the window", done: "", desc: "Everything that starts with the desktop (Halcyon's parts, your hypr-user.lua lines, systemd user services, autostart files) with the processes it runs, their RAM and CPU, a switch for each, and every other process of yours with an End button. The Health tab compares all of Halcyon with the RAM and CPU limits (Performance & memory) and lists the likely causes when it is over. Also `>startup` in the launcher." },
            { type: "toggle", key: "st:NM_APPLET", label: "Network tray icon (nm-applet)", desc: "Off saves roughly 30-50 MB. The island already lists Wi-Fi networks. Turn it on for VPN and 802.1x (company / school Wi-Fi) password prompts. Starts or stops at once." },
            { type: "toggle", key: "st:BLUEMAN", label: "Bluetooth tray icon (blueman-applet)", desc: "Off saves roughly 30-50 MB. Already paired devices reconnect without it; you only need it to pair a new device from a window. Starts or stops at once." },
            { type: "toggle", key: "st:CLIPBOARD", label: "Clipboard history", desc: "The two small watchers that remember what you copy (text and pictures) for the clipboard pickers: Super + V and >clipboard in the launcher. A copy that a password manager marks as secret is never saved. Off stops them at once and saves a few MB; the pickers then only show what was saved before. Empty the history from >clipboard (Clear history)." },
            { type: "toggle", adv: true, key: "opt:clipAtCursor", def: true, label: "Clipboard opens at the mouse", desc: "Super + V opens the clipboard panel where the mouse pointer is, like Windows does (it flips to the other side of the pointer near a screen edge). Off: it opens on the side of the screen." },
            { type: "toggle", key: "st:AUDIO_FOCUS", label: "One thing plays at a time", desc: "Start a video or any other player while music is going and the music pauses; when the video stops or ends, the music carries on by itself. Only what it paused itself comes back: if you paused the music yourself, it stays paused. Works with everything that shows up as a media player (Spotify, browser tabs, mpv, VLC ...). Needs playerctl." },
            { type: "toggle", key: "st:AUDIO_RESUME", when: "st:AUDIO_FOCUS=true", label: "Bring the music back afterwards", desc: "When the video or other player stops or ends, what was paused for it starts again. Off: the music is only paused for you, you start it yourself. Something you paused by hand is never started either way." },
            { type: "seg", adv: true, key: "st:AUDIO_DELAY", when: "st:AUDIO_FOCUS=true&st:AUDIO_RESUME=true", label: "Wait before bringing it back", desc: "Seconds of silence first, so a song change or the next video in a playlist does not count as a stop.", opts: [o("1", "1 s"), o("2", "2 s"), o("5", "5 s"), o("10", "10 s")] },
            { type: "seg", adv: true, key: "st:PORTAL", label: "Screen-sharing helper", desc: "At login: it is always ready (Hyprland's own screen-share portal). On demand: it is not started until the first app asks to share or record the screen (browser, OBS), which then takes a moment longer once. Saves its memory until then.", opts: [o("login", "At login"), o("demand", "On demand")] },
            { type: "seg", adv: true, key: "st:POLKIT", label: "Password prompt helper (polkit agent)", desc: "The small program that shows the 'enter your password' window for apps that need admin rights. Auto picks the lightest one installed: Hyprland's, then GNOME's, then KDE's (the heaviest). None = no password windows at all. Takes effect at the next login.", opts: [o("auto", "Auto"), o("hyprpolkitagent", "Hyprland"), o("gnome", "GNOME"), o("kde", "KDE"), o("none", "None")] },
            { type: "seg", adv: true, key: "st:GPU", label: "Graphics card for the desktop", desc: "Integrated: the Intel / AMD graphics draw the desktop, but Hyprland still opens the NVIDIA card, which on many laptops keeps it awake (about 2.5 W). Integrated only: Hyprland is not given the NVIDIA card at all, so it can sleep until you run a program with prime-run; screens on its ports stay dark unless one is plugged in at login. NVIDIA: the NVIDIA card draws the desktop; smoother with heavy blur, but it loads the NVIDIA libraries (+100 MB or more RAM) and uses a lot more battery. Takes effect at the next login.", opts: [o("igpu", "Integrated"), o("igpu-only", "Integrated only (NVIDIA sleeps)"), o("dgpu", "NVIDIA")] }
        ] },
        { id: "apps", title: "Apps & config", section: "System", items: [
            { type: "custom", name: "apps" },
            { type: "seg", key: "st:FILE_ICONS", label: "File manager icons", desc: "How big the icons are in Thunar (side bar, lists, icon view, toolbar). Thunar picks it up at once; windows that are already open may need a reopen.", opts: [o("small", "Small"), o("medium", "Medium"), o("large", "Large")] },
            { type: "acts", label: "Rice", desc: "Edit config: opens the config files. Shortcuts: the shortcut tree. Reload: re-reads the config files and puts the island's own values back on top.", btns: [{ id: "config", btn: "Edit config", done: "", close: true }, { id: "cheatsheet", btn: "Shortcuts", done: "", close: true }, { id: "reload", btn: "Reload Hyprland", done: "Reloading…" }] }
        ] },
        { id: "backup", title: "Backup", section: "System", items: [
            { type: "custom", name: "dayClock" },
            { type: "acts", label: "Backup", desc: "Plug in an external hard disk or SSD, pick it in the terminal that opens, and the files are copied onto it (scripts/backup-device.sh). Whole system: everything (asks for your admin password). Home folder: only your files, no password. Nothing on the disk is erased; every backup goes in its own dated folder. Caches, trash, package downloads and game files are skipped; add your own in ~/.config/Halcyon/backup-exclude.conf.", btns: [{ id: "backup-device", btn: "Whole system", done: "Opening…" }, { id: "backup-home", btn: "Home folder only", done: "Opening…" }] },
            { type: "acts", label: "Restore", desc: "Plug in the backup disk and pick a backup in the terminal that opens. Whole system: a whole-system backup can restore your home folder or the whole system (asks for your admin password and a typed confirmation). Home folder only: only ever touches your home folder (any backup works), you can restore just one folder or file, no password. Nothing is deleted, you see what would change first, and every file that gets replaced is saved in an undo folder.", btns: [{ id: "restore-device", btn: "From a backup", done: "Opening…" }, { id: "restore-home", btn: "Home folder only", done: "Opening…" }] }
        ].concat(root.remindRows("BACKUP", "Remind me to back up", "A notification when it has been that long since the last backup made with the buttons above. Off by default; nothing runs in the background while every reminder is off.")) },
        { id: "security", title: "Security", section: "System", items: [
            { type: "seg", key: "st:ANTIVIRUS", needs: "anyav", label: "Antivirus", desc: "Which antivirus runs. Off stops it; it stays installed with its settings. The change opens the console and asks for your admin password.",
              opts: (root.startup.has && root.startup.has.antivirus ? [o("ai", "AI Antivirus")] : []).concat(root.startup.has && root.startup.has.clamav ? [o("clamav", "ClamAV")] : []).concat([o("off", "Off")]) },
            { type: "action", id: "security-firewall", needs: "firewall", label: "Firewall", btn: "Open in the Security center", done: "Opening…" },
            { type: "action", id: "security-antivirus", needs: "antivirus", label: "Antivirus", btn: "Open in the Security center", done: "Opening…" },
            { type: "action", id: "security-exceptions", needs: "antivirus", label: "Antivirus exceptions", btn: "Open", done: "Opening…" },
            { type: "action", needs: "antivirus", id: root.avAiOn ? "antivirus-ai:off" : "antivirus-ai:on", label: "AI review of antivirus alerts", btn: root.avAiOn ? "Turn off" : "Turn on", done: "Opening…", desc: "Now: " + (root.avAiOn ? "on" : "off") + ". ai-antivirus sends each alert to your local model (loopback only) and keeps its comments, advice only: it never blocks or deletes anything by itself. The model is the one in /etc/ai-antivirus/ai-antivirus.toml ([ai]); if Ollama lacks it you are asked to download it. Opens the console and asks for your admin password.", },
            { type: "action", adv: true, id: "safety-check", needs: "safety", label: "Safety check", btn: "Run the safety check", done: "Opening…", desc: "Opens a terminal and, after your admin password, runs the full check: system update, ClamAV malware scan, rkhunter rootkit check, firewall, Lynis audit, AIDE file integrity (monthly) and a backup to your backup disk. It takes a while; the log is saved in /var/log/halcyon/safety_check/." }
        ].concat(root.remindRows("SAFETY", "Remind me to run the safety check", "Same, for the safety check (by hand or automatic, either counts as done).", "safety")).concat([
            { type: "custom", name: "safetyAuto" },
            { type: "custom", name: "counterScan", when: "sysmode=stealth|hacking", label: "Counter-scan attackers (nmap)", desc: "stealth mode only: scan back whoever probes the decoys. Once on it stays on until you turn it off." }
        ]) },
        { id: "firewall", title: "Firewall", section: "System", items: [
            { type: "acts", needs: "firewall", label: "ai-firewall", desc: "Halcyon's firewall: incoming connections are refused unless you open a port, and anything that scans or floods this machine is banned for a while (longer each time). Firewall Center (also >firewall in the launcher): a live graph, bans, rules and profiles, blocklist feeds, history, and an assistant that explains network problems. Status page: the quick view in the island. Terminal dashboard: the same live view in a terminal.", btns: [{ id: "fw-center", btn: "Firewall Center", done: "", close: true }, { id: "fw-page", btn: "Status page", done: "", close: true }, { id: "fw-top", btn: "Terminal dashboard", done: "Opening…" }] },
            { type: "action", needs: "firewall", id: "fw-doctor", label: "Network doctor", btn: "Check the network", done: "Opening…", desc: "Checks the firewall, the internet, DNS and VM / container networking, and offers a fix for each problem it can solve (you confirm each one). Opens a terminal; asks for your admin password." },
            { type: "action", adv: true, needs: "firewall", id: "fw-config", label: "Firewall config", btn: "Edit config", done: "", desc: "/etc/ai-firewall/config.toml: open ports, ping, trusted and blocked addresses, how quickly it bans, the assistant's model. Saved changes apply within 3 seconds; a broken edit is ignored and the last good config stays." }
        ] }
    ]

    // ---- reading and formatting values
    function get(key) {
        if (!key || typeof key !== "string") return undefined
        if (key === "opt:tilingLayout") return (opt && opt.floatAll) ? "off" : (hyCur && hyCur.layout ? hyCur.layout : "dwindle")
        if (key.indexOf("opt:") === 0) return opt ? opt[key.substring(4)] : undefined
        if (key.indexOf("hy:") === 0) return hyCur ? hyCur[key.substring(3)] : undefined
        if (key.indexOf("st:") === 0) return startup ? startup[key.substring(3)] : undefined
        if (key.indexOf("gr:") === 0) return greeting ? greeting[key.substring(3)] : undefined
        if (key === "ai:enabled") return !(ai && ai.enabled === false)
        if (key.indexOf("nt:") === 0) return notesConf ? notesConf[key.substring(3)] : undefined
        if (key.indexOf("fx:") === 0) return fxConf ? fxConf[key.substring(3)] : undefined
        if (key.indexOf("fc:") === 0) return focusConf ? focusConf[key.substring(3)] : undefined
        if (key.indexOf("rm:") === 0) return remind ? remind[key.substring(3)] : undefined
        if (key.indexOf("rmwhen:") === 0) {          // BACKUP / SAFETY: "off", or the interval it is on with
            var rw = key.substring(7)
            return (remind && remind[rw + "_REMIND"]) ? String(remind[rw + "_EVERY"]) : "off"
        }
        if (key.indexOf("bl:") === 0) {              // the bar's own layout (opt.barLayout): shape, side, rstyle, caps, spMode; isRail = the bar is a rail now
            var bl = BL.normalize(opt ? opt.barLayout : null)
            if (key === "bl:isRail") return !!opt && (opt.barStyle === "rail" || (opt.barStyle === "custom" && bl.shape === "rail"))
            return bl[key.substring(3)]
        }
        if (key.indexOf("pair:") === 0) {            // the value of the bar that is showing now (both get written together)
            var pr = pairs[key.substring(5)]
            return opt ? opt[(opt.barStyle === "notch" || opt.barStyle === "custom" || opt.barStyle === "rail") ? pr[1] : pr[0]] : undefined
        }
        return root[key]
    }
    // ---- shared by both layouts: what to say under a row
    function isOff(m) { return (m.needs !== undefined && !(startup.has && startup.has[m.needs] === true)) || m.dis !== undefined }   // an optional part that is not installed, or a row whose switch is off (see disWhy)
    // A row marked soft: true that has a `when` is not hidden while that `when` fails: it moves to the "Disabled" part at the bottom of
    // its group, greyed out and locked, and hovering it says what to turn on. (Search still lists only what is active.)
    function findItem(key) {
        for (var g = 0; g < groups.length; g++)
            for (var i = 0; i < groups[g].items.length; i++)
                if (groups[g].items[i].key === key) return groups[g].items[i]
        return null
    }
    function disWhy(it) {
        if (it.why) return it.why
        var p = String(it.when || "").split("||")[0].split("&")[0].split("=")
        var dep = p.length > 1 ? findItem(p[0]) : null
        var lab = dep && dep.label ? "\u201c" + dep.label + "\u201d" : "the option above"
        if (!dep || dep.type === "toggle") return "Turn on " + lab + " to change this."
        var want = p[1].split("|")[0], ol = want
        if (dep.opts) for (var i = 0; i < dep.opts.length; i++) if (String(dep.opts[i].v) === want) ol = dep.opts[i].t
        return "Set " + lab + " to " + ol + " to change this."
    }
    function descOf(m) {
        if (m.dis !== undefined) return "Turned off"
        var off = isOff(m)
        return off ? (m.needs === "firewall"
                ? "ai-firewall is not installed, so this is switched off. Add it with ./install.sh --firewall ai (or ./install.sh --choose), then open Settings again."
                : "Not installed, so this is switched off. Add it with ./install.sh --safety-check (or ./install.sh --choose and answer yes), then open Settings again.")
            : (m.key === "nightlight" && !root.tools.nightlightOk) ? "hyprsunset is not installed (pacman -S hyprsunset / apt install hyprsunset)"
            : (m.key === "st:NM_APPLET" && root.startup.has && !root.startup.has.nm) ? "nm-applet is not installed (pacman -S network-manager-applet / apt install network-manager-gnome)"
            : (m.key === "st:BLUEMAN" && root.startup.has && !root.startup.has.blueman) ? "blueman is not installed (pacman -S blueman / apt install blueman)"
            : (m.key === "st:GPU" && root.startup.has && !root.startup.has.nvidia) ? (m.desc || "") + " (The NVIDIA driver is not loaded now, so the NVIDIA choice does nothing until it is.)"
            : ((m.key === "st:POLKIT" || m.key === "st:GPU" || m.key === "st:PORTAL") && root.startupNote !== "") ? (m.desc || "") + "  \u2192 " + root.startupNote
            : (m.key === "fx:profile" && root.fxConf.safe) ? (m.desc || "") + "  Safe mode is on, so profiles are paused: turn safe mode off first."
            : (m.label === "Safe mode" && root.fxConf.safe) ? "Safe mode is ON: blur, shadows, window animations, stars and motion are off. Back to normal puts your earlier values back."
            : (m.key === "nt:NOTES_OCR" && root.notesConf.NOTES_OCR && root.notesConf.tesseract === false) ? (m.desc || "") + "  tesseract is not installed right now, so nothing is read until it is."
            : (m.key === "nt:NOTES_VLM" && root.notesConf.NOTES_VLM && root.notesConf.vlmModel) ? (m.desc || "") + "  Picture model in use: " + root.notesConf.vlmModel + "."
            : (m.key === "nt:NOTES_OVERVIEW" && root.notesConf.NOTES_OVERVIEW && root.notesConf.ollama === false) ? (m.desc || "") + "  Ollama is not running right now, so new notes get no overview until it is."
            : (m.key === "nt:NOTES_OVERVIEW" && root.notesConf.NOTES_OVERVIEW && root.notesConf.model) ? (m.desc || "") + "  Model in use: " + root.notesConf.model + " (the same one `ai` uses; change it under Performance)."
            : (m.key === "nt:NOTES_AI" && root.notesConf.NOTES_AI && root.notesConf.ollama === false) ? (m.desc || "") + "  Ollama is not running right now, so new notes are saved as plain notes until it is."
            : (m.key === "nt:NOTES_AI" && root.notesConf.NOTES_AI && root.notesConf.model) ? (m.desc || "") + "  Model in use: " + root.notesConf.model + " (the same one `ai` uses; change it under Performance)."
            : m.key === "rmwhen:BACKUP" ? (m.desc || "") + "  Last backup made here: " + root.remind.backupAgo + "."
            : m.key === "rmwhen:SAFETY" ? (m.desc || "") + "  Last safety check: " + root.remind.safetyAgo + "."
            : (m.id === "layout" ? "Now: " + (root.hyCur.layout || "dwindle") : (m.desc || ""))
    }
    // item.when = "key=value": the item is only listed while that setting has that value (e.g. the notch options)
    // several conditions can be joined with "&": "opt:barStyle=notch&opt:notchCombo=false"
    function whenOk(w) {
        var alts = w.split("||")                       // several ways to be shown: any one is enough
        for (var a = 0; a < alts.length; a++) {
            var parts = alts[a].split("&"), ok = true
            for (var i = 0; i < parts.length && ok; i++) {
                var p = parts[i].split("=")
                if (p[1].split("|").indexOf(String(get(p[0]))) < 0) ok = false      // "key=a|b": that setting is a or b
            }
            if (ok) return true
        }
        return false
    }
    function num(m) {
        var v = get(m.key)
        return (v === undefined || v === null) ? (m.def !== undefined ? m.def : m.min) : Number(v)
    }
    function fmt(m, v) {
        var x = v * (m.scale || 1)
        var t = m.dec ? x.toFixed(m.dec) : String(Math.round(x))
        return (m.signed && x >= 0 ? "+" : "") + t + (m.unit || "")
    }
    function same(a, b) { return a === b || (typeof a === "number" && typeof b === "number" && Math.abs(a - b) < 0.0001) }
    // ---- drop-down rows (item.drop: true on a seg or chips row): SDrop.qml shows them instead of a row of buttons
    // the entries of the menu: a seg lists every choice (the present one is on); chips list the switches that are shown now
    function dropItems(m) {
        var out = []
        if (!m || !m.opts) return out
        for (var i = 0; i < m.opts.length; i++) {
            var q = m.opts[i]
            if (m.type === "chips") {
                if (q.when && !whenOk(q.when)) continue
                out.push({ t: q.t, on: !!get(q.k), idx: i })
            } else {
                out.push({ t: q.t, on: same(get(m.key), q.v), idx: i })
            }
        }
        return out
    }
    // the text on the closed menu: the choice, or how many of the switches are on
    function dropSummary(m) {
        var it = dropItems(m), n = 0, name = ""
        for (var i = 0; i < it.length; i++) if (it[i].on) { n++; if (name === "") name = it[i].t }
        if (m.type === "chips") return n === 0 ? "None" : (n === it.length ? "All " + n : n + " of " + it.length + " on")
        return name !== "" ? name : "Choose"
    }
    function dropPick(m, i) {
        var it = dropItems(m)
        if (i < 0 || i >= it.length) return
        var q = m.opts[it[i].idx]
        if (m.type === "chips") change(q.k, !get(q.k))
        else change(m.key, q.v)
    }
    function boolVal(m) {
        if (m.type === "tool") return !!tools[m.key]
        var v = get(m.key)
        return v === undefined ? false : !!v
    }

    // ---- search + collapsing
    property string query: ""
    property bool scrolling: false          // true while the list is moving: the starfield / pulses pause so scrolling gets the whole frame
    property string section: ""             // "" = every section; else Appearance | Bar & panels | Desktop | Input & power | Performance | System
    readonly property var sections: ["Discover", "Appearance", "Stars & splash", "Bar & panels", "Desktop", "Productivity", "Input & power", "Performance", "System"]
    property var collapsed: ({ apps: true, growth: true, gestures: true, mousebtn: true, treeview: true })

    // ---- two layouts: "tree" (the branching view, the default) and "pages" (a menu on the left, one page at a time).
    // Both read the same groups / items and write through the same change(), so nothing is lost by switching.
    readonly property bool pagesMode: opt && opt.settingsStyle === "pages"
    // every group sits on exactly ONE page (tests/settings-groups.test.js checks it); the pages follow the section tabs of the tree
    readonly property var pages: [
        { id: "Discover", sub: "The settings you use most, everything Halcyon can do, and the guided tour.", groups: ["often", "discover"] },
        { id: "Appearance", sub: "Look, your profile, colours, wallpaper, transparency and motion.", groups: ["look", "profile", "colours", "wallpaper", "glass", "motion"] },
        { id: "Stars & splash", sub: "Constellations, the splash, the weekly sky, time of day and the terminal greeting.", groups: ["growth", "signature", "greeting"] },
        { id: "Bar", sub: "The bar: its look and edge, what is on it, how it behaves, the border and the clock.", groups: ["bar", "barwidgets", "barbehave", "frame", "clock"] },
        { id: "Panels", sub: "Notifications, the edge boxes, the volume bar and the utilities box.", groups: ["notifications", "osd", "utilbox"] },
        { id: "Desktop", sub: "The desktop and widget builders, workspaces and windows.", groups: ["desktop", "widgets", "workspaces"] },
        { id: "Productivity", sub: "Focus mode, the calendar, notes and recording.", groups: ["focus", "calendar", "notes", "recording"] },
        { id: "AI", sub: "The local AI helpers: the master switch, the model, the daily brief and the error explainer.", groups: ["ai"] },
        { id: "Input & power", sub: "Mouse, touchpad, gestures, mouse buttons, keyboard, power and the lock screen.", groups: ["mouse", "keyboard", "gestures", "mousebtn", "power", "lockscreen", "loginscreen"] },
        { id: "Performance", sub: "Profiles, safe mode, speed, memory limits, the tree view and suggestions.", groups: ["performance", "treeview", "profiles", "suggestions"] },
        { id: "System", sub: "Preferences, timeouts, login manager, startup and apps.", groups: ["sysoptions", "startup", "apps"] },
        { id: "Backup", sub: "Backups and restore, with reminders.", groups: ["backup"] },
        { id: "Security", sub: "The antivirus, the firewall, the safety check and their reminders.", groups: ["security", "firewall"] }
    ]
    property string page: "Discover"
    function pageOf(gid) { for (var i = 0; i < pages.length; i++) if (pages[i].groups.indexOf(gid) >= 0) return pages[i].id; return "Appearance" }
    function pageInfo(id) { for (var i = 0; i < pages.length; i++) if (pages[i].id === id) return pages[i]; return pages[0] }
    // "Advanced" rows: items marked adv: true stay behind a fold in each group (a search always finds them; advAll shows them everywhere)
    property bool advAll: false
    property var advMap: ({})
    function toggleAdv(id) {
        var c = {}
        for (var k in advMap) c[k] = advMap[k]
        if (c[id]) delete c[id]; else c[id] = true
        advMap = c
    }
    function toggleGroup(id) {
        var c = {}
        for (var k in collapsed) c[k] = collapsed[k]
        if (c[id]) delete c[id]; else c[id] = true
        collapsed = c
    }
    function setAll(coll) {
        var c = {}
        if (coll) for (var i = 0; i < groups.length; i++) c[groups[i].id] = true   // every group, shown or not
        collapsed = c
    }
    function itemText(g, it) {
        var t = ((g.section || "") + " " + g.title + " " + (it.label || "") + " " + (it.desc || "") + " " + (it.name || "") + " " + (it.btn || ""))
        if (it.opts) for (var i = 0; i < it.opts.length; i++) t += " " + it.opts[i].t
        if (it.btns) for (var b = 0; b < it.btns.length; b++) t += " " + it.btns[b].btn
        return t.toLowerCase()
    }
    // cached results (plain objects that are only mutated, never re-assigned): the filter / column functions hand back the SAME
    // array when nothing changed, because a Repeater tears down and rebuilds every delegate whenever its model is replaced
    readonly property var _fc: ({ sig: "", out: [] })
    readonly property var _cc: ({ sig: "", out: [] })
    readonly property var groupsNow: {
        var q = query.toLowerCase().trim()
        var out = [], sig = ""
        for (var g = 0; g < groups.length; g++) {
            var grp = groups[g], items = [], idx = "", advN = 0, dis = [], didx = ""
            if (grp.id === "often") {                      // not in a search (the rows show in their own groups there)
                if (q !== "" || oftenItems.length === 0 || (!pagesMode && section !== "" && grp.section !== section)) continue
                out.push({ id: grp.id, title: grp.title, section: grp.section, items: oftenItems, advN: 0, advShow: false })
                for (var oi = 0; oi < oftenItems.length; oi++) sig += (oftenItems[oi].key || oftenItems[oi].id) + ","
                sig += ";"
                continue
            }
            var advShow = advAll || !!advMap[grp.id]
            if (q === "" && !pagesMode && section !== "" && grp.section !== section) continue
            for (var i = 0; i < grp.items.length; i++) {
                var it = grp.items[i]
                if (it.when && !whenOk(it.when)) {
                    if (it.soft === true && q === "" && (it.adv !== true || advShow)) {      // kept, but greyed out under "Disabled"
                        var dc = {}
                        for (var dk in it) dc[dk] = it[dk]
                        delete dc.when
                        dc.dis = disWhy(it)
                        dis.push(dc); didx += i + ","
                    }
                    continue
                }
                if (q !== "" && itemText(grp, it).indexOf(q) < 0) continue
                if (q === "" && it.adv === true) { advN++; if (!advShow) continue }
                items.push(it); idx += i + ","
            }
            if (items.length > 0 && dis.length > 0) {
                items.push({ type: "divider", label: "Disabled" })
                for (var dd = 0; dd < dis.length; dd++) items.push(dis[dd])
                idx += "D" + didx
            }
            if (items.length > 0) { out.push({ id: grp.id, title: grp.title, section: grp.section, items: items, advN: advN, advShow: advShow }); sig += grp.id + ":" + idx + advN + (advShow ? "A" : "a") + ";" }
        }
        if (sig === _fc.sig) return _fc.out
        _fc.sig = sig; _fc.out = out
        return out
    }
    readonly property var _pc: ({ out: [] })
    readonly property var pageGroupsNow: {
        var src = groupsNow, ids = null, out = []
        if (query === "") ids = pageInfo(page).groups
        for (var g = 0; g < src.length; g++) if (ids === null || ids.indexOf(src[g].id) >= 0) out.push(src[g])
        var prev = _pc.out, same = prev.length === out.length
        for (var i = 0; same && i < out.length; i++) if (prev[i] !== out[i]) same = false
        if (same) return prev
        _pc.out = out
        return out
    }
    readonly property int shownCount: { var n = 0; for (var g = 0; g < groupsNow.length; g++) n += groupsNow[g].items.length; return n }
    readonly property int colCount: (typeof card !== "undefined" && card) ? (card.width >= 1080 ? 2 : 1) : 2
    function weight(grp) {
        var w = 2
        if (query === "" && collapsed[grp.id]) return w
        for (var i = 0; i < grp.items.length; i++) {
            var t = grp.items[i]
            w += t.type === "custom" ? (t.name === "wallpaper" ? 9 : t.name === "apps" ? 8 : t.name === "focusApps" ? 7 : t.name === "aiModel" ? 7 : t.name === "safetyAuto" ? 5 : t.name === "counterScan" ? 6 : t.name === "dayClock" ? 13 : t.name === "wallClock" ? 5 : t.name === "profile" ? 6 : t.name === "liveWalls" ? 7 : t.name === "focusClock" ? 6 : t.name === "specialCmds" ? 9 : t.name === "barBuilder" ? 7 : t.name === "notifBuilder" ? 7 : t.name === "desktopBuilder" ? 7 : t.name === "widgetBuilder" ? 8 : t.name === "gestures" ? 10 : t.name === "mouseButtons" ? 7 : t.name === "discover" ? 30 : 4)
               : (t.type === "seg" || t.type === "slider" || t.type === "chips" || t.type === "acts") ? 2.2 : 1.2
            if (t.desc) w += 0.7
        }
        if (grp.advN > 0) w += 1
        return w
    }
    // the groups keep their order: top to bottom in the first column, then the next one (the split is by height, so the columns stay about even)
    readonly property var columns: {
        var n = colCount || 2, cols = [], ws = [], total = 0
        for (var i = 0; i < n; i++) cols.push([])
        for (var g = 0; g < groupsNow.length; g++) { var w = weight(groupsNow[g]); ws.push(w); total += w }
        var per = total / n, acc = 0, c = 0
        for (var k = 0; k < groupsNow.length; k++) {
            if (c < n - 1 && acc > 0 && acc + ws[k] / 2 > per * (c + 1)) c++
            cols[c].push(groupsNow[k])
            acc += ws[k]
        }
        var sig = ""
        for (var a = 0; a < cols.length; a++) { for (var b = 0; b < cols[a].length; b++) sig += cols[a][b].id + ","; sig += "|" }
        sig = n + "#" + sig
        if (sig === _cc.sig && groupsNow === _cc.src) return _cc.out
        _cc.sig = sig; _cc.src = groupsNow; _cc.out = cols
        return cols
    }

    // columns that actually hold a group: a search with few hits fills only the first one, and the empty one gets no trunk line / dot
    readonly property int usedCols: {
        var n = 0
        for (var i = 0; i < columns.length; i++) if (columns[i].length > 0) n = i + 1
        return Math.max(1, n)
    }

    onOpenChanged: if (open) {
        if (!appsProc.running) appsProc.running = true
        if (!specialProc.running) specialProc.running = true
        if (!startupProc.running) startupProc.running = true
        if (!greetProc.running) greetProc.running = true
        if (!notesProc.running) notesProc.running = true
        if (!remindProc.running) remindProc.running = true
        if (!tlProc.running) tlProc.running = true
        startupNote = ""
        query = ""
        focusLoad()
        aiLoad(false)
        if (pendingGroup !== "") { unfoldOnly(pendingGroup); pendingGroup = "" }
    }

    // ======================================================================== custom leaves
    Component { id: cSwatches; SetSwatches { root: settingsScope } }

    Component { id: cWallpaper; SetWallpaper { root: settingsScope } }

    Component { id: cApps; SetApps { root: settingsScope } }

    // Special workspace commands: your own command per special workspace, started whenever it opens with no window in it
    Component { id: cSpecialCmds; SetSpecialCmds { root: settingsScope } }

    // Touchpad gestures: pick 3 or 4 fingers, then what each swipe / pinch does (ActionPick.qml). Saved by scripts/input-conf.sh.
    Component { id: cGestures; SetGestures { root: settingsScope } }

    // Mouse buttons: shown for the mice that are connected right now (looked for every few seconds while this is on screen)
    Component { id: cMouseButtons; SetMouseButtons { root: settingsScope } }

    // Wallpaper timeline (top of Settings > Wallpaper): when the picture last changed. wallpaper.sh saves the time when it really
    // changes (wallpaper-changed); an install from before that has no file yet, and then the date of the wallpaper state file is used.
    Component { id: cWallClock; SetWallClock { root: settingsScope } }
    // the name and picture of the Overview's laptop node (it was the Overview's own "Edit profile" card)
    Component { id: cProfile; SetProfile { root: settingsScope } }
    Component { id: cLiveWalls; SetLiveWall { root: settingsScope } }

    // Focus streak timeline (top of Settings > Focus mode): days in a row you reached the goal, against your best streak. The goal is
    // the Focus widget's "Minutes that count as a focus day" (25 when there is no Focus widget), the same rule the widget uses.
    Component { id: cFocusClock; SetFocusClock { root: settingsScope } }

    // Backup and safety-check clocks: two timelines (last time, today, due day) in place of the old pair of rings
    Component { id: cDayClock; SetDayClock { root: settingsScope } }

    // Safety check, automatic run: root, so every change (on, how often, off) asks for the sudo password. The password goes to
    // `sudo -k -S` once (-k = a password you typed a minute ago in a terminal does not count) and is never stored or logged.
    Component { id: cSafetyAuto; SetSafetyAuto { root: settingsScope } }
    Component { id: cCounterScan; SetCounterScan { root: settingsScope } }

    Component { id: cAiModel; SetAiModel { root: settingsScope } }
    Component { id: cVoiceKey; SetVoiceKey { root: settingsScope } }
    Component { id: cDiscover; SetDiscover { root: settingsScope } }

    Component { id: cFocusApps; SetFocusApps { root: settingsScope } }

    Component { id: cNotifBuilder; SetNotifBuilder { root: settingsScope } }

    Component { id: cDesktopBuilder; SetDesktopBuilder { root: settingsScope } }

    Component { id: cWidgetBuilder; SetWidgetBuilder { root: settingsScope } }

    Component { id: cBarBuilder; SetBarBuilder { root: settingsScope } }

    Component { id: cGrowth; SetGrowth { root: settingsScope } }

    // ======================================================================== the window
    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "island-settings"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: (root.open && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Item {
            id: fade
            anchors.fill: parent
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            // the picture picker of Settings > Profile, over everything in this window
            Loader {
                z: 100
                anchors.fill: parent
                active: root.imgPickOpen
                sourceComponent: ImagePicker {
                    pal: root.pal
                    Component.onCompleted: openAt(root.imgPickStart)
                    onPicked: path => { if (root.imgPickCb) root.imgPickCb(path); root.imgPickOpen = false }
                    onCancelled: root.imgPickOpen = false
                }
            }
            // the bar was turned off with the screen border on: keep the border or turn it off too
            Rectangle {
                z: 110
                anchors.fill: parent
                visible: root.borderAsk
                color: Qt.alpha("#000000", 0.5)
                MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: root.borderAsk = false }
                Rectangle {
                    anchors.centerIn: parent
                    width: 380; height: askCol.implicitHeight + 40
                    radius: 14
                    color: root.pal.box(Qt.alpha(root.pal.surface, 0.97))
                    border.width: 1; border.color: root.pal.line
                    MouseArea { anchors.fill: parent }
                    Column {
                        id: askCol
                        anchors.fill: parent; anchors.margins: 20
                        spacing: 14
                        Text {
                            width: parent.width
                            text: "Turn the screen border off too?"
                            color: root.pal.text; wrapMode: Text.WordWrap
                            font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            text: "The bar is off, but the frame around the screen is still on. It was drawn in the bar's colour and the boxes slide out from under it."
                            color: root.pal.muted; wrapMode: Text.WordWrap
                            font.family: root.pal.uiFont; font.pixelSize: 12
                        }
                        Row {
                            spacing: 10
                            Rectangle {
                                width: 170; height: 34; radius: 10
                                color: Qt.alpha(root.pal.accent, 0.22); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.7)
                                Text { anchors.centerIn: parent; text: "Turn the border off"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 12 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.setting("opt:frame", false); root.borderAsk = false } }
                            }
                            Rectangle {
                                width: 150; height: 34; radius: 10
                                color: "transparent"; border.width: 1; border.color: root.pal.line
                                Text { anchors.centerIn: parent; text: "Keep the border"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 12 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.borderAsk = false }
                            }
                        }
                    }
                }
            }
            focus: root.open
            Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { if (root.borderAsk) root.borderAsk = false; else root.hide(); e.accepted = true } }
            // the search box must be focused from in here: `search` is not visible from the root scope (this window is built by a LazyLoader)
            Timer { running: root.open; interval: 80; onTriggered: if (!root.galleryOpen) search.forceActiveFocus() }

            Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, root.pal.calm ? 0.55 : 0.40) }
            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Glass {
                id: card
                pal: root.pal
                anchors.centerIn: parent
                width: Math.min(parent.width - 100, 1320)
                height: parent.height - 80
                radius: root.pal.rXl
                opacityBody: root.pal.solid ? 1 : (root.opt.settingsGlass !== undefined ? root.opt.settingsGlass : 0.72)
                border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)
                scale: root.open ? 1 : 0.96
                Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                MouseArea { anchors.fill: parent }   // swallow clicks

                Backdrop {
                    visible: root.open && (root.opt.dialogStarStyle !== "moving") && root.opt.dialogStarStyle !== "none" && root.opt.stars !== false && root.opt.starsSettings !== false
                    anchors.fill: parent
                    anchors.margins: 12
                    pal: root.pal
                    mode: root.sysmode
                    avatarStars: root.starData
                    profileStars: root.profileStars
                    dots: 14
                    artStrength: 0.6
                    artFit: 0.85
                    paused: root.scrolling
                }

                BarStars {
                    z: 1
                    anchors.fill: parent
                    anchors.margins: 14
                    pal: root.pal
                    count: 12
                    loopMs: 140000
                    sizeScale: 1.4
                    active: root.open
                    visible: root.open && (root.opt.dialogStarStyle === "moving" || root.opt.dialogStarStyle === "both" || (root.opt.dialogStarStyle === undefined && root.opt.starsBar !== false))
                }

                // ---------------- header: title, search, collapse, close
                RowLayout {
                    id: head
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 36 }
                    spacing: 16
                    Text { visible: !root.pal.zen; text: String.fromCodePoint(0xF0493); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                    BoxTitle { pal: root.pal; size: 20; overlay: true; title: "Settings" }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 380
                        implicitHeight: root.pal.zen ? 38 : 34
                        radius: height / 2
                        color: root.pal.zen ? root.pal.field : Qt.alpha(root.pal.bg, 0.55)
                        border.width: root.pal.zen ? 0 : 1
                        border.color: search.activeFocus ? root.pal.lineFocus : root.pal.line
                        Text {
                            anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            text: root.pal.zen ? "Search settings" : String.fromCodePoint(0xF0349) + "  search settings"
                            color: root.pal.muted; font.family: root.pal.zen ? root.pal.uiFont : root.pal.font; font.pixelSize: root.pal.tBody
                        }
                        TextInput {
                            id: search
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.pal.text
                            selectionColor: Qt.alpha(root.pal.accent, 0.4)
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                            clip: true
                            Component.onCompleted: forceActiveFocus()
                            onTextChanged: { root.scrolling = true; settleT.restart(); qDebounce.restart() }
                            Timer { id: qDebounce; interval: 130; onTriggered: root.query = search.text }
                            Keys.onEscapePressed: { if (text !== "") text = ""; else root.hide() }
                        }
                    }
                    Text { visible: !root.pal.zen || root.query !== ""; text: root.shownCount + " settings"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                    Item { Layout.fillWidth: true }
                    SChip { pal: root.pal; label: root.advAll ? "Advanced: shown" : "Advanced: hidden"; on: root.advAll; onClicked: root.advAll = !root.advAll }
                    SChip { pal: root.pal; label: root.pagesMode ? "Tree view" : "Pages view"; onClicked: root.setting("opt:settingsStyle", root.pagesMode ? "tree" : "pages") }
                    SChip { visible: !root.pagesMode; pal: root.pal; label: "Collapse all"; onClicked: root.setAll(true) }
                    SChip { visible: !root.pagesMode; pal: root.pal; label: "Expand all"; onClicked: root.setAll(false) }
                    RoundBtn { pal: root.pal; glyph: "✕"; size: 32; onClicked: root.hide() }
                }

                // ---------------- section tabs: All / Appearance / Stars & splash / Bar & panels / Desktop / Productivity / Input & power / Performance / System
                Flow {
                    id: sectionRow
                    visible: !root.pagesMode
                    anchors { left: parent.left; right: parent.right; top: head.bottom; leftMargin: 36; rightMargin: 36; topMargin: 14 }
                    spacing: 10
                    opacity: root.query === "" ? 1 : 0.45
                    SChip { pal: root.pal; label: "All"; on: root.query === "" && root.section === ""; onClicked: { root.section = ""; scroll.contentY = 0 } }
                    Repeater {
                        model: root.sections
                        delegate: SChip {
                            required property var modelData
                            pal: root.pal
                            label: modelData
                            on: root.query === "" && root.section === modelData
                            onClicked: { root.section = modelData; scroll.contentY = 0 }
                        }
                    }
                }

                // ---------------- the pages layout: a trunk of pages on the left, flat cards on the right
                Item {
                    id: pagesView
                    visible: root.pagesMode
                    anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 36; topMargin: 22 }

                    // the trunk: one node per page
                    Item {
                        id: pagesNav
                        width: 190
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        opacity: root.query === "" ? 1 : 0.45
                        Rectangle { visible: !root.pal.calm; x: 5; y: 14; width: 1; height: navCol.height - 28; color: Qt.alpha(root.pal.accent, 0.4) }
                        Column {
                            id: navCol
                            width: parent.width
                            Repeater {
                                model: root.pages
                                delegate: Item {
                                    id: navItem
                                    required property var modelData
                                    readonly property bool cur: root.query === "" && root.page === navItem.modelData.id
                                    width: navCol.width
                                    height: root.pal.calm ? 38 : 40
                                    // calm: a soft pill under the current page instead of the trunk and its dots
                                    Rectangle {
                                        visible: root.pal.calm
                                        anchors { fill: parent; topMargin: 2; bottomMargin: 2; rightMargin: 14 }
                                        radius: height / 2
                                        color: navItem.cur ? root.pal.chosenFill : (navMa.containsMouse ? root.pal.fill : "transparent")
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                    }
                                    Rectangle {
                                        visible: !root.pal.calm
                                        x: 1; anchors.verticalCenter: parent.verticalCenter
                                        width: 9; height: 9; radius: 4.5
                                        color: navItem.cur ? root.pal.accent : root.pal.bg
                                        border.width: navItem.cur ? 0 : 1; border.color: root.pal.muted
                                        Rectangle { visible: navItem.cur; anchors.centerIn: parent; width: 17; height: 17; radius: 8.5; color: "transparent"; border.width: 4; border.color: Qt.alpha(root.pal.accent, 0.2) }
                                    }
                                    Text {
                                        x: root.pal.calm ? 16 : 28; anchors.verticalCenter: parent.verticalCenter
                                        text: navItem.modelData.id
                                        color: navItem.cur ? (root.pal.zen ? root.pal.chosenText : root.pal.calm ? root.pal.accent : root.pal.text) : (navMa.containsMouse ? root.pal.text : (root.pal.zen ? Qt.alpha(root.pal.text, 0.78) : root.pal.muted))
                                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1
                                        font.weight: navItem.cur ? Font.Medium : Font.Normal
                                    }
                                    MouseArea { id: navMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { if (search.text !== "") search.text = ""; root.query = ""; root.page = navItem.modelData.id; pscroll.contentY = 0 } }
                                }
                            }
                        }
                    }

                    Flickable {
                        id: pscroll
                        anchors { left: pagesNav.right; leftMargin: 28; right: parent.right; top: parent.top; bottom: parent.bottom }
                        contentWidth: width
                        contentHeight: pcol.height + 24
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        pixelAligned: true
                        flickDeceleration: 2800
                        maximumFlickVelocity: 3200
                        readonly property real maxY: Math.max(0, contentHeight - height)
                        onContentYChanged: { root.scrolling = true; settleT.restart() }
                        onMovementStarted: pwheelAnim.stop()
                        NumberAnimation { id: pwheelAnim; target: pscroll; property: "contentY"; duration: 230; easing.type: Easing.OutCubic }
                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: event => {
                                var pd = event.pixelDelta.y
                                if (pd !== 0) { pwheelAnim.stop(); pscroll.contentY = Math.max(0, Math.min(pscroll.maxY, pscroll.contentY - pd)) }
                                else {
                                    var base = pwheelAnim.running ? pwheelAnim.to : pscroll.contentY
                                    var to = Math.max(0, Math.min(pscroll.maxY, base - event.angleDelta.y / 120 * 90))
                                    pwheelAnim.stop(); pwheelAnim.to = to; pwheelAnim.start()
                                }
                                event.accepted = true
                            }
                        }

                        Column {
                            id: pcol
                            width: pscroll.width - 6
                            spacing: 0
                            Text {
                                text: root.query === "" ? root.page : "Search results"
                                bottomPadding: root.pal.zen && root.pal.hideHints && root.query === "" ? 22 : 0
                                color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 24; font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width
                                topPadding: 6; bottomPadding: 22
                                visible: !(root.pal.zen && root.pal.hideHints && root.query === "")
                                text: root.query === "" ? root.pageInfo(root.page).sub + "  Rarely used options sit behind Advanced." : root.shownCount + " settings match, from every page."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; wrapMode: Text.WordWrap
                            }

                            Repeater {
                                model: root.pagesMode ? root.pageGroupsNow : []
                                delegate: Column {
                                    id: pg
                                    required property var modelData
                                    width: pcol.width
                                    bottomPadding: 22
                                    spacing: 10
                                    Text {
                                        leftPadding: 4
                                        text: (root.pal.calm ? pg.modelData.title : pg.modelData.title.toUpperCase()) + (root.query !== "" ? "   \u00b7   " + root.pageOf(pg.modelData.id) : "")
                                        color: root.pal.zen ? root.pal.muted : root.pal.calm ? Qt.alpha(root.pal.text, 0.72) : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.zen ? 12 : root.pal.calm ? 13 : 11; font.weight: root.pal.calm ? Font.Medium : Font.DemiBold; font.letterSpacing: root.pal.calm ? 0.2 : (1.6)
                                    }
                                    Rectangle {
                                        width: pg.width
                                        height: rowsCol.height
                                        color: root.pal.zen ? root.pal.group : root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.surface, 0.55)
                                        radius: root.pal.calm ? root.pal.rLg : 16
                                        border.width: root.pal.calm ? 0 : 1; border.color: root.pal.lineSoft
                                        clip: true
                                        Column {
                                            id: rowsCol
                                            width: parent.width
                                            Repeater {
                                                model: pg.modelData.items
                                                delegate: Item {
                                                    id: pr
                                                    required property var modelData
                                                    required property int index
                                                    readonly property var m: pr.modelData
                                                    readonly property bool off: root.isOff(pr.m)
                                                    readonly property string descText: root.descOf(pr.m)
                                                    readonly property bool longDesc: root.pal.hideHints && descText !== ""        // Hide explanations: folded behind the ? (hover peeks, click keeps it open)
                                                    property bool descOpen: false
                                                    property bool descPeek: false
                                                    readonly property bool child: pr.m.when !== undefined && root.query === ""      // depends on the row above: a short branch
                                                    readonly property bool shortSeg: pr.m.type === "seg" && pr.m.drop !== true && pr.m.opts.length <= 3 && pr.m.opts.every(function (x) { return String(x.t).length <= 14 })
                                                    readonly property bool side: pr.m.type === "toggle" || pr.m.type === "tool" || pr.m.type === "action" || pr.m.type === "slider" || pr.shortSeg
                                                    width: rowsCol.width
                                                    height: body.implicitHeight + (root.pal.zen ? 36 : root.pal.calm ? 34 : 28)

                                                    Rectangle { visible: pr.index > 0; x: 18; width: parent.width - 36; height: 1; color: root.pal.lineSoft }
                                                    Rectangle { anchors.fill: parent; color: prMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.35) : "transparent" }
                                                    MouseArea { id: prMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                                    // a disabled row: greyed out (see isOff), nothing in it can be clicked, hovering says what to turn on
                                                    MouseArea { id: disMa; z: 20; anchors.fill: parent; visible: pr.m.dis !== undefined; enabled: pr.m.dis !== undefined; hoverEnabled: true; cursorShape: Qt.ForbiddenCursor }
                                                    // a dependent row hangs off the one above it
                                                    Rectangle { visible: pr.child; x: 30; y: 0; width: 1; height: 30; color: Qt.alpha(root.pal.accent, 0.45) }
                                                    Rectangle { visible: pr.child; x: 30; y: 30; width: 12; height: 1; color: Qt.alpha(root.pal.accent, 0.45) }

                                                    ColumnLayout {
                                                        id: body
                                                        x: pr.child ? 52 : 20; y: 14
                                                        width: pr.width - x - 20
                                                        spacing: 12
                                                        opacity: pr.off ? 0.45 : 1

                                                        RowLayout {
                                                            Layout.fillWidth: true
                                                            visible: pr.m.type !== "custom"
                                                            spacing: 20
                                                            ColumnLayout {
                                                                Layout.fillWidth: true
                                                                spacing: 4
                                                                RowLayout {
                                                                    Layout.fillWidth: true
                                                                    spacing: 8
                                                                    Text {
                                                                        Layout.maximumWidth: Math.max(60, body.width - 120)
                                                                        text: pr.m.type === "divider" ? (root.pal.calm ? (pr.m.label || "") : (pr.m.label || "").toUpperCase()) : (pr.m.label || "")
                                                                        color: pr.m.type === "divider" ? root.pal.muted : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: pr.m.type === "divider" ? 11 : root.pal.tBody + 1; font.weight: pr.m.type === "divider" ? Font.DemiBold : Font.Medium; font.letterSpacing: root.pal.calm ? 0.2 : (pr.m.type === "divider" ? 1.6 : 0); wrapMode: Text.WordWrap
                                                                    }
                                                                    Rectangle {
                                                                        visible: pr.longDesc && !root.pal.zen       // the new style: no ? at all (ask > instead)
                                                                        Layout.preferredWidth: 18; Layout.preferredHeight: 18; radius: 9
                                                                        color: pr.descOpen ? Qt.alpha(root.pal.accent, 0.22) : "transparent"
                                                                        border.width: 1; border.color: pr.descOpen ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
                                                                        Text { anchors.centerIn: parent; text: "?"; color: pr.descOpen ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; font.weight: Font.DemiBold }
                                                                        MouseArea { anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onContainsMouseChanged: pr.descPeek = containsMouse; onClicked: pr.descOpen = !pr.descOpen }
                                                                    }
                                                                    Item { Layout.fillWidth: true }
                                                                }
                                                                Text {
                                                                    Layout.fillWidth: true
                                                                    // always the whole text; Hide explanations folds it behind the ? (shown while it is hovered or clicked open)
                                                                    visible: text !== "" && (!pr.longDesc || pr.descOpen || pr.descPeek || (pr.m.dis !== undefined && disMa.containsMouse))
                                                                    text: (pr.m.dis !== undefined && disMa.containsMouse) ? pr.m.dis : pr.descText
                                                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 12; lineHeight: 1.25; wrapMode: Text.WordWrap
                                                                    MouseArea { anchors.fill: parent; enabled: pr.longDesc; cursorShape: Qt.PointingHandCursor; onClicked: pr.descOpen = !pr.descOpen }
                                                                }
                                                            }
                                                            // the control sits on the right
                                                            Toggle {
                                                                visible: pr.m.type === "toggle" || pr.m.type === "tool"
                                                                Layout.alignment: Qt.AlignVCenter
                                                                pal: root.pal
                                                                on: root.boolVal(pr.m)
                                                                busy: pr.m.type === "tool" && root.toolPending === pr.m.key
                                                                onToggled: pr.m.type === "tool" ? root.toolFlip(pr.m.key) : root.change(pr.m.key, !root.boolVal(pr.m))
                                                            }
                                                            ActionChip {
                                                                visible: pr.m.type === "action"
                                                                Layout.alignment: Qt.AlignVCenter
                                                                pal: root.pal
                                                                label: pr.m.btn || ""
                                                                doneLabel: pr.m.done || ""
                                                                disabled: pr.off
                                                                onClicked: { if (pr.off) return; root.action(pr.m.id); if (pr.m.close) root.hide() }
                                                            }
                                                            Slider {
                                                                visible: pr.m.type === "slider"
                                                                Layout.alignment: Qt.AlignVCenter
                                                                Layout.preferredWidth: 280
                                                                pal: root.pal
                                                                glyph: String.fromCodePoint(pr.m.glyph || 0xF0335)
                                                                value: pr.m.type === "slider" ? Math.max(0, Math.min(1, (root.num(pr.m) - pr.m.min) / (pr.m.max - pr.m.min))) : 0
                                                                readout: pr.m.type === "slider" ? root.fmt(pr.m, root.num(pr.m)) : ""
                                                                onMoved: v => {
                                                                    var raw = pr.m.min + v * (pr.m.max - pr.m.min)
                                                                    var q = Math.round(raw / pr.m.step) * pr.m.step
                                                                    root.change(pr.m.key, Math.round(q * 1000) / 1000)
                                                                }
                                                            }
                                                            Row {
                                                                visible: pr.shortSeg
                                                                Layout.alignment: Qt.AlignVCenter
                                                                spacing: 8
                                                                Repeater {
                                                                    model: pr.shortSeg ? pr.m.opts : []
                                                                    delegate: SChip {
                                                                        required property var modelData
                                                                        pal: root.pal
                                                                        label: modelData.t
                                                                        on: root.same(root.get(pr.m.key), modelData.v)
                                                                        onClicked: root.change(pr.m.key, modelData.v)
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        // the wide ones sit under the label: long option lists, several switches in one row
                                                        Flow {
                                                            Layout.fillWidth: true
                                                            visible: pr.m.drop !== true && ((pr.m.type === "seg" && !pr.shortSeg) || pr.m.type === "chips")
                                                            spacing: 10
                                                            Repeater {
                                                                model: (pr.m.drop !== true && ((pr.m.type === "seg" && !pr.shortSeg) || pr.m.type === "chips")) ? pr.m.opts : []
                                                                delegate: SChip {
                                                                    required property var modelData
                                                                    visible: pr.m.type !== "chips" || !modelData.when || root.whenOk(modelData.when)
                                                                    pal: root.pal
                                                                    label: modelData.t
                                                                    on: pr.m.type === "chips" ? !!root.get(modelData.k) : root.same(root.get(pr.m.key), modelData.v)
                                                                    onClicked: pr.m.type === "chips" ? root.change(modelData.k, !root.get(modelData.k)) : root.change(pr.m.key, modelData.v)
                                                                }
                                                            }
                                                        }
                                                        // a drop-down instead of a row of buttons (item.drop)
                                                        SDrop {
                                                            Layout.preferredWidth: 300
                                                            Layout.alignment: Qt.AlignLeft
                                                            visible: pr.m.drop === true
                                                            pal: root.pal
                                                            multi: pr.m.type === "chips"
                                                            items: pr.m.drop === true ? root.dropItems(pr.m) : []
                                                            summary: pr.m.drop === true ? root.dropSummary(pr.m) : ""
                                                            onPicked: i => root.dropPick(pr.m, i)
                                                        }
                                                        Flow {
                                                            Layout.fillWidth: true
                                                            visible: pr.m.type === "acts"
                                                            spacing: 10
                                                            Repeater {
                                                                model: pr.m.type === "acts" ? pr.m.btns : []
                                                                delegate: ActionChip {
                                                                    required property var modelData
                                                                    visible: !modelData.when || root.whenOk(modelData.when)
                                                                    pal: root.pal
                                                                    label: modelData.btn || ""
                                                                    doneLabel: modelData.done || ""
                                                                    disabled: pr.off
                                                                    onClicked: { if (pr.off) return; root.action(modelData.id); if (modelData.close) root.hide() }
                                                                }
                                                            }
                                                        }
                                                        Loader {
                                                            Layout.fillWidth: true
                                                            visible: pr.m.type === "custom"
                                                            active: pr.m.type === "custom"
                                                            sourceComponent: root.leafComp(pr.m.name)
                                                        }
                                                    }
                                                }
                                            }
                                            // the fold for this card's less used settings
                                            Item {
                                                visible: pg.modelData.advN > 0 && root.query === "" && !root.advAll
                                                width: rowsCol.width
                                                height: visible ? 46 : 0
                                                Rectangle { x: 18; y: 0; width: parent.width - 36; height: 1; color: root.pal.lineSoft }
                                                Text {
                                                    x: 20; anchors.verticalCenter: parent.verticalCenter
                                                    text: (pg.modelData.advShow ? "\u25be  Hide advanced" : "\u25b8  Advanced  \u00b7  " + pg.modelData.advN)
                                                    color: advPMa.containsMouse ? root.pal.text : root.pal.muted
                                                    font.family: root.pal.uiFont; font.pixelSize: 13
                                                }
                                                MouseArea { id: advPMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleAdv(pg.modelData.id) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------------- the tree
                Flickable {
                    id: scroll
                    visible: !root.pagesMode
                    anchors { left: parent.left; right: parent.right; top: sectionRow.bottom; bottom: parent.bottom; margins: 36; topMargin: 20 }
                    contentWidth: width
                    contentHeight: tree.height + 12
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    pixelAligned: true                 // whole-pixel positions: text does not shimmer while it moves
                    flickDeceleration: 2800
                    maximumFlickVelocity: 3200
                    readonly property real maxY: Math.max(0, contentHeight - height)

                    // "scrolling" = contentY moved in the last ~200 ms: the sky and the pulses stand still meanwhile
                    onContentYChanged: { root.scrolling = true; settleT.restart() }
                    onMovementStarted: wheelAnim.stop()
                    Timer { id: settleT; interval: 200; onTriggered: root.scrolling = false }

                    // mouse wheel: glide to the target instead of jumping a notch at a time
                    NumberAnimation { id: wheelAnim; target: scroll; property: "contentY"; duration: 230; easing.type: Easing.OutCubic }
                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: event => {
                            var pd = event.pixelDelta.y
                            if (pd !== 0) {                    // touchpad: already smooth, follow the fingers 1:1
                                wheelAnim.stop()
                                scroll.contentY = Math.max(0, Math.min(scroll.maxY, scroll.contentY - pd))
                            } else {                           // wheel notch (120 units): ~90 px, chained notches add up
                                var base = wheelAnim.running ? wheelAnim.to : scroll.contentY
                                var to = Math.max(0, Math.min(scroll.maxY, base - event.angleDelta.y / 120 * 90))
                                wheelAnim.stop()
                                wheelAnim.to = to
                                wheelAnim.start()
                            }
                            event.accepted = true
                        }
                    }

                    Item {
                        id: tree
                        width: scroll.width
                        readonly property real gap: 64
                        readonly property real colW: (width - (root.colCount - 1) * gap) / root.colCount
                        readonly property real barY: 72
                        readonly property real colsY: 98
                        property real colsH: 0
                        height: colsY + colsH + 24

                        function measure() {
                            var h = 0
                            for (var i = 0; i < colRep.count; i++) {
                                var c = colRep.itemAt(i)
                                if (c) h = Math.max(h, c.height)
                            }
                            colsH = h
                        }

                        // pulses that run down the branches
                        property real tt: 0
                        NumberAnimation on tt { from: 0; to: 1; duration: 3600; loops: Animation.Infinite; running: root.open && !root.pagesMode && root.pal.motion > 0.3 && !root.scrolling }

                        // ---- root node
                        Rectangle {
                            id: rootNode
                            width: rootRow.implicitWidth + 36
                            height: 42
                            radius: 21
                            anchors.horizontalCenter: parent.horizontalCenter
                            color: Qt.alpha(root.pal.accent, 0.16)
                            border.width: 1
                            border.color: Qt.alpha(root.pal.accent, 0.55)
                            Row {
                                id: rootRow
                                anchors.centerIn: parent
                                spacing: 10
                                Text { text: String.fromCodePoint(0xF0493); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 17; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: "Halcyon"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: root.groupsNow.length + " branches  ·  everything applies at once"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; anchors.verticalCenter: parent.verticalCenter }
                            }
                        }
                        Rectangle { visible: root.groupsNow.length > 0; x: tree.width / 2; y: rootNode.height; width: 1; height: tree.barY - rootNode.height; color: Qt.alpha(root.pal.accent, 0.45) }
                        Rectangle {
                            visible: root.groupsNow.length > 0
                            readonly property real firstX: 10
                            readonly property real lastX: (root.usedCols - 1) * (tree.colW + tree.gap) + 10
                            x: Math.min(firstX, tree.width / 2)
                            y: tree.barY
                            width: Math.max(1, Math.max(lastX, tree.width / 2) - x)
                            height: 1
                            color: Qt.alpha(root.pal.accent, 0.45)
                        }
                        Repeater {
                            model: root.groupsNow.length > 0 ? root.usedCols : 0
                            delegate: Item {
                                required property int index
                                readonly property real cx: index * (tree.colW + tree.gap) + 10
                                Rectangle { x: parent.cx; y: tree.barY; width: 1; height: tree.colsY - tree.barY; color: Qt.alpha(root.pal.accent, 0.45) }
                                Rectangle { x: parent.cx - 3; y: tree.barY - 3; width: 7; height: 7; radius: 3.5; color: root.pal.accent; opacity: 0.8 }
                                Rectangle {
                                    visible: root.pal.motion > 0.3
                                    x: parent.cx - 2
                                    y: tree.barY + (tree.colsY - tree.barY) * ((tree.tt + index * 0.23) % 1)
                                    width: 5; height: 5; radius: 2.5
                                    color: root.pal.accent
                                    opacity: Math.sin(((tree.tt + index * 0.23) % 1) * Math.PI) * 0.9
                                }
                            }
                        }

                        // ---- the columns of branches
                        Repeater {
                            id: colRep
                            model: root.pagesMode ? [] : root.columns        // the hidden view builds nothing (it was every row of every page, twice)
                            delegate: Column {
                                id: col
                                required property var modelData
                                required property int index
                                x: index * (tree.colW + tree.gap)
                                y: tree.colsY
                                width: tree.colW
                                spacing: 0
                                onHeightChanged: tree.measure()
                                Component.onCompleted: tree.measure()

                                Repeater {
                                    model: col.modelData
                                    delegate: Item {
                                        id: grp
                                        required property var modelData
                                        required property int index
                                        readonly property bool lastGroup: grp.index === col.modelData.length - 1
                                        readonly property bool shut: root.query === "" && !!root.collapsed[grp.modelData.id]
                                        width: col.width
                                        height: grpHead.height + leavesBox.height + 36

                                        // the column's trunk
                                        Rectangle {
                                            x: 10; y: 0; width: 1
                                            height: grp.lastGroup ? grpHead.height / 2 : grp.height
                                            color: Qt.alpha(root.pal.accent, 0.45)
                                        }

                                        // group node + title (click to fold)
                                        Item {
                                            id: grpHead
                                            width: parent.width
                                            height: 48
                                            Rectangle {
                                                x: 3; anchors.verticalCenter: parent.verticalCenter
                                                width: 15; height: 15; radius: 7.5
                                                color: Qt.alpha(root.pal.accent, 0.25)
                                                border.width: 1.5
                                                border.color: root.pal.accent
                                                Rectangle { anchors.centerIn: parent; width: 5; height: 5; radius: 2.5; color: root.pal.accent }
                                            }
                                            Text {
                                                id: groupTitle
                                                x: 28; anchors.verticalCenter: parent.verticalCenter
                                                text: (root.pal.calm ? grp.modelData.title : grp.modelData.title.toUpperCase())
                                                color: root.pal.accent
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 12
                                                font.weight: Font.DemiBold
                                                font.letterSpacing: root.pal.calm ? 0.2 : (1.6)
                                            }
                                            Text {
                                                x: 28 + groupTitle.implicitWidth + 12; anchors.verticalCenter: parent.verticalCenter
                                                visible: root.section === "" || root.query !== ""
                                                text: (grp.modelData.section || "").toLowerCase()
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 10
                                                opacity: 0.75
                                            }
                                            Text {
                                                anchors.right: parent.right; anchors.rightMargin: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: grp.modelData.items.length + "  " + (grp.shut ? "▸" : "▾")
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 11
                                            }
                                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleGroup(grp.modelData.id) }
                                        }

                                        // leaves
                                        Item {
                                            id: leavesBox
                                            y: grpHead.height
                                            width: parent.width
                                            height: grp.shut ? 0 : leaves.height
                                            clip: height !== leaves.height      // only while folding; a clip node per group splits batching
                                            opacity: grp.shut ? 0 : 1
                                            Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                                            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

                                            Column {
                                                id: leaves
                                                width: parent.width
                                                spacing: 0

                                                Repeater {
                                                    model: grp.modelData.items
                                                    delegate: Item {
                                                        id: leaf
                                                        required property var modelData
                                                        required property int index
                                                        readonly property var m: leaf.modelData
                                                        readonly property bool lastLeaf: leaf.index === grp.modelData.items.length - 1
                                                        readonly property bool off: (m.needs !== undefined && !(root.startup.has && root.startup.has[m.needs] === true)) || m.dis !== undefined   // an optional part that was not installed, or a switch that is off (Disabled): greyed out
                                                        readonly property bool inline: m.type === "toggle" || m.type === "tool" || m.type === "action"
                                                        // the description as one line; the full text opens with the small "?" (or a click on the line)
                                                        readonly property string descText: root.descOf(leaf.m)
                                                        readonly property bool longDesc: root.pal.hideHints && descText !== ""        // Hide explanations: folded behind the ? (hover peeks, click keeps it open)
                                                        property bool descOpen: false
                                                        property bool descPeek: false
                                                        width: leaves.width
                                                        height: Math.max(56, content.implicitHeight + 32)

                                                        // sub-trunk + elbow
                                                        Rectangle { x: 34; y: 0; width: 1; height: leaf.lastLeaf ? 28 : leaf.height; color: Qt.alpha(root.pal.accent, 0.28) }
                                                        Rectangle { x: 34; y: 28; width: 16; height: 1; color: Qt.alpha(root.pal.accent, 0.28) }
                                                        Rectangle { x: 50; y: 28 - 3; width: 6; height: 6; radius: 3; color: Qt.alpha(root.pal.accent, 0.6) }

                                                        Rectangle {
                                                            anchors { fill: content; margins: -10; rightMargin: -8 }
                                                            radius: 12
                                                            color: leafMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.45) : "transparent"
                                                            Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                                        }
                                                        MouseArea { id: leafMa; anchors.fill: content; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                                        // a disabled row: nothing in it can be clicked, hovering says what to turn on
                                                        MouseArea { id: leafDisMa; z: 20; anchors.fill: content; visible: leaf.m.dis !== undefined; enabled: leaf.m.dis !== undefined; hoverEnabled: true; cursorShape: Qt.ForbiddenCursor }

                                                        ColumnLayout {
                                                            id: content
                                                            x: 70; y: 16
                                                            width: leaf.width - 70 - 10
                                                            spacing: 14

                                                            // label (+ description) and the inline control
                                                            RowLayout {
                                                                Layout.fillWidth: true
                                                                spacing: 20
                                                                visible: leaf.m.type !== "custom"
                                                                opacity: leaf.off ? 0.45 : 1
                                                                ColumnLayout {
                                                                    Layout.fillWidth: true
                                                                    spacing: 5
                                                                    RowLayout {
                                                                        Layout.fillWidth: true
                                                                        spacing: 8
                                                                        Text {
                                                                            Layout.maximumWidth: Math.max(60, content.width - 140)
                                                                            text: leaf.m.type === "divider" ? (root.pal.calm ? (leaf.m.label || "") : (leaf.m.label || "").toUpperCase()) : (leaf.m.label || "")
                                                                            color: leaf.m.type === "divider" ? root.pal.muted : root.pal.text
                                                                            font.family: root.pal.uiFont
                                                                            font.pixelSize: leaf.m.type === "divider" ? 11 : root.pal.tBody
                                                                            font.letterSpacing: root.pal.calm ? 0.2 : (leaf.m.type === "divider" ? 1.6 : 0)
                                                                            font.weight: leaf.m.type === "divider" ? Font.DemiBold : Font.Medium
                                                                            wrapMode: Text.WordWrap
                                                                        }
                                                                        Rectangle {
                                                                            visible: leaf.longDesc && !root.pal.zen
                                                                            Layout.preferredWidth: 18; Layout.preferredHeight: 18
                                                                            radius: 9
                                                                            color: leaf.descOpen ? Qt.alpha(root.pal.accent, 0.22) : (qMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.9) : "transparent")
                                                                            border.width: root.pal.zen && !(leaf.descOpen) ? 0 : 1
                                                                            border.color: leaf.descOpen ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
                                                                            Text { anchors.centerIn: parent; text: "?"; color: leaf.descOpen ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; font.weight: Font.DemiBold }
                                                                            MouseArea { id: qMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onContainsMouseChanged: leaf.descPeek = containsMouse; onClicked: leaf.descOpen = !leaf.descOpen }
                                                                        }
                                                                        Item { Layout.fillWidth: true }
                                                                    }
                                                                    Text {
                                                                        Layout.fillWidth: true
                                                                        // always the whole text; Hide explanations folds it behind the ? (shown while it is hovered or clicked open)
                                                                        visible: text !== "" && (!leaf.longDesc || leaf.descOpen || leaf.descPeek || (leaf.m.dis !== undefined && leafDisMa.containsMouse))
                                                                        text: (leaf.m.dis !== undefined && leafDisMa.containsMouse) ? leaf.m.dis : leaf.descText
                                                                        color: root.pal.muted
                                                                        font.family: root.pal.uiFont
                                                                        font.pixelSize: 11
                                                                        lineHeight: 1.3
                                                                        wrapMode: Text.WordWrap
                                                                        MouseArea { anchors.fill: parent; enabled: leaf.longDesc; cursorShape: Qt.PointingHandCursor; onClicked: leaf.descOpen = !leaf.descOpen }
                                                                    }
                                                                }
                                                                Toggle {
                                                                    visible: leaf.m.type === "toggle" || leaf.m.type === "tool"
                                                                    Layout.alignment: Qt.AlignTop
                                                                    pal: root.pal
                                                                    on: root.boolVal(leaf.m)
                                                                    busy: leaf.m.type === "tool" && root.toolPending === leaf.m.key
                                                                    onToggled: leaf.m.type === "tool" ? root.toolFlip(leaf.m.key) : root.change(leaf.m.key, !root.boolVal(leaf.m))
                                                                }
                                                                ActionChip {
                                                                    visible: leaf.m.type === "action"
                                                                    Layout.alignment: Qt.AlignTop
                                                                    pal: root.pal
                                                                    label: leaf.m.btn || ""
                                                                    doneLabel: leaf.m.done || ""
                                                                    disabled: leaf.off
                                                                    onClicked: { if (leaf.off) return; root.action(leaf.m.id); if (leaf.m.close) root.hide() }
                                                                }
                                                            }

                                                            // pick one (seg) / switch several on and off (chips: every chip flips its own key)
                                                            Flow {
                                                                Layout.fillWidth: true
                                                                visible: leaf.m.drop !== true && (leaf.m.type === "seg" || leaf.m.type === "chips")
                                                                spacing: 10
                                                                Repeater {
                                                                    model: (leaf.m.drop !== true && (leaf.m.type === "seg" || leaf.m.type === "chips")) ? leaf.m.opts : []
                                                                    delegate: SChip {
                                                                        required property var modelData
                                                                        visible: leaf.m.type !== "chips" || !modelData.when || root.whenOk(modelData.when)
                                                                        pal: root.pal
                                                                        label: modelData.t
                                                                        on: leaf.m.type === "chips" ? !!root.get(modelData.k) : root.same(root.get(leaf.m.key), modelData.v)
                                                                        onClicked: leaf.m.type === "chips" ? root.change(modelData.k, !root.get(modelData.k)) : root.change(leaf.m.key, modelData.v)
                                                                    }
                                                                }
                                                            }

                                                            // a drop-down instead of a row of buttons (item.drop)
                                                            SDrop {
                                                                Layout.preferredWidth: 300
                                                                Layout.alignment: Qt.AlignLeft
                                                                visible: leaf.m.drop === true
                                                                pal: root.pal
                                                                multi: leaf.m.type === "chips"
                                                                items: leaf.m.drop === true ? root.dropItems(leaf.m) : []
                                                                summary: leaf.m.drop === true ? root.dropSummary(leaf.m) : ""
                                                                onPicked: i => root.dropPick(leaf.m, i)
                                                            }

                                                            // several buttons in one row
                                                            Flow {
                                                                Layout.fillWidth: true
                                                                visible: leaf.m.type === "acts"
                                                                spacing: 10
                                                                Repeater {
                                                                    model: leaf.m.type === "acts" ? leaf.m.btns : []
                                                                    delegate: ActionChip {
                                                                        required property var modelData
                                                                        visible: !modelData.when || root.whenOk(modelData.when)
                                                                        pal: root.pal
                                                                        label: modelData.btn || ""
                                                                        doneLabel: modelData.done || ""
                                                                        disabled: leaf.off
                                                                        onClicked: { if (leaf.off) return; root.action(modelData.id); if (modelData.close) root.hide() }
                                                                    }
                                                                }
                                                            }

                                                            // drag
                                                            Slider {
                                                                Layout.fillWidth: true
                                                                visible: leaf.m.type === "slider"
                                                                pal: root.pal
                                                                glyph: String.fromCodePoint(leaf.m.glyph || 0xF0335)
                                                                value: leaf.m.type === "slider" ? Math.max(0, Math.min(1, (root.num(leaf.m) - leaf.m.min) / (leaf.m.max - leaf.m.min))) : 0
                                                                readout: leaf.m.type === "slider" ? root.fmt(leaf.m, root.num(leaf.m)) : ""
                                                                onMoved: v => {
                                                                    var raw = leaf.m.min + v * (leaf.m.max - leaf.m.min)
                                                                    var q = Math.round(raw / leaf.m.step) * leaf.m.step
                                                                    root.change(leaf.m.key, Math.round(q * 1000) / 1000)
                                                                }
                                                            }

                                                            // wallpaper picker, default apps, constellations, colour swatches
                                                            Loader {
                                                                Layout.fillWidth: true
                                                                visible: leaf.m.type === "custom"
                                                                active: leaf.m.type === "custom" && !grp.shut
                                                                sourceComponent: root.leafComp(leaf.m.name)
                                                            }
                                                        }
                                                    }
                                                }

                                                // fold for the less used settings of this group
                                                Item {
                                                    visible: grp.modelData.advN > 0 && root.query === "" && !root.advAll
                                                    width: leaves.width
                                                    height: visible ? 44 : 0
                                                    Rectangle { x: 34; y: 0; width: 1; height: 22; color: Qt.alpha(root.pal.accent, 0.28) }
                                                    Rectangle { x: 34; y: 22; width: 16; height: 1; color: Qt.alpha(root.pal.accent, 0.28) }
                                                    Rectangle {
                                                        x: 62; anchors.verticalCenter: parent.verticalCenter
                                                        width: advRow.implicitWidth + 24; height: 28; radius: 14
                                                        color: advMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.8) : Qt.alpha(root.pal.surface, 0.5)
                                                        border.width: 1; border.color: grp.modelData.advShow ? Qt.alpha(root.pal.accent, 0.4) : root.pal.lineSoft
                                                        Row {
                                                            id: advRow
                                                            anchors.centerIn: parent
                                                            spacing: 8
                                                            Text { text: grp.modelData.advShow ? "▾" : "▸"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                                                            Text { text: grp.modelData.advShow ? "Hide advanced" : "Advanced  ·  " + grp.modelData.advN; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                                                        }
                                                        MouseArea { id: advMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleAdv(grp.modelData.id) }
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
        }
    }
}
    // ======================================================================== the Wallpaper Gallery window
    // Opens on its own (`>wallpaper gallery`, the Settings chip, IPC): a full-screen overlay with the gallery on it.
    LazyLoader {
        active: root.galleryLoaded
        PanelWindow {
            id: gwin
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-gallery"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.galleryOpen && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // opens one frame after the window exists, so the fade-in plays
            property bool shown: false
            Timer { running: true; interval: 30; onTriggered: gwin.shown = true }

            WallpaperGallery {
                id: wallpaperGallery
                anchors.fill: parent
                sysmode: root.sysmode
                starData: root.starData
                profileStars: root.profileStars
                movingStars: root.opt.starsBar !== false
                open: root.galleryOpen && gwin.shown
                onClosed: root.galleryOpen = false
                pal: root.pal
                wp: root.wp
                colors: root.wpColors
                onPicked: path => root.pickWallpaper(path)
                onAction: act => root.wpAct(act)
            }
        }
    }

    // ======================================================================== the Bar builder window
    // A full-screen overlay with the builder on it (drag widgets into the left / middle / right of the bar).
    LazyLoader {
        active: root.builderLoaded
        PanelWindow {
            id: bwin
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-barbuilder"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.builderOpen && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // opens one frame after the window exists, so the fade-in plays
            property bool shown: false
            Timer { running: true; interval: 30; onTriggered: bwin.shown = true }

            BarBuilderWindow {
                anchors.fill: parent
                open: root.builderOpen && bwin.shown
                pal: root.pal
                layout: root.get("opt:barLayout")
                barPadding: root.barPadding
                spacious: root.get("opt:notchSpacing") === "spacious"
                wifiLook: root.get("opt:notchWifiStyle") || "bars"
                btMode: root.get("opt:notchBtMode") || "connected"
                showBatPct: root.get("opt:notchBatPct") === true
                sysmode: root.sysmode
                starData: root.starData
                profileStars: root.profileStars
                movingStars: root.opt.starsBar !== false
                onClosed: root.builderOpen = false
                onEdited: l => root.setting("opt:barLayout", l)
                frameOn: root.get("opt:frame") === true
                frameW: root.get("opt:frameW") !== undefined ? Number(root.get("opt:frameW")) : 12
                frameR: root.get("opt:frameR") !== undefined ? Number(root.get("opt:frameR")) : 22
                onFrameEdited: (k, v) => root.setting(k, v)
            }
        }
    }

    // ======================================================================== the Notification box builder window
    LazyLoader {
        active: root.nbLoaded
        PanelWindow {
            id: nbwin
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-notifbuilder"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.nbOpen && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // opens one frame after the window exists, so the fade-in plays
            property bool shown: false
            Timer { running: true; interval: 30; onTriggered: nbwin.shown = true }

            NotifBuilderWindow {
                anchors.fill: parent
                open: root.nbOpen && nbwin.shown
                pal: root.pal
                layout: root.get("opt:notifLayout")
                look: root.get("opt:notifStyle") || "stack"
                sysmode: root.sysmode
                starData: root.starData
                profileStars: root.profileStars
                stars: root.opt.stars !== false && root.opt.starsNotifs !== false
                movingStars: root.opt.starsBar !== false
                onClosed: root.nbOpen = false
                onEdited: l => root.setting("opt:notifLayout", l)
                onLookChosen: v => root.setting("opt:notifStyle", v)
            }
        }
    }

    // ======================================================================== the Desktop builder window
    LazyLoader {
        active: root.dbLoaded
        PanelWindow {
            id: dbwin
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-desktopbuilder"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.dbOpen && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // opens one frame after the window exists, so the fade-in plays
            property bool shown: false
            Timer { running: true; interval: 30; onTriggered: dbwin.shown = true }

            DesktopBuilderWindow {
                anchors.fill: parent
                open: root.dbOpen && dbwin.shown
                pal: root.pal
                opt: root.opt
                wallpaperPath: root.wallpaperPath
                globalClick: root.clickMode
                target: root.dbTarget
                onTargetPicked: t => root.dbTarget = (t === "lock") ? "lock" : "desktop"
                onClosed: root.dbOpen = false
                onOpenWidgets: t => { root.dbOpen = false; root.openWidgetBuilder("", t) }
                onEditDesktop: t => { root.dbOpen = false; root.editOnDesktop(t) }
                onChanged: (k, v) => root.setting("opt:" + k, v)
            }
        }
    }

    // ======================================================================== the Widget builder window
    LazyLoader {
        active: root.wbLoaded
        PanelWindow {
            id: wbwin
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-widgetbuilder"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.wbOpen && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            property bool shown: false
            Timer { running: true; interval: 30; onTriggered: wbwin.shown = true }

            WidgetBuilderWindow {
                id: wbw
                anchors.fill: parent
                open: root.wbOpen && wbwin.shown
                pal: root.pal
                env: root.env
                opt: root.opt
                wallpaper: root.wallpaperPath
                pick: root.wbPick
                target: root.wbTarget
                onTargetPicked: t => root.wbTarget = t
                onClosed: { root.wbOpen = false; root.wbPick = "" }
                onEditOnDesktop: t => { root.wbOpen = false; root.editOnDesktop(t) }
                onChanged: (k, v) => root.setting("opt:" + k, v)
            }
        }
    }

    // ======================================================================== the Startup & processes window
    // A full-screen overlay with one card on it. It reads scripts/startup-view.py every 5 s while it is open, and nothing otherwise.
    LazyLoader {
        active: root.startupLoaded
        PanelWindow {
            id: swin
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-startup"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.startupOpen && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // opens one frame after the window exists, so the fade-in plays
            property bool shown: false
            Timer { running: true; interval: 30; onTriggered: swin.shown = true }

            StartupWindow {
                anchors.fill: parent
                pal: root.pal
                movingStars: root.opt.starsBar !== false
                limRam: root.opt.limRam !== undefined ? Number(root.opt.limRam) : 600
                limCpu: root.opt.limCpu !== undefined ? Number(root.opt.limCpu) : 10
                adaptive: root.opt.limMode === "auto"
                open: root.startupOpen && swin.shown
                onClosed: root.startupOpen = false
                onPresetPicked: m => root.change("opt:resMode", m)
                // like the Game Center: this window closes first (it holds the keyboard), then the console opens with the command
                onConsoleRequested: cmd => { root.startupOpen = false; if (root.env && typeof root.env.consolePrefill === "function") root.env.consolePrefill(cmd) }
            }
        }
    }
}
