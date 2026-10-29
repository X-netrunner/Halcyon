import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// A click on the Wi-Fi, Bluetooth or battery icon of ANY bar (island, notch, custom, rail) opens this small card next to the icon:
//   Wi-Fi       the networks in range: click one to join it (a password field asks when it needs one), On / Off, rescan
//   Bluetooth   paired and nearby devices: click one to connect / disconnect, On / Off, rescan
//   Battery     the charge, and the power mode: Battery saver / Balanced / Performance / Auto
// The three chips at the top switch between them, so the combined status icon (one round icon for all three) works too.
// Where the card appears follows the bar's edge: under a top bar, over a bottom bar, to the right of a left rail, to the left of a right one,
// always level with the icon that was clicked. The lists are the ones the utilities box uses (`hx wifi`, `hx bt`, scripts/wifi-connect.sh, scripts/bt-set.sh).
// Nothing runs while the card is closed (LazyLoader: no window, no process, no timer).
Scope {
    id: root
    property var pal
    property var net: ({})
    property var stats: ({})
    property string profile: "balanced"
    property bool autoPower: false
    property bool open: false
    property bool linger: false
    property string kind: "wifi"            // wifi | bt | battery
    property string side: "top"             // the bar's edge: top | bottom | left | right
    property real along: 0                  // where the icon is along that edge (x on a top / bottom bar, y on a left / right one), in screen px
    property real edge: 0                   // the bar's inner edge, in screen px (y of a top bar's bottom, x of a left rail's right side ...)

    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()

    function show(k, s, a, e) {
        var same = open && kind === k
        if (same) { hide(); return }
        kind = k; side = s || "top"; along = a || 0; edge = e || 0
        open = true
        refresh()
    }
    function hide() { open = false }
    function refresh() {
        if (kind === "wifi") { wifiProc.running = true; wifiAgain.restart() }
        else if (kind === "bt") { btProc.running = true; Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/bt-set.sh"), "scan"]) }
        else batProc.running = true
    }
    function pick(k) { if (kind === k) return; kind = k; askFor = ""; refresh() }
    onOpenChanged: {
        if (open) { linger = true; lingerT.stop() }
        else { linger = false; wifiLog = []; askFor = "" }
    }
    Timer { id: lingerT; interval: 300; onTriggered: root.linger = false }

    // ---- data
    property var wifi: ({ on: false, nets: [] })
    property var bt: ({ on: false, devs: [] })
    property int btBattery: -1
    property string askFor: ""
    readonly property string hx: Quickshell.env("HOME") + "/.config/Halcyon/bin/hx"
    Process { id: wifiProc; command: [root.hx, "wifi"]; stdout: StdioCollector { onStreamFinished: { try { root.wifi = JSON.parse(text) } catch (e) {} } } }
    Process { id: btProc; command: [root.hx, "bt"]; stdout: StdioCollector { onStreamFinished: { try { root.bt = JSON.parse(text) } catch (e) {} } } }
    Process {
        id: batProc
        command: ["bash", Quickshell.shellPath("scripts/bt-battery.sh")]
        stdout: StdioCollector { onStreamFinished: { var n = parseInt(text); root.btBattery = (isNaN(n) || n < 0 || n > 100) ? -1 : n } }
    }
    Timer { id: wifiAgain; interval: 3500; onTriggered: if (root.open && root.kind === "wifi") wifiProc.running = true }
    Timer { interval: 6000; repeat: true; running: root.open && root.kind === "wifi"; onTriggered: wifiProc.running = true }
    Timer { interval: 2500; repeat: true; running: root.open && root.kind === "bt"; onTriggered: btProc.running = true }
    Timer { id: soon; property string what: ""; interval: 1200; onTriggered: { if (what === "wifi") wifiProc.running = true; else if (what === "bt") btProc.running = true } }
    function later(what, ms) { soon.what = what; soon.interval = ms; soon.restart() }

    // Wi-Fi connecting: scripts/wifi-connect.sh prints "<level>|<seconds>|<text>" for each step
    property var wifiLog: []
    property string wifiLogSsid: ""
    readonly property bool wifiWorking: wifiConn.running
    function connectWifi(ssid, pw) {
        if (wifiConn.running) return
        wifiLog = []; wifiLogSsid = ssid
        wifiHideT.stop()
        wifiConn.command = ["bash", Quickshell.shellPath("scripts/wifi-connect.sh"), ssid].concat(pw ? [pw] : [])
        wifiConn.running = true
    }
    Process {
        id: wifiConn
        stdout: SplitParser {
            onRead: d => {
                var i = d.indexOf("|"), j = d.indexOf("|", i + 1)
                if (i < 0 || j < 0) return
                var l = root.wifiLog.slice()
                l.push({ lvl: d.substring(0, i), secs: d.substring(i + 1, j), text: d.substring(j + 1) })
                root.wifiLog = l
            }
        }
        onExited: code => { root.later("wifi", 600); if (code === 0) wifiHideT.restart() }
    }
    Timer { id: wifiHideT; interval: 9000; onTriggered: root.wifiLog = [] }

    readonly property var wifiItems: {
        var out = [], n = wifi.nets || []
        for (var i = 0; i < n.length; i++) {
            var s = n[i].signal
            var g = s > 75 ? 0xF0928 : (s > 50 ? 0xF0925 : (s > 25 ? 0xF0922 : 0xF091F))
            out.push({ title: n[i].ssid, glyph: String.fromCodePoint(g), active: n[i].active,
                       sub: n[i].active ? "Connected" : (n[i].saved ? "Saved" : (n[i].secure ? "Secured" : "Open")) + " · " + s + "%" })
        }
        return out
    }
    readonly property var btItems: {
        var out = [], d = bt.devs || []
        var glyphs = { "audio": 0xF02CB, "input-keyboard": 0xF0313, "input-mouse": 0xF037D, "phone": 0xF011C, "input-gaming": 0xF0297 }
        var hasPaired = false, hasFound = false
        for (var k = 0; k < d.length; k++) { if (d[k].paired) hasPaired = true; else hasFound = true }
        var h1 = false, h2 = false, batShown = false
        for (var i = 0; i < d.length; i++) {
            var it = d[i]
            if (hasFound && it.paired && !h1) { out.push({ section: "Paired" }); h1 = true }
            else if (hasPaired && !it.paired && !h2) { out.push({ section: "Available Nearby" }); h2 = true }
            var ic = String(it.icon || ""), g = 0xF00AF
            for (var key in glyphs) if (ic.indexOf(key) === 0) g = glyphs[key]
            var sub = it.connected ? "Connected" + ((!batShown && root.btBattery >= 0) ? "  \u00b7  " + root.btBattery + "%" : "") : (it.paired ? "Paired" : "Ready to pair")
            if (it.connected) batShown = true
            out.push({ title: it.name, sub: sub, glyph: String.fromCodePoint(g), active: it.connected, devIndex: i })
        }
        return out
    }

    readonly property var modes: [
        { id: "power-saver", label: "Battery saver", hint: "Quiet and cool, the longest battery life", glyph: 0xF0079 },
        { id: "balanced",    label: "Balanced",      hint: "The everyday mode",                         glyph: 0xF0A8F },
        { id: "performance", label: "Performance",   hint: "Full speed, uses more power",               glyph: 0xF04C5 },
        { id: "auto",        label: "Auto",          hint: "Halcyon picks one for you",                 glyph: 0xF0450 }
    ]
    readonly property string curMode: autoPower ? "auto" : profile

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-statuspop"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: (root.open && root.askFor !== "") ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            mask: Region { item: catcher }

            Item {
                id: catcher
                anchors.fill: parent
                focus: root.open
                Keys.onEscapePressed: root.hide()
                MouseArea { anchors.fill: parent; onClicked: root.hide() }

                Rectangle {
                    id: card
                    readonly property real gap: 8
                    width: 320
                    height: body.implicitHeight + 24
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.94)
                    border.width: 1
                    border.color: root.pal.lineSoft
                    // beside the bar, level with the icon, always inside the screen
                    x: {
                        if (root.side === "left") return root.edge + gap
                        if (root.side === "right") return catcher.width - root.edge - width - gap
                        return Math.max(gap, Math.min(catcher.width - width - gap, root.along - width / 2))
                    }
                    y: {
                        if (root.side === "top") return root.edge + gap
                        if (root.side === "bottom") return catcher.height - root.edge - height - gap
                        return Math.max(gap, Math.min(catcher.height - height - gap, root.along - height / 2))
                    }
                    // grows out of the bar: the side it opens from sets where it scales from
                    transformOrigin: root.side === "top" ? Item.Top : root.side === "bottom" ? Item.Bottom : root.side === "left" ? Item.Left : Item.Right
                    opacity: root.open ? 1 : 0
                    scale: root.open ? 1 : 0.94
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    Behavior on scale { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    MouseArea { anchors.fill: parent }          // clicks inside the card do not reach the catcher

                    ColumnLayout {
                        id: body
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Chip { Layout.fillWidth: true; pal: root.pal; implicitHeight: 30; padX: 8; glyph: String.fromCodePoint(0xF05A9); label: "Wi-Fi"; on: root.kind === "wifi"; onClicked: root.pick("wifi") }
                            Chip { Layout.fillWidth: true; pal: root.pal; implicitHeight: 30; padX: 8; glyph: String.fromCodePoint(0xF00AF); label: "Bluetooth"; on: root.kind === "bt"; onClicked: root.pick("bt") }
                            Chip { Layout.fillWidth: true; pal: root.pal; implicitHeight: 30; padX: 8; glyph: String.fromCodePoint(0xF0079); label: "Battery"; visible: root.stats.hasBat === true; on: root.kind === "battery"; onClicked: root.pick("battery") }
                        }

                        DeviceMenu {
                            id: wifiMenu
                            visible: root.kind === "wifi"
                            Layout.fillWidth: true
                            pal: root.pal
                            title: "Wi-Fi"
                            hasPower: true
                            powered: root.wifi.on === true
                            scanning: root.wifi.scanning === true
                            items: root.wifiItems
                            maxHeight: 260
                            emptyText: "No networks in range"
                            footer: "Network settings"
                            askFor: root.askFor
                            log: root.wifiLog
                            logBusy: root.wifiWorking
                            logTitle: root.wifiLogSsid
                            onLogDismissed: root.wifiLog = []
                            onPowerToggled: { root.toggleWifi(); root.later("wifi", 1500) }
                            onRescanClicked: wifiProc.running = true
                            onFooterClicked: { Quickshell.execDetached(["nm-connection-editor"]); root.hide() }
                            onPicked: i => {
                                var n = root.wifi.nets[i]
                                if (!n || n.active || root.wifiWorking) return
                                if (n.secure && !n.saved) { root.askFor = n.ssid; return }
                                root.connectWifi(n.ssid, "")
                            }
                            onPasswordSubmitted: pw => { if (root.wifiWorking) return; root.connectWifi(root.askFor, pw); root.askFor = "" }
                            onAskCancelled: root.askFor = ""
                        }

                        DeviceMenu {
                            visible: root.kind === "bt"
                            Layout.fillWidth: true
                            pal: root.pal
                            title: "Bluetooth"
                            hasPower: true
                            powered: root.bt.on === true
                            scanning: root.bt.scanning === true
                            items: root.btItems
                            maxHeight: 260
                            emptyText: root.bt.scanning ? "Searching for devices..." : (root.bt.on ? "No devices found" : "Bluetooth is off")
                            footer: "Bluetooth settings"
                            onPowerToggled: { root.toggleBt(); root.later("bt", 1500) }
                            onRescanClicked: { Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/bt-set.sh"), "scan"]); btProc.running = true; root.later("bt", 1500) }
                            onFooterClicked: { Quickshell.execDetached(["blueman-manager"]); root.hide() }
                            onPicked: i => {
                                var it = root.btItems[i]
                                if (!it || it.section) return
                                var d = root.bt.devs[it.devIndex !== undefined ? it.devIndex : i]
                                if (!d) return
                                Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/bt-set.sh"), d.connected ? "disconnect" : "connect", d.mac, d.name])
                                root.later("bt", 2500)
                            }
                        }

                        // ---- battery: the charge and the power mode
                        ColumnLayout {
                            visible: root.kind === "battery"
                            Layout.fillWidth: true
                            spacing: 6
                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: Math.round(Number(root.stats.bat || 0)) + "%"
                                    color: (root.stats.bat || 0) <= 20 && !root.stats.charging ? root.pal.bad : root.pal.text
                                    font.family: root.pal.uiFont; font.pixelSize: 22; font.weight: Font.DemiBold
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.stats.charging ? "Charging" : (root.stats.ac ? "Plugged in" : "On battery")
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                    elide: Text.ElideRight
                                }
                            }
                            Repeater {
                                model: root.modes
                                delegate: Rectangle {
                                    id: row
                                    required property var modelData
                                    readonly property bool cur: root.curMode === modelData.id
                                    Layout.fillWidth: true
                                    implicitHeight: 48
                                    radius: root.pal.rMd
                                    color: cur ? Qt.alpha(root.pal.accent, 0.18) : (ma.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.85) : Qt.alpha(root.pal.surface, 0.6))
                                    border.width: cur ? 1 : 0
                                    border.color: Qt.alpha(root.pal.accent, 0.4)
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                        spacing: 10
                                        Text { text: String.fromCodePoint(row.modelData.glyph); color: row.cur ? root.pal.accent : root.pal.muted; font.family: root.pal.font; font.pixelSize: 18 }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Text { Layout.fillWidth: true; text: row.modelData.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                            Text { Layout.fillWidth: true; text: row.modelData.hint; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; elide: Text.ElideRight }
                                        }
                                        Text { visible: row.cur; text: "●"; color: root.pal.accent; font.pixelSize: 11 }
                                    }
                                    MouseArea {
                                        id: ma
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { if (row.modelData.id === "auto") root.setAuto(); else root.setProfile(row.modelData.id) }
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
