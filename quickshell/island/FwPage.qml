pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// The firewall page: what ai-firewall is doing right now. Reads the status file the daemon rewrites every 3 s
// (/run/ai-firewall/status.json, world-readable), only while the page is open. Changes run in the pop-out console
// (sudo asks for the password there), so the island itself never needs root; the dashboard opens a terminal.
Item {
    id: root
    property var pal
    property bool active: false
    signal consoleRequested(string cmd)       // shell.qml runs it in the pop-out console

    property var st: null               // the parsed status, null = daemon not running
    property double readAt: 0
    readonly property bool alive: st !== null && (Date.now() / 1000 - (st.updated_unix || 0)) < 30
    readonly property var bans: st ? (st.bans || []) : []
    readonly property var recent: st ? (st.recent || []).slice().reverse() : []

    // per-second rates from the last two reads
    property double lastPassed: -1
    property double lastDropped: -1
    property real passRate: 0
    property real dropRate: 0

    function dur(s) {
        if (s <= 0) return "forever"
        if (s < 120) return s + "s"
        if (s < 7200) return Math.floor(s / 60) + "m"
        return Math.floor(s / 3600) + "h" + String(Math.floor(s % 3600 / 60)).padStart(2, "0")
    }
    function count(n) {
        if (n >= 1e7) return Math.round(n / 1e6) + "M"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
        if (n >= 1e4) return Math.round(n / 1e3) + "k"
        return String(n)
    }
    function ports(list) { return list && list.length ? list.join(" ") : "none" }

    readonly property string scripts: Quickshell.env("HOME") + "/.config/Halcyon/scripts"
    function inTerminal(cmd) {
        Quickshell.execDetached(["bash", scripts + "/apps.sh", "term-exec", "bash", "-c", cmd])
    }

    FileView {
        id: statusFile
        path: "/run/ai-firewall/status.json"
        printErrors: false
        onLoaded: {
            try {
                const s = JSON.parse(text())
                const dropped = (s.dropped_policy || 0) + (s.dropped_blocklist || 0)
                const dt = Math.max(1, (Date.now() - root.readAt) / 1000)
                if (root.lastPassed >= 0) {
                    root.passRate = Math.max(0, (s.passed - root.lastPassed) / dt)
                    root.dropRate = Math.max(0, (dropped - root.lastDropped) / dt)
                }
                root.lastPassed = s.passed || 0
                root.lastDropped = dropped
                root.readAt = Date.now()
                root.st = s
            } catch (e) { root.st = null }
        }
        onLoadFailed: root.st = null
    }
    // the daemon replaces the file (write + rename), which a file watch would lose track of: just re-read it
    Timer {
        interval: 2000
        repeat: true
        running: root.active
        triggeredOnStart: true
        onTriggered: statusFile.reload()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        anchors.leftMargin: 34
        anchors.rightMargin: 34
        spacing: 12

        // ---- state line
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Rectangle {
                Layout.preferredWidth: 36; Layout.preferredHeight: 36; radius: root.pal.rMd - 2
                color: Qt.alpha(stateColor.color, 0.14)
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(root.alive ? 0xF0565 : 0xF099D)     // shield-check / shield-off
                    color: stateColor.color
                    font.family: root.pal.font
                    font.pixelSize: 18
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    id: stateColor
                    text: !root.st ? "Firewall is not running"
                        : !root.alive ? "Firewall is not responding"
                        : root.st.mode === "enforce" ? "Protecting" : "Monitoring only"
                    color: !root.alive ? root.pal.bad : (root.st.mode === "enforce" ? root.pal.good : root.pal.warn)
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tTitle
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: !root.st ? "start it with: sudo systemctl start ai-firewall"
                        : (root.st.interface || "no uplink") + " · " + (root.st.xdp_mode || "-") + " XDP · up "
                          + root.dur(Math.max(1, root.st.updated_unix - root.st.started_unix))
                          + (root.st.attaches > 1 ? " · healed " + (root.st.attaches - 1) + "×" : "")
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
            }
            Text {
                visible: root.st !== null
                text: "tcp " + root.ports(root.st ? root.st.allow_tcp : []) + "   udp " + root.ports(root.st ? root.st.allow_udp : [])
                color: root.pal.muted
                font.family: root.pal.mono
                font.pixelSize: root.pal.tCap
            }
        }

        // ---- counters
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Repeater {
                model: [
                    { v: root.st ? root.count(root.st.passed) : "–", sub: Math.round(root.passRate) + "/s", label: "passed", c: root.pal.good },
                    { v: root.st ? root.count(root.st.dropped_policy) : "–", sub: Math.round(root.dropRate) + "/s dropped", label: "blocked by policy", c: root.pal.warn },
                    { v: root.st ? root.count(root.st.dropped_blocklist) : "–", sub: root.bans.length + " banned", label: "from banned sources", c: root.pal.bad },
                    { v: root.st ? root.count(root.st.dropped_feed || 0) : "–", sub: root.count(root.st ? (root.st.feed_networks || 0) : 0) + " listed", label: "from blocklists", c: root.pal.accent2 }
                ]
                delegate: Rectangle {
                    id: tile
                        required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: 54
                    radius: root.pal.rMd
                    color: root.pal.calm ? root.pal.fill : Qt.alpha(root.pal.surface, 0.8)
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.right: parent.right
                        spacing: 1
                        Row {
                            spacing: 6
                            Text { text: tile.modelData.v; color: tile.modelData.c; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                            Text { anchors.baseline: parent.children[0].baseline; text: tile.modelData.sub; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                        }
                        Text { text: tile.modelData.label; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                    }
                }
            }
        }

        // ---- bans | detections
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 26

            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: 4
                Text { text: root.pal.cap("BANS") + " (" + root.bans.length + ")"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                Text { visible: root.bans.length === 0; text: "nobody is banned"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                Repeater {
                    model: root.bans.slice(0, 4)
                    delegate: RowLayout {
                        id: banRow
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: banRow.modelData.ip; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 150; elide: Text.ElideRight }
                        Text { text: root.dur(banRow.modelData.remaining_secs); color: root.pal.accent2; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 48 }
                        Text { text: banRow.modelData.reason; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.fillWidth: true; elide: Text.ElideRight }
                        Text {
                            visible: banRow.modelData.source !== "config"
                            text: "unban"
                            color: unbanMa.containsMouse ? root.pal.accent : root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            MouseArea { id: unbanMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.consoleRequested("sudo ai-firewall unban " + String(banRow.modelData.ip).replace(/[^0-9a-fA-F:.\/]/g, "")) }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: 4
                Text { text: root.pal.cap("DETECTIONS"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                Text { visible: root.recent.length === 0; text: "all quiet"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                Repeater {
                    model: root.recent.slice(0, 4)
                    delegate: RowLayout {
                        id: hitRow
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: root.dur(Math.max(1, Math.round(Date.now() / 1000 - hitRow.modelData.at_unix))); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 40 }
                        Text { text: hitRow.modelData.ip; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 150; elide: Text.ElideRight }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: hitRow.modelData.reason + (hitRow.modelData.enforced ? "" : " (monitor)")
                            color: hitRow.modelData.enforced ? root.pal.bad : root.pal.warn
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                        }
                    }
                }
            }
        }

        // ---- actions (each opens a terminal; sudo asks for the password there)
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0565); label: "Firewall Center"; onClicked: Quickshell.execDetached(["quickshell", "-p", Quickshell.shellDir, "ipc", "call", "island", "firewallcenter"]) }
            ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0128); label: "Dashboard"; onClicked: root.inTerminal("sudo ai-firewall top") }
            ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0B79); label: "Ask"; onClicked: root.inTerminal("sudo ai-firewall top --ask") }
            ActionChip {
                pal: root.pal
                glyph: String.fromCodePoint(0xF0F8B)
                label: "Doctor"
                onClicked: root.consoleRequested("sudo ai-firewall doctor --fix")
            }
            Item { Layout.fillWidth: true }
            ActionChip {
                visible: root.st === null
                pal: root.pal
                label: "Start"
                onClicked: root.consoleRequested("sudo systemctl start ai-firewall")
            }
        }
    }
}
