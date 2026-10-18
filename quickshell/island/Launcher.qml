import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// One bar for everything:
//   <text>   search apps (clutter like qv4l2 / avahi / Qt tools is hidden)
//   .        every installed app, A-Z  (".fire" filters that list)
//   >        list of commands (random wallpaper, calculator, settings, power options, ...)
//   =        calculator, e.g.  =2*(3+4)   (Enter copies the result)
Item {
    id: root
    property var pal
    property bool active: false
    signal closeRequested()
    signal commandRequested(string cmdId)

    // ---- query history (Up / Down while typing). Newest last; saved in ~/.local/state/island/launcher-history.log
    property var history: []
    property int histIdx: -1            // -1 = what you are typing now, 0 = newest entry, 1 = the one before ...
    property string histDraft: ""
    property bool histBusy: false       // true while history itself is changing the text
    property real hx: -1                // last REAL pointer position, so scrolling under a resting pointer does not move the selection
    property real hy: -1
    function pushHistory(q) {
        q = (q || "").trim()
        if (q === "") return false
        var h = history.filter(function (x) { return x !== q })
        h.push(q)
        if (h.length > 100) h = h.slice(h.length - 100)
        history = h
        return true
    }
    function saveHistory(q) {
        if (pushHistory(q))
            Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.local/state/island && printf '%s\\n' \"$0\" >> ~/.local/state/island/launcher-history.log", q.trim()])
    }
    function histStep(d) {                 // d = +1 older (Up), -1 newer (Down)
        if (history.length === 0) return
        var ni = Math.min(history.length - 1, histIdx + d)
        if (ni < -1 || ni === histIdx) return
        if (histIdx === -1) histDraft = input.text
        histIdx = ni
        histBusy = true
        input.text = ni === -1 ? histDraft : history[history.length - 1 - ni]
        input.cursorPosition = input.text.length
        histBusy = false
    }
    function stepResult(d) {               // Tab / Shift+Tab: next / previous result, wraps around
        var n = results.length
        if (n === 0) return
        grid.currentIndex = (grid.currentIndex + d + n) % n
    }

    property var usage: ({})
    property int serial: 0
    property string query: ""
    property var results: []
    property var cmdResults: []
    property string pendingConfirm: ""
    property bool stagger: false        // staggered entrance only right after opening
    readonly property real decay: 0.97

    // Apps hidden from the normal list and search; they only show up after typing "."
    // (lower-case substrings, matched against the app name and its desktop id). Edit freely.
    readonly property var hiddenPatterns: [
        "avahi", "bssh", "bvnc", "qv4l2", "qvidcap", "lstopo", "hardware locality",
        "xwayland", "qt assistant", "qt designer", "qt linguist", "qdbusviewer", "qdbus",
        "cmake", "jconsole", "jshell", "java policy", "java web", "openjdk", "ibus", "fcitx",
        "uxterm", "xterm", "xfce4-", "nm-connection", "kbuildsycoca", "org.freedesktop",
        "gtk3 icon browser", "gtk-demo", "gtk4 ", "adwaita", "pcmanfm-desktop", "polkit",
        "cups", "system-config-printer", "vim", "electron", "bluetooth adapters", "blueman-adapters",
        "kvantum", "qt5 settings", "qt6 settings", "qt5ct", "qt6ct", "nwg-", "lsp-plugins"
    ]
    // search index per app, built once (cleared when the app list changes): lower-cased name, lower-cased extra text, hidden or not
    property var appIdx: ({})
    function info(a) {
        var k = a.id || a.name
        var x = appIdx[k]
        if (x) return x
        x = { name: (a.name || "").toLowerCase(),
              extra: ((a.genericName || "") + " " + (a.comment || "") + " " + String(a.keywords || "")).toLowerCase(),
              hidden: isHidden(a) }
        appIdx[k] = x
        return x
    }
    // same entries in the same order? then the model is left alone (replacing it rebuilds every delegate)
    function sameList(a, b) {
        if (a.length !== b.length) return false
        for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
        return true
    }
    function isHidden(a) {
        var hay = ((a.name || "") + " " + (a.id || "")).toLowerCase()
        for (var i = 0; i < hiddenPatterns.length; i++)
            if (hay.indexOf(hiddenPatterns[i]) >= 0) return true
        return false
    }

    property string cmdCategory: "all"
    property int infoIdx: -1              // the command row whose description popup is open (-1 = none)
    // the order of the command list: groups first, then this order inside each group (anything not listed goes last)
    readonly property var catOrder: ["system", "desktop", "tools", "power"]
    readonly property var cmdOrder: [
        "settings", "display", "printer", "wifi", "bluetooth", "startupview", "quickterm", "cheatsheet", "reload", "tour",
        "desktopbuilder", "widgetbuilder", "desktopedit", "bartoggle", "barbuilder", "notifbuilder", "wallgallery", "wallpaper", "theme", "barstyle", "edgemode", "routing",
        "calendar", "notes", "notesall", "clipboard", "screenshot", "lyrics", "queue", "calc", "record", "extradim", "caffeine", "dnd", "notifications", "apps",
        "power", "gaming", "profile-auto", "profile-power-saver", "profile-balanced", "profile-performance", "lock", "suspend", "logout", "reboot", "shutdown"
    ]
    readonly property bool cmdGrouped: mode === "cmd" && q0.substring(1).trim() === "" && cmdCategory === "all"
    function cmdRank(c) {
        var ci = catOrder.indexOf(c.cat), oi = cmdOrder.indexOf(c.id)
        return (ci < 0 ? 9 : ci) * 1000 + (oi < 0 ? 999 : oi)
    }

    // ---- commands (">" mode). confirm = needs Enter twice.
    readonly property var commands: [
        { id: "wallgallery", name: "Wallpaper gallery", desc: "Interactive 3D carousel & search gallery (Tide style)", glyph: 0xF024B, kw: "wallpapers gallery background images picker choose coverflow", cat: "desktop" },
        { id: "startupview", name: "Startup & processes", desc: "Everything that starts with the desktop and what is running: RAM, CPU, switches, End", glyph: 0xF035B, kw: "startup autostart boot login processes running ram memory cpu htop task manager services apps kill end", cat: "system" },
        { id: "calendar", name: "Calendar", desc: "Google Calendar: your events by day, with reminder notifications", glyph: 0xF00ED, kw: "calender calendar agenda schedule tasks events google reminders meeting", cat: "tools" },
        { id: "notes", name: "New note", desc: "A small panel on the side of the screen: type a note and press Enter to save it (Super + N)", glyph: 0xF03EB, kw: "notes note new write memo text scratchpad todo tasks quick add", cat: "tools" },
        { id: "notesall", name: "All notes", desc: "Every note in one window: search, filter, pin, tick off, copy and delete", glyph: 0xF03EB, kw: "notes all view list browse read search saved memo scratchpad todo tasks pinned", cat: "tools" },
        { id: "clipboard", name: "Clipboard history", desc: "What you copied lately: search, click or Enter to copy it back, delete one or clear all. Copies from password managers are not kept", glyph: 0xF014C, kw: "clipboard history copy paste copied clip cliphist recent wl-copy", cat: "tools" },
        { id: "screenshot", name: "Screenshot", desc: "A small panel: Region, Window or Full screen, then Copy, Save or Both (Super + Ctrl + S). Super + Shift + S still drags a region at once", glyph: 0xF0100, kw: "screenshot screen capture grim slurp region window full print snip snap", cat: "tools" },
        { id: "lyrics", name: "Lyrics", desc: "The lyrics of the song that plays, in a panel on the side. Works with any player that shows up in the bar (Spotify app, browser, mpv ...): from a .lrc file next to the song, lrclib.net or lyrics.ovh, and spotify_player if you have it. Also the Lyrics chip on the music page", glyph: 0xF0387, kw: "lyrics song words music spotify sing text genius spotify_player", cat: "tools" },
        { id: "queue", name: "Music queue", desc: "What plays next on your Spotify account (needs spotify_player). Read-only: it shows the queue, it does not change it. Also the Queue chip on the music page", glyph: 0xF0CB9, kw: "queue next up music spotify playlist upcoming songs spotify_player", cat: "tools" },
        { id: "record", name: "Screen recorder", desc: "On-demand screen or audio recording, with desktop sound and / or microphone, to ~/Videos/Recordings (Super + Alt + R)", glyph: 0xF012F, kw: "record screen capture video stream cast obs", cat: "tools" },
        { id: "tour", name: "Guided tour", desc: "Replay the walkthrough of the island, its panels and shortcuts", glyph: 0xF02D6, kw: "tutorial help intro welcome walkthrough onboarding whats new release notes learn", cat: "system" },
        { id: "barbuilder", name: "Bar builder", desc: "Drag widgets into the left, middle and right of your own bar", glyph: 0xF0208, kw: "bar custom widgets layout drag drop builder edit", cat: "desktop" },
        { id: "widgetbuilder", name: "Widget builder", desc: "Desktop widgets (clock, system usage, music, visualizer, focus streak ...): pick a layout and a look for each", glyph: 0xF0208, kw: "widgets desktop clock battery wifi stats cpu music visualizer focus streak weather style look design builder customise", cat: "desktop" },
        { id: "desktopedit", name: "Place widgets on the desktop", desc: "Drag, resize and add your widgets right on the screen", glyph: 0xF0208, kw: "widgets desktop move drag place resize edit layout", cat: "desktop" },
        { id: "bartoggle", name: "Top bar on / off", desc: "Switch the top bar off (use desktop widgets instead) or back on", glyph: 0xF0208, kw: "bar top off hide disable remove widgets", cat: "desktop" },
        { id: "desktopbuilder", name: "Desktop builder", desc: "Wallpaper, blur, moving stars, where the widgets sit, and the activation zone (corner) of each box", glyph: 0xF0208, kw: "desktop wallpaper background blur stars moving corner boxes activation position hot corner builder", cat: "desktop" },
        { id: "notifbuilder", name: "Notification box builder", desc: "Arrange the notification box: its parts, constellations, flying stars, padding, width and place on the screen", glyph: 0xF009A, kw: "notifications notification box builder layout design style timeline grouped stars constellation padding edit customise", cat: "desktop" },
        { id: "reload", name: "Reload", desc: "Reload Hyprland, the terminal colours and the island", glyph: 0xF0450, kw: "restart refresh apply config hyprland island quickshell", cat: "system" },
        { id: "wallpaper", name: "Random wallpaper", desc: "Switch to a new wallpaper now", glyph: 0xF02E9, kw: "background change image", cat: "desktop" },
        { id: "calc", name: "Calculator", desc: "Type = then an expression", glyph: 0xF00EB, kw: "math calculate", cat: "tools" },
        { id: "theme", name: "Light / dark theme", desc: "Switch the whole desktop between the dark and the light theme (toggle)", glyph: 0xF0594, kw: "dark light mode appearance colours day night", cat: "desktop" },
        { id: "settings", name: "Settings", desc: "Theme, wallpaper, scrolling, default apps, transparency, motion, gaming", glyph: 0xF0493, kw: "rice options look theme gear config", cat: "system" },
        { id: "extradim", name: "Extra dim display", desc: "Dim screen backlight to minimum (Super + Alt + D)", glyph: 0xF058F, kw: "dim brightness backlight dark night minimum screen", cat: "tools" },
        { id: "power", name: "Power options", desc: "Lock, sleep, log out, restart, shut down", glyph: 0xF0425, kw: "session", cat: "power" },
        { id: "gaming", name: "Gaming mode", desc: "Performance profile, effects off, helpers stopped (toggle)", glyph: 0xF0297, kw: "game fast performance snappy", cat: "power" },
        { id: "caffeine", name: "Caffeine (keep screen awake)", desc: "No dimming, idle lock or idle sleep until you turn it off (toggle)", glyph: 0xF0176, kw: "coffee awake sleep idle lock inhibit stay on", cat: "tools" },
        { id: "apps", name: "Background apps", desc: "Spotify, Discord ... running without a window: open or quit them", glyph: 0xF003B, kw: "running tray spotify discord quit close processes", cat: "tools" },
        { id: "routing", name: "App routing on / off", desc: "Send Spotify to the music workspace and Discord to communication when they open (toggle)", glyph: 0xF0A2D, kw: "spotify discord music communication workspace automatic move", cat: "desktop" },
        { id: "cheatsheet", name: "Shortcuts (cheatsheet)", desc: "Tree of every shortcut and gesture; change them or add your own", glyph: 0xF030C, kw: "keybinds keys shortcuts bindings gestures help", cat: "system" },
        { id: "notifications", name: "Notifications", desc: "Open the notification centre", glyph: 0xF009A, kw: "notifs inbox bell history", cat: "tools" },
        { id: "quickterm", name: "Quick terminal", desc: "Pop-out terminal for one-shot commands and sysmode", glyph: 0xF0489, kw: "terminal shell command console sysmode run", cat: "system" },
        { id: "edgemode", name: "Edge boxes: hover / click", desc: "Open notifications, console and utilities by hovering the edge, or by clicking it", glyph: 0xF0A2D, kw: "edge hover click corner notifications console utilities toggle", cat: "desktop" },
        { id: "dnd", name: "Toggle do not disturb", desc: "Silence popups, keep storing notifications", glyph: 0xF009B, kw: "notifications mute quiet focus", cat: "tools" },
        { id: "barstyle", name: "Switch bar style", desc: "Island (floating pill) or Notch (hangs from the top edge)", glyph: 0xF0208, kw: "bar style notch island", cat: "desktop" },
        { id: "display", name: "Display & Projector Manager", desc: "Mirror screen to projector, extend right/left, or external-only (Super + P)", glyph: 0xF021F, kw: "monitor display screen projector mirror clone extend dual second presentation", cat: "system" },
        { id: "printer", name: "Printer Manager", desc: "Manage printers, print queue, and CUPS settings", glyph: 0xF042A, kw: "printer print cups documents hardware add queue", cat: "system" },
        { id: "profile-auto", name: "Power mode: Auto", desc: "Let the power manager decide (load, battery, heat)", glyph: 0xF0079, kw: "battery profile", cat: "power" },
        { id: "profile-power-saver", name: "Power mode: Battery saver", desc: "", glyph: 0xF0079, kw: "battery profile", cat: "power" },
        { id: "profile-balanced", name: "Power mode: Balanced", desc: "", glyph: 0xF0079, kw: "battery profile", cat: "power" },
        { id: "profile-performance", name: "Power mode: Performance", desc: "", glyph: 0xF04C5, kw: "battery profile speed", cat: "power" },
        { id: "wifi", name: "Toggle Wi-Fi", desc: "", glyph: 0xF0928, kw: "network wireless", cat: "system" },
        { id: "bluetooth", name: "Toggle Bluetooth", desc: "", glyph: 0xF00AF, kw: "bt", cat: "system" },
        { id: "lock", name: "Lock screen", desc: "", glyph: 0xF033E, kw: "", cat: "power" },
        { id: "suspend", name: "Sleep", desc: "", glyph: 0xF04B2, kw: "suspend", cat: "power" },
        { id: "logout", name: "Log out", desc: "", glyph: 0xF0343, kw: "exit", confirm: true, cat: "power" },
        { id: "reboot", name: "Restart", desc: "", glyph: 0xF0709, kw: "reboot", confirm: true, cat: "power" },
        { id: "shutdown", name: "Shut down", desc: "", glyph: 0xF0425, kw: "poweroff", confirm: true, cat: "power" }
    ]

    // ---- mode
    readonly property string q0: query.replace(/^\s+/, "")
    readonly property string mode: q0.charAt(0) === ">" ? "cmd"
                                 : (q0.charAt(0) === "=" ? "calc"
                                 : (q0.charAt(0) === "." ? "all" : "apps"))
    readonly property bool gridMode: mode === "apps" || mode === "all"
    readonly property var calcOut: evalCalc(q0.substring(1))

    // ---- size the bar should grow to (the island follows these)
    readonly property int rows: mode === "all" ? Math.max(1, Math.min(4, Math.ceil(results.length / 6)))
                              : (query.trim() === "" ? 2 : Math.max(1, Math.min(3, Math.ceil(results.length / 6))))
    readonly property real wantedWidth: gridMode ? 680 : 540
    readonly property real wantedHeight: {
        // margins 36 + search 46 + header 14 + footer 16 + 4 gaps of 12 = 160 + content
        if (mode === "calc") return 36 + 46 + 12 + 64
        if (mode === "cmd") return 160 + Math.max(1, Math.min(7, cmdResults.length)) * 46 + (infoIdx >= 0 && cmdResults[infoIdx] ? infoBox.height + 12 : 0)
        return 160 + (results.length === 0 ? 40 : rows * 92)
    }

    // ---- usage ranking (decayed launch count, log in ~/.local/state/island/usage.log)
    property bool dirty: true           // the result list is out of date (usage changed); rebuilt on the next open
    function bumpScore(id) {
        dirty = true
        serial++
        var u = usage[id]
        usage[id] = { s: (u ? u.s * Math.pow(decay, serial - u.n) : 0) + 1, n: serial }
    }
    function score(id) {
        var u = usage[id]
        return u ? u.s * Math.pow(decay, serial - u.n) : 0
    }
    function fuzzy(q, s) {
        var j = 0
        for (var i = 0; i < s.length && j < q.length; i++) if (s[i] === q[j]) j++
        return j === q.length
    }

    function evalCalc(expr) {
        var e = expr.trim().toLowerCase()
        if (e === "") return { ok: false, text: "" }
        var s = e.replace(/\^/g, "**")
                 .replace(/\b(sqrt|sin|cos|tan|abs|floor|ceil|round|pow)\b/g, "Math.$1")
                 .replace(/\b(ln|log)\b/g, "Math.log")
                 .replace(/\bpi\b/g, "Math.PI")
        // whatever is left (after removing the Math.* names) may only be digits, operators, brackets
        if (!/^[0-9+\-*\/%().,\s]*$/.test(s.replace(/Math\.[A-Za-z]+/g, "0")))
            return { ok: false, text: "…" }
        try {
            var v = eval(s)
            if (typeof v !== "number" || !isFinite(v)) return { ok: false, text: "…" }
            return { ok: true, text: String(parseFloat(v.toPrecision(12))) }
        } catch (err) {
            return { ok: false, text: "…" }
        }
    }

    function refresh() {
        dirty = false
        if (mode === "cmd") {
            var cq = q0.substring(1).trim().toLowerCase()
            var outc = []
            for (var c = 0; c < commands.length; c++) {
                var cm = commands[c]
                if (root.cmdCategory !== "all" && cm.cat !== root.cmdCategory) continue
                var nm = cm.name.toLowerCase()
                var r = 1
                if (cq !== "") {
                    if (nm.indexOf(cq) === 0) r = 4
                    else if (nm.indexOf(cq) >= 0) r = 3
                    else if ((cm.kw + " " + cm.desc + " " + (cm.cat || "")).toLowerCase().indexOf(cq) >= 0) r = 2
                    else if (cq.length > 1 && fuzzy(cq, nm)) r = 1
                    else continue
                }
                outc.push({ c: cm, r: r, i: c })
            }
            outc.sort(function (x, y) { return (y.r - x.r) || (root.cmdRank(x.c) - root.cmdRank(y.c)) || (x.i - y.i) })
            var ncmd = outc.map(function (o) { return o.c })
            infoIdx = -1
            if (!sameList(ncmd, cmdResults)) cmdResults = ncmd
            cmdList.currentIndex = 0
            return
        }
        if (mode === "calc") return

        var showAll = mode === "all"
        var apps = DesktopEntries.applications.values
        var q = (showAll ? q0.substring(1) : query).trim().toLowerCase()
        var out = []
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i]
            if (a.noDisplay) continue
            var ix = info(a)
            if (!showAll && ix.hidden) continue
            var name = ix.name
            var rank = 1
            if (q !== "") {
                if (name.indexOf(q) === 0) rank = 5
                else if (name.indexOf(" " + q) >= 0) rank = 4
                else if (name.indexOf(q) >= 0) rank = 3
                else if (ix.extra.indexOf(q) >= 0) rank = 2
                else if (q.length > 1 && fuzzy(q, name)) rank = 1
                else continue
            }
            out.push({ e: a, rank: rank, s: score(a.id) })
        }
        if (showAll && q === "") {
            out.sort(function (x, y) { return x.e.name.localeCompare(y.e.name) })
        } else {
            out.sort(function (x, y) {
                return (y.rank - x.rank) || (y.s - x.s) || x.e.name.localeCompare(y.e.name)
            })
        }
        // nothing typed: only what you actually use (padded a little on a fresh install)
        if (!showAll && q === "") {
            var used = out.filter(function (o) { return o.s > 0.02 }).slice(0, 12)
            if (used.length < 6) {
                var have = {}
                used.forEach(function (o) { have[o.e.id] = true })
                var pad = out.filter(function (o) { return !have[o.e.id] })
                    .sort(function (x, y) { return x.e.name.localeCompare(y.e.name) })
                used = used.concat(pad.slice(0, 12 - used.length))
            }
            out = used
        }
        var nres = out.map(function (o) { return o.e })
        if (!sameList(nres, results)) results = nres
        grid.currentIndex = 0
    }

    function iconFor(e) {
        var ic = e && e.icon ? e.icon : ""
        if (!ic) return Quickshell.iconPath("application-x-executable")
        if (ic.indexOf("/") === 0) return "file://" + ic
        return Quickshell.iconPath(ic, "application-x-executable")
    }

    function launch(i) {
        var e = results[i]
        if (!e) return
        saveHistory(query)
        bumpScore(e.id)
        Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.local/state/island && echo \"$0\" >> ~/.local/state/island/usage.log", e.id])
        e.execute()
        closeRequested()
    }

    function runCmd(i) {
        var c = cmdResults[i]
        if (!c) return
        if (c.confirm && pendingConfirm !== c.id) { pendingConfirm = c.id; return }
        pendingConfirm = ""
        saveHistory(query)
        if (c.id === "calc") {            // stay in the bar, switch to calculator mode
            input.text = "="
            input.cursorPosition = 1
            return
        }
        commandRequested(c.id)
        closeRequested()
    }

    function copyCalc() {
        if (!calcOut.ok) return
        saveHistory(query)
        Quickshell.execDetached(["wl-copy", calcOut.text])
        closeRequested()
    }

    Timer { id: staggerT; interval: 600; onTriggered: root.stagger = false }

    onActiveChanged: {
        if (active) {
            stagger = true
            staggerT.restart()
            var had = query
            input.text = ""
            query = ""
            cmdCategory = "all"
            infoIdx = -1
            pendingConfirm = ""
            histIdx = -1; histDraft = ""
            // rebuilding the grid while the island starts to grow is what made opening choppy: only do it when it is needed
            if (had !== "" || dirty) refresh()
            Qt.callLater(function () { input.forceActiveFocus() })
        }
    }

    Component.onCompleted: refresh()

    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { root.appIdx = ({}); refreshT.restart() }
    }
    Timer { id: refreshT; interval: 150; onTriggered: root.refresh() }

    Process {
        running: true
        command: ["sh", "-c", "f=~/.local/state/island/launcher-history.log; [ -f \"$f\" ] || exit 0; if [ \"$(wc -l < \"$f\")\" -gt 200 ]; then tail -n 100 \"$f\" > \"$f.tmp\" && mv -f \"$f.tmp\" \"$f\"; fi; tail -n 100 \"$f\" 2>/dev/null"]
        stdout: SplitParser { onRead: d => root.pushHistory(d) }
    }

    Process {
        running: true
        command: ["sh", "-c", "f=~/.local/state/island/usage.log; [ -f \"$f\" ] || exit 0; if [ \"$(wc -l < \"$f\")\" -gt 4000 ]; then tail -n 3000 \"$f\" > \"$f.tmp\" && mv -f \"$f.tmp\" \"$f\"; fi; tail -n 3000 \"$f\" 2>/dev/null"]
        stdout: SplitParser {
            onRead: d => {
                var id = d.trim()
                if (id) root.bumpScore(id)
            }
        }
        onExited: root.refresh()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        // ---------- search bar ----------
        Rectangle {
            id: bar
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            radius: 23
            color: Qt.alpha(root.pal.surface, 0.85)
            border.width: 1
            border.color: input.activeFocus ? root.pal.lineFocus : root.pal.line
            Behavior on border.color { ColorAnimation { duration: 180 } }

            // soft glow while typing
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 4
                color: "transparent"
                border.width: 4
                border.color: root.pal.accent
                opacity: input.activeFocus ? 0.07 : 0
                Behavior on opacity { NumberAnimation { duration: 240 } }
            }

            Text {
                id: mag
                x: 18
                anchors.verticalCenter: parent.verticalCenter
                text: String.fromCodePoint(root.mode === "cmd" ? 0xF0493 : (root.mode === "calc" ? 0xF00EB : (root.mode === "all" ? 0xF003B : 0xF0349)))
                color: root.pal.accent
                font.family: root.pal.font
                font.pixelSize: 18
            }
            Text {
                visible: input.text === ""
                anchors.left: input.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Search apps…"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 15
            }
            TextInput {
                id: input
                anchors.left: mag.right
                anchors.leftMargin: 12
                anchors.right: badge.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                color: root.pal.text
                selectionColor: root.pal.accent
                selectedTextColor: root.pal.bg
                font.family: root.pal.uiFont
                font.pixelSize: 15
                clip: true
                onTextChanged: { root.query = text; root.pendingConfirm = ""; if (!root.histBusy) root.histIdx = -1; root.refresh() }

                // Up / Down / Left / Right: with something typed they walk through the apps; with the box empty, Up / Down are older / newer
                // searches (in the command list Up / Down move the selection) and Left / Right move the text cursor
                // Tab / Shift+Tab (or Ctrl+N / Ctrl+P): next / previous result;  Ctrl+Up / Ctrl+Down: a row up / down
                Keys.onPressed: e => {
                    var cmd = root.mode === "cmd", calc = root.mode === "calc"
                    var ctrl = (e.modifiers & Qt.ControlModifier) !== 0
                    // once something is typed (and you are not paging through old searches), the arrow keys walk through the apps:
                    // Up / Down a row, Left / Right one app. Shift / Alt + Left / Right and Ctrl + Left / Right still move the text cursor.
                    var nav = root.gridMode && root.results.length > 0 && root.query !== "" && root.histIdx === -1
                    var plain = (e.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
                    if (e.key === Qt.Key_Escape) { if (root.infoIdx >= 0) root.infoIdx = -1; else root.closeRequested(); e.accepted = true }
                    else if (e.key === Qt.Key_Down) {
                        if (cmd) { cmdList.incrementCurrentIndex(); root.pendingConfirm = "" }
                        else if (ctrl) { if (!calc) grid.moveCurrentIndexDown() }
                        else if (nav) grid.moveCurrentIndexDown()
                        else root.histStep(-1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Up) {
                        if (cmd) { cmdList.decrementCurrentIndex(); root.pendingConfirm = "" }
                        else if (ctrl) { if (!calc) grid.moveCurrentIndexUp() }
                        else if (nav) grid.moveCurrentIndexUp()
                        else root.histStep(1)
                        e.accepted = true
                    }
                    else if (nav && plain && e.key === Qt.Key_Right) { grid.moveCurrentIndexRight(); e.accepted = true }
                    else if (nav && plain && e.key === Qt.Key_Left) { grid.moveCurrentIndexLeft(); e.accepted = true }
                    else if (e.key === Qt.Key_Tab || (ctrl && e.key === Qt.Key_N)) {
                        if (cmd) { cmdList.incrementCurrentIndex(); root.pendingConfirm = "" } else if (!calc) root.stepResult(1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Backtab || (ctrl && e.key === Qt.Key_P)) {
                        if (cmd) { cmdList.decrementCurrentIndex(); root.pendingConfirm = "" } else if (!calc) root.stepResult(-1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (cmd) root.runCmd(cmdList.currentIndex)
                        else if (calc) root.copyCalc()
                        else root.launch(grid.currentIndex)
                        e.accepted = true
                    }
                }
            }

            // current mode, so "." / ">" / "=" are never a mystery
            Rectangle {
                id: badge
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                height: 24
                width: badgeTxt.implicitWidth + 20
                radius: 12
                color: Qt.alpha(root.pal.accent, 0.14)
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Text {
                    id: badgeTxt
                    anchors.centerIn: parent
                    text: root.mode === "cmd" ? "commands" : (root.mode === "calc" ? "calculator" : (root.mode === "all" ? "all apps" : "apps"))
                    color: root.pal.accent
                    font.family: root.pal.uiFont
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    font.letterSpacing: 0.4
                }
            }
        }

        // ---------- section label & category tabs ----------
        RowLayout {
            visible: root.mode !== "calc"
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            spacing: 8

            Text {
                text: root.mode === "cmd" ? "COMMANDS"
                    : root.mode === "all" ? "ALL APPS · " + root.results.length
                    : (root.query === "" ? "MOST USED" : "RESULTS")
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
                Layout.alignment: Qt.AlignVCenter
            }

            Item { Layout.fillWidth: true }

            Row {
                visible: root.mode === "cmd"
                spacing: 5
                Layout.alignment: Qt.AlignVCenter

                Repeater {
                    model: [
                        { id: "all", label: "All" },
                        { id: "desktop", label: "Desktop" },
                        { id: "system", label: "System" },
                        { id: "tools", label: "Tools" },
                        { id: "power", label: "Power" }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool activeCat: root.cmdCategory === modelData.id
                        height: 20
                        width: catText.implicitWidth + 16
                        radius: 10
                        color: activeCat ? Qt.alpha(root.pal.accent, 0.20) : (catMa.containsMouse ? Qt.alpha(root.pal.text, 0.08) : Qt.alpha(root.pal.text, 0.03))
                        border.width: 1
                        border.color: activeCat ? Qt.alpha(root.pal.accent, 0.45) : Qt.alpha(root.pal.lineSoft, 0.4)
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Behavior on border.color { ColorAnimation { duration: 120 } }

                        Text {
                            id: catText
                            anchors.centerIn: parent
                            text: modelData.label
                            font.family: root.pal.uiFont
                            font.pixelSize: 10
                            font.weight: activeCat ? Font.DemiBold : Font.Normal
                            color: activeCat ? root.pal.accent : (catMa.containsMouse ? root.pal.text : root.pal.muted)
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }

                        MouseArea {
                            id: catMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.cmdCategory = modelData.id
                                root.refresh()
                            }
                        }
                    }
                }
            }
        }

        // ---------- apps ----------
        GridView {
            id: grid
            visible: root.gridMode && root.results.length > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: Math.floor(width / 6)
            cellHeight: 92
            model: root.results
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 260
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, GridView.Contain)

            // one pill that slides between apps instead of every cell lighting up on its own
            highlight: Item {
                width: grid.cellWidth
                height: grid.cellHeight
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: 18
                    color: Qt.alpha(root.pal.accent, 0.13)
                    border.width: 1
                    border.color: Qt.alpha(root.pal.accent, 0.28)
                }
            }

            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool cur: GridView.isCurrentItem
                width: grid.cellWidth
                height: grid.cellHeight

                // entrance: smooth, unified glide up + fade without jarring stagger
                property real appear: 0
                opacity: appear
                transform: Translate { y: (1 - cell.appear) * 5 }
                Component.onCompleted: enterAnim.start()
                NumberAnimation {
                    id: enterAnim
                    target: cell; property: "appear"; to: 1
                    duration: 150
                    easing.type: Easing.OutCubic
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 7
                    scale: ma.pressed ? 0.94 : 1
                    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                    Image {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 42
                        height: 42
                        sourceSize: Qt.size(84, 84)
                        source: root.iconFor(cell.modelData)
                        asynchronous: true
                        smooth: true
                        scale: cell.cur ? 1.08 : (ma.containsMouse ? 1.04 : 1)
                        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    }
                    Text {
                        width: cell.width - 16
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: cell.modelData.name
                        color: cell.cur ? root.pal.text : Qt.alpha(root.pal.text, 0.78)
                        font.family: root.pal.uiFont
                        font.pixelSize: 11
                        font.weight: cell.cur ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: m => {
                        var g = mapToItem(root, m.x, m.y)
                        if (Math.abs(g.x - root.hx) > 1 || Math.abs(g.y - root.hy) > 1) { root.hx = g.x; root.hy = g.y; grid.currentIndex = cell.index }
                    }
                    onClicked: root.launch(cell.index)
                }
            }
        }
        Text {
            visible: root.gridMode && root.results.length === 0
            text: root.mode === "all" ? "No app matches that" : "No apps found — type  .  to see every app,  >  for commands"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 13
            Layout.leftMargin: 10
            Layout.fillHeight: true
            verticalAlignment: Text.AlignVCenter
        }

        // ---------- commands ----------
        ListView {
            id: cmdList
            visible: root.mode === "cmd"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.cmdResults
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 150
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            highlight: Rectangle {
                width: cmdList.width
                height: 46
                radius: 14
                color: Qt.alpha(root.pal.accent, 0.13)
                border.width: 1
                border.color: Qt.alpha(root.pal.accent, 0.28)
            }

            delegate: Item {
                id: crow
                required property var modelData
                required property int index
                width: cmdList.width
                height: 46

                property real appear: 0
                opacity: appear
                transform: Translate { x: (1 - crow.appear) * 5 }
                Component.onCompleted: cEnter.start()
                NumberAnimation { id: cEnter; target: crow; property: "appear"; to: 1; duration: 130; easing.type: Easing.OutCubic }

                Text {
                    id: cg
                    x: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(crow.modelData.glyph)
                    color: root.pal.accent
                    font.family: root.pal.font
                    font.pixelSize: 18
                }
                Text {
                    id: cname
                    anchors.left: cg.right
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: crow.modelData.name
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }
                Rectangle {
                    id: ccatBadge
                    anchors.left: cname.right
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    height: 18
                    width: ccatTxt.implicitWidth + 12
                    radius: 9
                    color: {
                        var cat = crow.modelData.cat
                        if (cat === "power") return Qt.alpha(root.pal.accent2, 0.16)
                        if (cat === "tools") return Qt.alpha(root.pal.good || root.pal.accent, 0.16)
                        if (cat === "system") return Qt.alpha(root.pal.warn || root.pal.accent, 0.16)
                        return Qt.alpha(root.pal.accent, 0.12)
                    }
                    border.width: 1
                    border.color: {
                        var cat = crow.modelData.cat
                        if (cat === "power") return Qt.alpha(root.pal.accent2, 0.35)
                        if (cat === "tools") return Qt.alpha(root.pal.good || root.pal.accent, 0.35)
                        if (cat === "system") return Qt.alpha(root.pal.warn || root.pal.accent, 0.35)
                        return Qt.alpha(root.pal.accent, 0.28)
                    }
                    Text {
                        id: ccatTxt
                        anchors.centerIn: parent
                        text: (crow.modelData.cat || "cmd").toUpperCase()
                        font.family: root.pal.uiFont
                        font.pixelSize: 9
                        font.weight: Font.DemiBold
                        font.letterSpacing: 0.6
                        color: {
                            var cat = crow.modelData.cat
                            if (cat === "power") return root.pal.accent2
                            if (cat === "tools") return root.pal.good || root.pal.accent
                            if (cat === "system") return root.pal.warn || root.pal.accent
                            return root.pal.accent
                        }
                    }
                }
                Text {
                    // only while a Enter-twice command waits for its confirmation; the description lives behind the info button
                    anchors.right: infoBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.pendingConfirm === crow.modelData.id
                    text: "press Enter again to confirm"
                    color: root.pal.accent2
                    font.family: root.pal.uiFont
                    font.pixelSize: 11
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: m => {
                        var g = mapToItem(root, m.x, m.y)
                        if (Math.abs(g.x - root.hx) > 1 || Math.abs(g.y - root.hy) > 1) { root.hx = g.x; root.hy = g.y; cmdList.currentIndex = crow.index }
                    }
                    onClicked: root.runCmd(crow.index)
                }
                // thin line where a new group starts (only in the plain, ordered list)
                Rectangle {
                    visible: root.cmdGrouped && crow.index > 0 && root.cmdResults[crow.index - 1] && root.cmdResults[crow.index - 1].cat !== crow.modelData.cat
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.leftMargin: 16; anchors.rightMargin: 16
                    y: 0; height: 1
                    color: Qt.alpha(root.pal.accent, 0.22)
                }
                // right-most: the description button
                Rectangle {
                    id: infoBtn
                    visible: (crow.modelData.desc || "") !== ""
                    readonly property bool openNow: root.infoIdx === crow.index
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24; height: 24; radius: 12
                    color: openNow ? Qt.alpha(root.pal.accent, 0.25) : (infoMa.containsMouse ? Qt.alpha(root.pal.text, 0.10) : "transparent")
                    border.width: 1
                    border.color: openNow ? Qt.alpha(root.pal.accent, 0.55) : Qt.alpha(root.pal.lineSoft, 0.6)
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(0xF02FD)
                        font.family: root.pal.font
                        font.pixelSize: 14
                        color: infoBtn.openNow ? root.pal.accent : root.pal.muted
                    }
                    MouseArea {
                        id: infoMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.infoIdx = infoBtn.openNow ? -1 : crow.index; cmdList.currentIndex = crow.index; input.forceActiveFocus() }
                    }
                }
            }
        }

        // ---------- description popup: extends the open menu downwards ----------
        Rectangle {
            id: infoBox
            readonly property var cur: root.infoIdx >= 0 ? root.cmdResults[root.infoIdx] : null
            visible: root.mode === "cmd" && cur !== null
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? height : 0
            height: infoCol.implicitHeight + 24
            radius: 16
            color: Qt.alpha(root.pal.accent, 0.09)
            border.width: 1
            border.color: Qt.alpha(root.pal.accent, 0.30)
            Column {
                id: infoCol
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                anchors.topMargin: 12
                spacing: 4
                Text {
                    width: parent.width
                    text: infoBox.cur ? infoBox.cur.name : ""
                    color: root.pal.text
                    font.family: root.pal.uiFont; font.pixelSize: 13; font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: infoBox.cur ? infoBox.cur.desc : ""
                    color: root.pal.muted
                    font.family: root.pal.uiFont; font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    lineHeight: 1.2
                }
            }
        }

        // ---------- calculator ----------
        Rectangle {
            visible: root.mode === "calc"
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            radius: 18
            color: Qt.alpha(root.pal.accent, 0.12)
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: root.calcOut.text === "" ? "type an expression" : "= " + root.calcOut.text
                color: root.calcOut.ok ? root.pal.text : root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 22
                font.bold: root.calcOut.ok
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                visible: root.calcOut.ok
                text: "Enter to copy"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 11
            }
        }

        // ---------- footer hints ----------
        Row {
            visible: root.mode !== "calc"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 16
            spacing: 18
            Repeater {
                model: root.mode === "cmd"
                    ? [["↑↓", "move"], ["⏎", "run"], ["esc", "close"]]
                    : [["↑↓", "history"], ["←→", "cursor"], ["tab", "move"], ["⏎", "open"], [".", "all apps"], [">", "commands"], ["=", "calc"]]
                delegate: Row {
                    required property var modelData
                    spacing: 5
                    Text {
                        text: modelData[0]
                        color: root.pal.accent
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: modelData[1]
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                    }
                }
            }
        }
    }
}
