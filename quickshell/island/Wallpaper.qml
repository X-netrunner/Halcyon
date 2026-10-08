import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: wallpaper
    color: "black"
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "wallpaper"

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

    // ---- the wallpaper currently on screen
    Image {
        id: cur
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize: Qt.size(wallpaper.decodeW, wallpaper.decodeH)   // decode at screen size, not at the file's (maybe 4K / 8K) size
        opacity: wallpaper.shown ? 1 : 0
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
        visible: false
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
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
        visible: wallpaper.revealing || wallpaper.swapping
        source: inc
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

    // ---- flow: show(path) -> load -> beginReveal -> finishReveal -> settle
    function show(path) {
        if (!path || path === currentPath || path === incomingPath) return
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
        incomingPath = ""
    }

    // `inc` only exists to feed the reveal. After the hand-over it would keep a second decoded copy + GPU texture alive
    // for as long as the wallpaper stays (hours), so drop it. `cur` has its own reference to the same cached pixmap.
    function releaseIncoming() {
        if (!revealing && !swapping && !waiting) inc.source = ""
    }

    // palette.sh reads the picture's own dominant colours (see island/scripts/palette.sh); the old `hx palette` is the fallback
    function runPalette(p) {
        Quickshell.execDetached(["sh", "-c", "bash \"$1/scripts/palette.sh\" \"$2\" || \"$HOME/.config/Halcyon/bin/hx\" palette \"$2\"", "sh", wallpaper.island, p])
    }

    function next() {
        wpProc.mode = "next"
        wpProc.arg = ""
        wpProc.running = true
    }

    // a specific file (Settings > Wallpaper thumbnails)
    function useFile(path) {
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
        function set(path: string): void { wallpaper.useFile(path) }
    }
}
