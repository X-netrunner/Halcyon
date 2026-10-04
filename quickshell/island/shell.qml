import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris

ShellRoot {
    id: root

    // ---------- tunables ----------
    // Auto power mode = the power-manager daemon (custom/power-manager, user service power-manager.service).
    // Its thresholds (load, battery, heat, idle) live in custom/power-manager/src/main.rs.
    readonly property string powerService: "power-manager.service"
    readonly property int notifMax: 5        // popups on screen at once; a new one past this hides the oldest popup (it stays in the centre)
    readonly property int notifHistoryMax: 30 // notifications kept in the top-right centre; a new one past this replaces the oldest

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

    // persisted in ~/.local/state/island/settings.json
    property bool autoHide: false
    property bool autoPower: false
    property bool dnd: false            // do not disturb: no popups, everything is still stored
    property string edgeMode: "hover"   // hover | drag: how the edge boxes (notifications, console, utilities) open and close
    readonly property bool dragMode: edgeMode === "drag"
    readonly property string sysmode: stats.sysmode || ""
    property var gpu: ({ gpu: 0, state: "none" })   // gpu.sh, only polled while the performance page is open
    property var specs: ({})                         // hx specs, once at start
    property var disks: ({ disks: [] })              // disk.py, only polled while the performance page is open
    property double autoGuard: 0        // ignore the daemon's state file until this time (ms) after a click
    property bool compactSpecial: true
    property string profileName: ""
    property string profileAvatar: ""
    property bool settingsLoaded: false

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

    Pal { id: pal }

    // notification daemon + top-right bell, popups and centre (replaces dunst)
    Notifs {
        id: notifs
        pal: pal
        maxToasts: root.notifMax
        maxHistory: root.notifHistoryMax
        dnd: root.dnd
        dragMode: root.dragMode
        autoHide: root.autoHide
        sysmode: root.sysmode
        onDndRequested: v => root.setDnd(v)
    }

    // top-left pop-out terminal (one-shot commands, sysmode switches; shows honeypot status while idle)
    QuickTerm {
        id: quickTerm
        pal: pal
        sysmode: root.sysmode
        dragMode: root.dragMode
        autoHide: root.autoHide
    }

    // ---------- actions ----------
    function go(dir) {
        if (page === "launcher") return
        if (dir < 0) page = (page === "perf") ? "home" : "media"
        else page = (page === "media") ? "home" : "perf"
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

    function saveSettings() {
        if (!settingsLoaded) return
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/settings.json\"", "sh", stateDir,
                                 JSON.stringify({ autoHide: autoHide, autoPower: autoPower, compactSpecial: compactSpecial, dnd: dnd, edgeMode: edgeMode,
                                                  profileName: profileName, profileAvatar: profileAvatar })])
    }
    function setAutoHide(v) { autoHide = v; saveSettings() }
    function setCompactSpecial(v) { compactSpecial = v; saveSettings() }
    function setDnd(v) { dnd = v; saveSettings() }
    function setEdgeMode(m) { edgeMode = m; saveSettings() }
    function toggleEdgeMode() { setEdgeMode(dragMode ? "hover" : "drag") }
    function setProfileInfo(name, avatar) { profileName = name; profileAvatar = avatar; saveSettings() }

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
        case "lock": Quickshell.execDetached(["hyprlock"]); break
        case "suspend": Quickshell.execDetached(["systemctl", "suspend"]); break
        case "logout": hypr("hl.dsp.exit()"); break
        case "reboot": Quickshell.execDetached(["systemctl", "reboot"]); break
        case "shutdown": Quickshell.execDetached(["systemctl", "poweroff"]); break
        }
    }
    function randomWallpaper() {
        Quickshell.execDetached(["quickshell", "ipc", "-p", cfg + "/wallpaper", "call", "wallpaper", "next"])
    }
    function runCommand(id) {
        if (id.indexOf("profile-") === 0) {
            var p = id.substring(8)
            if (p === "auto") setAuto(); else setProfile(p)
            return
        }
        switch (id) {
        case "wallpaper": randomWallpaper(); break
        case "settings":
        case "power": corner.pinFor(6000); break
        case "autohide": setAutoHide(!autoHide); break
        case "notifications": notifs.toggleCenter(); break
        case "quickterm": quickTerm.toggle(); break
        case "edgemode": toggleEdgeMode(); break
        case "dnd": setDnd(!dnd); break
        case "cheatsheet": Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/cheatsheet.sh"]); break
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
                    root.edgeMode = s.edgeMode === "drag" ? "drag" : "hover"
                    if (root.autoPower) {
                        root.autoGuard = Date.now() + 10000
                        Quickshell.execDetached(["systemctl", "--user", "start", root.powerService])
                    }
                    root.compactSpecial = s.compactSpecial !== false
                    root.profileName = s.profileName || ""
                    root.profileAvatar = s.profileAvatar || ""
                } catch (e) {}
                root.settingsLoaded = true
            }
        }
    }
    Process {
        running: true
        command: ["bash", root.cfg + "/island/scripts/stats.sh", "2"]
        stdout: SplitParser { onRead: d => { try { root.stats = JSON.parse(d) } catch (e) {} } }
    }
    Process {
        running: true
        command: [root.hx, "specs"]
        stdout: StdioCollector { onStreamFinished: { try { root.specs = JSON.parse(text) } catch (e) {} } }
    }
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
                } catch (e) {}
            }
        }
    }
    property real pendVol: -1
    property real pendBright: -1
    Timer {
        id: sliderT
        interval: 70
        onTriggered: {
            if (root.pendVol >= 0) {
                Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", Math.round(root.pendVol * 100) + "%"])
                root.pendVol = -1
            }
            if (root.pendBright >= 0) {
                Quickshell.execDetached(["brightnessctl", "set", Math.max(1, Math.round(root.pendBright * 100)) + "%"])
                root.pendBright = -1
            }
        }
    }

    // visualizer feed, only runs while something is playing
    Process {
        running: root.playing
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
        }
    }

    // quickshell ipc -p ~/.config/Halcyon/quickshell/island call island <fn>
    IpcHandler {
        target: "island"
        function launcher(): void { root.toggleLauncher() }
        function overview(): void { root.toggleOverview() }
        function home(): void { root.page = "home" }
        function media(): void { root.page = "media" }
        function perf(): void { root.page = "perf" }
        function panel(): void { corner.pinFor(6000) }
        function autohide(): void { root.setAutoHide(!root.autoHide) }
        function clearnotifs(): void { notifs.clearAll() }
        function notifcenter(): void { notifs.toggleCenter() }
        function dnd(): void { root.setDnd(!root.dnd) }
        function cheatsheet(): void { root.runCommand("cheatsheet") }
        function quickterm(): void { quickTerm.toggle() }
        function edgemode(): void { root.toggleEdgeMode() }
    }

    // =====================================================================
    //  TOP: the island (bar -> media / performance pages -> expanding search bar)
    // =====================================================================
    PanelWindow {
        id: win

        anchors { top: true; left: true; right: true }
        implicitHeight: 620
        // auto-hide frees the strip the bar reserves; otherwise windows start below the bar
        exclusiveZone: root.autoHide ? 0 : 62
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
            anchors.topMargin: win.shown ? 16 : -(height + 30)
            anchors.horizontalCenter: parent.horizontalCenter
            clip: true

            width: root.page === "home" ? home.implicitWidth + 56
                 : root.page === "media" ? 500
                 : root.page === "perf" ? 720
                 : launcher.wantedWidth
            height: root.page === "home" ? 44
                  : root.page === "media" ? 156
                  : root.page === "perf" ? 346
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

            // media/perf fall back to the bar when the pointer leaves
            Timer {
                interval: 4000
                running: (root.page === "media" || root.page === "perf") && !hov.hovered
                onTriggered: root.page = "home"
            }

            // scroll / two-finger swipe to move between pages
            Timer { id: wheelCool; interval: 450 }
            WheelHandler {
                enabled: root.page !== "launcher"
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: e => {
                    if (wheelCool.running) return
                    var d = Math.abs(e.angleDelta.x) > Math.abs(e.angleDelta.y) ? e.angleDelta.x : e.angleDelta.y
                    if (d === 0) return
                    root.go(d > 0 ? -1 : 1)
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
                    playing: root.playing
                    activeSpecial: root.activeSpecial
                    opacity: root.page === "home" ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                    onStatusClicked: root.page = "perf"
                    onWorkspaceClicked: n => root.hypr("hl.dsp.focus({ workspace = " + n + " })")
                    onSpecialClicked: name => root.hypr("hl.dsp.workspace.toggle_special(\"" + name + "\")")
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
                anchors.fill: parent
                anchors.margins: 22
                pal: pal
                active: root.page === "launcher"
                opacity: root.page === "launcher" ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
                onCloseRequested: root.page = "home"
                onCommandRequested: c => root.runCommand(c)
            }
        }
    }

    // =====================================================================
    //  FULLSCREEN: SUPER+TAB live tree (laptop -> workspaces -> windows)
    // =====================================================================
    PanelWindow {
        id: ovWin

        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        visible: root.overviewOpen || tree.opacity > 0.01
        color: "transparent"

        WlrLayershell.namespace: "island-overview"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.overviewOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Overview {
            id: tree
            anchors.fill: parent
            pal: pal
            open: root.overviewOpen
            compactSpecial: root.compactSpecial
            profileName: root.profileName
            profileAvatar: root.profileAvatar
            sysmode: root.sysmode

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

    // =====================================================================
    //  BOTTOM-RIGHT: hover the corner for wifi / bluetooth / volume / power / rice / session
    // =====================================================================
    PanelWindow {
        id: corner

        anchors { bottom: true; right: true }
        implicitWidth: 436
        implicitHeight: 900
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.namespace: "island-panel"
        WlrLayershell.layer: WlrLayer.Top
        // only the Wi-Fi password field needs keys; click it to focus
        WlrLayershell.keyboardFocus: panel.wantsKeys ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        property bool hovering: false
        property bool pulling: false
        property real pullAmt: 0
        readonly property bool open: hovering
        readonly property real reveal: pulling ? pullAmt : (hovering ? 1 : 0)
        // hover mode: touching the corner opens it and leaving closes it. drag mode: pull it out of the corner,
        // push it back (handle at the top of the box) to close; auto-hide on closes it when the pointer leaves, in both modes
        function setHover(on) {
            if (on) { closeT.stop(); if (!root.dragMode) hovering = true }
            else if (!panel.wantsKeys && (!root.dragMode || root.autoHide)) { closeT.interval = 450; closeT.restart() }
        }
        // open it from the launcher (>settings / >power options); closes by itself if you don't touch it
        function pinFor(ms) { hovering = true; closeT.interval = ms; closeT.restart() }
        Timer { id: closeT; interval: 450; onTriggered: corner.hovering = false }

        mask: (open || pulling) ? openMask : hotMask
        Region { id: hotMask; item: hot }
        Region { id: openMask; regions: [ Region { item: hot }, Region { item: panel } ] }

        EdgeGrab {
            id: hot
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: root.dragMode ? 36 : 12
            height: root.dragMode ? 36 : 12
            dragMode: root.dragMode
            dx: -0.7; dy: -0.7; span: 260
            onHoverChanged: on => corner.setHover(on)
            onPullChanged: if (pulling) corner.pullAmt = pull
            onPullingChanged: corner.pulling = pulling
            onReleased: o => { corner.pulling = false; corner.hovering = o }
            Rectangle {
                visible: root.dragMode && !corner.open
                anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.rightMargin: 3; anchors.bottomMargin: 3
                width: 12; height: 12; radius: 6
                color: Qt.alpha(pal.accent, 0.35)
            }
        }

        Panel {
            id: panel
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 34
            anchors.bottomMargin: 34
            pal: pal
            active: corner.open
            stats: root.stats
            net: root.net
            profile: root.profile
            autoPower: root.autoPower
            autoHide: root.autoHide
            dragMode: root.dragMode
            vol: root.vol
            muted: root.muted
            bright: root.bright

            opacity: Math.min(1, corner.reveal * 1.6)
            visible: opacity > 0.01
            scale: 0.94 + 0.06 * corner.reveal
            transformOrigin: Item.BottomRight
            Behavior on opacity { enabled: !corner.pulling; NumberAnimation { duration: pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on scale { enabled: !corner.pulling; NumberAnimation { duration: pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

            HoverHandler { onHoveredChanged: corner.setHover(hovered) }

            onToggleWifi: root.toggleWifi()
            onToggleBt: root.toggleBt()
            onSetProfile: p => root.setProfile(p)
            onSetAuto: root.setAuto()
            onToggleAutoHide: root.setAutoHide(!root.autoHide)
            onToggleEdgeMode: root.toggleEdgeMode()
            onCloseDragged: (pull, release) => { if (release) { corner.pulling = false; corner.hovering = pull > 0.6 } else { corner.pulling = true; corner.pullAmt = pull } }
            onRandomWallpaper: root.randomWallpaper()
            onEditConfig: Quickshell.execDetached(["codium", Quickshell.env("HOME") + "/.config/Halcyon"])
            onSession: a => root.session(a)
            onVolumeMoved: v => { root.pendVol = v; root.vol = v * 100; if (!sliderT.running) sliderT.start() }
            onBrightnessMoved: v => { root.pendBright = v; root.bright = v * 100; if (!sliderT.running) sliderT.start() }
        }
    }
}
