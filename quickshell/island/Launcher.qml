import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// One bar for everything:
//   <text>   search apps (clutter like qv4l2 / avahi / Qt tools is hidden)
//   .        every installed app, A-Z  (".fire" filters that list)
//   >        list of commands (random wallpaper, calculator, settings, power options, ...)
//   =        calculator, e.g.  =2*(3+4)   (Enter copies the result); also unit conversion  =5 km in miles  =72 f to c
//   timer    a countdown that notifies when it ends, e.g.  timer 10m   timer 1h30m tea   timer 25  (minutes)   (Enter starts it)
//   >ask     a quick one-line answer from the local AI, e.g.  >ask how many ml in a cup   (Enter asks, Enter again copies the answer)
//   >do      plain English to a Halcyon action, e.g.  >do move this window to workspace 3   >do gaming mode on   (scripts/halcyon-ai.py)
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
    property string runningGame: ""       // the game that runs now (shell.qml): "Stop the game" is only listed then
    property bool firewallInstalled: false // ai-firewall is installed (shell.qml): its two commands are only listed then
    property int infoIdx: -1              // the command row whose description popup is open (-1 = none)
    // the order of the command list: groups first, then this order inside each group (anything not listed goes last)
    readonly property var catOrder: ["system", "desktop", "tools", "games", "power"]
    readonly property var cmdOrder: [
        "settings", "display", "printer", "wifi", "bluetooth", "firewall", "firewall-dashboard", "startupview", "quickterm", "cheatsheet", "reload", "tour",
        "desktopbuilder", "lockdesktopbuilder", "widgetbuilder", "desktopedit", "bartoggle", "barbuilder", "notifbuilder", "wallgallery", "weeklysky", "focusgraph", "wallpaper", "theme", "barstyle", "edgemode", "routing",
        "calendar", "notes", "notesall", "study", "clipboard", "screenshot", "lyrics", "queue", "ask", "do", "calc", "tool-colorpick", "tool-measure", "tool-wifi-qr", "tool-updates-now", "tool-updates-run", "tool-snippets", "tool-windows", "tool-mixer", "tool-zoom", "tool-vpn", "record", "extradim", "caffeine", "dnd", "notifications", "apps",
        "gamecenter", "games", "games-stop",
        "power", "gaming", "profile-auto", "profile-power-saver", "profile-balanced", "profile-performance", "lock", "suspend", "logout", "reboot", "shutdown"
    ]
    // ">"  = adaptive: your most used commands first (usage.log, "cmd:<id>", decayed like the apps), topped up from cmdCore while
    //        you have used fewer than cmdShort; ">." = every command, grouped by category. Words or a category chip search them all.
    readonly property bool cmdAll: mode === "cmd" && q0.substring(1).trim() === "."
    readonly property bool cmdGrouped: mode === "cmd" && cmdAll && cmdCategory === "all"
    readonly property int cmdShort: 10
    readonly property var cmdCore: ["settings", "wallgallery", "desktopbuilder", "barbuilder", "calendar", "notes", "clipboard", "screenshot", "record",
        "tool-colorpick", "ask", "calc", "quickterm", "cheatsheet", "startupview", "reload", "gamecenter", "games-stop", "power", "gaming"]
    property int cmdTucked: 0
    function cmdRank(c) {
        var ci = catOrder.indexOf(c.cat), oi = cmdOrder.indexOf(c.id)
        return (ci < 0 ? 9 : ci) * 1000 + (oi < 0 ? 999 : oi)
    }

    // ---- commands (">" mode). confirm = needs Enter twice.
    readonly property var commands: [
        { id: "wallgallery", name: "Wallpaper gallery", desc: "Interactive 3D carousel & search gallery (Tide style)", glyph: 0xF024B, kw: "wallpapers gallery background images picker choose coverflow", cat: "desktop" },
        { id: "splash", name: "Play the splash", desc: "The login animation: moving stars and the Halcyon sparkle (click or any key skips it)", glyph: 0xF035B, kw: "splash logo intro boot login animation stars sparkle startup screen", cat: "system" },
        { id: "weeklysky", name: "Weekly sky", desc: "Your week as stars: one for every focus session, finished task and calendar event. Save it as a picture to share", glyph: 0xF04CE, kw: "weekly sky week stars constellation focus tasks calendar wrapped share picture summary", cat: "desktop" },
        { id: "focusgraph", name: "Focus streak graph", desc: "Your streak with its flame, today's minutes against the goal, the last 14 days, 12 weeks and your milestones, with Start / Pause / Stop for a Focus session (Space). Also `halcyon focus-graph`, or click the Focus streak graph widget", glyph: 0xF051B, kw: "focus streak graph days best minutes pomodoro history stats", cat: "desktop" },
        { id: "startupview", name: "Startup & processes", desc: "Everything that starts with the desktop and what is running: RAM, CPU, switches, End", glyph: 0xF035B, kw: "startup autostart boot login processes running ram memory cpu htop task manager services apps kill end", cat: "system" },
        { id: "calendar", name: "Calendar", desc: "Google Calendar: your events by day, with reminder notifications", glyph: 0xF00ED, kw: "calender calendar agenda schedule tasks events google reminders meeting", cat: "tools" },
        { id: "notes", name: "New note", desc: "A small panel on the side of the screen: type a note and press Enter to save it (Super + N)", glyph: 0xF03EB, kw: "notes note new write memo text scratchpad todo tasks quick add", cat: "tools" },
        { id: "notesall", name: "All notes", desc: "Every note in one window: search, filter, pin, tick off, copy and delete", glyph: 0xF03EB, kw: "notes all view list browse read search saved memo scratchpad todo tasks pinned", cat: "tools" },
        { id: "clipboard", name: "Clipboard history", desc: "What you copied lately: search, click or Enter to copy it back, delete one or clear all. Copies from password managers are not kept", glyph: 0xF014C, kw: "clipboard history copy paste copied clip cliphist recent wl-copy", cat: "tools" },
        { id: "screenshot", name: "Screenshot", desc: "A small panel: Region, Window or Full screen, then Copy, Save or Both (Super + Ctrl + S). Super + Shift + S still drags a region at once", glyph: 0xF0100, kw: "screenshot screen capture grim slurp region window full print snip snap", cat: "tools" },
        { id: "lyrics", name: "Lyrics", desc: "The lyrics of the song that plays, in a panel on the side. Works with any player that shows up in the bar (Spotify app, browser, mpv ...): from a .lrc file next to the song, lrclib.net or lyrics.ovh, and spotify_player if you have it. Also the Lyrics chip on the music page", glyph: 0xF0387, kw: "lyrics song words music spotify sing text genius spotify_player", cat: "tools" },
        { id: "queue", name: "Music queue", desc: "What plays next on your Spotify account (needs spotify_player). Read-only: it shows the queue, it does not change it. Also the Queue chip on the music page", glyph: 0xF0CB9, kw: "queue next up music spotify playlist upcoming songs spotify_player", cat: "tools" },
        { id: "record", name: "Screen recorder", desc: "On-demand screen or audio recording, with desktop sound and / or microphone, to ~/Videos/Recordings (Super + Alt + R)", glyph: 0xF012F, kw: "record screen capture video stream cast obs", cat: "tools" },
        { id: "tool-colorpick", name: "Color picker", desc: "Click any pixel on the screen: its colour is copied (#rrggbb) and shown as a swatch (Super + Shift + C)", glyph: 0xF0A75, kw: "color colour picker eyedropper pixel hex rgb hsl design css", cat: "tools" },
        { id: "tool-measure", name: "Measure on screen", desc: "Drag a box: its size in pixels is copied (Super + Alt + M)", glyph: 0xF0A60, kw: "measure ruler size pixels width height dimensions screen", cat: "tools" },
        { id: "tool-wifi-qr", name: "Wi-Fi QR code", desc: "A QR code of the Wi-Fi you are on: a friend scans it with the phone camera and joins, no password to read out", glyph: 0xF0432, kw: "wifi wi-fi qr code share password network guest join", cat: "tools" },
        { id: "tool-updates-now", name: "Check for updates", desc: "Count the waiting pacman and AUR updates now (needs pacman-contrib). For a daily check: halcyon updates timer on", glyph: 0xF06B0, kw: "updates upgrade pacman aur yay packages outdated system", cat: "tools" },
        { id: "tool-updates-run", name: "Run system updates", desc: "Open a terminal and run the update (yay or pacman -Syu)", glyph: 0xF06B0, kw: "updates upgrade pacman aur yay packages install system", cat: "tools" },
        { id: "tool-snippets", name: "Paste a snippet", desc: "Pick a saved text (address, signature, reply ...) and it is typed into the window you were in. Add one with: halcyon snippets add <name> <text>", glyph: 0xF0E15, kw: "snippet snippets text expander template paste type canned reply signature", cat: "tools" },
        { id: "tool-windows", name: "Switch window", desc: "A list of every open window, most recently used first (Alt + Shift + Tab). Alt + Tab flips to the previous one", glyph: 0xF05AC, kw: "window windows switch alt tab app focus list", cat: "tools" },
        { id: "tool-mixer", name: "Volume per app", desc: "Choose an app that plays sound and set its own volume, or mute it. In a terminal: halcyon mixer set spotify 30", glyph: 0xF057E, kw: "volume mixer app per application spotify discord sound audio mute", cat: "tools" },
        { id: "tool-zoom", name: "Magnifier", desc: "Zoom the whole screen in and out (Super + Alt + Z toggles 2x); good for small text and for checking pixels", glyph: 0xF0349, kw: "zoom magnifier magnify screen enlarge accessibility lens", cat: "tools" },
        { id: "tool-vpn", name: "VPN on / off", desc: "Switch your VPN (NetworkManager, WireGuard or Tailscale) on or off; with several it asks which", glyph: 0xF0582, kw: "vpn wireguard tailscale network tunnel privacy openvpn", cat: "tools" },
        { id: "firewall", name: "Firewall Center", desc: "Everything ai-firewall does in one window: a live graph, bans, rules and profiles, blocklist feeds, history, and its assistant with the network doctor", glyph: 0xF0565, kw: "firewall ai-firewall ufw security network ports blocked banned bans attack scan protect shield", cat: "system" },
        { id: "firewall-dashboard", name: "Firewall dashboard", desc: "The live firewall dashboard in a terminal: counters, a drops graph, bans and detections; press a to ask it what's wrong", glyph: 0xF0128, kw: "firewall dashboard ai-firewall top monitor network traffic bans ask doctor", cat: "system" },
        { id: "tour", name: "Guided tour", desc: "Replay the walkthrough of the island, its panels and shortcuts", glyph: 0xF02D6, kw: "tutorial help intro welcome walkthrough onboarding whats new release notes learn", cat: "system" },
        { id: "barbuilder", name: "Bar builder", desc: "Drag widgets into the left, middle and right of your own bar", glyph: 0xF0208, kw: "bar custom widgets layout drag drop builder edit", cat: "desktop" },
        { id: "widgetbuilder", name: "Widget builder", desc: "Desktop widgets (clock, system usage, music, visualizer, focus streak ...): pick a layout and a look for each", glyph: 0xF0208, kw: "widgets desktop clock battery wifi stats cpu music visualizer focus streak weather style look design builder customise", cat: "desktop" },
        { id: "desktopedit", name: "Place widgets on the desktop", desc: "Drag, resize and add your widgets right on the screen", glyph: 0xF0208, kw: "widgets desktop move drag place resize edit layout", cat: "desktop" },
        { id: "bartoggle", name: "Top bar on / off", desc: "Switch the top bar off (use desktop widgets instead) or back on", glyph: 0xF0208, kw: "bar top off hide disable remove widgets", cat: "desktop" },
        { id: "desktopbuilder", name: "Desktop builder", desc: "Wallpaper, blur, moving stars, where the widgets sit, and the activation zone (corner) of each box", glyph: 0xF0208, kw: "desktop wallpaper background blur stars moving corner boxes activation position hot corner builder", cat: "desktop" },
        { id: "lockdesktopbuilder", name: "Lock screen builder", desc: "The lock screen's background, blur and tint, its stars and splash, and its widgets (the Desktop builder's Lock screen side)", glyph: 0xF033E, kw: "lock screen background blur tint widgets stars splash switch user builder", cat: "desktop" },
        { id: "notifbuilder", name: "Notification box builder", desc: "Arrange the notification box: its parts, constellations, flying stars, padding, width and place on the screen", glyph: 0xF009A, kw: "notifications notification box builder layout design style timeline grouped stars constellation padding edit customise", cat: "desktop" },
        { id: "reload", name: "Reload", desc: "Reload Hyprland, the terminal colours and the island", glyph: 0xF0450, kw: "restart refresh apply config hyprland island quickshell", cat: "system" },
        { id: "wallpaper", name: "Random wallpaper", desc: "Switch to a new wallpaper now", glyph: 0xF02E9, kw: "background change image", cat: "desktop" },
        { id: "ask", name: "Ask the AI", desc: "Type >ask and a question for a quick answer from your local model. Ask how to change something in Halcyon (\"how do I turn off the constellations\") and you get the steps; Enter then takes you to that setting", glyph: 0xF0B79, kw: "ai ask question answer llm ollama chat quick help how guide setting where turn off", cat: "tools" },
        { id: "do", name: "Do it in plain English", desc: "Type >do and what you want: \"move this window to workspace 3\", \"gaming mode on\", \"volume 40\". Clear phrases work without the AI", glyph: 0xF06A9, kw: "ai do command action natural language plain english voice", cat: "tools" },
        { id: "calc", name: "Calculator", desc: "Type = then an expression or a conversion (=5 km in miles); \"timer 10m\" starts a countdown", glyph: 0xF00EB, kw: "math calculate convert units timer countdown", cat: "tools" },
        { id: "theme", name: "Light / dark theme", desc: "Switch the whole desktop between the dark and the light theme (toggle)", glyph: 0xF0594, kw: "dark light mode appearance colours day night", cat: "desktop" },
        { id: "settings", name: "Settings", desc: "Theme, wallpaper, scrolling, default apps, transparency, motion, gaming", glyph: 0xF0493, kw: "rice options look theme gear config", cat: "system" },
        { id: "extradim", name: "Extra dim display", desc: "Dim screen backlight to minimum (Super + Alt + D)", glyph: 0xF058F, kw: "dim brightness backlight dark night minimum screen", cat: "tools" },
        { id: "study", name: "Study Center", desc: "Add PDFs, slides, notes or photos of pages and ask questions about them; the answers name the page. Also a revision summary, a quiz and flashcards. All on this computer", glyph: 0xF0474, kw: "study learn pdf notes lecture slides exam revise revision quiz flashcards summary ask questions document book homework", cat: "tools" },
        { id: "gamecenter", name: "Game Center", desc: "Your games with cover art: add a Windows game (.exe), read Steam, Epic and GOG, Proton versions and the system check for games", glyph: 0xF0297, kw: "game games center library add exe import steam epic gog stores proton runtimes doctor check settings launcher", cat: "games" },
        { id: "games", name: "Games", desc: "Your game library: Enter launches. Type  >  and its name (or  >game  for the list) to find one (Steam games and the .exe games you added). Halcyon rests while a game runs", glyph: 0xF0297, kw: "game games play library steam proton launcher", cat: "games" },
        // only listed while a game runs (runningGame)
        { id: "games-stop", name: "Stop the game", desc: "Stop the running game completely (no leftover wine processes); Halcyon goes back to normal", glyph: 0xF04DB, kw: "game stop quit kill close running", cat: "games" },
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
    onQ0Changed: favSel = ""
    readonly property string mode: /^>\s*ask\s/i.test(q0) ? "ask" : (/^>\s*do\s/i.test(q0) ? "do" : modeBase)
    readonly property bool aiMode: mode === "ask" || mode === "do"
    readonly property string modeBase: q0.charAt(0) === ">" ? "cmd"
                                 : ((q0.charAt(0) === "=" || /^timer\s/i.test(q0)) ? "calc"
                                 : (q0.charAt(0) === "." ? "all" : "apps"))
    readonly property bool gridMode: mode === "apps" || mode === "all"
    readonly property var calcOut: evalCalc(q0.charAt(0) === "=" ? q0.substring(1) : q0)

    // ---- size the bar should grow to (the island follows these)
    readonly property int rows: mode === "all" ? Math.max(1, Math.min(4, Math.ceil(results.length / 6)))
                              : (query.trim() === "" ? 2 : Math.max(1, Math.min(3, Math.ceil(results.length / 6))))
    readonly property real wantedWidth: gridMode ? 680 : 540
    readonly property int searchH: pal.zen ? 52 : 46
    readonly property int footH: pal.zen && mode === "cmd" ? 22 : 16          // the new style puts the command groups down there
    readonly property real wantedHeight: {
        // margins 36 + search + header 14 + footer + 4 gaps of 12 = base + content
        var base = 36 + searchH + 14 + footH + 48
        if (mode === "calc") return 36 + searchH + 12 + 64
        if (aiMode) return 36 + searchH + 12 + Math.max(64, aiBox.implicitHeight) + 12 + 16
        if (mode === "cmd") return base + Math.max(1, Math.min(7, cmdResults.length)) * 46 + (infoIdx >= 0 && cmdResults[infoIdx] ? infoBox.height + 12 : 0)
        return base + (results.length === 0 ? 40 : rows * (pal.zen ? 96 : 92))
    }

    // the command groups (All / Desktop / System ...): beside "Commands" in the earlier styles, under the list in the new one
    // (nothing button-like sits above the results there)
    component CatTabs: Row {
        spacing: 5
        Repeater {
            model: [
                { id: "all", label: "All" },
                { id: "desktop", label: "Desktop" },
                { id: "system", label: "System" },
                { id: "tools", label: "Tools" },
                { id: "games", label: "Games" },
                { id: "power", label: "Power" }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool activeCat: root.cmdCategory === modelData.id
                height: root.pal.zen ? 22 : 20
                width: catText.implicitWidth + (root.pal.zen ? 20 : 16)
                radius: height / 2
                color: activeCat ? (root.pal.zen ? root.pal.chosenFill : Qt.alpha(root.pal.accent, 0.20)) : (catMa.containsMouse ? Qt.alpha(root.pal.text, 0.08) : Qt.alpha(root.pal.text, root.pal.zen ? 0.04 : 0.03))
                border.width: root.pal.bw
                border.color: activeCat ? Qt.alpha(root.pal.accent, 0.45) : Qt.alpha(root.pal.lineSoft, 0.4)
                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on border.color { ColorAnimation { duration: 120 } }

                Text {
                    id: catText
                    anchors.centerIn: parent
                    text: modelData.label
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.zen ? 11 : 10
                    font.weight: activeCat ? Font.DemiBold : Font.Normal
                    color: activeCat ? (root.pal.zen ? root.pal.chosenText : root.pal.accent) : (catMa.containsMouse ? root.pal.text : root.pal.muted)
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

    // ---- unit conversion and timers (calc mode). Offline: no rates, nothing downloaded.
    readonly property var unitGroups: ({
        len:   { m: 1, meter: 1, meters: 1, km: 1000, kilometer: 1000, kilometers: 1000, cm: 0.01, mm: 0.001, mi: 1609.344, mile: 1609.344, miles: 1609.344,
                 ft: 0.3048, foot: 0.3048, feet: 0.3048, "in": 0.0254, inch: 0.0254, inches: 0.0254, yd: 0.9144, yard: 0.9144, yards: 0.9144 },
        mass:  { kg: 1, g: 0.001, mg: 0.000001, lb: 0.45359237, lbs: 0.45359237, pound: 0.45359237, pounds: 0.45359237, oz: 0.028349523125, ounce: 0.028349523125, ounces: 0.028349523125 },
        vol:   { l: 1, liter: 1, liters: 1, litre: 1, litres: 1, ml: 0.001, gal: 3.785411784, gallon: 3.785411784, gallons: 3.785411784, cup: 0.2365882365, cups: 0.2365882365,
                 floz: 0.0295735295625, tbsp: 0.01478676478125, tsp: 0.00492892159375 },
        speed: { "m/s": 1, ms: 1, "km/h": 0.2777777778, kmh: 0.2777777778, kph: 0.2777777778, mph: 0.44704, knot: 0.5144444444, knots: 0.5144444444 },
        data:  { b: 1, kb: 1000, mb: 1000000, gb: 1000000000, tb: 1000000000000, kib: 1024, mib: 1048576, gib: 1073741824, tib: 1099511627776 },
        time:  { s: 1, sec: 1, secs: 1, min: 60, mins: 60, minute: 60, minutes: 60, h: 3600, hr: 3600, hrs: 3600, hour: 3600, hours: 3600, d: 86400, day: 86400, days: 86400, week: 604800, weeks: 604800 }
    })
    function unitOf(name) {
        for (var g in unitGroups) if (unitGroups[g].hasOwnProperty(name)) return g
        return ""
    }
    function tempToC(v, u) { return u === "f" ? (v - 32) * 5 / 9 : (u === "k" ? v - 273.15 : v) }
    function tempFromC(c, u) { return u === "f" ? c * 9 / 5 + 32 : (u === "k" ? c + 273.15 : c) }
    function tempName(u) {
        u = u.replace(/^°/, "").replace(/^deg(rees?)?/, "").replace(/^\s+/, "")
        if (u === "c" || u === "celsius") return "c"
        if (u === "f" || u === "fahrenheit") return "f"
        if (u === "k" || u === "kelvin") return "k"
        return ""
    }
    function fmtNum(v) { return String(parseFloat(v.toPrecision(7))) }
    function convertUnits(e) {
        var m = /^(-?[0-9]*\.?[0-9]+)\s*([a-z°\/]+)\s+(?:in|to|as|into)\s+([a-z°\/]+)$/.exec(e)
        if (!m) return null
        var v = parseFloat(m[1]), a = m[2], b = m[3]
        var ta = tempName(a), tb = tempName(b)
        if (ta !== "" && tb !== "") {
            var r = fmtNum(tempFromC(tempToC(v, ta), tb))
            return { ok: true, kind: "unit", text: r + " °" + tb.toUpperCase(), copy: r }
        }
        var ga = unitOf(a), gb = unitOf(b)
        if (ga === "" || ga !== gb) return null
        var out = fmtNum(v * unitGroups[ga][a] / unitGroups[gb][b])
        return { ok: true, kind: "unit", text: out + " " + b, copy: out }
    }
    function fmtDur(s) {
        var h = Math.floor(s / 3600), mi = Math.floor((s % 3600) / 60), se = Math.round(s % 60), p = []
        if (h) p.push(h + " h")
        if (mi) p.push(mi + " min")
        if (se) p.push(se + " s")
        return p.join(" ")
    }
    // "timer 10m", "timer 1h30m tea", "timer 90s", "timer 25" (minutes)
    function parseTimer(e) {
        var rest = e.replace(/^timer\s*/, "").trim()
        var hint = { ok: false, bare: true, kind: "hint", text: "timer: say how long, e.g. timer 10m  ·  timer 1h30m tea  ·  timer 25 (minutes)" }
        if (rest === "") return hint
        var m = /^((?:[0-9]+(?:\.[0-9]+)?\s*(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])\s*)+|[0-9]+(?:\.[0-9]+)?)\s*(.*)$/.exec(rest)
        if (!m) return hint
        var re = /([0-9]+(?:\.[0-9]+)?)\s*([a-z]*)/g, t, total = 0
        while ((t = re.exec(m[1])) !== null) {
            var n = parseFloat(t[1]), u = t[2].charAt(0)
            total += n * (u === "h" ? 3600 : (u === "s" ? 1 : 60))
        }
        total = Math.round(total)
        if (total < 1) return hint
        if (total > 7 * 86400) return { ok: false, bare: true, kind: "hint", text: "timer: 7 days at most" }
        var label = m[2].trim().substring(0, 80)
        return { ok: true, bare: true, kind: "timer", secs: total, label: label, text: "Timer  ·  " + fmtDur(total) + (label !== "" ? "  ·  " + label : "") }
    }

    function evalCalc(expr) {
        var e = expr.trim().toLowerCase()
        if (e === "") return { ok: false, text: "" }
        if (/^timer(\s|$)/.test(e)) return parseTimer(e)
        var cv = convertUnits(e)
        if (cv) return cv
        // "20% of 50"
        var po = /^([0-9]*\.?[0-9]+)\s*%\s*of\s+(.+)$/.exec(e)
        if (po) e = "(" + po[1] + "/100)*(" + po[2] + ")"
        var v = calcParse(e)
        if (typeof v !== "number" || !isFinite(v)) return { ok: false, text: "…" }
        return { ok: true, text: String(parseFloat(v.toPrecision(12))) }
    }

    // A small expression parser instead of eval(): numbers (1e5), + - * / % ^ (right to left, -2^2 = -4), ! , brackets,
    // implicit multiplication (2pi, 3(4+1)), constants pi / e and a fixed list of functions. Anything else is NaN.
    // It cannot run code, loop, or hang: input is capped and nesting is limited.
    readonly property var calcFns: ({
        sqrt: Math.sqrt, sin: Math.sin, cos: Math.cos, tan: Math.tan, abs: Math.abs, floor: Math.floor, ceil: Math.ceil,
        round: Math.round, exp: Math.exp, ln: Math.log, log: Math.log, log10: Math.log10, log2: Math.log2,
        pow: Math.pow, min: Math.min, max: Math.max, cbrt: Math.cbrt, asin: Math.asin, acos: Math.acos, atan: Math.atan })
    function calcParse(src) {
        if (src.length > 200) return NaN
        var toks = [], rest = src, m
        while (true) {
            rest = rest.replace(/^\s+/, "")
            if (rest === "") break
            if ((m = /^(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:e[+-]?[0-9]+)?/.exec(rest))) toks.push({ n: parseFloat(m[0]) })
            else if ((m = /^[a-z][a-z0-9]*/.exec(rest))) toks.push({ id: m[0] })
            else if ((m = /^[-+*\/%^!(),]/.exec(rest))) toks.push({ op: m[0] })
            else return NaN
            rest = rest.substring(m[0].length)
        }
        var pos = 0, depth = 0, bad = false, fns = calcFns
        function peekOp(o) { return pos < toks.length && toks[pos].op === o }
        function expr() {
            var v = term()
            while (!bad && (peekOp("+") || peekOp("-"))) { var o = toks[pos++].op; var r = term(); v = o === "+" ? v + r : v - r }
            return v
        }
        function term() {
            var v = unary()
            while (!bad && pos < toks.length) {
                var t = toks[pos]
                if (t.op === "*" || t.op === "/" || t.op === "%") { pos++; var r = unary(); v = t.op === "*" ? v * r : t.op === "/" ? v / r : v % r }
                else if (t.n !== undefined || t.id !== undefined || t.op === "(") v = v * unary()      // implicit multiplication
                else break
            }
            return v
        }
        function unary() {
            if (peekOp("-")) { pos++; return -unary() }
            if (peekOp("+")) { pos++; return unary() }
            return power()
        }
        function power() {
            var b = postfix()
            if (!bad && peekOp("^")) { pos++; return Math.pow(b, unary()) }
            return b
        }
        function postfix() {
            var v = primary()
            while (!bad && peekOp("!")) {
                pos++
                if (v < 0 || v > 170 || Math.floor(v) !== v) { bad = true; return NaN }
                var f = 1
                for (var i = 2; i <= v; i++) f *= i
                v = f
            }
            return v
        }
        function primary() {
            if (pos >= toks.length || ++depth > 40) { bad = true; return NaN }
            var t = toks[pos++], v
            if (t.n !== undefined) v = t.n
            else if (t.op === "(") { v = expr(); if (!peekOp(")")) bad = true; else pos++ }
            else if (t.id === "pi") v = Math.PI
            else if (t.id === "e") v = Math.E
            else if (t.id !== undefined && fns[t.id] && peekOp("(")) {
                pos++
                var args = []
                if (!peekOp(")")) { args.push(expr()); while (!bad && peekOp(",")) { pos++; args.push(expr()) } }
                if (!peekOp(")")) bad = true; else pos++
                v = bad ? NaN : fns[t.id].apply(null, args)
            } else bad = true
            depth--
            return bad ? NaN : v
        }
        var out = expr()
        return (bad || pos !== toks.length) ? NaN : out
    }

    // ---- >games / >game <name>: the game library (hgl list --json) as extra rows in the commands list; Enter runs the game ("game:<id>").
    // ">" and a game's name (">cyberpunk") finds it too, among the commands
    readonly property bool gameQuery: mode === "cmd" && /^>\s*games?(\s|$)/i.test(q0)
    readonly property string gameArg: gameQuery ? q0.replace(/^>\s*games?\s*/i, "").trim() : ""
    property var gameList: []
    onModeChanged: if (mode === "cmd" && !gamesProc.running) gamesProc.running = true      // read the library each time you start typing ">"
    Process {
        id: gamesProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hgl", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                var l = []
                try { l = JSON.parse(text) } catch (e) { l = [] }
                root.gameList = Array.isArray(l) ? l : []
                if (root.mode === "cmd") root.refresh()
            }
        }
    }
    function gameRows(cq) {
        var out = []
        if (cmdCategory !== "all" && cmdCategory !== "games") return out
        var byName = !gameQuery                          // ">" and a name: only games whose name has it, ranked in between the commands
        if (byName && cq.length < 2) return out
        var ga = (byName ? cq : gameArg).toLowerCase()
        for (var gi = 0; gi < gameList.length; gi++) {
            var gm = gameList[gi]
            if (!gm || !gm.id) continue
            var gn = String(gm.name || gm.id).toLowerCase()
            var gr = byName ? (gn.indexOf(ga) === 0 ? 4.5 : (gn.indexOf(ga) >= 0 ? 3.5 : 0))
                            : (ga === "" ? 5 : (gn.indexOf(ga) === 0 ? 8 : (gn.indexOf(ga) >= 0 ? 7 : (ga.length > 1 && fuzzy(ga, gn) ? 6 : 0))))
            if (gr === 0) continue
            if (gm.fav) gr += byName ? 0.5 : 10          // favourites first (the star on the row, or Ctrl+F, toggles it); among commands only within their tier
            var why = gm.running ? "Running now" : (gm.status === "attention" ? "Needs attention: " + (gm.statusReason || "see hgl show " + gm.id) : "Enter to play")
            out.push({ c: { id: "game:" + gm.id, name: gm.name || gm.id, desc: why, glyph: 0xF0297, kw: "", cat: "games", fav: !!gm.fav }, r: gr, i: -1000 + gi })
        }
        return out
    }

    // star / unstar a game (hgl set <id> fav on|off); the list is re-read so it moves at once
    property string favSel: ""             // the game just starred stays selected while the list re-sorts
    Process {
        id: favProc
        onExited: if (!gamesProc.running) gamesProc.running = true
    }
    // favourites for every command (not only games): ids in ~/.local/state/island/cmd-favs.txt, one per line. A starred command is listed first
    // in ">" (always, even if you never use it) and first among the matches while you search; in the grouped ">." list it keeps its group.
    property var cmdFavs: ({})
    function isFav(c) { return !!c && (c.id.indexOf("game:") === 0 ? !!c.fav : root.cmdFavs[c.id] === true) }
    Process {
        running: true
        command: ["sh", "-c", "cat ~/.local/state/island/cmd-favs.txt 2>/dev/null"]
        stdout: SplitParser {
            onRead: d => {
                var id = d.trim()
                if (id) { var f = Object.assign({}, root.cmdFavs); f[id] = true; root.cmdFavs = f }
            }
        }
        onExited: root.refresh()
    }
    function toggleCmdFav(c) {
        var on = root.cmdFavs[c.id] !== true
        var f = Object.assign({}, root.cmdFavs)
        if (on) f[c.id] = true; else delete f[c.id]
        root.cmdFavs = f
        Quickshell.execDetached(["sh", "-c", on
            ? "mkdir -p ~/.local/state/island; f=~/.local/state/island/cmd-favs.txt; grep -qxF -- \"$0\" \"$f\" 2>/dev/null || echo \"$0\" >> \"$f\""
            : "f=~/.local/state/island/cmd-favs.txt; grep -vxF -- \"$0\" \"$f\" > \"$f.tmp\" 2>/dev/null; mv -f \"$f.tmp\" \"$f\" 2>/dev/null; true", c.id])
        favSel = c.id                                       // the command just starred stays selected while the list re-sorts
        refresh()
    }
    function toggleFav(i) {
        var c = cmdResults[i]
        if (c && c.id.indexOf("game:") !== 0) { toggleCmdFav(c); return }
        if (!c || favProc.running) return
        for (var k = 0; k < gameList.length; k++)          // flip it here too, so the star answers before hgl does
            if (gameList[k] && "game:" + gameList[k].id === c.id) gameList[k].fav = !c.fav
        favProc.command = [Quickshell.env("HOME") + "/.config/Halcyon/bin/hgl", "set", c.id.substring(5), "fav", c.fav ? "off" : "on"]
        favProc.running = true
        favSel = c.id
        refresh()
    }

    function refresh() {
        dirty = false
        if (mode === "cmd") {
            var cq = q0.substring(1).trim().toLowerCase()
            if (cq === ".") cq = ""                          // ">." = everything
            var outc = [], total = 0, nfav = 0
            var shortList = cq === "" && !cmdAll && root.cmdCategory === "all"
            for (var c = 0; c < commands.length; c++) {
                var cm = commands[c]
                if (root.cmdCategory !== "all" && cm.cat !== root.cmdCategory) continue
                if (cm.id === "games-stop" && root.runningGame === "") continue
                if ((cm.id === "firewall" || cm.id === "firewall-dashboard") && !root.firewallInstalled) continue
                total++
                if (shortList) {                             // used: by how much (always above the core ones); core: in its own order
                    var us = score("cmd:" + cm.id), ci = cmdCore.indexOf(cm.id)
                    if (root.cmdFavs[cm.id] === true) { nfav++; outc.push({ c: cm, r: 2000, i: c }) }          // starred: always first
                    else if (cm.id === "games-stop") outc.push({ c: cm, r: 1000, i: c })
                    else if (us >= 0.3) outc.push({ c: cm, r: 100 + us, i: c })
                    else if (ci >= 0) outc.push({ c: cm, r: 1 - ci / 100, i: c })
                    continue
                }
                var nm = cm.name.toLowerCase()
                var r = 1
                if (cq !== "") {
                    if (nm.indexOf(cq) === 0) r = 4
                    else if (nm.indexOf(cq) >= 0) r = 3
                    else if ((cm.kw + " " + cm.desc + " " + (cm.cat || "")).toLowerCase().indexOf(cq) >= 0) r = 2
                    else if (cq.length > 1 && fuzzy(cq, nm)) r = 1
                    else continue
                }
                // starred: first of all with nothing typed; while you search only above matches of the same strength, so a star that
                // matches by a keyword ("settings" is one of Game Center's) never beats the command whose name you are typing
                if (root.cmdFavs[cm.id] === true && !root.cmdGrouped) r += cq === "" ? 10 : 0.5
                // ">game": the games come in as rows of 5 (starred ones 15). A command called "Game ..." (Game Center) goes above the
                // unstarred games, and a starred one above every game: the star means "this first"
                if (root.gameQuery && r >= 4) r = root.cmdFavs[cm.id] === true ? 20 : 5.5
                outc.push({ c: cm, r: r, i: c })
            }
            outc = outc.concat(root.gameRows(cq))
            outc.sort(function (x, y) { return (y.r - x.r) || (root.cmdRank(x.c) - root.cmdRank(y.c)) || (x.i - y.i) })
            if (shortList && outc.length > Math.max(cmdShort, nfav)) outc = outc.slice(0, Math.max(cmdShort, nfav))
            cmdTucked = shortList ? Math.max(0, total - outc.length) : 0
            var ncmd = outc.map(function (o) { return o.c })
            infoIdx = -1
            if (!sameList(ncmd, cmdResults)) cmdResults = ncmd
            var sel = 0
            if (favSel !== "") for (var fi = 0; fi < ncmd.length; fi++) if (ncmd[fi].id === favSel) { sel = fi; break }
            cmdList.currentIndex = sel
            return
        }
        if (mode === "calc" || aiMode) return

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
        // usage.log ranks the launcher; launch-times.log ("<unix time> <id>") tells Startup & processes > Unused when an app was last started
        Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.local/state/island && echo \"$0\" >> ~/.local/state/island/usage.log && echo \"$(date +%s) $0\" >> ~/.local/state/island/launch-times.log", e.id])
        e.execute()
        closeRequested()
    }

    // `island command games` (and the Games row) opens the bar on the game list
    property string pendingQuery: ""
    function applyPending() {
        if (pendingQuery === "") return
        input.text = pendingQuery
        input.cursorPosition = input.text.length
        pendingQuery = ""
    }
    function openGames() {
        pendingQuery = ">game "
        if (active) applyPending()
    }
    function runCmd(i) {
        var c = cmdResults[i]
        if (!c) return
        if (c.confirm && pendingConfirm !== c.id) { pendingConfirm = c.id; return }
        pendingConfirm = ""
        saveHistory(query)
        if (c.id.indexOf("game:") !== 0) {      // remembered, so it stays in the short ">" list (cmdCore)
            bumpScore("cmd:" + c.id)
            Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.local/state/island && echo \"$0\" >> ~/.local/state/island/usage.log", "cmd:" + c.id])
        }
        if (c.id === "calc") {            // stay in the bar, switch to calculator mode
            input.text = "="
            input.cursorPosition = 1
            return
        }
        if (c.id === "ask" || c.id === "do") {
            input.text = ">" + c.id + " "
            input.cursorPosition = input.text.length
            return
        }
        if (c.id === "games") {           // stay in the bar: the game list (last played first)
            openGames()
            return
        }
        commandRequested(c.id)
        closeRequested()
    }

    function copyCalc() {
        if (!calcOut.ok) return
        saveHistory(query)
        if (calcOut.kind === "timer") {
            // a transient user timer unit: it keeps counting if the shell restarts and uses no memory while it waits
            var what = calcOut.label !== "" ? calcOut.label : fmtDur(calcOut.secs)
            Quickshell.execDetached(["systemd-run", "--user", "--quiet", "--unit=halcyon-timer-" + Date.now(), "--on-active=" + calcOut.secs + "s",
                                     "notify-send", "-a", "Halcyon", "-i", "alarm-symbolic", "Timer done", what])
            Quickshell.execDetached(["notify-send", "-a", "Halcyon", "-i", "alarm-symbolic", "Timer set", fmtDur(calcOut.secs) + (calcOut.label !== "" ? "  ·  " + calcOut.label : "")])
        } else {
            Quickshell.execDetached(["wl-copy", calcOut.copy !== undefined ? calcOut.copy : calcOut.text])
        }
        closeRequested()
    }

    // ---- >ask / >do (scripts/halcyon-ai.py). One run per Enter; the answer belongs to the text it was asked for
    readonly property string aiArg: aiMode ? q0.replace(/^>\s*(ask|do)\s+/i, "").trim() : ""
    property string aiFor: ""              // mode + text the answer below is for
    property string aiText: ""
    property bool aiOk: true
    property bool aiConfirm: false         // >do: the action ends something (close, log out ...): Enter again does it
    property var aiOpen: null              // >ask about Halcyon itself: the guide's place, { settings: group } or { command: id }; Enter goes there
    readonly property bool aiFresh: aiFor === mode + "\u0001" + aiArg
    readonly property string aiScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-ai.py"
    function aiEnter() {
        if (aiArg === "" || aiProc.running) return
        if (mode === "ask" && aiFresh && aiOk && aiOpen) {                // a guide: Enter opens the setting it is about
            saveHistory(query)
            commandRequested(aiOpen.settings ? "settings:" + aiOpen.settings : aiOpen.command)
            closeRequested()
            return
        }
        if (mode === "ask" && aiFresh && aiOk && aiText !== "") {          // the answer is there: Enter copies it
            saveHistory(query)
            Quickshell.execDetached(["wl-copy", aiText])
            closeRequested()
            return
        }
        var yes = mode === "do" && aiFresh && aiConfirm
        saveHistory(query)
        aiFor = mode + "\u0001" + aiArg
        aiText = ""; aiOk = true; aiConfirm = false; aiOpen = null
        aiProc.command = ["python3", aiScript, mode, "--json"].concat(yes ? ["--yes"] : []).concat([aiArg])
        aiProc.running = true
    }
    Process {
        id: aiProc
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (!d) { root.aiOk = false; root.aiText = "No answer (is python3 there?)"; return }
                root.aiOk = d.ok === true
                root.aiText = d.ok ? d.text : d.error
                root.aiConfirm = d.ok === true && d.confirm === true && d.done !== true
                root.aiOpen = d.ok === true && d.kind === "howto" && d.open ? d.open : null
                if (d.ok && d.done === true) aiCloseT.restart()
            }
        }
    }
    Timer { id: aiCloseT; interval: 650; onTriggered: root.closeRequested() }

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
            else grid.currentIndex = 0             // the arrows start from the first app
            Qt.callLater(function () { input.forceActiveFocus() })
            if (pendingQuery !== "") Qt.callLater(applyPending)
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
            Layout.preferredHeight: root.pal.zen ? 52 : 46
            radius: height / 2
            // new: a soft pill, no outline and no glow
            color: root.pal.zen ? root.pal.field : Qt.alpha(root.pal.surface, 0.85)
            border.width: root.pal.bw
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
                opacity: input.activeFocus && !root.pal.zen ? 0.07 : 0
                Behavior on opacity { NumberAnimation { duration: 240 } }
            }

            Text {
                id: mag
                x: root.pal.zen ? 22 : 18
                anchors.verticalCenter: parent.verticalCenter
                color: root.pal.zen ? root.pal.muted : root.pal.accent
                text: String.fromCodePoint(root.aiMode ? (root.mode === "do" ? 0xF06A9 : 0xF0B79) : (root.mode === "cmd" ? 0xF0493 : (root.mode === "calc" ? 0xF00EB : (root.mode === "all" ? 0xF003B : 0xF0349))))
                font.family: root.pal.font
                font.pixelSize: 18
            }
            Text {
                visible: input.text === ""
                anchors.left: input.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.pal.zen ? "Search apps, commands, files" : "Search apps…"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.zen ? 16 : 15
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
                font.pixelSize: root.pal.zen ? 16 : 15
                clip: true
                onTextChanged: { root.query = text; root.pendingConfirm = ""; if (!root.histBusy) root.histIdx = -1; root.refresh() }

                // Up / Down / Left / Right walk through the apps as soon as the bar opens (in the command list Up / Down move the selection)
                // Ctrl+Up / Ctrl+Down with the box empty: older / newer searches (then plain Up / Down keep paging until you type)
                // Tab / Shift+Tab (or Ctrl+N / Ctrl+P): next / previous result;  Ctrl+Up / Ctrl+Down with something typed: a row up / down
                Keys.onPressed: e => {
                    var cmd = root.mode === "cmd", calc = root.mode === "calc"
                    var ctrl = (e.modifiers & Qt.ControlModifier) !== 0
                    // unless you are paging through old searches, the arrow keys walk through the apps from the moment the bar opens:
                    // Up / Down a row, Left / Right one app. Shift / Alt + Left / Right and Ctrl + Left / Right still move the text cursor.
                    var nav = root.gridMode && root.results.length > 0 && root.histIdx === -1
                    var hist = root.query === "" || root.histIdx !== -1
                    var plain = (e.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
                    if (e.key === Qt.Key_Escape) { if (root.infoIdx >= 0) root.infoIdx = -1; else root.closeRequested(); e.accepted = true }
                    else if (e.key === Qt.Key_Down) {
                        if (cmd) { cmdList.incrementCurrentIndex(); root.pendingConfirm = "" }
                        else if (ctrl && hist) root.histStep(-1)
                        else if (ctrl) { if (!calc) grid.moveCurrentIndexDown() }
                        else if (nav) grid.moveCurrentIndexDown()
                        else root.histStep(-1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Up) {
                        if (cmd) { cmdList.decrementCurrentIndex(); root.pendingConfirm = "" }
                        else if (ctrl && hist) root.histStep(1)
                        else if (ctrl) { if (!calc) grid.moveCurrentIndexUp() }
                        else if (nav) grid.moveCurrentIndexUp()
                        else root.histStep(1)
                        e.accepted = true
                    }
                    else if (cmd && ctrl && e.key === Qt.Key_F) { root.toggleFav(cmdList.currentIndex); e.accepted = true }
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
                        if (root.aiMode) root.aiEnter()
                        else if (cmd) root.runCmd(cmdList.currentIndex)
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
                // new: just the word, quietly ("Apps"), as the mode is a fact and not a button
                color: root.pal.zen ? "transparent" : Qt.alpha(root.pal.accent, 0.14)
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Text {
                    id: badgeTxt
                    anchors.centerIn: parent
                    readonly property string word: root.mode === "ask" ? "ask" : (root.mode === "do" ? "do" : (root.mode === "cmd" ? "commands" : (root.mode === "calc" ? "calculator" : (root.mode === "all" ? "all apps" : "apps"))))
                    text: root.pal.zen ? root.pal.cap(word) : word
                    color: root.pal.zen ? root.pal.muted : root.pal.accent
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.zen ? 12 : 11
                    font.weight: root.pal.zen ? Font.Normal : Font.Medium
                    font.letterSpacing: root.pal.zen ? 0 : 0.4
                }
            }
        }

        // ---------- section label & category tabs ----------
        RowLayout {
            visible: root.mode !== "calc" && !root.aiMode
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            spacing: 8

            Text {
                // the new style: the label sits in the middle, over the middle of the apps
                Layout.fillWidth: root.pal.zen
                horizontalAlignment: root.pal.zen ? Text.AlignHCenter : Text.AlignLeft
                readonly property string word: root.mode === "cmd" ? "COMMANDS"
                    : root.mode === "all" ? "ALL APPS · " + root.results.length
                    : (root.query === "" ? "MOST USED" : "RESULTS")
                text: root.pal.zen ? root.pal.cap(word) : word
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.zen ? 12 : 10
                font.weight: root.pal.zen ? Font.Normal : Font.DemiBold
                font.letterSpacing: root.pal.zen ? 0 : 1.4
                Layout.alignment: Qt.AlignVCenter
            }

            Item { visible: !root.pal.zen; Layout.fillWidth: true }

            CatTabs {
                visible: root.mode === "cmd" && !root.pal.zen
                Layout.alignment: Qt.AlignVCenter
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
            cellHeight: root.pal.zen ? 96 : 92
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
                    radius: root.pal.zen ? 18 : root.pal.calm ? root.pal.rLg : 18
                    color: root.pal.zen ? Qt.alpha(root.pal.text, 0.07) : Qt.alpha(root.pal.accent, root.pal.calm ? 0.12 : 0.13)
                    border.width: root.pal.calm ? 0 : 1
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.28)
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
                    spacing: root.pal.zen ? 9 : 7
                    scale: ma.pressed ? 0.94 : 1
                    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                    Image {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: root.pal.zen ? 44 : 42
                        height: width
                        sourceSize: Qt.size(88, 88)
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
                        color: cell.cur ? root.pal.text : Qt.alpha(root.pal.text, root.pal.zen ? 0.8 : 0.78)
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.zen ? 12 : 11
                        font.weight: cell.cur && !root.pal.zen ? Font.DemiBold : Font.Medium
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
                radius: root.pal.calm ? root.pal.rMd : 14
                color: root.pal.zen ? Qt.alpha(root.pal.text, 0.07) : Qt.alpha(root.pal.accent, root.pal.calm ? 0.12 : 0.13)
                border.width: root.pal.calm ? 0 : 1
                border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.28)
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
                    color: root.pal.zen && !crow.ListView.isCurrentItem ? root.pal.muted : root.pal.accent
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
                        if (root.pal.calm) return "transparent"          // calm: the group is a quiet word, not a coloured badge
                        if (cat === "power") return Qt.alpha(root.pal.accent2, 0.16)
                        if (cat === "tools") return Qt.alpha(root.pal.good || root.pal.accent, 0.16)
                        if (cat === "system") return Qt.alpha(root.pal.warn || root.pal.accent, 0.16)
                        return Qt.alpha(root.pal.accent, 0.12)
                    }
                    border.width: root.pal.calm ? 0 : 1
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
                        text: root.pal.calm ? (crow.modelData.cat || "cmd") : (crow.modelData.cat || "cmd").toUpperCase()
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.calm ? 11 : 9
                        font.weight: root.pal.calm ? Font.Normal : Font.DemiBold
                        font.letterSpacing: root.pal.calm ? 0 : 0.6
                        color: {
                            var cat = crow.modelData.cat
                            if (root.pal.calm) return Qt.alpha(root.pal.muted, 0.8)
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
                    color: root.pal.zen ? root.pal.lineSoft : Qt.alpha(root.pal.accent, 0.22)
                }
                // the favourite star on every command and game (favourites are listed first; Ctrl + F on the selected row does the same)
                Text {
                    id: favBtn
                    readonly property bool isFav: root.isFav(crow.modelData)
                    visible: isFav || crow.ListView.isCurrentItem
                    anchors.right: infoBtn.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(isFav ? 0xF04CE : 0xF04D2)
                    color: isFav ? root.pal.accent : (favMa.containsMouse ? root.pal.text : root.pal.muted)
                    font.family: root.pal.font
                    font.pixelSize: 16
                    MouseArea {
                        id: favMa
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { input.forceActiveFocus(); root.toggleFav(crow.index) }     // focus first: the list is rebuilt and this row goes
                    }
                }
                // right-most: the description button
                Rectangle {
                    id: infoBtn
                    // new style: only on the row you are on (the description is there when you want it, not on every line)
                    visible: (crow.modelData.desc || "") !== "" && (!root.pal.zen || crow.ListView.isCurrentItem || openNow)
                    readonly property bool openNow: root.infoIdx === crow.index
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24; height: 24; radius: 12
                    color: openNow ? Qt.alpha(root.pal.accent, 0.25) : (infoMa.containsMouse ? Qt.alpha(root.pal.text, 0.10) : "transparent")
                    border.width: root.pal.zen && !openNow ? 0 : 1
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
            color: root.pal.zen ? root.pal.group : Qt.alpha(root.pal.accent, 0.09)
            border.width: root.pal.bw
            border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
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
                text: root.calcOut.text === "" ? "type an expression, a conversion (5 km in miles) or timer 10m" : ((root.calcOut.bare === true ? "" : "= ") + root.calcOut.text)
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
                text: root.calcOut.kind === "timer" ? "Enter to start" : "Enter to copy"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 11
            }
        }

        // ---------- >ask / >do ----------
        Rectangle {
            visible: root.aiMode
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(64, aiBox.implicitHeight)
            radius: 18
            color: Qt.alpha(root.aiFresh && !root.aiOk && !aiProc.running ? root.pal.warn : root.pal.accent, 0.12)
            Column {
                id: aiBox
                anchors.left: parent.left; anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: 20; rightPadding: 20; topPadding: 14; bottomPadding: 14
                spacing: 6
                Text {
                    width: aiBox.width - 40
                    wrapMode: Text.Wrap
                    maximumLineCount: 12
                    elide: Text.ElideRight
                    text: aiProc.running ? (root.mode === "ask" ? "Thinking…" : "Working it out…")
                        : (root.aiFresh && root.aiText !== "" ? root.aiText
                        : (root.aiArg === "" ? (root.mode === "ask" ? "type a question, e.g. how many grams in a cup of flour" : "say what to do, e.g. move this window to workspace 3")
                        : (root.mode === "ask" ? "Enter asks your local AI" : "Enter does it")))
                    color: root.aiFresh && root.aiText !== "" && !aiProc.running ? (root.aiOk ? root.pal.text : root.pal.warn) : root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.aiFresh && root.aiText !== "" && !aiProc.running ? 16 : 15
                    lineHeight: 1.15
                }
            }
        }
        Text {
            visible: root.aiMode
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 16
            text: root.mode === "ask" ? (root.aiFresh && root.aiOk && root.aiText !== "" && !aiProc.running
                                         ? (root.aiOpen ? (root.aiOpen.settings ? "⏎ takes you there in Settings   ·   esc closes" : "⏎ runs it   ·   esc closes") : "⏎ copies the answer   ·   esc closes")
                                         : "⏎ asks   ·   ask about anything, or how to change something in Halcyon   ·   nothing leaves this computer")
                                      : (root.aiConfirm && root.aiFresh ? "⏎ again to do it   ·   esc cancels" : "⏎ does it   ·   clear phrases work without the AI")
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 10
        }

        // ---------- footer hints ----------
        CatTabs {
            visible: root.pal.zen && root.mode === "cmd"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 22
        }
        // the new style: one quiet line, as in the prototype
        Text {
            visible: root.pal.zen && root.mode !== "calc" && root.mode !== "cmd" && !root.aiMode
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 16
            text: "Enter to open   ·   > commands   ·   = calculate   ·   . all apps"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 11
        }
        Row {
            visible: !root.pal.zen && root.mode !== "calc" && !root.aiMode
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 16
            spacing: 18
            Repeater {
                model: root.mode === "cmd"
                    ? (root.cmdTucked > 0 ? [["↑↓", "move"], ["⏎", "run"], [">.", "all " + (root.cmdTucked + root.cmdResults.length) + " commands"]]
                                                              : [["↑↓", "move"], ["⏎", "run"], ["esc", "close"]])
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
