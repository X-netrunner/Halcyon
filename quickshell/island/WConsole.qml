import QtQuick
import Quickshell
import Quickshell.Io

// "Console": a terminal-style box on the desktop. It shows what a command prints (run again every few seconds, only while the widget is
// on screen) and a click opens the real console (QuickTerm). No keyboard focus is taken: it is a display, not a shell.
//   terminal | window | glass | retro | minimal
//   options: cmd (what to run), title, lines, width, every (seconds), prompt (show the command line), click
WBase {
    id: root

    readonly property string cmdText: String(opt("cmd", "")).trim()
    readonly property int maxLines: Math.max(1, Math.round(opt("lines", 8)))
    readonly property real boxW: opt("width", 380)
    readonly property real everyS: Math.max(2, opt("every", 10))
    readonly property bool showPrompt: opt("prompt", true) === true
    readonly property string title: String(opt("title", "console"))

    // the retro look is always green on black, the others use the widget's own colours
    readonly property bool retro: style === "retro"
    readonly property color txt: retro ? "#6dff9a" : fg
    readonly property color txtDim: retro ? Qt.alpha("#6dff9a", 0.6) : dim
    readonly property color lit: retro ? "#b6ffd0" : accent

    // everything the command printed last time (cut to the 240 first letters of each line); the last `lines` of it are shown, so
    // changing "Most lines" in the builder takes effect at once instead of at the next run
    property var rawLines: []
    property bool ran: false                      // the command has finished at least once (so an empty answer reads "no output", not "...")
    readonly property var outLines: rawLines.length > maxLines ? rawLines.slice(rawLines.length - maxLines) : rawLines

    // PATH gets the rice's own tools (hx, sysmode helpers) like the real console; stderr is shown too. TERM=dumb and COLUMNS keep
    // tools from drawing colours / tables wider than the box. A command that never ends (top, watch, ping ...) is stopped after a
    // few seconds (timeout) and what it printed so far is shown, instead of the box sitting on "..." forever.
    readonly property int cols: Math.max(20, Math.floor(boxW / Math.max(6, fsz * 0.6)))
    readonly property int killS: Math.max(3, Math.min(20, Math.round(everyS)))
    readonly property string wrapped: "export PATH=\"$HOME/.config/Halcyon/bin:$HOME/.local/bin:$PATH\" TERM=dumb NO_COLOR=1 COLUMNS=" + cols + "; ( " + cmdText + "\n) 2>&1 </dev/null"
    property string ranCmd: ""                    // the command the running / last run was started with
    function take(t) {
        if (ranCmd !== cmdText) return            // the command was changed while it ran: that answer belongs to the old one
        var s = String(t).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\x1b\][^\x07]*\x07/g, "").replace(/\r/g, "")
        var a = s.split("\n")
        while (a.length > 0 && a[a.length - 1].trim() === "") a.pop()
        for (var i = 0; i < a.length; i++) {
            if (a[i].length > 240) a[i] = a[i].substring(0, 240)
            a[i] = a[i].replace(/\t/g, "    ")
        }
        rawLines = a
        ran = true
    }
    Process {
        id: proc
        command: ["timeout", "-k", "1", String(root.killS), "sh", "-c", root.wrapped]
        stdout: StdioCollector { onStreamFinished: root.take(text) }
    }
    function runNow() { if (cmdText !== "" && !proc.running) { ranCmd = cmdText; proc.running = true } }
    Timer { running: root.live && root.cmdText !== ""; repeat: true; interval: root.everyS * 1000; triggeredOnStart: true; onTriggered: root.runNow() }
    // a new command (typed in the builder) replaces a running one at once and runs straight away
    onCmdTextChanged: {
        ran = false
        rawLines = []
        if (proc.running) proc.running = false
        if (live) restartT.restart()
    }
    Timer { id: restartT; interval: 250; onTriggered: root.runNow() }

    readonly property real fsz: sz(12.5)
    // "No box" in the Widget builder = no frame at all: the lines sit straight on the wallpaper (no dark rectangle, no scanlines)
    readonly property bool bare: w && w.look ? w.look.surface === "clear" : false
    implicitWidth: boxW
    implicitHeight: col.implicitHeight

    // the frame of each look sits behind the lines (the widget's own surface is the Widget builder's "Box")
    Rectangle {
        visible: !root.bare && (root.style === "terminal" || root.style === "retro")
        anchors.fill: parent; anchors.margins: -root.sz(6)
        radius: root.retro ? 4 : root.sz(10)
        color: root.retro ? "#050b07" : Qt.alpha(Qt.tint("#0b0c10", Qt.alpha(root.accent, 0.12)), 0.82)
        border.width: 1
        border.color: root.retro ? Qt.alpha("#6dff9a", 0.55) : Qt.alpha(root.accent, 0.35)
    }
    // retro scanlines
    Item {
        visible: root.retro && !root.bare
        anchors.fill: parent; anchors.margins: -root.sz(6); clip: true
        Repeater {
            model: Math.ceil(parent.height / 3)
            delegate: Rectangle { required property int index; y: index * 3; width: parent.width; height: 1; color: Qt.alpha("#000000", 0.28) }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: !root.editing && root.opt("click", true) === true && !!root.env
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.env.deskAct("console")
    }

    Column {
        id: col
        width: root.boxW
        spacing: root.sz(6)

        // title bar: three dots (window) or a quiet caption (the others)
        Row {
            visible: root.style !== "minimal"
            spacing: root.sz(7)
            height: root.sz(16)
            Repeater {
                model: root.style === "window" ? 3 : 0
                delegate: Rectangle {
                    required property int index
                    width: root.sz(10); height: width; radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: index === 0 ? "#ff6b6b" : (index === 1 ? "#ffd166" : "#6bff95")
                    border.width: 1; border.color: Qt.alpha("#000000", 0.35)
                }
            }
            WIco { b: root; visible: root.style !== "window"; text: root.glyph(0xF018D); color: root.lit; font.pixelSize: root.sz(13); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.title.toUpperCase(); color: root.txtDim; font.pixelSize: root.sz(10); font.letterSpacing: 2.5; anchors.verticalCenter: parent.verticalCenter }
        }
        Rectangle { visible: root.style === "window" || root.style === "glass"; width: parent.width; height: 1; color: Qt.alpha(root.fg, 0.14) }

        // the command line the output belongs to
        WLbl {
            visible: root.showPrompt && root.cmdText !== ""
            width: parent.width
            text: "❯ " + root.cmdText.replace(/\s+/g, " ")
            color: root.lit
            font.family: root.pal ? root.pal.mono : "monospace"; font.pixelSize: root.fsz
            elide: Text.ElideRight
        }
        // the output
        Column {
            width: parent.width
            spacing: 1
            Repeater {
                model: root.outLines
                delegate: WLbl {
                    required property string modelData
                    b: root
                    width: parent.width
                    text: modelData === "" ? " " : modelData
                    color: root.txt
                    font.family: root.pal ? root.pal.mono : "monospace"; font.pixelSize: root.fsz
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                }
            }
            WLbl {
                visible: root.outLines.length === 0
                b: root
                text: root.cmdText === "" ? "Pick a command in the Widget builder" : (root.ran ? "(no output)" : "…")
                color: root.txtDim
                font.family: root.pal ? root.pal.mono : "monospace"; font.pixelSize: root.fsz
            }
        }
        // the cursor
        Rectangle {
            visible: root.style !== "minimal"
            width: root.sz(8); height: root.sz(14)
            color: root.lit
            SequentialAnimation on opacity {
                running: root.live; loops: Animation.Infinite
                NumberAnimation { to: 0.1; duration: 520 }
                NumberAnimation { to: 1; duration: 520 }
            }
        }
    }
}
