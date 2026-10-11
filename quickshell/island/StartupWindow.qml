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
// The data comes from scripts/startup-view.py, polled every 5 s ONLY while the window is open; when it closes the numbers are
// dropped and the window is unloaded, so it costs nothing while you are not looking at it.
Item {
    id: root

    property var pal
    property bool open: false
    property bool movingStars: true      // the few stars flying over the card (Settings > Look > Moving stars), like the bar builder and the gallery
    signal closed()

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/startup-view.py"
    readonly property var empty: ({ items: [], procs: [], n_procs: 0, session_mb: 0, startup_mb: 0, total_mb: 0, avail_mb: 0 })
    property var info: empty
    property bool loaded: false
    property string tab: "startup"            // startup | procs
    property string filter: "all"             // startup tab: all | running | off
    property string sortBy: "mem"             // processes tab: mem | cpu
    property var busyIds: ({})
    property string note: ""
    property string query: ""                 // the search box: filters whichever list is showing

    component Cap: Text { color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }

    // ---------------------------------------------------------------- numbers
    function fmt(mb) {
        if (mb >= 1024) return (mb / 1024).toFixed(2) + " GB"
        return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + " MB"
    }
    function kindLabel(k) {
        return k === "halcyon" ? "Halcyon" : k === "service" ? "Service" : k === "autostart" ? "Autostart" : k === "hypr" ? "hypr-user.lua" : k
    }
    function runningOf(it) { return it.count > 0 }

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
    readonly property real maxProcMem: { var m = 1, all = info.procs || []; for (var i = 0; i < all.length; i++) m = Math.max(m, all[i].mem); return m }

    // ---------------------------------------------------------------- data (only while open)
    // The two lists are ListModels that are brought up to date IN PLACE (rows are moved, changed, added, removed, never rebuilt),
    // so a refresh every 5 s does not make rows flash, lose their hover or jump the scroll position.
    ListModel { id: itemModel; dynamicRoles: true }
    ListModel { id: procModel; dynamicRoles: true }
    property var itemKeys: []
    property var procKeys: []
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

    Process {
        id: poll
        command: ["python3", root.script, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    root.info = d
                    root.loaded = true
                    root.busyIds = ({})
                } catch (e) {}
            }
        }
    }
    Timer { id: ticker; interval: 5000; running: root.open; repeat: true; triggeredOnStart: true; onTriggered: if (!poll.running) poll.running = true }
    Timer { id: again; interval: 1300; onTriggered: if (!poll.running) poll.running = true }
    function refresh() { if (!poll.running) poll.running = true }

    function setToggle(it, on) {
        var b = Object.assign({}, busyIds); b[it.id] = true; busyIds = b
        Quickshell.execDetached(["python3", script, "toggle", it.toggle.mode, it.toggle.key, on ? "1" : "0"])
        note = it.toggle.login ? it.name + ": applies the next time you log in." : ""
        again.restart()
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
        else { info = empty; loaded = false; busyIds = ({}); query = ""; searchInput.text = "" }       // let go of the numbers: nothing is kept while it is closed
    }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })
    Keys.onPressed: function (e) {
        if (e.key === Qt.Key_Escape) {
            if (searchInput.activeFocus && searchInput.text !== "") searchInput.text = ""
            else root.closed()
            e.accepted = true
        }
        else if (e.key === Qt.Key_Slash && !searchInput.activeFocus) { searchInput.forceActiveFocus(); e.accepted = true }
        else if (e.key === Qt.Key_Tab) { root.tab = root.tab === "startup" ? "procs" : "startup"; e.accepted = true }
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
                    options: [ { k: "startup", t: "Startup" }, { k: "procs", t: "Processes" } ]
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
                                { k: "STARTUP ITEMS", v: memCard.startup, c: root.pal.accent },
                                { k: "REST OF YOUR SESSION", v: memCard.restSession, c: root.pal.accent2 },
                                { k: "EVERYTHING ELSE", v: memCard.others, c: Qt.alpha(root.pal.muted, 0.6) },
                                { k: "FREE", v: root.info.avail_mb, c: "transparent" }
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
                                    Cap { text: stat.modelData.k }
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
                Text {
                    visible: root.loaded
                    text: root.tab === "startup" ? root.shownItems.length + " shown" : root.shownProcs.length + " shown"
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                }
            }

            // ---- column titles
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16; Layout.rightMargin: 24
                spacing: 12
                Item { Layout.preferredWidth: root.tab === "startup" ? 14 : 44; height: 1 }
                Cap { Layout.fillWidth: true; text: root.tab === "startup" ? "ITEM" : "PROCESS" }
                Cap { visible: root.tab === "procs"; Layout.preferredWidth: 130; text: "STARTED BY" }
                Cap { Layout.preferredWidth: 84; horizontalAlignment: Text.AlignRight; text: "MEMORY" }
                Cap { Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight; text: "CPU" }
                Cap { visible: root.tab === "startup"; Layout.preferredWidth: 34; horizontalAlignment: Text.AlignRight; text: "PROC" }
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
                            Text { Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight; text: row.running ? row.model.cpu.toFixed(1) + "%" : "—"; color: row.model.cpu > 25 ? root.pal.warn : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Text { Layout.preferredWidth: 34; horizontalAlignment: Text.AlignRight; text: row.running ? row.model.count : "—"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
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
                            Text { Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight; text: prow.model.cpu.toFixed(1) + "%"; color: prow.model.cpu > 25 ? root.pal.warn : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
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

            // ---- footer
            Text {
                Layout.fillWidth: true
                text: root.note !== "" ? root.note : "Memory is PSS (shared pages split fairly). The switch changes what starts next login; polkit and portal need a new login. / searches, Tab switches view, F5 refreshes, Esc closes."
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
                elide: Text.ElideRight
            }
        }

        // a few stars flying over everything on the card (Settings > Look > Moving stars), the same as the bar builder and the gallery
        BarStars { z: 20; anchors.fill: parent; anchors.margins: 14; pal: root.pal; count: 10; loopMs: 140000; sizeScale: 1.4; active: root.open; visible: root.open && root.movingStars }
    }
}
