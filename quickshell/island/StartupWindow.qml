import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// The Startup & processes window (`>startup`, Settings > Startup & background > "Open startup & processes", IPC `startup`).
// A dimmed overlay with one card on it, the same way the wallpaper gallery and the bar builder are opened.
//
//   Startup items:  everything that starts with the desktop (Halcyon's own parts, your own hypr-user.lua lines, systemd user
//                   services, autostart .desktop files), with the processes it is running now: memory (PSS), CPU, count.
//                   The switch turns an item on / off for the next login (and starts / stops it at once where that is safe).
//   All processes:  every process of yours, biggest first (RAM or CPU), with the startup item it belongs to and an End button.
//
//   Health:         Halcyon as a whole (its own parts together) against the RAM and CPU limits from Settings > Performance & memory; when it is
//                   over, the likely causes and what to do about each one (buttons where one click is safe).
//   Every column title and caption has a small "?": hover it for what the word means (no explanation text at the bottom any more).
//
// The data comes from scripts/startup-view.py, polled every 5 s ONLY while the window is open; when it closes the numbers are
// dropped and the window is unloaded, so it costs nothing while you are not looking at it.
Item {
    id: root

    property var pal
    property bool open: false
    property bool movingStars: true      // the few stars flying over the card (Settings > Look > Moving stars), like the bar builder and the gallery
    property real limRam: 600            // Settings > Performance & memory > Halcyon RAM limit (MB, all Halcyon parts together)
    property real limCpu: 10             // ... CPU limit (% of the whole processor)
    property bool adaptive: false        // Settings > Performance & memory > Limits: Adaptive. The limits are then learned by startup-view.py (adapt-sample), see effRam / effCpu
    signal closed()
    signal presetPicked(string mode)     // the Health tab's "Switch to Low / Medium resource use" button (Settings applies it)

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/startup-view.py"
    readonly property var empty: ({ items: [], procs: [], suggest: [], ncpu: 1, n_procs: 0, session_mb: 0, startup_mb: 0, total_mb: 0, avail_mb: 0, health: ({ findings: [] }) })
    property var info: empty
    property bool loaded: false
    property string tab: "startup"            // startup | procs | health | tips
    property string filter: "all"             // startup tab: all | running | off
    property string sortBy: "mem"             // processes tab: mem | cpu
    property var busyIds: ({})
    property string note: ""
    property string query: ""
    property var cpuMemo: ({})                // smoothed CPU per item / process (see smoothCpu)
    property int cpuStreak: 0                 // readings in a row with Halcyon over its CPU limit: one reading is often just a burst
    property var tipItem: null                // the "?" that is hovered now (one shared bubble, see showTip)
    property string tipText: ""
    property real tipCx: 0
    property real tipTop: 0
    property real tipBottom: 0
    readonly property int ncpu: Math.max(1, info.ncpu || 1)
    readonly property var shownTips: info.suggest || []                 // the search box: filters whichever list is showing

    component Cap: Text { color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }
    component Q: HelpTip { id: q; pal: root.pal; onHoveredChanged: root.setTip(q, hovered) }
    // a column title with its "?" ; alignRight = the text sits at the right edge (number columns)
    component Head: Item {
        id: hd
        property string label: ""
        property string tip: ""
        property bool alignRight: true
        implicitHeight: 15
        Row {
            spacing: 5
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: hd.alignRight ? parent.right : undefined
            anchors.left: hd.alignRight ? undefined : parent.left
            Cap { anchors.verticalCenter: parent.verticalCenter; text: hd.label }
            Q { anchors.verticalCenter: parent.verticalCenter; tip: hd.tip }
        }
    }
    // a caption with its "?" (the memory bar)
    component Titled: Row {
        id: tt
        property string label: ""
        property string tip: ""
        spacing: 5
        Cap { anchors.verticalCenter: parent.verticalCenter; text: tt.label }
        Q { anchors.verticalCenter: parent.verticalCenter; tip: tt.tip }
    }

    // one usage bar with a tick where the limit is (the bar runs to 1.5 x the limit)
    component Meter: Item {
        id: mt
        property string label: ""
        property string valueText: ""
        property string limitText: ""
        property real value: 0
        property real limit: 1
        property color tone: root.pal.good
        implicitHeight: 38
        Cap { anchors.left: parent.left; anchors.top: parent.top; text: mt.label }
        Text {
            anchors.right: parent.right; anchors.top: parent.top
            text: mt.valueText + "   of limit " + mt.limitText
            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
        }
        Rectangle {
            id: track
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: 3
            height: 8; radius: 4
            color: Qt.alpha(root.pal.text, 0.08)
            Rectangle {
                height: parent.height; radius: 4
                width: parent.width * Math.max(0.01, Math.min(1, mt.value / (mt.limit * 1.5)))
                color: mt.tone
                Behavior on width { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: root.pal.dMed } }
            }
            Rectangle { x: parent.width / 1.5 - 1; y: -3; width: 2; height: parent.height + 6; radius: 1; color: root.pal.text; opacity: 0.65 }
        }
    }

    function setTip(item, on) {
        if (!on) { if (tipItem === item) tipItem = null; return }
        var a = card.mapFromItem(item, item.width / 2, 0), b = card.mapFromItem(item, 0, item.height)
        tipText = item.tip; tipCx = a.x; tipTop = a.y; tipBottom = b.y
        tipItem = item
    }
    onTabChanged: tipItem = null

    // ---------------------------------------------------------------- numbers
    function fmt(mb) {
        if (mb >= 1024) return (mb / 1024).toFixed(2) + " GB"
        return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + " MB"
    }
    function kindLabel(k) {
        return k === "halcyon" ? "Halcyon" : k === "service" ? "Service" : k === "autostart" ? "Autostart" : k === "hypr" ? "hypr-user.lua" : k
    }
    function runningOf(it) { return it.count > 0 }
    // CPU as the script measures it is "percent of ONE core" over a 0.4 s snapshot: a helper process that happens to run at that
    // moment (power-manager starts nvidia-smi / powerprofilesctl every poll) can read above 100. Every refresh is blended into a
    // running average (60 % old, 40 % new), so a one-off burst fades and a steady load shows its true size after a few seconds.
    function smoothCpu(d) {
        var memo = root.cpuMemo, next = {}
        function f(k, v) {
            var o = memo[k], sv = (o === undefined) ? v : o * 0.6 + v * 0.4
            next[k] = sv
            return Math.round(sv * 10) / 10
        }
        var i
        for (i = 0; i < (d.items || []).length; i++) d.items[i].cpu = f("i" + d.items[i].id, d.items[i].cpu)
        for (i = 0; i < (d.procs || []).length; i++) d.procs[i].cpu = f("p" + d.procs[i].pid, d.procs[i].cpu)
        root.cpuMemo = next
    }
    function pct(v) { return v.toFixed(1) + "%" }                       // a share of the whole processor
    function ofCore(v) { return (v < 10 ? v.toFixed(1) : Math.round(v)) + "% core" }   // the same, as a part of one core

    function hit(q, parts) { return q === "" || parts.join(" ").toLowerCase().indexOf(q) >= 0 }
    readonly property var shownItems: {
        var out = [], all = info.items || [], q = query.trim().toLowerCase()
        for (var i = 0; i < all.length; i++) {
            var it = all[i], run = it.count > 0
            if (filter === "running" && !run) continue
            if (filter === "off" && run) continue
            if (!hit(q, [it.name, it.desc || "", kindLabel(it.kind)])) continue
            out.push(it)
        }
        return out
    }
    readonly property int runningCount: {
        var n = 0, all = info.items || []
        for (var i = 0; i < all.length; i++) if (all[i].count > 0) n++
        return n
    }
    readonly property var shownProcs: {
        var out = [], all = info.procs || [], q = query.trim().toLowerCase()
        for (var i = 0; i < all.length; i++) if (hit(q, [all[i].name, all[i].cmd || "", all[i].owner || "", String(all[i].pid)])) out.push(all[i])
        if (sortBy === "cpu") out.sort(function (a, b) { return b.cpu - a.cpu || b.mem - a.mem })
        return out
    }
    readonly property real maxItemMem: { var m = 1, all = info.items || []; for (var i = 0; i < all.length; i++) m = Math.max(m, all[i].mem); return m }
    // ---------------------------------------------------------------- memory history (Health tab): one reading per poll, kept only in
    // this window's memory while it is open (about 10 minutes), so a step up can be matched to the part that caused it
    property var hist: []                     // [{ total: MB, by: { itemId: MB } }]
    readonly property int histMax: 120
    function pushHist(d) {
        var by = {}, tot = 0, all = d.items || []
        for (var i = 0; i < all.length; i++) if (all[i].kind === "halcyon") { by[all[i].id] = all[i].mem; tot += all[i].mem }
        var h = hist.length >= histMax ? hist.slice(1) : hist.slice()
        h.push({ total: tot, by: by })
        hist = h
    }
    // the Halcyon parts that grew most since the first reading: [{ name, from, to, d }]
    readonly property var growers: {
        if (hist.length < 2) return []
        var first = hist[0].by, out = [], all = info.items || []
        for (var i = 0; i < all.length; i++) {
            var it = all[i]
            if (it.kind !== "halcyon" || first[it.id] === undefined) continue
            var dm = it.mem - first[it.id]
            if (dm >= 1) out.push({ name: it.name, from: first[it.id], to: it.mem, d: dm })
        }
        out.sort(function (a, b) { return b.d - a.d })
        return out.slice(0, 4)
    }
    // ---------------------------------------------------------------- Halcyon against its limits
    // "Halcyon" = its own parts together (Hyprland, the island with everything it starts, the helpers: the items marked Halcyon in the list).
    readonly property real halRam: { var m = 0, all = info.items || []; for (var i = 0; i < all.length; i++) if (all[i].kind === "halcyon") m += all[i].mem; return m }
    readonly property real halCpu: { var c = 0, all = info.items || []; for (var i = 0; i < all.length; i++) if (all[i].kind === "halcyon") c += all[i].cpu; return c / ncpu }
    // the limits that count: the learned ones once Adaptive has watched long enough, otherwise the manual ones from Settings
    readonly property var ad: info.adaptive || ({})
    readonly property bool learned: adaptive && ad.state === "ready"
    readonly property real effRam: learned ? Number(ad.ram_limit) : limRam
    readonly property real effCpu: learned ? Number(ad.cpu_limit) : limCpu
    readonly property bool overRam: loaded && halRam > effRam
    readonly property bool overCpu: loaded && cpuStreak >= 2
    readonly property bool overAny: overRam || overCpu
    readonly property string healthState: overAny ? "over" : (loaded && (halRam > effRam * 0.85 || halCpu > effCpu * 0.85) ? "near" : "ok")
    readonly property color healthTone: healthState === "over" ? root.pal.bad : (healthState === "near" ? root.pal.warn : root.pal.good)
    // what the Health tab lists: the RAM causes while RAM is over, the CPU causes once CPU has been over twice in a row
    readonly property var shownFindings: {
        var out = [], f = (info.health && info.health.findings) || []
        for (var i = 0; i < f.length; i++) {
            if (f[i].kind === "ram" && !overRam) continue
            if (f[i].kind === "cpu" && !overCpu) continue
            // the lists inside a card travel as JSON text: a ListModel turns a nested array into a nested model, which a Repeater cannot read as plain strings
            var cj = JSON.stringify(f[i].causes || []), aj = JSON.stringify(f[i].actions || [])
            out.push({ key: f[i].kind + ":" + f[i].id, kind: f[i].kind, id: f[i].id, name: f[i].name, value: f[i].value, share: f[i].share,
                       detail: f[i].detail || "", causesJson: cj, actionsJson: aj, sig: cj + "|" + aj })
        }
        return out
    }
    readonly property real maxProcMem: { var m = 1, all = info.procs || []; for (var i = 0; i < all.length; i++) m = Math.max(m, all[i].mem); return m }

    // ---------------------------------------------------------------- data (only while open)
    // The two lists are ListModels that are brought up to date IN PLACE (rows are moved, changed, added, removed, never rebuilt),
    // so a refresh every 5 s does not make rows flash, lose their hover or jump the scroll position.
    ListModel { id: itemModel; dynamicRoles: true }
    ListModel { id: procModel; dynamicRoles: true }
    ListModel { id: tipModel; dynamicRoles: true }
    ListModel { id: findModel; dynamicRoles: true }
    property var findKeys: []
    // like syncModel, but the lists inside a card (causes, actions) are only replaced when they really changed, so the buttons do not flicker
    function syncFindings(rows) {
        for (var i = 0; i < rows.length; i++) {
            var k = rows[i].key, j = findKeys.indexOf(k, i)
            if (j < 0) { findModel.insert(i, rows[i]); findKeys.splice(i, 0, k) }
            else {
                if (j !== i) { findModel.move(j, i, 1); findKeys.splice(i, 0, findKeys.splice(j, 1)[0]) }
                if (findModel.get(i).sig !== rows[i].sig) findModel.set(i, rows[i])
                else { findModel.setProperty(i, "value", rows[i].value); findModel.setProperty(i, "share", rows[i].share); findModel.setProperty(i, "detail", rows[i].detail) }
            }
        }
        while (findKeys.length > rows.length) { findModel.remove(findKeys.length - 1); findKeys.pop() }
    }
    onShownFindingsChanged: syncFindings(shownFindings)
    property var itemKeys: []
    property var procKeys: []
    property var tipKeys: []
    function syncModel(model, keys, rows, key) {
        for (var i = 0; i < rows.length; i++) {
            var k = rows[i][key], j = keys.indexOf(k, i)
            if (j < 0) { model.insert(i, rows[i]); keys.splice(i, 0, k) }
            else {
                if (j !== i) { model.move(j, i, 1); keys.splice(i, 0, keys.splice(j, 1)[0]) }
                model.set(i, rows[i])
            }
        }
        while (keys.length > rows.length) { model.remove(keys.length - 1); keys.pop() }
    }
    onShownItemsChanged: syncModel(itemModel, itemKeys, shownItems, "id")
    onShownProcsChanged: syncModel(procModel, procKeys, shownProcs, "pid")
    onShownTipsChanged: syncModel(tipModel, tipKeys, shownTips, "id")

    Process {
        id: poll
        command: ["python3", root.script, "list", "--ram", String(Math.round(root.limRam)), "--cpu", String(root.limCpu)].concat(root.adaptive ? ["--auto"] : [])
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    root.smoothCpu(d)
                    var hc = 0
                    for (var hi = 0; hi < (d.items || []).length; hi++) if (d.items[hi].kind === "halcyon") hc += d.items[hi].cpu
                    var lc = (root.adaptive && d.adaptive && d.adaptive.state === "ready") ? Number(d.adaptive.cpu_limit) : root.limCpu
                    root.cpuStreak = (hc / Math.max(1, d.ncpu || 1)) > lc ? root.cpuStreak + 1 : 0
                    root.info = d
                    root.pushHist(d)
                    root.loaded = true
                    root.busyIds = ({})
                } catch (e) {}
            }
        }
    }
    Timer { id: ticker; interval: 5000; running: root.open; repeat: true; triggeredOnStart: true; onTriggered: if (!poll.running) poll.running = true }
    onNoteChanged: if (note !== "") noteT.restart()
    Timer { id: noteT; interval: 9000; onTriggered: root.note = "" }
    Timer { id: again; interval: 1300; onTriggered: if (!poll.running) poll.running = true }
    function refresh() { if (!poll.running) poll.running = true }

    function setToggle(it, on) {
        var b = Object.assign({}, busyIds); b[it.id] = true; busyIds = b
        Quickshell.execDetached(["python3", script, "toggle", it.toggle.mode, it.toggle.key, on ? "1" : "0"])
        note = it.toggle.login ? it.name + ": applies the next time you log in." : ""
        again.restart()
    }
    function itemById(id) {
        var all = info.items || []
        for (var i = 0; i < all.length; i++) if (all[i].id === id) return all[i]
        return null
    }
    function turnOff(id) {
        var it = itemById(id)
        if (!it || !it.toggle) return
        var b = Object.assign({}, busyIds); b[id] = true; busyIds = b
        Quickshell.execDetached(["python3", script, "toggle", it.toggle.mode, it.toggle.key, "0"])
        note = it.name + (it.toggle.mode === "xdg" ? ": will not start at the next login. It keeps running until you end it (Processes tab) or log out."
                          : it.toggle.login ? ": turned off from the next login on." : ": turned off.")
        again.restart()
    }
    function keepTip(id) {
        Quickshell.execDetached(["python3", script, "keep", id])
        again.restart()
    }
    function runAction(a) {
        if (a.t === "preset") { presetPicked(a.v); note = "Resource use set to " + a.v + ". The numbers settle in a few seconds."; again.restart() }
        else if (a.t === "toggle") turnOff(a.id)
        else if (a.t === "end") endProc({ pid: a.pid, name: a.name || "the process" })
    }
    function endProc(p) {
        Quickshell.execDetached(["python3", script, "end", String(p.pid)])
        note = "Asked " + p.name + " (" + p.pid + ") to quit."
        again.restart()
    }

    // ---------------------------------------------------------------- the window
    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
    onOpenChanged: {
        if (open) { note = ""; Qt.callLater(function () { root.forceActiveFocus() }) }
        else { info = empty; hist = []; loaded = false; busyIds = ({}); cpuMemo = ({}); cpuStreak = 0; tipItem = null; query = ""; searchInput.text = "" }       // let go of the numbers: nothing is kept while it is closed
    }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })
    Keys.onPressed: function (e) {
        if (e.key === Qt.Key_Escape) {
            if (searchInput.activeFocus && searchInput.text !== "") searchInput.text = ""
            else root.closed()
            e.accepted = true
        }
        else if (e.key === Qt.Key_Slash && !searchInput.activeFocus) { searchInput.forceActiveFocus(); e.accepted = true }
        else if (e.key === Qt.Key_Tab) { root.tab = root.tab === "startup" ? "procs" : root.tab === "procs" ? "health" : root.tab === "health" ? "tips" : "startup"; e.accepted = true }
        else if (e.key === Qt.Key_F5) { root.refresh(); e.accepted = true }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.45)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }

    Glass {
        id: card
        pal: root.pal
        anchors.centerIn: parent
        width: Math.min(parent.width - 120, 1040)
        height: Math.min(parent.height - 80, 780)
        radius: root.pal.rXl
        opacityBody: root.pal.solid ? 1 : 0.78
        border.color: Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 14

            // ---- header: the gallery's: icon, title, search, switch, round buttons
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: String.fromCodePoint(0xF035B)
                    font.family: root.pal.font; font.pixelSize: 22
                    color: root.pal.accent
                }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 1
                    Text { text: "Startup & processes"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold }
                    Text {
                        text: root.loaded ? (root.info.items.length + " startup items, " + root.runningCount + " running  ·  " + root.info.n_procs + " processes of yours") : "Reading what is running…"
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                    }
                }
                Item { Layout.fillWidth: true }

                Rectangle {
                    visible: root.tab === "startup" || root.tab === "procs"
                    Layout.preferredWidth: 230
                    Layout.preferredHeight: 34
                    radius: 12
                    color: Qt.alpha(root.pal.bg, 0.6)
                    border.width: 1
                    border.color: searchInput.activeFocus ? root.pal.accent : root.pal.line
                    Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10; anchors.rightMargin: 8
                        spacing: 6
                        Text { text: "\uf002"; font.family: root.pal.font; font.pixelSize: 12; color: root.pal.muted }
                        TextInput {
                            id: searchInput
                            Layout.fillWidth: true
                            color: root.pal.text
                            selectionColor: Qt.alpha(root.pal.accent, 0.4)
                            selectedTextColor: root.pal.text
                            font.family: root.pal.uiFont; font.pixelSize: 12
                            clip: true; selectByMouse: true
                            onTextChanged: root.query = text
                            Text {
                                visible: parent.text === "" && !parent.activeFocus
                                text: root.tab === "startup" ? "Search startup items…" : "Search processes…"
                                color: root.pal.muted
                                font.family: parent.font.family; font.pixelSize: parent.font.pixelSize
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Rectangle {
                            visible: searchInput.text !== ""
                            width: 18; height: 18; radius: 9
                            color: clearMa.containsMouse ? Qt.alpha(root.pal.text, 0.2) : "transparent"
                            Text { anchors.centerIn: parent; text: "✕"; font.pixelSize: 10; color: root.pal.muted }
                            MouseArea { id: clearMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: searchInput.text = "" }
                        }
                    }
                }
                SegSwitch {
                    pal: root.pal
                    options: [ { k: "startup", t: "Startup" }, { k: "procs", t: "Processes" }, { k: "health", t: "Health" + (root.overAny ? "  !" : "") }, { k: "tips", t: "Suggestions" + (root.shownTips.length > 0 ? "  " + root.shownTips.length : "") } ]
                    current: root.tab
                    onPicked: k => root.tab = k
                }
                RoundIcon { pal: root.pal; glyph: "\uf021"; onClicked: root.refresh() }
                RoundIcon { pal: root.pal; glyph: "✕"; onClicked: root.closed() }
            }

            // ---- memory: where it all is, in one bar
            Rectangle {
                id: memCard
                Layout.fillWidth: true
                implicitHeight: 86
                radius: root.pal.rLg
                color: Qt.alpha(root.pal.bg, 0.55)
                border.width: 1
                border.color: root.pal.lineTint
                readonly property real total: Math.max(1, root.info.total_mb)
                readonly property real startup: Math.min(root.info.startup_mb, root.info.session_mb)
                readonly property real restSession: Math.max(0, root.info.session_mb - startup)
                readonly property real others: Math.max(0, root.info.total_mb - root.info.avail_mb - root.info.session_mb)
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 30
                        Repeater {
                            model: [
                                { k: "STARTUP ITEMS", v: memCard.startup, c: root.pal.accent, tip: "Memory used by everything in the Startup list: Halcyon's own parts, your hypr-user.lua lines, services and autostart apps. Measured as PSS (shared pages split fairly), so nothing is counted twice." },
                                { k: "REST OF YOUR SESSION", v: memCard.restSession, c: root.pal.accent2, tip: "Everything else you started yourself: browser, editor, terminals, games. Anything that is not a startup item." },
                                { k: "EVERYTHING ELSE", v: memCard.others, c: Qt.alpha(root.pal.muted, 0.6), tip: "Memory in use that is not one of your processes: the kernel, drivers, system services and graphics memory." },
                                { k: "FREE", v: root.info.avail_mb, c: "transparent", tip: "What a program could get right now. It is free memory plus cache the system can drop at once (Linux calls it available)." }
                            ]
                            delegate: Row {
                                id: stat
                                required property var modelData
                                spacing: 9
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 9; height: 9; radius: 4.5
                                    color: stat.modelData.c
                                    border.width: stat.modelData.c === "transparent" ? 1 : 0
                                    border.color: root.pal.muted
                                }
                                Column {
                                    spacing: 0
                                    Titled { label: stat.modelData.k; tip: stat.modelData.tip }
                                    Text { text: root.loaded ? root.fmt(stat.modelData.v) : "—"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 17; font.weight: Font.DemiBold }
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Text { text: root.loaded ? "of " + root.fmt(root.info.total_mb) : ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.alignment: Qt.AlignBottom }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 8
                        radius: 4
                        color: Qt.alpha(root.pal.text, 0.08)
                        clip: true
                        Row {
                            anchors.fill: parent
                            Rectangle { height: parent.height; width: parent.width * memCard.startup / memCard.total; color: root.pal.accent; Behavior on width { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } } }
                            Rectangle { height: parent.height; width: parent.width * memCard.restSession / memCard.total; color: root.pal.accent2; Behavior on width { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } } }
                            Rectangle { height: parent.height; width: parent.width * memCard.others / memCard.total; color: Qt.alpha(root.pal.muted, 0.5); Behavior on width { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } } }
                        }
                    }
                }
            }

            // ---- filters / sorting
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { visible: root.tab === "health"; text: "Halcyon against its limits"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                Q { visible: root.tab === "health"; tip: "Halcyon = its own parts together (Hyprland, the island with its helpers, the daemons). The limits are in Settings > Performance & memory. RAM is checked on every reading; CPU is only flagged after two readings in a row over the limit, so one short burst does not raise an alarm. The causes below are likely ones, worked out from your settings and what each part is doing, not certainties." }
                Text { visible: root.tab === "tips"; text: "Startup items that are not earning their place"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                Q { visible: root.tab === "tips"; tip: "Safe to turn off: this machine has nothing for it to do. Worth a look: it may be useful to you, only you can tell. Nothing is turned off until you press Turn off. Keep hides a suggestion for good. Startup items change at the next login." }
                SegSwitch {
                    pal: root.pal
                    visible: root.tab === "startup"
                    options: [ { k: "all", t: "All" }, { k: "running", t: "Running" }, { k: "off", t: "Not running" } ]
                    current: root.filter
                    onPicked: k => root.filter = k
                }
                Text { visible: root.tab === "procs"; text: "Sort by"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                SegSwitch {
                    pal: root.pal
                    visible: root.tab === "procs"
                    options: [ { k: "mem", t: "Memory" }, { k: "cpu", t: "CPU" } ]
                    current: root.sortBy
                    onPicked: k => root.sortBy = k
                }
                Item { Layout.fillWidth: true }
                Chip {
                    visible: root.overAny && (root.tab === "startup" || root.tab === "procs")
                    pal: root.pal; implicitHeight: 28; maxLabel: 1000
                    label: "Halcyon is over its limit: see why"
                    on: true
                    onClicked: root.tab = "health"
                }
                Chip {
                    visible: root.tab === "startup" && root.shownTips.length > 0
                    pal: root.pal; implicitHeight: 28; maxLabel: 1000
                    label: root.shownTips.length + (root.shownTips.length === 1 ? " suggestion" : " suggestions")
                    on: true
                    onClicked: root.tab = "tips"
                }
                Text {
                    visible: root.loaded && (root.tab === "startup" || root.tab === "procs")
                    text: root.tab === "startup" ? root.shownItems.length + " shown" : root.shownProcs.length + " shown"
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                }
                Q { tip: "Keys:  /  searches   Tab  next view   F5  refreshes   Esc  closes. The numbers refresh every 5 s while this window is open; nothing is read while it is closed." }
            }

            // ---- column titles
            RowLayout {
                visible: root.tab === "startup" || root.tab === "procs"
                Layout.fillWidth: true
                Layout.leftMargin: 16; Layout.rightMargin: 24
                spacing: 12
                Item { Layout.preferredWidth: root.tab === "startup" ? 14 : 44; height: 1 }
                Head {
                    Layout.fillWidth: true; alignRight: false
                    label: root.tab === "startup" ? "ITEM" : "PROCESS"
                    tip: root.tab === "startup"
                         ? "Something that starts with your desktop. Green dot: running. Orange dot: switched on but not running now. Grey dot: switched off. 'core' = Halcyon cannot work without it, so it has no switch. 'missing' = the program is not installed."
                         : "Every program of yours, biggest first. The number on the left is its process id (PID). End asks it to quit politely; the desktop itself is protected."
                }
                Head { visible: root.tab === "procs"; Layout.preferredWidth: 130; alignRight: false; label: "STARTED BY"; tip: "The startup item this process belongs to. A dash means you started it yourself (not at login)." }
                Head { Layout.preferredWidth: 84; label: "MEMORY"; tip: "PSS: the memory a program really uses. Pages that several programs share (libraries) are split fairly between them, so adding the numbers up gives the true total." }
                Head { Layout.preferredWidth: 76; label: "CPU"; tip: "Big number: its share of the whole processor. Small number: the same as a part of ONE core (100% core = one core fully busy). Measured over a short moment and averaged, so a one-off burst fades out." }
                Head { visible: root.tab === "startup"; Layout.preferredWidth: 62; label: "PROCS"; tip: "How many processes this item runs. One program is often several processes (a browser has one per tab)." }
                Item { Layout.preferredWidth: 60; height: 1 }
            }

            // ---- the lists
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: itemList
                    anchors.fill: parent
                    visible: root.tab === "startup"
                    clip: true
                    spacing: 6
                    boundsBehavior: Flickable.StopAtBounds
                    model: itemModel
                    delegate: Rectangle {
                        id: row
                        required property var model
                        readonly property bool running: model.count > 0
                        width: ListView.view ? ListView.view.width - 8 : 0
                        height: 56
                        radius: root.pal.rMd
                        color: rowHover.hovered ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, row.running ? 0.75 : 0.45)
                        border.width: 1
                        border.color: rowHover.hovered ? Qt.alpha(root.pal.accent, 0.3) : root.pal.lineSoft
                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                        HoverHandler { id: rowHover }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 16; anchors.rightMargin: 16
                            spacing: 12
                            Item {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.preferredWidth: 14; Layout.preferredHeight: 14
                                Rectangle { anchors.centerIn: parent; width: 14; height: 14; radius: 7; color: root.pal.good; opacity: row.running ? 0.22 : 0 }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 8; height: 8; radius: 4
                                    color: row.running ? root.pal.good : (row.model.off ? Qt.alpha(root.pal.muted, 0.5) : root.pal.warn)
                                }
                            }
                            Column {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 2
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: row.model.name
                                    color: row.running || !row.model.off ? root.pal.text : Qt.alpha(root.pal.text, 0.6)
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: root.kindLabel(row.model.kind) + (row.model.desc ? "  ·  " + row.model.desc : "")
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                }
                            }
                            // memory, with a small bar against the biggest item
                            Column {
                                Layout.preferredWidth: 84
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 4
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: row.running ? root.fmt(row.model.mem) : "—"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Item {
                                    width: parent.width; height: 3
                                    Rectangle {
                                        anchors.right: parent.right
                                        visible: row.running
                                        height: 3; radius: 1.5
                                        width: Math.max(3, parent.width * (row.model.mem / root.maxItemMem))
                                        color: Qt.alpha(root.pal.accent, 0.6)
                                    }
                                }
                            }
                            Column {
                                Layout.preferredWidth: 76
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 1
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: row.running ? root.pct(row.model.cpu / root.ncpu) : "—"; color: row.model.cpu > 50 ? root.pal.warn : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; visible: row.running; text: root.ofCore(row.model.cpu); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                            }
                            Text { Layout.preferredWidth: 62; horizontalAlignment: Text.AlignRight; text: row.running ? row.model.count : "—"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Item {
                                Layout.preferredWidth: 60
                                Layout.fillHeight: true
                                Toggle {
                                    anchors.centerIn: parent
                                    visible: row.model.toggle !== null && row.model.toggle !== undefined && !row.model.core && !row.model.missing
                                    pal: root.pal
                                    on: row.model.toggle ? row.model.toggle.on : false
                                    busy: root.busyIds[row.model.id] === true
                                    onToggled: root.setToggle(row.model, !row.model.toggle.on)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: row.model.toggle === null || row.model.toggle === undefined || row.model.core || row.model.missing
                                    text: row.model.missing ? "missing" : (row.model.core ? "core" : "")
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                }
                            }
                        }
                    }
                    Rectangle {      // scroll thumb
                        visible: itemList.contentHeight > itemList.height
                        anchors.right: parent.right
                        width: 3; radius: 1.5
                        color: Qt.alpha(root.pal.text, 0.25)
                        height: Math.max(24, itemList.height * itemList.height / Math.max(1, itemList.contentHeight))
                        y: itemList.contentHeight <= itemList.height ? 0 : (itemList.height - height) * itemList.contentY / (itemList.contentHeight - itemList.height)
                    }
                }

                ListView {
                    id: procList
                    anchors.fill: parent
                    visible: root.tab === "procs"
                    clip: true
                    spacing: 5
                    boundsBehavior: Flickable.StopAtBounds
                    model: procModel
                    delegate: Rectangle {
                        id: prow
                        required property var model
                        width: ListView.view ? ListView.view.width - 8 : 0
                        height: 48
                        radius: root.pal.rMd
                        color: procHover.hovered ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, 0.6)
                        border.width: 1
                        border.color: procHover.hovered ? Qt.alpha(root.pal.accent, 0.3) : root.pal.lineSoft
                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                        HoverHandler { id: procHover }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 16; anchors.rightMargin: 16
                            spacing: 12
                            Text { Layout.preferredWidth: 44 - 12; text: prow.model.pid; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Column {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 0
                                Text { width: parent.width; elide: Text.ElideRight; text: prow.model.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                Text { width: parent.width; elide: Text.ElideRight; text: prow.model.cmd; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                            }
                            Text { Layout.preferredWidth: 130; elide: Text.ElideRight; text: prow.model.owner !== "" ? prow.model.owner : "—"; color: prow.model.owner !== "" ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Column {
                                Layout.preferredWidth: 84
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 4
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: root.fmt(prow.model.mem); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Item {
                                    width: parent.width; height: 3
                                    Rectangle {
                                        anchors.right: parent.right
                                        height: 3; radius: 1.5
                                        width: Math.max(3, parent.width * (prow.model.mem / root.maxProcMem))
                                        color: Qt.alpha(root.pal.accent, 0.6)
                                    }
                                }
                            }
                            Column {
                                Layout.preferredWidth: 76
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 1
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: root.pct(prow.model.cpu / root.ncpu); color: prow.model.cpu > 50 ? root.pal.warn : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: root.ofCore(prow.model.cpu); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                            }
                            Item {
                                Layout.preferredWidth: 60
                                Layout.fillHeight: true
                                Chip {
                                    anchors.centerIn: parent
                                    visible: !prow.model.protected
                                    pal: root.pal; implicitHeight: 26; label: "End"
                                    onClicked: root.endProc(prow.model)
                                }
                                Text { anchors.centerIn: parent; visible: prow.model.protected; text: "core"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            }
                        }
                    }
                    Rectangle {
                        visible: procList.contentHeight > procList.height
                        anchors.right: parent.right
                        width: 3; radius: 1.5
                        color: Qt.alpha(root.pal.text, 0.25)
                        height: Math.max(24, procList.height * procList.height / Math.max(1, procList.contentHeight))
                        y: procList.contentHeight <= procList.height ? 0 : (procList.height - height) * procList.contentY / (procList.contentHeight - procList.height)
                    }
                }

                // ---- suggestions: what is running at startup and is not earning its place
                ListView {
                    id: tipList
                    anchors.fill: parent
                    visible: root.tab === "tips"
                    clip: true
                    spacing: 8
                    boundsBehavior: Flickable.StopAtBounds
                    model: tipModel
                    delegate: Rectangle {
                        id: trow
                        required property var model
                        readonly property bool safe: model.level === "safe"
                        readonly property color tone: safe ? root.pal.good : root.pal.warn
                        width: ListView.view ? ListView.view.width - 8 : 0
                        height: 88
                        radius: root.pal.rLg
                        color: tipHover.hovered ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, 0.75)
                        border.width: 1
                        border.color: tipHover.hovered ? Qt.alpha(root.pal.accent, 0.3) : root.pal.lineSoft
                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                        HoverHandler { id: tipHover }

                        Rectangle {
                            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                            anchors.margins: 12
                            width: 3; radius: 1.5
                            color: trow.tone
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 28; anchors.rightMargin: 16; anchors.topMargin: 10; anchors.bottomMargin: 10
                            spacing: 16
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 5
                                RowLayout {
                                    spacing: 10
                                    Text { text: trow.model.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                                    Rectangle {
                                        implicitWidth: pillText.implicitWidth + 16; implicitHeight: 18; radius: 9
                                        color: Qt.alpha(trow.tone, 0.16)
                                        Text {
                                            id: pillText
                                            anchors.centerIn: parent
                                            text: trow.safe ? "SAFE TO TURN OFF" : "WORTH A LOOK"
                                            color: trow.tone
                                            font.family: root.pal.uiFont; font.pixelSize: 9; font.weight: Font.DemiBold; font.letterSpacing: 1
                                        }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: trow.model.why
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
                                }
                            }
                            Column {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.preferredWidth: 78
                                visible: trow.model.mb >= 1
                                spacing: 0
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: "−" + root.fmt(trow.model.mb); color: root.pal.good; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text { width: parent.width; horizontalAlignment: Text.AlignRight; text: "memory"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                            }
                            Chip { Layout.alignment: Qt.AlignVCenter; pal: root.pal; maxLabel: 1000; implicitHeight: 32; label: "Turn off"; on: true; onClicked: root.turnOff(trow.model.id) }
                            Chip { Layout.alignment: Qt.AlignVCenter; pal: root.pal; maxLabel: 1000; implicitHeight: 32; label: "Keep"; onClicked: root.keepTip(trow.model.id) }
                        }
                    }
                }

                // ---- health: Halcyon as a whole against its limits, and why when it is over
                Flickable {
                    id: healthView
                    anchors.fill: parent
                    visible: root.tab === "health"
                    clip: true
                    contentWidth: width
                    contentHeight: healthCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: healthCol
                        width: healthView.width - 8
                        spacing: 10

                        Rectangle {
                            width: parent.width
                            height: 158
                            radius: root.pal.rLg
                            color: Qt.alpha(root.pal.bg, 0.55)
                            border.width: 1
                            border.color: root.loaded && root.healthState !== "ok" ? Qt.alpha(root.healthTone, 0.5) : root.pal.lineTint
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 12
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Rectangle { Layout.alignment: Qt.AlignVCenter; width: 10; height: 10; radius: 5; color: root.loaded ? root.healthTone : root.pal.muted }
                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: !root.loaded ? "Reading…"
                                              : root.healthState === "over" ? "Halcyon is over its " + (root.overRam && root.overCpu ? "RAM and CPU limits" : root.overRam ? "RAM limit" : "CPU limit")
                                              : root.healthState === "near" ? "Halcyon is close to a limit" : "Halcyon is within its limits"
                                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold
                                    }
                                    Item { Layout.fillWidth: true }
                                    Text { text: root.loaded ? "all Halcyon parts together" : ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                }
                                Meter {
                                    Layout.fillWidth: true
                                    label: "MEMORY (PSS)"
                                    value: root.halRam; limit: root.effRam
                                    valueText: root.loaded ? root.fmt(root.halRam) : "—"
                                    limitText: root.fmt(root.effRam)
                                    tone: root.overRam ? root.pal.bad : (root.halRam > root.effRam * 0.85 ? root.pal.warn : root.pal.good)
                                }
                                Meter {
                                    Layout.fillWidth: true
                                    label: "CPU (SHARE OF THE WHOLE PROCESSOR)"
                                    value: root.halCpu; limit: root.effCpu
                                    valueText: root.loaded ? root.pct(root.halCpu) : "—"
                                    limitText: root.effCpu + "%"
                                    tone: root.overCpu ? root.pal.bad : (root.halCpu > root.effCpu * 0.85 ? root.pal.warn : root.pal.good)
                                }
                            }
                        }

                        // ---- Halcyon's memory over the last minutes: which part made it step up
                        Rectangle {
                            width: parent.width
                            height: 36 + 120 + 16 + (root.growers.length > 0 ? 24 + root.growers.length * 20 : 24) + 16
                            radius: root.pal.rLg
                            color: Qt.alpha(root.pal.bg, 0.55)
                            border.width: 1
                            border.color: root.pal.lineTint
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 8
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "MEMORY OVER TIME"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; font.letterSpacing: 1.2 }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        text: root.hist.length < 2 ? "collecting…" : "last " + Math.max(1, Math.round(root.hist.length * 5 / 60)) + " min, one point every 5 s"
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                }
                                Canvas {
                                    id: histCv
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 120
                                    visible: root.tab === "health"
                                    onPaint: {
                                        var c = getContext("2d")
                                        c.clearRect(0, 0, width, height)
                                        var h = root.hist
                                        if (h.length < 2) return
                                        var lo = 1e9, hi = 0
                                        for (var i = 0; i < h.length; i++) { lo = Math.min(lo, h[i].total); hi = Math.max(hi, h[i].total) }
                                        hi = Math.max(hi, lo + 20)                      // a flat line stays flat, not stretched to the edges
                                        var pad = (hi - lo) * 0.15, y0 = lo - pad, y1 = hi + pad
                                        function X(i) { return 2 + (width - 4) * i / (root.histMax - 1) + (width - 4) * (root.histMax - h.length) / (root.histMax - 1) }
                                        function Y(v) { return height - 4 - (height - 8) * (v - y0) / (y1 - y0) }
                                        c.strokeStyle = String(Qt.alpha(root.pal.muted, 0.25)); c.lineWidth = 1
                                        c.beginPath(); c.moveTo(0, height - 0.5); c.lineTo(width, height - 0.5); c.stroke()
                                        c.beginPath()
                                        for (var j = 0; j < h.length; j++) { if (j === 0) c.moveTo(X(j), Y(h[j].total)); else c.lineTo(X(j), Y(h[j].total)) }
                                        c.strokeStyle = String(root.pal.accent); c.lineWidth = 2; c.lineJoin = "round"; c.stroke()
                                        c.lineTo(X(h.length - 1), height); c.lineTo(X(0), height); c.closePath()
                                        c.fillStyle = String(Qt.alpha(root.pal.accent, 0.12)); c.fill()
                                        c.fillStyle = String(root.pal.muted); c.font = "10px sans-serif"
                                        c.fillText(root.fmt(hi), 4, 11); c.fillText(root.fmt(lo), 4, height - 6)
                                    }
                                    Connections { target: root; function onHistChanged() { if (root.tab === "health") histCv.requestPaint() } }
                                    onVisibleChanged: if (visible) requestPaint()
                                }
                                Text {
                                    visible: root.growers.length === 0
                                    text: root.hist.length < 2 ? "Leave this window open and a part that keeps growing will be named here." : "No Halcyon part has grown since this window opened."
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                }
                                Text {
                                    visible: root.growers.length > 0
                                    text: "GREW MOST SINCE THIS WINDOW OPENED"
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; font.letterSpacing: 1.2
                                }
                                Repeater {
                                    model: root.growers
                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        Text { Layout.fillWidth: true; text: modelData.name; elide: Text.ElideRight; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        Text { text: root.fmt(modelData.from) + "  \u2192  " + root.fmt(modelData.to); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                        Text { text: "+" + root.fmt(modelData.d); color: root.pal.warn; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                    }
                                }
                            }
                        }

                        Cap { visible: root.shownFindings.length > 0; leftPadding: 4; text: "WHY, AND WHAT YOU CAN DO" }

                        Repeater {
                            model: findModel
                            delegate: Rectangle {
                                id: fcard
                                required property var model
                                readonly property color tone: model.kind === "machine" ? root.pal.warn : root.pal.bad
                                readonly property var causes: JSON.parse(model.causesJson)
                                readonly property var actions: JSON.parse(model.actionsJson)
                                width: healthCol.width
                                height: fcol.implicitHeight + 28
                                radius: root.pal.rLg
                                color: Qt.alpha(root.pal.surface, 0.75)
                                border.width: 1
                                border.color: root.pal.lineSoft
                                Rectangle {
                                    anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                                    anchors.margins: 12
                                    width: 3; radius: 1.5
                                    color: fcard.tone
                                }
                                Column {
                                    id: fcol
                                    x: 28; y: 14
                                    width: fcard.width - 28 - 16
                                    spacing: 8
                                    RowLayout {
                                        width: parent.width
                                        spacing: 10
                                        Text { Layout.alignment: Qt.AlignVCenter; text: fcard.model.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            implicitWidth: kindText.implicitWidth + 16; implicitHeight: 18; radius: 9
                                            color: Qt.alpha(fcard.tone, 0.16)
                                            Text {
                                                id: kindText
                                                anchors.centerIn: parent
                                                text: fcard.model.kind === "ram" ? "RAM" : fcard.model.kind === "cpu" ? "CPU" : "WHOLE MACHINE"
                                                color: fcard.tone
                                                font.family: root.pal.uiFont; font.pixelSize: 9; font.weight: Font.DemiBold; font.letterSpacing: 1
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
                                        Column {
                                            Layout.alignment: Qt.AlignVCenter
                                            Text { anchors.right: parent.right; text: fcard.model.value; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold }
                                            Text { anchors.right: parent.right; visible: fcard.model.share > 0; text: fcard.model.share + "% of Halcyon"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                                        }
                                    }
                                    Text {
                                        visible: fcard.model.detail !== ""
                                        width: parent.width
                                        text: fcard.model.detail
                                        wrapMode: Text.WordWrap
                                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                    Cap { topPadding: 2; text: "LIKELY CAUSES" }
                                    Repeater {
                                        model: fcard.causes
                                        delegate: Row {
                                            required property var modelData
                                            width: fcol.width
                                            spacing: 8
                                            Text { width: 8; text: "•"; color: fcard.tone; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                            Text { width: parent.width - 16; text: parent.modelData; wrapMode: Text.WordWrap; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                        }
                                    }
                                    Cap { visible: fcard.actions.length > 0; topPadding: 4; text: "WHAT YOU CAN DO" }
                                    Repeater {
                                        model: fcard.actions
                                        delegate: Item {
                                            id: act
                                            required property var modelData
                                            readonly property bool isBtn: modelData.t !== "text"
                                            width: fcol.width
                                            height: isBtn ? btn.implicitHeight : txt.implicitHeight
                                            Chip {
                                                id: btn
                                                visible: act.isBtn
                                                pal: root.pal; implicitHeight: 30; maxLabel: 1000
                                                label: act.modelData.label
                                                on: act.modelData.t === "preset"
                                                onClicked: root.runAction(act.modelData)
                                            }
                                            Column {
                                                id: txt
                                                visible: !act.isBtn
                                                width: parent.width
                                                spacing: 1
                                                Text { width: parent.width; text: act.modelData.label; color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.DemiBold }
                                                Text { width: parent.width; text: act.modelData.text || ""; wrapMode: Text.WordWrap; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.loaded && root.overAny && root.shownFindings.length === 0
                            width: parent.width; leftPadding: 4; wrapMode: Text.WordWrap
                            text: "Nothing stands out now: likely a short burst. F5 checks again."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        }
                        Text {
                            visible: root.loaded && !root.overAny
                            width: parent.width; leftPadding: 4; wrapMode: Text.WordWrap
                            text: "Nothing to fix."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        }
                        Text {
                            visible: root.loaded
                            width: parent.width; leftPadding: 4; wrapMode: Text.WordWrap
                            text: !root.adaptive ? "Limits: " + root.fmt(root.limRam) + " of RAM and " + root.limCpu + "% of the processor. Change them in Settings > Performance & memory."
                                : root.learned ? "Limits learned from your own use (the last " + Math.min(14, Math.floor(root.ad.days || 0)) + " days, " + root.ad.samples + " readings): " + root.fmt(root.effRam) + " of RAM and " + root.effCpu + "% of the processor. They keep adjusting. Settings > Performance & memory to go back to manual."
                                : "Learning what is normal for you: day " + Math.min(root.ad.need_days || 3, Math.floor(root.ad.days || 0) + 1) + " of " + (root.ad.need_days || 3) + ", " + (root.ad.samples || 0) + " readings so far (one every 5 min while the desktop runs). Until then the manual limits apply: " + root.fmt(root.limRam) + " and " + root.limCpu + "%."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                        }
                    }
                    Rectangle {
                        visible: healthView.contentHeight > healthView.height
                        anchors.right: parent.right
                        width: 3; radius: 1.5
                        color: Qt.alpha(root.pal.text, 0.25)
                        height: Math.max(24, healthView.height * healthView.height / Math.max(1, healthView.contentHeight))
                        y: healthView.contentHeight <= healthView.height ? 0 : (healthView.height - height) * healthView.contentY / (healthView.contentHeight - healthView.height)
                    }
                }

                Column {
                    anchors.centerIn: parent
                    visible: root.loaded && root.tab === "tips" && root.shownTips.length === 0
                    spacing: 6
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Nothing stands out"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 16; font.weight: Font.DemiBold }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Everything that starts with your desktop is doing a job on this machine."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.loaded && ((root.tab === "startup" && root.shownItems.length === 0) || (root.tab === "procs" && root.shownProcs.length === 0))
                    text: root.query !== "" ? "Nothing matches “" + root.query + "”" : "Nothing matches this filter"
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
                Text {
                    anchors.centerIn: parent
                    visible: !root.loaded
                    text: "Reading what is running…"
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
            }

            // ---- footer: only the answer to what you just did (the explanations are the "?" markers above)
            Text {
                visible: root.note !== ""
                Layout.fillWidth: true
                text: root.note
                color: root.pal.accent
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
                elide: Text.ElideRight
            }
        }

        // the one bubble every "?" shows; it lives on the card so no list or row can cut it off
        Rectangle {
            id: bubble
            z: 40
            visible: root.tipItem !== null
            width: Math.min(320, card.width - 40)
            height: bubbleText.implicitHeight + 22
            radius: root.pal.rMd
            color: Qt.alpha(root.pal.bg, 0.98)
            border.width: 1
            border.color: Qt.alpha(root.pal.accent, 0.5)
            x: Math.max(12, Math.min(card.width - width - 12, root.tipCx - width / 2))
            y: root.tipBottom + 10 + height > card.height - 8 ? root.tipTop - height - 10 : root.tipBottom + 10
            Text {
                id: bubbleText
                x: 12; y: 11
                width: parent.width - 24
                text: root.tipText
                wrapMode: Text.WordWrap
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap + 1
                lineHeight: 1.15
            }
        }

        // a few stars flying over everything on the card (Settings > Look > Moving stars), the same as the bar builder and the gallery
        BarStars { z: 20; anchors.fill: parent; anchors.margins: 14; pal: root.pal; count: 10; loopMs: 140000; sizeScale: 1.4; active: root.open; visible: root.open && root.movingStars }
    }
}
