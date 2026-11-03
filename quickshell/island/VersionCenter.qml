import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Version Center.   >versions in the launcher (also >update, the IPC call `versions`, Settings > System > Version Center).
// One card per component: Halcyon, LUNA, ai-antivirus, ai-firewall. Each shows what is installed and what is newest on GitHub, a commit
// list loaded on demand (30 at a time), and Update / Install this version / Roll back / Pin. A component you did not choose at install is
// greyed with an Install button and is never updated behind your back.
// Everything goes through scripts/halcyon-versions.py (JSON on stdout), which runs update.sh / scripts/update-extras.sh / install.sh, so this
// window and the command line do the same thing. Admin passwords go to the helper on stdin once and are never stored. One operation at a
// time. Nothing runs while the window is closed; the commit lists are read only when a card is opened.
Scope {
    id: root
    property var pal
    property bool open: false
    readonly property bool asWindow: open && pal.deskWin
    signal focusRequested(string what)

    readonly property string helper: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-versions.py"

    // ---------------------------------------------------------------- state
    property var comps: []                  // from `status`
    property real checked: 0                // unix time of the last look at GitHub
    property bool offline: false
    property bool autoOn: false             // the daily background check (a systemd user timer)
    property bool loaded: false
    property string note: ""
    property bool noteBad: false
    property var lists: ({})                // id -> { open, commits, more, loading, offline, tags }
    property var dlg: null                  // the confirm dialog: { kind, id, ref, plan, targets, label }
    property var dlgReq: null
    property string dlgPw: ""               // typed in the dialog; handed to the helper's stdin once, then cleared
    property var extBusy: null              // another operation (the command line, another window) holds the lock
    property bool firstCheck: false
    property string opFor: ""               // the card the log pane belongs to ("all" = Update all)
    property var opLines: []
    property string opStep: ""
    property var opResult: null
    property string opPw: ""
    readonly property bool busy: opProc.running
    readonly property bool locked: opProc.running || extBusy !== null
    readonly property bool working: busy || statusProc.running || planProc.running

    function parse(t) { try { return JSON.parse(t) } catch (e) { return null } }
    function flash(m, bad) { note = m; noteBad = !!bad; noteT.restart() }
    function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1) }
    function fmtDate(iso) {
        if (!iso) return ""
        var d = new Date(iso)
        return isNaN(d.getTime()) ? "" : Qt.formatDate(d, "d MMM yyyy")
    }
    function ago(ts) {
        if (!ts) return "never"
        var s = Math.max(0, Math.round(Date.now() / 1000 - ts))
        if (s < 90) return "just now"
        if (s < 5400) return Math.round(s / 60) + " min ago"
        if (s < 129600) return Math.round(s / 3600) + " h ago"
        return Math.round(s / 86400) + " days ago"
    }
    function byId(id) { for (var i = 0; i < comps.length; i++) if (comps[i].id === id) return comps[i]; return null }
    function verText(v) {
        if (!v) return "unknown"
        var t = v.short || ""
        var d = fmtDate(v.date)
        if (d !== "") t += "  ·  " + d
        if (v.tags && v.tags.length > 0) t += "  ·  " + v.tags[0]
        return t
    }
    function stateText(c) {
        if (c.state === "not-chosen") return "not installed"
        if (c.state === "missing") return "not found on this machine"
        if (c.state === "pacman") return "managed by pacman"
        if (c.state === "local") return "built from a local folder"
        if (c.state === "behind") return c.behind + (c.behind === 1 ? " commit behind" : " commits behind")
        if (c.state === "ahead") return "ahead of main"
        if (c.state === "up-to-date") return "up to date"
        return "not checked yet"
    }
    function stateColor(c) {
        if (c.state === "up-to-date") return pal.good
        if (c.state === "behind") return pal.accent
        return pal.muted
    }
    function isBusyFor(id) { return busy && (opFor === id || opFor === "all") }
    function resFor(id) {
        if (!opResult) return null
        if (opResult.results) { for (var i = 0; i < opResult.results.length; i++) if (opResult.results[i].component === id) return opResult.results[i]; return null }
        return (opResult.component === id || (!opResult.component && opFor === id)) ? opResult : null
    }
    function lastLines(n) { return opLines.slice(Math.max(0, opLines.length - n)).join("\n") }

    // ---------------------------------------------------------------- status
    function refresh(net) {
        if (statusProc.running || busy) return
        statusProc.command = ["python3", helper, "status"].concat(net ? ["--refresh"] : [])
        statusProc.running = true
    }
    function gotStatus(text) {
        var o = parse(text)
        if (!o || !o.components) { flash("The version helper did not answer. Is " + helper + " there?", true); return }
        comps = o.components
        checked = o.checked || 0
        offline = !!o.offline
        autoOn = !!o.autocheck
        extBusy = (o.busy && !opProc.running) ? o.busy : null
        loaded = true
        if (open && checked === 0 && !firstCheck) { firstCheck = true; firstT.restart() }      // the very first time: look at GitHub once
    }
    Timer { id: firstT; interval: 400; onTriggered: { root.flash("Looking at GitHub…", false); root.refresh(true) } }
    function checkNow() { if (!working) { flash("Looking at GitHub…", false); refresh(true) } }

    // ---------------------------------------------------------------- the commit list of one card (read only when it is opened)
    property string logFor: ""
    function setList(id, patch) {
        var m = Object.assign({}, lists)
        m[id] = Object.assign({ open: false, commits: [], more: false, loading: false, offline: false, tags: [] }, m[id] || {}, patch)
        lists = m
    }
    function toggleList(id) {
        var cur = lists[id]
        var op = !(cur && cur.open)
        setList(id, { open: op })
        if (op && (!cur || cur.commits.length === 0)) { loadLog(id, 0); loadTags(id) }
    }
    function loadLog(id, from) {
        if (logProc.running) return
        logFor = id
        setList(id, { loading: true })
        logProc.command = ["python3", helper, "log", id, "--from", String(from)]
        logProc.running = true
    }
    function gotLog(text) {
        var o = parse(text), id = logFor
        if (!o) { setList(id, { loading: false }); return }
        var cur = lists[id] || { commits: [] }
        var all = cur.commits.concat(o.commits)
        setList(id, { commits: all, more: !!o.more, loading: false, offline: !!o.offline })
    }
    property string tagsFor: ""
    function loadTags(id) {
        if (tagsProc.running) return
        tagsFor = id
        tagsProc.command = ["python3", helper, "tags", id]
        tagsProc.running = true
    }
    function gotTags(text) {
        var o = parse(text)
        if (o && o.tags) setList(tagsFor, { tags: o.tags.slice(0, 12) })
    }

    // ---------------------------------------------------------------- the confirm dialog (shown BEFORE anything runs)
    function ask(kind, id, ref, label) {
        if (locked || planProc.running) return
        dlgReq = { kind: kind, id: id, ref: ref, label: label || ref }
        planProc.command = ["python3", helper, "plan", id, ref]
        planProc.running = true
    }
    function gotPlan(text) {
        var p = parse(text), r = dlgReq
        if (!p || p.ok === false || !r) { flash(p && p.error ? p.error : "Could not prepare that.", true); return }
        dlg = { kind: r.kind, id: r.id, ref: r.ref, label: r.label, plan: p, targets: null, err: "" }
        Qt.callLater(function () { root.focusRequested("pw") })
    }
    function askUpdate(id) {
        var c = byId(id)
        if (!c || !c.latest) { flash("Press Check now first, so it is known what is newest.", true); return }
        ask("update", id, c.latest.sha, c.latest.short)
    }
    function askInstallNew(id) {
        var c = byId(id)
        dlg = { kind: "install-new", id: id, label: c.name, plan: { needs_root: c.needs_root, warnings: [], backups: [], diffstat: "" }, targets: null, err: "" }
        Qt.callLater(function () { root.focusRequested("pw") })
    }
    function askRollback(id) {
        var c = byId(id)
        if (!c || !c.previous) return
        ask("rollback", id, c.previous.sha, c.previous.short)
    }
    function askUnpin(id) {
        var c = byId(id)
        if (!c || !c.latest) { flash("Press Check now first.", true); return }
        ask("unpin", id, c.latest.sha, c.latest.short)
    }
    function askRestore(id) {
        dlg = { kind: "restore", id: id, label: id, plan: { needs_root: true, warnings: ["Puts back the copy of /var/lib/ai-antivirus made before the change. Whatever the antivirus recorded since then is replaced by it."], backups: [], diffstat: "" }, targets: null, err: "" }
        Qt.callLater(function () { root.focusRequested("pw") })
    }
    // anything Update all would act on: it is the window's main action only then (otherwise a quiet button)
    readonly property bool anyBehind: {
        var order = ["halcyon", "luna", "ai-firewall", "ai-antivirus"]
        for (var i = 0; i < order.length; i++) {
            var c = byId(order[i])
            if (c && c.chosen && c.present && !c.pinned && c.state === "behind") return true
        }
        return false
    }
    function askAll() {
        var t = []
        var order = ["halcyon", "luna", "ai-firewall", "ai-antivirus"]
        for (var i = 0; i < order.length; i++) {
            var c = byId(order[i])
            if (c && c.chosen && c.present && !c.pinned && c.state === "behind") t.push(c)
        }
        var root_ = false
        for (var j = 0; j < t.length; j++) if (t[j].needs_root) root_ = true
        dlg = { kind: "updateall", id: "all", label: "everything", plan: { needs_root: root_, warnings: [], backups: [], diffstat: "" }, targets: t, err: "" }
        Qt.callLater(function () { root.focusRequested("pw") })
    }
    function closeDialog() { dlg = null; dlgPw = "" }
    function confirmDialog() {
        var d = dlg
        if (!d || locked) return
        if (d.kind === "updateall" && d.targets.length === 0) { closeDialog(); return }
        var args = []
        if (d.kind === "install") args = ["install-version", d.id, d.ref]
        else if (d.kind === "update") args = ["update", d.id]
        else if (d.kind === "install-new") args = ["update", d.id]
        else if (d.kind === "rollback") args = ["rollback", d.id]
        else if (d.kind === "unpin") args = ["unpin", d.id]
        else if (d.kind === "updateall") args = ["update", "all"]
        else if (d.kind === "restore") args = ["restore-backup", d.id]
        var needsRoot = !!(d.plan && d.plan.needs_root)
        if (needsRoot) {
            if (dlgPw === "") { dlg = Object.assign({}, d, { err: "Type your admin password first." }); return }
            args.push("--password-stdin")
        }
        var pw = needsRoot ? dlgPw : ""
        dlgPw = ""
        dlg = null
        startOp(d.id, args, pw)
    }
    function startOp(id, args, pw) {
        opFor = id
        opLines = []
        opStep = ""
        opResult = null
        opPw = pw
        opProc.command = ["python3", helper].concat(args)
        opProc.running = true
    }
    function opLine(line) {
        if (line.indexOf("##step ") === 0) { opStep = line.substring(7); return }
        if (line.indexOf("##result ") === 0) { opResult = parse(line.substring(9)); return }
        var l = opLines.length >= 300 ? opLines.slice(100) : opLines.slice()
        l.push(line)
        opLines = l
    }
    function opDone(code) {
        if (!opResult) opResult = { ok: false, error: code === 143 ? "Cancelled." : "The helper stopped with exit code " + code + ". The full log is in ~/.local/state/halcyon/versions.log." }
        var ids = []
        // the commit lists show the new installed / newer / older marks
        for (var k in lists) if (lists[k].open) ids.push(k)
        var m = Object.assign({}, lists)
        for (var i = 0; i < ids.length; i++) m[ids[i]] = Object.assign({}, m[ids[i]], { commits: [], more: false })
        lists = m
        statusProc.command = ["python3", helper, "status"]
        statusProc.running = true
        for (var j = 0; j < ids.length; j++) { loadLogLater = ids[j] }
        reloadT.restart()
    }
    property string loadLogLater: ""
    Timer { id: reloadT; interval: 600; onTriggered: { if (root.loadLogLater !== "" && root.open) { root.loadLog(root.loadLogLater, 0); root.loadLogLater = "" } } }
    function pinToggle(id) {
        var c = byId(id)
        if (!c || locked) return
        if (c.pinned) askUnpin(id)
        else startOp(id, ["pin", id], "")
    }

    // ---------------------------------------------------------------- the daily check (off by default)
    function setAuto(on) {
        if (autoProc.running) return
        autoProc.command = ["python3", helper, "autocheck", on ? "on" : "off"]
        autoProc.running = true
    }

    function show() { open = true; refresh(false); Qt.callLater(function () { root.focusRequested("panel") }) }
    function hide() { open = false; dlg = null; dlgPw = "" }
    function toggle() { if (open) hide(); else show() }
    property bool linger: false
    onOpenChanged: {
        if (!open) { linger = true; lingerT.restart() }
        else if (loaded && checked === 0) checkNow()
    }
    Timer {
        id: lingerT
        interval: (root.pal ? root.pal.dMed : 300) + 80
        onTriggered: {                              // closed for good: let go of the lists
            root.linger = false
            if (root.open) return
            root.lists = ({}); root.dlg = null; root.note = ""
            if (!root.busy) { root.opLines = []; root.opResult = null }
            gc()
        }
    }
    Timer { id: noteT; interval: 6000; onTriggered: root.note = "" }

    // ---------------------------------------------------------------- processes
    Process {
        id: statusProc
        stdout: StdioCollector { onStreamFinished: root.gotStatus(text) }
        onExited: { if (root.note === "Looking at GitHub…") root.flash(root.offline ? "GitHub could not be reached: showing what was saved." : "Checked.", root.offline) }
    }
    Process {
        id: logProc
        stdout: StdioCollector { onStreamFinished: root.gotLog(text) }
    }
    Process {
        id: tagsProc
        stdout: StdioCollector { onStreamFinished: root.gotTags(text) }
    }
    Process {
        id: planProc
        stdout: StdioCollector { onStreamFinished: root.gotPlan(text) }
    }
    Process {
        id: autoProc
        stdout: StdioCollector { onStreamFinished: { var o = root.parse(text); if (o && o.ok) root.autoOn = !!o.enabled; else root.flash((o && o.error) || "The timer could not be changed.", true) } }
    }
    Process {
        id: opProc
        stdinEnabled: true
        stdout: SplitParser { onRead: line => root.opLine(line) }
        onRunningChanged: { if (running && root.opPw !== "") { write(root.opPw + "\n"); root.opPw = "" } }
        onExited: code => root.opDone(code)
    }

    // ---------------------------------------------------------------- pieces
    component Label: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
        font.weight: Font.Medium
    }
    component Small: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap + 1
        elide: Text.ElideRight
    }
    component Mono: Text {
        color: root.pal.text
        font.family: root.pal.mono
        font.pixelSize: root.pal.tCap + 1
    }
    component Btn: Rectangle {
        id: b
        property string label: ""
        property bool primary: false
        property bool disabled: false
        signal clicked()
        implicitWidth: bTxt.implicitWidth + 26
        implicitHeight: 32
        radius: 10
        opacity: disabled ? 0.4 : 1
        color: primary ? (bMa.containsMouse && !disabled ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent)
                       : (bMa.containsMouse && !disabled ? root.pal.fillHover : root.pal.fill)
        scale: bMa.pressed && !disabled ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Text {
            id: bTxt
            anchors.centerIn: parent
            text: b.label
            color: b.primary ? root.pal.bg : root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody - 1
            font.weight: b.primary ? Font.Medium : Font.Medium
        }
        MouseArea { id: bMa; anchors.fill: parent; hoverEnabled: true; cursorShape: b.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!b.disabled) b.clicked() }
    }
    component Tag: Rectangle {
        property string label: ""
        property color tone: root.pal.muted
        implicitWidth: tagTxt.implicitWidth + 16
        implicitHeight: 20
        radius: 10
        color: Qt.alpha(tone, 0.16)
        Text { id: tagTxt; anchors.centerIn: parent; text: parent.label; color: parent.tone; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
    }

    // one card
    component Card: Rectangle {
        id: card
        required property var comp
        readonly property bool greyed: comp.state === "not-chosen" || comp.state === "missing"
        readonly property bool pacman: comp.state === "pacman"
        readonly property var lst: root.lists[comp.id] || null
        readonly property var res: root.resFor(comp.id)
        readonly property bool mine: root.isBusyFor(comp.id)
        width: ListView.view ? ListView.view.width : 600
        height: col.implicitHeight + 28
        radius: root.pal.rLg
        color: root.pal.fill
        border.width: 1
        border.color: mine ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
        // unslop: a component that is not installed reads quieter by its name only; its Install button stays fully legible
        Behavior on height { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        Behavior on border.color { ColorAnimation { duration: root.pal.dMed } }
        clip: true

        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: card.comp.name; color: card.greyed ? root.pal.muted : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.Medium }
                Tag { label: root.stateText(card.comp); tone: root.stateColor(card.comp) }
                Tag { visible: !!card.comp.pinned; label: "pinned " + (card.comp.pinned ? card.comp.pinned.short : ""); tone: root.pal.warn }
                Tag { visible: card.comp.dirty; label: "local changes"; tone: root.pal.muted }
                Tag { visible: card.comp.offline && !card.greyed; label: "offline"; tone: root.pal.muted }
                Item { Layout.fillWidth: true }
                Btn {
                    visible: card.greyed
                    label: "Install"
                    primary: false     // unslop: one primary action per window (Update all); these are secondary
                    disabled: root.locked
                    onClicked: root.askInstallNew(card.comp.id)
                }
            }

            GridLayout {
                visible: !card.greyed
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 14
                rowSpacing: 4
                Label { text: "Installed" }
                Mono { Layout.fillWidth: true; text: root.verText(card.comp.installed); elide: Text.ElideRight }
                Label { text: "Latest on main" }
                Mono { Layout.fillWidth: true; text: card.comp.latest ? root.verText(card.comp.latest) : "not checked yet (Check now)"; elide: Text.ElideRight; color: card.comp.latest ? root.pal.text : root.pal.muted }
                Label { visible: card.comp.installed && card.comp.installed.subject !== "" }
                Small { visible: card.comp.installed && card.comp.installed.subject !== ""; Layout.fillWidth: true; text: card.comp.installed ? card.comp.installed.subject : "" }
            }
            Small {
                visible: card.pacman
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
                text: "This one came from a pacman package, so pacman keeps it up to date. Nothing here changes it."
            }

            Flow {
                visible: !card.greyed && !card.pacman
                Layout.fillWidth: true
                spacing: 8
                Btn {
                    label: card.comp.pinned && card.comp.state === "behind" ? "Update to main" : "Update"
                    primary: card.comp.state === "behind"
                    disabled: root.locked || planProc.running || !(card.comp.state === "behind")
                    onClicked: root.askUpdate(card.comp.id)
                }
                Btn {
                    label: "Roll back"
                    disabled: root.locked || planProc.running || !card.comp.previous
                    onClicked: root.askRollback(card.comp.id)
                }
                Btn {
                    label: card.comp.pinned ? "Unpin" : "Pin"
                    disabled: root.locked || planProc.running || (!card.comp.pinned && !(card.comp.installed && card.comp.installed.sha))
                    onClicked: root.pinToggle(card.comp.id)
                }
                Btn {
                    label: (card.lst && card.lst.open) ? "Hide commits" : "Commits"
                    onClicked: root.toggleList(card.comp.id)
                }
            }

            // the log pane: the last lines of what is running, then the result and the health check
            Rectangle {
                visible: card.mine || card.res !== null
                Layout.fillWidth: true
                implicitHeight: logCol.implicitHeight + 20
                radius: root.pal.rSm
                color: Qt.alpha(root.pal.bg, 0.45)
                border.width: 1
                border.color: root.pal.lineSoft
                ColumnLayout {
                    id: logCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                    spacing: 6
                    RowLayout {
                        visible: card.mine
                        Layout.fillWidth: true
                        Text { text: root.opStep !== "" ? root.opStep : "Working…"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                        Btn { label: "Cancel"; onClicked: opProc.running = false }
                    }
                    Text {
                        visible: card.mine && root.opLines.length > 0
                        Layout.fillWidth: true
                        text: root.lastLines(7)
                        color: root.pal.muted
                        font.family: root.pal.mono
                        font.pixelSize: root.pal.tCap
                        elide: Text.ElideRight
                        maximumLineCount: 7
                        wrapMode: Text.NoWrap
                    }
                    Text {
                        visible: !card.mine && card.res !== null
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: card.res ? (card.res.skipped ? (root.cap(card.res.skipped) + ": skipped") : (card.res.ok ? (card.res.changed ? "Done: now at " + String(card.res.to || "").substring(0, 7) + (card.res.older ? " (an older version)" : "") : "Nothing to change.") : (card.res.error || "It did not work."))) : ""
                        color: card.res && card.res.ok ? root.pal.good : root.pal.bad
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody - 1
                    }
                    Text {
                        visible: !card.mine && card.res !== null && !!card.res.restored
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: "The version you had before is back."
                        color: root.pal.warn
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody - 1
                    }
                    Flow {
                        visible: !card.mine && card.res !== null && !!card.res.health
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: card.res && card.res.health ? card.res.health.checks : []
                            delegate: Tag {
                                required property var modelData
                                label: (modelData.ok ? "ok  " : "failed  ") + modelData.name + ": " + modelData.detail
                                tone: modelData.ok ? root.pal.good : root.pal.bad
                            }
                        }
                    }
                    Btn {
                        visible: !card.mine && card.res !== null && !!card.res.backup && card.comp.id === "ai-antivirus"
                        label: "Restore the database copy"
                        disabled: root.locked
                        onClicked: root.askRestore("ai-antivirus")
                    }
                }
            }

            // the commit list
            ColumnLayout {
                visible: !!(card.lst && card.lst.open)
                Layout.fillWidth: true
                spacing: 4
                Flow {
                    visible: !!(card.lst && card.lst.tags.length > 0)
                    Layout.fillWidth: true
                    spacing: 6
                    Label { text: "Tags"; height: 24; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: card.lst ? card.lst.tags : []
                        delegate: Rectangle {
                            required property var modelData
                            implicitWidth: tgTxt.implicitWidth + 18
                            implicitHeight: 24
                            radius: 12
                            color: tgMa.containsMouse ? root.pal.fillHover : root.pal.fill
                            Text { id: tgTxt; anchors.centerIn: parent; text: modelData.tag; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap }
                            MouseArea { id: tgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !root.locked; onClicked: root.ask("install", card.comp.id, modelData.tag, modelData.tag) }
                        }
                    }
                }
                Small { visible: !!(card.lst && card.lst.offline); text: "offline: this is the list that was saved" }
                Repeater {
                    model: card.lst ? card.lst.commits : []
                    delegate: Rectangle {
                        id: cr
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 34
                        radius: root.pal.rSm
                        color: crMa.containsMouse ? root.pal.fillHover : (modelData.rel === "installed" ? Qt.alpha(root.pal.accent, 0.12) : "transparent")
                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        MouseArea { id: crMa; anchors.fill: parent; hoverEnabled: true }
                        RowLayout {
                            anchors { fill: parent; leftMargin: 10; rightMargin: 8 }
                            spacing: 10
                            Mono { text: cr.modelData.short; color: root.pal.accent; Layout.preferredWidth: 64 }
                            Text {
                                Layout.fillWidth: true
                                text: cr.modelData.subject
                                color: root.pal.text
                                elide: Text.ElideRight
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody - 1
                            }
                            Tag { visible: cr.modelData.tags.length > 0; label: cr.modelData.tags.length > 0 ? cr.modelData.tags[0] : ""; tone: root.pal.accent2 }
                            Tag { visible: cr.modelData.rel === "installed"; label: "installed"; tone: root.pal.good }
                            Small { text: root.fmtDate(cr.modelData.date); Layout.preferredWidth: 84; horizontalAlignment: Text.AlignRight }
                            Small { text: cr.modelData.author; Layout.preferredWidth: 90 }
                            Btn {
                                visible: cr.modelData.rel !== "installed"
                                label: "Install"
                                implicitHeight: 26
                                disabled: root.locked || planProc.running
                                onClicked: root.ask("install", card.comp.id, cr.modelData.sha, cr.modelData.short)
                            }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !!(card.lst && (card.lst.more || card.lst.loading))
                    Btn { label: card.lst && card.lst.loading ? "Loading…" : "Load 30 more"; disabled: !!(card.lst && card.lst.loading); onClicked: root.loadLog(card.comp.id, card.lst.commits.length) }
                }
                Small { visible: !!(card.lst && !card.lst.loading && card.lst.commits.length === 0); text: "No history here yet. Press Check now." }
            }
        }
    }

    // ---------------------------------------------------------------- the window
    LazyLoader {
        active: root.open || root.linger
        Host {
            id: win
            desktop: root.pal.deskWin
            title: "Version Center"
            deskWidth: 980
            deskHeight: 720
            namespace: "island-versions"
            keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            onCloseRequested: root.hide()

            MouseArea { anchors.fill: parent; enabled: !win.desktop; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                focus: true
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { qp.forceActiveFocus() }) }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { if (root.dlg !== null) root.closeDialog(); else root.hide(); e.accepted = true }
                }
                Connections {
                    target: root
                    function onFocusRequested(what) { if (what === "pw" && root.dlg !== null && root.dlg.plan && root.dlg.plan.needs_root) pwIn.forceActiveFocus(); else qp.forceActiveFocus() }
                }

                Rectangle { visible: !win.desktop; anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * Math.max(0, Math.min(1, qp.reveal))) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: win.desktop ? qp.width : Math.min(980, qp.width - 80)
                    height: win.desktop ? qp.height : Math.min(720, qp.height - 80)
                    radius: win.desktop ? 0 : root.pal.rXl
                    opacityBody: 0.97
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                    anchors.centerIn: parent
                    opacity: win.desktop ? 1 : qp.reveal
                    scale: win.desktop ? 1 : 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 20
                        spacing: 14

                        // the top bar
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { text: String.fromCodePoint(0xF06B0); font.family: root.pal.font; font.pixelSize: 20; color: root.pal.accent }
                            ColumnLayout {
                                spacing: 1
                                Text { text: "Version Center"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 2; font.weight: Font.Medium }
                                Small {
                                    text: (root.extBusy ? "another operation is running (" + root.extBusy.component + ")  ·  " : "") + (root.offline ? "offline: showing what was saved  ·  " : "") + "last checked " + root.ago(root.checked)
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                visible: root.note !== ""
                                text: root.note
                                color: root.noteBad ? root.pal.bad : root.pal.good
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap + 1
                                elide: Text.ElideRight
                                Layout.maximumWidth: 280
                            }
                            Btn { label: root.autoOn ? "Daily check: on" : "Daily check: off"; onClicked: root.setAuto(!root.autoOn); disabled: root.locked }
                            Btn { label: statusProc.running ? "Checking…" : "Check now"; disabled: root.working || root.extBusy !== null; onClicked: root.checkNow() }
                            Btn { label: "Update all"; primary: root.anyBehind; disabled: root.working || root.extBusy !== null; onClicked: root.askAll() }
                            RoundBtn { pal: root.pal; size: 32; glyph: String.fromCodePoint(0xF0156); onClicked: root.hide() }   // the same close as the other centres
                        }
                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // an "Update all" run is summed up here
                        Text {
                            visible: !root.busy && root.opResult !== null && !!root.opResult.results
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: root.opResult && root.opResult.results ? (root.opResult.ok ? "Update all: finished." : "Update all: something did not work, see the cards below.") : ""
                            color: root.opResult && root.opResult.ok ? root.pal.good : root.pal.bad
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody - 1
                        }
                        Text {
                            visible: !root.busy && root.opResult !== null && root.opFor === "all" && !root.opResult.results && !!root.opResult.error
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: root.opResult && root.opResult.error ? root.opResult.error : ""
                            color: root.pal.bad
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody - 1
                        }
                        Rectangle {
                            visible: root.busy && root.opFor === "all"
                            Layout.fillWidth: true
                            implicitHeight: allCol.implicitHeight + 20
                            radius: root.pal.rSm
                            color: Qt.alpha(root.pal.bg, 0.45)
                            border.width: 1
                            border.color: root.pal.lineSoft
                            ColumnLayout {
                                id: allCol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                                spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: root.opStep !== "" ? root.opStep : "Working…"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                                    Btn { label: "Cancel"; onClicked: opProc.running = false }
                                }
                                Text { Layout.fillWidth: true; text: root.lastLines(7); color: root.pal.muted; font.family: root.pal.mono; font.pixelSize: root.pal.tCap; elide: Text.ElideRight; maximumLineCount: 7 }
                            }
                        }

                        // the cards, one column
                        ListView {
                            id: cardList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 12
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.loaded ? ["halcyon", "luna", "ai-antivirus", "ai-firewall"] : []
                            delegate: Card { required property var modelData; comp: root.byId(modelData) }
                            Text {
                                visible: !root.loaded
                                anchors.centerIn: parent
                                text: "Reading what is installed…"
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                            }
                        }
                    }

                    // the confirm dialog: nothing runs until this is accepted
                    Rectangle {
                        id: veil
                        anchors.fill: parent
                        radius: panel.radius
                        visible: opacity > 0.01
                        opacity: root.dlg !== null ? 1 : 0
                        color: Qt.alpha(root.pal.bg, 0.72)
                        Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                        MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                        Rectangle {
                            id: dbox
                            anchors.centerIn: parent
                            width: Math.min(620, parent.width - 60)
                            height: Math.min(parent.height - 60, dcol.implicitHeight + 40)
                            radius: root.pal.rLg
                            color: root.pal.surface
                            border.width: 1
                            border.color: root.pal.line
                            clip: true

                            ColumnLayout {
                                id: dcol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
                                spacing: 10
                                readonly property var d: root.dlg
                                readonly property var p: d ? d.plan : null

                                Text {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tTitle
                                    font.weight: Font.Medium
                                    text: !dcol.d ? "" : (dcol.d.kind === "updateall" ? "Update everything that is behind?"
                                        : dcol.d.kind === "restore" ? "Put the antivirus database copy back?"
                                        : dcol.d.kind === "install-new" ? "Install " + dcol.d.label + "?"
                                        : dcol.d.kind === "rollback" ? "Roll back " + (root.byId(dcol.d.id) ? root.byId(dcol.d.id).name : "") + " to " + dcol.d.label + "?"
                                        : dcol.d.kind === "unpin" ? "Unpin " + (root.byId(dcol.d.id) ? root.byId(dcol.d.id).name : "") + " and go back to main?"
                                        : dcol.d.kind === "update" ? "Update " + (root.byId(dcol.d.id) ? root.byId(dcol.d.id).name : "") + " to " + dcol.d.label + "?"
                                        : "Install " + dcol.d.label + " of " + (root.byId(dcol.d.id) ? root.byId(dcol.d.id).name : "") + "?")
                                }
                                // from -> to
                                Text {
                                    visible: !!(dcol.p && dcol.p.to)
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: root.pal.muted
                                    font.family: root.pal.mono
                                    font.pixelSize: root.pal.tCap + 1
                                    text: dcol.p && dcol.p.to ? ((dcol.p.from ? dcol.p.from.short : "?") + "  →  " + dcol.p.to.short + "   " + dcol.p.to.subject + (dcol.p.commits_between !== null && dcol.p.commits_between !== undefined ? "   (" + dcol.p.commits_between + " commits)" : "")) : ""
                                }
                                Text {
                                    visible: !!(dcol.p && dcol.p.diffstat)
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                    text: dcol.p ? "Changes: " + dcol.p.diffstat : ""
                                }
                                // what an Update all will touch
                                Repeater {
                                    model: dcol.d && dcol.d.targets ? dcol.d.targets : []
                                    delegate: Text {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        text: modelData.name + ":  " + (modelData.installed ? modelData.installed.short : "?") + "  →  " + (modelData.latest ? modelData.latest.short : "?")
                                        color: root.pal.text
                                        font.family: root.pal.mono
                                        font.pixelSize: root.pal.tCap + 1
                                    }
                                }
                                Text {
                                    visible: !!(dcol.d && dcol.d.kind === "updateall" && dcol.d.targets.length === 0)
                                    Layout.fillWidth: true
                                    text: "Everything that is not pinned is up to date."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody - 1
                                }
                                Text {
                                    visible: !!(dcol.d && dcol.d.kind === "updateall")
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "Halcyon goes first, then LUNA, ai-firewall and ai-antivirus (the order install.sh uses). Pinned components are skipped."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                Text {
                                    visible: !!(dcol.d && dcol.d.kind === "install-new")
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "This runs install.sh for that one component, the same as typing it in a terminal. It was not chosen at install, so nothing touches it until you do this."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                Text {
                                    visible: !!(dcol.d && dcol.d.kind === "unpin")
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "It follows the newest main again and is updated to it now."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                // warnings: an older version is said loudly, with what is done about it
                                Repeater {
                                    model: dcol.p ? dcol.p.warnings : []
                                    delegate: Text {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                        text: "!  " + modelData
                                        color: modelData.indexOf("OLDER") >= 0 || modelData.indexOf("schema") >= 0 ? root.pal.warn : root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap + 1
                                    }
                                }
                                Text {
                                    visible: !!(dcol.p && dcol.p.backups && dcol.p.backups.length > 0 && dcol.d.kind !== "unpin")
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: dcol.p && dcol.p.backups ? "Saved first:  " + dcol.p.backups.join("   ·   ") : ""
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                Text {
                                    visible: !!(dcol.d && dcol.d.kind !== "updateall" && dcol.d.kind !== "install-new" && dcol.d.kind !== "unpin" && dcol.d.kind !== "restore")
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: "If the new version fails its health check, the version you have now is put back automatically. Installing a version pins it: updates leave it alone until you unpin."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                // the admin password: once, to the helper's stdin, never stored
                                Rectangle {
                                    visible: !!(dcol.p && dcol.p.needs_root)
                                    Layout.fillWidth: true
                                    height: 36
                                    radius: 18
                                    color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.8))
                                    border.width: 1
                                    border.color: pwIn.activeFocus ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
                                    TextInput {
                                        id: pwIn
                                        anchors.fill: parent
                                        anchors.leftMargin: 16; anchors.rightMargin: 16
                                        verticalAlignment: TextInput.AlignVCenter
                                        echoMode: TextInput.Password
                                        passwordCharacter: "\u2022"
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        clip: true
                                        text: root.dlgPw
                                        onTextEdited: root.dlgPw = text
                                        onAccepted: root.confirmDialog()
                                        Text {
                                            visible: !parent.text && !parent.activeFocus
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "your admin password (asked once, never stored)"
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                        }
                                    }
                                }
                                Text {
                                    visible: !!(dcol.d && dcol.d.err !== "")
                                    text: dcol.d ? dcol.d.err : ""
                                    color: root.pal.bad
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 4
                                    spacing: 10
                                    Item { Layout.fillWidth: true }
                                    Btn { label: "Cancel"; onClicked: root.closeDialog() }
                                    Btn {
                                        primary: true
                                        label: !dcol.d ? "" : (dcol.d.kind === "updateall" ? "Update all" : dcol.d.kind === "rollback" ? "Roll back" : dcol.d.kind === "unpin" ? "Unpin and update" : dcol.d.kind === "install-new" ? "Install" : dcol.d.kind === "restore" ? "Restore" : dcol.d.kind === "update" ? "Update" : "Install this version")
                                        disabled: !!(dcol.d && dcol.d.kind === "updateall" && dcol.d.targets.length === 0)
                                        onClicked: root.confirmDialog()
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
