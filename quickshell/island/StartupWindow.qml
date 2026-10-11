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

    readonly property var shownItems: {
        var out = [], all = info.items || []
        for (var i = 0; i < all.length; i++) {
            var it = all[i], run = it.count > 0
            if (filter === "running" && !run) continue
            if (filter === "off" && run) continue
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
        var out = (info.procs || []).slice()
        if (sortBy === "cpu") out.sort(function (a, b) { return b.cpu - a.cpu || b.mem - a.mem })
        return out
    }
    readonly property real maxItemMem: { var m = 1, all = info.items || []; for (var i = 0; i < all.length; i++) m = Math.max(m, all[i].mem); return m }
    readonly property real maxProcMem: { var m = 1, all = info.procs || []; for (var i = 0; i < all.length; i++) m = Math.max(m, all[i].mem); return m }

    // ---------------------------------------------------------------- data (only while open)
    Process {
        id: poll
        command: ["python3", root.script, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    var y1 = itemList.contentY, y2 = procList.contentY      // a refresh must not scroll the lists back to the top
                    root.info = d
                    root.loaded = true
                    root.busyIds = ({})
                    Qt.callLater(function () { itemList.contentY = y1; procList.contentY = y2 })
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
        else { info = empty; loaded = false; busyIds = ({}) }       // let go of the numbers: nothing is kept while it is closed
    }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })
    Keys.onPressed: function (e) {
        if (e.key === Qt.Key_Escape) { root.closed(); e.accepted = true }
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
            anchors.margins: 32
            spacing: 14

            // ---- header
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Rectangle { Layout.alignment: Qt.AlignVCenter; width: 8; height: 8; radius: 4; color: root.pal.accent }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text { text: "Startup & processes"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
                    Text {
                        text: root.loaded ? (root.info.items.length + " startup items, " + root.runningCount + " running  ·  " + root.info.n_procs + " processes of yours") : "Reading what is running…"
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                    }
                }
                Item { Layout.fillWidth: true }
                ActionChip { pal: root.pal; label: "Refresh"; doneLabel: "Refreshed"; onClicked: root.refresh() }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            // ---- totals
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Repeater {
                    model: [
                        { k: "YOUR SESSION", v: root.fmt(root.info.session_mb), s: "all your processes, PSS" },
                        { k: "STARTUP ITEMS", v: root.fmt(root.info.startup_mb), s: "what the list below owns" },
                        { k: "MEMORY FREE", v: root.fmt(root.info.avail_mb), s: "of " + root.fmt(root.info.total_mb) }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 62
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.surface, 0.8)
                        border.width: 1
                        border.color: root.pal.lineSoft
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.leftMargin: 16
                            spacing: 1
                            Text { text: modelData.k; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }
                            Text { text: root.loaded ? modelData.v : "—"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold }
                            Text { text: modelData.s; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                        }
                    }
                }
            }

            // ---- tabs + filters
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Chip { pal: root.pal; implicitHeight: 30; label: "Startup items"; on: root.tab === "startup"; onClicked: root.tab = "startup" }
                Chip { pal: root.pal; implicitHeight: 30; label: "All processes"; on: root.tab === "procs"; onClicked: root.tab = "procs" }
                Item { Layout.fillWidth: true }
                Chip { visible: root.tab === "startup"; pal: root.pal; implicitHeight: 28; label: "All"; on: root.filter === "all"; onClicked: root.filter = "all" }
                Chip { visible: root.tab === "startup"; pal: root.pal; implicitHeight: 28; label: "Running"; on: root.filter === "running"; onClicked: root.filter = "running" }
                Chip { visible: root.tab === "startup"; pal: root.pal; implicitHeight: 28; label: "Not running"; on: root.filter === "off"; onClicked: root.filter = "off" }
                Text { visible: root.tab === "procs"; text: "Sort by"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                Chip { visible: root.tab === "procs"; pal: root.pal; implicitHeight: 28; label: "Memory"; on: root.sortBy === "mem"; onClicked: root.sortBy = "mem" }
                Chip { visible: root.tab === "procs"; pal: root.pal; implicitHeight: 28; label: "CPU"; on: root.sortBy === "cpu"; onClicked: root.sortBy = "cpu" }
            }

            // ---- column titles
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 14; Layout.rightMargin: 14
                spacing: 12
                Item { width: root.tab === "startup" ? 8 : 54; height: 1 }
                Cap { Layout.fillWidth: true; text: root.tab === "startup" ? "ITEM" : "PROCESS" }
                Cap { visible: root.tab === "procs"; Layout.preferredWidth: 130; text: "STARTED BY" }
                Cap { Layout.preferredWidth: 76; horizontalAlignment: Text.AlignRight; text: "MEMORY" }
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
                    model: root.shownItems
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        readonly property bool running: modelData.count > 0
                        width: ListView.view ? ListView.view.width - 8 : 0
                        height: 54
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.surface, row.running ? 0.8 : 0.5)
                        border.width: 1
                        border.color: root.pal.lineSoft

                        // how much memory it holds, against the biggest item
                        Rectangle {
                            anchors.left: parent.left; anchors.bottom: parent.bottom
                            anchors.leftMargin: 14; anchors.bottomMargin: 4
                            height: 2; radius: 1
                            width: Math.max(2, (parent.width - 28) * (row.modelData.mem / root.maxItemMem))
                            color: Qt.alpha(root.pal.accent, 0.5)
                            visible: row.running
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14; anchors.rightMargin: 14
                            spacing: 12
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                width: 8; height: 8; radius: 4
                                color: row.running ? root.pal.good : (row.modelData.off ? Qt.alpha(root.pal.muted, 0.5) : root.pal.warn)
                            }
                            Column {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 1
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: row.modelData.name
                                    color: row.running || !row.modelData.off ? root.pal.text : Qt.alpha(root.pal.text, 0.6)
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: root.kindLabel(row.modelData.kind) + (row.modelData.desc ? "  ·  " + row.modelData.desc : "")
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                }
                            }
                            Text { Layout.preferredWidth: 76; horizontalAlignment: Text.AlignRight; text: row.running ? root.fmt(row.modelData.mem) : "—"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Text { Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight; text: row.running ? row.modelData.cpu.toFixed(1) + "%" : "—"; color: row.modelData.cpu > 25 ? root.pal.warn : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Text { Layout.preferredWidth: 34; horizontalAlignment: Text.AlignRight; text: row.running ? row.modelData.count : "—"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Item {
                                Layout.preferredWidth: 60
                                Layout.fillHeight: true
                                Toggle {
                                    anchors.centerIn: parent
                                    visible: row.modelData.toggle !== null && !row.modelData.core && !row.modelData.missing
                                    pal: root.pal
                                    on: row.modelData.toggle ? row.modelData.toggle.on : false
                                    busy: root.busyIds[row.modelData.id] === true
                                    onToggled: root.setToggle(row.modelData, !row.modelData.toggle.on)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: row.modelData.toggle === null || row.modelData.core || row.modelData.missing
                                    text: row.modelData.missing ? "missing" : (row.modelData.core ? "core" : "")
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
                    spacing: 4
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.shownProcs
                    delegate: Rectangle {
                        id: prow
                        required property var modelData
                        width: ListView.view ? ListView.view.width - 8 : 0
                        height: 46
                        radius: root.pal.rMd
                        color: Qt.alpha(root.pal.surface, 0.6)
                        border.width: 1
                        border.color: root.pal.lineSoft

                        Rectangle {
                            anchors.left: parent.left; anchors.bottom: parent.bottom
                            anchors.leftMargin: 14; anchors.bottomMargin: 3
                            height: 2; radius: 1
                            width: Math.max(2, (parent.width - 28) * (prow.modelData.mem / root.maxProcMem))
                            color: Qt.alpha(root.pal.accent, 0.5)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14; anchors.rightMargin: 14
                            spacing: 12
                            Text { Layout.preferredWidth: 54 - 12; text: prow.modelData.pid; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Column {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 0
                                Text { width: parent.width; elide: Text.ElideRight; text: prow.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                Text { width: parent.width; elide: Text.ElideRight; text: prow.modelData.cmd; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                            }
                            Text { Layout.preferredWidth: 130; elide: Text.ElideRight; text: prow.modelData.owner !== "" ? prow.modelData.owner : "—"; color: prow.modelData.owner !== "" ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Text { Layout.preferredWidth: 76; horizontalAlignment: Text.AlignRight; text: root.fmt(prow.modelData.mem); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Text { Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight; text: prow.modelData.cpu.toFixed(1) + "%"; color: prow.modelData.cpu > 25 ? root.pal.warn : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Item {
                                Layout.preferredWidth: 60
                                Layout.fillHeight: true
                                Chip {
                                    anchors.centerIn: parent
                                    visible: !prow.modelData.protected
                                    pal: root.pal; implicitHeight: 26; label: "End"
                                    onClicked: root.endProc(prow.modelData)
                                }
                                Text { anchors.centerIn: parent; visible: prow.modelData.protected; text: "core"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
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
                    visible: root.loaded && root.tab === "startup" && root.shownItems.length === 0
                    text: "Nothing matches this filter"
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
                text: root.note !== "" ? root.note : "Memory is PSS (shared pages split fairly). The switch changes what starts next login; polkit and portal need a new login. Tab switches view, F5 refreshes, Esc closes."
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
                elide: Text.ElideRight
            }
        }
    }
}
