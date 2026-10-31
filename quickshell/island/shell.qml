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
import "Tour.js" as TourData
import "DeskSpots.js" as DS
import "WidgetData.js" as WD
import "BarLayout.js" as BL

ShellRoot {
    id: root

    // ---------- tunables ----------
    // Auto power mode = the power-manager daemon (custom/power-manager, user service power-manager.service).
    // Its thresholds (load, battery, heat, idle) live in custom/power-manager/src/main.rs.
    readonly property string powerService: "power-manager.service"
    // Settings > Bar > Padding: low | normal | high  ->  bar height, side padding, and the space ABOVE the bar (to the screen edge)
    // = the space BELOW it (to the windows): the same number, so the bar sits evenly. "low" is almost touching both.
    readonly property bool notchStyle: opt.barStyle === "notch" || opt.barStyle === "custom" || opt.barStyle === "rail" || opt.barStyle === "off"      // custom = the bar builder (CustomBar.qml): the same hanging bar; off = no bar at all (the pages and the launcher still hang from the top edge)
    // Style Custom / Rail: which edge the bar sits on (Bar builder > Side). A bar that is not on the top edge leaves the top free, like Bar style = Off:
    // the pages and the launcher still hang from the top edge, and the top of the border is reserved by the island window below.
    readonly property string barSide: {
        var l = opt.barLayout
        var s = l ? l.side : ""
        return (s === "bottom" || s === "left" || s === "right") ? s : "top"
    }
    readonly property bool topFree: opt.barStyle === "off" || ((opt.barStyle === "custom" || opt.barStyle === "rail") && barSide !== "top")
    property bool notchHovered: false
    // Settings > Bar style > Border around the screen: a frame (ScreenFrame.qml) the bar hangs from and the boxes slide out of
    readonly property bool frameOn: opt.frame === true
    readonly property int frameT: frameOn ? Math.max(4, Math.min(28, Math.round(Number(opt.frameW) || 12))) : 0
    readonly property bool cornerOut: frameOn && opt.boxOut !== "side"      // boxes come out of the corner (Desktop builder), not just the side
    readonly property int frameR: opt.frameR === undefined ? 22 : Math.max(0, Math.min(40, Math.round(Number(opt.frameR))))
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
        launchSpeed: "quick",      // normal | quick | instant : how fast the launcher grows out of the bar (root.launchK)
        accentMode: "fixed",       // fixed | cycle : the accent is the wallpaper's main colour, or drifts through all of its colours
        cycleSecs: 30,             // seconds from one wallpaper colour to the next
        termMode: "spectrum",      // spectrum | accent : terminal colours from every wallpaper colour, or from the one accent
        termDrift: false,          // open terminals follow the accent cycle
        wsEnd: "new",              // new | wrap | stay : "next workspace" on the last one (scripts/ws-nav.sh)
        wsStart: "wrap",           // wrap | stay : "previous workspace" on the first one
        wsMax: 9,                  // "next workspace" never opens a workspace above this number
        wpEvery: 0,                // minutes between automatic wallpaper changes (0 = off)
        wpSource: "local",         // local | online | mixed : where "next wallpaper" takes pictures from (scripts/wallpaper.sh)
        wpCat: "nature",           // online category: nature movies anime anime-art space city minimal cars random custom
        wpQuery: "",               // the search word used when wpCat is "custom"
        wpBootNew: false,          // a new random wallpaper at every boot (scripts/wallpaper.sh); off = the one you chose stays
        deskLive: "off",           // off | on : live wallpaper instead of the picture (Wallpaper.qml; Super + Alt + W)
        deskLivePick: "sky",       // which one: "sky" = the Halcyon sky (LiveSky.qml), or a video / GIF path (LiveVideo.qml, scripts/live-wallpapers.sh)
        gamePillSide: "l",         // l | r : the screen edge the game overlay tab is tucked into (GamePill.qml; its Move button flips it)
        deskLiveWord: true,        // the word HALCYON under the mark of the live sky
        widgetHalo: true,          // desktop widgets: the faint dark glow behind the words on a busy wallpaper (WidgetHost.qml)
        widgetReadability: 0,      // desktop widgets: percent added to every widget's own Readability (-30 .. 40)
        widgetDim: "wall",         // off | wall | auto | widgets : dim the whole wallpaper (default) or only behind widgets, so they read (WidgetHost.qml, Wallpaper.qml)
        widgetDimAmt: 0.35,        // how dark (0.1 .. 0.8)
        clockSeconds: false,       // show seconds in the bar clock
        clockDate: true,           // show the weekday and date next to the clock
        calOn: true,               // Calendar master switch (Super + R, >calendar, the clock click, reminders, auto Focus)
        calClock: true,            // a click on the bar clock drops the calendar out of the bar (instead of the old click action)
        calNotify: true,           // reminder notifications
        calFocus: false,           // start a Focus session when a task begins
        calNag: false,             // keep reminding until a task is marked done
        calNagEvery: 5,            // minutes between the nags
        calNagGiveUp: 180,         // stop nagging this many minutes after the task ended
        calTasks: "marked",        // marked | all : which events count as tasks
        clockAlign: "colon",       // colon | text : which part of the clock sits on the screen's centre line (Settings > Clock)
        clockNudge: 0,             // extra px to push the clock right (negative = left), on top of clockAlign
        accentBorder: true,        // the focused window's border takes the wallpaper accent (off = neutral white hairline)
        surface: "tint",           // tint | match | matte | black : the box background (Settings > Look > Box background); matte / black are solid and need the dark theme
        dropDown: "side",          // off | stack | side : drag the bar down for the utilities box (stack: drag again for the notifications; side: notifications beside it)
        osdHold: 1700,             // ms the volume / brightness bar stays
        keysStyle: "pages",        // tree | pages : the layout of the Shortcuts cheatsheet (the chip in its header, or Settings > Look > Shortcuts layout)
        settingsStyle: "pages",    // tree | pages : the layout of the Settings window (both stay; Settings > Look > Settings layout)
        toastSecs: 0,              // seconds a notification popup stays (0 = what the app asks for)
        critSecs: 30,              // seconds an urgent popup stays before it hides itself (0 = until clicked); it stays in the centre either way
        notifSpot: "edge",         // edge | corner : where the notification centre is opened from: a strip on the right edge, or the top-right corner
        notifStyle: "stack",       // stack | timeline | grouped : the look of the notification centre (Settings > Panels & notifications)
        notifLayout: null,         // the notification box builder's layout (NotifLayout.js); null = the default box
        notifIcon: "pfp",          // pfp | app : the picture of a notification is your profile picture (app icon as a badge), or the app's icon
        connErrOnly: false,        // Wi-Fi / Bluetooth: false = a notification for every connect / disconnect, true = only when connecting fails (scripts/wifi-connect.sh, bt-set.sh read the flag conn-errors-only)
        wifiVerbose: true,         // Wi-Fi: show every connection step (finding the network, authenticating, obtaining the IP ...) under the list in the utilities box
        bgRefresh: "normal",       // normal | relaxed | slow | auto (High / Medium / Low / Adaptive; its own choice, not part of the Resource use presets) : how often the always-on readers (CPU / battery / network state) look again while nothing needs them fresh (see syncRefresh below)
        viz: "full",               // full | light | off : the music bars in the bar: cava at 30 fps / 15 fps / not started at all
        wsSwipe4: "left",          // left | right : only the starting point for the 4-finger swipes now (Settings > Touchpad gestures sets them; scripts/input-conf.sh reads it once)
        wsInvert: false,           // invert the direction of workspace scrolling: bar wheel over the numbers + 3 / 4 finger swipes (scripts/ws-nav.sh)
        nightTemp: 4000,           // night light colour temperature (K)
        settingsGlass: 0.72,       // how opaque the Settings window is (lower = more see-through)
        lockBg: "solid",           // solid | wallpaper | sky : the plain theme colour, the current wallpaper blurred, or the splash's drifting stars (Lock.qml)
        lockBlur: 40,              // blur radius of that wallpaper (4 .. 64)
        lockTint: 0.55,            // how opaque the theme-colour sheet over the blurred wallpaper is (0 = wallpaper as it is .. 0.95); yours to set
        greeterBg: "lock",         // lock | wallpaper | solid : the login screen (greetd greeter, greeter/shell.qml) copies the lock screen's background, or forces the blurred wallpaper / the plain theme colour
        greeterAvatar: true,       // your picture (ring + ripples) above the name on the login screen
        greeterClock: true,        // clock and date on the login screen
        greeterSeconds: false,     // seconds in that clock
        greeterPower: true,        // Sleep / Restart / Shut down
        greeterSession: true,      // the session name (Tab changes it)
        greeterBattery: false,     // battery level (system data only)
        greeterWifi: false,        // Wi-Fi name (system data only)
        utilStyle: "tiles",        // tiles | split | classic : the utilities box (bottom-right corner): icon tiles with stars, two tall sliders + round buttons, or the old text pills (Panel.qml)
        utilBtShow: "stars",       // stars | percent : what the Bluetooth tile shows for the connected device
        lockMode: "lock",          // lock | login : after sleep / when locked: the lock screen (widgets allowed) or the login-screen look (no widgets at all)
        loginMode: "keep",         // keep | greeter | lock : what happens at BOOT (Settings > Power & lock > At boot; "Apply" runs scripts/halcyon-greeter.sh apply in a terminal)
        lockWidgets: false,        // OFF by default: the lock screen is just the clock + password. On = battery, Wi-Fi, a notification COUNT and a media card with play / skip buttons
        splashLock: true,          // the splash on the lock screen that is also the login screen (Lock.qml); needs the master `splash` switch
        splashDim: 0.75,           // 0 .. 0.9 : how dark the screen gets while any splash plays (a black veil under the stars; Splash.qml)
        splashStart: true,         // also play the splash once per login session when the lock screen is NOT the login screen (display-manager users); once per session, never on an island restart
        splashUnlock: true,        // the stars rush out again for ~2 s right after you unlock the screen (SplashPreview.qml, mode "unlock"); needs the login splash switch on; not in Gaming mode or with motion off
        splashShutdown: true,      // shut down / restart from the power menu: the stars are drawn back into the centre first (mode "shutdown"), then the machine goes down
        splashAwayMin: 60,         // minutes: the login and unlock splashes only play after you were away (locked, logged out, off) at least this long; 0 = always
        splashSound: false,        // a quiet chime with the splash (scripts/splash-sound.sh); off by default
        todOn: false,              // time-of-day wallpaper: a soft colour grade over the wallpaper that follows the sun (TimeOfDay.js, Wallpaper.qml); Settings > Splash, sky & time of day
        todStrength: 60,           // 0 .. 100 : how strong that grade is (100 = full dusk orange / deep night blue)
        splash: true,              // the login splash (Splash.qml: moving stars + the Halcyon sparkle) plays on the lock screen when it is also the login screen; Settings > Power & lock
        clipAtCursor: true,        // ON by default. Super + V opens the clipboard panel at the mouse pointer (like Windows); off = on the side of the screen
        lockSwitch: false,         // OFF by default. On = the lock screen has a "Switch user" button (other logged-in users, or a login screen for someone else)
        limMode: "manual",         // manual | auto : Settings > Performance > Limits. auto = the RAM / CPU limits are learned from your own use (startup-view.py adapt-sample, every 5 min)
        resMode: "high",           // low | medium | high : the preset picked in Settings > Performance > Resource use (applyResMode below)
        autoLowBat: false,         // true = switch to the Low resource preset when the charger is unplugged, and back when it is plugged in again (batCheck below)
        preBatMode: "",            // the preset to go back to when the charger returns (set by batCheck; empty = nothing to restore)
        focusQuiet: true,          // true = while a Focus work phase runs, the music bars (cava) stop and a video wallpaper (gslapper) is frozen
        perf: "high",              // low | medium | high : how much the tree view and constellations animate (and how many stars the picture gets)
        fps: 0,                    // frame rate of the tree view and constellations: 0 = every frame of the screen, or 60 / 30 / 20 / 15
        scrollLinger: 3000,        // ms a performance / media page opened by scrolling / swiping the bar stays after the pointer leaves (never shorter than pageClose)
        pageClose: 600,            // ms the performance / media page waits after the pointer leaves the bar before it folds back (150 / 600 / 4000)
        cornerTimeout: 6000,       // ms the bottom-right corner pin / quick utilities overlay remains open
        dndFullscreen: true,       // popups stay quiet while a window is fullscreen (Settings > Notifications); Halcyon's own and urgent ones still show
        treeConst: "full",         // full | corner | off : the constellation behind the tree view (corner = small, tucked into treeConstCorner)
        treeConstCorner: "br",     // tl | tr | bl | br
        treeConstSize: 30,         // % of the tree's width / height the small constellation takes
        treeDots: "load",          // load | even | off : floating dots gather around the heaviest workspaces / windows, spread evenly, or none
        lines: "gpu",              // gpu | cpu : who draws the constellation lines and the tree branches (gpu = plain quads + a small shader, no path tessellation)
        frame: false, frameW: 12, frameR: 22, boxOut: "corner",   // a border around the screen: on/off, thickness (px), inner corner radius (px)
        perfLook: "auto",          // auto | sky | orbit | pulse | tiles | sea | forecast | radar | cockpit | recorder | editorial | stars | classic : the look of the Performance tab on every bar (auto: rail = sky, island / notch = classic) (PerfTab.qml; Settings > Bar)
        barStyle: "island",        // island | notch | custom | off : the floating pill, or a bar hanging from the top edge (NotchBar.qml), or no bar (desktop widgets instead)
        notchTime: true, notchAccent: "theme", notchWs: true, notchWsMin: 5, notchSpecials: true, notchSpecialsSide: "auto", notchViz: true, notchDate: false,   // what the notch shows (Settings > Bar style)
        notchWifi: true, notchBtMode: "connected", notchWifiStyle: "bars", notchSpacing: "compact",
        islWs: true, islWsLook: "numbers", islWsMin: 5, islSpecials: true, islViz: true, islTime: true, islWifi: true, islWifiStyle: "symbol", islBtMode: "on", islBat: true, islBatPct: true, islCaffeine: true,   // what the island shows
        notchBat: true, notchBatPct: false, notchCaffeine: true, notchBg: true,
        deskWidgets: null,         // the desktop widgets { items: [...] } (WidgetData.js; Widget builder + Desktop builder)
        deskStyles: [],            // looks you saved in the Widget builder [{ name, look }]
        deskWidgetsOn: true,       // master switch: false = no desktop widgets are drawn and none of their readers run (each widget also has its own Switch off)
        lockDeskWidgets: null,     // the widgets on the LOCK screen { items: [...] }, same format as deskWidgets (Widget builder > Lock screen; placed with the desktop editor; Lock.qml draws them)
        lockDeskWidgetsOn: true,   // false = none of them are drawn on the lock screen
        aiBriefCard: true,         // the daily brief as a notification, once a day, the first time the desktop is used (scripts/halcyon-ai.py brief)
        unusedRemind: true,        // once a month: "N things you barely use" (halcyon-ai.py unused --remind; Startup & processes > Unused)
        aiExplain: true,           // a failed Halcyon service or a new island error gets explained by the local AI (halcyon-ai.py explain ... --if-new)
        deskGrid: true, deskGridSize: 40, deskGridSnap: false, deskCenter: true, deskThirds: false, deskSafe: true, deskMeasure: true,   // the desktop editor's helpers (grid, centre, thirds, safe area, measuring)
        barLayout: null,           // the bar builder's layout { left, center, right } (BarLayout.js); null = the default one
        notchCombo: true, islCombo: true, islSpacing: "compact",   // Wi-Fi + Bluetooth + battery as ONE round icon (StatusRing.qml); off = three separate icons
        bgWhere: "bar",            // corner | bar : where the number of background apps is shown (the box itself always opens bottom-left)
        stars: false,              // constellations in the boxes: off (the default; the Overview keeps its own, treeConst) = none anywhere; the ones below switch single boxes
        starsSettings: true, starsNotifs: true, starsCheatsheet: true, starsCalendar: true, starsPower: true, starsLock: true, starsTerm: true, starsBar: false,   // starsBar = the moving stars (bar, island, bar builder, wallpaper picker); not tied to `stars`
        dialogStarStyle: "none",   // moving | constellations | both | none : dialog star style (none by default: quiet, clean boxes)
        lazyLoad: true,            // unload closed heavy dialog trees when hidden
        boxShadow: true,           // the soft shadow around every Glass box (Settings > Look; Glass.qml)
        consoleMode: "terminal",   // terminal | chat : what the console corner opens (Desktop builder > Console). Old "luna" / consoleLuna settings count as chat: Luna is a provider in the chatbox now
        windowMode: "overlay",     // overlay | desktop : centres float above everything, or open as ordinary windows on the workspace (Host.qml)
        floatAll: false,           // every window floats, no tiling (scripts/floating-mode.sh, hyprland/rules.lua)
        uiStyle: "new",            // new | legacy | classic : the quiet redesign, the first calm look, the original (Settings > Look > Interface; Pal.zen / Pal.calm)
        hideHints: true,           // explanations and key hints shrink to a "?" dot that shows them on hover (Settings > Look; Pal.hideHints, Hint.qml)
        recKind: "screen",         // screen | audio : what the recorder (Super + Alt + R) records: the screen, or sound only (Settings > Screen & audio recording)
        recAudio: "system",        // none | system | mic | both : the sound that goes with it (system = what you hear, mic = the default microphone)
        limRam: 600,               // manual RAM limit (MB) for background helper warnings
        limCpu: 10                 // manual CPU limit (%) for background helper warnings
    })
    // Moving stars in the boxes (Settings, cheat sheet, calendar, power menu, console, tree view, lock screen) follow Resource use:
    // Low a few and slow, Medium some, High a little more. Not many on purpose, just enough to feel alive. They are on while
    // "Dialog stars effect" is Moving stars or Both, and they are separate from the constellations (which Low switches off).
    readonly property bool boxStarsOn: opt.dialogStarStyle === undefined || opt.dialogStarStyle === "moving" || opt.dialogStarStyle === "both"
    readonly property int boxStarCount: !boxStarsOn ? 0 : (opt.resMode === "low" ? 4 : opt.resMode === "medium" ? 7 : 10)
    readonly property int boxStarLoop: opt.resMode === "low" ? 220000 : opt.resMode === "medium" ? 170000 : 140000
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
        disableTyping: ["input", "touchpad", "disable_while_typing"], focusOnActivate: ["misc", "focus_on_activate"],
        resizeAnim: ["misc", "animate_manual_resizes"]
    })
    function setOpt(k, v) {
        var o = {}
        for (var x in opt) o[x] = opt[x]
        o[k] = v
        opt = o
        switch (k) {
        case "barStyle":
            if (v === "rail") {
                var bl = opt.barLayout ? JSON.parse(JSON.stringify(opt.barLayout)) : BL.defaults("rail")
                bl.shape = "rail"
                bl.caps = true
                if (!bl.side || bl.side === "top") bl.side = "left"
                if (!bl.left || bl.left.length === 0) bl.left = ["logo", "workspaces", "specials"]
                else if (bl.left.indexOf("logo") < 0) bl.left.unshift("logo")
                if (!bl.right || bl.right.length === 0) bl.right = ["status", "power"]
                else if (bl.right.indexOf("power") < 0) bl.right.push("power")
                root.setOpt("barLayout", bl)
            }
            break
        case "wpSource": writeFlag("wallpaper-source", v); break    // scripts/wallpaper.sh reads these two on every change
        case "wpCat": writeFlag("wallpaper-cat", v); break
        case "wpBootNew": writeFlag("wallpaper-boot-new", v ? "1" : "0"); break
        case "wpQuery": writeFlag("wallpaper-query", String(v || "").replace(/[\r\n]+/g, " ").trim()); break
        case "floatAll": Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/floating-mode.sh", v ? "on" : "off"]); break
        case "tilingLayout":
            if (v === "off") {
                root.setOpt("floatAll", true)
            } else {
                if (root.opt.floatAll) root.setOpt("floatAll", false)
                Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_layout.sh", v])
                hyReadAgain.restart()
            }
            break
        case "wsEnd": writeFlag("ws-end", v); break
        case "wsStart": writeFlag("ws-start", v); break
        case "wsMax": writeFlag("ws-max", v); break
        case "wsInvert": writeFlag("ws-invert", v ? "1" : "0"); break
        case "recKind": writeFlag("rec-kind", v); break           // scripts/screen-record.sh reads these two on every start
        case "recAudio": writeFlag("rec-audio", v); break
        case "wsSwipe4": writeFlag("ws-swipe4", v); break
        case "connErrOnly": writeFlag("conn-errors-only", v ? "1" : "0"); break
        case "bgRefresh": syncRefresh(); break
        case "viz": vizHold = true; vizHoldT.restart(); break
        case "termMode": writeFlag("term-mode", v); termRun.restart(); break
        case "termDrift": termRun.restart(); break
        case "accentMode": termRun.restart(); break
        case "nightTemp": nightT.restart(); break
        case "resMode": applyResMode(v); break
        case "accentBorder": hyprKick.restart(); break
        }
        saveSettings()
    }

    // ---- adaptive limits (Settings > Performance & memory > Limits: Adaptive) ----------------------------------------------
    // One short reading of how much RAM / CPU Halcyon uses every 5 minutes; startup-view.py keeps them (14 days) and works the
    // limits out from them. Only while the island runs and Adaptive is chosen; not in Gaming mode (the helpers are stopped then).
    Timer {
        interval: 300000; repeat: true
        running: root.settingsLoaded && root.opt.limMode === "auto" && !root.gaming
        onTriggered: Quickshell.execDetached([Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "adapt-sample"])
    }

    // ---- background refresh (Settings > Performance & memory > Background refresh) ----------------------------------------
    // The always-on readers (scripts/stats.sh: CPU / battery / sysmode, scripts/net.sh: Wi-Fi / Bluetooth state) look again every
    // 2 s / 4 s. "Relaxed" and "Slow" stretch that to 2.5x / 5x while nothing needs fresh numbers. Two flag files in
    // ~/.local/state/island tell them: bg-refresh (normal | relaxed | slow | auto) and stats-fast (1 while the performance page or the
    // bar's CPU / RAM / TEMP hover row can be on screen: stats.sh then keeps its normal pace). The scripts wait on a pipe in
    // $XDG_RUNTIME_DIR and writing the flags pokes that pipe, so a change shows within a second instead of after a slow wait.
    readonly property bool perfShown: page === "perf" || railPages.which === "perf"      // the performance page: on the island, or beside a rail
    readonly property bool statsFast: perfShown || hoverAction === "stats"
    onStatsFastChanged: syncRefresh()
    function syncRefresh() {
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/bg-refresh\" && printf '%s\\n' \"$3\" > \"$1/stats-fast\"; " +
            "for w in stats net; do f=\"${XDG_RUNTIME_DIR:-/tmp}/halcyon-$w.wake\"; [ -p \"$f\" ] && printf '\\n' 1<>\"$f\"; done; exit 0",
            "sh", stateDir, opt.bgRefresh || "normal", statsFast ? "1" : "0"])
    }
    // the Wi-Fi / Bluetooth switches show the new state at once; this makes net.sh confirm it a moment later
    Timer { id: netPokeT; interval: 1500; onTriggered: Quickshell.execDetached(["sh", "-c", "f=\"${XDG_RUNTIME_DIR:-/tmp}/halcyon-net.wake\"; [ -p \"$f\" ] && printf '\\n' 1<>\"$f\"; exit 0"]) }
    // music bars: changing the choice stops cava for a moment so it starts again with the new settings
    property bool vizHold: false
    Timer { id: vizHoldT; interval: 250; onTriggered: root.vizHold = false }

    // Settings > Performance > Resource use: three presets that set many options at once. The options stay changeable afterwards.
    // (Startup items and the GPU are NOT part of it: they only change at the next login, see Settings > Startup & background.)
    readonly property var resPresets: ({
        low:    { opt: { perf: "low",    fps: 30, lines: "gpu", stars: false, starsBar: false, dialogStarStyle: "moving", accentMode: "fixed", termDrift: false, clockSeconds: false, viz: "light", lazyLoad: true },
                  blur: false, shadows: false, hyprAnim: false, motion: 0.5, profileStars: false, notifHistoryMax: 10, notifMax: 3,
                  hy: { blurSize: 4, blurPasses: 1, resizeAnim: false } },
        medium: { opt: { perf: "medium", fps: 60, lines: "gpu", viz: "full", lazyLoad: true },        // the stars are your choice (Settings > Stars), not the preset's
                  blur: true,  shadows: false, hyprAnim: true,  motion: 1,   profileStars: true,  notifHistoryMax: 20, notifMax: 5,
                  hy: { blurSize: 5, blurPasses: 2, resizeAnim: true } },
        high:   { opt: { perf: "high",   fps: 0,  lines: "gpu", viz: "full", lazyLoad: false },
                  blur: true,  shadows: true,  hyprAnim: true,  motion: 1,   profileStars: true,  notifHistoryMax: 30, notifMax: 5,
                  hy: { blurSize: 7, blurPasses: 3, resizeAnim: true } }
    })
    function applyResMode(m) {
        var p = resPresets[m]
        if (!p) return
        var o = {}
        for (var x in opt) o[x] = opt[x]
        for (var y in p.opt) o[y] = p.opt[y]
        o.resMode = m
        opt = o
        syncRefresh()
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
    // Settings > Performance > Resource use > "Low preset on battery" (off by default): unplugging the charger switches to Low, plugging
    // it in puts the preset you had back, but only if you did not pick another one in between. preBatMode is saved, so a restart
    // while on battery still knows where to return to.
    readonly property bool onBattery: stats.hasBat === true && stats.ac !== true && stats.charging !== true
    function batCheck() {
        if (!opt.autoLowBat || !statsSeen) return
        if (onBattery) {
            if (opt.resMode !== "low") { var prev = opt.resMode; applyResMode("low"); setOpt("preBatMode", prev) }
        } else if (opt.preBatMode) {
            var back = opt.preBatMode
            if (opt.resMode === "low") applyResMode(back)
            setOpt("preBatMode", "")
        }
    }
    onOnBatteryChanged: batCheck()
    onStatsSeenChanged: batCheck()
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
        writeFlag("float-all", opt.floatAll ? "1" : "0")
        writeFlag("rec-kind", opt.recKind || "screen"); writeFlag("rec-audio", opt.recAudio || "system")
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
        running: root.settingsLoaded && root.opt.wpEvery > 0 && !root.gaming && root.opt.deskLive !== "on" && root.opt.deskLive !== "sky"
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
    readonly property string hgl: Quickshell.env("HOME") + "/.config/Halcyon/bin/hgl"
    readonly property string cfg: Quickshell.env("HOME") + "/.config/Halcyon/quickshell"
    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/island"

    // ---------- state ----------
    // media | home | perf | launcher
    property string page: "home"
    // ai-firewall installed? (install.sh --firewall ai) Its launcher commands are only listed then; checked once at start
    property bool fwInstalled: false
    Process { running: true; command: ["sh", "-c", "command -v ai-firewall >/dev/null"]; onExited: code => root.fwInstalled = code === 0 }
    property bool avInstalled: false
    Process { running: true; command: ["sh", "-c", "command -v ai-antivirus >/dev/null"]; onExited: code => root.avInstalled = code === 0 }

    // ---- Settings > Bar style > Drag the bar down: the utilities box (and the notifications) hang from the bar as two more pages, "util" and "notif"
    readonly property string dropMode: (opt.dropDown === "stack" || opt.dropDown === "side") ? opt.dropDown : "off"
    readonly property bool dropOn: dropMode !== "off"
    readonly property bool dropSide: dropMode === "side"
    readonly property bool dropStack: dropMode === "stack"      // "Swipe pages": utilities <-> notifications, with a header, arrows and swipe
    readonly property int dropHdrH: dropStack ? 44 : 0
    readonly property int dropHdr: dropStack ? dropHdrH + 12 : 0
    readonly property int dropPad: 14
    readonly property int dropHandleH: 18
    readonly property real dropW: (dropSide ? pal.boxW * 2 + dropPad : pal.boxW) + dropPad * 2
    readonly property real dropH: Math.min(540, Math.max(barPanel.implicitHeight, dropSide ? barNotifs.implicitHeight : 0)) + dropPad * 2 + dropHandleH + dropHdr
    readonly property real dropNotifW: pal.boxW + dropPad * 2
    readonly property real dropNotifH: Math.min(540, barNotifs.implicitHeight) + dropPad * 2 + dropHandleH + dropHdr
    // drag the bar down (+1) / up (-1): bar <-> the drop-down. The two pages (utilities / notifications) are side by side, see dropGo.
    function drop(dir) {
        if (!dropOn) return
        hoverOpened = false
        island.hoverSpent = true
        if (dir > 0) { if (page === "home") page = "util" }
        else if (page === "util" || page === "notif") page = "home"
    }
    // Swipe pages: the next page to the right (+1: notifications) or to the left (-1: utilities). Arrows, tabs, swipe and Left / Right all land here.
    function dropGo(dir) {
        if (!dropStack) return
        if (dir > 0 && page === "util") page = "notif"
        else if (dir < 0 && page === "notif") page = "util"
    }
    function dropStep() {                      // a tap on the handle: back up into the bar
        if (page === "util" || page === "notif") page = "home"
    }
    // keybind / IPC: open (or close) the utilities box / the notifications from the bar. false = the drop-down is off (the old boxes do it).
    function dropShow(which) {
        if (!dropOn) return false
        var target = (which === "notif" && dropSide) ? "util" : which
        hoverOpened = false
        island.hoverSpent = true
        page = (page === target) ? "home" : target
        return true
    }
    // with the drop-down on, the corner utilities box and the right-edge notification box are switched off (the drop-down replaces them)
    onDropOnChanged: {
        if (!dropOn && (page === "util" || page === "notif")) page = "home"
        if (dropOn) { corner.hovering = false; notifs.centerOpen = false }
    }
    // looking at the notifications here counts as reading them (and the popups get out of the way)
    function markSeen() { if (page === "notif" || (page === "util" && dropSide)) { notifs.unread = 0; notifs.hideToasts() } }
    onPageChanged: {
        markSeen(); if (page === "home") scrollOpened = false
        // the launcher's grow / shrink speed (Settings > Mouse, touchpad & keyboard > Launcher speed) applies to the way in AND the way out
        leavingLauncher = (lastPage === "launcher" && page !== "launcher")
        lastPage = page
        if (leavingLauncher) leaveT.restart()
    }
    property string lastPage: "home"
    property bool leavingLauncher: false
    Timer { id: leaveT; interval: 700; onTriggered: root.leavingLauncher = false }
    // normal = the same soft 520 ms as every other page; quick = about half; instant = a short snap. Tap-to-open waits for the key to
    // come UP (a bare Super cannot be told apart from the start of Super+T until then), so the grow animation is the part we can shorten.
    readonly property real launchK: ({ normal: 1.0, quick: 0.5, instant: 0.2 })[opt.launchSpeed || "quick"] || 0.5
    readonly property bool launcherMotion: page === "launcher" || leavingLauncher
    function pageMs(base) { return launcherMotion ? Math.max(40, Math.round(base * launchK)) : base }
    Connections { target: notifs; function onUnreadChanged() { if (notifs.unread > 0) root.markSeen() } }

    property var stats: ({ cpu: 0, mem: 0, memGb: "0.0", temp: 0, down: 0, up: 0, bat: 0, charging: false, ac: false, hasBat: false,
                               sysmode: "", auto: false, pmode: "", pprofile: "" })
    property var net: ({ wifi: "off", ssid: "", eth: false, bt: "off", btdev: "", btn: 0 })
    property string profile: "balanced"
    property var cava: []
    property string activeSpecial: ""
    property real vol: 0
    property bool muted: false
    property real bright: 0
    property real mic: 0
    property bool micMuted: false
    property bool gaming: false
    // ---- game launcher (hgl): `hgl run` tells the island through IPC (gamestart / gameend); the pill and the lean mode follow it
    property string gameId: ""          // the running game ("" = none)
    property string gameName: ""
    property double gameSince: 0        // unix seconds
    property bool lean: false           // lean island: the feeds, desktop widgets and animations rest while a game runs (setLean)
    property double leanAt: 0           // when lean last changed: a feed that exits right after being paused is not a broken feed
    property bool caffeine: false       // keep the screen awake (scripts/caffeine.sh); the unit is the truth, polled every 5 s
    property double caffeineGuard: 0
    property bool numLock: false        // Num Lock (scripts/numlock.sh); only watched while the Num Lock widget is on the custom bar
    property double numLockGuard: 0

    // app routing: Spotify / Discord ... go to their special workspace when they open (Routes.js)
    property bool routeApps: true
    property bool routeShow: false      // pop the special workspace into view when a routed app opens (off = move the window quietly)
    property var routed: ({})           // window addresses already handled, so a window you move yourself is left alone
    property bool routeSeeded: false    // the first pass only notes what is already open
    readonly property double startedAt: Date.now()

    // persisted in ~/.local/state/island/settings.json
    property bool autoHide: false
    property bool autoPower: false
    property bool dnd: false            // do not disturb: no popups, everything is still stored
    property string edgeMode: "hover"   // hover | click: how the edge boxes (notifications, console, utilities) open and close
    readonly property bool clickMode: edgeMode === "click"
    // each corner box may have its own hover / click (Desktop builder > Opens on); the rest follow clickMode
    readonly property bool notifClick: DS.trig(opt, "notif", clickMode)
    readonly property bool utilClick: DS.trig(opt, "util", clickMode)
    readonly property bool appsClick: DS.trig(opt, "apps", clickMode)
    readonly property bool termClick: DS.trig(opt, "term", clickMode)
    // Desktop builder > Console shows: the corner opens the AI chatbox (Luna, Ollama and the API providers live in its dropdown) instead of the terminal
    readonly property bool chatOnly: opt.consoleMode === "chat" || opt.consoleMode === "luna" || opt.consoleLuna === true
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
    property bool accentApplied: false  // the focused-window border currently has the accent colour (so "off" must put the neutral one back)
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
    // the profile picture as a constellation (secure / relaxed backdrops everywhere); redone when the picture changes
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
    // the tree view (and its thousands of constellation lines) is gone once it closes, but the JS heap that held them is only
    // freed by a collection: do one a moment after it closes, so the island goes back to its small size
    onOverviewOpenChanged: if (!overviewOpen) overviewGc.restart()
    Timer { id: overviewGc; interval: 2500; onTriggered: gc() }

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
        surfaceStyle: root.opt.surface || "tint"
        uiStyle: root.opt.uiStyle === "legacy" || root.opt.uiStyle === "classic" ? root.opt.uiStyle : "new"
        deskWin: root.opt.windowMode === "desktop"
        boxShadow: root.opt.boxShadow !== false
        glassShift: root.glassShift
        motion: root.lean ? 0 : (root.gaming ? 0.25 : root.motion)
        growth: root.growth
        growthOn: root.growthOn
        // Gaming mode: tree view and constellations drop to the lightest settings whatever Settings > Performance says
        artQuality: root.gaming ? 0 : root.perfLevel
        artFps: root.gaming ? 15 : (root.opt.fps || 0)
        lowPower: root.stats.hasBat === true && root.stats.ac !== true
        gpuLines: root.opt.lines !== "cpu"
        treeConst: root.opt.treeConst || "full"
        treeConstCorner: root.opt.treeConstCorner || "br"
        treeConstSize: (root.opt.treeConstSize || 30) / 100
        treeDots: root.opt.treeDots || "load"
        branchShader: root.branchShaderUrl
        skyShader: root.skyShaderUrl
        accentMode: root.opt.accentMode
        cycleSecs: root.opt.cycleSecs
        termDrift: root.opt.termDrift
        cyclePaused: root.gaming
        hideHints: root.opt.hideHints !== false
        frameOn: root.frameOn
        frameT: root.frameT
        cornerOut: root.cornerOut
        insL: root.insL; insT: root.insT; insR: root.insR; insB: root.insB
    }
    readonly property var palObj: pal

    // rice settings window (gear in the utilities panel, >settings, SUPER+I) and the power menu (power button)
    Settings {
        id: settingsWin
        pal: pal
        wallpaperPath: wallpaperLayer.lastPath
        env: root
        onEditOnDesktop: t => { root.deskEditTarget = (t === "lock") ? "lock" : "desktop"; root.deskEditing = true }
        sysmode: root.sysmode
        autoHide: root.autoHide
        clickMode: root.clickMode
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
        dnd: root.dnd
        gaming: root.gaming
        profileStars: root.profileStars
        starData: root.starData
        onFocusOptionsChanged: focusConfProc.running = true
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
        routeShow: root.routeShow
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
        avAiOn: root.avAiOn
        onSetting: (k, v) => root.setSetting(k, v)
        onWallpaperSet: path => root.setWallpaper(path)
        onAction: id => {
            if (id === "wallpaper") root.randomWallpaper()
            else if (id === "wallpaper-back") wallpaperLayer.back()
            else if (id === "wallpaper-keep") wallpaperLayer.keep()
            else if (id === "config") root.editConfig()
            else if (id === "cheatsheet") root.runCommand("cheatsheet")
            else if (id === "reload") fullReloadProc.running = true
            else if (id === "hypr-reload") bindsReload.restart()        // Settings > Touchpad gestures / Mouse buttons: Hyprland reads the new choices (batched like the shortcuts)
            else if (id === "nightlight") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_nightlight.sh"])
            else if (id === "touchpad") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_touchpad.sh"])
            else if (id === "gestures") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_gestures.sh"])
            else if (id === "wifi-powersave") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_wifi_powersave.sh"])
            else if (id === "termcolors") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/term-colors.sh", "--now"])
            else if (id === "layout") { Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_layout.sh"]); hyReadAgain.restart() }
            else if (id === "reset-look") root.resetLook()
            else if (id === "startup-view") settingsWin.openStartup()
            else if (id === "splash-preview") splashPreview.play()
            else if (id === "login-apply") { var gs = Quickshell.env("HOME") + "/.config/Halcyon/scripts"; Quickshell.execDetached(["bash", gs + "/apps.sh", "term-exec", "bash", "-c", "bash \"$1/halcyon-greeter.sh\" apply; echo; read -n1 -r -p 'Press any key to close '", "x", gs]) }
            else if (id === "greeter-preview") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-greeter.sh", "preview"])
            else if (id === "splash-unlock-preview") splashPreview.playMode("unlock")
            else if (id === "splash-shutdown-preview") splashPreview.playMode("shutdown")
            else if (id === "plymouth-install" || id === "plymouth-remove") { var pm = Quickshell.env("HOME") + "/.config/Halcyon/scripts"; Quickshell.execDetached(["bash", pm + "/apps.sh", "term-exec", "bash", "-c", "bash \"$1/halcyon-plymouth.sh\" $2; echo; read -n1 -r -p 'Press any key to close '", "x", pm, id === "plymouth-install" ? "install" : "remove"]) }
            else if (id === "sky-open") weeklySky.show()
            else if (id === "splash-sound-preview") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/splash-sound.sh", "login"])
            else if (id === "tour-replay") { settingsWin.hide(); root.tourReplay() }
            else if (id === "greeting-paste") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/greeting-conf.sh", "paste"])
            else if (id === "greeting-edit") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/greeting-conf.sh", "edit"])
            else if (id === "greeting-preview") quickTerm.run("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/greeting-conf.sh preview")
            else if (id === "rec-open") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/screen-record.sh", "open"])
            else if (id === "rec-last") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/screen-record.sh", "last"])
            else if (id === "rec-toggle") root.toggleRecording()
            else if (id === "mem-report") quickTerm.run("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-mem.sh")
            else if (id === "restore-device" || id === "restore-home") { var rh = Quickshell.env("HOME") + "/.config/Halcyon/scripts"; Quickshell.execDetached(["bash", rh + "/apps.sh", "term-exec", "bash", "-c", "bash \"$1\" $2; echo; read -n1 -r -p 'Press any key to close '", "x", rh + "/restore-device.sh", id === "restore-home" ? "--home" : ""]) }
            else if (id === "backup-device" || id === "backup-home") { var bh = Quickshell.env("HOME") + "/.config/Halcyon/scripts"; Quickshell.execDetached(["bash", bh + "/apps.sh", "term-exec", "bash", "-c", "bash \"$1\" $2; echo; read -n1 -r -p 'Press any key to close '", "x", bh + "/backup-device.sh", id === "backup-home" ? "--home" : ""]) }
            else if (id === "safety-check") { var sc = Quickshell.env("HOME") + "/.config/Halcyon/scripts"; Quickshell.execDetached(["bash", sc + "/apps.sh", "term-exec", "bash", "-c", "if [ -x /usr/local/bin/safety-check ]; then sudo /usr/local/bin/safety-check && bash \"$1/remind.sh\" done safety; else echo 'The safety check is not installed: ./install.sh --safety-check'; fi; echo; read -n1 -r -p 'Press any key to close '", "x", sc]) }
            else if (id === "security-firewall" || id === "security-antivirus" || id === "security-exceptions") { settingsWin.hide(); securityCenter.show(id.substring(9)) }
            else if (id.indexOf("antivirus-select:") === 0) {          // Settings > Security > Antivirus: ai | clamav | off, with sudo in the console
                var avm = id.substring(17)
                if (avm === "ai" || avm === "clamav" || avm === "off") { settingsWin.hide(); quickTerm.run("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/antivirus-select.sh " + avm) }
            }
            else if (id === "fw-center") { settingsWin.hide(); root.runCommand("firewall") }            // Settings > Security > ai-firewall: these five had no handler, so the buttons did nothing
            else if (id === "fw-page") { settingsWin.hide(); root.runCommand("firewall-page") }
            else if (id === "fw-top") root.runCommand("firewall-dashboard")
            else if (id === "fw-doctor") { settingsWin.hide(); quickTerm.run("sudo ai-firewall doctor --fix") }
            else if (id === "fw-config") { settingsWin.hide(); quickTerm.run("sudo -e /etc/ai-firewall/config.toml") }
            else if (id.indexOf("antivirus-ai:") === 0) {                // Settings > Security > AI review of alerts: on | off, with sudo in the console
                var avi = id.substring(13)
                if (avi === "on" || avi === "off") { settingsWin.hide(); quickTerm.run("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/antivirus-ai.sh " + avi) }
            }
            else if (id === "fx-safe-on") root.fxRun(["safe-mode", "on"])
            else if (id === "fx-safe-off") root.fxRun(["safe-mode", "back"])
            else if (id === "adapt-reset") Quickshell.execDetached([Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "adapt-reset"])
            else if (id === "netlearn-reset") Quickshell.execDetached(["rm", "-f", Quickshell.env("HOME") + "/.local/state/island/adaptive-net.tsv"])
            else if (id === "detect-ram") { Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/refresh-ram.sh", "--gui"]); specsAgain.restart() }
            else if (id === "opt-sweet-spot") {
                root.applyResMode("medium")
                root.setHy("blurPasses", 2)
                root.setHy("blurSize", 5)
                root.setSetting("opt:starsBar", false)
                root.setSetting("opt:fps", 60)
                root.setSetting("opt:lazyLoad", true)
                trimGc.restart()
            }
            else if (id === "opt-trim-mem") {
                gc()
                trimGc.restart()
            }
            else if (id === "opt-adaptive-advisor") quickTerm.run("python3 " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/adaptive-advisor.py")
            else if (id === "opt-llm-advisor") quickTerm.run("python3 " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/adaptive-advisor.py --llm")
            else if (id === "login-status") quickTerm.run("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/login-status.sh status")
            else if (id === "login-enable-lock") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/login-status.sh", "enable-lock"])
            else if (id === "login-remove-lock") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/login-status.sh", "remove-lock"])
        }
    }
    // the shortcut tree: every bind, gesture and command; click one to change it, add your own at the bottom
    Cheatsheet {
        id: cheat
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
        hasSysmode: cmdTree.available
        keyMap: root.keyMap
        customs: root.customBinds
        style: root.opt.keysStyle === "pages" ? "pages" : "tree"
        onStyleChosen: m => root.setOpt("keysStyle", m)
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
                    if (corner.open || root.page === "util") return          // the panel's own sliders are on screen already
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
                if (root.volPrimed && changed && !(corner.open || root.page === "util")) osd.show("vol", v, mu)
                root.lastVol = v; root.lastMuted = mu; root.volPrimed = true
            }
        }
    }
    Component.onCompleted: { volRead.running = true; startTapWatch(); fxPause.running = true }     // fxPause: a crash during Focus must not leave the video wallpaper frozen

    // our own lock screen (replaces hyprlock): SUPER+L, power menu > Lock, `>lock`, scripts/lock.sh
    // ---- the login screen (greetd greeter, greeter/shell.qml) is the lock screen's twin. Everything it needs to look exactly the same
    // (palette, fonts, sizes, the picture constellation, flying stars, sysmode art, the lock screen's background settings) is written
    // to ~/.cache/island/greeter-look.json a moment after anything changes; scripts/halcyon-greeter.sh sync copies it to the greeter.
    function lookJson() {
        var c = function (x) { return String(x) }
        return JSON.stringify({
            v: 1, zen: pal.zen, calm: pal.calm, solid: pal.solid, light: pal.light, uiFont: pal.uiFont,
            tCap: pal.tCap, tBody: pal.tBody, tTitle: pal.tTitle, tDisplay: pal.tDisplay,
            bg: c(pal.bg), surface: c(pal.surface), accent: c(pal.accent), accent2: c(pal.accent2), text: c(pal.text), muted: c(pal.muted), bad: c(pal.bad),
            boxFill: c(pal.box(Qt.alpha(pal.surface, 0.85))), line: c(pal.line), lineFocus: c(pal.lineFocus),
            motion: pal.motion, decor: pal.decor, starSlow: pal.starSlow, growthOn: pal.growthOn, growth: pal.growth,
            artQuality: pal.artQuality, artFps: pal.artFps, gpuLines: pal.gpuLines,
            stars: lockScreen.stars, ringFill: c(pal.box(Qt.alpha(pal.surface, 0.9))),
            flyCount: root.boxStarCount, flyLoop: root.boxStarLoop,
            sysmode: root.sysmode, profileStars: root.profileStars, starData: root.starData,
            name: lockScreen.name, user: Quickshell.env("USER"), avatar: root.avatarPath,
            bgMode: lockScreen.bgMode, blur: lockScreen.blurRadius, tint: lockScreen.tint
        })
    }
    Process {
        id: lookProc
        stdinEnabled: true
        command: ["sh", "-c", "d=\"$HOME/.cache/island\"; mkdir -p \"$d\"; head -n 1 > \"$d/greeter-look.json.tmp\" && mv -f \"$d/greeter-look.json.tmp\" \"$d/greeter-look.json\""]
    }
    Timer {
        id: lookT
        interval: 3000
        onTriggered: { if (!root.settingsLoaded || lookProc.running) return; lookProc.running = true; lookProc.write(root.lookJson() + "\n") }
    }
    // (in a Connections block: shell.qml already has its own onProfileNameChanged / onSettingsLoadedChanged further up, and a second
    // handler of the same name on the same object stops the whole island from loading: "Property value set multiple times")
    Connections {
        target: root
        function onOptChanged() { lookT.restart() }
        function onStarDataChanged() { lookT.restart() }
        function onSysmodeChanged() { lookT.restart() }
        function onProfileNameChanged() { lookT.restart() }
        function onAvatarPathChanged() { lookT.restart() }
        function onSettingsLoadedChanged() { if (root.settingsLoaded) lookT.restart() }
    }
    Connections { target: pal; function onAccentChanged() { lookT.restart() } function onBgChanged() { lookT.restart() } function onUiFontChanged() { lookT.restart() } }

    Lock {
        id: lockScreen
        pal: pal
        // one switch for the lock screen AND the login screen (Settings > Lock screen, or the Lock screen builder): not tied to the
        // "Constellations in the boxes" master switch, so turning it on here always shows them on both screens
        stars: root.opt.starsLock !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        name: root.profileName !== "" ? root.profileName : Quickshell.env("USER")
        avatarPath: root.avatarPath
        bgMode: root.opt.lockBg === "wallpaper" || root.opt.lockBg === "sky" ? root.opt.lockBg : "solid"
        wallpaper: wallpaperLayer.currentPath
        blurRadius: root.opt.lockBlur !== undefined ? root.opt.lockBlur : 40
        tint: root.opt.lockTint !== undefined ? root.opt.lockTint : 0.55
        plain: root.opt.lockMode === "login"          // Settings > Power & lock > After sleep: the login-screen look, no widgets of any kind
        widgets: root.opt.lockWidgets === true && root.opt.lockMode !== "login"
        allowSwitch: root.opt.lockSwitch === true && root.opt.lockMode !== "login"
        splash: root.opt.splash !== false && root.opt.splashLock !== false
        splashSound: root.opt.splashSound === true
        splashDim: root.opt.splashDim !== undefined ? root.opt.splashDim : 0.75
        player: root.player
        hasBat: root.stats.hasBat === true
        batPct: Math.round(root.stats.bat || 0)
        batCharging: root.stats.charging === true
        ssid: root.net.ssid || ""
        notifCount: notifs.history.length
        deskOpt: root.opt
        deskEnv: lockEnv
        deskLum: root.lockBackLum
    }
    // Login-screen mode (install.sh > "lock screen as login"): launch/halcyon-login.sh leaves a flag file before it starts
    // Hyprland, and the first thing the island does is take it and lock. So after boot the Halcyon lock screen IS the login
    // screen (your password is checked by PAM exactly like a normal login). No flag file = nothing happens.
    // The flag is only READ here. It is removed further down, once the session lock really is up (lockScreen.locked):
    // login-watchdog.sh keeps waiting for the flag to disappear, so if the lock never engages it still ends the session
    // instead of leaving an auto-logged-in desktop open.
    // Started from the tty1 login (launch/halcyon-login.sh exports HALCYON_LOGIN_LOCK=1; read at once, no file read): the desktop
    // (wallpaper, bar, corner boxes) stays hidden until the lock screen is really up, so it never shows for a frame between the boot
    // splash and the lock. Released when the flag turns out not to be there (an island restart later in the session), 700 ms after
    // the lock engaged, or after 8 s whatever happens.
    property bool startHold: Quickshell.env("HALCYON_LOGIN_LOCK") === "1"
    Timer { id: startHoldT; interval: 700; onTriggered: root.startHold = false }
    Timer { interval: 8000; running: root.startHold; onTriggered: root.startHold = false }
    Connections { target: lockScreen; enabled: root.startHold; function onLockedChanged() { if (lockScreen.locked) startHoldT.restart() } }
    Process {
        running: true
        command: ["sh", "-c", "[ -f \"$HOME/.cache/island/lock-on-start\" ] && echo yes $(( $(date +%s) - $(cat \"$HOME/.local/state/island/last-seen\" 2>/dev/null || echo 0) ))"]
        stdout: StdioCollector { onStreamFinished: {
            var w = text.trim().split(" ")
            if (w[0] !== "yes") { root.startHold = false; return }
            // armed either way (it marks the login lock); the splash itself is skipped when you were away less than splashAwayMin
            lockScreen.splashSkip = !root.awayLongEnough(Number(w[1]) * 1000)
            lockScreen.splashArm = true; lockScreen.lock(); splashMark.running = true
        } }
    }
    // the splash on its own (Settings > Power & lock > Play the splash, `halcyon splash`, `>splash`); the real one is inside the lock screen
    SplashPreview {
        id: splashPreview
        pal: pal
        sound: root.opt.splashSound === true
        dim: root.opt.splashDim !== undefined ? root.opt.splashDim : 0.75
        // a preview (Settings > Play the goodbye) has nothing pending: just give the screen back; a real shutdown / restart goes on now
        onDone: {
            if (root.powerPending === "") { splashPreview.stop(); return }
            var left = splashPreview.soundEndsAt - Date.now()          // let the goodbye sound finish first (at most ~1.5 s more)
            if (left > 50) { soundWaitT.interval = Math.min(2000, left); soundWaitT.restart() } else root.powerNow()
        }
    }
    Timer { id: soundWaitT; onTriggered: root.powerNow() }
    // the weekly sky: your week as stars (WeeklySky.qml; `>weekly sky`, `halcyon weekly-sky`, Settings > Splash, sky & time of day)
    WeeklySky { id: weeklySky; pal: pal }
    // the Wi-Fi QR code (WifiQr.qml; scripts/halcyon-tools.py wifi-qr)
    WifiQr { id: wifiQr; pal: pal }
    // the Focus streak view (FocusStreak.qml; `>focus streak graph`, `halcyon focus-graph`, a click on the Focus streak graph widget)
    FocusStreak { id: focusStreak; pal: pal; env: root }
    // a signature moment is allowed when the splash is on, motion is on and we are not gaming (same rule as the login splash)
    function splashAllowed(key) { return settingsLoaded && opt.splash !== false && opt[key] !== false && !gaming && pal.motion > 0.3 }
    // shut down / restart: draw the stars in first, then go. `powerFail` is the safety net: whatever happens to the animation
    // the machine still does what you asked within ~5 s.
    property string powerPending: ""
    function goodbye(action) {
        if (powerPending !== "") return                      // already on its way
        powerPending = action
        if (splashAllowed("splashShutdown")) {
            powerFail.restart(); splashPreview.playMode("shutdown")
            // tells the Plymouth power-off screen (halcyon-plymouth.sh) that the goodbye was just played: it stays dark, no second film
            Quickshell.execDetached(["sh", "-c", ": > /dev/shm/halcyon-goodbye"])
        } else powerNow()
    }
    function powerNow() {
        var a = powerPending
        powerPending = ""
        powerFail.stop()
        if (a === "shutdown") Quickshell.execDetached(["systemctl", "poweroff"])
        else if (a === "reboot") Quickshell.execDetached(["systemctl", "reboot"])
    }
    Timer { id: powerFail; interval: 5000; onTriggered: root.powerNow() }
    // the screen was just unlocked (and the lock was not the login lock, which already played the splash): the stars rush out again
    property bool lockWasLogin: false
    // Once per login session, for people who log in through a display manager (no lock-screen login, so Lock.qml never plays it):
    // wait until the settings are read, skip it when the lock screen is up or about to be (that one plays the splash itself), in Gaming
    // mode, or when motion is off. A marker in $XDG_RUNTIME_DIR (gone at logout / reboot) keeps an island restart from playing it again.
    property bool splashStartDone: false
    Timer {
        interval: 1200; repeat: true; running: !root.splashStartDone
        onTriggered: {
            if (!root.settingsLoaded) return
            root.splashStartDone = true
            if (root.opt.splash === false || root.opt.splashStart === false) return
            if (lockScreen.locked || lockScreen.splashArm || root.gaming || pal.motion <= 0.3) return
            splashCheck.running = true
        }
    }
    Process {
        id: splashCheck
        command: ["sh", "-c", "f=\"${XDG_RUNTIME_DIR:-/tmp}/halcyon-splash-done-$(id -u)\"; [ -e \"$f\" ] && exit 0; : > \"$f\" && echo yes $(( $(date +%s) - $(cat \"$HOME/.local/state/island/last-seen\" 2>/dev/null || echo 0) ))"]
        stdout: StdioCollector { onStreamFinished: {
            var w = text.trim().split(" ")
            if (w[0] === "yes" && !lockScreen.locked && root.awayLongEnough(Number(w[1]) * 1000)) splashPreview.play()
        } }
    }
    Process { id: splashMark; command: ["sh", "-c", ": > \"${XDG_RUNTIME_DIR:-/tmp}/halcyon-splash-done-$(id -u)\""] }
    // "away" for the splashes: a heartbeat in ~/.local/state/island/last-seen every minute while unlocked (and once at each lock),
    // so after a logout, reboot or a long lock the gap since it is how long you were gone
    property real lockedAt: Date.now()
    function awayLongEnough(ms) {
        var min = opt.splashAwayMin !== undefined ? Number(opt.splashAwayMin) : 60
        return min <= 0 || !(ms >= 0) || ms >= min * 60000
    }
    Process { id: lastSeenMark; command: ["sh", "-c", "mkdir -p \"$HOME/.local/state/island\" && date +%s > \"$HOME/.local/state/island/last-seen\""] }
    Timer { interval: 60000; repeat: true; triggeredOnStart: true; running: !lockScreen.locked && !root.lean; onTriggered: lastSeenMark.running = true }
    Process { id: lockFlagClear; command: ["rm", "-f", Quickshell.env("HOME") + "/.cache/island/lock-on-start"] }
    Connections {
        target: lockScreen
        function onLockedChanged() {
            if (lockScreen.locked) { lockFlagClear.running = true; root.lockWasLogin = lockScreen.splashArm; root.lockedAt = Date.now(); lastSeenMark.running = true }
            else {
                if (!root.lockWasLogin && root.splashAllowed("splashUnlock") && root.awayLongEnough(Date.now() - root.lockedAt)) splashPreview.playMode("unlock")
                root.lockWasLogin = false
                briefT.restart()
            }
        }
    }
    // ---- the small AI helpers (scripts/halcyon-ai.py). One-shot commands: nothing keeps running, and the script itself stops when the
    // master AI switch is off (the brief then still works, in plain words, from your notes and Focus days).
    readonly property string aiHelper: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-ai.py"
    // the morning card: the first time the desktop is used each day (a while after login, or after an unlock), at most once a day
    function briefCard(now) {
        if (!now && opt.unusedRemind !== false && !gaming) Quickshell.execDetached(["python3", aiHelper, "unused", "--remind"])   // the script keeps it to once a month
        if (!now && (opt.aiBriefCard === false || gaming)) return
        Quickshell.execDetached(now ? ["python3", aiHelper, "brief", "--notify"] : ["python3", aiHelper, "brief", "--notify", "--once"])
    }
    Timer { id: briefT; interval: 20000; running: true; onTriggered: if (!lockScreen.locked) root.briefCard(false) }
    // a new QML error in this run of the island: explained once, as a notification (halcyon-ai.py remembers what it already explained)
    Timer {
        interval: 45000; running: true
        onTriggered: if (root.opt.aiExplain !== false) Quickshell.execDetached(["python3", root.aiHelper, "explain", "island", "--notify", "--if-new"])
    }

    PowerMenu {
        id: powerMenu
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsPower !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        blurOn: root.blur
        onSession: a => root.session(a)
    }

    // a click on the Wi-Fi / Bluetooth / battery icon of any bar: the networks / devices / power modes, next to the icon
    StatusPop {
        id: statusPop
        pal: pal
        net: root.net
        stats: root.stats
        profile: root.profile
        autoPower: root.autoPower
        onToggleWifi: root.toggleWifi()
        onToggleBt: root.toggleBt()
        onSetProfile: p => root.setProfile(p)
        onSetAuto: root.setAuto()
    }
    // the background apps of a rail as a pop-out next to the icon above the clock (the other bars open the bottom-left box)
    BgPop {
        id: bgPop
        pal: pal
    }
    // the wake spot at the top middle of the screen: resting the pointer on it drops the dashboard (Calendar in the spotlight). It is the
    // ONLY way a rail opens the dashboard: resting the pointer on the rail, scrolling or dragging along it do nothing any more.
    property bool dashZoneOn: false
    ActivationZone {
        pal: pal
        zone: root.railOn ? ({ edge: "top", pos: 0.5 }) : null
        lenHover: 280
        graceMs: 400
        blocked: root.fsQuiet || root.page !== "home" || statusPop.open || bgPop.open
        onHoverChanged: on => { root.dashZoneOn = on; if (on && !railPages.open) railPages.show("cal") }
    }
    function popStatus(kind, side, along, edge) {
        if (dropOn) { dropShow("util"); return }
        railPages.hide()
        bgPop.hide()
        statusPop.show(kind, side, along, edge)
    }
    function popBg(side, along, edge) {
        railPages.hide()
        statusPop.hide()
        bgPop.show(side, along, edge)
    }
    // the island (Home.qml) is inside the island window: its x is the screen's x, its bottom edge is where the pop-up starts
    function homeStatusPopup(kind, item) {
        if (dropOn) { dropShow("util"); return }
        var c = item.mapToItem(null, item.width / 2, item.height / 2)
        var b = island.mapToItem(null, 0, island.height)
        popStatus(kind, "top", c.x, b.y)
    }

    // the Performance tab's look, resolved in this ONE place for the rail's dashboard and the island / notch page: 'auto' = sky beside a rail,
    // classic (rings, specs, disks) on the island and the notch
    readonly property string perfLookNow: {
        var l = String(opt.perfLook || "auto")
        if (l === "auto") return railOn ? "sky" : "classic"
        return l
    }
    // a rail bar: the music window (pointer near the top of the rail) and the performance window (near the bottom) come out sideways
    readonly property bool railOn: customBarLoader.item !== null && customBarLoader.item.rail === true
    RailPages {
        id: railPages
        pal: pal
        player: root.player
        cava: root.cava
        stats: root.stats
        gpu: root.gpu
        specs: root.specs
        disks: root.disks
        net: root.net
        cal: calendar
        perfLook: root.perfLookNow
        profile: root.profile
        profileLabel: root.profileLabel
        autoPower: root.autoPower
        autoNote: root.autoNote
        sysmode: root.stats.sysmode || ""
        side: customBarLoader.item ? customBarLoader.item.side : "left"
        edge: customBarLoader.item ? customBarLoader.item.edgeDist : 0
        frameT: root.frameT
        railHeld: root.dashZoneOn
        onOpenCalendar: calendar.show()
        closeMs: root.opt.pageClose !== undefined ? root.opt.pageClose : 600
        onToggleWifi: root.toggleWifi()
        onToggleBt: root.toggleBt()
        onSetProfile: p => root.setProfile(p)
        onSetAuto: root.setAuto()
        onOpenMusic: tab => { clipMenu.hide(); shotMenu.hide(); musicMenu.show(tab) }
    }

    // ---- wake spots: where each box wakes, anywhere on any edge (Desktop builder). No spot set = the box's own corner.
    ActivationZone {
        pal: pal; zone: root.boxZones.util; clickMode: root.utilClick; blocked: root.fsQuiet || root.dropOn
        onHoverChanged: on => { corner.extHover = on; corner.syncHover() }
        onTapped: corner.hovering = !corner.hovering
    }
    ActivationZone {
        pal: pal; zone: root.boxZones.apps; clickMode: root.appsClick; blocked: root.fsQuiet || root.railOn
        onHoverChanged: on => { appsWin.extHover = on; appsWin.syncHover() }
        onTapped: appsWin.hovering = !appsWin.hovering
    }
    ActivationZone {
        pal: pal; zone: root.boxZones.term; clickMode: root.termClick; blocked: root.fsQuiet
        onHoverChanged: on => quickTerm.setHover(on)
        onTapped: quickTerm.cornerTap()
    }
    ActivationZone {
        pal: pal; zone: root.boxZones.notif; clickMode: root.notifClick; blocked: root.fsQuiet || root.dropOn
        onHoverChanged: on => notifs.setHover(on)
        onTapped: notifs.toggleCenter()
    }

    DisplayPicker {
        id: displayPicker
        pal: pal
    }

    // notification daemon + top-right bell, popups and centre (replaces dunst)
    Notifs {
        id: notifs
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsNotifs !== false
        maxToasts: root.notifMax
        maxHistory: root.notifHistoryMax
        toastSecs: root.opt.toastSecs
        critSecs: root.opt.critSecs !== undefined ? root.opt.critSecs : 30
        avatar: root.avatarPath
        usePfp: root.opt.notifIcon !== "app"
        layout: root.opt.notifLayout
        look: root.opt.notifStyle === "timeline" || root.opt.notifStyle === "grouped" ? root.opt.notifStyle : "stack"
        spot: root.opt.notifSpot === "corner" ? "corner" : "edge"
        cornerId: (root.boxSpots && root.boxSpots.notif) || "tr"
        origin: DS.originOf(root.opt, "notif", (root.boxSpots && root.boxSpots.notif) || "tr")
        dnd: root.dnd
        fsQuiet: root.fsQuiet && root.opt.dndFullscreen !== false
        gameQuiet: root.gameFs
        asleep: root.fsQuiet
        edgeOn: !root.dropOn
        clickMode: root.notifClick
        customZone: root.boxZones.notif !== null
        autoHide: root.autoHide
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        onDndRequested: v => root.setDnd(v)
    }

    // a command typed into the console for you, not run (Startup & processes > Unused: remove / turn off): press Enter there
    function consolePrefill(t) { quickTerm.prefill(t) }

    // top-left pop-out terminal (one-shot commands, sysmode switches; shows honeypot status while idle)
    QuickTerm {
        id: quickTerm
        pal: pal
        customZone: root.boxZones.term !== null
        spot: root.boxSpots.term
        origin: DS.originOf(root.opt, "term", root.boxSpots.term)
        stars: root.opt.stars !== false && root.opt.starsTerm !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        sysmode: root.sysmode
        clickMode: root.termClick
        chatMode: root.chatOnly
        onChatRequested: (tog, corner) => { if (!tog) quickChat.summon(); else if (corner) quickChat.cornerToggle(); else quickChat.toggle() }
        autoHide: root.autoHide
        starData: root.starData
        profileStars: root.profileStars
        fsActive: root.fsQuiet
    }

    // Pop-out AI Chatbox (independent quick assistant supporting Ollama, custom API, and Luna)
    QuickChat {
        id: quickChat
        pal: pal
        spot: root.boxSpots.term
        origin: DS.originOf(root.opt, "term", root.boxSpots.term)
        stars: root.opt.stars !== false && root.opt.starsTerm !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        clickMode: root.termClick
        autoHide: root.autoHide
        fsActive: root.fsQuiet
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        onOpenLunaRequested: {
            quickChat.close()
            lunaCenter.toggle()
        }
    }

    // SUPER+ALT+/: every console command as a tree (only when sysmode is set up); a click puts the command in the console
    CmdTree {
        id: cmdTree
        pal: pal
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
        onUse: t => { cmdTree.hide(); quickTerm.prefill(t) }
    }

    // >calendar: Google Calendar (read-only, through its private iCal address) + reminder notifications (Calendar.qml, scripts/gcal.py)
    Calendar {
        id: calendar
        pal: pal
        enabled: root.opt.calOn !== false
        notifyOn: root.opt.calNotify !== false
        focusOn: root.opt.calFocus === true
        nagOn: root.opt.calNag === true
        nagEvery: root.opt.calNagEvery !== undefined ? root.opt.calNagEvery : 5
        nagGiveUp: root.opt.calNagGiveUp !== undefined ? root.opt.calNagGiveUp : 180
        tasksAll: root.opt.calTasks === "all"
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        flyCount: root.boxStarCount
        flyLoop: root.boxStarLoop
        constellation: root.opt.stars !== false && root.opt.starsCalendar !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
    }

    // SUPER+N: the new-note panel on the side of the screen (type, Enter saves). ">all notes" in the launcher: the full list (NotesMenu.qml)
    NotesMenu {
        id: notesMenu
        pal: pal
        opt: root.opt
        spot: DS.cornerFor(root.opt, "term", root.boxSpots.term)      // beside the console: the side it is on follows its tag
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
    }

    // >clipboard in the launcher: what you copied lately, click or Enter to put it back (ClipMenu.qml; the history itself is cliphist's)
    ClipMenu {
        id: clipMenu
        pal: pal
        opt: root.opt
        spot: DS.cornerFor(root.opt, "term", root.boxSpots.term)      // beside the console: the side it is on follows its tag
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
    }

    // >gamecenter in the launcher: the game library, Proton versions and the system check in one window (GameCenter.qml, everything goes through `hgl`)
    GameCenter {
        id: gameCenter
        pal: pal
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
        hgl: root.hgl
        runningId: root.gameId
        onLaunchRequested: id => root.gameLaunch(id)
        onStopRequested: Quickshell.execDetached([root.hgl, "stop"])
        onConsoleRequested: cmd => quickTerm.run(cmd)
    }

    // >study: your PDFs, slides and notes, with questions answered from them, summaries, quizzes and flashcards (StudyCenter.qml,
    // scripts/halcyon-study.py)
    // Firewall Center (>firewall): ai-firewall's status, bans, rules, feeds, history and its assistant (FwCenter.qml)
    FwCenter {
        id: fwCenter
        pal: pal
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
        onConsoleRequested: cmd => quickTerm.run(cmd)
    }

    StudyCenter {
        id: studyCenter
        pal: pal
        consoleOpen: quickTerm.open && (quickTerm.focused || quickTerm.pinned)
        onConsoleRequested: cmd => quickTerm.run(cmd)
    }

    // >luna: your saved conversations with Luna, the local assistant (LunaCenter.qml, scripts/halcyon-luna.py)
    LunaCenter {
        id: lunaCenter
        pal: pal
    }

    // >security, >firewall, >antivirus: the firewall (ai-firewall) and the antivirus (ai-antivirus) in one window, each one optional
    // (SecurityCenter.qml; install.sh --firewall ai, --antivirus). Root actions run in the pop-out console.
    SecurityCenter {
        id: securityCenter
        pal: pal
        onConsoleRequested: cmd => { securityCenter.hide(); quickTerm.run(cmd) }
        onTerminalRequested: cmd => { securityCenter.hide(); Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "term-exec", "bash", "-c", cmd]) }
    }

    // SUPER + CTRL + S, >screenshot: Region / Window / Full screen, then Copy, Save or Both (ShotMenu.qml, scripts/halcyon-shot.py)
    ShotMenu {
        id: shotMenu
        pal: pal
        opt: root.opt
        spot: DS.cornerFor(root.opt, "term", root.boxSpots.term)      // beside the console: the side it is on follows its tag
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
    }

    // the Lyrics / Queue chips on the media page, >lyrics, >queue: the lyrics of what plays and what plays next (MusicMenu.qml, scripts/halcyon-music.py)
    MusicMenu {
        id: musicMenu
        pal: pal
        opt: root.opt
        spot: DS.cornerFor(root.opt, "term", root.boxSpots.term)      // beside the console: the side it is on follows its tag
        stars: root.opt.stars !== false && root.opt.starsCheatsheet !== false
        sysmode: root.sysmode
        starData: root.starData
        profileStars: root.profileStars
        title: root.player ? (root.player.trackTitle || "") : ""
        artist: root.player ? (root.player.trackArtist || "") : ""
        album: root.player ? (root.player.trackAlbum || "") : ""
        duration: root.player && root.player.length > 0 ? root.player.length : 0        // seconds (MPRIS length)
        fileUrl: root.player && root.player.metadata ? String(root.player.metadata["xesam:url"] || "") : ""
        player: root.player             // its position lights the line being sung
    }

    // Notifications are on top of every window, big ones included. Those open on the same layer and later = above, so whenever one
    // opens while a toast is showing (or a toast arrives while one is open) the notification window is put back on top.
    // notifs.centerOpen is NOT in this list on purpose: the notification window does not need to raise itself above itself, and the
    // raise() un-maps the window for a moment, which made the box think the pointer had left and close about a second after opening.
    readonly property bool anyOverlay: cheat.open || cmdTree.open || overviewOpen || settingsWin.open
        || calendar.open || notesMenu.open || clipMenu.open || gameCenter.open || studyCenter.open || lunaCenter.open || securityCenter.open || shotMenu.open || musicMenu.open || powerMenu.open || tour.open || corner.open || appsWin.open
        || settingsWin.galleryOpen || settingsWin.builderOpen
        || settingsWin.nbOpen || settingsWin.dbOpen || settingsWin.startupOpen
    property int notifSeen: 0
    onAnyOverlayChanged: {
        if (anyOverlay) {
            notifRaiseT.restart()
        } else if (root.opt && root.opt.lazyLoad !== false) {
            trimGc.restart()
        }
    }
    Timer { id: trimGc; interval: 1000; onTriggered: gc() }
    Timer { interval: 90000; repeat: true; running: !root.anyOverlay; onTriggered: gc() }
    Connections {
        target: notifs
        function onToastsChanged() {
            var n = notifs.toasts.length
            if (n > root.notifSeen && root.anyOverlay) notifRaiseT.restart()
            root.notifSeen = n
        }
    }
    Timer { id: notifRaiseT; interval: 260; onTriggered: if (notifs.toasts.length > 0 || notifs.centerOpen) notifs.raise() }

    // =====================================================================
    //  GUIDED TOUR (Tour.qml). The steps are in features.json, the only file to edit when a feature ships.
    //  First start = the whole list. After an update = only entries that are new / have a higher "rev" compared with the copy
    //  the user saw last (~/.local/state/island/features.seen.json). Existing users without a copy only get the non-core ones.
    // =====================================================================
    property string tourMode: ""            // fresh | legacy | seen
    property var tourCur: null              // features.json now
    property var tourSeenFile: null         // the copy the user saw
    property string tourDemoName: ""
    property bool tourTermOpened: false
    Process {
        running: true
        command: ["sh", "-c",
            "f=\"$1/features.json\"; d=\"$2\"; mkdir -p \"$d\"; [ -f \"$f\" ] || exit 0; "
            + "if [ -f \"$d/features.seen.json\" ]; then m=seen; s=$(cat \"$d/features.seen.json\"); "
            + "elif [ -f \"$d/tour.pending\" ]; then m=fresh; s=null; "
            + "elif [ -s \"$d/settings.json\" ]; then m=legacy; s=null; "
            + "else m=fresh; s=null; : > \"$d/tour.pending\"; fi; "      // pending: settings.json appears within seconds, this still counts as a first start after a reload
            + "printf '{\"mode\":\"%s\",\"seen\":%s,\"cur\":' \"$m\" \"$s\"; cat \"$f\"; printf '}'",
            "sh", Quickshell.shellDir, stateDir]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var t = JSON.parse(text)
                    root.tourMode = t.mode; root.tourCur = t.cur; root.tourSeenFile = t.seen
                    tourBoot.restart()
                } catch (e) {}
            }
        }
    }
    // wait until the island, the wallpaper and the bar have settled, and never show it over the lock screen or in Gaming mode
    Timer {
        id: tourBoot
        interval: 5000
        onTriggered: {
            if (!root.settingsLoaded || lockScreen.locked || root.gaming || tour.open) { restart(); return }
            root.tourAuto()
        }
    }
    // AI review of antivirus alerts (scripts/antivirus-ai.sh): read at start and whenever Settings opens
    property bool avAiOn: false
    Process {
        id: avAiProc
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/antivirus-ai.sh", "status"]
        stdout: StdioCollector { onStreamFinished: root.avAiOn = text.trim().indexOf("on") === 0 }
    }
    Connections { target: settingsWin; function onOpenChanged() { if (settingsWin.open && root.avInstalled && !avAiProc.running) avAiProc.running = true } }
    property bool lunaInstalled: false
    Process { running: true; command: ["sh", "-c", "test -x \"$HOME/.local/bin/luna\" || command -v luna >/dev/null"]; onExited: code => root.lunaInstalled = code === 0 }
    function tourPlan(mode) { return TourData.plan(mode, tourCur, tourSeenFile, { sysmode: cmdTree.available, firewall: root.fwInstalled, antivirus: root.avInstalled, luna: root.lunaInstalled }) }
    function tourAuto() {
        if (!tourCur) return
        var plan = tourPlan(tourMode)
        if (plan.steps.length === 0) { tourSaveSeen(); return }       // nothing new: just keep the copy current
        tourBegin(plan)
    }
    // `>tour` / `halcyon tour`: the whole thing again
    function tourReplay() { if (tourCur) tourBegin(tourPlan("fresh")) }
    function tourBegin(plan) {
        overviewOpen = false
        if (page === "launcher") page = "home"
        tour.start(plan.mode, plan.steps)
    }
    // "seen" = a copy of features.json as it is now; the next update is diffed against it
    function tourSaveSeen() {
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$2\" && cp \"$1/features.json\" \"$2/features.seen.json\" && rm -f \"$2/tour.pending\"", "sh", Quickshell.shellDir, stateDir])
    }
    // The island opens what the step talks about and closes it again when the step changes. Re-applied every second, because
    // hover timers elsewhere would otherwise fold a page or box back by themselves.
    readonly property var tourBigDemos: ["cheat", "cmds", "tree", "settings", "calendar"]
    function tourApply(name) {
        if (name === "perf" || name === "media" || name === "launcher" || name === "fw") { if (page !== name) page = name }
        else if (page === "perf" || page === "media" || page === "launcher" || page === "fw") page = "home"
        if (!dropOn) {
            if (name === "corner") corner.pinFor(600000)
            else if (corner.hovering) corner.hovering = false
        }
        if (notifs.edgeOn) { if (notifs.centerOpen !== (name === "notifs")) notifs.centerOpen = (name === "notifs") }
        if (name === "term") {
            if (!quickTerm.open) { quickTerm.open = true; quickTerm.pinned = true; tourTermOpened = true }
        } else if (tourTermOpened) { quickTerm.close(); tourTermOpened = false }
        if (name === "cheat") { if (!cheat.open) cheat.show() } else if (cheat.open) cheat.hide()
        if (name === "cmds") { if (!cmdTree.open) cmdTree.show() } else if (cmdTree.open) cmdTree.hide()
        if (name === "tree") overviewOpen = true; else if (overviewOpen) overviewOpen = false
        if (name === "settings") { if (!settingsWin.open) settingsWin.show() } else if (settingsWin.open) settingsWin.hide()
        if (name === "calendar") { if (!calendar.open) calendar.show() } else if (calendar.open) calendar.hide()
        if (autoHide) { win.peek = true; hideTimer.stop() }
    }
    Timer { interval: 1000; repeat: true; running: tour.open && !root.tourWaiting; onTriggered: root.tourApply(root.tourDemoName) }
    // ---- tour challenges ("try" in features.json): the step waits until you open the thing yourself, then you get a star.
    // While it waits nothing is opened for you (and nothing you opened is closed again); "Show me" opens it like a normal step.
    property bool tourWaiting: false
    function tourCheck(name) {
        switch (name) {
        case "launcher": return page === "launcher"
        case "media": return page === "media"
        case "perf": return page === "perf"
        case "fw": return page === "fw"
        case "notifs": return notifs.centerOpen || (dropOn && (page === "notif" || (dropSide && page === "util")))
        case "term": return quickTerm.open
        case "cheat": return cheat.open
        case "tree": return overviewOpen
        case "notes": return notesMenu.open
        case "screenshot": return shotMenu.open
        case "clipboard": return clipMenu.open
        }
        return false
    }
    function tourShowDemo() {
        tourWaiting = false
        tourDemoName = tour.step ? (tour.step.demo || "") : ""
        tourApply(tourDemoName)
        tourRaiseT.restart()         // whatever opened (the launcher above all) took the keyboard: Enter must stay "next", not "launch"
    }
    Timer {
        interval: 150; repeat: true; running: tour.open && root.tourWaiting
        onTriggered: {
            if (!tour.step || !tour.step.try) { root.tourWaiting = false; return }
            if (root.tourCheck(tour.step.try.check)) { tour.challengeDone(); root.tourShowDemo() }
        }
    }
    // windows that open on top of the tour's own window: put it back on top after they have appeared
    Timer { id: tourRaiseT; interval: 220; onTriggered: if (tour.open) tour.raise() }
    // where the hole goes, in screen pixels (sw x sh = this screen); null = no hole. Read live (about 30 times a second) so the
    // light follows the bar while it grows, shrinks or slides.
    function tourBarRect() {
        if (island.opacity > 0.05 && island.visible) {
            var p = island.mapToItem(null, 0, 0)
            return { x: p.x, y: p.y, w: island.width, h: island.height, r: island.radius }
        }
        // notch style at rest: the notch is the bar, the island itself is not drawn
        return { x: (win.width - notchBodyW) / 2, y: 0, w: notchBodyW, h: notchBarH, r: pal.rMd }
    }
    function tourRect(name, sw, sh) {
        switch (name) {
        case "bar": case "perf": case "media": case "fw": return tourBarRect()          // pages are the island itself, grown
        case "corner":
            if (dropOn) return null
            if (corner.oSide) return { x: corner.atR ? sw - (frameOn ? frameT : pal.boxEdge) - panel.width : (frameOn ? frameT : pal.boxEdge), y: corner.offY, w: panel.width, h: panel.height }
            if (corner.oVert) return { x: corner.offX, y: corner.atB ? sh - (frameOn ? frameT : pal.boxEdge) - panel.height : (frameOn ? frameT : pal.boxTop), w: panel.width, h: panel.height }
            return { x: corner.atR ? sw - pal.boxEdge - panel.width : pal.boxEdge,
                     y: corner.atB ? sh - pal.boxEdge - panel.height : pal.boxTop, w: panel.width, h: panel.height }
        case "notifs": return notifs.tourRect(sw)
        case "term": return quickTerm.tourRect(sw, sh)
        }
        return null
    }
    Tour {
        id: tour
        pal: pal
        rectFn: (name, sw, sh) => root.tourRect(name, sw, sh)
        onStepShown: step => {
            if (step.try && !tour.isDone(step.id)) {
                root.tourDemoName = ""
                root.tourApply("")                  // the last step's demo goes away; this one waits for you
                root.tourWaiting = true
                return
            }
            root.tourWaiting = false
            root.tourDemoName = step.demo || ""
            root.tourApply(root.tourDemoName)
            if (root.tourDemoName !== "") tourRaiseT.restart()        // the tour keeps the keyboard (the launcher would take Enter)
        }
        onShowMe: root.tourShowDemo()
        onFinished: completed => {
            root.tourWaiting = false
            root.tourDemoName = ""
            root.tourApply("")
            root.tourSaveSeen()
        }
    }

    // ---------- actions ----------
    property bool scrollOpened: false
    function go(dir) {
        if (page === "launcher" || page === "util" || page === "notif" || page === "cal") return
        hoverOpened = false
        scrollOpened = true           // opened by scroll / swipe: stays a bit longer once the pointer leaves (scrollLinger)
        island.hoverSpent = true      // you chose a page yourself: do not re-open one by hover until the pointer has left
        if (dir < 0) page = (page === "perf") ? "home" : "media"
        else page = (page === "media") ? "home" : "perf"
    }
    // Super tap can arrive twice (fast file trigger + IPC fallback, or both Super_L bind forms): only the first counts
    // which corner each corner box opens from (Desktop builder; DeskSpots.js keeps it one box per corner): { util, apps, term } = tl | bl | br
    readonly property var boxSpots: DS.normalize(opt ? opt.boxSpots : null)
    // where each box wakes (Desktop builder wake spots): null = from its own corner
    readonly property var boxZones: ({ notif: DS.zoneOf(opt, "notif"), util: DS.zoneOf(opt, "util"), apps: DS.zoneOf(opt, "apps"), term: DS.zoneOf(opt, "term") })
    property double lastSuperTap: 0
    // viaIpc: the fallback of scripts/super_tap.sh (it only runs when this island did not answer the trigger file in time).
    // It is ignored for a while after a tap that did work, because it can arrive late.
    readonly property string superAckFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/halcyon-super-ack"
    function superTapFired(viaIpc) {
        Quickshell.execDetached(["touch", superAckFile])       // tells super_tap.sh the tap arrived (also when Tap Super is off: nothing more to try then)
        if (!superTap) return
        var n = Date.now()
        if (n - lastSuperTap < (viaIpc === true ? 900 : 350)) return
        lastSuperTap = n
        toggleLauncher()
    }
    // fast path: keybinds write this file (a few ms) instead of waiting for a whole `quickshell ipc` process to start
    readonly property string superTapFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/halcyon-super-tap"
    function startTapWatch() { Quickshell.execDetached(["sh", "-c", "echo 0 > \"$1\"", "sh", superTapFile]); tapWatchT.start() }
    Timer { id: tapWatchT; interval: 600; onTriggered: tapWatch.path = root.superTapFile }
    FileView { id: tapWatch; path: ""; watchChanges: true; onFileChanged: root.superTapFired(false) }
    // the top-most thing the island has on screen (power menu > settings > shortcuts > tree view > quick console >
    // notification centre > launcher / performance / media page). Returns false when there is nothing to close.
    // Super + R / >calendar: the full calendar. Master switch off: say so instead of doing nothing.
    function calendarKey() {
        if (root.opt.calOn === false) {
            Quickshell.execDetached(["notify-send", "-a", "Halcyon", "-i", "x-office-calendar", "Calendar is switched off", "Turn it on in Settings > Calendar."])
            return
        }
        if (page === "cal") page = "home"
        calendar.toggle()
    }
    // a click on the bar clock (Settings > Calendar > Clock click): the calendar drops out of the bar, in the bar's own style
    function clockClicked() {
        if (root.opt.calOn === false || root.opt.calClock === false) return false
        if (page === "cal") { page = "home"; return true }
        if (calendar.open) calendar.hide()
        hoverOpened = false; scrollOpened = false
        island.hoverSpent = true
        calendar.refresh()
        page = "cal"
        return true
    }
    function closeOverlay() {
        if (displayPicker.open) { displayPicker.hide(); return true }
        if (tour.open) { tour.end(false); return true }
        if (powerMenu.open) { powerMenu.hide(); return true }
        if (notesMenu.open) { notesMenu.close(); return true }
        if (clipMenu.open) { clipMenu.close(); return true }
        if (gameCenter.open && !gameCenter.asWindow) { gameCenter.close(); return true }
        if (studyCenter.open && !studyCenter.asWindow) { studyCenter.hide(); return true }
        if (lunaCenter.open && !lunaCenter.asWindow) { lunaCenter.hide(); return true }
        if (securityCenter.open && !securityCenter.asWindow) { securityCenter.hide(); return true }
        if (shotMenu.open) { shotMenu.close(); return true }
        if (musicMenu.open) { musicMenu.close(); return true }
        if (calendar.open) { calendar.hide(); return true }
        if (settingsWin.startupOpen) { settingsWin.startupOpen = false; return true }
        if (settingsWin.builderOpen) { settingsWin.builderOpen = false; return true }
        if (settingsWin.nbOpen) { settingsWin.nbOpen = false; return true }
        if (settingsWin.dbOpen) { settingsWin.dbOpen = false; return true }
        if (settingsWin.wbOpen) { settingsWin.wbOpen = false; return true }
        if (deskEditing) { deskEditing = false; return true }
        if (settingsWin.galleryOpen) { settingsWin.galleryOpen = false; return true }
        if (settingsWin.open) { settingsWin.hide(); return true }
        if (cheat.open) { if (cheat.editId !== "") cheat.cancelEdit(); else cheat.hide(); return true }
        if (overviewOpen) { overviewOpen = false; return true }
        if (cmdTree.open) { cmdTree.hide(); return true }
        if (quickChat.open && (quickChat.pinned || quickChat.focused)) { quickChat.close(); return true }
        if (quickTerm.open && (quickTerm.pinned || quickTerm.focused)) { quickTerm.close(); return true }
        if (notifs.centerOpen) { notifs.toggleCenter(); return true }
        if (page !== "home") { page = "home"; return true }
        return false
    }
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

    // writes are batched: a slider drag or a burst of changes now costs ONE shell + file write, 300 ms after the last change
    function saveSettings() {
        if (!settingsLoaded) return
        saveT.restart()
    }
    Timer { id: saveT; interval: 300; onTriggered: root.writeSettings() }
    Component.onDestruction: { if (saveT.running) { saveT.stop(); writeSettings() }; Quickshell.execDetached(["pkill", "-CONT", "-x", "gslapper"]) }      // never lose a pending save when the island reloads
    function writeSettings() {
        if (!settingsLoaded) return
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/settings.json\"", "sh", stateDir,
                                 JSON.stringify({ autoHide: autoHide, autoPower: autoPower, compactSpecial: compactSpecial, dnd: dnd, edgeMode: edgeMode, glassShift: glassShift, motion: motion, rounding: rounding, gaps: gaps, blur: blur, shadows: shadows,
                                                  hyprAnim: hyprAnim, profileStars: profileStars, hyprTouched: hyprTouched,
                                                  profileName: profileName, profileAvatar: profileAvatar, routeApps: routeApps, routeShow: routeShow,
                                                  notifHistoryMax: notifHistoryMax, notifMax: notifMax, idleLock: idleLock, idleSleep: idleSleep, idleDim: idleDim, osdOn: osdOn, idleTouched: idleTouched,
                                                  clock24: clock24, growthOn: growthOn, growthMin: growthMin, superTap: superTap, termFollow: termFollow, colorBoost: colorBoost,
                                                  theme: theme, themeTouched: themeTouched, scrollTouch: scrollTouch, scrollMouse: scrollMouse, scrollTouched: scrollTouched,
                                                  barScroll: barScroll, barPadding: barPadding, powerMgr: powerMgr, hoverAction: hoverAction, compactWs: compactWs, opt: opt, hy: hy })])
    }
    // small one-line state files read by scripts / Hyprland's Lua config
    function writeFlag(name, value) {
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$3\" > \"$1/$2\"", "sh", stateDir, name, String(value)])
    }
    // ---- Safe mode and Profiles (scripts/halcyon-fx.py). The script edits settings.json and asks the island to read it again.
    // fxRun first writes any save that is still waiting (so the script never reads, or gets overwritten by, older values), then starts it.
    readonly property string fxScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-fx.py"
    property var fxArgs: []
    function fxRun(args) {
        if (saveT.running) { saveT.stop(); writeSettings() }
        fxArgs = args
        fxStartT.restart()
    }
    Timer { id: fxStartT; interval: 450; onTriggered: Quickshell.execDetached(["python3", root.fxScript].concat(root.fxArgs)) }
    // read settings.json again inside the running island (no restart): `halcyon profile ...` calls this through IPC (applyFx)
    function reloadSettingsFile() { settingsLoadProc.running = false; settingsLoadProc.running = true }
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
        case "fxProfile": fxRun(["profile", String(v)]); return        // Settings > Performance > Profiles (Custom | Work | Gaming | Battery | Night)
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
        case "routeShow": routeShow = v; break
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
        // focused window: a hairline in the wallpaper accent (not while the accent is cycling: that would restart Hyprland's border fade every 100 ms)
        if (opt.accentBorder !== false && !pal.cycling) {
            var ac = String(pal.accent)                   // "#rrggbb"
            var acc = "rgba(" + ac.slice(1, 7) + (theme === "light" ? "a0" : "90") + ")"
            if (!cfg.general) cfg.general = {}
            cfg.general["col.active_border"] = acc
            if (!cfg.group) cfg.group = {}
            cfg.group["col.border_active"] = acc
            accentApplied = true
        } else if (opt.accentBorder === false && accentApplied) {
            // switched off: back to the neutral hairline
            var neutral = theme === "light" ? "rgba(00000038)" : "rgba(ffffff30)"
            if (!cfg.general) cfg.general = {}
            cfg.general["col.active_border"] = neutral
            if (!cfg.group) cfg.group = {}
            cfg.group["col.border_active"] = neutral
            accentApplied = false
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
    // the wallpaper (or the accent colour setting) changed: re-colour the focused-window border a moment later
    Timer { id: accentKick; interval: 1200; onTriggered: root.applyHypr() }
    Connections {
        target: pal
        function onAccentChanged() { if (root.opt.accentBorder !== false && !pal.cycling && root.settingsLoaded) accentKick.restart() }
        function onCyclingChanged() { if (!pal.cycling && root.settingsLoaded) accentKick.restart() }
    }

    property double gamingGuard: 0      // ignore the state-file poll until this time (ms): the script needs a moment
    function setGaming(on) {
        gaming = on
        gamingGuard = Date.now() + 1400
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/gamemode.sh", on ? "on" : "off"])
        if (!on) { hyprKick.interval = 1200; hyprKick.restart() }   // the script reloads Hyprland; put our tweaks back on top
        gamingCheck.restart()
    }
    // ---- game launcher (hgl). `hgl run` calls gamestart when the game starts and gameend once everything is put back (also when the
    // game crashed or hgl itself was killed: the watchdog does it). Lean = the island rests while the game runs: the stats / net
    // feeds stop, the desktop widgets are hidden (their timers stop with them), the visualizer and animations are off. Only the pill stays.
    function setLean(on) {
        if (lean === on) return
        leanAt = Date.now()
        lean = on
    }
    function gameStarted(id, name, since, lean) {
        gameId = id
        gameName = name
        gameSince = since > 0 ? since : Date.now() / 1000
        setLean(lean === true)
        gamingCheck.restart()                    // gamemode.sh was run by hgl just before: show the Gaming chip as it is
    }
    function gameEnded() {
        gameId = ""
        gameName = ""
        setLean(false)
        gamingCheck.restart()
        hyprKick.interval = 1200; hyprKick.restart()     // gamemode.sh off reloads Hyprland: put our tweaks back on top
    }
    function gameLaunch(id) {
        if (gameId !== "") {
            Quickshell.execDetached(["notify-send", "-a", "Halcyon", "-i", "applications-games", gameName + " is already running", "Stop it first (the pill, or >games stop)"])
            return
        }
        // its own process group and a scope-less detach: the game must not die with the shell
        // its output (and any error before the game starts) goes to a file the Game Center reads to say what is happening
        Quickshell.execDetached(["sh", "-c", "unset VK_DRIVER_FILES VK_ICD_FILENAMES __EGL_VENDOR_LIBRARY_FILENAMES; exec \"$1\" run \"$2\" >\"$3\" 2>&1", "sh", root.hgl, id, Quickshell.env("XDG_RUNTIME_DIR") + "/hgl-launch.out"])
    }
    // the island restarted while a game runs (a reload, a crash): hgl knows
    Process {
        running: true
        command: ["sh", "-c", "[ -x \"$1\" ] && \"$1\" status", "sh", root.hgl]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text)
                    if (j.running === true && root.gameId === "") root.gameStarted(j.id, j.name, j.since, j.lean === true)
                } catch (e) {}
            }
        }
    }
    GamePill {
        pal: pal
        env: root
        running: root.gameId !== ""
        name: root.gameName
        since: root.gameSince
        lean: root.lean
        onStopRequested: Quickshell.execDetached([root.hgl, "stop"])
    }

    // the state file is the truth: re-read it shortly after a click and every few seconds, so the chip can never
    // disagree with the script (a toggle from SUPER+F10 / a terminal / a failed run all end up shown correctly)
    Timer { id: gamingCheck; interval: 1700; onTriggered: gamingProc.running = true }
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
    Process {
        id: caffeineProc
        running: true
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/caffeine.sh", "status"]
        stdout: StdioCollector { onStreamFinished: { if (Date.now() > root.caffeineGuard) root.caffeine = text.trim() === "on" } }
    }

    // ---- Num Lock: the bar builder's "Num lock" widget. It is watched only while that widget is on the bar. The key's LED is read
    // straight from sysfs (no process); a keyboard without a Num Lock LED is asked through scripts/numlock.sh status instead.
    readonly property bool numLockShown: {
        if (deskNeeds.numlock) return true
        var l = root.opt.barLayout
        if ((root.opt.barStyle !== "custom" && root.opt.barStyle !== "rail") || !l) return false
        return [].concat(l.left || [], l.center || [], l.right || []).indexOf("numlock") >= 0
    }
    property string numLockLed: ""          // /sys/class/leds/...::numlock/brightness ("" = none, or not looked for yet)
    property bool numLockProbed: false
    function toggleNumLock() {
        numLock = !numLock
        numLockGuard = Date.now() + 1500
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/numlock.sh", "toggle"])
        numLockCheck.restart()
    }
    function pollNumLock() {
        if (numLockLed !== "") numLedFile.reload()
        else if (numLockProbed && !numLockProc.running) numLockProc.running = true
    }
    Timer { id: numLockCheck; interval: 900; onTriggered: root.pollNumLock() }
    Timer { interval: 1000; running: root.numLockShown && !root.lean; repeat: true; triggeredOnStart: true; onTriggered: root.pollNumLock() }
    Process {
        id: numLedProbe
        running: root.numLockShown && !root.numLockProbed
        command: ["bash", "-c", "for f in /sys/class/leds/*::numlock/brightness; do [ -r \"$f\" ] && { echo \"$f\"; break; }; done"]
        stdout: SplitParser { onRead: d => { if (d.trim() !== "") root.numLockLed = d.trim() } }
        onExited: root.numLockProbed = true
    }
    FileView {
        id: numLedFile
        path: root.numLockLed
        onLoaded: { if (Date.now() > root.numLockGuard) root.numLock = text().trim() !== "0" }
    }
    Process {
        id: numLockProc
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/numlock.sh", "status"]
        stdout: StdioCollector { onStreamFinished: { if (Date.now() > root.numLockGuard) root.numLock = text.trim() === "on" } }
    }

    // ---- Focus mode (scripts/focus.sh): an advanced do-not-disturb for studying / work. A timer (optionally Pomodoro), Do not
    // disturb + Caffeine while it runs, and the apps in the block list are closed when they open. The helper process owns the
    // session; this only shows it and sends commands. The countdown is computed here from the end time, so nothing is polled per second.
    property var focusState: ({ on: false })
    property double focusNow: Date.now() / 1000
    readonly property int focusLeft: !focusState.on ? 0 : (focusState.paused ? focusState.left : Math.max(0, Math.round(focusState.end - focusNow)))
    // Focus work phase (not a Pomodoro break, not paused) with "Quiet visuals during Focus" on: the visualizer feeds and a video wallpaper rest
    readonly property bool focusQuiet: opt.focusQuiet === true && focusState.on === true && focusState.paused !== true && focusState.phase !== "break"
    Process { id: fxPause; property string sig: "-CONT"; command: ["pkill", sig, "-x", "gslapper"] }
    onFocusQuietChanged: { fxPause.sig = focusQuiet ? "-STOP" : "-CONT"; fxPause.running = true }
    readonly property string focusText: {
        var s = focusLeft, m = Math.floor(s / 60), r = s % 60
        return (m < 10 ? "0" : "") + m + ":" + (r < 10 ? "0" : "") + r
    }
    readonly property string focusScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/focus.sh"
    function focusRun(args) {
        Quickshell.execDetached(["bash", focusScript].concat(args))
        focusKick.restart()
    }
    property var focusConf: ({ LENGTH: 25, POMODORO: false, apps: [] })
    function focusSet(mins, pomo) {
        var c = JSON.parse(JSON.stringify(focusConf))
        c.LENGTH = mins; c.POMODORO = pomo
        focusConf = c                                   // show it at once
        Quickshell.execDetached(["bash", "-c", "bash \"$0\" set LENGTH " + mins + " && bash \"$0\" set POMODORO " + (pomo ? 1 : 0), focusScript])
    }
    Process {
        id: focusConfProc
        command: ["bash", root.focusScript, "conf"]
        running: true
        stdout: StdioCollector { onStreamFinished: { try { root.focusConf = JSON.parse(text) } catch (e) {} } }
    }
    function focusToggle() { focusRun(focusState.on ? ["stop"] : ["start"]) }
    Timer { id: focusKick; interval: 700; onTriggered: if (!focusProc.running) focusProc.running = true }
    Timer {
        // ticks only while a session runs; when the phase is over it asks the helper what comes next (break / done)
        interval: 1000; running: root.focusState.on; repeat: true
        onTriggered: {
            root.focusNow = Date.now() / 1000
            if (root.focusState.on && !root.focusState.paused && root.focusNow >= root.focusState.end + 0.5 && !focusProc.running) focusProc.running = true
        }
    }
    Process {
        id: focusProc
        command: ["bash", root.focusScript, "status"]
        stdout: StdioCollector { onStreamFinished: { try { root.focusState = JSON.parse(text); root.focusNow = Date.now() / 1000 } catch (e) {} } }
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
            if (!quiet && routeShow) { showWs = app.ws; showT.restart() }
        }
        routed = keep
        routeSeeded = true
    }

    function toggleWifi() {
        var on = net.wifi === "on"
        Quickshell.execDetached(["nmcli", "radio", "wifi", on ? "off" : "on"])
        net = Object.assign({}, net, { wifi: on ? "off" : "on" })
        netPokeT.restart()
    }
    function toggleBt() {
        var on = net.bt === "on"
        Quickshell.execDetached(["bluetoothctl", "power", on ? "off" : "on"])
        net = Object.assign({}, net, { bt: on ? "off" : "on" })
        netPokeT.restart()
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
            if (a && !autoPower) { autoPower = true; saveSettings() }
            // the state file can go stale while the daemon is perfectly alive (a slow poll, suspend / resume), so a missing or old
            // file alone must not switch Auto off (and save that): ask systemd whether the daemon really is gone first
            else if (!a && autoPower && !autoCheck.running) autoCheck.running = true
        }
        if (autoPower && stats.pprofile) profile = stats.pprofile
    }

    Process {
        id: autoCheck
        command: ["systemctl", "--user", "is-active", "--quiet", root.powerService]
        onExited: code => {
            if (code !== 0 && root.stats.auto !== true && Date.now() > root.autoGuard && root.autoPower) { root.autoPower = false; root.saveSettings() }
        }
    }

    function session(action) {
        switch (action) {
        case "lock": lockScreen.lock(); break
        case "suspend": Quickshell.execDetached(["systemctl", "suspend"]); break
        case "logout": hypr("hl.dsp.exit()"); break
        case "reboot": goodbye("reboot"); break
        case "shutdown": goodbye("shutdown"); break
        }
    }
    function randomWallpaper() {
        wallpaperLayer.next()
    }
    // the everyday tools (scripts/halcyon-tools.py): a launcher entry "tool-<name>" runs the helper with these arguments
    readonly property var toolArgs: ({
        "colorpick": ["colorpick"], "measure": ["measure"], "wifi-qr": ["wifi-qr"],
        "updates-now": ["updates", "now"], "updates-run": ["updates", "run"],
        "snippets": ["snippets", "pick"], "windows": ["windows", "pick"], "mixer": ["mixer", "pick"],
        "zoom": ["zoom", "toggle"], "vpn": ["vpn", "toggle"]
    })
    // the ones `hal tools` has (Rust, ~1 ms to start) run there; the rest, or any without hal built, in the Python helper
    readonly property var halTools: ["colorpick", "measure", "zoom", "snippets", "windows"]
    function runTool(name) {
        var a = toolArgs[name]
        if (!a) return
        var home = Quickshell.env("HOME")
        if (halTools.indexOf(a[0]) >= 0)
            Quickshell.execDetached(["sh", "-c", "h=\"$1\"; shift; [ -x \"$h\" ] && exec \"$h\" tools \"$@\"; exec python3 \"$HOME/.config/Halcyon/scripts/halcyon-tools.py\" \"$@\"", "sh", home + "/.config/Halcyon/bin/hal"].concat(a))
        else
            Quickshell.execDetached(["python3", home + "/.config/Halcyon/scripts/halcyon-tools.py"].concat(a))
    }
    function runCommand(id) {
        if (id.indexOf("tool-") === 0) { runTool(id.substring(5)); return }
        if (id.indexOf("game:") === 0) { gameLaunch(id.substring(5)); return }       // a game row of >games / >game <name> (Launcher.qml)
        if (id.indexOf("settings:") === 0) { settingsWin.show(id.substring(9)); return }  // >ask's guide: Settings at that group (Launcher.qml)
        if (id.indexOf("profile-") === 0) {
            var p = id.substring(8)
            if (p === "auto") setAuto(); else setProfile(p)
            return
        }
        switch (id) {
        case "firewall": if (studyCenter.open && !studyCenter.asWindow) studyCenter.hide(); if (gameCenter.open && !gameCenter.asWindow) gameCenter.hide(); fwCenter.toggle(); break
        case "firewall-page": Qt.callLater(() => { root.page = "fw" }); return      // after the launcher's own close (which sets home)
        case "firewall-dashboard": Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "term-exec", "bash", "-c", "sudo ai-firewall top"]); break
        case "wallpaper": randomWallpaper(); break
        case "wallpaper-back": wallpaperLayer.back(); break
        case "wallpaper-keep": wallpaperLayer.keep(); break
        case "wallgallery": settingsWin.openGallery(); break
        case "barbuilder": settingsWin.openBuilder(); break
        case "notifbuilder": settingsWin.openNotifBuilder(); break
        case "desktopbuilder": settingsWin.openDesktopBuilder("desktop"); break
        case "lockdesktopbuilder": settingsWin.openDesktopBuilder("lock"); break
        case "widgetbuilder": settingsWin.openWidgetBuilder("", "desktop"); break
        case "lockwidgetbuilder": settingsWin.openWidgetBuilder("", "lock"); break
        case "desktopedit": deskEditTarget = "desktop"; deskEditing = !deskEditing; break
        case "lockdesktopedit": deskEditTarget = "lock"; deskEditing = !deskEditing; break
        case "bartoggle": setOpt("barStyle", opt.barStyle === "off" ? "island" : "off"); break
        case "startupview": settingsWin.openStartup(); break
        case "splash": splashPreview.play(); break
        case "weeklysky": weeklySky.toggle(); break
        case "focusgraph": focusStreak.toggle(); break
        case "tour": tourReplay(); break
        case "calendar": calendarKey(); break
        case "reload": fullReloadProc.running = true; break
        case "settings": settingsWin.show(); break
        case "power": powerMenu.show(); break
        case "gaming": setGaming(!gaming); break
        case "caffeine": setCaffeine(!caffeine, 0); break
        case "apps": appsWin.pinFor(9000); break
        case "routing": routeApps = !routeApps; saveSettings(); break
        case "autohide": setAutoHide(!autoHide); break
        case "barstyle": setOpt("barStyle", notchStyle ? "island" : "notch"); break
        case "notifications": notifs.toggleCenter(); break
        case "quickterm": quickTerm.toggle(); break
        case "quickchat": quickChat.toggle(); break
        // game launcher (hgl): `>games` is the quick list in the launcher, the rest opens the Game Center (GameCenter.qml)
        case "games": launcher.openGames(); if (page !== "launcher") { overviewOpen = false; page = "launcher" } break
        case "gamecenter": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); gameCenter.toggle(); break
        case "study": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); if (gameCenter.open && !gameCenter.asWindow) gameCenter.hide(); if (lunaCenter.open && !lunaCenter.asWindow) lunaCenter.hide(); studyCenter.toggle(); break
        case "luna": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); if (gameCenter.open && !gameCenter.asWindow) gameCenter.hide(); if (studyCenter.open && !studyCenter.asWindow) studyCenter.hide(); lunaCenter.toggle(); break
        case "security": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); if (gameCenter.open && !gameCenter.asWindow) gameCenter.hide(); if (studyCenter.open && !studyCenter.asWindow) studyCenter.hide(); securityCenter.toggle(); break
        case "firewall": case "antivirus": case "exceptions": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); if (gameCenter.open && !gameCenter.asWindow) gameCenter.hide(); if (studyCenter.open && !studyCenter.asWindow) studyCenter.hide(); securityCenter.show(id); break
        case "games-add": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); gameCenter.showAdd(); break
        case "games-import": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); gameCenter.show("library"); gameCenter.act([root.hgl, "import", "steam"], "Steam library read"); break
        case "games-doctor": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); gameCenter.show("doctor"); break
        case "games-stores": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); gameCenter.show("stores"); break
        case "games-proton": clipMenu.hide(); shotMenu.hide(); musicMenu.hide(); gameCenter.show("runtimes"); break
        case "games-stop": Quickshell.execDetached([root.hgl, "stop"]); break
        case "cmdlist": cmdTree.toggle(); break
        case "edgemode": toggleEdgeMode(); break
        case "dnd": setDnd(!dnd); break
        case "cheatsheet": cheat.toggle(); break
        case "display":
        case "projector":
            displayPicker.toggle()
            break
        case "printer":
            Quickshell.execDetached([Quickshell.env("HOME") + "/.config/Halcyon/scripts/printer.sh"])
            break
        case "theme": toggleTheme(); break
        case "wifi": toggleWifi(); break
        case "bluetooth": toggleBt(); break
        case "notes": notesMenu.toggle(); break
        case "notesall": notesMenu.toggleAll(); break
        case "clipboard": shotMenu.hide(); musicMenu.hide(); clipMenu.toggle(); break
        case "screenshot": clipMenu.hide(); musicMenu.hide(); shotMenu.toggle(); break
        case "lyrics": clipMenu.hide(); shotMenu.hide(); musicMenu.toggleTab("lyrics"); break
        case "queue": clipMenu.hide(); shotMenu.hide(); musicMenu.toggleTab("queue"); break
        case "record": toggleRecording(); break
        case "extradim": toggleExtraDim(); break
        default: session(id)
        }
    }

    // ---------- data sources ----------
    Process {
        id: settingsLoadProc
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
                        for (var oy in s.opt) if (oy !== "notchCenter") oo[oy] = s.opt[oy]      // notchCenter is gone: the notch clock is always centred
                        if (oo.lockCleanV2 !== true) {   // one-time: the lock screen is clean by default now (battery / Wi-Fi / media / Switch user are opt-in in Settings > Power & lock)
                            oo.lockWidgets = false; oo.lockSwitch = false; oo.lockCleanV2 = true
                        }
                        var mg = WD.migrate(oo)          // the old notes / calendar choice becomes one Notes widget, once
                        if (mg) oo.deskWidgets = mg
                        root.opt = oo
                        root.syncRefresh()
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
                    if (root.hyprTouched || root.themeTouched || root.scrollTouched || root.opt.accentBorder !== false || Object.keys(root.hy).length > 0) hyprKick.restart()
                    if (root.autoPower && root.powerMgr === "halcyon") {
                        root.autoGuard = Date.now() + 10000
                        Quickshell.execDetached(["systemctl", "--user", "start", root.powerService])
                    }
                    // a power manager other than Halcyon Auto: the system's own default starts at boot, so put the chosen one back
                    if (root.powerMgr !== "halcyon") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/power_manager_select.sh", root.powerMgr, "quiet"])
                    root.compactSpecial = s.compactSpecial !== false
                    root.applySpecialScale()
                    root.routeApps = s.routeApps !== false
                    root.routeShow = s.routeShow === true
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
    // The resource use picked in the installer (install.sh -> scripts/user-setup.sh resource-seed): applied ONCE, after settings.json has
    // been loaded, exactly like picking the preset in Settings > Performance > Resource use, plus the RAM / CPU limits of the Health tab.
    // The file is deleted right after it is read, so a later change in Settings is never overwritten.
    Process {
        running: root.settingsLoaded
        command: ["sh", "-c", "f=\"$HOME/.local/state/island/resource-seed.json\"; [ -s \"$f\" ] && cat \"$f\" && rm -f \"$f\"; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    if (text.trim() === "") return
                    var r = JSON.parse(text)
                    if (["low", "medium", "high"].indexOf(r.resMode) < 0) return
                    root.applyResMode(r.resMode)
                    var o = {}
                    for (var x in root.opt) o[x] = root.opt[x]
                    if (r.limMode === "auto" || r.limMode === "manual") o.limMode = r.limMode
                    if (r.limRam > 0) o.limRam = r.limRam
                    if (r.limCpu > 0) o.limCpu = r.limCpu
                    root.opt = o
                    root.saveSettings()
                } catch (e) {}
            }
        }
    }
    // A first look from the installer (scripts/user-setup.sh wallpaper, on a machine with no wallpapers yet): the live Halcyon sky on the
    // desktop and the lock screen. Applied once, like resource-seed.json; only these keys are taken.
    Process {
        running: root.settingsLoaded
        command: ["sh", "-c", "f=\"$HOME/.local/state/island/look-seed.json\"; [ -s \"$f\" ] && cat \"$f\" && rm -f \"$f\"; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    if (text.trim() === "") return
                    var r = JSON.parse(text)
                    if (r.deskLive === "on" || r.deskLive === "off") root.setOpt("deskLive", r.deskLive)
                    if (["solid", "wallpaper", "sky"].indexOf(r.lockBg) >= 0) root.setOpt("lockBg", r.lockBg)
                } catch (e) {}
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
    // the Halcyon sky's glow (sky.frag, LiveSky.qml), built the same way; empty = LiveSky paints it on a Canvas instead
    property string skyShaderUrl: ""
    Process {
        running: true
        command: ["bash", root.cfg + "/island/scripts/build-shader.sh", "sky"]
        stdout: StdioCollector { onStreamFinished: { var p = text.trim(); if (p !== "") root.skyShaderUrl = "file://" + p } }
    }
    Process {
        id: gamingProc
        running: true
        command: ["sh", "-c", "test -f /dev/shm/halcyon-gamemode && echo on || echo off"]
        stdout: StdioCollector { onStreamFinished: {
            if (Date.now() <= root.gamingGuard) return
            var was = root.gaming
            root.gaming = text.trim() === "on"
            // gaming mode ended (by hgl after a game, or anywhere else): gamemode.sh reloaded Hyprland, so put our look back on top.
            // (gameEnded's own kick came before this read and was skipped while `gaming` was still true)
            if (was && !root.gaming) { hyprKick.interval = 600; hyprKick.restart() }
        } }
    }
    // The always-on readers are `hx stats` / `hx net` (Rust, src/hx/src/sysfeeds.rs): no process is started per tick.
    // An older hx without them exits with code 2 and `touch ~/.local/state/island/stats-legacy` (or net-legacy) makes them exit
    // with 3: either way the island falls back to the bash scripts (scripts/stats.sh, scripts/net.sh), which stay as they were.
    property bool statsLegacy: false
    property bool statsSeen: false
    Process {
        running: !root.statsLegacy && !root.lean
        command: [root.hx, "stats", "2"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.stats = JSON.parse(d); root.statsSeen = true } catch (e) {} } }
        onExited: code => { if (code !== 0 && Date.now() - root.leanAt > 4000) root.statsLegacy = true }     // (a feed stopped for lean mode is not a broken feed)
    }
    Timer { interval: 10000; running: !root.statsLegacy && !root.statsSeen && !root.lean; onTriggered: root.statsLegacy = true }   // hx missing / silent
    Process {
        running: root.statsLegacy && !root.lean
        command: ["bash", root.cfg + "/island/scripts/stats.sh", "2"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.stats = JSON.parse(d) } catch (e) {} } }
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
        running: (root.perfShown || root.deskNeeds.disk) && !root.lean
        command: [root.hx, "disk", "10"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.disks = JSON.parse(d) } catch (e) {} } }
    }
    // every 2 s on the performance page, every 6 s for a desktop GPU widget alone: each read of an awake NVIDIA GPU starts
    // nvidia-smi (~40 ms of CPU)
    Process {
        running: root.perfShown && !root.lean
        command: ["bash", root.cfg + "/island/scripts/gpu.sh", "2"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.gpu = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        running: !root.perfShown && root.deskNeeds.gpu && !root.lean
        command: ["bash", root.cfg + "/island/scripts/gpu.sh", "6"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.gpu = JSON.parse(d) } catch (e) {} } }
    }
    property bool netLegacy: false
    property bool netSeen: false
    Process {
        running: !root.netLegacy && !root.lean
        command: [root.hx, "net", "4"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.net = JSON.parse(d); root.netSeen = true } catch (e) {} } }
        onExited: code => { if (code !== 0 && Date.now() - root.leanAt > 4000) root.netLegacy = true }
    }
    Timer { interval: 10000; running: !root.netLegacy && !root.netSeen && !root.lean; onTriggered: root.netLegacy = true }
    Process {
        running: root.netLegacy && !root.lean
        command: ["bash", root.cfg + "/island/scripts/net.sh", "4"]
        stdout: SplitParser { property string last: ""; onRead: d => { if (d === last) return; last = d; try { root.net = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        id: profProc
        command: ["powerprofilesctl", "get"]
        stdout: SplitParser { onRead: d => { if (d.trim()) root.profile = d.trim() } }
    }
    // one slow poll for the state readers (gaming flag, caffeine unit, power profile, focus session). `hx states` answers all four
    // in ONE short process (they used to be sh + bash/systemctl + two Python interpreters every 15 s). The old four-process
    // poll below is only used when the installed hx is too old to know `states`. The guards are the same ones the single
    // readers use, so a switch you just flipped is not overwritten by a poll that started before it.
    property bool statesLegacy: false
    property bool statesSeen: false
    Process {
        id: statesProc
        command: [root.hx, "states"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text)
                    root.statesSeen = true
                    if (Date.now() > root.gamingGuard) root.gaming = j.gaming === true
                    if (Date.now() > root.caffeineGuard) root.caffeine = j.caffeine === true
                    if (j.profile) root.profile = j.profile
                    if (j.focus) { root.focusState = j.focus; root.focusNow = Date.now() / 1000 }
                } catch (e) {}
            }
        }
        onExited: code => { if (code !== 0) root.statesLegacy = true }
    }
    Timer { interval: 20000; running: !root.statesLegacy && !root.statesSeen; onTriggered: root.statesLegacy = true }   // hx missing / silent
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: { if (!root.statesLegacy) { if (!statesProc.running) statesProc.running = true } else { gamingProc.running = true; caffeineProc.running = true; profProc.running = true; if (!focusProc.running) focusProc.running = true } } }
    Timer { id: profKick; interval: 3500; onTriggered: profProc.running = true }

    // volume / brightness, only polled while the bottom-right panel is open
    Process {
        running: corner.open || root.page === "util" || root.deskNeeds.ctl
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

    // visualizer feed, only runs while something is playing AND a surface showing it is visible (bar style Off has no bar: the
    // media page and the desktop widget are the only readers, and the widget has its own cava below)
    Process {
        running: root.playing && !root.gaming && !root.lean && !root.focusQuiet && root.opt.viz !== "off" && !root.vizHold && (root.page === "media" || (root.page === "home" && root.opt.barStyle !== "off" && (win.shown || root.notchStyle || root.opt.barStyle === "custom" || root.opt.barStyle === "rail")))
        command: ["cava", "-p", Quickshell.shellPath(root.opt.viz === "light" ? "cava-light.conf" : "cava.conf")]
        stdout: SplitParser {
            onRead: d => {
                var a = d.split(";"), out = []
                for (var i = 0; i < a.length; i++) if (a[i] !== "") out.push(parseInt(a[i]))
                root.cava = out
            }
        }
        onRunningChanged: if (!running) root.cava = []
    }
    // the desktop's audio visualizer widget has its own, finer cava (48 bars): started only while that widget exists and music plays
    property var cavaDesk: []
    Process {
        running: root.playing && !root.gaming && !root.lean && !root.focusQuiet && root.opt.viz !== "off" && root.deskNeeds.viz
        command: ["cava", "-p", Quickshell.shellPath(root.opt.viz === "light" ? "cava-desk-light.conf" : "cava-desk.conf")]
        stdout: SplitParser {
            onRead: d => {
                var a = d.split(";"), out = []
                for (var i = 0; i < a.length; i++) if (a[i] !== "") out.push(parseInt(a[i]))
                root.cavaDesk = out
            }
        }
        onRunningChanged: if (!running) root.cavaDesk = []
    }

    // ================= desktop widgets (WidgetData.js, DeskWidgets.qml, WidgetBuilderWindow.qml, DesktopEditor.qml) =================
    // `deskNeeds`: which readers the placed widgets need, so nothing runs for a widget that is not there.
    // The lock screen's widgets need their feeds only while the lock screen is up (or while you place them): lockNeeds is empty otherwise.
    readonly property bool lockWidgetsLive: WD.isOn(opt, "lock") && (lockScreen.locked || (deskEditing && deskEditTarget === "lock") || (settingsWin.wbOpen && settingsWin.wbTarget === "lock"))
    readonly property var lockNeeds: lockWidgetsLive ? WD.needs(WD.normalizeFor(opt.lockDeskWidgets, "lock")) : WD.needs(null)
    readonly property var deskNeeds: WD.mergeNeeds(opt.deskWidgetsOn === false ? WD.needs(null) : WD.needs(WD.normalize(opt.deskWidgets)), lockNeeds)
    property bool deskEditing: false                     // "place them on the desktop" is open (DesktopEditor.qml)
    property string deskEditTarget: "desktop"            // ... and it works on this list: "desktop" or "lock" (the lock screen's widgets)
    // the desktop widgets keep clear of the screen border too (frameT is 0 with the border off)
    readonly property real deskTop: ((railUp && railBar.side === "top") ? railBar.zoneWanted + 16 : (topFree ? 24 : 70)) + frameT
    // a rail on any edge: the desktop widgets sit beside it, not under it
    readonly property var railBar: customBarLoader.item
    readonly property bool railUp: railBar !== null && railBar.rail === true
    // where the wake spots of the corner boxes (notifications, utilities, console, apps) start on each edge: right at the screen edge, ON the
    // border, like before the rail. Only on the edge a rail sits on do they move in, to the rail's band (it already includes the border), so
    // the rail never blocks them
    readonly property real insL: (railUp && railBar.side === "left") ? railBar.zoneWanted : 0
    readonly property real insT: (railUp && railBar.side === "top") ? railBar.zoneWanted : 0
    readonly property real insR: (railUp && railBar.side === "right") ? railBar.zoneWanted : 0
    readonly property real insB: (railUp && railBar.side === "bottom") ? railBar.zoneWanted : 0
    readonly property real deskLeft: (railUp && railBar.side === "left" ? railBar.zoneWanted : 0) + frameT
    readonly property real deskRight: (railUp && railBar.side === "right" ? railBar.zoneWanted : 0) + frameT
    readonly property real deskBottom: (railUp && railBar.side === "bottom" ? railBar.zoneWanted : 0) + frameT
    function deskSetVol(f) { pendVol = f; vol = f * 100; if (!sliderT.running) sliderT.start() }
    function deskSetBright(f) { pendBright = f; bright = f * 100; if (!sliderT.running) sliderT.start() }
    function deskRun(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }
    function openFocusStreak() { focusStreak.show() }      // the Focus streak graph widget's click
    // what a widget button or wheel can do
    function deskAct(a) {
        switch (a) {
        case "wifi": toggleWifi(); break
        case "bt": toggleBt(); break
        case "dnd": setDnd(!dnd); break
        case "caffeine": setCaffeine(!caffeine, 0); break
        case "gaming": setGaming(!gaming); break
        case "numlock": toggleNumLock(); break
        case "theme": toggleTheme(); break
        case "night": Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/toggle_nightlight.sh"]); break
        case "lock": lockScreen.lock(); break
        case "power": powerMenu.show(); break
        case "console": quickTerm.toggle(); break
        case "notes": notesMenu.show(); break
        case "mute": Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]); muted = !muted; break
        case "ws-up": Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/ws-nav.sh", "wheel-up"]); break
        case "ws-down": Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/ws-nav.sh", "wheel-down"]); break
        }
    }
    // What the widgets on the LOCK screen get as `env` instead of the shell itself (Lock.qml deskEnv). The values are the real ones, so the widgets
    // show the real numbers; every action is empty, so even if a widget body asked for one, nothing could be run, switched or opened from a locked
    // screen. (WidgetData.js also leaves out of the lock screen every type that runs commands or shows private things.)
    QtObject {
        id: lockEnv
        readonly property var opt: root.opt
        readonly property var stats: root.stats
        readonly property var net: root.net
        readonly property real vol: root.vol
        readonly property bool muted: root.muted
        readonly property real bright: root.bright
        readonly property var gpu: root.gpu
        readonly property var disks: root.disks
        readonly property bool clock24: root.clock24
        readonly property string starName: root.starName
        readonly property var player: root.player
        readonly property bool playing: root.playing
        readonly property var cavaDesk: root.cavaDesk
        readonly property var focusState: root.focusState
        readonly property var focusDays: root.focusDays
        readonly property int focusLeft: root.focusLeft
        readonly property string focusText: root.focusText
        readonly property real lockBackLum: root.lockBackLum
        // what toggles, the boxes, workspaces and special workspaces SHOW (read only: their buttons are dead while locked)
        readonly property bool caffeine: root.caffeine
        readonly property bool dnd: root.dnd
        readonly property bool gaming: root.gaming
        readonly property bool numLock: root.numLock
        readonly property string theme: root.theme
        readonly property string activeSpecial: root.activeSpecial
        function deskAct(a) { }
        function openFocusStreak() { }
        function deskRun(c) { }
        function deskSetVol(f) { }
        function deskSetBright(f) { }
        function focusRun(args) { }
        function focusToggle() { }
        function toggleSpecial(n) { }
        function hypr(d) { }
    }
    // How bright the lock screen's background is (linear 0 .. 1): the plain theme colour, or the whole wallpaper (it is blurred, so only its average
    // counts) mixed with the theme colour by the tint sheet. The widgets pick readable colours from it (WidgetHost.lockLum); the Widget builder's
    // lock-screen preview reads it too.
    readonly property real lockBackLum: {
        var bg = (palObj && palObj.bg) ? WD.relLum(palObj.bg) : 0.05
        if (opt.lockBg !== "wallpaper" || wallpaperLayer.currentPath === "") return bg
        var t = Math.max(0, Math.min(0.95, opt.lockTint !== undefined ? opt.lockTint : 0.55))
        var wallLum = (palObj && typeof palObj.lumAt === "function") ? palObj.lumAt(0, 0, 1, 1) : 0.15
        return wallLum * (1 - t) + bg * t
    }

    // Focus streak: the minutes of every work phase are counted here, one a minute, into focus-days.json (scripts/focus-log.sh)
    property var focusDays: ({})
    readonly property string focusLogScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/focus-log.sh"
    function focusDayKey() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
    Process {
        id: focusDaysProc
        command: ["bash", root.focusLogScript, "json"]
        stdout: StdioCollector { onStreamFinished: { try { root.focusDays = JSON.parse(text) } catch (e) {} } }
    }
    function refreshFocusDays() { if (!focusDaysProc.running) focusDaysProc.running = true }
    // Read the history at startup, whenever a Focus widget appears or the Focus streak view opens, and every 5 min after. (This used to
    // run only from onDeskNeedsChanged, which does not fire for the value a widget list already has at startup, so the streak / graph
    // stayed empty until the list was edited. With no Focus widget at all it was never read, so the streak view showed 0.)
    Timer {
        interval: 300000; repeat: true; triggeredOnStart: true
        running: root.deskNeeds.focusLog === true || focusStreak.open
        onTriggered: if (!focusDaysProc.running) focusDaysProc.running = true
    }
    Timer {
        interval: 60000; repeat: true
        running: root.focusState.on === true && root.focusState.paused !== true && root.focusState.phase === "work"
        onTriggered: {
            var d = {}, k = root.focusDayKey()
            for (var x in root.focusDays) d[x] = root.focusDays[x]
            d[k] = (d[k] || 0) + 1
            root.focusDays = d
            Quickshell.execDetached(["bash", root.focusLogScript, "add", "1"])
        }
    }

    // ---- quiet while a window is fullscreen (a video, a game, a presentation): popups stay away but are still kept in the notification
    // centre; Halcyon's own (timers, reminders) and urgent ones still show. Do not disturb itself is not touched. After a fullscreen /
    // workspace / window-close event it asks Hyprland once what the active window is doing (one short hyprctl call, nothing runs in between).
    // it is asked whatever Settings > Notifications says: the edge boxes and the console also go to sleep while a window is fullscreen
    // (touching a screen edge in a game must not slide a box over it); keybinds and the launcher still open them
    property bool fsQuiet: false
    // a game is fullscreen (one hgl started, or gaming mode is on): not a single popup, they all wait in the notification centre
    readonly property bool gameFs: fsQuiet && (gameId !== "" || gaming)
    onFsQuietChanged: if (fsQuiet) {
        if (corner.hovering && !corner.pinnedOpen) corner.hovering = false
        if (appsWin.hovering && !appsWin.pinnedOpen) appsWin.hovering = false
    }
    // the time-of-day grade over the wallpaper right now (Wallpaper.qml: { r, g, b, tint, dim }), or null when it is off: the desktop
    // widgets work out their colours from the picture as it is seen, after this wash (WidgetHost.qml)
    readonly property var todGrade: wallpaperLayer.todOn ? wallpaperLayer.todNow : null
    readonly property bool screenLocked: lockScreen.locked      // for things that only get the shell as `env` (DesktopStars stops drawing)
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            var n = event.name
            if (n === "fullscreen" || n === "workspacev2" || (n === "closewindow" && root.fsQuiet)) fsT.restart()
        }
    }
    Timer { id: fsT; interval: 250; onTriggered: if (!fsProc.running) fsProc.running = true }
    Process {
        id: fsProc
        command: ["hyprctl", "-j", "activewindow"]
        stdout: StdioCollector {
            onStreamFinished: {
                var q = false
                try { var d = JSON.parse(text); q = (d.fullscreen === true || d.fullscreen === 2 || d.fullscreen === 3) } catch (e) {}
                root.fsQuiet = q
            }
        }
    }

    // ---- the desktop is hidden under windows (Hyprland's window list for the wallpaper's screen: its workspace and an open special
    // workspace cover >= 92 % of it). The moving stars and the desktop widgets stop drawing then; nobody sees them, and every star
    // tick or widget update also made Hyprland re-blur the windows above. Re-checked after window events and every 5 s while they
    // are on (a floating window's drag or resize sends no event). An event that can uncover it shows them again at once, before
    // the check: a closed window never leaves an empty desktop for a moment.
    property bool deskCovered: false
    property string coverFocus: ""          // the focused window's address at the last activewindowv2
    readonly property bool deskCoverWatch: (opt.deskStars === true || opt.deskLive === "on" || opt.deskLive === "sky" || opt.deskWidgetsOn !== false) && !gaming && !lockScreen.locked
    Connections {
        target: Hyprland
        enabled: root.deskCoverWatch
        function onRawEvent(event) {
            var n = event.name
            // activewindowv2 also comes on every title change of the focused window (a terminal's spinner: once a second);
            // only a focus change to another window counts
            if (n === "activewindowv2") { if (event.data === root.coverFocus) return; root.coverFocus = event.data }
            if (n === "openwindow" || n === "closewindow" || n === "movewindowv2" || n === "changefloatingmode" || n === "fullscreen"
                || n === "workspacev2" || n === "activespecial" || n === "activespecialv2" || n === "focusedmonv2" || n === "activewindowv2") {
                if (n !== "openwindow" && n !== "activewindowv2") root.deskCovered = false
                coverT.restart()
            }
        }
    }
    Timer { id: coverT; interval: 300; onTriggered: if (!coverProc.running) coverProc.running = true }
    // the 5 s re-check is only for floating windows (dragging or resizing one sends no event); with none on screen it stops
    property bool coverFloating: true        // true until the first check: that check is what starts the watch
    Timer { interval: 5000; repeat: true; running: root.deskCoverWatch && root.coverFloating; triggeredOnStart: true; onTriggered: coverT.restart() }
    onDeskCoverWatchChanged: { if (!deskCoverWatch) deskCovered = false; else coverT.restart() }
    Process {
        id: coverProc
        command: ["sh", "-c", "hyprctl -j monitors; echo; echo @@; hyprctl -j clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                var cov = false
                try {
                    var parts = text.split("@@")
                    var mons = JSON.parse(parts[0]), wins = JSON.parse(parts[1])
                    var want = wallpaperLayer.screen ? wallpaperLayer.screen.name : ""
                    var m = null
                    for (var i = 0; i < mons.length; i++) if (mons[i].name === want || (!m && want === "")) m = mons[i]
                    if (m) {
                        var sc = m.scale || 1, mw = m.width / sc, mh = m.height / sc
                        if (m.transform % 2 === 1) { var tmp = mw; mw = mh; mh = tmp }
                        var ws = [m.activeWorkspace ? m.activeWorkspace.id : -999, m.specialWorkspace ? m.specialWorkspace.id : -999]
                        var rects = [], floating = false
                        for (var j = 0; j < wins.length; j++) {
                            var c = wins[j]
                            if (!c.mapped || c.hidden || !c.workspace || ws.indexOf(c.workspace.id) < 0) continue
                            rects.push([c.at[0] - m.x, c.at[1] - m.y, c.size[0], c.size[1]])
                            if (c.floating) floating = true
                        }
                        root.coverFloating = floating
                        // sample a 24 x 15 grid of the screen: the share of points under some window
                        var hit = 0, tot = 0
                        for (var gy = 0; gy < 15; gy++) for (var gx = 0; gx < 24; gx++) {
                            var px = (gx + 0.5) * mw / 24, py = (gy + 0.5) * mh / 15
                            tot++
                            for (var r = 0; r < rects.length; r++) {
                                var q = rects[r]
                                if (px >= q[0] && px < q[0] + q[2] && py >= q[1] && py < q[1] + q[3]) { hit++; break }
                            }
                        }
                        cov = hit / tot >= 0.92
                    }
                } catch (e) {}
                root.deskCovered = cov && root.deskCoverWatch
            }
        }
    }

    readonly property var compactEvents: ({ workspace: 1, workspacev2: 1, focusedmon: 1, focusedmonv2: 1, openwindow: 1, closewindow: 1, movewindow: 1, movewindowv2: 1, destroyworkspace: 1, destroyworkspacev2: 1 })
    // which special workspace is open ("" = none)
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "activespecial")
                root.activeSpecial = event.data.split(",")[0].replace("special:", "")
            else if (event.name === "openwindow")
                root.routeSoon()
            if (root.compactEvents[event.name] === 1)
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
                if (!root.compactWs || root.activeSpecial !== "") return
                var f = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
                var cl = []
                try { cl = JSON.parse(text) } catch (e) { return }

                // Group mapped window addresses by normal numeric workspace (> 0)
                var wsMap = {}
                for (var i = 0; i < cl.length; i++) {
                    var c = cl[i]
                    if (!c.mapped) continue
                    var w = c.workspace ? c.workspace.id : 0
                    if (w <= 0) continue
                    if (!wsMap[w]) wsMap[w] = []
                    wsMap[w].push(c.address)
                }

                // Sorted list of occupied numeric workspaces
                var occupied = Object.keys(wsMap).map(Number).sort(function (a, b) { return a - b })
                if (occupied.length === 0) return

                var cmds = []
                var changed = false
                var newFocused = f

                for (var k = 0; k < occupied.length; k++) {
                    var curWs = occupied[k]
                    var targetWs = k + 1
                    if (curWs !== targetWs) {
                        changed = true
                        var addrs = wsMap[curWs]
                        for (var j = 0; j < addrs.length; j++) {
                            cmds.push("dispatch hl.dsp.window.move({ workspace = " + targetWs + ", window = \"address:" + addrs[j] + "\" })")
                        }
                        if (f === curWs) newFocused = targetWs
                    }
                }

                if (!changed) return

                if (newFocused !== f && newFocused > 0) {
                    cmds.push("dispatch hl.dsp.focus({ workspace = " + newFocused + " })")
                }

                Quickshell.execDetached(["hyprctl", "--batch", cmds.join(" ; ")])
            }
        }
    }

    // the wallpaper layer (circular reveal) lives in this same Quickshell process: one Qt/QML/GL stack instead of two.
    // `quickshell ipc -p ~/.config/Halcyon/quickshell/island call wallpaper next` still works (target "wallpaper" in Wallpaper.qml)
    Wallpaper { id: wallpaperLayer; visible: !root.startHold; pal: pal; opt: root.opt; env: root; widgetsHidden: root.deskEditing; widgetsTop: root.deskTop; widgetsLeft: root.deskLeft; widgetsRight: root.deskRight; widgetsBottom: root.deskBottom }

    // quickshell ipc -p ~/.config/Halcyon/quickshell/island call island <fn>
    IpcHandler {
        target: "island"
        function launcher(): void { root.toggleLauncher() }
        function supertap(): void { root.superTapFired(true) }
        // Hyprland also reports a pinch and runs this when the fingers lift. The live tracker (touchpad-gestures) has already opened or
        // closed the tree view by then, and this is a TOGGLE, so it used to undo it. Ignored while the tracker is on it and for a moment
        // after. With the tracker not running, nothing is ignored: this call is then the only thing that opens it.
        function overview(): void {
            if ((root.gestureActive && root.gestureTarget === "overview") || (Date.now() - root.overviewGestureEndAt) < 900) return
            root.toggleOverview()
        }
        function home(): void { root.page = "home" }
        function media(): void { root.page = "media" }
        function perf(): void { root.page = "perf" }
        function firewall(): void { root.page = root.page === "fw" ? "home" : "fw" }      // ai-firewall status page (FwPage.qml)
        function firewallcenter(): void { root.runCommand("firewall") }                   // the Firewall Center window (FwCenter.qml)
        function panel(): void { if (!root.dropShow("util")) corner.pinFor(6000) }
        function autohide(): void { root.setAutoHide(!root.autoHide) }
        function barstyle(): void { root.runCommand("barstyle") }
        function clearnotifs(): void { notifs.clearAll() }
        function notifcenter(): void { if (!root.dropShow("notif")) notifs.toggleCenter() }
        function dnd(): void { root.setDnd(!root.dnd) }
        function dndset(on: bool): void { root.setDnd(on) }          // set (gamemode.sh): dnd() above only toggles
        function gamingset(on: bool): void { if (root.gaming !== on) root.setGaming(on) }       // set, for `halcyon ai do gaming on`
        function gamestart(id: string, name: string, since: string, lean: bool): void { root.gameStarted(id, name, Number(since), lean) }   // hgl run
        function gameend(): void { root.gameEnded() }                                                                                     // hgl run, when the game is over
        function lunasettings(): void { if (!lunaCenter.open) root.runCommand("luna"); lunaCenter.openSettings() }   // the Luna window on its Settings page
        function luna(): void { root.runCommand("luna") }                                                                                  // the Luna window (toggle)
        function study(): void { root.runCommand("study") }                                                                                // the Study Center window (toggle)
        function security(): void { root.runCommand("security") }                                                                          // the Security center window (toggle)
        function securitypage(page: string): void { securityCenter.show(page) }                                                           // overview | firewall | antivirus | exceptions | ask
        function gamecenter(): void { root.runCommand("gamecenter") }                                                                      // the Game Center window (toggle)
        function gamecenterpage(page: string): void { gameCenter.show(page) }                                                              // library | stores | runtimes | doctor
        function leanset(on: bool): void { root.setLean(on) }                                                                              // by hand: the lean island alone
        function caffeineset(on: bool): void { if (root.caffeine !== on) root.setCaffeine(on, 0) }
        function command(id: string): void { root.runCommand(id) }   // any launcher command by its id (">" list), e.g. profile-balanced, wifi
        function brief(): void { root.briefCard(true) }              // the daily brief as a notification now (scripts/halcyon-ai.py brief)
        function cheatsheet(): void { root.runCommand("cheatsheet") }
        function display(): void { displayPicker.toggle() }
        // SUPER+Q (scripts/close.sh): closes the top-most island overlay and answers "closed"; "none" = nothing was open,
        // so the script closes the focused window instead
        function closeTop(): string { return root.closeOverlay() ? "closed" : "none" }
        function theme(): void { root.toggleTheme() }
        function quickterm(): void { quickTerm.toggle() }
        function quickchat(): void { quickChat.toggle() }
        function reloadPalette(): void { pal.reloadFromFile() }
        function cmdlist(): void { cmdTree.toggle() }                // SUPER+ALT+/ (does nothing without sysmode)
        function edgemode(): void { root.toggleEdgeMode() }
        function settings(): void { settingsWin.toggle() }
        function barbuilder(): void { settingsWin.openBuilder() }
        function notifbuilder(): void { settingsWin.openNotifBuilder() }
        function desktopbuilder(): void { settingsWin.openDesktopBuilder("desktop") }
        function lockdesktopbuilder(): void { settingsWin.openDesktopBuilder("lock") }
        function widgetbuilder(): void { settingsWin.openWidgetBuilder("", "desktop") }
        function lockwidgetbuilder(): void { settingsWin.openWidgetBuilder("", "lock") }
        function desktopedit(): void { root.deskEditTarget = "desktop"; root.deskEditing = !root.deskEditing }
        function lockdesktopedit(): void { root.deskEditTarget = "lock"; root.deskEditing = !root.deskEditing }
        function bar(): void { root.setOpt("barStyle", root.opt.barStyle === "off" ? "island" : "off") }      // the top bar on / off
        function setopt(key: string, json: string): void { try { root.setOpt(key, JSON.parse(json)) } catch (e) {} }     // any opt.* by hand / from scripts: setopt hideHints true
        // preview a Performance tab look: `qs ipc call island perfLook forecast` (or auto); returns the name, or an error with the valid names
        function perfLook(name: string): string {
            var ok = ["auto", "sky", "orbit", "pulse", "tiles", "sea", "forecast", "radar", "cockpit", "recorder", "editorial", "stars", "classic"]
            var n = String(name).trim().toLowerCase()
            if (ok.indexOf(n) < 0) return "error: unknown look '" + name + "'. Valid: " + ok.join(", ")
            root.setOpt("perfLook", n)
            return n
        }
        function gallery(): void { settingsWin.openGallery() }
        function startup(): void { settingsWin.openStartup() }
        function splash(): void { splashPreview.play() }
        function weeklysky(): void { weeklySky.toggle() }
        function wifiqr(png: string, ssid: string): void { if (png === "") wifiQr.hide(); else wifiQr.show(png, ssid) }   // halcyon-tools.py wifi-qr ("" closes it)
        function focusgraph(): void { focusStreak.toggle() }
        function tour(): void { root.tourReplay() }
        function calendar(): void { root.runCommand("calendar") }
        function processes(): void { settingsWin.openStartup() }
        function wallpaperpicker(): void { settingsWin.openGallery() }
        function power(): void { powerMenu.show() }
        // shut down / restart with the goodbye splash first (the fish poweroff / reboot / shutdown now / systemctl wrappers call this)
        function goodbye(action: string): void { root.goodbye(action === "reboot" ? "reboot" : "shutdown") }
        function gaming(): void { root.setGaming(!root.gaming) }
        function caffeine(): void { root.setCaffeine(!root.caffeine, 0) }
        function focus(): void { root.focusToggle() }                 // start / stop a Focus session (SUPER+ALT+F)
        function focuspause(): void { root.focusRun([root.focusState.paused ? "resume" : "pause"]) }
        function apps(): void { appsWin.pinFor(9000) }
        function routing(): void { root.runCommand("routing") }
        function lock(): void { lockScreen.lock() }
        function trim(): void { gc() }
        function sweetspot(): void {
            root.applyResMode("medium")
            root.setHy("blurPasses", 2)
            root.setHy("blurSize", 5)
            root.setSetting("opt:starsBar", false)
            root.setSetting("opt:fps", 60)
            root.setSetting("opt:lazyLoad", true)
            gc()
        }
        function advisor(): void { quickTerm.run("python3 " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/adaptive-advisor.py") }
        function advisorLlm(): void { quickTerm.run("python3 " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/adaptive-advisor.py --llm") }
        function extradim(): void { root.toggleExtraDim() }
        function notes(): void { notesMenu.toggle() }
        function notesAll(): void { notesMenu.toggleAll() }
        function clipboard(): void { root.runCommand("clipboard") }
        function screenshot(): void { root.runCommand("screenshot") }
        function lyrics(): void { root.runCommand("lyrics") }
        function queue(): void { root.runCommand("queue") }
        function music(): void { root.runCommand("lyrics") }
        function refreshNotes(): void { notesMenu.loadNotes() }
        function record(): void { root.toggleRecording() }
        function reload(): void { fullReloadProc.running = true }
        function applyFx(): void { root.reloadSettingsFile() }          // halcyon-fx.py: settings.json changed, read it again now
    }

    // =====================================================================
    //  TOP: the island (bar -> media / performance pages -> expanding search bar)
    // =====================================================================
    // ---- Live 1:1 finger-following 3-finger & 4-finger touchpad gesture state (written by touchpad-gestures)
    property bool gestureActive: false
    property real gestureProgress: 0.0
    property real gestureScale: 1.0
    property string gestureTarget: ""
    property bool gestureStartOpen: false
    property double overviewGestureEndAt: 0     // when a live 3 / 4 finger gesture last decided the tree view (see overview() in the IpcHandler)
    property bool winLinger: false

    Connections {
        target: root
        function onPageChanged() {
            if (root.page !== "home") {
                root.winLinger = true
                winLingerT.stop()
            } else {
                winLingerT.restart()
            }
        }
    }
    Timer {
        id: winLingerT
        interval: 480
        onTriggered: {
            root.winLinger = false
            if (root.opt && root.opt.lazyLoad !== false) gc()
        }
    }

    // If the gesture daemon dies mid-gesture (or the last "end" is lost) the bar and the tree view would keep following stale
    // finger positions. No update for 600 ms while a gesture is active = the gesture is over.
    Timer {
        id: gestureWatchdog
        interval: 600
        onTriggered: {
            root.gestureActive = false
            root.gestureTarget = ""
            root.gestureProgress = 1.0
            root.gestureScale = 1.0
            island.dragX = 0
            island.dragY = 0
        }
    }

    FileView {
        id: liveGestureView
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/halcyon-gesture.json"
        printErrors: false             // the gesture tracker writes it on the first swipe; until then a missing file is normal
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            var raw = (text() || "").trim()
            if (!raw) return
            try {
                var g = JSON.parse(raw)
                var ph = g.phase || ""
                var act = g.action || ""
                var dx = Number(g.dx || 0)
                var dy = Number(g.dy || 0)
                var sc = Number(g.scale || 1)
                if (ph === "begin" || ph === "update") gestureWatchdog.restart()
                else gestureWatchdog.stop()
                if (ph === "begin") {
                    root.gestureActive = true
                    root.gestureTarget = ""
                    root.gestureProgress = 0
                    root.gestureScale = 1
                    root.gestureStartOpen = root.overviewOpen || root.page !== "home"
                } else if (ph === "update") {
                    root.gestureActive = true
                    if (act && root.gestureTarget === "") {
                        root.gestureTarget = act
                        if (act === "overview") {
                            root.gestureStartOpen = root.overviewOpen
                            if (!root.overviewOpen) root.overviewOpen = true
                        } else if ((act === "launcher" || act === "Launcher") && root.page !== "launcher") {
                            root.page = "launcher"
                        } else if ((act === "todo" || act === "Calendar") && root.page !== "cal") {
                            root.page = "cal"
                        } else if ((act === "notifcenter" || act === "Control") && root.page !== "util") {
                            root.page = "util"
                        }
                    }
                    var mag = Math.min(1.0, Math.max(Math.abs(dx), Math.abs(dy), Math.abs(sc - 1.0) / 0.35))
                    root.gestureProgress = root.gestureStartOpen ? Math.max(0.08, 1.0 - mag * 0.85) : Math.max(0.12, mag)
                    root.gestureScale = sc
                    if (root.gestureTarget === "" && Math.abs(dy) > Math.abs(dx)) {
                        island.dragY = dy * 90
                    }
                } else if (ph === "end") {
                    var finalMag = Math.max(Math.abs(dx), Math.abs(dy), Math.abs(sc - 1.0) / 0.35)
                    if (root.gestureTarget === "overview") {
                        root.overviewGestureEndAt = Date.now()
                        if (root.gestureStartOpen && finalMag > 0.32) root.overviewOpen = false
                        else if (!root.gestureStartOpen && finalMag < 0.25) root.overviewOpen = false
                        else root.overviewOpen = true
                    } else if (root.gestureTarget === "launcher" || root.gestureTarget === "Launcher" || root.gestureTarget === "todo" || root.gestureTarget === "Calendar" || root.gestureTarget === "notifcenter" || root.gestureTarget === "Control") {
                        if (finalMag < 0.25 && !root.gestureStartOpen) root.page = "home"
                    }
                    island.dragX = 0
                    island.dragY = 0
                    root.gestureActive = false
                    root.gestureTarget = ""
                    root.gestureProgress = 1.0
                    root.gestureScale = 1.0
                }
            } catch (e) {}
        }
    }

    PanelWindow {
        id: win
        visible: !root.startHold

        anchors { top: true; left: true; right: true }
        // FIXED height on purpose. Shrinking this surface while the bar is idle made every page open / close re-send the pointer
        // enter / leave, so the media / performance pages (and the boxes) could open and fold back by themselves. The masks below keep
        // the empty part click-through, and the blur rule ignores the transparent part, so it costs next to nothing.
        implicitHeight: 620 + root.frameT
        // auto-hide frees the strip the bar reserves; otherwise windows start below the bar
        // Hyprland starts windows at (this zone + the outer gap), so the outer gap is taken off to get exactly padSet.gap between bar and windows
        // (it can not go lower than the outer gap itself: Settings > Look > Gaps)
        // with a border: the island style (and "off") reserves its room from the border's width on; Notch / Custom leave that to the bar
        readonly property int zoneWanted: ((root.autoHide || root.notchStyle) ? 0 : Math.max(0, root.padSet.top + root.padSet.h + root.padSet.gap - root.gaps * 2))
                       + ((root.notchStyle && !root.topFree) ? 0 : root.frameT)
        // A window that reserves nothing used to be exclusiveZone 0 + Ignore. Zone 0 still means "keep out of the room other bars reserve":
        // when the launcher takes the keyboard focus the compositor re-arranges the layers and this window was pushed down by the notch
        // bar's room (the page then hung 24-36 px under the border, with a gap). -1 is the layer-shell value for "ignore every other
        // window's zone, extend to the screen's edges": the page always hangs from the very top edge, whatever else is on the screen.
        exclusiveZone: zoneWanted > 0 ? zoneWanted : -1
        exclusionMode: ExclusionMode.Normal
        color: "transparent"

        WlrLayershell.namespace: "island"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: root.page === "launcher" ? WlrKeyboardFocus.Exclusive
                                   : ((root.page === "util" && barPanel.wantsKeys) || (root.dropStack && (root.page === "util" || root.page === "notif"))) ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // ---- auto-hide: the bar slides away until the pointer touches the top edge
        property bool peek: false
        readonly property bool shown: !root.autoHide || peek || root.page !== "home"
        function peekHover(on) {
            if (on) { hideTimer.stop(); peek = true } else hideTimer.restart()
        }
        // Edge boxes = Click (Settings > Edge boxes): touching the top edge does nothing, a click on it brings the bar back
        function peekClick() { hideTimer.stop(); peek = true; clickGrace.restart() }
        Timer { id: hideTimer; interval: 700; onTriggered: win.peek = false }
        // if the pointer never reaches the bar after the click, let it go again
        Timer { id: clickGrace; interval: 2500; onTriggered: if (!hov.hovered) win.peek = false }

        mask: root.page === "launcher" ? launcherMask : ((root.notchStyle && root.page === "home") ? stripMask : normalMask)
        // while the launcher is open the window catches the pointer only over the launcher / the bar and a click-away area in the middle;
        // the left and right sides stay free, so the edge and corner spots (notifications, quick terminal, utilities, background apps) still work
        readonly property real launcherInset: Math.max(0, Math.min(pal.boxW + 60, (width - launcher.wantedWidth) / 2))
        Region { id: launcherMask; regions: [ Region { item: backdrop }, Region { item: island } ] }
        Region { id: stripMask; item: strip }
        Region { id: normalMask; regions: [ Region { item: strip }, Region { item: island } ] }

        Item {
            id: backdrop
            anchors.fill: parent
            anchors.leftMargin: win.launcherInset
            anchors.rightMargin: win.launcherInset
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
            HoverHandler { enabled: !root.clickMode; onHoveredChanged: win.peekHover(hovered) }
            TapHandler { enabled: root.clickMode; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: win.peekClick() }
        }

        // soft halo around the island; follows its size while it grows and shrinks.
        // Hollow on purpose: nothing sits under the glass, so the bar stays light.
        HaloShadow {
            anchors.fill: island
            radius: island.radius
            spread: 22
            peak: 0.18
            opacity: (win.shown && !root.notchStyle) ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        }

        // style Notch: the same silhouette as the bar, for the pages. Its halo reaches above the screen edge so only the sides and bottom show.
        HaloShadow {
            anchors.fill: island
            anchors.topMargin: -60
            radius: island.radius
            spread: 22
            peak: 0.18
            opacity: root.hangShape ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        }
        NotchShape {
            pal: pal
            earR: root.notchEar
            cornR: island.radius
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.frameT
            width: island.width + root.notchEar * 2
            height: island.height
            fillCol: root.frameOn ? pal.frameCol : Qt.alpha(pal.bg, Math.min(0.97, pal.glassBarOpen + 0.16))
            opacity: root.hangShape ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        }

        Glass {
            id: island
            pal: pal
            shadow: false           // drawn by the HaloShadow above (this item clips its content)
            flat: root.notchStyle || root.hangPage   // style Notch: the NotchShape behind it is the surface
            // light glass as the bar, a bit more solid once it grows into a page / the launcher
            opacityBody: root.page === "home" ? pal.glassBar : pal.glassBarOpen
            Behavior on opacityBody { NumberAnimation { duration: pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            anchors.top: parent.top
            anchors.topMargin: (root.notchStyle || root.hangPage) ? root.frameT : (win.shown ? root.padSet.top + root.frameT : -(height + 30))
            anchors.horizontalCenter: parent.horizontalCenter
            clip: true
            // notch style: at rest the island is not there (the notch is); the pages drop down from under it
            opacity: (root.notchStyle && root.page === "home") ? 0 : 1
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

            // with the border around the screen the pages come out of the BORDER (they grow down from nothing at the page's own width);
            // without it they grow out of the notch bar
            readonly property real pageW: root.page === "media" ? 500
                 : root.page === "perf" ? 720
                 : root.page === "fw" ? 720
                 : root.page === "cal" ? 660
                 : root.page === "util" ? root.dropW
                 : root.page === "notif" ? root.dropNotifW
                 : launcher.wantedWidth
            property real lastPageW: 500
            onPageWChanged: if (root.page !== "home") lastPageW = pageW
            width: root.page === "home" ? (root.notchStyle ? ((root.frameOn && !root.notchMorph) ? island.lastPageW : root.notchBodyW) : home.implicitWidth + root.padSet.x)
                 : root.page === "media" ? 500
                 : root.page === "perf" ? 720
                 : root.page === "fw" ? 720
                 : root.page === "cal" ? 660
                 : root.page === "util" ? root.dropW
                 : root.page === "notif" ? root.dropNotifW
                 : launcher.wantedWidth
            height: root.page === "home" ? (root.notchStyle ? ((root.frameOn && !root.notchMorph) ? 0 : root.notchBarH) : root.padSet.h)
                  : (root.page === "media" ? 156
                  : root.page === "perf" ? 316
                  : root.page === "fw" ? 330
                  : root.page === "cal" ? 356
                  : root.page === "util" ? root.dropH
                  : root.page === "notif" ? root.dropNotifH
                  : launcher.wantedHeight) + ((root.notchStyle || root.hangPage) ? root.notchPad : 0)
            radius: root.page === "home" ? (root.notchStyle ? root.notchEar : height / 2) : ((root.notchStyle || root.hangPage) ? 26 : pal.rXl)

            property real dragX: 0
            property real dragY: 0

            // one soft curve for everything: fast start, long gentle landing, no overshoot
            Behavior on anchors.topMargin { NumberAnimation { duration: root.pageMs(pal.dSlow); easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
            Behavior on width { NumberAnimation { duration: root.pageMs(pal.dSlow); easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
            Behavior on height { NumberAnimation { duration: root.pageMs(pal.dSlow); easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
            Behavior on radius { NumberAnimation { duration: root.pageMs(pal.dSlow); easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

            // swallow clicks so they don't reach the backdrop
            MouseArea { anchors.fill: parent }

            HoverHandler { id: hov; onHoveredChanged: { win.peekHover(hovered); if (hovered && root.page === "cal") island.calArmed = true } }
            // The calendar page opened by a click on the clock stays until the pointer has been on it and has left again (or the clock is
            // clicked again). Opened from the notch bar, which is another window, the pointer is not on the page yet: it must not fold away.
            property bool calArmed: false
            Connections { target: root; function onPageChanged() { island.calArmed = (root.page === "cal" && hov.hovered) } }

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
                interval: {
                    var c = root.opt.pageClose !== undefined ? root.opt.pageClose : 600
                    var l = root.opt.scrollLinger !== undefined ? root.opt.scrollLinger : 3000
                    return root.scrollOpened ? Math.max(c, l) : c
                }
                running: (root.opt.pageClose === 0 ? false : ((root.page === "media" || root.page === "perf" || root.page === "fw" || (root.page === "cal" && island.calArmed) || ((root.page === "util" || root.page === "notif") && !barPanel.wantsKeys)) && !hov.hovered && !tour.open))
                onTriggered: { root.page = "home"; root.hoverOpened = false; root.scrollOpened = false }
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
                enabled: root.page !== "launcher" && root.page !== "util" && root.page !== "notif"     // those two have their own handle (dropPage below)
                xAxis.enabled: true
                yAxis.enabled: root.dropOn
                onTranslationChanged: if (active) { island.dragX = translation.x; island.dragY = translation.y }
                onActiveChanged: {
                    if (active) return
                    var dx = island.dragX, dy = island.dragY
                    island.dragX = 0; island.dragY = 0
                    if (root.dropOn && Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 40) root.drop(dy > 0 ? 1 : -1)
                    else if (dx < -50) root.go(1)
                    else if (dx > 50) root.go(-1)
                }
            }

            // a few tiny stars drifting along the island, behind the widgets (Settings > Look > Moving stars).
            // They fade out with the home page and stop while it is not shown.
            BarStars {
                pal: pal
                active: root.page === "home"
                opacity: (root.page === "home" && !root.notchStyle) ? 1 : 0
                visible: opacity > 0.01 && win.shown && root.opt.starsBar !== false
                Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                anchors.fill: parent
                anchors.leftMargin: root.padSet.h * 0.45
                anchors.rightMargin: root.padSet.h * 0.45
                anchors.topMargin: 3
                anchors.bottomMargin: 3
            }

            // pages follow the pointer while dragging
            Item {
                id: pager
                anchors.fill: parent
                anchors.topMargin: (root.notchStyle || root.hangPage) ? root.notchPad : 0
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
                    clockAlign: root.opt.clockAlign === "text" ? "text" : "colon"
                    clockNudge: Math.round(Number(root.opt.clockNudge || 0))
                    calClock: root.opt.calOn !== false && root.opt.calClock !== false
                    onClockClicked: root.clockClicked()
                    onClockToggled: what => root.setSetting(what === "seconds" ? "opt:clockSeconds" : "clock24", what === "seconds" ? !root.opt.clockSeconds : !root.clock24)
                    showWs: root.opt.islWs !== false
                    showSpecials: root.opt.islSpecials !== false
                    wsLook: root.opt.islWsLook === "capsules" ? "capsules" : "numbers"
                    wsMin: root.opt.islWsMin || 5
                    showViz: root.opt.islViz !== false
                    showTime: root.opt.islTime !== false
                    showWifi: root.opt.islWifi !== false
                    wifiLook: root.opt.islWifiStyle || "symbol"
                    btMode: root.opt.islBtMode || "on"
                    showBat: root.opt.islBat !== false
                    showBatPct: root.opt.islBatPct !== false
                    showCaffeine: root.opt.islCaffeine !== false
                    combo: root.opt.islCombo !== false
                    spacious: root.opt.islSpacing === "spacious"
                    comboSize: Math.round(root.padSet.h * 0.55)
                    barH: root.padSet.h
                    playing: root.playing
                    activeSpecial: root.activeSpecial
                    caffeine: root.caffeine
                    focusText: root.focusState.on ? root.focusText : ""
                    focusPaused: root.focusState.on && root.focusState.paused === true
                    showStats: root.hoverAction === "stats" && hov.hovered
                    bgCount: bgPanel.count
                    showBgCount: root.opt.bgWhere !== "corner"
                    onBgClicked: appsWin.pinFor(9000)
                    opacity: root.page === "home" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                    onStatusPopup: (kind, item) => root.homeStatusPopup(kind, item)
                    onStatusClicked: {
                        if (root.dropOn) root.dropShow("util")
                        else root.page = (root.page === "perf" ? "home" : "perf")
                    }
                    onWorkspaceClicked: n => root.hypr("hl.dsp.focus({ workspace = " + n + " })")
                    onWorkspaceScrolled: d => Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/ws-nav.sh", d > 0 ? "wheel-up" : "wheel-down"])
                    onSpecialClicked: name => root.toggleSpecial(name)
                }

                MediaPage {
                    anchors.fill: parent
                    pal: pal
                    player: root.player
                    onOpenMusic: tab => {
                        clipMenu.hide(); shotMenu.hide()
                        root.page = "home"             // the island folds back; the panel opens on the side
                        musicMenu.show(tab)
                    }
                    opacity: root.page === "media" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                }

                PerfTab {
                    width: 704
                    height: 316
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
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
                    look: root.perfLookNow
                    active: root.page === "perf"
                    opacity: root.page === "perf" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                    onToggleWifi: root.toggleWifi()
                    onToggleBt: root.toggleBt()
                    onSetProfile: p => root.setProfile(p)
                    onSetAuto: root.setAuto()
                }

                // ---- the firewall page (`qs ipc call island firewall`): what ai-firewall is doing right now
                FwPage {
                    anchors.fill: parent
                    pal: pal
                    onConsoleRequested: cmd => { root.page = "home"; quickTerm.run(cmd) }
                    active: root.page === "fw"
                    opacity: root.page === "fw" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                }

                // ---- the calendar page: the bar clock drops it out of the bar (Settings > Calendar > Clock click)
                CalPage {
                    anchors.fill: parent
                    pal: pal
                    cal: calendar
                    notchStyle: root.notchStyle || root.hangPage
                    opacity: root.page === "cal" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                    onOpenFull: { root.page = "home"; calendar.show() }
                }

                // ---- drop-down pages (Settings > Bar > Drag the bar down): the utilities box and the notifications
                //   Swipe pages:   a header (arrows + two tabs) over two pages that slide: swipe, tap an arrow / tab, or press Left / Right
                //   Side by side:  both boxes at once
                Item {
                    id: dropPage
                    anchors.fill: parent
                    opacity: (root.page === "util" || root.page === "notif") ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }

                    // where the pages are: 0 = utilities, 1 = notifications. It keeps its place while the drop-down folds away.
                    property real slideTo: 0
                    property real slide: slideTo
                    Behavior on slide { enabled: !swipe.active && dropPage.opacity > 0.5; NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
                    // how far the finger has pulled it, in pages
                    property real swipeN: 0
                    Behavior on swipeN { enabled: !swipe.active; NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
                    readonly property real pos: root.dropStack ? Math.max(-0.12, Math.min(1.12, slide + swipeN)) : 0
                    readonly property real posC: Math.max(0, Math.min(1, pos))
                    readonly property real pitch: pal.boxW + root.dropPad * 2        // one page to the next

                    Connections {
                        target: root
                        function onPageChanged() {
                            if (root.page === "util") dropPage.slideTo = 0
                            else if (root.page === "notif") dropPage.slideTo = 1
                        }
                    }

                    // hold and drag sideways: turn the page. It does not take a drag away from a slider (items keep theirs).
                    DragHandler {
                        id: swipe
                        target: null
                        enabled: root.dropStack
                        xAxis.enabled: true
                        yAxis.enabled: false
                        grabPermissions: PointerHandler.CanTakeOverFromHandlersOfDifferentType | PointerHandler.ApprovesTakeOverByAnything
                        onTranslationChanged: if (active) dropPage.swipeN = -translation.x / dropPage.pitch
                        onActiveChanged: {
                            if (active) return
                            var n = dropPage.swipeN
                            dropPage.swipeN = 0
                            if (n > 0.16) root.dropGo(1)
                            else if (n < -0.16) root.dropGo(-1)
                        }
                    }
                    // Left / Right (click the drop-down once so it has the keyboard; not while the Wi-Fi password is being typed)
                    Shortcut { sequence: "Left"; enabled: root.dropStack && root.page === "notif"; onActivated: root.dropGo(-1) }
                    Shortcut { sequence: "Right"; enabled: root.dropStack && root.page === "util" && !barPanel.wantsKeys; onActivated: root.dropGo(1) }

                    DropHeader {
                        visible: root.dropStack
                        pal: pal
                        anchors.top: parent.top
                        anchors.topMargin: root.dropPad
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: pal.boxW
                        height: root.dropHdrH
                        pos: dropPage.pos
                        unread: notifs.unread
                        dnd: root.dnd
                        onStep: dir => root.dropGo(dir)
                        onPick: i => root.dropGo(i === 1 ? 1 : -1)
                    }

                    Item {
                        id: dropView
                        anchors.top: parent.top
                        anchors.topMargin: root.dropPad + root.dropHdr
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: root.dropHandleH
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: root.dropSide ? pal.boxW * 2 + root.dropPad : pal.boxW
                        clip: root.dropStack

                        Row {
                            id: dropRow
                            x: root.dropStack ? -dropPage.pos * dropPage.pitch : 0
                            spacing: root.dropStack ? root.dropPad * 2 : root.dropPad

                            Item {
                                id: paneUtil
                                width: pal.boxW
                                height: barPanel.implicitHeight
                                // the page you are leaving fades and shrinks a little
                                opacity: root.dropStack ? 1 - dropPage.posC * 0.85 : 1
                                scale: root.dropStack ? 1 - dropPage.posC * 0.04 : 1

                                Panel {
                                    id: barPanel
                                    visible: root.dropStack ? dropPage.posC < 0.99 : root.page === "util"
                                    flat: true
                                    shadow: false
                                    pal: pal
                                    active: root.page === "util"
                                    stats: root.stats
                                    net: root.net
                                    profile: root.profile
                                    autoPower: root.autoPower
                                    autoHide: root.autoHide
                                    gaming: root.gaming
                                    caffeine: root.caffeine
                                    focusInfo: root.focusState
                                    focusText: root.focusText
                                    focusSecs: root.focusLeft
                                    focusMins: root.focusConf.LENGTH
                                    focusPomo: root.focusConf.POMODORO
                                    focusBlocked: (root.focusConf.apps || []).length
                                    mic: root.mic
                                    micMuted: root.micMuted
                                    vol: root.vol
                                    muted: root.muted
                                    bright: root.bright
                                    cfg: root.opt

                                    onToggleWifi: root.toggleWifi()
                                    onToggleBt: root.toggleBt()
                                    onSetProfile: p => root.setProfile(p)
                                    onSetAuto: root.setAuto()
                                    onOpenSettings: settingsWin.show()
                                    onToggleGaming: root.setGaming(!root.gaming)
                                    onToggleCaffeine: root.setCaffeine(!root.caffeine, 0)
                                    onFocusStart: (mins, pomo) => root.focusRun(["start", String(mins), pomo ? "pomo" : "single"])
                                    onFocusCommand: what => root.focusRun(what.split(" "))
                                    onFocusPick: (mins, pomo) => root.focusSet(mins, pomo)
                                    onOpenFocusSettings: settingsWin.show("focus")
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

                            Item {
                                id: paneNotif
                                width: pal.boxW
                                height: barNotifs.implicitHeight
                                opacity: root.dropStack ? 0.15 + dropPage.posC * 0.85 : 1
                                scale: root.dropStack ? 0.96 + dropPage.posC * 0.04 : 1

                                NotifCentre {
                                    id: barNotifs
                                    visible: root.dropStack ? dropPage.posC > 0.01 : root.page === "util"
                                    pal: pal
                                    notifs: notifs
                                    active: visible && (!root.dropStack || dropPage.posC > 0.5)
                                }
                            }
                        }
                    }

                    // the handle: tap it or drag it up to fold the drop-down back into the bar (drag the bar down to open it)
                    Item {
                        id: dropHandle
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 160
                        height: root.dropHandleH + 8
                        property real dy: 0
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 8
                            width: 28
                            height: 4
                            radius: 2
                            color: pal.accent
                        }
                        TapHandler { onTapped: root.dropStep() }
                        DragHandler {
                            target: null
                            xAxis.enabled: false
                            yAxis.enabled: true
                            onTranslationChanged: if (active) dropHandle.dy = translation.y
                            onActiveChanged: {
                                if (active) return
                                var d = dropHandle.dy
                                dropHandle.dy = 0
                                if (d > 30) root.drop(1)
                                else if (d < -30) root.drop(-1)
                            }
                        }
                    }
                }
            }

            Launcher {
                id: launcher
                // fixed at the FINAL size and pinned to the top: the pill grows over it like a curtain. With
                // anchors.fill the whole grid was re-laid out on every frame of the grow animation (that was the roughness).
                anchors.top: parent.top
                anchors.topMargin: 22 + ((root.notchStyle || root.hangPage) ? root.notchPad : 0)
                anchors.horizontalCenter: parent.horizontalCenter
                width: launcher.wantedWidth - 44
                height: launcher.wantedHeight - 44
                pal: pal
                runningGame: root.gameId
                firewallInstalled: root.fwInstalled
                antivirusInstalled: root.avInstalled
                active: root.page === "launcher"
                opacity: root.page === "launcher" ? 1 : 0
                visible: opacity > 0.01
                // instant, fluid fade without lagging pauses
                Behavior on opacity {
                    NumberAnimation {
                        duration: root.page === "launcher" ? root.pageMs(160) : 120
                        easing.type: Easing.OutCubic
                    }
                }
                onCloseRequested: root.page = "home"
                onCommandRequested: c => root.runCommand(c)
            }
        }
    }

    // =====================================================================
    //  TOP, style "Notch": a bar hanging from the top edge (NotchBar.qml). The island above keeps the pages and the launcher.
    // =====================================================================
    // style Notch: the pages (media / performance / launcher) hang from the top edge in the same notch silhouette and grow out of the bar
    readonly property int notchBarH: ({ low: 26, normal: 32, high: 40 })[barPadding] || 32
    readonly property real notchEar: Math.round(notchBarH * 0.42)
    // The pages have 22 px of padding inside already. Here they sit right under the screen edge, so that is cut by 8 px (14 px left on top,
    // 22 px at the bottom). Negative = less room above the content. 0 would give the full 22 px, -14 would leave 8 px.
    readonly property int notchPad: -8
    // a page (launcher / media / performance / calendar ...) that is open hangs from the top border in the notch silhouette: always in the
    // Notch / Custom / Off styles, and with the border around the screen also in the Island style (it used to open as a floating box
    // under the pill, not attached to the border)
    readonly property bool hangPage: (notchStyle || frameOn) && page !== "home"
    // the silhouette is drawn while a page hangs, and (Notch / Custom / Off with the border) while it is still folding back into the border
    readonly property bool hangShape: hangPage || (frameOn && notchStyle && island.height > (notchMorph ? notchBarH + 2 : 2))
    // With a notch bar on the top edge the page is the notch itself growing into the page (and shrinking back into the bar): at rest the
    // silhouette has the bar's size, so nothing is laid over the notch. Without it (rail / bar on another edge / no bar) the page grows out
    // of the border as before.
    readonly property bool notchMorph: notchStyle && (opt.barStyle === "notch" || (opt.barStyle === "custom" && customBarLoader.item !== null && customBarLoader.item.side === "top" && !customBarLoader.item.rail))
    property real notchBodyW: 260                   // width of the bar (set by NotchBar)
    // hovering the notch opens perf / media after a moment (Settings > Bar > When you hover the bar), like hovering the island
    Timer {
        interval: 350
        running: root.notchStyle && !root.railOn && root.notchHovered && root.page === "home" && !island.hoverSpent && (root.hoverAction === "perf" || root.hoverAction === "media")
        onTriggered: { root.hoverOpened = true; root.page = root.hoverAction }
    }
    onNotchHoveredChanged: if (!notchHovered) island.hoverSpent = false
    LazyLoader {
        active: root.opt.barStyle === "notch"
        NotchBar {
            pal: root.palObj
            stats: root.stats
            net: root.net
            cava: root.cava
            playing: root.playing
            activeSpecial: root.activeSpecial
            caffeine: root.caffeine
            focusText: root.focusState.on ? root.focusText : ""
            focusPaused: root.focusState.on && root.focusState.paused === true
            bgCount: bgPanel.count
            opt: root.opt
            barPadding: root.barPadding
            autoHide: root.autoHide
            clickMode: root.clickMode
            clock24: root.clock24
            gaps: root.gaps
            frameT: root.frameT
            Component.onCompleted: root.notchBodyW = bodyWidth
            onBodyWidthChanged: root.notchBodyW = bodyWidth
            showStats: root.hoverAction === "stats" && root.notchHovered
            pageOpen: root.page !== "home"
            onWorkspaceClicked: n => root.hypr("hl.dsp.focus({ workspace = " + n + " })")
            onWorkspaceScrolled: d => Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/ws-nav.sh", d > 0 ? "wheel-up" : "wheel-down"])
            onSpecialClicked: name => root.toggleSpecial(name)
            onStatusClicked: {
                if (root.dropOn) root.dropShow("util")
                else root.page = (root.page === "perf" ? "home" : "perf")
            }
            onStatusPopup: (kind, along, edge) => root.popStatus(kind, "top", along, edge)
            onClockClicked: root.clockClicked()
            onClockToggled: what => root.setSetting(what === "seconds" ? "opt:clockSeconds" : "clock24", what === "seconds" ? !root.opt.clockSeconds : !root.clock24)
            onBgClicked: appsWin.pinFor(9000)
            onPageDrop: dir => root.drop(dir)
            onPageStep: dir => root.go(dir)
            onHoverEdited: on => root.notchHovered = on
        }
    }

    // the border around the screen (Settings > Bar style): drawn above the boxes so they come out from under it
    ScreenFrame {
        pal: root.palObj
        skip: (root.opt.barStyle === "custom" || root.opt.barStyle === "rail") ? root.barSide : ""      // the custom/rail bar reserves the border's width on its own edge
        on: root.frameOn
        t: root.frameT
        r: root.frameR
        bandSide: customBarLoader.item ? customBarLoader.item.bandSide : ""       // a rail draws the border's width on its own edge
        hidden: root.fsQuiet
    }

    // style Custom / Rail: the bar with the widgets and places picked in Settings > Bar style > Bar builder
    LazyLoader {
        id: customBarLoader
        active: root.opt.barStyle === "custom" || root.opt.barStyle === "rail"
        CustomBar {
            pal: root.palObj
            stats: root.stats
            net: root.net
            cava: root.cava
            playing: root.playing
            activeSpecial: root.activeSpecial
            caffeine: root.caffeine
            numLock: root.numLock
            focusText: root.focusState.on ? root.focusText : ""
            focusPaused: root.focusState.on && root.focusState.paused === true
            bgCount: bgPanel.count
            opt: root.opt
            barPadding: root.barPadding
            autoHide: root.autoHide
            clickMode: root.clickMode
            clock24: root.clock24
            gaps: root.gaps
            frameT: root.frameT
            Component.onCompleted: root.notchBodyW = bodyWidth
            onBodyWidthChanged: root.notchBodyW = bodyWidth
            showStats: root.hoverAction === "stats" && root.notchHovered
            pageOpen: root.page !== "home"
            onWorkspaceClicked: n => root.hypr("hl.dsp.focus({ workspace = " + n + " })")
            onWorkspaceScrolled: d => Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/ws-nav.sh", d > 0 ? "wheel-up" : "wheel-down"])
            onSpecialClicked: name => root.toggleSpecial(name)
            onStatusClicked: {
                if (root.dropOn) root.dropShow("util")
                else root.page = (root.page === "perf" ? "home" : "perf")
            }
            onClockClicked: root.clockClicked()
            onClockToggled: what => root.setSetting(what === "seconds" ? "opt:clockSeconds" : "clock24", what === "seconds" ? !root.opt.clockSeconds : !root.clock24)
            onBgClicked: appsWin.pinFor(9000)
            onBgPopup: (along, edge) => root.popBg(side, along, edge)
            onNumLockClicked: root.toggleNumLock()
            onLogoClicked: root.toggleLauncher()
            onPowerClicked: powerMenu.show()
            onStatusPopup: (kind, along, edge) => root.popStatus(kind, side, along, edge)
            onPageDrop: dir => root.drop(dir)
            onPageStep: dir => { if (!rail) root.go(dir) }
            onHoverEdited: on => root.notchHovered = on
        }
    }

    // a rail's own window ignores the zones of other windows (so it reaches the border); this reserves its room
    RailReserve {
        on: customBarLoader.item !== null && customBarLoader.item.rail === true
        side: customBarLoader.item ? customBarLoader.item.side : "left"
        zone: customBarLoader.item ? customBarLoader.item.zoneWanted : 0
    }

    // place the desktop widgets right on the screen (DesktopEditor.qml)
    LazyLoader {
        active: root.deskEditing
        DesktopEditor {
            pal: root.palObj
            env: root
            opt: root.opt
            open: root.deskEditing
            target: root.deskEditTarget
            topInset: root.deskEditTarget === "lock" ? 24 : root.deskTop
            roomLeft: root.deskLeft; roomRight: root.deskRight; roomBottom: root.deskBottom
            onTargetPicked: t => root.deskEditTarget = (t === "lock") ? "lock" : "desktop"
            onCommit: d => root.setOpt(WD.keyOf(root.deskEditTarget), d)
            onOptToggled: (k, v) => root.setOpt(k, v)
            onDone: root.deskEditing = false
            onOpenWidget: uid => { root.deskEditing = false; settingsWin.openWidgetBuilder(uid, root.deskEditTarget) }
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
                gestureActive: root.gestureActive && root.gestureTarget === "overview"
                gestureProgress: root.gestureProgress
                gestureScale: root.gestureScale
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
        visible: !root.dropOn && !root.startHold       // the drop-down (Settings > Bar > Drag the bar down) replaces this box

        // the corner it opens from (Desktop builder > Where the boxes open): default bottom-right
        readonly property string spot: root.boxSpots.util
        // it opens from the tag you dragged in the Desktop builder (any edge, anywhere along it); with no tag, from its corner
        readonly property var org: DS.originOf(root.opt, "util", spot)
        readonly property bool atR: org.atR
        readonly property bool atB: org.atB
        readonly property bool oSide: org.custom && org.side        // out of the left / right edge, at offY down it
        readonly property bool oVert: org.custom && !org.side       // out of the top / bottom edge, at offX along it
        readonly property real oMargin: root.frameOn ? root.frameT + 12 : 16
        readonly property real offY: oSide ? DS.along(org.pos, corner.height, panel.height + 30, oMargin) : 0
        readonly property real offX: oVert ? DS.along(org.pos, corner.width, panel.width + 30, oMargin) : 0
        // a box on a side edge uses the whole height of the screen, one on the top / bottom edge the whole width (the mask keeps the rest click-through)
        anchors { top: corner.oSide ? true : !corner.atB; bottom: corner.oSide ? true : corner.atB; left: corner.oVert ? true : !corner.atR; right: corner.oVert ? true : corner.atR }
        // FIXED size on purpose: it used to grow / shrink with the box (48 px tab <-> full size). Each resize made the compositor
        // re-pick the pointer focus, so a pointer parked in the corner got a leave + enter, which closed and re-opened the box
        // over and over. The input region (mask below) is what keeps the surface from catching clicks while it is closed.
        property bool cornerLinger: false
        property bool pinnedOpen: false     // opened from a keybind / the launcher (pinFor), not by hovering the corner
        onOpenChanged: {
            if (open) { cornerLinger = true; cornerLingerT.stop() }
            else { pinnedOpen = false; cornerLingerT.restart() }
        }
        Timer { id: cornerLingerT; interval: 900; onTriggered: { corner.cornerLinger = false; gc() } }
        // fixed size (see the note above): never resized, so opening / closing never makes the compositor re-send enter / leave
        // (wide enough for the Focus card that opens beside the box; the mask below keeps that room click-through until it is shown)
        implicitWidth: pal.boxW + pal.boxEdge + 30 + panel.flyExtra
        implicitHeight: 1000
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.namespace: "island-panel"
        WlrLayershell.layer: WlrLayer.Top
        // only the Wi-Fi password field needs keys; click it to focus
        WlrLayershell.keyboardFocus: panel.wantsKeys ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        property bool hovering: false
        property bool zoneHover: false      // pointer in the corner / gap zone
        property bool panelHover: false     // pointer on the panel itself (its chips and sliders take hover away from the zone)
        property bool extHover: false      // the wake spot (ActivationZone) has the pointer
        function syncHover() { setHover(zoneHover || panelHover || extHover) }
        readonly property bool open: hovering
        readonly property real reveal: hovering ? 1 : 0
        // hover mode: touching the corner opens it and leaving closes it. click mode: click the corner to open / close it.
        // auto-hide on closes it when the pointer leaves, in both modes
        // after it closes, a pointer that is still sitting in the corner must not re-open it by itself: enter events that come from
        // the box shrinking back are ignored for a moment (move out and in again to open it)
        property double blockUntil: 0
        function setHover(on) {
            if (on) { closeT.stop(); if (!root.utilClick && !root.fsQuiet && Date.now() >= blockUntil) hovering = true }
            else if (!panel.wantsKeys && (!root.utilClick || root.autoHide)) { closeT.interval = 450; closeT.restart() }
        }
        // open it from the launcher / keybind; closes by itself if you don't touch it
        function pinFor(ms) { hovering = true; pinnedOpen = true; closeT.interval = (ms < 60000 && root.opt && root.opt.cornerTimeout) ? root.opt.cornerTimeout : ms; closeT.restart() }
        Timer { id: closeT; interval: 450; onTriggered: { corner.hovering = false; corner.blockUntil = Date.now() + 600 } }

        // one hover zone for corner + panel (see QuickTerm.qml): no flicker when the panel slides in under the pointer
        mask: Region { item: zone }
        Item {
            id: zone
            anchors.right: corner.atR ? parent.right : undefined
            anchors.left: corner.atR ? undefined : parent.left
            anchors.bottom: corner.atB ? parent.bottom : undefined
            anchors.top: corner.atB ? undefined : parent.top
            anchors.topMargin: corner.oSide ? corner.offY : (corner.open ? 0 : root.insT)
            anchors.leftMargin: corner.oVert ? corner.offX : (corner.open ? 0 : root.insL)
            anchors.rightMargin: corner.open ? 0 : root.insR
            anchors.bottomMargin: corner.open ? 0 : root.insB
            width: corner.open ? panel.width + pal.boxEdge + 30 + (panel.flyShown ? panel.flyExtra : 0) : ((root.fsQuiet || root.boxZones.util) ? 0 : (root.utilClick ? 28 : 12))
            height: corner.open ? panel.height + pal.boxEdge + 30 : ((root.fsQuiet || root.boxZones.util) ? 0 : (root.utilClick ? 28 : 12))
            HoverHandler { onHoveredChanged: { corner.zoneHover = hovered; corner.syncHover() } }
            Rectangle {
                visible: root.utilClick && !corner.open
                anchors.right: corner.atR ? parent.right : undefined
                anchors.left: corner.atR ? undefined : parent.left
                anchors.bottom: corner.atB ? parent.bottom : undefined
                anchors.top: corner.atB ? undefined : parent.top
                anchors.rightMargin: 3; anchors.leftMargin: 3; anchors.bottomMargin: 3; anchors.topMargin: 3
                width: 12; height: 12; radius: 6
                color: Qt.alpha(pal.accent, 0.35)
            }
            Item {
                anchors.right: corner.atR ? parent.right : undefined
                anchors.left: corner.atR ? undefined : parent.left
                anchors.bottom: corner.atB ? parent.bottom : undefined
                anchors.top: corner.atB ? undefined : parent.top
                width: 20; height: 20
                TapHandler {
                    enabled: root.utilClick
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: { if (corner.hovering) { closeT.stop(); corner.hovering = false } else { closeT.stop(); corner.hovering = true } }
                }
            }
        }

        Panel {
            id: panel
            anchors.right: corner.atR ? parent.right : undefined
            anchors.left: corner.atR ? undefined : parent.left
            anchors.bottom: corner.atB ? parent.bottom : undefined
            anchors.top: corner.atB ? undefined : parent.top
            // border around the screen: flush with it (and flaring into it), emerging from under it
            anchors.rightMargin: root.frameOn ? root.frameT : pal.boxEdge; anchors.leftMargin: corner.oVert ? corner.offX : (root.frameOn ? root.frameT : pal.boxEdge)
            anchors.bottomMargin: root.frameOn ? root.frameT : pal.boxEdge
            anchors.topMargin: corner.oSide ? corner.offY : (corner.oVert ? (root.frameOn ? root.frameT : pal.boxTop) : (root.cornerOut ? root.frameT : pal.boxTop))
            joinH: root.frameOn ? (corner.oVert ? "" : (corner.atR ? "r" : "l")) : ""
            joinV: root.frameOn ? (corner.oSide ? "" : (corner.oVert ? (corner.atB ? "b" : "t") : (corner.atB ? "b" : (root.cornerOut ? "t" : "")))) : ""
            pal: pal
            active: corner.open
            stats: root.stats
            net: root.net
            profile: root.profile
            autoPower: root.autoPower
            autoHide: root.autoHide
            gaming: root.gaming
            caffeine: root.caffeine
            focusInfo: root.focusState
            focusText: root.focusText
            focusSecs: root.focusLeft
            focusMins: root.focusConf.LENGTH
            focusPomo: root.focusConf.POMODORO
            focusBlocked: (root.focusConf.apps || []).length
            mic: root.mic
            micMuted: root.micMuted
            vol: root.vol
            muted: root.muted
            bright: root.bright
            cfg: root.opt
            // Focus opens as its own card beside the box (toward the middle of the screen) rather than unfolding inside it
            flyout: true
            flyLeft: corner.atR
            flyBottom: corner.atB

            // hovering anything inside the panel (or its Focus card) keeps the whole box open (same idea as the notification centre)
            HoverHandler { id: panelHH; onHoveredChanged: { corner.panelHover = hovered || panel.flyHovered; corner.syncHover() } }
            onFlyHoveredChanged: { corner.panelHover = panelHH.hovered || panel.flyHovered; corner.syncHover() }

            // with the border: no fade / zoom, the box slides out from under the border it is attached to
            property real slide: corner.reveal
            Behavior on slide { NumberAnimation { duration: corner.open ? pal.dSlow : pal.dClose; easing.type: Easing.BezierSpline; easing.bezierCurve: corner.open ? pal.curve : pal.curveClose } }
            opacity: root.frameOn ? 1 : corner.reveal
            visible: root.frameOn ? slide > 0.002 : opacity > 0.01
            scale: root.frameOn ? 1 : 0.97 + 0.03 * corner.reveal
            transform: Translate {
                x: (root.frameOn && !corner.oVert) ? (corner.atR ? 1 : -1) * (1 - panel.slide) * (panel.width + root.frameT + 30) : 0
                // out of the corner: along the top / bottom border too; out of a top / bottom edge it slides along its height instead
                y: (corner.oVert ? root.frameOn : (root.cornerOut && !corner.oSide)) ? (corner.atB ? 1 : -1) * (1 - panel.slide) * (panel.height + root.frameT + 30) : 0
            }
            transformOrigin: corner.oSide ? (corner.atR ? Item.Right : Item.Left) : corner.oVert ? (corner.atB ? Item.Bottom : Item.Top)
                           : (corner.atB ? (corner.atR ? Item.BottomRight : Item.BottomLeft) : (corner.atR ? Item.TopRight : Item.TopLeft))
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on scale { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

            onToggleWifi: root.toggleWifi()
            onToggleBt: root.toggleBt()
            onSetProfile: p => root.setProfile(p)
            onSetAuto: root.setAuto()
            onOpenSettings: settingsWin.show()
            onToggleGaming: root.setGaming(!root.gaming)
            onToggleCaffeine: root.setCaffeine(!root.caffeine, 0)
            onFocusStart: (mins, pomo) => root.focusRun(["start", String(mins), pomo ? "pomo" : "single"])
            onFocusCommand: what => root.focusRun(what.split(" "))
            onFocusPick: (mins, pomo) => root.focusSet(mins, pomo)
            onOpenFocusSettings: settingsWin.show("focus")
            onCaffeineHour: root.setCaffeine(true, 60)
            onOpenApps: appsWin.pinFor(9000)
            onOpenPower: powerMenu.show()
            onToggleMute: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            onToggleMic: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
            onMicMoved: v => { root.pendMic = v; root.mic = v * 100; if (!sliderT.running) sliderT.start() }
            onVolumeMoved: v => { root.pendVol = v; root.vol = v * 100; if (!sliderT.running) sliderT.start() }
            onBrightnessMoved: v => { root.pendBright = v; root.bright = v * 100; if (!sliderT.running) sliderT.start() }
            extraDim: root.opt && root.opt.extraDim === true
            onExtraDimToggled: root.toggleExtraDim()
            isRecording: root.isRecording
            onToggleRecord: root.toggleRecording()
        }
    }

    property bool isRecording: false
    Process {
        id: recStatusProc
        command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/screen-record.sh", "status"]
        stdout: StdioCollector { onStreamFinished: root.isRecording = (text.trim() === "recording") }
    }
    Timer {
        id: recPollTimer
        interval: 3000
        repeat: true
        running: root.isRecording
        onTriggered: recStatusProc.running = true
    }

    function toggleRecording() {
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/screen-record.sh", "toggle"])
        recCheckT.restart()
    }
    Timer { id: recCheckT; interval: 600; onTriggered: recStatusProc.running = true }

    function toggleExtraDim() {
        var next = !(root.opt && root.opt.extraDim === true)
        root.setSetting("opt:extraDim", next)
        Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/extra-dim.sh", next ? "on" : "off"])
    }

    // =====================================================================
    //  BOTTOM-LEFT: background apps (Spotify, Discord ... that keep running without a window): open / quit them
    // =====================================================================
    PanelWindow {
        id: appsWin
        visible: !root.startHold

        // the corner it opens from (Desktop builder > Where the boxes open): default bottom-left
        readonly property string spot: root.boxSpots.apps
        // opens from its tag (any edge, anywhere along it); with no tag, from its corner (see the utilities box)
        readonly property var org: DS.originOf(root.opt, "apps", spot)
        readonly property bool atR: org.atR
        readonly property bool atB: org.atB
        readonly property bool oSide: org.custom && org.side
        readonly property bool oVert: org.custom && !org.side
        readonly property real oMargin: root.frameOn ? root.frameT + 12 : 16
        readonly property real offY: oSide ? DS.along(org.pos, appsWin.height, bgPanel.height + 30, oMargin) : 0
        readonly property real offX: oVert ? DS.along(org.pos, appsWin.width, bgPanel.width + 30, oMargin) : 0
        anchors { top: appsWin.oSide ? true : !appsWin.atB; bottom: appsWin.oSide ? true : appsWin.atB; left: appsWin.oVert ? true : !appsWin.atR; right: appsWin.oVert ? true : appsWin.atR }
        // fixed size, see the utilities box (a surface that resizes under a parked pointer makes the box flicker)
        property bool appsLinger: false
        property bool pinnedOpen: false     // opened by the Apps button / a command (pinFor), not by hovering the corner
        onOpenChanged: {
            if (open) { appsLinger = true; appsLingerT.stop() }
            else { pinnedOpen = false; appsLingerT.restart() }
        }
        Timer { id: appsLingerT; interval: 900; onTriggered: { appsWin.appsLinger = false; gc() } }
        // fixed size: a resize re-sends enter / leave and made the box open and close by itself; the mask keeps it click-through
        implicitWidth: pal.boxW + pal.boxEdge + 30
        implicitHeight: 700
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.namespace: "island-apps"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // same open / close behaviour as the utilities box in the opposite corner (hover or click, see Edge boxes)
        property bool hovering: false
        property bool zoneHover: false
        property bool panelHover: false
        property bool extHover: false      // the wake spot (ActivationZone) has the pointer
        function syncHover() { setHover(zoneHover || panelHover || extHover) }
        readonly property bool open: hovering
        readonly property real reveal: hovering ? 1 : 0
        property double blockUntil: 0
        function setHover(on) {
            if (on) { aClose.stop(); if (!root.appsClick && !root.fsQuiet && Date.now() >= blockUntil) hovering = true }
            else if (!root.appsClick || root.autoHide) { aClose.interval = 450; aClose.restart() }
        }
        function pinFor(ms) { hovering = true; pinnedOpen = true; aClose.interval = ms; aClose.restart() }
        Timer { id: aClose; interval: 450; onTriggered: { appsWin.hovering = false; appsWin.blockUntil = Date.now() + 600 } }

        mask: Region { item: aZone }
        Item {
            id: aZone
            anchors.right: appsWin.atR ? parent.right : undefined
            anchors.left: appsWin.atR ? undefined : parent.left
            anchors.bottom: appsWin.atB ? parent.bottom : undefined
            anchors.top: appsWin.atB ? undefined : parent.top
            anchors.topMargin: appsWin.oSide ? appsWin.offY : (appsWin.open ? 0 : root.insT)
            anchors.leftMargin: appsWin.oVert ? appsWin.offX : (appsWin.open ? 0 : root.insL)
            anchors.rightMargin: appsWin.open ? 0 : root.insR
            anchors.bottomMargin: appsWin.open ? 0 : root.insB
            // a rail has the background-apps icon (BgPop): no corner spot for it
            width: appsWin.open ? bgPanel.width + pal.boxEdge + 30 : ((root.fsQuiet || root.railOn || root.boxZones.apps) ? 0 : (root.appsClick ? 28 : 12))
            height: appsWin.open ? bgPanel.height + pal.boxEdge + 30 : ((root.fsQuiet || root.railOn || root.boxZones.apps) ? 0 : (root.appsClick ? 28 : 12))
            HoverHandler { onHoveredChanged: { appsWin.zoneHover = hovered; appsWin.syncHover() } }
            Rectangle {
                visible: root.appsClick && !appsWin.open
                anchors.right: appsWin.atR ? parent.right : undefined
                anchors.left: appsWin.atR ? undefined : parent.left
                anchors.bottom: appsWin.atB ? parent.bottom : undefined
                anchors.top: appsWin.atB ? undefined : parent.top
                anchors.rightMargin: 3; anchors.leftMargin: 3; anchors.bottomMargin: 3; anchors.topMargin: 3
                width: 12; height: 12; radius: 6
                color: Qt.alpha(pal.accent, 0.35)
            }
            Item {
                anchors.right: appsWin.atR ? parent.right : undefined
                anchors.left: appsWin.atR ? undefined : parent.left
                anchors.bottom: appsWin.atB ? parent.bottom : undefined
                anchors.top: appsWin.atB ? undefined : parent.top
                width: 20; height: 20
                TapHandler {
                    enabled: root.appsClick
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: { aClose.stop(); appsWin.hovering = !appsWin.hovering }
                }
            }
        }

        // apps alive in the background: a small dot on the corner while the box is closed (the box itself lists them)
        Item {
            visible: bgPanel.count > 0 && !appsWin.open && !root.railOn && root.opt.bgWhere === "corner"
            anchors.right: appsWin.atR ? parent.right : undefined
            anchors.left: appsWin.atR ? undefined : parent.left
            anchors.bottom: appsWin.atB ? parent.bottom : undefined
            anchors.top: appsWin.atB ? undefined : parent.top
            anchors.rightMargin: 6 + root.insR; anchors.leftMargin: 6 + (appsWin.oVert ? appsWin.offX : root.insL); anchors.bottomMargin: 6 + root.insB; anchors.topMargin: 6 + (appsWin.oSide ? appsWin.offY : root.insT)
            width: 11
            height: 11

            // soft glow ring
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: height / 2
                color: Qt.alpha(pal.accent, 0.28)
            }

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: Qt.alpha(pal.surface, 0.92)
                border.width: 1.5
                border.color: Qt.alpha(pal.accent, 0.75)
            }

            Rectangle {
                anchors.centerIn: parent
                width: 5; height: 5; radius: 2.5
                color: pal.accent
            }
        }

        BgApps {
            id: bgPanel
            anchors.right: appsWin.atR ? parent.right : undefined
            anchors.left: appsWin.atR ? undefined : parent.left
            anchors.bottom: appsWin.atB ? parent.bottom : undefined
            anchors.top: appsWin.atB ? undefined : parent.top
            // border around the screen: flush with it (and flaring into it), emerging from under it
            anchors.rightMargin: root.frameOn ? root.frameT : pal.boxEdge; anchors.leftMargin: appsWin.oVert ? appsWin.offX : (root.frameOn ? root.frameT : pal.boxEdge)
            anchors.bottomMargin: root.frameOn ? root.frameT : pal.boxEdge
            anchors.topMargin: appsWin.oSide ? appsWin.offY : (appsWin.oVert ? (root.frameOn ? root.frameT : pal.boxTop) : (root.cornerOut ? root.frameT : pal.boxTop))
            joinH: root.frameOn ? (appsWin.oVert ? "" : (appsWin.atR ? "r" : "l")) : ""
            joinV: root.frameOn ? (appsWin.oSide ? "" : (appsWin.oVert ? (appsWin.atB ? "b" : "t") : (appsWin.atB ? "b" : (root.cornerOut ? "t" : "")))) : ""
            pal: pal
            active: appsWin.open

            HoverHandler { onHoveredChanged: { appsWin.panelHover = hovered; appsWin.syncHover() } }

            property real slide: appsWin.reveal
            Behavior on slide { NumberAnimation { duration: appsWin.open ? pal.dSlow : pal.dClose; easing.type: Easing.BezierSpline; easing.bezierCurve: appsWin.open ? pal.curve : pal.curveClose } }
            opacity: root.frameOn ? 1 : appsWin.reveal
            visible: root.frameOn ? slide > 0.002 : opacity > 0.01
            scale: root.frameOn ? 1 : 0.97 + 0.03 * appsWin.reveal
            transform: Translate {
                x: (root.frameOn && !appsWin.oVert) ? (appsWin.atR ? 1 : -1) * (1 - bgPanel.slide) * (bgPanel.width + root.frameT + 30) : 0
                y: (appsWin.oVert ? root.frameOn : (root.cornerOut && !appsWin.oSide)) ? (appsWin.atB ? 1 : -1) * (1 - bgPanel.slide) * (bgPanel.height + root.frameT + 30) : 0
            }
            transformOrigin: appsWin.oSide ? (appsWin.atR ? Item.Right : Item.Left) : appsWin.oVert ? (appsWin.atB ? Item.Bottom : Item.Top)
                           : (appsWin.atB ? (appsWin.atR ? Item.BottomRight : Item.BottomLeft) : (appsWin.atR ? Item.TopRight : Item.TopLeft))
            Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on scale { NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }
        }
    }
}
