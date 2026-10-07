import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// Rice settings: one centred window, blurred backdrop, "node" cards in the same look as the SUPER+TAB tree.
// Everything here is applied live and remembered (settings.json); Hyprland values are re-applied when the island starts.
//   Esc or a click outside closes it.   Open: gear in the utilities panel, `>settings`, SUPER+F11.
Scope {
    id: root
    property var pal
    property string sysmode: ""
    property bool open: false

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
    property var opt: ({})                 // the extra settings (shell.qml "opt"): colour cycling, workspaces, clock, popups ...
    property var hyCur: ({})               // Hyprland values as they are now (shell.qml): where the sliders start

    // ---- Tools: what is switched on right now (scripts/tool-state.sh), so a switch always shows the truth
    property var tools: ({ nightlight: false, nightlightOk: true, touchpad: true, gestures: true, wifips: false, wifiOk: true, temp: 4000 })
    property string toolPending: ""
    readonly property var toolActions: ({ nightlight: "nightlight", touchpad: "touchpad", gestures: "gestures", wifips: "wifi-powersave" })
    function toolFlip(k) {
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
    // wallpaper folder (scripts/wallpapers.sh): the folder, the wallpaper in use, every image in it
    property var wp: ({ dir: "", current: "", files: [] })
    property string wpText: ""
    readonly property string wpScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/wallpapers.sh"
    function wpAct(a) {
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
    Timer { id: wpAgain; interval: 1500; onTriggered: if (!wpProc.running) wpProc.running = true }
    Timer { id: wpPoll; interval: 4000; running: root.open; repeat: true; triggeredOnStart: true; onTriggered: if (!wpProc.running) wpProc.running = true }
    Process {
        id: wpProc
        command: ["bash", root.wpScript, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.wpText) return          // nothing changed: keep the thumbnails as they are
                root.wpText = text
                try { root.wp = JSON.parse(text) } catch (e) {}
            }
        }
    }

    Timer { id: appsAgain; interval: 600; onTriggered: if (!appsProc.running) appsProc.running = true }
    Process {
        id: appsProc
        command: ["bash", root.appsScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.apps = JSON.parse(text) } catch (e) {} } }
    }

    signal setting(string key, var value)
    signal wallpaperSet(string path)  // a thumbnail was clicked
    signal action(string id)          // wallpaper | config | cheatsheet | reload

    function show() { open = true }
    function hide() { open = false }
    function toggle() { open = !open }

    component SChip: Chip { maxLabel: 1000 }

    // ======================================================================== the tree
    // group { id, title, items[] }.  item types:
    //   toggle  { key, label, desc }                         a switch
    //   tool    { key, label, desc }                         a switch for something a script owns (shows its real state)
    //   seg     { key, label, desc, opts: [{v, t}] }         pick one
    //   slider  { key, label, desc, min, max, step, ... }    drag
    //   action  { id, label, btn, done, desc }               a button that does something
    //   custom  { name }                                     wallpaper picker, default apps, constellations, colour swatches
    // key: "theme" = a property of this window, "opt:x" / "hy:x" = shell.qml's opt / Hyprland values
    function o(v, t) { return { v: v, t: t } }
    readonly property var groups: [
        { id: "look", title: "Look", items: [
            { type: "seg", key: "theme", label: "Theme", desc: "Island, panels, lock screen, window borders and apps (GTK / Qt) follow it. Colours still come from the wallpaper.", opts: [o("dark", "Dark"), o("light", "Light")] },
            { type: "slider", key: "opt:settingsGlass", def: 0.72, label: "Settings window opacity", desc: "Lower = more see-through: the blurred wallpaper and windows show through the Settings window.", min: 0.35, max: 1, step: 0.01, scale: 100, unit: " %", glyph: 0xF0335 },
            { type: "slider", key: "glassShift", label: "Transparency", desc: "Of the island, panels and overlays", min: -0.15, max: 0.05, step: 0.01, scale: 100, signed: true, glyph: 0xF0335 },
            { type: "slider", key: "colorBoost", label: "Colour intensity", desc: "How strongly the wallpaper's colour shows in the accent. 100 % is natural.", min: 0.5, max: 1.5, step: 0.05, scale: 100, unit: " %", glyph: 0xF03D8 },
            { type: "custom", name: "swatches" },
            { type: "slider", key: "rounding", label: "Corner rounding", desc: "Window corners", min: 0, max: 28, step: 1, unit: " px", glyph: 0xF0A39 },
            { type: "slider", key: "gaps", label: "Gaps", desc: "Between windows (the outer gap is double)", min: 0, max: 20, step: 1, unit: " px", glyph: 0xF0B36 },
            { type: "slider", key: "hy:borderSize", def: 2, label: "Border width", min: 0, max: 6, step: 1, unit: " px" },
            { type: "slider", key: "hy:inactiveOpacity", def: 1, label: "Unfocused window opacity", desc: "Below 100 % windows you are not using turn see-through", min: 0.5, max: 1, step: 0.05, scale: 100, unit: " %" },
            { type: "toggle", key: "blur", label: "Blur" },
            { type: "slider", key: "hy:blurSize", def: 8, label: "Blur strength", min: 1, max: 16, step: 1 },
            { type: "slider", key: "hy:blurPasses", def: 2, label: "Blur quality", desc: "More passes look smoother and cost more GPU", min: 1, max: 5, step: 1 },
            { type: "toggle", key: "shadows", label: "Shadows" },
            { type: "toggle", key: "hy:dimInactive", label: "Dim unfocused windows" },
            { type: "slider", key: "hy:dimStrength", def: 0.3, label: "Dim amount", min: 0, max: 0.8, step: 0.05, scale: 100, unit: " %" },
            { type: "action", id: "reset-look", label: "Look values", btn: "Back to the config files", done: "Reset", desc: "Forgets every window / look value changed here; hyprland/*.lua rules again." }
        ] },
        { id: "colours", title: "Colours", items: [
            { type: "seg", key: "opt:accentMode", label: "Accent colour", desc: "Fixed: the wallpaper's strongest colour. Cycle: the accent drifts slowly through every colour the wallpaper has, e.g. red, then purple, then back.", opts: [o("fixed", "Fixed"), o("cycle", "Cycle through the wallpaper")] },
            { type: "seg", key: "opt:cycleSecs", label: "Time per colour", desc: "How long the accent takes to go from one wallpaper colour to the next", opts: [o(10, "10 s"), o(20, "20 s"), o(30, "30 s"), o(60, "1 min"), o(120, "2 min"), o(300, "5 min")] },
            { type: "toggle", key: "termFollow", label: "Terminals follow the wallpaper" },
            { type: "seg", key: "opt:termMode", label: "Terminal colours", desc: "Spectrum: red, green, blue, magenta ... each come from a colour the wallpaper really has. Accent: everything is pulled towards the one accent.", opts: [o("spectrum", "Spectrum"), o("accent", "One accent")] },
            { type: "toggle", key: "opt:termDrift", label: "Open terminals cycle too", desc: "Cursor, blue and magenta follow the accent while it cycles (repainted every few seconds)." },
            { type: "action", id: "termcolors", label: "Repaint terminals", btn: "Repaint now", done: "Repainted" }
        ] },
        { id: "workspaces", title: "Workspaces", items: [
            { type: "seg", key: "opt:wsEnd", label: "Next workspace, from the last one", desc: "With workspaces 1 and 2, going next from 2 opens a new workspace 3 (never from an empty one).", opts: [o("new", "Open a new one"), o("wrap", "Go back to 1"), o("stay", "Stay")] },
            { type: "seg", key: "opt:wsStart", label: "Previous workspace, from the first one", desc: "Wrap: from 1 you land on the highest workspace.", opts: [o("wrap", "Jump to the last"), o("stay", "Stay")] },
            { type: "seg", key: "opt:wsMax", label: "Never open more than", opts: [o(3, "3"), o(4, "4"), o(5, "5"), o(6, "6"), o(9, "9"), o(10, "10")] },
            { type: "seg", key: "opt:wsSwipe4", label: "4-finger swipe", desc: "Which way you swipe with four fingers to go to the next workspace.", opts: [o("left", "Left = next"), o("right", "Right = next")] },
            { type: "toggle", key: "opt:wsInvert", label: "Invert workspace scrolling", desc: "Flips the direction when you scroll or 3-finger swipe through workspaces: the mouse wheel / two-finger scroll over the workspace numbers in the bar, and the 3 finger swipes (the 4 finger swipe has its own option above). Off: scroll down / swipe right = next workspace.", },
            { type: "toggle", key: "compactWs", label: "Keep workspaces compact", desc: "On workspace 3 with nothing on 1 and 2? Its windows move to workspace 1." },
            { type: "toggle", key: "hy:focusOnActivate", label: "Jump to a window that asks for attention" },
            { type: "action", id: "layout", label: "Tiling layout", btn: "Switch dwindle / scrolling", done: "Switched" }
        ] },
        { id: "motion", title: "Motion", items: [
            { type: "seg", key: "motion", label: "Island animations", opts: [o(0, "Off"), o(0.5, "Fast"), o(1, "Normal")] },
            { type: "toggle", key: "hyprAnim", label: "Window animations" },
            { type: "toggle", key: "compactSpecial", label: "Compact special workspaces", desc: "On: scratch / music / communication / monitor / tasks windows are smaller. Off: full size." }
        ] },
        { id: "bar", title: "Bar", items: [
            { type: "seg", key: "hoverAction", label: "When you hover the bar", desc: "Stats: CPU, memory and temperature slide out. Performance / Media: that page opens by itself.", opts: [o("none", "Nothing"), o("stats", "Live stats"), o("perf", "Performance"), o("media", "Media")] },
            { type: "seg", key: "barScroll", label: "Scroll / swipe on the bar to change page", opts: [o("low", "Long swipe"), o("medium", "Medium"), o("high", "Sensitive")] },
            { type: "seg", key: "clock24", label: "Clock", opts: [o(false, "12 hour"), o(true, "24 hour")] },
            { type: "toggle", key: "opt:clockSeconds", label: "Show seconds" },
            { type: "toggle", key: "opt:clockDate", label: "Show the day and date" },
            { type: "seg", key: "barPadding", label: "Bar size and padding", desc: "How tall the island is, how far it floats from the top edge, and the space at its sides.", opts: [o("low", "Low"), o("normal", "Normal"), o("high", "High")] },
            { type: "toggle", key: "autoHide", label: "Auto-hide the bar" },
            { type: "toggle", key: "superTap", label: "Tap Super to open the launcher" }
        ] },
        { id: "panels", title: "Panels & notifications", items: [
            { type: "seg", key: "clickMode", label: "Edge boxes (notifications, console, utilities)", opts: [o(false, "Hover"), o(true, "Click")] },
            { type: "toggle", key: "dnd", label: "Do not disturb" },
            { type: "seg", key: "notifHistoryMax", label: "Notifications the centre keeps", opts: [o(10, "10"), o(20, "20"), o(30, "30"), o(50, "50"), o(100, "100")] },
            { type: "seg", key: "notifMax", label: "Popups on screen at once", desc: "When it is full the oldest goes.", opts: [o(1, "1"), o(2, "2"), o(3, "3"), o(5, "5"), o(8, "8")] },
            { type: "seg", key: "opt:notifIcon", label: "Notification picture", desc: "Profile picture: your picture, with the app's icon as a small badge. App icon: only the app's own icon. No profile picture found? The app icon is used.", opts: [o("pfp", "Profile picture"), o("app", "App icon")] },
            { type: "seg", key: "opt:toastSecs", label: "How long a popup stays", desc: "Urgent ones always wait for a click.", opts: [o(0, "App decides"), o(3, "3 s"), o(5, "5 s"), o(8, "8 s"), o(12, "12 s")] },
            { type: "toggle", key: "osdOn", label: "Volume / brightness bar", desc: "Slides up from the bottom whenever volume, brightness or the keyboard light changes." },
            { type: "seg", key: "opt:osdHold", label: "How long that bar stays", opts: [o(1000, "Short"), o(1700, "Normal"), o(3000, "Long")] },
            { type: "toggle", key: "profileStars", label: "Profile picture constellation" },
            { type: "toggle", key: "routeApps", label: "Send Spotify / Discord to their workspace" }
        ] },
        { id: "input", title: "Mouse, touchpad & keyboard", items: [
            { type: "slider", key: "scrollTouch", label: "Touchpad scroll speed", min: 0.1, max: 1.5, step: 0.05, dec: 2, unit: "×", glyph: 0xF037D },
            { type: "slider", key: "scrollMouse", label: "Mouse wheel scroll speed", desc: "In every app. Higher is faster.", min: 0.25, max: 3, step: 0.05, dec: 2, unit: "×", glyph: 0xF037D },
            { type: "toggle", key: "hy:naturalScroll", label: "Natural scrolling (touchpad)" },
            { type: "toggle", key: "hy:tapToClick", label: "Tap to click" },
            { type: "toggle", key: "hy:disableTyping", label: "Pause the touchpad while typing" },
            { type: "toggle", key: "hy:leftHanded", label: "Left-handed buttons" },
            { type: "slider", key: "hy:sensitivity", def: 0, label: "Pointer speed", min: -1, max: 1, step: 0.1, dec: 1, signed: true },
            { type: "seg", key: "hy:accelProfile", label: "Pointer acceleration", desc: "Flat = the pointer moves exactly as far as your hand does.", opts: [o("adaptive", "Adaptive"), o("flat", "Flat")] },
            { type: "seg", key: "hy:followMouse", label: "Focus follows the pointer", opts: [o(0, "Click to focus"), o(1, "Hover"), o(2, "Hover, no raise")] },
            { type: "slider", key: "hy:repeatDelay", def: 600, label: "Key repeat delay", min: 150, max: 800, step: 10, unit: " ms" },
            { type: "slider", key: "hy:repeatRate", def: 25, label: "Key repeat speed", min: 5, max: 70, step: 1, unit: "/s" }
        ] },
        { id: "tools", title: "Tools", items: [
            { type: "tool", key: "nightlight", label: "Night light", desc: "Warmer screen colours (hyprsunset)." },
            { type: "slider", key: "opt:nightTemp", def: 4000, label: "Night light warmth", desc: "Lower is warmer", min: 2500, max: 6500, step: 100, unit: " K" },
            { type: "tool", key: "touchpad", label: "Touchpad" },
            { type: "tool", key: "gestures", label: "Edge gestures", desc: "Volume, brightness and track skipping from the touchpad edges." },
            { type: "tool", key: "wifips", label: "Wi-Fi power saving", desc: "On saves battery. Off gives the lowest latency (Gaming mode switches it off by itself)." },
            { type: "toggle", key: "gaming", label: "Gaming mode", desc: "CPU / GPU at full speed, turbo on, Wi-Fi power saving off, effects off, Caffeine and Do not disturb on, background helpers stopped. SUPER+F10." },
            { type: "action", id: "detect-ram", label: "Memory details", btn: "Detect RAM", done: "Asking…", desc: "Asks for your password once to read the memory type and speed." }
        ] },
        { id: "wallpaper", title: "Wallpaper", items: [
            { type: "seg", key: "opt:wpEvery", label: "Change it by itself", desc: "A new random wallpaper from the folder; the island's colours follow each one.", opts: [o(0, "Never"), o(5, "5 min"), o(15, "15 min"), o(30, "30 min"), o(60, "1 hour")] },
            { type: "custom", name: "wallpaper" }
        ] },
        { id: "sleep", title: "Power, sleep & lock", items: [
            { type: "seg", key: "powerMgr", label: "Power manager", desc: "Which program controls CPU power. Only one runs at a time; the others are stopped. Halcyon Auto drives power-profiles-daemon by itself.", opts: [o("halcyon", "Halcyon Auto"), o("power-profiles-daemon", "power-profiles-daemon"), o("tlp", "TLP"), o("auto-cpufreq", "auto-cpufreq"), o("tuned", "Tuned")] },
            { type: "seg", key: "idleDim", label: "Dim the screen and keyboard light after", opts: [o(0, "Never"), o(1, "1 min"), o(2, "2 min"), o(3, "3 min"), o(5, "5 min"), o(10, "10 min")] },
            { type: "seg", key: "idleLock", label: "Lock the screen after", opts: [o(0, "Never"), o(2, "2 min"), o(5, "5 min"), o(10, "10 min"), o(15, "15 min"), o(30, "30 min")] },
            { type: "seg", key: "idleSleep", label: "Go to sleep after", desc: "Counted from when you last touched the computer. Caffeine stops all three. Needs hypridle.", opts: [o(0, "Never"), o(15, "15 min"), o(30, "30 min"), o(60, "1 h"), o(120, "2 h"), o(240, "4 h")] }
        ] },
        { id: "apps", title: "Default apps", items: [ { type: "custom", name: "apps" } ] },
        { id: "growth", title: "Constellations", items: [
            { type: "toggle", key: "opt:stars", label: "Constellations in the boxes", desc: "The drifting dots and lines behind the Settings, notification centre, cheat sheet, power menu, lock screen and console. Off = none anywhere, whatever the switches below say." },
            { type: "toggle", key: "opt:starsSettings", label: "Settings" },
            { type: "toggle", key: "opt:starsNotifs", label: "Notification centre" },
            { type: "toggle", key: "opt:starsCheatsheet", label: "Cheat sheet (keys)" },
            { type: "toggle", key: "opt:starsPower", label: "Power menu" },
            { type: "toggle", key: "opt:starsLock", label: "Lock screen" },
            { type: "toggle", key: "opt:starsTerm", label: "Console (quick terminal)" },
            { type: "custom", name: "growth" }
        ] },
        { id: "rice", title: "Rice", items: [
            { type: "action", id: "config", label: "Config files", btn: "Edit config", close: true },
            { type: "action", id: "cheatsheet", label: "Shortcuts", btn: "Open the shortcut tree", close: true },
            { type: "action", id: "reload", label: "Hyprland", btn: "Reload", done: "Reloading…", desc: "Re-reads the config files and puts the island's own values back on top." }
        ] }
    ]

    // ---- reading and formatting values
    function get(key) {
        if (!key || typeof key !== "string") return undefined
        if (key.indexOf("opt:") === 0) return opt ? opt[key.substring(4)] : undefined
        if (key.indexOf("hy:") === 0) return hyCur ? hyCur[key.substring(3)] : undefined
        return root[key]
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
    function boolVal(m) {
        if (m.type === "tool") return !!tools[m.key]
        var v = get(m.key)
        return v === undefined ? false : !!v
    }

    // ---- search + collapsing
    property string query: ""
    property var collapsed: ({ apps: true, growth: true })
    function toggleGroup(id) {
        var c = {}
        for (var k in collapsed) c[k] = collapsed[k]
        if (c[id]) delete c[id]; else c[id] = true
        collapsed = c
    }
    function setAll(coll) {
        var c = {}
        if (coll) for (var i = 0; i < groups.length; i++) c[groups[i].id] = true
        collapsed = c
    }
    function itemText(g, it) {
        var t = (g.title + " " + (it.label || "") + " " + (it.desc || "") + " " + (it.name || "") + " " + (it.btn || ""))
        if (it.opts) for (var i = 0; i < it.opts.length; i++) t += " " + it.opts[i].t
        return t.toLowerCase()
    }
    readonly property var groupsNow: {
        var q = query.toLowerCase().trim()
        var out = []
        for (var g = 0; g < groups.length; g++) {
            var grp = groups[g], items = []
            for (var i = 0; i < grp.items.length; i++)
                if (q === "" || itemText(grp, grp.items[i]).indexOf(q) >= 0) items.push(grp.items[i])
            if (items.length > 0) out.push({ id: grp.id, title: grp.title, items: items })
        }
        return out
    }
    readonly property int shownCount: { var n = 0; for (var g = 0; g < groupsNow.length; g++) n += groupsNow[g].items.length; return n }
    readonly property int colCount: (typeof card !== "undefined" && card) ? (card.width >= 1080 ? 2 : 1) : 2
    function weight(grp) {
        var w = 2
        if (query === "" && collapsed[grp.id]) return w
        for (var i = 0; i < grp.items.length; i++) {
            var t = grp.items[i]
            w += t.type === "custom" ? (t.name === "wallpaper" ? 9 : t.name === "apps" ? 8 : 4)
               : (t.type === "seg" || t.type === "slider") ? 2.2 : 1.2
            if (t.desc) w += 0.7
        }
        return w
    }
    readonly property var columns: {
        var n = colCount || 2, cols = [], hs = []
        for (var i = 0; i < n; i++) { cols.push([]); hs.push(0) }
        for (var g = 0; g < groupsNow.length; g++) {
            var best = 0
            for (var j = 1; j < n; j++) if (hs[j] < hs[best]) best = j
            if (cols[best]) {
                cols[best].push(groupsNow[g])
                hs[best] += weight(groupsNow[g])
            }
        }
        return cols
    }

    onOpenChanged: if (open) {
        if (!appsProc.running) appsProc.running = true
        query = ""; focusT.restart()
    }
    Timer { id: focusT; interval: 60; onTriggered: if (typeof search !== "undefined" && search) { search.text = ""; search.forceActiveFocus() } }

    // ======================================================================== custom leaves
    Component {
        id: cSwatches
        ColumnLayout {
            width: parent ? parent.width : 0
            spacing: 10
            Row {
                spacing: 12
                Repeater {
                    model: [ root.pal.accent, root.pal.accent2, root.pal.surfaceHi, root.pal.surface, root.pal.bg ]
                    delegate: Rectangle { required property var modelData; width: 34; height: 18; radius: 9; color: modelData; border.width: 1; border.color: root.pal.line }
                }
            }
            Text { text: "Now in use: accent, second accent, surfaces"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
            Row {
                spacing: 10
                Repeater {
                    model: root.pal.ring
                    delegate: Rectangle {
                        required property var modelData
                        width: 22; height: 22; radius: 11
                        color: Qt.hsla(modelData.h, modelData.s, modelData.l, 1)
                        border.width: 1; border.color: root.pal.line
                    }
                }
            }
            Text {
                text: root.pal.ring.length > 0 ? "The wallpaper's colours" + (root.pal.cycling ? " (the accent is moving through them)" : "") : "Colours of the wallpaper show up here"
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
            }
        }
    }

    Component {
        id: cWallpaper
        ColumnLayout {
            width: parent ? parent.width : 0
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Text { text: String.fromCodePoint(0xF024B); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 16 }
                Text {
                    Layout.fillWidth: true
                    text: root.wp.dir !== "" ? root.wp.dir : "~/Pictures/Wallpapers"
                    elide: Text.ElideMiddle
                    color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tBody
                }
                Text { text: (root.wp.files ? root.wp.files.length : 0) + " images"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
            }
            Flow {
                Layout.fillWidth: true
                spacing: 12
                ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0976); label: "Next wallpaper"; onClicked: root.action("wallpaper") }
                ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0770); label: "Open folder"; onClicked: root.wpAct("open") }
                ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0415); label: "Add wallpapers…"; onClicked: root.wpAct("add") }
                ActionChip { pal: root.pal; label: "Change folder…"; onClicked: root.wpAct("choose-dir") }
                ActionChip { pal: root.pal; label: "Default folder"; doneLabel: "Done"; onClicked: root.wpAct("reset-dir") }
            }
            Flickable {
                Layout.fillWidth: true
                Layout.preferredHeight: 92
                visible: root.wp.files && root.wp.files.length > 0
                contentWidth: thumbRow.width
                contentHeight: height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick
                Row {
                    id: thumbRow
                    spacing: 14
                    Repeater {
                        model: root.wp.files || []
                        delegate: Rectangle {
                            id: th
                            required property var modelData
                            readonly property bool now: root.wp.current === th.modelData.path
                            width: 140; height: 86; radius: 12
                            color: root.pal.surface
                            border.width: th.now ? 2 : 1
                            border.color: th.now ? root.pal.accent : root.pal.line
                            Image {
                                anchors.fill: parent; anchors.margins: 3
                                source: "file://" + th.modelData.path
                                sourceSize.width: 280; sourceSize.height: 170
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                opacity: thMa.containsMouse ? 1 : 0.92
                            }
                            Rectangle {
                                visible: th.now
                                anchors { right: parent.right; top: parent.top; margins: 6 }
                                width: 18; height: 18; radius: 9; color: root.pal.accent
                                Text { anchors.centerIn: parent; text: "✓"; color: root.pal.bg; font.pixelSize: 11; font.weight: Font.Bold }
                            }
                            MouseArea { id: thMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickWallpaper(th.modelData.path) }
                        }
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.wp.files && root.wp.files.length > 0 ? "Click one to use it. Drop more images into the folder (or Add wallpapers) and they show up here." : "No images in that folder yet. Use Add wallpapers, or open the folder and drop .jpg / .png / .webp files in."
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
            }
        }
    }

    Component {
        id: cApps
        ColumnLayout {
            width: parent ? parent.width : 0
            spacing: 14
            Repeater {
                model: [ { kind: "terminal", title: "Terminal" }, { kind: "browser", title: "Browser" }, { kind: "files", title: "File manager" },
                         { kind: "editor", title: "Code editor  (also used by Edit config)" }, { kind: "music", title: "Music player  (opens on the music workspace)" },
                         { kind: "chat", title: "Chat  (opens on the communication workspace)" } ]
                delegate: ColumnLayout {
                    id: appRow
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 10
                    Text { text: appRow.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 12
                        Repeater {
                            model: root.apps[appRow.modelData.kind] || []
                            delegate: SChip {
                                required property var modelData
                                pal: root.pal
                                label: modelData.name
                                on: root.apps.current && root.apps.current[appRow.modelData.kind] === modelData.id
                                onClicked: root.setApp(appRow.modelData.kind, modelData.id)
                            }
                        }
                        Text {
                            visible: (root.apps[appRow.modelData.kind] || []).length === 0
                            text: "none installed"
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        }
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                text: "Only installed apps are listed. A browser or file manager you pick also becomes the system default for links and folders. Something missing? Add a line to ~/.config/Halcyon/apps.custom (see the top of scripts/apps.sh)."
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
            }
        }
    }

    Component {
        id: cGrowth
        ColumnLayout {
            width: parent ? parent.width : 0
            spacing: 12
            Text {
                Layout.fillWidth: true
                text: "They grow the longer the island runs: the dragon unfolds two wings, the shield gains a second rim, a crest and a crown, and the profile picture gets more and more stars until it looks like the picture. Fully grown after 72 hours of use."
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
            }
            Slider {
                Layout.fillWidth: true; pal: root.pal
                glyph: String.fromCodePoint(0xF04CE)
                value: root.growth
                readout: Math.round(root.growth * 100) + " %"
                onMoved: v => root.setting("growthMin", Math.round(v * root.growthFullMin))
            }
            Text {
                Layout.fillWidth: true
                text: "Grown for " + (root.growthMin >= 60 ? Math.floor(root.growthMin / 60) + " h " + Math.round(root.growthMin % 60) + " min" : Math.round(root.growthMin) + " min") + ".  Drag the bar to preview any stage."
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
            }
            Flow {
                Layout.fillWidth: true
                spacing: 12
                SChip { pal: root.pal; label: root.growthOn ? "Growing: on" : "Growing: off"; on: root.growthOn; onClicked: root.setting("growthOn", !root.growthOn) }
                ActionChip { pal: root.pal; label: "Start over"; doneLabel: "Reset"; onClicked: root.setting("growthReset", true) }
                ActionChip { pal: root.pal; label: "Fully grown"; doneLabel: "Grown"; onClicked: root.setting("growthMin", root.growthFullMin) }
            }
        }
    }

    // ======================================================================== the window
    LazyLoader {
        active: root.open
        PanelWindow {
            id: win
            visible: true
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "island-settings"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        Item {
            id: fade
            anchors.fill: parent
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            focus: root.open
            Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true } }

            Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.40) }
            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Glass {
                id: card
                pal: root.pal
                anchors.centerIn: parent
                width: Math.min(parent.width - 100, 1320)
                height: parent.height - 80
                radius: root.pal.rXl
                opacityBody: root.opt.settingsGlass !== undefined ? root.opt.settingsGlass : 0.72
                border.color: Qt.alpha(root.pal.accent, 0.35)
                scale: root.open ? 1 : 0.96
                Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                MouseArea { anchors.fill: parent }   // swallow clicks

                Backdrop { visible: root.open && root.opt.stars !== false && root.opt.starsSettings !== false; anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; avatarStars: root.starData; profileStars: root.profileStars; dots: 14; artStrength: 0.6; artFit: 0.85 }

                // ---------------- header: title, search, collapse, close
                RowLayout {
                    id: head
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 36 }
                    spacing: 16
                    Text { text: String.fromCodePoint(0xF0493); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                    Text { text: "Settings"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 380
                        implicitHeight: 34
                        radius: 17
                        color: Qt.alpha(root.pal.bg, 0.55)
                        border.width: 1
                        border.color: search.activeFocus ? root.pal.lineFocus : root.pal.line
                        Text {
                            anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            text: String.fromCodePoint(0xF0349) + "  search settings"
                            color: root.pal.muted; font.family: root.pal.font; font.pixelSize: root.pal.tBody
                        }
                        TextInput {
                            id: search
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.pal.text
                            selectionColor: Qt.alpha(root.pal.accent, 0.4)
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                            clip: true
                            onTextChanged: root.query = text
                            Keys.onEscapePressed: { if (text !== "") text = ""; else root.hide() }
                        }
                    }
                    Text { text: root.shownCount + " settings"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                    Item { Layout.fillWidth: true }
                    SChip { pal: root.pal; label: "Collapse all"; onClicked: root.setAll(true) }
                    SChip { pal: root.pal; label: "Expand all"; onClicked: root.setAll(false) }
                    RoundBtn { pal: root.pal; glyph: "✕"; size: 32; onClicked: root.hide() }
                }

                // ---------------- the tree
                Flickable {
                    id: scroll
                    anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 36; topMargin: 26 }
                    contentWidth: width
                    contentHeight: tree.height + 12
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

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
                        NumberAnimation on tt { from: 0; to: 1; duration: 3600; loops: Animation.Infinite; running: root.open && root.pal.motion > 0.3 }

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
                                Text { text: root.groups.length + " branches  ·  everything applies at once"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; anchors.verticalCenter: parent.verticalCenter }
                            }
                        }
                        Rectangle { x: tree.width / 2; y: rootNode.height; width: 1; height: tree.barY - rootNode.height; color: Qt.alpha(root.pal.accent, 0.45) }
                        Rectangle {
                            readonly property real firstX: 10
                            readonly property real lastX: (root.colCount - 1) * (tree.colW + tree.gap) + 10
                            x: Math.min(firstX, tree.width / 2)
                            y: tree.barY
                            width: Math.max(1, Math.max(lastX, tree.width / 2) - x)
                            height: 1
                            color: Qt.alpha(root.pal.accent, 0.45)
                        }
                        Repeater {
                            model: root.colCount
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
                            model: root.columns
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
                                                x: 28; anchors.verticalCenter: parent.verticalCenter
                                                text: grp.modelData.title.toUpperCase()
                                                color: root.pal.accent
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 12
                                                font.weight: Font.DemiBold
                                                font.letterSpacing: 1.6
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
                                            clip: true
                                            opacity: grp.shut ? 0 : 1
                                            Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                                            Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }

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
                                                        readonly property bool inline: m.type === "toggle" || m.type === "tool" || m.type === "action"
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
                                                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                                        }
                                                        MouseArea { id: leafMa; anchors.fill: content; hoverEnabled: true; acceptedButtons: Qt.NoButton }

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
                                                                ColumnLayout {
                                                                    Layout.fillWidth: true
                                                                    spacing: 5
                                                                    Text {
                                                                        Layout.fillWidth: true
                                                                        text: leaf.m.label || ""
                                                                        color: root.pal.text
                                                                        font.family: root.pal.uiFont
                                                                        font.pixelSize: root.pal.tBody
                                                                        font.weight: Font.Medium
                                                                        wrapMode: Text.WordWrap
                                                                    }
                                                                    Text {
                                                                        Layout.fillWidth: true
                                                                        visible: text !== ""
                                                                        text: (leaf.m.key === "nightlight" && !root.tools.nightlightOk) ? "hyprsunset is not installed (pacman -S hyprsunset)"
                                                                            : (leaf.m.id === "layout" ? "Now: " + (root.hyCur.layout || "dwindle") : (leaf.m.desc || ""))
                                                                        color: root.pal.muted
                                                                        font.family: root.pal.uiFont
                                                                        font.pixelSize: 11
                                                                        lineHeight: 1.3
                                                                        wrapMode: Text.WordWrap
                                                                    }
                                                                }
                                                                Toggle {
                                                                    visible: leaf.m.type === "toggle" || leaf.m.type === "tool"
                                                                    Layout.alignment: Qt.AlignTop
                                                                    pal: root.pal
                                                                    on: root.boolVal(leaf.m)
                                                                    busy: leaf.m.type === "tool" && root.toolPending === leaf.m.key
                                                                    onToggled: leaf.m.type === "tool" ? root.toolFlip(leaf.m.key) : root.setting(leaf.m.key, !root.boolVal(leaf.m))
                                                                }
                                                                ActionChip {
                                                                    visible: leaf.m.type === "action"
                                                                    Layout.alignment: Qt.AlignTop
                                                                    pal: root.pal
                                                                    label: leaf.m.btn || ""
                                                                    doneLabel: leaf.m.done || ""
                                                                    onClicked: { root.action(leaf.m.id); if (leaf.m.close) root.hide() }
                                                                }
                                                            }

                                                            // pick one
                                                            Flow {
                                                                Layout.fillWidth: true
                                                                visible: leaf.m.type === "seg"
                                                                spacing: 10
                                                                Repeater {
                                                                    model: leaf.m.type === "seg" ? leaf.m.opts : []
                                                                    delegate: SChip {
                                                                        required property var modelData
                                                                        pal: root.pal
                                                                        label: modelData.t
                                                                        on: root.same(root.get(leaf.m.key), modelData.v)
                                                                        onClicked: root.setting(leaf.m.key, modelData.v)
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
                                                                    root.setting(leaf.m.key, Math.round(q * 1000) / 1000)
                                                                }
                                                            }

                                                            // wallpaper picker, default apps, constellations, colour swatches
                                                            Loader {
                                                                Layout.fillWidth: true
                                                                visible: leaf.m.type === "custom"
                                                                active: leaf.m.type === "custom" && !grp.shut
                                                                sourceComponent: leaf.m.name === "wallpaper" ? cWallpaper
                                                                               : leaf.m.name === "apps" ? cApps
                                                                               : leaf.m.name === "growth" ? cGrowth : cSwatches
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
    }
}
}
