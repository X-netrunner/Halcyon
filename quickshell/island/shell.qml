import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import "StarData.js" as Stars
import "Routes.js" as Routes
import "Binds.js" as Binds

ShellRoot {
    id: root

    // ---------- tunables ----------
    // Auto power mode = the power-manager daemon (custom/power-manager, user service power-manager.service).
    // Its thresholds (load, battery, heat, idle) live in custom/power-manager/src/main.rs.
    readonly property string powerService: "power-manager.service"
    // Settings > Bar > Padding: low | normal | high  ->  bar height, side padding, and the space ABOVE the bar (to the screen edge)
    // = the space BELOW it (to the windows): the same number, so the bar sits evenly. "low" is almost touching both.
    readonly property var padSet: ({ low: { h: 32, top: 3, gap: 3, x: 28 }, normal: { h: 44, top: 12, gap: 12, x: 56 }, high: { h: 54, top: 20, gap: 20, x: 76 } })[barPadding] || ({ h: 44, top: 12, gap: 12, x: 56 })
    property int notifMax: 5                 // popups on screen at once (Settings > Notifications); a new one past this hides the oldest popup (it stays in the centre)
    // notifications kept in the notification centre (Settings > Notifications, remembered); a new one past this replaces the oldest
    property int notifHistoryMax: 30
    // idle: lock the screen after N minutes, sleep after N minutes (0 = never). Settings > Sleep & lock, applied by scripts/idle.sh
    property int idleLock: 5
    property int idleSleep: 30
    property int idleDim: 3                // minutes until the screen dims to its minimum and the keyboard light goes off (0 = never)
    property bool idleTouched: false
    property bool osdOn: true              // the volume / brightness bar that slides in on every change
    // 12 / 24 hour clock in the bar (Settings > Bar)
    property bool clock24: false
    // ---- the rest of the Settings tree. Settings.qml reads / writes these by key ("opt:<key>" and "hy:<key>"), they are saved in
    // settings.json (under "opt" / "hy") and applied below (setOpt / applyHypr)
    property var opt: ({
        accentMode: "fixed",       // fixed | cycle : the accent is the wallpaper's main colour, or drifts through all of its colours
        cycleSecs: 30,             // seconds from one wallpaper colour to the next
        termMode: "spectrum",      // spectrum | accent : terminal colours from every wallpaper colour, or from the one accent
        termDrift: false,          // open terminals follow the accent cycle
        wsEnd: "new",              // new | wrap | stay : "next workspace" on the last one (scripts/ws-nav.sh)
        wsStart: "wrap",           // wrap | stay : "previous workspace" on the first one
        wsMax: 9,                  // "next workspace" never opens a workspace above this number
        wpEvery: 0,                // minutes between automatic wallpaper changes (0 = off)
        clockSeconds: false,       // show seconds in the bar clock
        clockDate: true,           // show the weekday and date next to the clock
        osdHold: 1700,             // ms the volume / brightness bar stays
        toastSecs: 0,              // seconds a notification popup stays (0 = what the app asks for)
        notifIcon: "pfp",          // pfp | app : the picture of a notification is your profile picture (app icon as a badge), or the app's icon
        wsSwipe4: "left",          // left | right : which 4-finger swipe goes to the NEXT workspace (scripts/ws-nav.sh)
        wsInvert: false,           // invert the direction of workspace scrolling: bar wheel over the numbers + 3 / 4 finger swipes (scripts/ws-nav.sh)
        nightTemp: 4000,           // night light colour temperature (K)
        settingsGlass: 0.72,       // how opaque the Settings window is (lower = more see-through)
        resMode: "high",           // low | medium | high : the preset picked in Settings > Performance > Resource use (applyResMode below)
        perf: "high",              // low | medium | high : how much the tree view and constellations animate (and how many stars the picture gets)
        fps: 0,                    // frame rate of the tree view and constellations: 0 = every frame of the screen, or 60 / 30 / 20 / 15
        pageClose: 600,            // ms the performance / media page waits after the pointer leaves the bar before it folds back (150 / 600 / 4000)
        lines: "gpu",              // gpu | cpu : who draws the constellation lines and the tree branches (gpu = plain quads + a small shader, no path tessellation)
        bgWhere: "bar",            // corner | bar : where the number of background apps is shown (the box itself always opens bottom-left)
        stars: true,               // constellations in the boxes: off = none anywhere; the ones below switch single boxes
        starsSettings: true, starsNotifs: true, starsCheatsheet: true, starsPower: true, starsLock: true, starsTerm: true
    })
    // Hyprland values you changed in Settings: only these are pushed (the Lua config rules for everything else).
    // hyCur = what Hyprland has right now (read at start by scripts/hypr-values.sh, then your changes) = where the sliders start.
    property var hy: ({})
    property var hyCur: ({})
    readonly property var hyMap: ({
        borderSize: ["general", "border_size"], resizeOnBorder: ["general", "resize_on_border"],
        activeOpacity: ["decoration", "active_opacity"], inactiveOpacity: ["decoration", "inactive_opacity"],
        dimInactive: ["decoration", "dim_inactive"], dimStrength: ["decoration", "dim_strength"],
        blurSize: ["decoration", "blur", "size"], blurPasses: ["decoration", "blur", "passes"],
        followMouse: ["input", "follow_mouse"], repeatDelay: ["input", "repeat_delay"], repeatRate: ["input", "repeat_rate"],
        sensitivity: ["input", "sensitivity"], accelProfile: ["input", "accel_profile"], leftHanded: ["input", "left_handed"],
        naturalScroll: ["input", "touchpad", "natural_scroll"], tapToClick: ["input", "touchpad", "tap_to_click"],
        disableTyping: ["input", "touchpad", "disable_while_typing"], focusOnActivate: ["misc", "focus_on_activate"]
    })
    function setOpt(k, v) {
        var o = {}
        for (var x in opt) o[x] = opt[x]
        o[k] = v
        opt = o
        switch (k) {
        case "wsEnd": writeFlag("ws-end", v); break
        case "wsStart": writeFlag("ws-start", v); break
        case "wsMax": writeFlag("ws-max", v); break
        case "wsInvert": writeFlag("ws-invert", v ? "1" : "0"); break
        case "wsSwipe4": writeFlag("ws-swipe4", v); break
        case "termMode": writeFlag("term-mode", v); termRun.restart(); break
        case "termDrift": termRun.restart(); break
        case "accentMode": termRun.restart(); break
        case "nightTemp": nightT.restart(); break
        case "resMode": applyResMode(v); break
        }
        saveSettings()
    }

    // Settings > Performance > Resource use: three presets that set many options at once. The options stay changeable afterwards.
    // (Startup items and the GPU are NOT part of it: they only change at the next login, see Settings > Startup & background.)
    readonly property var resPresets: ({
        low:    { opt: { perf: "low",    fps: 30, lines: "gpu", stars: false, accentMode: "fixed", termDrift: false, clockSeconds: false },
                  blur: false, shadows: false, hyprAnim: false, motion: 0.5, profileStars: false, notifHistoryMax: 10, notifMax: 3,
                  hy: { blurSize: 4, blurPasses: 1 } },
        medium: { opt: { perf: "medium", fps: 60, lines: "gpu", stars: true },
                  blur: true,  shadows: false, hyprAnim: true,  motion: 1,   profileStars: true,  notifHistoryMax: 20, notifMax: 5,
                  hy: { blurSize: 6, blurPasses: 2 } },
        high:   { opt: { perf: "high",   fps: 0,  lines: "gpu", stars: true },
                  blur: true,  shadows: true,  hyprAnim: true,  motion: 1,   profileStars: true,  notifHistoryMax: 30, notifMax: 5,
                  hy: { blurSize: 7, blurPasses: 3 } }
    })
    function applyResMode(m) {
        var p = resPresets[m]
        if (!p) return
        var o = {}
        for (var x in opt) o[x] = opt[x]
        for (var y in p.opt) o[y] = p.opt[y]
        o.resMode = m
        opt = o
        blur = p.blur; shadows = p.shadows; hyprAnim = p.hyprAnim; motion = p.motion
        profileStars = p.profileStars; notifHistoryMax = p.notifHistoryMax; notifMax = p.notifMax
        hyprTouched = true
        var h = {}, c = {}
        for (var a in hy) h[a] = hy[a]
        for (var b in hyCur) c[b] = hyCur[b]
        for (var k in p.hy) { h[k] = p.hy[k]; c[k] = p.hy[k] }
        hy = h; hyCur = c
        hyprKick.restart()
    }
    function setHy(k, v) {
        var h = {}, c = {}
        for (var x in hy) h[x] = hy[x]
        for (var y in hyCur) c[y] = hyCur[y]
        h[k] = v; c[k] = v
        hy = h; hyCur = c
        saveSettings()
        hyprKick.restart()
    }
    // the flag files scripts read (ws-nav.sh, term-colors.sh): written again at start so they always match the settings
    function syncOptFlags() {
        writeFlag("ws-end", opt.wsEnd); writeFlag("ws-start", opt.wsStart); writeFlag("ws-max", opt.wsMax); writeFlag("ws-invert", opt.wsInvert ? "1" : "0"); writeFlag("ws-swipe4", opt.wsSwipe4 || "left")
        writeFlag("term-mode", opt.termMode)
    }
    // Settings > Look > "Back to the Lua config": forget every Hyprland value changed here and let the config files rule again
    function resetLook() {
        hy = {}
        hyprTouched = false; scrollTouched = false
        rounding = 18; gaps = 8; blur = true; shadows = true; hyprAnim = true; scrollTouch = 0.3; scrollMouse = 1.0
        saveSettings()
        reloadProc.running = true
        hyReadAgain.restart()
    }
    Timer { id: termRun; interval: 500; onTriggered: pal.runTermColors() }
    Timer { id: nightT; interval: 600; onTriggered: Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_nightlight.sh", "temp", String(root.opt.nightTemp)]) }
    Timer { id: hyReadAgain; interval: 1800; onTriggered: hyRead.running = true }
    Process {
        id: hyRead
        running: true
        command: ["bash", root.cfg + "/island/scripts/hypr-values.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var v = JSON.parse(text), o = {}
                    for (var k in v) o[k] = v[k]
                    for (var h in root.hy) o[h] = root.hy[h]
                    root.hyCur = o
                } catch (e) {}
            }
        }
    }
    // wallpaper slideshow (Settings > Wallpaper): a new random wallpaper every N minutes; the island's colours follow it
    Timer {
        interval: Math.max(1, root.opt.wpEvery) * 60000
        running: root.settingsLoaded && root.opt.wpEvery > 0 && !root.gaming
        repeat: true
        onTriggered: root.randomWallpaper()
    }
    // constellations grow with the total minutes the island has run (Settings > Constellations)
    property bool growthOn: true
    property double growthMin: 0
    property bool superTap: true        // tapping Super alone opens the launcher (hyprland/keybinds.lua reads the flag file)
    property bool termFollow: true      // terminals take the wallpaper's colours automatically
    property real colorBoost: 1.0       // 0.5 calm .. 1.5 vivid: how strongly the wallpaper's colour shows in the accent
    readonly property real growthFullMin: 4320          // 72 hours of use = fully grown
    readonly property real growth: Math.min(1, growthMin / growthFullMin)
    Timer {
        interval: 60000; running: root.growthOn && root.growth < 1; repeat: true
        onTriggered: { root.growthMin += 1; if (Math.round(root.growthMin) % 5 === 0) root.saveSettings() }
    }

    readonly property string hx: Quickshell.env("HOME") + "/.config/Halcyon/bin/hx"
    readonly property string cfg: Quickshell.env("HOME") + "/.config/Halcyon/quickshell"
    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/island"

    // ---------- state ----------
    // media | home | perf | launcher
    property string page: "home"

    property var stats: ({ cpu: 0, mem: 0, memGb: "0.0", temp: 0, down: 0, up: 0, bat: 0, charging: false, ac: false, hasBat: false,
                               sysmode: "", auto: false, pmode: "", pprofile: "" })
    property var net: ({ wifi: "off", ssid: "", eth: false, bt: "off", btdev: "" })
    property string profile: "balanced"
    property var cava: []
    property string activeSpecial: ""
    property real vol: 0
    property bool muted: false
    property real bright: 0
    property real mic: 0
    property bool micMuted: false
    property bool gaming: false
    property bool caffeine: false       // keep the screen awake (scripts/caffeine.sh); the unit is the truth, polled every 5 s
    property double caffeineGuard: 0

    // app routing: Spotify / Discord ... go to their special workspace when they open (Routes.js)
    property bool routeApps: true
    property var routed: ({})           // window addresses already handled, so a window you move yourself is left alone
    property bool routeSeeded: false    // the first pass only notes what is already open
    readonly property double startedAt: Date.now()

    // persisted in ~/.local/state/island/settings.json
    property bool autoHide: false
    property bool autoPower: false
    property bool dnd: false            // do not disturb: no popups, everything is still stored
    property string edgeMode: "hover"   // hover | click: how the edge boxes (notifications, console, utilities) open and close
    readonly property bool clickMode: edgeMode === "click"
    readonly property string sysmode: stats.sysmode || ""
    // Settings window (all remembered): look + motion + behaviour
    property real glassShift: 0
    property real motion: 1
    property int rounding: 18
    property int gaps: 8
    property bool blur: true
    property bool shadows: true
    property bool hyprAnim: true
    property bool profileStars: true
    property bool hyprTouched: false    // only push Hyprland values once the user changed one (otherwise the Lua config rules)
    // theme (Settings > Look): dark | light. Everything reads pal, which flips with it
    property string theme: "dark"
    property bool themeTouched: false
    // scroll sensitivity (Hyprland scroll_factor), pushed once changed; barScroll = how far you scroll on the bar to change page
    property real scrollTouch: 0.3
    property real scrollMouse: 1.0
    property bool scrollTouched: false
    property string barScroll: "medium"
    property string barPadding: "normal"  // low | normal | high
    property string powerMgr: "halcyon"   // halcyon | power-profiles-daemon | tlp | auto-cpufreq | tuned
    readonly property real barScrollStep: ({ "low": 240, "medium": 90, "high": 25 })[barScroll] || 90
    // what hovering the bar does: none | stats (CPU / RAM / temp slide out in the bar) | perf | media (that page opens)
    property string hoverAction: "none"
    property bool hoverOpened: false    // the current page was opened by hovering, so it also closes soon after the pointer leaves
    // workspaces: windows on workspace N move to 1 when nothing is before them
    property bool compactWs: true
    // shortcuts you changed / added in the cheatsheet (binds.json for us, binds.lua for Hyprland)
    property var keyMap: ({})
    property var customBinds: []
    property var gpu: ({ gpu: 0, state: "none" })   // gpu.sh, only polled while the performance page is open
    property var specs: ({})                         // hx specs, once at start
    property var disks: ({ disks: [] })              // disk.py, only polled while the performance page is open
    property double autoGuard: 0        // ignore the daemon's state file until this time (ms) after a click
    property bool compactSpecial: true
    property string profileName: ""
    property string profileAvatar: ""
    property bool settingsLoaded: false
    // the profile picture as a constellation (secure / cyber backdrops everywhere); redone when the picture changes
    property var starData: null
    // Settings > Performance: 0 low, 1 medium, 2 high. Also sets how detailed the picture constellation is (grid of the picture)
    readonly property int perfLevel: opt.perf === "low" ? 0 : (opt.perf === "medium" ? 1 : 2)
    readonly property int starGrid: perfLevel === 0 ? 96 : (perfLevel === 1 ? 128 : 160)
    onStarGridChanged: if (settingsLoaded && profileStars && avatarPath !== "") makeStars()
    property string avatarPath: ""      // the picture actually found (scripts/avatar.sh); "" = none
    readonly property string starName: profileName !== "" ? profileName : Quickshell.env("USER")
    function refreshAvatar() { avatarProc.running = true }
    // picture -> `hx stars`; no picture, or a flat one that gives (almost) no stars -> a sky made from your name,
    // so the constellation is never just blank
    function makeStars() {
        if (!profileStars) return
        if (avatarPath === "") starData = Stars.fromName(starName)
        else starProc.running = true
    }
    onProfileAvatarChanged: if (settingsLoaded) refreshAvatar()
    onProfileNameChanged: if (settingsLoaded && avatarPath === "" && profileStars) starData = Stars.fromName(starName)
    onProfileStarsChanged: if (settingsLoaded && profileStars && starData === null) makeStars()
    onSettingsLoadedChanged: if (settingsLoaded) refreshAvatar()

    // SUPER+TAB tree overview
    property bool overviewOpen: false

    // why Auto is where it is (from the daemon's current mode); "" for the plain AC-balanced case
    readonly property string autoNote: ({ "battery": "on battery", "ac-performance": "heavy load", "idle": "idle",
                                          "gaming": "gaming", "thermal": "thermal hold", "starting": "starting" })[stats.pmode] || ""

    readonly property string profileLabel: ({ "power-saver": "Battery saver", "balanced": "Balanced", "performance": "Performance" })[profile] || profile

    property var player: {
        var l = Mpris.players.values
        var first = null
        for (var i = 0; i < l.length; i++) {
            if (l[i].isPlaying) return l[i]
            if (!first) first = l[i]
        }
        return first
    }
    readonly property bool playing: player !== null && player !== undefined && player.isPlaying

    Pal {
        id: pal
        light: root.theme === "light"
        glassShift: root.glassShift
        motion: root.gaming ? 0.25 : root.motion
        growth: root.growth
        growthOn: root.growthOn
        // Gaming mode: tree view and constellations drop to the lightest settings whatever Settings > Performance says
        artQuality: root.gaming ? 0 : root.perfLevel
        artFps: root.gaming ? 15 : (root.opt.fps || 0)
        gpuLines: root.opt.lines !== "cpu"
        branchShader: root.branchShaderUrl
        accentMode: root.opt.accentMode
        cycleSecs: root.opt.cycleSecs
        termDrift: root.opt.termDrift
        cyclePaused: root.gaming
    }
    readonly property var palObj: pal

    // rice settings window (gear in the utilities panel, >settings, SUPER+F11) and the power menu (power button)
    Settings {
        id: settingsWin
        pal: pal
        sysmode: root.sysmode
        autoHide: root.autoHide
        clickMode: root.clickMode
        dnd: root.dnd
        gaming: root.gaming
        profileStars: root.profileStars
        starData: root.starData
        glassShift: root.glassShift
        motion: root.motion
        rounding: root.rounding
        gaps: root.gaps
        blur: root.blur
        shadows: root.shadows
        hyprAnim: root.hyprAnim
        notifHistoryMax: root.notifHistoryMax
        notifMax: root.notifMax
        compactSpecial: root.compactSpecial
        routeApps: root.routeApps
        clock24: root.clock24
        growthOn: root.growthOn
        growthMin: root.growthMin
        growthFullMin: root.growthFullMin
        superTap: root.superTap
        termFollow: root.termFollow
        colorBoost: root.colorBoost
        idleLock: root.idleLock
        idleSleep: root.idleSleep
        idleDim: root.idleDim
        osdOn: root.osdOn
        theme: root.theme
        compactWs: root.compactWs
        hoverAction: root.hoverAction
        barScroll: root.barScroll
        barPadding: root.barPadding
        powerMgr: root.powerMgr
        scrollTouch: root.scrollTouch
        scrollMouse: root.scrollMouse
        opt: root.opt
        hyCur: root.hyCur
        onSetting: (k, v) => root.setSetting(k, v)
        onWallpaperSet: path => root.setWallpaper(path)
        onAction: id => {
            if (id === "wallpaper") root.randomWallpaper()
            else if (id === "config") root.editConfig()
            else if (id === "cheatsheet") root.runCommand("cheatsheet")
            else if (id === "reload") fullReloadProc.running = true
            else if (id === "nightlight") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_nightlight.sh"])
            else if (id === "touchpad") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_touchpad.sh"])
            else if (id === "gestures") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_gestures.sh"])
            else if (id === "wifi-powersave") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_wifi_powersave.sh"])
            else if (id === "termcolors") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/term-colors.sh", "--now"])
            else if (id === "layout") { Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_layout.sh"]); hyReadAgain.restart() }
            else if (id === "reset-look") root.resetLook()
            else if (id === "mem-report") { var h = Quickshell.env("HOME") + "/.config/Halcyon/scripts"; Quickshell.execDetached(["bash", h + "/apps.sh", "term-exec", "bash", "-c", "bash \"$1\"; echo; read -n1 -r -p 'Press any key to close '", "x", h + "/halcyon-mem.sh"]) }
            else if (id === "detect-ram") { Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/refresh-ram.sh", "--gui"]); specsAgain.restart() }
        }
    }
    // the shortcut tree: every bind, gesture and command; click one to change it, add your own at the bottom
    Cheatsheet {
        id: cheat
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        keyMap: root.keyMap
        customs: root.customBinds
        onRebind: (id, keys) => root.setBind(id, keys)
        onCustomSaved: (i, label, keys, cmd) => root.saveCustomBind(i, label, keys, cmd)
        onCustomRemoved: i => root.removeCustomBind(i)
    }
    // `hyprctl reload`, then put the island's own Hyprland tweaks back on top (a reload resets them)
    Process { id: reloadProc; command: ["hyprctl", "reload"]; onExited: hyprKick.restart() }
    // Settings > Reload Hyprland: Hyprland's config + terminal colours (scripts/reload.sh), then the island itself reloads
    // (that also puts the island's own Hyprland tweaks back on top, they are re-applied at island start)
    Process {
        id: fullReloadProc
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/reload.sh"]
        onExited: Quickshell.reload(false)
    }
    // ---- volume / brightness / keyboard-light bar: slides up from the bottom edge on every change (Osd.qml)
    Osd { id: osd; pal: pal; enabled: root.osdOn; holdMs: root.opt.osdHold }
    // brightness + keyboard light: scripts/osd-watch.sh prints a line when either changes (silent while the idle dim is active)
    Process {
        running: root.osdOn
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/osd-watch.sh"]
        stdout: SplitParser {
            onRead: d => {
                try {
                    var m = JSON.parse(d)
                    if (corner.open) return          // the panel's own sliders are on screen already
                    osd.show(m.k, m.p / 100, false)
                } catch (e) {}
            }
        }
    }
    // volume: PipeWire/Pulse tells us about every sink change, then we read the new level
    property bool volPrimed: false
    property real lastVol: -1
    property bool lastMuted: false
    Process {
        running: root.osdOn
        command: ["pactl", "subscribe"]
        stdout: SplitParser { onRead: d => { if (d.indexOf("sink") >= 0 && d.indexOf("source") < 0 && d.indexOf("sink-input") < 0 && (d.indexOf("change") >= 0 || d.indexOf("new") >= 0 || d.indexOf("server") >= 0)) volReadT.restart() } }
    }
    Timer { id: volReadT; interval: 60; onTriggered: if (!volRead.running) volRead.running = true }
    Process {
        id: volRead
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = /Volume:\s*([0-9.]+)/.exec(text)
                if (!m) return
                var v = parseFloat(m[1]), mu = text.indexOf("MUTED") >= 0
                var changed = Math.abs(v - root.lastVol) > 0.004 || mu !== root.lastMuted
                if (root.volPrimed && changed && !corner.open) osd.show("vol", v, mu)
                root.lastVol = v; root.lastMuted = mu; root.volPrimed = true
            }
        }
    }
    Component.onCompleted: { volRead.running = true; startTapWatch() }

    // our own lock screen (replaces hyprlock): SUPER+L, power menu > Lock, `>lock`, scripts/lock.sh
    Lock {
        id: lockScreen
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsLock !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        name: root.profileName !== "" ? root.profileName : Quickshell.env("USER")
        avatarPath: root.avatarPath
    }
    // Login-screen mode (install.sh > "lock screen as login"): launch/halcyon-login.sh leaves a flag file before it starts
    // Hyprland, and the first thing the island does is take it and lock. So after boot the Halcyon lock screen IS the login
    // screen (your password is checked by PAM exactly like a normal login). No flag file = nothing happens.
    Process {
        running: true
        command: ["sh", "-c", "f=\"$HOME/.cache/island/lock-on-start\"; if [ -f \"$f\" ]; then rm -f \"$f\"; echo yes; fi"]
        stdout: StdioCollector { onStreamFinished: { if (text.trim() === "yes") lockScreen.lock() } }
    }
    PowerMenu {
        id: powerMenu
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsPower !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        onSession: a => root.session(a)
    }

    // notification daemon + top-right bell, popups and centre (replaces dunst)
    Notifs {
        id: notifs
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsNotifs !== false
        maxToasts: root.notifMax
        maxHistory: root.notifHistoryMax
        toastSecs: root.opt.toastSecs
        avatar: root.avatarPath
        usePfp: root.opt.notifIcon !== "app"
        dnd: root.dnd
        clickMode: root.clickMode
        autoHide: root.autoHide
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        onDndRequested: v => root.setDnd(v)
    }

    // top-left pop-out terminal (one-shot commands, sysmode switches; shows honeypot status while idle)
    QuickTerm {
        id: quickTerm
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsTerm !== false
        sysmode: root.sysmode
        clickMode: root.clickMode
        autoHide: root.autoHide
        starData: root.starData
        profileStars: root.profileStars
    }

    // ---------- actions ----------
    function go(dir) {
        if (page === "launcher") return
        hoverOpened = false
        island.hoverSpent = true      // you chose a page yourself: do not re-open one by hover until the pointer has left
        if (dir < 0) page = (page === "perf") ? "home" : "media"
        else page = (page === "media") ? "home" : "perf"
    }
    // Super tap can arrive twice (fast file trigger + IPC fallback, or both Super_L bind forms): only the first counts
    property double lastSuperTap: 0
    function superTapFired() {
        if (!superTap) return
        var n = Date.now()
        if (n - lastSuperTap < 350) return
        lastSuperTap = n
        toggleLauncher()
    }
    // fast path: keybinds write this file (a few ms) instead of waiting for a whole `quickshell ipc` process to start
    readonly property string superTapFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/halcyon-super-tap"
    function startTapWatch() { Quickshell.execDetached(["sh", "-c", "echo 0 > \"$1\"", "sh", superTapFile]); tapWatchT.start() }
    Timer { id: tapWatchT; interval: 600; onTriggered: tapWatch.path = root.superTapFile }
    FileView { id: tapWatch; path: ""; watchChanges: true; onFileChanged: root.superTapFired() }
    function toggleLauncher() {
        overviewOpen = false
        page = (page === "launcher") ? "home" : "launcher"
    }
    function toggleOverview() {
        if (!overviewOpen && page === "launcher") page = "home"
        overviewOpen = !overviewOpen
    }
    function focusWindow(w) {
        if (w.special && activeSpecial !== w.spName) {
            // window lives on a hidden special workspace: showing the workspace brings it up
            hypr("hl.dsp.workspace.toggle_special(\"" + w.spName + "\")")
            return
        }
        if (w.ref && w.ref.wayland) w.ref.wayland.activate()
        else hypr("hl.dsp.focus({ window = \"address:0x" + w.address + "\" })")
    }

    // hyprctl dispatch takes Lua expressions on Hyprland 0.55+
    function hypr(expr) { Quickshell.execDetached(["hyprctl", "dispatch", expr]) }

    function saveSettings() {
        if (!settingsLoaded) return
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/settings.json\"", "sh", stateDir,
                                 JSON.stringify({ autoHide: autoHide, autoPower: autoPower, compactSpecial: compactSpecial, dnd: dnd, edgeMode: edgeMode, glassShift: glassShift, motion: motion, rounding: rounding, gaps: gaps, blur: blur, shadows: shadows,
                                                  hyprAnim: hyprAnim, profileStars: profileStars, hyprTouched: hyprTouched,
                                                  profileName: profileName, profileAvatar: profileAvatar, routeApps: routeApps,
                                                  notifHistoryMax: notifHistoryMax, notifMax: notifMax, idleLock: idleLock, idleSleep: idleSleep, idleDim: idleDim, osdOn: osdOn, idleTouched: idleTouched,
                                                  clock24: clock24, growthOn: growthOn, growthMin: growthMin, superTap: superTap, termFollow: termFollow, colorBoost: colorBoost,
                                                  theme: theme, themeTouched: themeTouched, scrollTouch: scrollTouch, scrollMouse: scrollMouse, scrollTouched: scrollTouched,
                                                  barScroll: barScroll, barPadding: barPadding, powerMgr: powerMgr, hoverAction: hoverAction, compactWs: compactWs, opt: opt, hy: hy })])
    }
    // small one-line state files read by scripts / Hyprland's Lua config
    function writeFlag(name, value) {
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$3\" > \"$1/$2\"", "sh", stateDir, name, String(value)])
    }
    Timer { id: boostT; interval: 350; onTriggered: Quickshell.execDetached(["bash", cfg + "/island/scripts/palette.sh"]) }
    function setAutoHide(v) { autoHide = v; saveSettings() }
    function setCompactSpecial(v) { compactSpecial = v; saveSettings(); applySpecialScale() }
    // special workspace windows (scratch / music / communication / monitor / tasks): compact = a smaller window,
    // off = the normal full size. Same switch as the one in the SUPER+TAB tree. Sizes: variables.lua (specialScale*)
    readonly property real specialScaleCompact: 0.84      // keep equal to variables.lua
    readonly property real specialScaleFull: 1.0
    function applySpecialScale() {
        var f = compactSpecial ? specialScaleCompact : specialScaleFull
        Quickshell.execDetached(["hyprctl", "eval", "hl.config({ dwindle = { special_scale_factor = " + f + " }, master = { special_scale_factor = " + f + " } })"])
    }
    function setDnd(v) { dnd = v; saveSettings() }
    function setEdgeMode(m) { edgeMode = m; saveSettings() }

    // one entry point for every value the Settings window changes
    function setSetting(k, v) {
        if (k.indexOf("opt:") === 0) { setOpt(k.substring(4), v); return }
        if (k.indexOf("hy:") === 0) { setHy(k.substring(3), v); return }
        switch (k) {
        case "autoHide": setAutoHide(v); return
        case "dnd": setDnd(v); return
        case "clickMode": setEdgeMode(v ? "click" : "hover"); return
        case "gaming": setGaming(v); return
        case "profileStars": profileStars = v; break
        case "notifHistoryMax": notifHistoryMax = v; break
        case "notifMax": notifMax = v; break
        case "clock24": clock24 = v; break
        case "growthOn": growthOn = v; break
        case "growthMin": growthMin = v; break
        case "growthReset": growthMin = 0; break
        case "superTap": superTap = v; writeFlag("super-tap", v ? "on" : "off"); break
        case "termFollow": termFollow = v; writeFlag("term-follow", v ? "on" : "off"); if (v) Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/term-colors.sh", "--now"]); break
        case "colorBoost": colorBoost = Math.max(0.5, Math.min(1.5, v)); writeFlag("color-boost", colorBoost.toFixed(2)); boostT.restart(); break
        case "compactSpecial": setCompactSpecial(v); return
        case "routeApps": routeApps = v; break
        case "idleLock": idleLock = v; idleTouched = true; applyIdle(); break
        case "idleSleep": idleSleep = v; idleTouched = true; applyIdle(); break
        case "idleDim": idleDim = v; idleTouched = true; applyIdle(); break
        case "osdOn": osdOn = v; break
        case "glassShift": glassShift = v; break
        case "motion": motion = v; break
        case "rounding": rounding = v; hyprTouched = true; break
        case "gaps": gaps = v; hyprTouched = true; break
        case "blur": blur = v; hyprTouched = true; break
        case "shadows": shadows = v; hyprTouched = true; break
        case "hyprAnim": hyprAnim = v; hyprTouched = true; break
        case "theme": setTheme(v); return
        case "compactWs": compactWs = v; if (v) compactT.restart(); break
        case "hoverAction": hoverAction = v; hoverOpened = false; break
        case "barScroll": barScroll = v; break
        case "barPadding": barPadding = v; break
        case "powerMgr": powerMgr = v; Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/power_manager_select.sh", v]); break
        case "scrollTouch": scrollTouch = v; scrollTouched = true; break
        case "scrollMouse": scrollMouse = v; scrollTouched = true; break
        }
        saveSettings()
        if (["rounding", "gaps", "blur", "shadows", "hyprAnim", "scrollTouch", "scrollMouse"].indexOf(k) >= 0) hyprKick.restart()
    }

    // ---- theme: the island follows `pal.light`; Hyprland's borders and GTK/portal apps are told separately
    function setTheme(t) {
        theme = t === "light" ? "light" : "dark"
        themeTouched = true
        saveSettings()
        applyThemeApps()
        hyprKick.restart()
    }
    function toggleTheme() { setTheme(theme === "light" ? "dark" : "light") }
    function applyThemeApps() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/theme.sh", theme])
    }

    // ---- wallpaper: a thumbnail in Settings / next
    function setWallpaper(path) {
        wallpaperLayer.useFile(path)          // same process now (it used to be a second quickshell, ~100 MB more)
    }

    // ---- Settings > Edit config: the code editor chosen in Settings > Default apps (falls back to the file manager)
    function editConfig() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "run", "editor", Quickshell.env("HOME") + "/.config/Halcyon"])
    }

    // ---- shortcuts: changed / added in the cheatsheet. binds.json is ours, binds.lua is what hyprland/keybinds.lua reads;
    // a Hyprland reload applies it (batched, so changing several in a row reloads once)
    function saveBinds() {
        var json = JSON.stringify({ keys: keyMap, custom: customBinds })
        var lua = Binds.toLua(keyMap, customBinds)
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/binds.json\" && printf '%s' \"$3\" > \"$1/binds.lua\"", "sh", stateDir, json, lua])
        bindsReload.restart()
    }
    Timer { id: bindsReload; interval: 900; onTriggered: reloadProc.running = true }
    function setBind(id, keys) {
        var m = {}
        for (var k in keyMap) m[k] = keyMap[k]
        if (keys === "") delete m[id]; else m[id] = keys
        keyMap = m
        saveBinds()
    }
    function saveCustomBind(i, label, keys, cmd) {
        var l = customBinds.slice()
        var rec = { label: label, keys: keys, cmd: cmd }
        if (i >= 0 && i < l.length) l[i] = rec; else l.push(rec)
        customBinds = l
        saveBinds()
    }
    function removeCustomBind(i) {
        var l = customBinds.slice()
        if (i >= 0 && i < l.length) l.splice(i, 1)
        customBinds = l
        saveBinds()
    }
    Process {
        running: true
        command: ["sh", "-c", "cat \"$HOME/.local/state/island/binds.json\" 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var b = JSON.parse(text)
                    root.keyMap = b.keys || {}
                    root.customBinds = b.custom || []
                } catch (e) {}
            }
        }
    }
    function applyIdle() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/idle.sh", "apply", String(idleLock), String(idleSleep), String(idleDim)])
    }
    // Hyprland values are pushed live with `hyprctl eval` (same mechanism as scripts/toggle_layout.sh), batched so a
    // dragged slider does not spawn a process per pixel; not while Gaming mode owns them.
    // Only what you changed is pushed: the look sliders (hyprTouched), the theme borders, the scroll speeds.
    function luaVal(v) {
        if (typeof v === "string") return JSON.stringify(v)
        if (typeof v === "object") {
            var parts = []
            for (var k in v) parts.push((/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "[" + JSON.stringify(k) + "]") + " = " + luaVal(v[k]))
            return "{ " + parts.join(", ") + " }"
        }
        return String(v)
    }
    function applyHypr() {
        applySpecialScale()
        if (gaming) return
        var cfg = {}
        if (hyprTouched) {
            cfg.general = { gaps_in: gaps, gaps_out: gaps * 2 }
            cfg.decoration = { rounding: rounding, blur: { enabled: blur }, shadow: { enabled: shadows } }
            cfg.animations = { enabled: hyprAnim }
        }
        if (theme === "light" || themeTouched) {
            var dk = theme !== "light"
            var act = dk ? "rgba(ffffff30)" : "rgba(00000038)"
            var ina = dk ? "rgba(ffffff10)" : "rgba(00000014)"
            if (!cfg.general) cfg.general = {}
            cfg.general["col.active_border"] = act
            cfg.general["col.inactive_border"] = ina
            cfg.group = { "col.border_active": act, "col.border_inactive": ina, groupbar: { text_color: dk ? "rgb(dcdce6)" : "rgb(1b1d27)" } }
        }
        if (scrollTouched) cfg.input = { scroll_factor: scrollMouse, touchpad: { scroll_factor: scrollTouch } }
        // the values changed in Settings > Look / Windows / Input: each one into its place in the config table
        for (var hk in hy) {
            var path = hyMap[hk]
            if (!path) continue
            var node = cfg
            for (var pi = 0; pi < path.length - 1; pi++) {
                if (!node[path[pi]]) node[path[pi]] = {}
                node = node[path[pi]]
            }
            node[path[path.length - 1]] = hy[hk]
        }
        var any = false
        for (var k in cfg) any = true
        if (!any) return
        Quickshell.execDetached(["hyprctl", "eval", "hl.config(" + luaVal(cfg) + ")"])
    }
    Timer { id: hyprKick; interval: 250; onTriggered: root.applyHypr() }

    property double gamingGuard: 0      // ignore the state-file poll until this time (ms): the script needs a moment
    function setGaming(on) {
        gaming = on
        gamingGuard = Date.now() + 1400
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/gamemode.sh", on ? "on" : "off"])
        if (!on) { hyprKick.interval = 1200; hyprKick.restart() }   // the script reloads Hyprland; put our tweaks back on top
        gamingCheck.restart()
    }
    // the state file is the truth: re-read it shortly after a click and every few seconds, so the chip can never
    // disagree with the script (a toggle from SUPER+F10 / a terminal / a failed run all end up shown correctly)
    Timer { id: gamingCheck; interval: 1700; onTriggered: gamingProc.running = true }
    Timer { interval: 15000; running: true; repeat: true; onTriggered: gamingProc.running = true }
    function toggleEdgeMode() { setEdgeMode(clickMode ? "hover" : "click") }
    function setProfileInfo(name, avatar) { profileName = name; profileAvatar = avatar; saveSettings() }

    // ---- caffeine: screen stays awake, no idle lock / suspend (scripts/caffeine.sh holds a systemd-inhibit lock)
    function setCaffeine(on, mins) {
        caffeine = on
        caffeineGuard = Date.now() + 2200
        var args = ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/caffeine.sh", on ? "on" : "off"]
        if (on && mins) args.push(String(mins))
        Quickshell.execDetached(args)
        caffeineCheck.restart()
    }
    Timer { id: caffeineCheck; interval: 2400; onTriggered: caffeineProc.running = true }
    Timer { interval: 15000; running: true; repeat: true; onTriggered: caffeineProc.running = true }
    Process {
        id: caffeineProc
        running: true
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/caffeine.sh", "status"]
        stdout: StdioCollector { onStreamFinished: { if (Date.now() > root.caffeineGuard) root.caffeine = text.trim() === "on" } }
    }

    // ---- special workspaces: music / communication start their app the first time (scripts/special.sh)
    function toggleSpecial(name) {
        if (name === "music" || name === "communication")
            Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/special.sh", name])
        else
            hypr("hl.dsp.workspace.toggle_special(\"" + name + "\")")
    }

    // ---- app routing: when a window of a known app (Routes.js) opens, move it to its special workspace and show it.
    // `hyprctl clients` is read shortly after every new window (the class of some apps is set a moment late), and again
    // a little later. Windows that were open when the island started are left alone, and so is a window you move yourself.
    function routeSoon() { routeT.restart(); routeT2.restart() }
    function pollClients() { if (!clientsProc.running) clientsProc.running = true }
    Timer { id: routeT; interval: 700; onTriggered: root.pollClients() }
    Timer { id: routeT2; interval: 2800; onTriggered: root.pollClients() }
    Timer { interval: 1500; running: true; onTriggered: root.pollClients() }      // seeds the list at start
    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector { onStreamFinished: root.routeClients(text) }
    }
    property string showWs: ""
    Timer { id: showT; interval: 220; onTriggered: if (root.showWs !== "" && root.activeSpecial !== root.showWs) root.toggleSpecial(root.showWs) }
    function routeClients(text) {
        var cl = []
        try { cl = JSON.parse(text) } catch (e) { return }
        var keep = {}
        // do not pop a workspace over your work while the session is still starting (autostarted apps)
        var quiet = (Date.now() - startedAt) < 45000
        for (var i = 0; i < cl.length; i++) {
            var c = cl[i]
            if (routed[c.address]) { keep[c.address] = true; continue }
            var app = Routes.appForClass(c["class"])
            if (!app) continue
            keep[c.address] = true
            if (!routeSeeded || !routeApps) continue
            var wsName = c.workspace ? c.workspace.name : ""
            if (wsName === "special:" + app.ws) continue
            hypr("hl.dsp.window.move({ workspace = \"special:" + app.ws + "\", window = \"address:" + c.address + "\" })")
            if (!quiet) { showWs = app.ws; showT.restart() }
        }
        routed = keep
        routeSeeded = true
    }

    function toggleWifi() {
        var on = net.wifi === "on"
        Quickshell.execDetached(["nmcli", "radio", "wifi", on ? "off" : "on"])
        net = Object.assign({}, net, { wifi: on ? "off" : "on" })
    }
    function toggleBt() {
        var on = net.bt === "on"
        Quickshell.execDetached(["bluetoothctl", "power", on ? "off" : "on"])
        net = Object.assign({}, net, { bt: on ? "off" : "on" })
    }

    // picking a mode by hand stops the daemon (it would re-assert its own profile every 15s);
    // Auto starts it again, and the performance page keeps showing the profile that is actually active
    function setProfile(p) {
        autoPower = false
        autoGuard = Date.now() + 6000
        saveSettings()
        Quickshell.execDetached(["sh", "-c", "systemctl --user stop \"$1\"; powerprofilesctl set \"$2\"", "sh", powerService, p])
        profile = p
    }
    function setAuto() {
        autoPower = true
        autoGuard = Date.now() + 8000
        saveSettings()
        Quickshell.execDetached(["systemctl", "--user", "start", powerService])
        profKick.restart()
    }
    // the daemon's state file is the truth: SUPER+ALT+P (toggle_power.sh) flips Auto behind our back too
    onStatsChanged: {
        if (Date.now() > autoGuard) {
            var a = stats.auto === true
            if (a !== autoPower) { autoPower = a; saveSettings() }
        }
        if (autoPower && stats.pprofile) profile = stats.pprofile
    }

    function session(action) {
        switch (action) {
        case "lock": lockScreen.lock(); break
        case "suspend": Quickshell.execDetached(["systemctl", "suspend"]); break
        case "logout": hypr("hl.dsp.exit()"); break
        case "reboot": Quickshell.execDetached(["systemctl", "reboot"]); break
        case "shutdown": Quickshell.execDetached(["systemctl", "poweroff"]); break
        }
    }
    function randomWallpaper() {
        wallpaperLayer.next()
    }
    function runCommand(id) {
        if (id.indexOf("profile-") === 0) {
            var p = id.substring(8)
            if (p === "auto") setAuto(); else setProfile(p)
            return
        }
        switch (id) {
        case "wallpaper": randomWallpaper(); break
        case "settings": settingsWin.show(); break
        case "power": powerMenu.show(); break
        case "gaming": setGaming(!gaming); break
        case "caffeine": setCaffeine(!caffeine, 0); break
        case "apps": appsWin.pinFor(9000); break
        case "routing": routeApps = !routeApps; saveSettings(); break
        case "autohide": setAutoHide(!autoHide); break
        case "notifications": notifs.toggleCenter(); break
        case "quickterm": quickTerm.toggle(); break
        case "edgemode": toggleEdgeMode(); break
        case "dnd": setDnd(!dnd); break
        case "cheatsheet": cheat.toggle(); break
        case "theme": toggleTheme(); break
        case "wifi": toggleWifi(); break
        case "bluetooth": toggleBt(); break
        default: session(id)
        }
    }

    // ---------- data sources ----------
    Process {
        running: true
        command: ["sh", "-c", "cat \"$HOME/.local/state/island/settings.json\" 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var s = JSON.parse(text)
                    root.autoHide = !!s.autoHide
                    root.autoPower = !!s.autoPower
                    root.dnd = !!s.dnd
                    root.edgeMode = (s.edgeMode === "click" || s.edgeMode === "drag") ? "click" : "hover"
                    if (s.glassShift !== undefined) root.glassShift = s.glassShift
                    if (s.motion !== undefined) root.motion = s.motion
                    if (s.rounding !== undefined) root.rounding = s.rounding
                    if (s.gaps !== undefined) root.gaps = s.gaps
                    root.blur = s.blur !== false
                    root.shadows = s.shadows !== false
                    root.hyprAnim = s.hyprAnim !== false
                    root.profileStars = s.profileStars !== false
                    root.hyprTouched = !!s.hyprTouched
                    root.theme = s.theme === "light" ? "light" : "dark"
                    root.themeTouched = !!s.themeTouched
                    if (s.scrollTouch !== undefined) root.scrollTouch = s.scrollTouch
                    if (s.scrollMouse !== undefined) root.scrollMouse = s.scrollMouse
                    root.scrollTouched = !!s.scrollTouched
                    if (["low", "medium", "high"].indexOf(s.barScroll) >= 0) root.barScroll = s.barScroll
                    if (s.barPadding && ["low", "normal", "high"].indexOf(s.barPadding) >= 0) root.barPadding = s.barPadding
                    if (s.powerMgr) root.powerMgr = s.powerMgr
                    if (["none", "stats", "perf", "media"].indexOf(s.hoverAction) >= 0) root.hoverAction = s.hoverAction
                    root.compactWs = s.compactWs !== false
                    if (s.opt) {
                        var oo = {}
                        for (var ox in root.opt) oo[ox] = root.opt[ox]
                        for (var oy in s.opt) oo[oy] = s.opt[oy]
                        root.opt = oo
                    }
                    if (s.hy) {
                        root.hy = s.hy
                        var hc = {}
                        for (var hx in root.hyCur) hc[hx] = root.hyCur[hx]
                        for (var hz in s.hy) hc[hz] = s.hy[hz]
                        root.hyCur = hc
                    }
                    root.syncOptFlags()
                    if (root.themeTouched) root.applyThemeApps()
                    if (root.hyprTouched || root.themeTouched || root.scrollTouched || Object.keys(root.hy).length > 0) hyprKick.restart()
                    if (root.autoPower && root.powerMgr === "halcyon") {
                        root.autoGuard = Date.now() + 10000
                        Quickshell.execDetached(["systemctl", "--user", "start", root.powerService])
                    }
                    // a power manager other than Halcyon Auto: the system's own default starts at boot, so put the chosen one back
                    if (root.powerMgr !== "halcyon") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/power_manager_select.sh", root.powerMgr, "quiet"])
                    root.compactSpecial = s.compactSpecial !== false
                    root.applySpecialScale()
                    root.routeApps = s.routeApps !== false
                    root.profileName = s.profileName || ""
                    root.profileAvatar = s.profileAvatar || ""
                    if (s.notifHistoryMax !== undefined) root.notifHistoryMax = s.notifHistoryMax
                    if (s.notifMax !== undefined) root.notifMax = s.notifMax
                    root.clock24 = !!s.clock24
                    root.growthOn = s.growthOn !== false
                    root.superTap = s.superTap !== false
                    root.termFollow = s.termFollow !== false
                    if (s.colorBoost !== undefined) root.colorBoost = s.colorBoost
                    if (s.growthMin !== undefined) root.growthMin = s.growthMin
                    if (s.idleLock !== undefined) root.idleLock = s.idleLock
                    if (s.idleSleep !== undefined) root.idleSleep = s.idleSleep
                    if (s.idleDim !== undefined) root.idleDim = s.idleDim
                    root.osdOn = s.osdOn !== false
                    root.idleTouched = !!s.idleTouched
                    if (root.idleTouched) root.applyIdle()      // otherwise the autostart (idle.sh start) uses its defaults
                } catch (e) {}
                root.settingsLoaded = true
            }
        }
    }
    // tree-branch shader (branch.frag): compiled once with Qt's `qsb` into ~/.cache/halcyon, again only when branch.frag changes.
    // No qsb on the machine (package qt6-shadertools) = the url stays empty and the branches use the Shape fallback.
    property string branchShaderUrl: ""
    Process {
        running: true
        command: ["bash", root.cfg + "/island/scripts/build-shader.sh"]
        stdout: StdioCollector { onStreamFinished: { var p = text.trim(); if (p !== "") root.branchShaderUrl = "file://" + p } }
    }
    Process {
        id: gamingProc
        running: true
        command: ["sh", "-c", "test -f /dev/shm/halcyon-gamemode && echo on || echo off"]
        stdout: StdioCollector { onStreamFinished: { if (Date.now() > root.gamingGuard) root.gaming = text.trim() === "on" } }
    }
    Process {
        running: true
        command: ["bash", root.cfg + "/island/scripts/stats.sh", "2"]
        stdout: SplitParser { onRead: d => { try { root.stats = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        id: avatarProc
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/avatar.sh", root.profileAvatar]
        stdout: StdioCollector { onStreamFinished: { root.avatarPath = text.trim(); root.makeStars() } }
    }
    // The picture constellation: `scripts/portrait.sh` turns the profile picture into a high-detail sky whose stars and
    // lines are born one after the other as the island is used, so at full growth it IS the picture (eyes, hair, outline).
    // If that script is missing or gives nothing, the older route is used: four `hx stars` calls (70 / 110 / 160 / 220
    // stars) merged into nested levels (see StarData.fromLevels).
    Process {
        id: starProc
        // `hx portrait` does it in milliseconds. Exit 1 = this picture gives no usable stars (-> a sky from your name);
        // anything else (an older hx without `portrait`) falls back to the awk script, then to four `hx stars` calls.
        command: ["sh", "-c", "\"$3\" portrait \"$2\" \"$4\"; rc=$?; case $rc in 0|1) ;; *) bash \"$1\" \"$2\" \"$4\" || for n in 70 110 160 220; do \"$3\" stars \"$2\" $n; done ;; esac",
                  "sh", root.cfg + "/island/scripts/portrait.sh", root.avatarPath, root.hx, String(root.starGrid)]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.split("\n").filter(function (l) { return l.trim() !== "" })
                var d = null
                try {
                    if (lines.length === 1) d = Stars.fromPortrait(lines[0])
                    else if (lines.length > 1) d = Stars.fromLevels(lines)
                } catch (e) {}
                root.starData = d ? d : Stars.fromName(root.starName)
            }
        }
    }
    Process {
        id: specsProc
        running: true
        command: [root.hx, "specs"]
        stdout: StdioCollector { onStreamFinished: { try { root.specs = JSON.parse(text) } catch (e) {} } }
    }
    // after "Detect RAM details" (Settings): read the hardware list again once the password was given
    Timer { id: specsAgain; interval: 12000; onTriggered: { specsProc.running = false; specsProc.running = true } }
    Process {
        running: root.page === "perf"
        command: [root.hx, "disk", "10"]
        stdout: SplitParser { onRead: d => { try { root.disks = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        running: root.page === "perf"
        command: ["bash", root.cfg + "/island/scripts/gpu.sh", "2"]
        stdout: SplitParser { onRead: d => { try { root.gpu = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        running: true
        command: ["bash", root.cfg + "/island/scripts/net.sh", "4"]
        stdout: SplitParser { onRead: d => { try { root.net = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        id: profProc
        command: ["powerprofilesctl", "get"]
        stdout: SplitParser { onRead: d => { if (d.trim()) root.profile = d.trim() } }
    }
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: profProc.running = true }
    Timer { id: profKick; interval: 3500; onTriggered: profProc.running = true }

    // volume / brightness, only polled while the bottom-right panel is open
    Process {
        running: corner.open
        command: [root.hx, "ctl"]
        stdout: SplitParser {
            onRead: d => {
                try {
                    var c = JSON.parse(d)
                    root.vol = c.vol; root.muted = c.muted; root.bright = c.bright
                    root.mic = c.mic || 0; root.micMuted = !!c.micMuted
                } catch (e) {}
            }
        }
    }
    property real pendVol: -1
    property real pendMic: -1
    property real pendBright: -1
    Timer {
        id: sliderT
        interval: 70
        onTriggered: {
            if (root.pendVol >= 0) {
                Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", Math.round(root.pendVol * 100) + "%"])
                root.pendVol = -1
            }
            if (root.pendMic >= 0) {
                Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@", Math.round(root.pendMic * 100) + "%"])
                root.pendMic = -1
            }
            if (root.pendBright >= 0) {
                Quickshell.execDetached(["brightnessctl", "set", Math.max(1, Math.round(root.pendBright * 100)) + "%"])
                root.pendBright = -1
            }
        }
    }

    // visualizer feed, only runs while something is playing
    Process {
        running: root.playing && !root.gaming
        command: ["cava", "-p", Quickshell.shellPath("cava.conf")]
        stdout: SplitParser {
            onRead: d => {
                var a = d.split(";"), out = []
                for (var i = 0; i < a.length; i++) if (a[i] !== "") out.push(parseInt(a[i]))
                root.cava = out
            }
        }
        onRunningChanged: if (!running) root.cava = []
    }

    // which special workspace is open ("" = none)
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "activespecial")
                root.activeSpecial = event.data.split(",")[0].replace("special:", "")
            else if (event.name === "openwindow")
                root.routeSoon()
            if (["workspacev2", "focusedmonv2", "openwindow", "closewindow", "movewindowv2", "destroyworkspacev2"].indexOf(event.name) >= 0)
                compactT.restart()
        }
    }

    // ---- compact workspaces: you are on workspace 3, nothing is on 1 or 2 -> the windows of 3 move to workspace 1.
    // Looked at a moment after things settle; not while a special workspace, the tree, Gaming mode or the first seconds of the session.
    Timer { id: compactT; interval: 800; onTriggered: root.checkCompact() }
    function checkCompact() {
        if (!compactWs || gaming || overviewOpen || activeSpecial !== "" || (Date.now() - startedAt) < 6000) return
        if (!compactProc.running) compactProc.running = true
    }
    Process {
        id: compactProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                var f = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
                if (f <= 1 || !root.compactWs || root.activeSpecial !== "") return
                var cl = []
                try { cl = JSON.parse(text) } catch (e) { return }
                var mine = []
                for (var i = 0; i < cl.length; i++) {
                    var w = cl[i].workspace ? cl[i].workspace.id : 0
                    if (!cl[i].mapped) continue
                    if (w > 0 && w < f) return              // something is before it: leave everything alone
                    if (w === f) mine.push(cl[i].address)
                }
                if (mine.length === 0) return                // an empty workspace you walked to on purpose stays put
                var cmds = []
                for (var j = 0; j < mine.length; j++)
                    cmds.push("dispatch hl.dsp.window.move({ workspace = 1, window = \"address:" + mine[j] + "\" })")
                cmds.push("dispatch hl.dsp.focus({ workspace = 1 })")
                Quickshell.execDetached(["hyprctl", "--batch", cmds.join(" ; ")])
            }
        }
    }

    // the wallpaper layer (circular reveal) lives in this same Quickshell process: one Qt/QML/GL stack instead of two.
    // `quickshell ipc -p ~/.config/Halcyon/quickshell/island call wallpaper next` still works (target "wallpaper" in Wallpaper.qml)
    Wallpaper { id: wallpaperLayer }

    // quickshell ipc -p ~/.config/Halcyon/quickshell/island call island <fn>
    IpcHandler {
        target: "island"
        function launcher(): void { root.toggleLauncher() }
        function supertap(): void { root.superTapFired() }
        function overview(): void { root.toggleOverview() }
        function home(): void { root.page = "home" }
        function media(): void { root.page = "media" }
        function perf(): void { root.page = "perf" }
        function panel(): void { corner.pinFor(6000) }
        function autohide(): void { root.setAutoHide(!root.autoHide) }
        function clearnotifs(): void { notifs.clearAll() }
        function notifcenter(): void { notifs.toggleCenter() }
        function dnd(): void { root.setDnd(!root.dnd) }
        function dndset(on: bool): void { root.setDnd(on) }          // set (gamemode.sh): dnd() above only toggles
        function cheatsheet(): void { root.runCommand("cheatsheet") }
        function theme(): void { root.toggleTheme() }
        function quickterm(): void { quickTerm.toggle() }
        function edgemode(): void { root.toggleEdgeMode() }
        function settings(): void { settingsWin.toggle() }
        function power(): void { powerMenu.show() }
        function gaming(): void { root.setGaming(!root.gaming) }
        function caffeine(): void { root.setCaffeine(!root.caffeine, 0) }
        function apps(): void { appsWin.pinFor(9000) }
        function routing(): void { root.runCommand("routing") }
        function lock(): void { lockScreen.lock() }
        function reload(): void { fullReloadProc.running = true }
    }

    // =====================================================================
    //  TOP: the island (bar -> media / performance pages -> expanding search bar)
    // =====================================================================
    PanelWindow {
        id: win

        anchors { top: true; left: true; right: true }
        implicitHeight: 620
        // auto-hide frees the strip the bar reserves; otherwise windows start below the bar
        // Hyprland starts windows at (this zone + the outer gap), so the outer gap is taken off to get exactly padSet.gap between bar and windows
        // (it can not go lower than the outer gap itself: Settings > Look > Gaps)
        exclusiveZone: root.autoHide ? 0 : Math.max(0, root.padSet.top + root.padSet.h + root.padSet.gap - root.gaps * 2)
        color: "transparent"

        WlrLayershell.namespace: "island"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: root.page === "launcher" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // ---- auto-hide: the bar slides away until the pointer touches the top edge
        property bool peek: false
        readonly property bool shown: !root.autoHide || peek || root.page !== "home"
        function peekHover(on) {
            if (on) { hideTimer.stop(); peek = true } else hideTimer.restart()
        }
        Timer { id: hideTimer; interval: 700; onTriggered: win.peek = false }

        mask: root.page === "launcher" ? launcherMask : normalMask
        Region { id: launcherMask; item: backdrop }
        Region { id: normalMask; regions: [ Region { item: strip }, Region { item: island } ] }

        Item {
            id: backdrop
            anchors.fill: parent
            MouseArea {
                anchors.fill: parent
                enabled: root.page === "launcher"
                onClicked: root.page = "home"
            }
        }

        // thin hot strip along the top edge that reveals a hidden bar
        Item {
            id: strip
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: 420
            height: 5
            HoverHandler { onHoveredChanged: win.peekHover(hovered) }
        }

        // soft halo around the island; follows its size while it grows and shrinks.
        // Hollow on purpose: nothing sits under the glass, so the bar stays light.
        HaloShadow {
            anchors.fill: island
            radius: island.radius
            spread: 22
            peak: 0.18
            opacity: win.shown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: pal.dMed } }
        }

        Glass {
            id: island
            pal: pal
            shadow: false           // drawn by the HaloShadow above (this item clips its content)
            // light glass as the bar, a bit more solid once it grows into a page / the launcher
            opacityBody: root.page === "home" ? pal.glassBar : pal.glassBarOpen
            Behavior on opacityBody { NumberAnimation { duration: pal.dMed } }
            anchors.top: parent.top
            anchors.topMargin: win.shown ? root.padSet.top : -(height + 30)
            anchors.horizontalCenter: parent.horizontalCenter
            clip: true

            width: root.page === "home" ? home.implicitWidth + root.padSet.x
                 : root.page === "media" ? 500
                 : root.page === "perf" ? 720
                 : launcher.wantedWidth
            height: root.page === "home" ? root.padSet.h
                  : root.page === "media" ? 156
                  : root.page === "perf" ? 316
                  : launcher.wantedHeight
            radius: root.page === "home" ? height / 2 : pal.rXl

            property real dragX: 0

            // one soft curve for everything: fast start, long gentle landing, no overshoot
            Behavior on anchors.topMargin { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
            Behavior on width { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
            Behavior on height { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
            Behavior on radius { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

            // swallow clicks so they don't reach the backdrop
            MouseArea { anchors.fill: parent }

            HoverHandler { id: hov; onHoveredChanged: win.peekHover(hovered) }

            // Settings > Bar > "When you hover the bar": perf / media open by themselves after the pointer rests on the bar
            property bool hoverSpent: false
            Connections { target: hov; function onHoveredChanged() { if (!hov.hovered) island.hoverSpent = false } }
            Timer {
                interval: 350
                running: hov.hovered && root.page === "home" && !island.hoverSpent && (root.hoverAction === "perf" || root.hoverAction === "media")
                onTriggered: { root.hoverOpened = true; root.page = root.hoverAction }
            }
            // media/perf fall back to the bar when the pointer leaves (quickly if hovering opened them)
            Timer {
                interval: root.opt.pageClose !== undefined ? root.opt.pageClose : 600
                running: (root.page === "media" || root.page === "perf") && !hov.hovered
                onTriggered: { root.page = "home"; root.hoverOpened = false }
            }

            // scroll / two-finger swipe to move between pages
            // (Settings > Bar > scroll: how much scrolling counts as "one swipe")
            Timer { id: wheelCool; interval: 450 }
            property real wheelAcc: 0
            Timer { id: wheelReset; interval: 300; onTriggered: island.wheelAcc = 0 }
            WheelHandler {
                enabled: root.page !== "launcher"
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: e => {
                    if (wheelCool.running) return
                    var d = Math.abs(e.angleDelta.x) > Math.abs(e.angleDelta.y) ? e.angleDelta.x : e.angleDelta.y
                    if (d === 0) return
                    island.wheelAcc += d
                    wheelReset.restart()
                    if (Math.abs(island.wheelAcc) < root.barScrollStep) return
                    root.go(island.wheelAcc > 0 ? -1 : 1)
                    island.wheelAcc = 0
                    wheelCool.start()
                }
            }

            // hold + drag the bar sideways: drag left -> performance, drag right -> media
            DragHandler {
                id: dragH
                target: null
                enabled: root.page !== "launcher"
                xAxis.enabled: true
                yAxis.enabled: false
                onTranslationChanged: if (active) island.dragX = translation.x
                onActiveChanged: {
                    if (active) return
                    var dx = island.dragX
                    island.dragX = 0
                    if (dx < -50) root.go(1)
                    else if (dx > 50) root.go(-1)
                }
            }

            // pages follow the pointer while dragging
            Item {
                id: pager
                anchors.fill: parent
                x: island.dragX * 0.35
                Behavior on x { enabled: !dragH.active; NumberAnimation { duration: pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

                Home {
                    id: home
                    anchors.centerIn: parent
                    pal: pal
                    stats: root.stats
                    net: root.net
                    cava: root.cava
                    clock24: root.clock24
                    clockSeconds: root.opt.clockSeconds
                    clockDate: root.opt.clockDate
                    playing: root.playing
                    activeSpecial: root.activeSpecial
                    caffeine: root.caffeine
                    showStats: root.hoverAction === "stats" && hov.hovered
                    bgCount: bgPanel.count
                    showBgCount: root.opt.bgWhere !== "corner"
                    onBgClicked: appsWin.pinFor(9000)
                    opacity: root.page === "home" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                    onStatusClicked: root.page = "perf"
                    onWorkspaceClicked: n => root.hypr("hl.dsp.focus({ workspace = " + n + " })")
                    onWorkspaceScrolled: d => Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/ws-nav.sh", d > 0 ? "wheel-up" : "wheel-down"])
                    onSpecialClicked: name => root.toggleSpecial(name)
                }

                MediaPage {
                    anchors.fill: parent
                    pal: pal
                    player: root.player
                    opacity: root.page === "media" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                }

                PerfPage {
                    anchors.fill: parent
                    pal: pal
                    stats: root.stats
                    gpu: root.gpu
                    specs: root.specs
                    disks: root.disks
                    net: root.net
                    profile: root.profile
                    profileLabel: root.profileLabel
                    autoPower: root.autoPower
                    autoNote: root.autoNote
                    sysmode: root.stats.sysmode || ""
                    opacity: root.page === "perf" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                    onToggleWifi: root.toggleWifi()
                    onToggleBt: root.toggleBt()
                    onSetProfile: p => root.setProfile(p)
                    onSetAuto: root.setAuto()
                }
            }

            Launcher {
                id: launcher
                // fixed at the FINAL size and pinned to the top: the pill grows over it like a curtain. With
                // anchors.fill the whole grid was re-laid out on every frame of the grow animation (that was the roughness).
                anchors.top: parent.top
                anchors.topMargin: 22
                anchors.horizontalCenter: parent.horizontalCenter
                width: launcher.wantedWidth - 44
                height: launcher.wantedHeight - 44
                pal: pal
                active: root.page === "launcher"
                opacity: root.page === "launcher" ? 1 : 0
                visible: opacity > 0.01
                // opening: wait a moment so the pill has started to grow, then fade in; closing: fade out at once
                Behavior on opacity {
                    SequentialAnimation {
                        PauseAnimation { duration: root.page === "launcher" ? Math.round(pal.dMed * 0.3) : 0 }
                        NumberAnimation { duration: root.page === "launcher" ? pal.dMed : pal.dFast; easing.type: Easing.OutCubic }
                    }
                }
                onCloseRequested: root.page = "home"
                onCommandRequested: c => root.runCommand(c)
            }
        }
    }

    // =====================================================================
    //  FULLSCREEN: SUPER+TAB live tree (laptop -> workspaces -> windows)
    // =====================================================================
    LazyLoader {
        active: root.overviewOpen
        PanelWindow {
            id: ovWin

            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            visible: true
            color: "transparent"

            WlrLayershell.namespace: "island-overview"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.overviewOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Overview {
                id: tree
                anchors.fill: parent
                pal: root.palObj
                open: root.overviewOpen
                compactSpecial: root.compactSpecial
                profileName: root.profileName
                profileAvatar: root.profileAvatar
                avatarFile: root.avatarPath
                starData: root.starData
                sysmode: root.sysmode
                profileStars: root.profileStars

                onCloseRequested: root.overviewOpen = false
                onCompactToggled: on => root.setCompactSpecial(on)
                onProfileSaved: (name, avatar) => root.setProfileInfo(name, avatar)
                onWorkspaceClicked: n => { root.overviewOpen = false; root.hypr("hl.dsp.focus({ workspace = " + n + " })") }
                onSpecialClicked: name => { root.overviewOpen = false; root.hypr("hl.dsp.workspace.toggle_special(\"" + name + "\")") }
                onWindowClicked: w => { root.overviewOpen = false; root.focusWindow(w) }
                // drag a window node onto a workspace node: move it, keep the tree open so you see it land
                onWindowMoved: (address, target) => {
                    var ws = target.indexOf("special:") === 0 ? "\"" + target + "\"" : target
                    root.hypr("hl.dsp.window.move({ workspace = " + ws + ", window = \"address:0x" + address + "\" })")
                }
            }
        }
    }

    // =====================================================================
    //  BOTTOM-RIGHT: hover the corner for wifi / bluetooth / volume / power / rice / session
    // =====================================================================
    PanelWindow {
        id: corner

        anchors { bottom: true; right: true }
        // only as big as the box while it is open or fading out; closed it is a small corner tab (a 450x900 surface = ~5 MB of
        // buffers here and again in Hyprland for nothing). The box fades in over ~200 ms, so the resize is not visible.
        readonly property bool big: open || panel.visible
        implicitWidth: big ? pal.boxW + pal.boxEdge + 30 : 48     // same box width / edge gap as the notification centre
        implicitHeight: big ? 900 : 48
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.namespace: "island-panel"
        WlrLayershell.layer: WlrLayer.Top
        // only the Wi-Fi password field needs keys; click it to focus
        WlrLayershell.keyboardFocus: panel.wantsKeys ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        property bool hovering: false
        property bool zoneHover: false      // pointer in the corner / gap zone
        property bool panelHover: false     // pointer on the panel itself (its chips and sliders take hover away from the zone)
        function syncHover() { setHover(zoneHover || panelHover) }
        readonly property bool open: hovering
        readonly property real reveal: hovering ? 1 : 0
        // hover mode: touching the corner opens it and leaving closes it. click mode: click the corner to open / close it.
        // auto-hide on closes it when the pointer leaves, in both modes
        function setHover(on) {
            if (on) { closeT.stop(); if (!root.clickMode) hovering = true }
            else if (!panel.wantsKeys && (!root.clickMode || root.autoHide)) { closeT.interval = 450; closeT.restart() }
        }
        // open it from the launcher / keybind; closes by itself if you don't touch it
        function pinFor(ms) { hovering = true; closeT.interval = ms; closeT.restart() }
        Timer { id: closeT; interval: 450; onTriggered: corner.hovering = false }

        // one hover zone for corner + panel (see QuickTerm.qml): no flicker when the panel slides in under the pointer
        mask: Region { item: zone }
        Item {
            id: zone
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: corner.open ? panel.width + pal.boxEdge + 30 : (root.clickMode ? 28 : 12)
            height: corner.open ? panel.height + pal.boxEdge + 30 : (root.clickMode ? 28 : 12)
            HoverHandler { onHoveredChanged: { corner.zoneHover = hovered; corner.syncHover() } }
            Rectangle {
                visible: root.clickMode && !corner.open
                anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.rightMargin: 3; anchors.bottomMargin: 3
                width: 12; height: 12; radius: 6
                color: Qt.alpha(pal.accent, 0.35)
            }
            Item {
                anchors.right: parent.right; anchors.bottom: parent.bottom
                width: 20; height: 20
                TapHandler {
                    enabled: root.clickMode
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: { if (corner.hovering) { closeT.stop(); corner.hovering = false } else { closeT.stop(); corner.hovering = true } }
                }
            }
        }

        Panel {
            id: panel
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: pal.boxEdge
            anchors.bottomMargin: pal.boxEdge
            pal: pal
            active: corner.open
            stats: root.stats
            net: root.net
            profile: root.profile
            autoPower: root.autoPower
            autoHide: root.autoHide
            gaming: root.gaming
            caffeine: root.caffeine
            mic: root.mic
            micMuted: root.micMuted
            vol: root.vol
            muted: root.muted
            bright: root.bright

            // hovering anything inside the panel keeps the whole box open (same idea as the notification centre)
            HoverHandler { onHoveredChanged: { corner.panelHover = hovered; corner.syncHover() } }

            opacity: corner.reveal
            visible: opacity > 0.01
            scale: 0.94 + 0.06 * corner.reveal
            transformOrigin: Item.BottomRight
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on scale { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

            onToggleWifi: root.toggleWifi()
            onToggleBt: root.toggleBt()
            onSetProfile: p => root.setProfile(p)
            onSetAuto: root.setAuto()
            onOpenSettings: settingsWin.show()
            onToggleGaming: root.setGaming(!root.gaming)
            onToggleCaffeine: root.setCaffeine(!root.caffeine, 0)
            onCaffeineHour: root.setCaffeine(true, 60)
            onOpenApps: appsWin.pinFor(9000)
            onOpenPower: powerMenu.show()
            onToggleMute: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            onToggleMic: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
            onMicMoved: v => { root.pendMic = v; root.mic = v * 100; if (!sliderT.running) sliderT.start() }
            onVolumeMoved: v => { root.pendVol = v; root.vol = v * 100; if (!sliderT.running) sliderT.start() }
            onBrightnessMoved: v => { root.pendBright = v; root.bright = v * 100; if (!sliderT.running) sliderT.start() }
        }
    }

    // =====================================================================
    //  BOTTOM-LEFT: background apps (Spotify, Discord ... that keep running without a window): open / quit them
    // =====================================================================
    PanelWindow {
        id: appsWin

        anchors { bottom: true; left: true }
        readonly property bool big: open || bgPanel.visible      // see the utilities box: small corner tab while closed
        implicitWidth: big ? pal.boxW + pal.boxEdge + 30 : 48
        implicitHeight: big ? 700 : 48
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.namespace: "island-apps"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // same open / close behaviour as the utilities box in the opposite corner (hover or click, see Edge boxes)
        property bool hovering: false
        property bool zoneHover: false
        property bool panelHover: false
        function syncHover() { setHover(zoneHover || panelHover) }
        readonly property bool open: hovering
        readonly property real reveal: hovering ? 1 : 0
        function setHover(on) {
            if (on) { aClose.stop(); if (!root.clickMode) hovering = true }
            else if (!root.clickMode || root.autoHide) { aClose.interval = 450; aClose.restart() }
        }
        function pinFor(ms) { hovering = true; aClose.interval = ms; aClose.restart() }
        Timer { id: aClose; interval: 450; onTriggered: appsWin.hovering = false }

        mask: Region { item: aZone }
        Item {
            id: aZone
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            width: appsWin.open ? bgPanel.width + pal.boxEdge + 30 : (root.clickMode ? 28 : 12)
            height: appsWin.open ? bgPanel.height + pal.boxEdge + 30 : (root.clickMode ? 28 : 12)
            HoverHandler { onHoveredChanged: { appsWin.zoneHover = hovered; appsWin.syncHover() } }
            Rectangle {
                visible: root.clickMode && !appsWin.open
                anchors.left: parent.left; anchors.bottom: parent.bottom
                anchors.leftMargin: 3; anchors.bottomMargin: 3
                width: 12; height: 12; radius: 6
                color: Qt.alpha(pal.accent, 0.35)
            }
            Item {
                anchors.left: parent.left; anchors.bottom: parent.bottom
                width: 20; height: 20
                TapHandler {
                    enabled: root.clickMode
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: { aClose.stop(); appsWin.hovering = !appsWin.hovering }
                }
            }
        }

        // how many apps are alive in the background: a small count on the corner while the box is closed
        Rectangle {
            visible: bgPanel.count > 0 && !appsWin.open && root.opt.bgWhere === "corner"
            anchors.left: parent.left; anchors.bottom: parent.bottom
            anchors.leftMargin: 6; anchors.bottomMargin: 6
            width: 18; height: 18; radius: 9
            color: Qt.alpha(pal.accent, 0.9)
            Text {
                anchors.centerIn: parent
                text: bgPanel.count
                color: pal.bg
                font.family: pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold
            }
        }

        BgApps {
            id: bgPanel
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.leftMargin: pal.boxEdge
            anchors.bottomMargin: pal.boxEdge
            pal: pal
            active: appsWin.open

            HoverHandler { onHoveredChanged: { appsWin.panelHover = hovered; appsWin.syncHover() } }

            opacity: appsWin.reveal
            visible: opacity > 0.01
            scale: 0.94 + 0.06 * appsWin.reveal
            transformOrigin: Item.BottomLeft
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on scale { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
        }
    }
}
