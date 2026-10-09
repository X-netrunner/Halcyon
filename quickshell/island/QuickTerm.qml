import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

// Top-left pop-out console for one-shot commands (sysmode switches, ls, ip a, ...).
//
//  open     hover mode: touch the top-left corner.  click mode: click the corner.
//           Either way SUPER+SHIFT+Enter opens it focused (and again closes it), or click the box to type.
//  close    hover mode: move the pointer away.  click mode: click the corner again.  Esc always works.
//           Auto-hide on = it closes whenever the pointer leaves, in both modes (never while you have text typed).
//  idle     empty input and nothing run yet: shows the sysmode / honeypot status (`hx status`) as plain console lines;
//           they fade away the moment you type
//  run      Enter. Output streams in. Ctrl+C stops, Ctrl+L clears, Up/Down = history
//  sudo     `sudo ...` and root sysmode actions (`sysmode stealth`, `sm lockdown`, or just `lockdown`) ask for your
//           password right in the console (masked) and feed it to sudo -S; nothing is stored or logged
//  TUIs     vim, htop, ssh, less ... need a real terminal, so they open in foot instead
//
// quickshell ipc -p ~/.config/Halcyon/quickshell/island call island quickterm
Scope {
    id: root
    property var pal
    property bool stars: true             // constellations in this box (Settings > Constellations)
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool clickMode: false
    property bool autoHide: false

    readonly property int boxW: 520
    readonly property int maxOut: 400
    readonly property string sysmodeBin: "/usr/local/bin/sysmode"
    readonly property string hx: Quickshell.env("HOME") + "/.config/Halcyon/bin/hx"
    readonly property string pwMarker: "SUDO_PW"
    readonly property var modes: ["secure", "stealth", "cyber", "lockdown"]
    readonly property var rootless: ["status", "logs", "dossier", "verify", "check", "doctor", "help", "-h", "--help"]
    readonly property var tuis: ["vim", "nvim", "vi", "nano", "emacs", "htop", "btop", "top", "less", "more", "man", "ssh",
                                 "mosh", "tmux", "screen", "ncmpcpp", "mutt", "ranger", "yazi", "fzf", "python", "python3", "node", "irb"]
    readonly property var modeColor: pal.modeColor
    readonly property string mono: pal.mono

    property bool open: false
    property bool pinned: false                      // opened from the keyboard: stays until closed (unless auto-hide)
    property bool focused: false                     // box has the keyboard
    property bool grabKeys: false                    // first moments after a keybind: Exclusive, then normal on-demand focus
    readonly property real reveal: open ? 1 : 0
    readonly property bool shown: open

    property string cwd: Quickshell.env("HOME")
    property var st: ({})
    property var history: []
    property int histIdx: -1
    property bool busy: false
    property bool askPass: false

    ListModel { id: out }

    // ---------- open / close ----------
    readonly property bool mayAutoClose: !askPass && input.text === "" && (autoHide || (!clickMode && !pinned))
    function setHover(on) {
        if (on) { closeT.stop(); if (!clickMode) open = true }
        else if (mayAutoClose) { closeT.interval = 550; closeT.restart() }
    }
    function cornerTap() { if (open) close(); else { closeT.stop(); open = true } }
    function toggle() {
        if (open && focused) { close(); return }
        closeT.stop()
        open = true
        pinned = true
        takeFocus()
    }
    function takeFocus() {
        focused = true
        grabKeys = true
        grabT.restart()
        Qt.callLater(function () { input.forceActiveFocus() })
    }
    function close() {
        closeT.stop()
        if (askPass) cancelRun()
        focused = false
        open = false
        pinned = false
    }
    Timer { id: closeT; interval: 550; onTriggered: if (root.mayAutoClose) root.close() }
    // Exclusive only long enough to be granted the keyboard; after that it is on-demand, so clicking another
    // window or opening a terminal hands the keyboard straight to it and nothing stays stuck
    Timer { id: grabT; interval: 350; onTriggered: root.grabKeys = false }

    // a new window took the keyboard: let go, a click on the box takes it back
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "openwindow") root.focused = false
        }
    }

    // ---------- output ----------
    property var pend: []                 // lines waiting to be shown (flushed every 40 ms)
    function push(text, kind) {
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) pend.push({ t: lines[i], k: kind })
        if (!flushT.running) flushT.start()
    }
    function toEnd() { view.positionViewAtEnd() }
    function flushOut() {
        var p = pend
        pend = []
        if (p.length > maxOut) p = p.slice(p.length - maxOut)      // only the last maxOut lines could stay anyway
        for (var i = 0; i < p.length; i++) out.append(p[i])
        if (out.count > maxOut) out.remove(0, out.count - maxOut)
        Qt.callLater(toEnd)
    }
    Timer { id: flushT; interval: 40; onTriggered: root.flushOut() }
    function clearOut() { pend = []; out.clear() }
    function cancelRun() { askPass = false; runner.running = false }

    // ---------- running a command ----------
    function words(s) { return s.trim().split(/\s+/) }
    function sudoed(rest) { return "sudo -S -p $'" + pwMarker + "\\n' " + rest }

    function prepare(line) {
        var w = words(line)
        var first = w[0]
        if (w.length === 1 && modes.indexOf(first) >= 0) { w = ["sysmode", first]; line = "sysmode " + first }
        if (first === "sm") { w[0] = "sysmode"; line = "sysmode" + line.trim().substring(2) }
        if (w[0] === "sysmode") {
            var action = w[1] || "status"
            var rest = line.trim().substring(7)
            var cmd = sysmodeBin + (rest.length ? rest : " status")
            return { cmd: rootless.indexOf(action) >= 0 ? cmd : sudoed(cmd), tui: false }
        }
        if (first === "sudo") return { cmd: sudoed(line.trim().substring(4).trim()), tui: false }
        return { cmd: line, tui: tuis.indexOf(first) >= 0 }
    }

    function submit(raw) {
        var line = raw.trim()
        if (line === "") return
        if (history[history.length - 1] !== line) history = history.concat([line]).slice(-100)
        histIdx = -1
        push(cwdLabel() + " ❯ " + line, "cmd")

        if (line === "clear" || line === "cls") { clearOut(); return }
        if (line === "exit" || line === "quit") { close(); return }
        if (line === "help") {
            push("sysmode: secure | stealth | cyber | lockdown | status | logs | dossier [ip]   (sm = sysmode)\n" +
                 "sudo works here: it asks for your password in this line.\n" +
                 "cd, clear, exit, Ctrl+C stop, Ctrl+L clear, Up/Down history. Anything else runs in bash.\n" +
                 "vim / htop / ssh ... open in a real terminal.", "info")
            return
        }
        var cd = line.match(/^cd(?:\s+(.*))?$/)
        if (cd) { cdProc.target = (cd[1] || "~").trim(); cdProc.running = true; return }
        if (busy) { push("still running: Ctrl+C to stop it first", "err"); return }

        var p = prepare(line)
        if (p.tui) {
            Quickshell.execDetached({ command: ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh", "term-exec", "bash", "-c", p.cmd + "; exec bash"], workingDirectory: cwd })
            push("opened in a terminal window", "info")
            return
        }
        runner.command = ["bash", "-c", "exec 2>&1; " + p.cmd]
        runner.running = true
    }
    function cwdLabel() {
        var home = Quickshell.env("HOME")
        var c = cwd.indexOf(home) === 0 ? "~" + cwd.substring(home.length) : cwd
        var parts = c.split("/")
        return parts.length > 2 ? "…/" + parts[parts.length - 1] : c
    }

    Process {
        id: runner
        workingDirectory: root.cwd
        stdinEnabled: true
        onRunningChanged: { root.busy = running; if (!running) root.askPass = false }
        stdout: SplitParser {
            onRead: d => {
                var l = d.replace(/\r/g, "")
                if (l === root.pwMarker) { root.askPass = true; root.takeFocus(); return }
                root.push(l, "out")
            }
        }
        onExited: (code, status) => {
            if (code !== 0) root.push("exit " + code + (code === 126 || code === 127 ? "  (not found / not allowed)" : ""), "err")
        }
    }
    Process {
        id: cdProc
        property string target: "~"
        workingDirectory: root.cwd
        command: ["bash", "-c", "cd -- \"${1/#\\~/$HOME}\" 2>&1 && pwd", "_", target]
        stdout: StdioCollector {
            onStreamFinished: {
                var t = text.trim()
                if (t.charAt(0) === "/") root.cwd = t.split("\n").pop()
                else if (t) root.push(t, "err")
            }
        }
    }

    // status feed: only while the box is showing
    Process {
        id: statusProc
        command: [root.hx, "status"]
        property string last: ""
        stdout: StdioCollector { onStreamFinished: { if (text === statusProc.last) return; statusProc.last = text; try { root.st = JSON.parse(text) } catch (e) {} } }
    }
    // 3 s while the idle status rows are what you see, a slow 15 s once the console holds output
    Timer { interval: out.count === 0 ? 3000 : 15000; running: root.shown; repeat: true; triggeredOnStart: true; onTriggered: if (!statusProc.running) statusProc.running = true }

    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function dot(on, label) {
        return "<font color='" + (on ? pal.good : pal.muted) + "'>" + (on ? "●" : "○") + "</font> " + esc(label)
    }
    function row(k, v) { return "<font color='" + pal.muted + "'>" + esc(k.padEnd(12, " ")) + "</font>" + v }
    readonly property var statusRows: {
        var s = st || {}
        var m = sysmode || s.mode || ""
        var mc = modeColor[m] || pal.muted
        var rd = !!s.readable
        var num = function (v) { return (v === undefined || v === null) ? "–" : String(v) }
        var rows = [
            row("sysmode", "<font color='" + mc + "'><b>" + esc(m !== "" ? m : "not set") + "</b></font>"),
            row("honeypot", dot(!!s.honeypot, s.honeypot ? "active" : "off")),
            row("ids", dot(!!s.ids, s.ids ? "active" : "off")),
            row("cowrie", dot(!!s.cowrie, s.cowrie ? "active" : "off")),
            row("decoy wifi", dot(!!s.decoyWifi, s.decoyWifi ? s.decoyWifi : "off")),
            "&nbsp;",
            row(">ids hit", ": " + num(s.idsAlerts)),
            row(">alerts", ": " + (rd ? num(s.today) + " today · " + num(s.alerts) + " total" : "–")),
            row(">attackers", ": " + (rd ? num(s.attackers) : "–"))
        ]
        if (s.last) {
            var ev = String(s.last)
            var i = ev.indexOf("] ")                 // drop the leading [timestamp]
            if (ev.charAt(0) === "[" && i > 0) ev = ev.substring(i + 2)
            rows.push(row(">last", ": " + esc(ev.slice(0, 52))))
        }
        if (!rd) rows.push("<font color='" + pal.muted + "'>log not readable as your user: <b>sudo sysmode logs</b></font>")
        return rows
    }

    PanelWindow {
        id: win
        anchors { top: true; left: true }
        implicitWidth: root.boxW + 60
        implicitHeight: 560
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-term"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: !root.focused ? WlrKeyboardFocus.None
                                   : (root.grabKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)

        mask: Region { item: zone }

        // ONE hover zone covers the corner trigger, the gap and the whole box, so moving from the corner onto the
        // box (or the box sliding in under a resting pointer) never counts as "left": no more flicker in and out
        Item {
            id: zone
            anchors.top: parent.top
            anchors.left: parent.left
            width: root.shown ? root.boxW + 40 : (root.clickMode ? 28 : 14)
            height: root.shown ? box.y + box.height + 24 : (root.clickMode ? 28 : 14)
            HoverHandler { onHoveredChanged: root.setHover(hovered) }

            // click mode: a faint tab marks the corner
            Rectangle {
                visible: root.clickMode && !root.shown
                x: 3; y: 3; width: 12; height: 12; radius: 6
                color: Qt.alpha(root.pal.accent, 0.35)
            }
            Item {
                width: 20; height: 14
                TapHandler {
                    enabled: root.clickMode
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.cornerTap()
                }
            }

        Glass {
            id: box
            pal: root.pal
            x: 22 - (1 - root.reveal) * (root.boxW * 0.5)
            y: root.pal.boxTop - (1 - root.reveal) * (height + root.pal.boxTop + 14)
            width: root.boxW
            height: Math.min(520, 40 + body.implicitHeight + 76)
            radius: root.pal.rLg
            opacityBody: root.pal.glassSolid - 0.04
            opacity: Math.min(1, root.reveal * 1.6)
            visible: opacity > 0.01
            border.color: root.focused ? root.pal.lineFocus : Qt.alpha(root.pal.accent, 0.30)
            Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on y { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

            MouseArea {
                anchors.fill: parent
                onClicked: root.takeFocus()
            }

            // hover mode: resting the pointer on the box itself (not just the corner) is enough to type, no click needed.
            // Leaving with an empty prompt closes it and hands the keyboard straight back.
            HoverHandler { onHoveredChanged: { if (hovered && root.open && !root.focused && !root.clickMode) dwellT.restart(); else dwellT.stop() } }
            Timer { id: dwellT; interval: 250; onTriggered: if (root.open && !root.focused) root.takeFocus() }

            // same quiet look as the tree: drifting dots, and the shield / dragon for lockdown / stealth
            Backdrop {
                visible: root.shown && root.stars
                anchors.fill: parent
                anchors.margins: 14
                pal: root.pal
                mode: root.sysmode
                avatarStars: root.starData
                profileStars: root.profileStars
                dots: 8
                artStrength: 1
                artFit: 0.95
                artShift: 90
            }


            // ---------- title line ----------
            Item {
                id: head
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 16 }
                height: 20
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "❯ halcyon"
                    color: root.pal.accent
                    font.family: root.mono
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.centerIn: parent
                    visible: root.busy
                    text: root.askPass ? "waiting for password" : "running · Ctrl+C"
                    color: root.pal.accent
                    font.family: root.mono
                    font.pixelSize: 11
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.sysmode !== "" ? root.sysmode : "no mode")
                    color: root.modeColor[root.sysmode] || root.pal.muted
                    font.family: root.mono
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }
            Rectangle { id: sep1; anchors { left: parent.left; right: parent.right; top: head.bottom; leftMargin: 20; rightMargin: 20; topMargin: 10 } height: 1; color: root.pal.lineSoft }

            // ---------- body: status when idle, output once you type / run ----------
            Item {
                id: body
                anchors { left: parent.left; right: parent.right; top: sep1.bottom; bottom: sep2.top; leftMargin: 20; rightMargin: 20; topMargin: 12; bottomMargin: 10 }
                readonly property bool idle: input.text === "" && out.count === 0 && !root.busy
                implicitHeight: idle ? statusCol.implicitHeight : Math.min(320, Math.max(40, view.contentHeight + 4))

                Column {
                    id: statusCol
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    spacing: 3
                    opacity: body.idle ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    Repeater {
                        model: root.statusRows
                        delegate: Text {
                            required property string modelData
                            width: statusCol.width
                            text: modelData
                            textFormat: Text.RichText
                            color: root.pal.text
                            elide: Text.ElideRight
                            font.family: root.mono
                            font.pixelSize: 12
                            lineHeight: 1.1
                        }
                    }
                    Text {
                        topPadding: 6
                        text: "type a command · secure · stealth · cyber · lockdown"
                        color: Qt.alpha(root.pal.muted, 0.8)
                        font.family: root.mono
                        font.pixelSize: 10
                    }
                }

                ListView {
                    id: view
                    anchors.fill: parent
                    clip: true
                    model: out
                    opacity: body.idle ? 0 : 1
                    visible: opacity > 0.01
                    boundsBehavior: Flickable.StopAtBounds
                    TapHandler { onTapped: root.takeFocus() }
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    delegate: Text {
                        required property string t
                        required property string k
                        width: view.width
                        text: t === "" ? " " : t
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAnywhere
                        color: k === "cmd" ? root.pal.accent : k === "err" ? root.pal.bad : k === "info" ? root.pal.muted : root.pal.text
                        font.family: root.mono
                        font.pixelSize: 12
                        font.weight: k === "cmd" ? Font.DemiBold : Font.Normal
                    }
                }
            }

            // ---------- input line ----------
            Rectangle { id: sep2; anchors { left: parent.left; right: parent.right; bottom: inputRow.top; leftMargin: 20; rightMargin: 20; bottomMargin: 8 } height: 1; color: root.pal.lineSoft }
            Item {
                id: inputRow
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 16 }
                height: 22

                TapHandler { onTapped: root.takeFocus() }
                Text {
                    id: prompt
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.askPass ? "[sudo] password ❯" : root.cwdLabel() + " ❯"
                    color: root.askPass ? root.pal.warn : root.pal.accent
                    font.family: root.mono
                    font.pixelSize: 13
                }
                TextInput {
                    id: input
                    anchors.left: prompt.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.pal.text
                    selectionColor: Qt.alpha(root.pal.accent, 0.4)
                    font.family: root.mono
                    font.pixelSize: 13
                    clip: true
                    echoMode: root.askPass ? TextInput.Password : TextInput.Normal
                    passwordCharacter: "•"
                    onTextEdited: root.histIdx = -1
                    // the field swallows the click, so ask for the keyboard here too (passive: the cursor still moves)
                    TapHandler { onTapped: root.takeFocus() }

                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Escape) {
                            if (root.askPass) { root.cancelRun(); text = "" } else root.close()
                            e.accepted = true
                        }
                        else if (e.key === Qt.Key_C && (e.modifiers & Qt.ControlModifier) && root.busy) { root.cancelRun(); text = ""; e.accepted = true }
                        else if (e.key === Qt.Key_L && (e.modifiers & Qt.ControlModifier)) { root.clearOut(); e.accepted = true }
                        else if (e.key === Qt.Key_U && (e.modifiers & Qt.ControlModifier)) { text = ""; e.accepted = true }
                        else if (!root.askPass && e.key === Qt.Key_Up && root.history.length) {
                            root.histIdx = root.histIdx < 0 ? root.history.length - 1 : Math.max(0, root.histIdx - 1)
                            text = root.history[root.histIdx]; cursorPosition = text.length; e.accepted = true
                        } else if (!root.askPass && e.key === Qt.Key_Down && root.histIdx >= 0) {
                            root.histIdx++
                            text = root.histIdx >= root.history.length ? "" : root.history[root.histIdx]
                            if (root.histIdx >= root.history.length) root.histIdx = -1
                            cursorPosition = text.length; e.accepted = true
                        }
                    }
                    onAccepted: {
                        var l = text
                        text = ""
                        if (root.askPass) { runner.write(l + "\n"); root.askPass = false; return }
                        root.submit(l)
                    }
                }
                Text {
                    anchors.left: prompt.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    visible: input.text === "" && !root.focused
                    text: "rest the pointer here, or SUPER+SHIFT+Enter, to type"
                    color: Qt.alpha(root.pal.muted, 0.7)
                    font.family: root.mono
                    font.pixelSize: 11
                }
            }
        }
        }
    }
}
