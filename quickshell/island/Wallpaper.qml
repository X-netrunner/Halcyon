import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "TimeOfDay.js" as TOD

PanelWindow {
    id: wallpaper
    color: "black"
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "wallpaper"

    // ---- Desktop builder (Settings > Appearance > Desktop builder): shell.qml hands over the palette and the options
    property var pal: null
    property var opt: ({})
    property var env: null                  // the shell: the feeds and actions the desktop widgets use
    property bool widgetsHidden: false      // the desktop editor shows them itself while you place them
    property real widgetsTop: 24            // room kept free at the top (the bar)
    // Live wallpaper (Settings > Wallpaper > Live wallpaper, Super + Alt + W): opt.deskLive "on" shows opt.deskLivePick instead of the picture:
    // "sky" = the Halcyon sky (LiveSky.qml), else a video / GIF file (LiveVideo.qml). The picture is then not decoded at all. The colours
    // come from the file's thumbnail (scripts/live-wallpapers.sh); the sky keeps the colours of the last picture.
    readonly property bool liveOn: !!opt && (opt.deskLive === "on" || opt.deskLive === "sky")
    readonly property string livePick: (opt && opt.deskLivePick) || "sky"
    readonly property bool liveRun: !(env && (env.gaming || env.screenLocked || env.fsQuiet || env.deskCovered || env.lean === true || env.focusQuiet === true))
    function liveThumb(path) { return Quickshell.env("HOME") + "/.cache/island/live-thumbs/" + Qt.md5(path) + ".jpg" }
    onLivePickChanged: if (liveOn && livePick !== "sky") runPalette(liveThumb(livePick))
    onLiveOnChanged: {
        if (liveOn && livePick !== "sky") runPalette(liveThumb(livePick))
        else if (!liveOn && currentPath !== "") runPalette(currentPath)        // back to the picture's own colours
    }
    readonly property bool wpOn: (!opt || opt.deskWall !== false) && !liveOn         // false = no picture: a plain background (colours still follow the last wallpaper)
    readonly property real blurAmt: Math.max(0, Math.min(1, (opt && opt.deskBlur !== undefined ? Number(opt.deskBlur) : 0) / 100))
    readonly property int blurPad: Math.round(blurAmt * 56)                           // the picture is drawn a bit larger so the blur does not darken the screen edges
    readonly property string bgKind: (opt && opt.deskBg) || "theme"                   // theme | black | gradient : what you see when the wallpaper is off
    property string lastPath: ""                                                      // the wallpaper that was asked for last, so switching the picture back on is instant

    readonly property string island: Quickshell.env("HOME") + "/.config/Halcyon/quickshell/island"
    readonly property real diag: Math.sqrt(width * width + height * height)

    property string currentPath: ""     // what `cur` shows
    property string incomingPath: ""    // what is being revealed
    property bool shown: false          // first wallpaper has faded in
    property bool waiting: false        // incoming is loading
    property bool revealing: false      // the circle is growing
    property bool swapping: false       // reveal done, waiting for `cur` to take over
    property real maskSize: 0
    // Decode size = the screen. With PreserveAspectCrop and BOTH sides given, Qt decodes the picture so that it just covers
    // this rectangle (any aspect ratio), so a wide picture is no longer decoded at 2.4x the screen width.
    // 1920x1200: ~9 MB per decoded wallpaper instead of ~21 MB, and the reveal holds two of them at once.
    readonly property int decodeW: Math.max(1, Math.round(width))
    readonly property int decodeH: Math.max(1, Math.round(height))

    // ---- what shows when the wallpaper picture is switched off (or has not loaded yet)
    Rectangle {
        id: bgFill
        anchors.fill: parent
        visible: (!wallpaper.wpOn || !wallpaper.shown) && !wallpaper.liveOn
        color: wallpaper.bgKind === "black" ? "#000000" : (wallpaper.pal ? wallpaper.pal.bg : "#000000")
        gradient: wallpaper.bgKind === "gradient" && wallpaper.pal ? bgGrad : null
        Gradient {
            id: bgGrad
            GradientStop { position: 0.0; color: wallpaper.pal ? wallpaper.pal.bg : "#000000" }
            GradientStop { position: 1.0; color: wallpaper.pal ? Qt.tint(wallpaper.pal.bg, Qt.alpha(wallpaper.pal.accent, 0.30)) : "#000000" }
        }
    }

    // ---- the wallpaper currently on screen
    Image {
        id: cur
        anchors.fill: parent
        anchors.margins: -wallpaper.blurPad
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize: Qt.size(wallpaper.decodeW, wallpaper.decodeH)   // decode at screen size, not at the file's (maybe 4K / 8K) size
        layer.enabled: wallpaper.blurAmt > 0.001
        layer.effect: MultiEffect { blurEnabled: true; blurMax: 64; blur: wallpaper.blurAmt; autoPaddingEnabled: false }
        opacity: (wallpaper.shown && wallpaper.wpOn) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
        onStatusChanged: {
            if (status !== Image.Ready) return
            wallpaper.shown = true
            if (wallpaper.swapping) wallpaper.settle()
        }
    }

    // ---- the new wallpaper, loaded in the background and shown through a growing circle
    Image {
        id: inc
        anchors.fill: parent
        anchors.margins: -wallpaper.blurPad
        visible: false
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize: Qt.size(wallpaper.decodeW, wallpaper.decodeH)
        onStatusChanged: if (status === Image.Ready && wallpaper.waiting) wallpaper.beginReveal()
    }
    Item {
        id: maskItem
        anchors.fill: parent
        visible: false
        layer.enabled: wallpaper.revealing || wallpaper.swapping     // the full-screen mask texture only exists during a change
        Rectangle {
            anchors.centerIn: parent
            width: wallpaper.maskSize
            height: width
            radius: width / 2
            color: "black"
        }
    }
    MultiEffect {
        id: reveal
        anchors.fill: parent
        anchors.margins: -wallpaper.blurPad
        visible: wallpaper.revealing || wallpaper.swapping
        source: inc
        blurEnabled: wallpaper.blurAmt > 0.001
        blurMax: 64
        blur: wallpaper.blurAmt
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: maskItem
        transformOrigin: Item.Center
    }
    // thin ring riding the edge of the circle
    Rectangle {
        anchors.centerIn: parent
        width: wallpaper.maskSize
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 2
        border.color: "#ffffff"
        visible: wallpaper.revealing
        opacity: 0.4 * (1 - Math.min(1, wallpaper.maskSize / wallpaper.diag))
    }

    // ---- the live wallpaper; it stops drawing whenever nobody can see it (the same rules as the moving stars)
    Loader {
        anchors.fill: parent
        active: wallpaper.liveOn && wallpaper.livePick === "sky"
        sourceComponent: LiveSky {
            pal: wallpaper.pal
            showWord: !wallpaper.opt || wallpaper.opt.deskLiveWord !== false
            running: wallpaper.liveRun
        }
    }
    Loader {
        anchors.fill: parent
        active: wallpaper.liveOn && wallpaper.livePick !== "sky"
        sourceComponent: LiveVideo {
            path: wallpaper.livePick
            running: wallpaper.liveRun
            onFailed: why => {
                Quickshell.execDetached(["notify-send", "-a", "Halcyon", "-i", "video-display", "Live wallpaper", "Could not play " + wallpaper.livePick.replace(/^.*\//, "") + ": back to the Halcyon sky. " + why])
                if (wallpaper.env && typeof wallpaper.env.setOpt === "function") wallpaper.env.setOpt("deskLivePick", "sky")
            }
        }
    }

    // ---- time-of-day grade (Settings > Splash, sky & time of day): a soft colour wash and a little dimming over the picture that follow
    // the sun (TimeOfDay.js: blue night, rose dawn, clear noon, amber golden hour, magenta dusk). It is only a rectangle: the picture and
    // its colours (palette, terminals, app themes) are untouched, so switching it off gives the plain wallpaper back at once. The clock
    // ticks once a minute, and only while the grade is on.
    readonly property bool todOn: !!opt && opt.todOn === true
    readonly property real todStrength: Math.max(0, Math.min(1, (opt && opt.todStrength !== undefined ? Number(opt.todStrength) : 60) / 100))
    property real todHour: TOD.hourOf(new Date())          // refreshed by todClock while the grade is on
    readonly property var todNow: TOD.at(todHour, todStrength)
    readonly property string todPhase: todNow.name
    SystemClock {
        id: todClock
        enabled: wallpaper.todOn
        precision: SystemClock.Minutes
        onDateChanged: wallpaper.todHour = TOD.hourOf(todClock.date)
    }
    onTodOnChanged: if (todOn) todHour = TOD.hourOf(new Date())
    Item {
        anchors.fill: parent
        opacity: wallpaper.todOn ? 1 : 0
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(wallpaper.todNow.r, wallpaper.todNow.g, wallpaper.todNow.b, wallpaper.todNow.tint)
        }
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, wallpaper.todNow.dim)
        }
    }

    // moving stars (Desktop builder): above the picture, so they work on a wallpaper and on the plain background alike
    DesktopStars {
        anchors.fill: parent
        pal: wallpaper.pal
        opt: wallpaper.opt
        env: wallpaper.env
    }

    // Dim behind widgets: Whole wallpaper (Settings > Widget builder; WidgetHost.qml does the other modes, around each widget)
    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: !wallpaper.opt || (wallpaper.opt.widgetDim || "wall") === "wall"
        opacity: Math.max(0.1, Math.min(0.8, wallpaper.opt && wallpaper.opt.widgetDimAmt !== undefined ? Number(wallpaper.opt.widgetDimAmt) : 0.35))
    }

    // the desktop widgets (Widget builder = how each looks, Desktop builder / desktop editor = where they sit)
    DeskWidgets {
        anchors.fill: parent
        visible: !wallpaper.widgetsHidden && wallpaper.opt.deskWidgetsOn !== false && !(wallpaper.env && wallpaper.env.lean === true)     // lean (a game runs): hidden, so every widget timer stops
                 && !(wallpaper.env && (wallpaper.env.deskCovered === true || wallpaper.env.fsQuiet === true))   // under windows: not drawn (no repaint, no re-blur above)
        pal: wallpaper.pal
        env: wallpaper.env
        opt: wallpaper.opt
        topInset: wallpaper.widgetsTop
    }

    SequentialAnimation {
        id: revealAnim
        ParallelAnimation {
            // circle grows from the centre, the old wallpaper gets pushed back as it is eaten
            NumberAnimation { target: wallpaper; property: "maskSize"; from: 0; to: wallpaper.diag * 1.02; duration: 1150; easing.type: Easing.InOutCubic }
            NumberAnimation { target: reveal; property: "scale"; from: 1.07; to: 1; duration: 1350; easing.type: Easing.OutCubic }
            NumberAnimation { target: cur; property: "scale"; from: 1; to: 1.035; duration: 1150; easing.type: Easing.InOutCubic }
        }
        ScriptAction { script: wallpaper.finishReveal() }
    }

    // switching the picture off frees both decoded copies; switching it on again loads the last wallpaper with the normal fade-in
    onWpOnChanged: {
        if (!wpOn) {
            revealAnim.stop()
            waiting = false                // (before resetReveal, which keeps incomingPath while something is waiting)
            resetReveal()
            inc.source = ""
            cur.source = ""
            shown = false
            gc()
        } else if (lastPath !== "") {
            var p = lastPath
            currentPath = ""
            incomingPath = ""
            show(p)
        }
    }

    // ---- flow: show(path) -> load -> beginReveal -> finishReveal -> settle
    function show(path) {
        if (!path) return
        lastPath = path
        if (!wpOn) {                                           // wallpaper switched off: no picture is decoded (saves the RAM); the colours still follow it
            if (path !== currentPath) { currentPath = path; runPalette(path) }
            return
        }
        if (path === currentPath || path === incomingPath) return
        var url = "file://" + path

        if (!shown && cur.source.toString() === "") {         // first wallpaper: plain fade in
            currentPath = path
            cur.source = url
            runPalette(path)
            return
        }
        if (revealAnim.running) {                              // interrupted: jump to where it was heading
            revealAnim.stop()
            cur.source = inc.source
            currentPath = incomingPath
            resetReveal()
        }
        waiting = true
        incomingPath = path
        inc.source = url
        if (inc.status === Image.Ready) beginReveal()
    }

    function beginReveal() {
        if (incomingPath === "") { waiting = false; return }       // nothing to reveal any more (the change was cancelled)
        waiting = false
        maskSize = 0
        revealing = true
        runPalette(incomingPath)      // island colours start following while the circle grows
        revealAnim.restart()
    }

    function finishReveal() {
        // hand the picture over to `cur` (same URL, so it is already in the pixmap cache)
        swapping = true
        cur.source = inc.source
        currentPath = incomingPath
        if (cur.status === Image.Ready) settle()
    }

    function settle() {
        swapping = false
        resetReveal()
        releaseIncoming()
    }

    function resetReveal() {
        revealing = false
        swapping = false
        cur.scale = 1
        reveal.scale = 1
        maskSize = 0
        if (!waiting) incomingPath = ""     // a newer wallpaper that is still loading keeps its name (a change during the hand-over used to wipe it, then the palette ran on "")
    }

    // `inc` only exists to feed the reveal. After the hand-over it would keep a second decoded copy + GPU texture alive
    // for as long as the wallpaper stays (hours), so drop it. `cur` has its own reference to the same cached pixmap.
    function releaseIncoming() {
        if (!revealing && !swapping && !waiting) { inc.source = ""; gc() }
    }

    // palette.sh reads the picture's own dominant colours (see island/scripts/palette.sh); the old `hx palette` is the fallback
    function runPalette(p) {
        Quickshell.execDetached(["sh", "-c", "bash \"$1/scripts/palette.sh\" \"$2\" || \"$HOME/.config/Halcyon/bin/hx\" palette \"$2\"", "sh", wallpaper.island, p])
    }

    // picking a picture (next, back, a thumbnail) switches the live wallpaper off, so the picture is what you see
    function leaveLive() { if (liveOn && env && typeof env.setOpt === "function") env.setOpt("deskLive", "off") }
    // Super + Alt + W (scripts/toggle_livewallpaper.sh) and the Settings tiles
    function toggleLive() { if (env && typeof env.setOpt === "function") env.setOpt("deskLive", liveOn ? "off" : "on") }
    function pickLive(path) {
        if (!env || typeof env.setOpt !== "function") return
        env.setOpt("deskLivePick", path === "" ? "sky" : path)
        if (!liveOn) env.setOpt("deskLive", "on")
    }

    function next() {
        leaveLive()
        wpProc.mode = "next"
        wpProc.arg = ""
        wpProc.running = true
    }

    // the previous wallpaper (scripts/wallpaper.sh remembers the last 30)
    function back() {
        leaveLive()
        wpProc.mode = "back"
        wpProc.arg = ""
        wpProc.running = true
    }

    // copy the current ONLINE wallpaper into your wallpaper folder (a notification says where it went)
    function keep() {
        Quickshell.execDetached(["bash", wallpaper.island + "/scripts/wallpaper.sh", "keep"])
    }

    // a specific file (Settings > Wallpaper thumbnails)
    function useFile(path) {
        leaveLive()
        if (!path) return
        wpProc.mode = "set"
        wpProc.arg = path
        wpProc.running = true
    }

    // The wallpaper is picked once per boot (see island/scripts/wallpaper.sh), so restarting
    // quickshell or reloading the config keeps the same one. "next" forces a new random pick.
    Process {
        id: wpProc
        property string mode: "current"
        property string arg: ""
        command: arg !== "" ? ["bash", wallpaper.island + "/scripts/wallpaper.sh", mode, arg] : ["bash", wallpaper.island + "/scripts/wallpaper.sh", mode]
        running: true
        onExited: { mode = "current"; arg = "" }
        stdout: SplitParser {
            onRead: data => wallpaper.show(data.trim())
        }
    }

    // quickshell ipc -p ~/.config/Halcyon/quickshell/island call wallpaper next   (also: set <path>)
    IpcHandler {
        target: "wallpaper"
        function next(): void { wallpaper.next() }
        function back(): void { wallpaper.back() }
        function keep(): void { wallpaper.keep() }
        function set(path: string): void { wallpaper.useFile(path) }
        function toggleLive(): string { wallpaper.toggleLive(); return wallpaper.liveOn ? "on" : "off" }      // what it is now
        function live(path: string): void { wallpaper.pickLive(path === "sky" ? "" : path) }
    }
}
