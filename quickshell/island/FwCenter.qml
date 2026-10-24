pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Firewall Center.   >firewall in the launcher (also the IPC call `firewallcenter`, Settings > Backup > Firewall).
// Everything ai-firewall knows, in one window:
//   Overview  is it protecting, a live graph of what it drops, counters, the latest detections
//   Bans      who is banned and why; lift one, or ban an address yourself
//   Rules     the network profile in use, open ports, narrower rules (edit the config from here)
//   Feeds     the lists of known-bad networks it loads, and when they were refreshed
//   History   what it did: bans, lifts, profile switches, feed updates
//   Ask       the network doctor's findings, and questions to the firewall's local AI (its suggested fixes are buttons)
// It reads /run/ai-firewall/status.json and runs `ai-firewall` without root. Anything that changes the firewall runs in the
// pop-out console (QuickTerm: sudo asks for the password there, [y/N] questions are answered there); the window steps aside
// so the console gets the keyboard. Only the full-screen ones (the terminal dashboard, editing the config) open a terminal.
// Nothing runs while the window is closed.
Scope {
    id: root
    property var pal
    property bool open: false
    property string tab: "overview"            // overview | bans | rules | feeds | history | ask
    signal consoleRequested(string cmd)        // shell.qml runs it in the pop-out console

    readonly property string scripts: Quickshell.env("HOME") + "/.config/Halcyon/scripts"
    function inTerminal(cmd) {
        Quickshell.execDetached(["bash", scripts + "/apps.sh", "term-exec", "bash", "-c", cmd])
    }
    // `sudo ai-firewall <args>` in the console. Only plain words reach the shell: everything here is built from the daemon's
    // own status, the doctor's fixed fix ids or validated input, but the console runs bash, so it is checked once more.
    function sudoThen(args) {
        args = String(args).trim()
        if (!/^[A-Za-z0-9 ._:\/-]+$/.test(args)) return
        hide()
        consoleRequested("sudo ai-firewall " + args)
    }

    // ---- status (re-read every 2 s while open: the daemon replaces the file, which a watch would lose)
    property var st: null
    readonly property bool alive: st !== null && (Date.now() / 1000 - (st.updated_unix || 0)) < 30
    property double lastDropped: -1
    property double lastPassed: -1
    property double readAt: 0
    property var dropHist: []                  // drops per second, newest last (the graph)
    property real passRate: 0
    property real dropRate: 0
    readonly property var bans: st ? (st.bans || []) : []
    readonly property var recent: st ? (st.recent || []).slice().reverse() : []

    FileView {
        id: statusFile
        path: "/run/ai-firewall/status.json"
        printErrors: false
        onLoaded: {
            try {
                const s = JSON.parse(text())
                const dropped = (s.dropped_policy || 0) + (s.dropped_blocklist || 0)
                const dt = Math.max(1, (Date.now() - root.readAt) / 1000)
                if (root.lastDropped >= 0) {
                    root.dropRate = Math.max(0, (dropped - root.lastDropped) / dt)
                    root.passRate = Math.max(0, (s.passed - root.lastPassed) / dt)
                    const h = root.dropHist.slice(-89)
                    h.push(root.dropRate)
                    root.dropHist = h
                }
                root.lastDropped = dropped
                root.lastPassed = s.passed || 0
                root.readAt = Date.now()
                root.st = s
            } catch (e) { root.st = null }
        }
        onLoadFailed: root.st = null
    }
    Timer { interval: 2000; repeat: true; running: root.open; triggeredOnStart: true; onTriggered: statusFile.reload() }

    // ---- history
    property var hist: []
    Process {
        id: histProc
        command: ["ai-firewall", "history", "--json", "-n", "200"]
        stdout: StdioCollector { onStreamFinished: { try { root.hist = JSON.parse(text).reverse() } catch (e) { root.hist = [] } } }
    }
    Timer { interval: 5000; repeat: true; running: root.open && root.tab === "history"; triggeredOnStart: true; onTriggered: if (!histProc.running) histProc.running = true }

    // ---- doctor
    property var findings: []
    property bool doctorRan: false
    Process {
        id: doctorProc
        command: ["ai-firewall", "doctor", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.findings = JSON.parse(text).findings || [] } catch (e) { root.findings = [] } root.doctorRan = true } }
    }

    // ---- ask: streams `ai-firewall ask`; the "suggested:" lines become buttons
    property var msgs: []                      // { role: "you" | "fw", text, cmds: [] }
    property string answer: ""
    property var answerCmds: []
    property bool inSuggest: false
    property string askModel: ""
    readonly property bool asking: askProc.running
    function ask(q) {
        q = q.trim()
        if (q === "" || asking) return
        msgs = msgs.concat([{ role: "you", text: q, cmds: [] }])
        answer = ""; answerCmds = []; inSuggest = false
        askProc.command = ["ai-firewall", "ask", q]
        askProc.running = true
    }
    Process {
        id: askProc
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() === "suggested:") { root.inSuggest = true; return }
                if (root.inSuggest) {
                    const c = line.split("#")[0].trim()
                    if (c.indexOf("sudo ai-firewall ") === 0) root.answerCmds = root.answerCmds.concat([{ cmd: c.substring(17), what: (line.split("#")[1] || "").trim() }])
                    return
                }
                root.answer += (root.answer === "" ? "" : "\n") + line
            }
        }
        stderr: SplitParser { onRead: line => { const m = line.match(/^\((.+)\)$/); if (m) root.askModel = m[1] } }
        onExited: {
            root.msgs = root.msgs.concat([{ role: "fw", text: root.answer.trim() || "No answer.", cmds: root.answerCmds }])
            root.answer = ""
        }
    }

    function show(t) {
        if (t) tab = t
        open = true
        if (tab === "ask" && !doctorRan) doctorProc.running = true
    }
    function hide() { open = false }
    function toggle() { if (open) hide(); else show("") }
    function setTab(t) {
        tab = t
        if (t === "ask" && !doctorRan && !doctorProc.running) doctorProc.running = true
        if (t === "history" && !histProc.running) histProc.running = true
    }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    function dur(s) {
        if (s <= 0) return "forever"
        if (s < 120) return Math.round(s) + "s"
        if (s < 7200) return Math.floor(s / 60) + "m"
        if (s < 172800) return Math.floor(s / 3600) + "h" + String(Math.floor(s % 3600 / 60)).padStart(2, "0")
        return Math.floor(s / 86400) + "d"
    }
    function count(n) {
        if (n >= 1e7) return Math.round(n / 1e6) + "M"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
        if (n >= 1e4) return Math.round(n / 1e3) + "k"
        return String(n || 0)
    }
    function ago(t) { return dur(Math.max(1, Date.now() / 1000 - t)) + " ago" }
    readonly property color stateColor: !alive ? pal.bad : (st.mode === "enforce" ? pal.good : pal.warn)

    // ======================================================================================== the window
    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-firewall"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(() => qp.forceActiveFocus()) }
                Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true } }

                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: Math.min(1100, qp.width - 80)
                    height: Math.min(720, qp.height - 80)
                    radius: root.pal.rXl
                    opacityBody: 0.97
                    anchors.centerIn: parent
                    opacity: qp.reveal
                    scale: 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== sidebar: state + tabs
                        Item {
                            Layout.preferredWidth: 236
                            Layout.fillHeight: true
                            Item {
                                anchors.fill: parent
                                anchors.margins: 1
                                clip: true
                                Rectangle { width: parent.width + root.pal.rXl; height: parent.height; radius: root.pal.rXl; color: Qt.alpha(root.pal.surface, 0.35) }
                            }
                            Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right; topMargin: 24; bottomMargin: 24 } width: 1; color: root.pal.lineSoft }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 22
                                anchors.rightMargin: 23
                                spacing: 6

                                Row {
                                    spacing: 12
                                    Rectangle {
                                        width: 42; height: 42; radius: 13
                                        color: Qt.alpha(root.stateColor, 0.15)
                                        Text {
                                            anchors.centerIn: parent
                                            text: String.fromCodePoint(root.alive ? 0xF0565 : 0xF099D)
                                            color: root.stateColor
                                            font.family: root.pal.font
                                            font.pixelSize: 22
                                        }
                                    }
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 1
                                        Text { text: "Firewall"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                                        Text {
                                            text: !root.st ? "not running" : !root.alive ? "not responding" : root.st.mode === "enforce" ? "protecting" : "monitoring only"
                                            color: root.stateColor
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                    }
                                }
                                Item { implicitHeight: 14 }

                                Repeater {
                                    model: [
                                        { id: "overview", label: "Overview", glyph: 0xF0565 },
                                        { id: "bans", label: "Bans", glyph: 0xF0156 },
                                        { id: "rules", label: "Rules", glyph: 0xF0493 },
                                        { id: "feeds", label: "Feeds", glyph: 0xF0E8F },
                                        { id: "history", label: "History", glyph: 0xF02DA },
                                        { id: "ask", label: "Ask & doctor", glyph: 0xF0B79 }
                                    ]
                                    delegate: Rectangle {
                                        id: tabRow
                                        required property var modelData
                                        readonly property bool on: root.tab === modelData.id
                                        Layout.fillWidth: true
                                        implicitHeight: 38
                                        radius: 12
                                        color: on ? Qt.alpha(root.pal.accent, 0.16) : (tabMa.containsMouse ? root.pal.fillHover : "transparent")
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        Row {
                                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                            spacing: 12
                                            Text { text: String.fromCodePoint(tabRow.modelData.glyph); color: tabRow.on ? root.pal.accent : root.pal.muted; font.family: root.pal.font; font.pixelSize: 16; anchors.verticalCenter: parent.verticalCenter }
                                            Text {
                                                text: tabRow.modelData.label + (tabRow.modelData.id === "bans" && root.bans.length > 0 ? "  " + root.bans.length : "")
                                                color: tabRow.on ? root.pal.text : root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                font.weight: tabRow.on ? Font.DemiBold : Font.Normal
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                        MouseArea { id: tabMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setTab(tabRow.modelData.id) }
                                    }
                                }
                                Item { Layout.fillHeight: true }

                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    visible: root.st !== null
                                    text: root.st ? ((root.st.interface || "no uplink") + " · " + (root.st.xdp_mode || "-") + " XDP\n"
                                        + "profile: " + (root.st.profile || "default") + "\nup " + root.dur(root.st.updated_unix - root.st.started_unix)
                                        + (root.st.attaches > 1 ? " · healed " + (root.st.attaches - 1) + "×" : "")) : ""
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                    lineHeight: 1.2
                                }
                                ActionChip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0128); label: "Terminal dashboard"; onClicked: root.inTerminal("sudo ai-firewall top") }
                                ActionChip {
                                    Layout.fillWidth: true
                                    visible: root.st === null
                                    pal: root.pal
                                    label: "Start the firewall"
                                    onClicked: { root.hide(); root.consoleRequested("sudo systemctl start ai-firewall") }
                                }
                            }
                        }

                        // ======================== content
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            // ---------------- Overview
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 16
                                visible: root.tab === "overview"

                                Text { text: "Overview"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.DemiBold }

                                // the config file is broken: say so, the last config that worked is what applies
                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: root.st !== null && !!root.st.config_error
                                    implicitHeight: cfgErr.implicitHeight + 22
                                    radius: root.pal.rMd
                                    color: Qt.alpha(root.pal.bad, 0.12)
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 16; rightMargin: 10 }
                                        spacing: 12
                                        Text {
                                            id: cfgErr
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            text: "The config file has an error, so the last config that worked is in force.\n" + (root.st && root.st.config_error ? root.st.config_error : "")
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                        ActionChip { pal: root.pal; label: "Edit config"; onClicked: root.inTerminal("sudoedit /etc/ai-firewall/config.toml") }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 12
                                    Repeater {
                                        model: [
                                            { v: root.st ? root.count(root.st.passed) : "–", sub: Math.round(root.passRate) + "/s", label: "packets passed", c: root.pal.good },
                                            { v: root.st ? root.count(root.st.dropped_policy) : "–", sub: Math.round(root.dropRate) + "/s now", label: "blocked by your rules", c: root.pal.warn },
                                            { v: root.st ? root.count(root.st.dropped_blocklist) : "–", sub: root.bans.length + " banned now", label: "from banned sources", c: root.pal.bad },
                                            { v: root.st ? root.count(root.st.dropped_feed || 0) : "–", sub: root.count(root.st ? (root.st.feed_networks || 0) : 0) + " networks listed", label: "from blocklists", c: root.pal.accent2 }
                                        ]
                                        delegate: Rectangle {
                                            id: tile
                                            required property var modelData
                                            Layout.fillWidth: true
                                            Layout.preferredWidth: 1
                                            implicitHeight: 76
                                            radius: root.pal.rLg
                                            color: root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.surface, 0.8)
                                            Column {
                                                anchors { left: parent.left; leftMargin: 18; right: parent.right; verticalCenter: parent.verticalCenter }
                                                spacing: 3
                                                Row {
                                                    spacing: 8
                                                    Text { id: tv; text: tile.modelData.v; color: tile.modelData.c; font.family: root.pal.uiFont; font.pixelSize: 24; font.weight: Font.DemiBold }
                                                    Text { anchors.baseline: tv.baseline; text: tile.modelData.sub; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                                }
                                                Text { text: tile.modelData.label; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                            }
                                        }
                                    }
                                }

                                // live graph: drops per second over the last three minutes
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 170
                                    radius: root.pal.rLg
                                    color: root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.surface, 0.8)
                                    Text {
                                        anchors { left: parent.left; top: parent.top; margins: 14 }
                                        text: "Dropped per second · last 3 minutes"
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                    }
                                    Canvas {
                                        id: graph
                                        anchors { fill: parent; topMargin: 36; leftMargin: 14; rightMargin: 14; bottomMargin: 12 }
                                        property var data: root.dropHist
                                        onDataChanged: requestPaint()
                                        onPaint: {
                                            const ctx = getContext("2d")
                                            ctx.reset()
                                            const d = data, n = 90
                                            if (d.length < 2) return
                                            const max = Math.max(4, Math.max.apply(null, d) * 1.15)
                                            const step = width / (n - 1)
                                            const x0 = width - (d.length - 1) * step
                                            ctx.beginPath()
                                            for (let i = 0; i < d.length; i++) {
                                                const x = x0 + i * step, y = height - d[i] / max * height
                                                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                                            }
                                            ctx.strokeStyle = root.pal.accent
                                            ctx.lineWidth = 2
                                            ctx.stroke()
                                            ctx.lineTo(width, height); ctx.lineTo(x0, height); ctx.closePath()
                                            const g = ctx.createLinearGradient(0, 0, 0, height)
                                            g.addColorStop(0, Qt.alpha(root.pal.accent, 0.30))
                                            g.addColorStop(1, Qt.alpha(root.pal.accent, 0.0))
                                            ctx.fillStyle = g
                                            ctx.fill()
                                        }
                                    }
                                    Text {
                                        anchors.centerIn: graph
                                        visible: root.dropHist.length < 2
                                        text: root.st ? "collecting…" : "the firewall is not running"
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                    }
                                }

                                Text { text: root.pal.cap("LATEST DETECTIONS"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                ListView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 6
                                    model: root.recent
                                    delegate: DetRow { pal: root.pal; c: root }
                                    Text { visible: root.recent.length === 0; text: "all quiet"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                }
                            }

                            // ---------------- Bans
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14
                                visible: root.tab === "bans"

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "Bans"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                    InputPill {
                                        id: banIn
                                        pal: root.pal
                                        hint: "address to ban for an hour"
                                        onSubmitted: v => { root.sudoThen("ban " + v.replace(/[^0-9a-fA-F:.\/]/g, "") + " --minutes 60"); banIn.clear() }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "Sources that scan or flood this machine are banned for 2 minutes, twice as long each time they come back (up to a day). Your router, DNS and own networks are never banned."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                                ListView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 6
                                    model: root.bans
                                    delegate: Rectangle {
                                        id: banRow
                                        required property var modelData
                                        width: ListView.view.width
                                        implicitHeight: 52
                                        radius: root.pal.rMd
                                        color: root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.surface, 0.8)
                                        RowLayout {
                                            anchors { fill: parent; leftMargin: 16; rightMargin: 10 }
                                            spacing: 14
                                            Text { text: banRow.modelData.ip; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 230; elide: Text.ElideRight }
                                            Text { text: root.dur(banRow.modelData.remaining_secs); color: root.pal.accent2; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 64 }
                                            Text {
                                                text: banRow.modelData.source
                                                color: banRow.modelData.source === "auto" ? root.pal.bad : banRow.modelData.source === "config" ? root.pal.muted : root.pal.warn
                                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 50
                                            }
                                            Text { text: banRow.modelData.reason; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.fillWidth: true; elide: Text.ElideRight }
                                            ActionChip {
                                                visible: banRow.modelData.source !== "config"
                                                pal: root.pal
                                                label: "Lift"
                                                implicitHeight: 32
                                                onClicked: root.sudoThen("unban " + banRow.modelData.ip)
                                            }
                                        }
                                    }
                                    Text { visible: root.bans.length === 0; text: "Nobody is banned right now."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                }
                            }

                            // ---------------- Rules
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14
                                visible: root.tab === "rules"

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "Rules"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                    ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF03EB); label: "Edit config"; onClicked: root.inTerminal("sudoedit /etc/ai-firewall/config.toml") }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "Nothing gets in unless a port is open below; everything you start yourself can always go out. Changes to the config apply within 3 seconds."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }

                                RuleCard {
                                    pal: root.pal
                                    title: "Network profile"
                                    value: root.st ? (root.st.profile || "default") + ((root.st.profiles || []).length > 0 ? "   (profiles: " + root.st.profiles.join(", ") + ")" : "   (no profiles set up)") : "–"
                                    note: "A profile can open different ports per network (home wifi vs public), picked by the connection's name."
                                }
                                RuleCard {
                                    pal: root.pal
                                    title: "Open to everyone · TCP"
                                    value: root.st && root.st.allow_tcp.length ? root.st.allow_tcp.join("  ") : "none"
                                    mono: true
                                }
                                RuleCard {
                                    pal: root.pal
                                    title: "Open to everyone · UDP"
                                    value: root.st && root.st.allow_udp.length ? root.st.allow_udp.join("  ") : "none"
                                    note: root.st && root.st.udp_strict ? "Other UDP only gets in as a reply to something this machine sent." : "UDP to high ports is let in as replies (udp_strict is off)."
                                    mono: true
                                }
                                RuleCard {
                                    pal: root.pal
                                    title: "Narrower rules"
                                    value: root.st && (root.st.rules || []).length ? root.st.rules.join("\n") : "none (e.g. ssh only from your LAN, or a limit against password guessing)"
                                    mono: root.st !== null && (root.st.rules || []).length > 0
                                }
                                RuleCard {
                                    pal: root.pal
                                    title: "Ping"
                                    value: root.st && root.st.ping === false ? "ignored" : "answered"
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    InputPill {
                                        id: portIn
                                        pal: root.pal
                                        hint: "tcp 22  or  udp 51820  or  tcp 1714-1764"
                                        Layout.fillWidth: true
                                        onSubmitted: v => {
                                            const m = v.trim().match(/^(tcp|udp)\s+(\d{1,5}(-\d{1,5})?)$/i)
                                            if (m) { root.sudoThen("open " + m[1].toLowerCase() + " " + m[2]); portIn.clear() }
                                        }
                                    }
                                    ActionChip { pal: root.pal; label: "Open port"; onClicked: portIn.submit() }
                                }
                                Item { Layout.fillHeight: true }
                            }

                            // ---------------- Feeds
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14
                                visible: root.tab === "feeds"

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "Feeds"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                    ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0450); label: "Refresh now"; onClicked: root.sudoThen("feeds --refresh") }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "Public lists of networks known for attacks, spam and hijacking. Everything from them is dropped before it reaches anything else. Private and LAN ranges are always taken out of the lists. Pick lists in the config ([feeds])."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                                Repeater {
                                    model: root.st ? (root.st.feeds || []) : []
                                    delegate: Rectangle {
                                        id: feedRow
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: 60
                                        radius: root.pal.rMd
                                        color: root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.surface, 0.8)
                                        RowLayout {
                                            anchors { fill: parent; leftMargin: 18; rightMargin: 18 }
                                            spacing: 14
                                            Column {
                                                Layout.fillWidth: true
                                                spacing: 2
                                                Text { text: feedRow.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                                Text {
                                                    text: feedRow.modelData.updated_unix ? "updated " + root.ago(feedRow.modelData.updated_unix) : "not downloaded yet"
                                                    color: feedRow.modelData.error ? root.pal.warn : root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                            }
                                            Text { text: root.count(feedRow.modelData.entries) + " networks"; color: root.pal.accent2; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        }
                                    }
                                }
                                Text {
                                    visible: !root.st || (root.st.feeds || []).length === 0
                                    text: "No lists turned on."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                }
                                Item { Layout.fillHeight: true }
                            }

                            // ---------------- History
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14
                                visible: root.tab === "history"

                                Text { text: "History"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.DemiBold }
                                ListView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 4
                                    model: root.hist
                                    delegate: RowLayout {
                                        id: histRow
                                        required property var modelData
                                        width: ListView.view.width
                                        spacing: 12
                                        Text { text: root.ago(histRow.modelData.at_unix); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 80 }
                                        Rectangle {
                                            implicitWidth: kindTxt.implicitWidth + 16; implicitHeight: 20; radius: 10
                                            readonly property color kc: histRow.modelData.kind === "ban" ? root.pal.bad : histRow.modelData.kind === "profile" ? root.pal.accent : histRow.modelData.kind === "feeds" ? root.pal.accent2 : root.pal.good
                                            color: Qt.alpha(kc, 0.15)
                                            Text { id: kindTxt; anchors.centerIn: parent; text: histRow.modelData.kind; color: parent.kc; font.family: root.pal.uiFont; font.pixelSize: 10 }
                                        }
                                        Text { text: histRow.modelData.ip || ""; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 200; elide: Text.ElideRight }
                                        Text { text: histRow.modelData.detail || ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.fillWidth: true; elide: Text.ElideRight }
                                    }
                                    Text { visible: root.hist.length === 0; text: "Nothing yet."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                }
                            }

                            // ---------------- Ask & doctor
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 12
                                visible: root.tab === "ask"

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "Ask & doctor"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tDisplay; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                    ActionChip { pal: root.pal; label: doctorProc.running ? "Checking…" : "Check again"; onClicked: if (!doctorProc.running) doctorProc.running = true }
                                    ActionChip { pal: root.pal; label: "Full check (admin)"; onClicked: root.sudoThen("doctor --fix") }
                                }

                                // doctor findings that need attention
                                Repeater {
                                    model: root.findings.filter(f => f.severity === "warn" || f.severity === "fail")
                                    delegate: Rectangle {
                                        id: fRow
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: fCol.implicitHeight + 20
                                        radius: root.pal.rMd
                                        color: Qt.alpha(fRow.modelData.severity === "fail" ? root.pal.bad : root.pal.warn, 0.10)
                                        RowLayout {
                                            anchors { fill: parent; leftMargin: 16; rightMargin: 10 }
                                            spacing: 12
                                            Column {
                                                id: fCol
                                                Layout.fillWidth: true
                                                spacing: 2
                                                Text { text: fRow.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold; width: parent.width; elide: Text.ElideRight }
                                                Text { text: fRow.modelData.detail; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; width: parent.width; wrapMode: Text.WordWrap }
                                            }
                                            ActionChip { visible: !!fRow.modelData.fix; pal: root.pal; label: "Fix"; implicitHeight: 32; onClicked: root.sudoThen("fix " + fRow.modelData.fix) }
                                        }
                                    }
                                }
                                Text {
                                    visible: root.doctorRan && root.findings.filter(f => f.severity === "warn" || f.severity === "fail").length === 0
                                    text: "✓  The doctor found nothing wrong" + (root.findings.some(f => f.title === "Partial check") ? " (the admin check also looks at firewall rules and bans)." : ".")
                                    color: root.pal.good
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                }

                                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.pal.lineSoft }

                                ListView {
                                    id: chat
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 12
                                    model: root.msgs.concat(root.asking ? [{ role: "fw", text: root.answer === "" ? "thinking…" : root.answer, cmds: [], live: true }] : [])
                                    onCountChanged: Qt.callLater(() => chat.positionViewAtEnd())
                                    delegate: Column {
                                        id: msg
                                        required property var modelData
                                        width: ListView.view.width
                                        spacing: 6
                                        Text {
                                            text: msg.modelData.role === "you" ? "you" : "firewall" + (root.askModel !== "" ? " · " + root.askModel : "")
                                            color: msg.modelData.role === "you" ? root.pal.accent2 : root.pal.accent
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                            font.weight: Font.DemiBold
                                        }
                                        Text {
                                            width: parent.width
                                            text: msg.modelData.text
                                            wrapMode: Text.WordWrap
                                            color: msg.modelData.live ? root.pal.muted : root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                            lineHeight: 1.25
                                        }
                                        Flow {
                                            width: parent.width
                                            spacing: 8
                                            visible: (msg.modelData.cmds || []).length > 0
                                            Repeater {
                                                model: msg.modelData.cmds || []
                                                delegate: ActionChip {
                                                    id: cmdChip
                                                    required property var modelData
                                                    pal: root.pal
                                                    glyph: String.fromCodePoint(0xF040A)
                                                    label: cmdChip.modelData.what || cmdChip.modelData.cmd
                                                    onClicked: root.sudoThen(cmdChip.modelData.cmd)
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        visible: root.msgs.length === 0 && !root.asking
                                        width: chat.width
                                        wrapMode: Text.WordWrap
                                        text: "Ask about your network or this firewall: why can't my VM reach the internet? · I want to ssh in from my phone · why was this address banned?\nIt answers from what the doctor and the firewall see right now, using your local model. A suggested fix is a button; nothing changes until you press it."
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                        lineHeight: 1.3
                                    }
                                }
                                InputPill {
                                    id: askIn
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    hint: root.asking ? "answering…" : "ask the firewall"
                                    onSubmitted: v => { root.ask(v); askIn.clear() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- small parts
    component DetRow: RowLayout {
        id: det
        required property var modelData
        property var pal
        property var c
        width: ListView.view ? ListView.view.width : 0
        spacing: 12
        Text { text: det.c.ago(det.modelData.at_unix); color: det.pal.muted; font.family: det.pal.uiFont; font.pixelSize: det.pal.tCap; Layout.preferredWidth: 80 }
        Text { text: det.modelData.ip; color: det.pal.text; font.family: det.pal.mono; font.pixelSize: det.pal.tCap; Layout.preferredWidth: 200; elide: Text.ElideRight }
        Text {
            text: det.modelData.reason + (det.modelData.ports ? " · " + det.modelData.ports : "") + (det.modelData.enforced ? "" : " (monitor)")
            color: det.modelData.enforced ? det.pal.bad : det.pal.warn
            font.family: det.pal.uiFont
            font.pixelSize: det.pal.tCap
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
        Text { text: "strike " + det.modelData.strikes; color: det.pal.muted; font.family: det.pal.uiFont; font.pixelSize: det.pal.tCap }
    }

    component RuleCard: Rectangle {
        id: card
        property var pal
        property string title: ""
        property string value: ""
        property string note: ""
        property bool mono: false
        Layout.fillWidth: true
        implicitHeight: cardCol.implicitHeight + 22
        radius: pal.rMd
        color: pal.calm ? pal.fill : Qt.alpha(pal.surface, 0.8)
        Column {
            id: cardCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 18 }
            spacing: 3
            Text { text: card.title; color: card.pal.muted; font.family: card.pal.uiFont; font.pixelSize: card.pal.tCap }
            Text { width: parent.width; text: card.value; wrapMode: Text.WordWrap; color: card.pal.text; font.family: card.mono ? card.pal.mono : card.pal.uiFont; font.pixelSize: card.pal.tBody }
            Text { visible: card.note !== ""; width: parent.width; text: card.note; wrapMode: Text.WordWrap; color: card.pal.muted; font.family: card.pal.uiFont; font.pixelSize: card.pal.tCap }
        }
    }

    component InputPill: Rectangle {
        id: pill
        property var pal
        property string hint: ""
        signal submitted(string v)
        function clear() { field.text = "" }
        function submit() { if (field.text.trim() !== "") pill.submitted(field.text.trim()) }
        implicitWidth: 300
        implicitHeight: 40
        radius: 20
        color: pal.calm ? pal.fill : Qt.alpha(pal.surface, 0.8)
        border.width: field.activeFocus ? 1 : 0
        border.color: pal.lineFocus
        TextInput {
            id: field
            anchors { fill: parent; leftMargin: 18; rightMargin: 18 }
            verticalAlignment: TextInput.AlignVCenter
            color: pill.pal.text
            font.family: pill.pal.uiFont
            font.pixelSize: pill.pal.tBody
            selectByMouse: true
            clip: true
            onAccepted: pill.submit()
            Text { anchors.verticalCenter: parent.verticalCenter; visible: field.text === ""; text: pill.hint; color: pill.pal.muted; font: field.font }
        }
    }
}
