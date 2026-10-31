import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Bottom-right utilities panel (wifi, bluetooth, audio, volume, mic, brightness, power mode; gear = Settings, gaming toggle, power button = PowerMenu).
// Wi-Fi / Bluetooth chips: click = radio on / off, right-click = the drawn list (scan, pick a network / device).
// Audio chip: click opens the list to pick from, right-click mutes. The lists come from `hx wifi`, `hx bt` and `hx audio`.
// Second row: Hotspot (scripts/hotspot.sh), Airplane (Wi-Fi and Bluetooth both off), Charge limit (scripts/charge-limit.sh, only on laptops
// that have one). The Bluetooth chip also shows the battery of the connected device when it reports one (scripts/bt-battery.sh).
// These small reads run only while the box is open.
Glass {
    id: root
    property var stats
    property var net
    property string profile: "balanced"
    property bool autoPower: false
    property bool autoHide: false
    property bool gaming: false
    property bool caffeine: false
    property var focusInfo: ({ on: false })  // the Focus session (shell.qml focusState); not called `focus`: that is an Item property
    property int focusSecs: 0                // seconds left in the running phase
    property string focusText: "00:00"       // time left in the running phase
    property int focusMins: 25               // length picked for the next session
    property bool focusPomo: false           // Pomodoro for the next session
    property int focusBlocked: 0             // how many apps are on the block list
    property bool focusOpen: false           // the Focus section is folded into one row; click it to open the picker / controls
    // flyout: the Focus controls open in their own card beside the box (shell.qml turns this on for the corner box, which has
    // room next to it) instead of unfolding inside it. flyLeft = the card sits to the left of the box, flyBottom = it lines up with
    // the box's bottom edge (else its top edge).
    property bool flyout: false
    property bool flyLeft: true
    property bool flyBottom: true
    readonly property bool flyHovered: focusFly.hovered
    readonly property bool flyShown: flyout && focusOpen && shown("Focus")
    readonly property real flyGap: focusFly.attached ? 0 : 8             // joined to the box: no gap
    readonly property real flyExtra: focusFly.width + 8                  // how much room the card needs beside the box
    property real mic: 0
    property bool micMuted: false
    property real vol: 0
    property bool muted: false
    property real bright: 0
    property bool active: false             // the corner is open (set by shell.qml)
    readonly property bool wantsKeys: wifiMenu.askFor !== ""   // the Wi-Fi password field needs the keyboard

    property string menu: ""                // "", "wifi", "bt", "audio" or "mic"
    property var wifi: ({ on: false, nets: [] })
    property var bt: ({ on: false, devs: [] })
    property var audio: ({ sinks: [], sources: [] })
    property int btBattery: -1              // battery % of the connected Bluetooth device, -1 = unknown
    property bool hotspotOn: false
    property int hotClients: 0              // devices connected to the hotspot (the Tiles style shows them as stars)
    // Settings > Behaviour > Utilities box > Layout: tiles (icon tiles with stars) | split (two tall sliders + round buttons) | classic (the old pills)
    readonly property string uStyle: cfg && (cfg.utilStyle === "split" || cfg.utilStyle === "classic") ? cfg.utilStyle : "tiles"
    readonly property bool classic: uStyle === "classic"
    readonly property bool tiles: uStyle === "tiles"
    readonly property bool split: uStyle === "split"
    readonly property bool btPercent: !!(cfg && cfg.utilBtShow === "percent")
    readonly property bool wifiLinked: net.wifi === "on" && !net.eth && (net.ssid || "") !== ""
    readonly property int wifiStars: Math.max(1, Math.min(5, Math.ceil((Number(net.signal) || 0) / 20)))
    readonly property int btStars: btBattery < 0 ? -1 : Math.max(1, Math.min(5, Math.ceil(btBattery / 20)))
    readonly property var powerModes: [
        { id: "auto", g: 0xF0674, tip: "Auto  ·  the power manager decides (load, battery, heat)" },
        { id: "power-saver", g: 0xF032A, tip: "Saver  ·  longest battery life" },
        { id: "balanced", g: 0xF05D1, tip: "Balanced" },
        { id: "performance", g: 0xF0241, tip: "Performance  ·  fastest, uses more power" }
    ]
    function modeOn(id) { return id === "auto" ? autoPower : profile === id }
    function modeSet(id) { if (id === "auto") setAuto(); else setProfile(id) }
    property var cfg: ({})                  // shell.qml opt: the uHide* switches (Settings > Behaviour > Utilities box: what to leave out of this box)
    function shown(id) { return !(cfg && cfg["uHide" + id] === true) }
    property int chargeLimit: 0             // 0 = this laptop has no charge limit, else the limit now (100 = full charge)
    readonly property bool airplaneOn: net.wifi !== "on" && net.bt !== "on"

    function toggleMenu(name) {
        wifiMenu.askFor = ""
        menu = menu === name ? "" : name
        if (menu === "wifi") {
            wifiProc.running = true
            wifiAgain.restart()
        } else if (menu === "bt") {
            btProc.running = true
            root.sh("bt-set.sh", ["scan"])
        } else if (menu === "audio" || menu === "mic") {
            audioProc.running = true
        }
    }
    onActiveChanged: {
        if (active) { audioProc.running = true; refreshExtras() }      // fills the Audio chip and the second row
        else { menu = ""; wifiMenu.askFor = ""; if (flyout) focusOpen = false }
    }
    function refreshExtras() {
        batProc.running = true
        hotProc.running = true
        chargeProc.running = true
        if (hotspotOn) clientProc.running = true
    }
    readonly property string btDevKey: net.btdev || ""
    onBtDevKeyChanged: { btBattery = -1; if (active) batProc.running = true }
    Process {
        id: batProc
        command: ["bash", Quickshell.shellPath("scripts/bt-battery.sh")]
        stdout: StdioCollector { onStreamFinished: { var n = parseInt(text); root.btBattery = (isNaN(n) || n < 0 || n > 100) ? -1 : n } }
    }
    Timer { interval: 30000; repeat: true; running: root.active && root.net.bt === "on"; onTriggered: batProc.running = true }
    Process {
        id: hotProc
        command: ["bash", "-c", "nmcli -t -f NAME connection show --active 2>/dev/null | grep -qxF Halcyon-Hotspot && echo 1 || echo 0"]
        stdout: StdioCollector { onStreamFinished: root.hotspotOn = text.trim() === "1" }
    }
    Timer { id: hotAgain; interval: 4000; onTriggered: hotProc.running = true }
    // how many devices are on the hotspot: iw's station list, or the neighbour table when iw is not installed
    Process {
        id: clientProc
        command: ["bash", "-c", "d=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2==\"wifi\"{print $1;exit}'); [ -n \"$d\" ] || { echo 0; exit; }; "
                 + "if command -v iw >/dev/null 2>&1; then iw dev \"$d\" station dump 2>/dev/null | grep -c '^Station'; "
                 + "else ip -4 neigh show dev \"$d\" 2>/dev/null | grep -Ec 'REACHABLE|STALE|DELAY'; fi"]
        stdout: StdioCollector { onStreamFinished: { var n = parseInt(text); root.hotClients = isNaN(n) ? 0 : Math.max(0, n) } }
    }
    Timer { interval: 8000; repeat: true; running: root.active && root.hotspotOn && !root.classic; onTriggered: clientProc.running = true }
    onHotspotOnChanged: { if (hotspotOn && active) clientProc.running = true; else hotClients = 0 }
    Process {
        id: chargeProc
        command: ["bash", Quickshell.shellPath("scripts/charge-limit.sh"), "status"]
        stdout: StdioCollector { onStreamFinished: { var n = parseInt(text); root.chargeLimit = isNaN(n) ? 0 : n } }
    }
    Timer { id: chargeAgain; interval: 900; onTriggered: chargeProc.running = true }

    function toggleHotspot() {
        // a failure (no adapter, Wi-Fi switched off ...) is told in a notification; the chip only lights up when it really is on
        Quickshell.execDetached(["bash", "-c", 'out=$(bash "$1" "$2" 2>&1) || notify-send -a Halcyon -i network-wireless "Hotspot" "$out"',
                                 "sh", Quickshell.env("HOME") + "/.config/Halcyon/scripts/hotspot.sh", hotspotOn ? "off" : "on"])
        hotAgain.interval = hotspotOn ? 4000 : 6000
        hotAgain.restart()
    }
    // Airplane: everything off, or (when both are already off) both back on
    function toggleAirplane() {
        if (airplaneOn) { toggleWifi(); toggleBt() }
        else { if (net.wifi === "on") toggleWifi(); if (net.bt === "on") toggleBt() }
    }
    function toggleChargeLimit() {
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/charge-limit.sh"), "toggle"])
        chargeAgain.restart()
    }

    Process {
        id: wifiProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "wifi"]
        stdout: StdioCollector { onStreamFinished: { try { root.wifi = JSON.parse(text) } catch (e) {} } }
    }
    Timer { id: wifiAgain; interval: 3500; onTriggered: if (root.menu === "wifi") wifiProc.running = true }
    Timer {
        id: wifiPoll
        interval: 6000
        repeat: true
        running: root.active && root.menu === "wifi"
        onTriggered: wifiProc.running = true
    }
    Process {
        id: btProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "bt"]
        stdout: StdioCollector { onStreamFinished: { try { root.bt = JSON.parse(text) } catch (e) {} } }
    }
    Timer {
        id: btPoll
        interval: 2500
        repeat: true
        running: root.active && root.menu === "bt"
        onTriggered: btProc.running = true
    }
    Process {
        id: audioProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "audio"]
        stdout: StdioCollector { onStreamFinished: { try { root.audio = JSON.parse(text) } catch (e) {} } }
    }
    // let nmcli / bluetoothctl / pactl finish, then re-read
    Timer { id: refreshSoon; property string what: ""; interval: 1200
        onTriggered: {
            if (what === "wifi") wifiProc.running = true
            else if (what === "bt") btProc.running = true
            else audioProc.running = true
        }
    }
    function later(what, ms) { refreshSoon.what = what; refreshSoon.interval = ms; refreshSoon.restart() }

    function sh(script, args) {
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/" + script)].concat(args))
    }

    // ---- Wi-Fi connecting, step by step. scripts/wifi-connect.sh prints "<level>|<seconds>|<text>" for every step it takes (finding the
    // network, authenticating, obtaining an IP, gateway, DNS, internet check); they are shown under the Wi-Fi list while it works.
    // Settings > Notifications > Wi-Fi details > "Show each connection step" (opt.wifiVerbose, on by default) switches the box off; the connection is the same either way.
    readonly property bool wifiVerbose: !(cfg && cfg.wifiVerbose === false)
    property var wifiLog: []
    property string wifiLogSsid: ""
    property bool wifiWorking: wifiConn.running
    function connectWifi(ssid, pw) {
        if (wifiConn.running) return
        wifiLog = []
        wifiLogSsid = ssid
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
        onExited: code => {
            root.later("wifi", 600)
            if (code === 0) wifiHideT.restart()         // a success folds away by itself; a failure stays until you close it or try again
        }
    }
    Timer { id: wifiHideT; interval: 9000; onTriggered: root.wifiLog = [] }

    readonly property var wifiItems: {
        var out = []
        var n = wifi.nets || []
        for (var i = 0; i < n.length; i++) {
            var s = n[i].signal
            var g = s > 75 ? 0xF0928 : (s > 50 ? 0xF0925 : (s > 25 ? 0xF0922 : 0xF091F))
            out.push({
                title: n[i].ssid,
                sub: n[i].active ? "Connected" : (n[i].saved ? "Saved" : (n[i].secure ? "Secured" : "Open")) + " · " + s + "%",
                glyph: String.fromCodePoint(g), active: n[i].active
            })
        }
        return out
    }
    readonly property var btItems: {
        var out = []
        var d = bt.devs || []
        var glyphs = { "audio": 0xF02CB, "input-keyboard": 0xF0313, "input-mouse": 0xF037D, "phone": 0xF011C, "input-gaming": 0xF0297 }
        var hasPaired = false, hasDiscovered = false
        for (var k = 0; k < d.length; k++) {
            if (d[k].paired) hasPaired = true
            else hasDiscovered = true
        }

        var pairedHeaderAdded = false, nearbyHeaderAdded = false, batShown = false    // the battery belongs to the first connected device
        for (var i = 0; i < d.length; i++) {
            var item = d[i]
            if (hasDiscovered && item.paired && !pairedHeaderAdded) {
                out.push({ section: "Paired" })
                pairedHeaderAdded = true
            } else if (hasPaired && !item.paired && !nearbyHeaderAdded) {
                out.push({ section: "Available Nearby" })
                nearbyHeaderAdded = true
            }
            var ic = String(item.icon || "")
            var g = 0xF00AF
            for (var key in glyphs) if (ic.indexOf(key) === 0) g = glyphs[key]
            var subText = item.connected ? "Connected" + ((!batShown && root.btBattery >= 0) ? "  \u00b7  " + root.btBattery + "%" : "") : (item.paired ? "Paired" : "Ready to pair")
            if (item.connected) batShown = true
            out.push({
                title: item.name,
                sub: subText,
                glyph: String.fromCodePoint(g),
                active: item.connected,
                devIndex: i
            })
        }
        return out
    }
    function audioGlyph(kind) {
        return String.fromCodePoint(kind === "bluetooth" ? 0xF00B0 : kind === "hdmi" ? 0xF0379
                                  : kind === "headphones" ? 0xF02CB : kind === "mic" ? 0xF036C : 0xF04C3)
    }
    readonly property var audioItems: {
        var out = []
        var s = audio.sinks || [], m = audio.sources || []
        if (s.length > 0) out.push({ section: "Output" })
        for (var i = 0; i < s.length; i++)
            out.push({ title: s[i].desc, sub: s[i].muted ? "Muted" : "", glyph: audioGlyph(s[i].kind), active: s[i].default, kind: "sink", name: s[i].name })
        if (m.length > 0) out.push({ section: "Input" })
        for (var j = 0; j < m.length; j++)
            out.push({ title: m[j].desc, sub: m[j].muted ? "Muted" : "", glyph: audioGlyph(m[j].kind), active: m[j].default, kind: "source", name: m[j].name })
        return out
    }
    // microphone picker: only the input devices
    readonly property var micItems: {
        var out = []
        var m = audio.sources || []
        for (var j = 0; j < m.length; j++)
            out.push({ title: m[j].desc, sub: m[j].muted ? "Muted" : "", glyph: audioGlyph(m[j].kind), active: m[j].default, kind: "source", name: m[j].name })
        return out
    }
    readonly property var defaultSource: {
        var m = audio.sources || []
        for (var i = 0; i < m.length; i++) if (m[i].default) return m[i]
        return null
    }
    readonly property var defaultSink: {
        var s = audio.sinks || []
        for (var i = 0; i < s.length; i++) if (s[i].default) return s[i]
        return null
    }

    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()
    signal openSettings()
    signal toggleGaming()
    signal toggleCaffeine()
    signal caffeineHour()
    signal focusStart(int mins, bool pomo)
    signal focusCommand(string what)         // stop | pause | resume | skip | add 5
    signal focusPick(int mins, bool pomo)    // remember the length / Pomodoro choice
    signal openFocusSettings()
    signal openApps()
    signal openPower()
    signal micMoved(real v)
    signal toggleMic()
    signal toggleMute()
    signal volumeMoved(real v)
    signal brightnessMoved(real v)
    property bool extraDim: false
    signal extraDimToggled()
    function toggleExtraDim() { extraDimToggled() }
    property bool isRecording: false
    signal toggleRecord()

    width: pal.boxW
    height: implicitHeight
    implicitHeight: col.implicitHeight + 2 * pad
    readonly property int pad: pal.boxPad
    radius: pal.rXl
    opacityBody: pal.glassSolid - 0.06

    // swallow clicks
    MouseArea { anchors.fill: parent }


    // the Focus card beside the box (see `flyout` above)
    FocusFlyout {
        id: focusFly
        pal: root.pal
        shown: root.flyShown
        toLeft: root.flyLeft
        atBottom: root.flyBottom
        joinV: root.joinV
        anchors.right: root.flyLeft ? parent.left : undefined
        anchors.left: root.flyLeft ? undefined : parent.right
        anchors.rightMargin: root.flyGap; anchors.leftMargin: root.flyGap
        // the card lines up with the box's edge; the pad around it (room for the flares) hangs over
        anchors.bottom: root.flyBottom ? parent.bottom : undefined
        anchors.top: root.flyBottom ? undefined : parent.top
        anchors.bottomMargin: -focusFly.pad; anchors.topMargin: -focusFly.pad
        focusInfo: root.focusInfo; focusSecs: root.focusSecs; focusText: root.focusText
        focusMins: root.focusMins; focusPomo: root.focusPomo; focusBlocked: root.focusBlocked
        onFocusStart: (m, p) => root.focusStart(m, p)
        onFocusCommand: w => root.focusCommand(w)
        onFocusPick: (m, p) => root.focusPick(m, p)
        onOpenFocusSettings: root.openFocusSettings()
    }

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.pad
        spacing: 12

        // connectivity: Wi-Fi / Bluetooth click = on / off, right-click = the list (scan and pick); Audio click = the list, right-click = mute
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            spacing: 8
            z: 3                    // above the rows below: the hover bubbles hang under the chips
            visible: root.classic && (root.shown("Wifi") || root.shown("Bt") || root.shown("Audio"))
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Wifi")
                pal: root.pal
                maxLabel: 52
                glyph: String.fromCodePoint(root.net.eth ? 0xF0200 : 0xF0928)
                label: ""                                    // calm: the icon alone (lit = on); the network name is in the hover bubble
                tipAlign: "left"
                tip: root.net.wifi !== "on" ? "Wi-Fi off  ·  click to turn on"
                   : (root.net.ssid ? "Connected to " + root.net.ssid : (root.net.eth ? "Ethernet" : "Wi-Fi on, not connected"))
                     + "  ·  right-click for networks"
                on: root.net.wifi === "on" || root.menu === "wifi"
                onClicked: { root.toggleWifi(); if (root.menu === "wifi") root.later("wifi", 1500) }
                onRightClicked: root.toggleMenu("wifi")
            }
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Bt")
                pal: root.pal
                maxLabel: 52
                glyph: String.fromCodePoint(0xF00AF)
                label: ""                                    // calm: the symbol alone (lit = on); device and battery are in the hover bubble
                tip: root.net.bt !== "on" ? "Bluetooth off  ·  click to turn on"
                   : (root.net.btdev ? root.net.btdev + (root.btBattery >= 0 ? "  ·  " + root.btBattery + "%" : "") : "Bluetooth on, no device")
                     + "  ·  right-click for devices"
                on: root.net.bt === "on" || root.menu === "bt"
                onClicked: { root.toggleBt(); if (root.menu === "bt") root.later("bt", 1500) }
                onRightClicked: root.toggleMenu("bt")
            }
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Audio")
                pal: root.pal
                maxLabel: 52
                glyph: root.audioGlyph(root.defaultSink ? root.defaultSink.kind : "speaker")
                label: ""                                    // calm: the icon alone; the speaker name is in the hover bubble
                tipAlign: "right"
                tip: (root.defaultSink ? root.defaultSink.desc : "Audio") + "  ·  click to choose, right-click to mute"
                on: root.menu === "audio"
                onClicked: root.toggleMenu("audio")
                onRightClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            }
        }

        // hotspot, airplane mode, charge limit (the last only on laptops that have one)
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            spacing: 8
            z: 2
            visible: root.classic && (root.shown("Hotspot") || root.shown("Airplane") || (root.chargeLimit > 0 && root.shown("Charge")))
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Hotspot")
                pal: root.pal
                maxLabel: 62
                glyph: String.fromCodePoint(0xF0003)
                label: ""
                tipAlign: "left"
                tip: root.hotspotOn ? "Hotspot on  ·  click to turn off" : "Hotspot off  ·  click to turn on"
                on: root.hotspotOn
                onClicked: root.toggleHotspot()
            }
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Airplane")
                pal: root.pal
                maxLabel: 62
                glyph: String.fromCodePoint(0xF001D)
                label: ""
                tip: root.airplaneOn ? "Airplane mode on  ·  click to bring Wi-Fi and Bluetooth back" : "Airplane mode  ·  switches Wi-Fi and Bluetooth off"
                on: root.airplaneOn
                onClicked: root.toggleAirplane()
            }
            Chip {
                Layout.fillWidth: true
                visible: root.chargeLimit > 0 && root.shown("Charge")
                pal: root.pal
                maxLabel: 90                     // "Limit 80%" is wider than the 62 px the other tiles use (it was cut to "Limit 80...")
                padX: 12
                glyph: String.fromCodePoint(0xF0079)
                label: ""
                tipAlign: "right"
                tip: root.chargeLimit > 0 && root.chargeLimit < 100 ? "Charge limit " + root.chargeLimit + "%  ·  protects the battery, click for full charge"
                                                                   : "Full charge  ·  click to limit charging and protect the battery"
                on: root.chargeLimit > 0 && root.chargeLimit < 100
                onClicked: root.toggleChargeLimit()
            }
        }

        // ===== style "Tiles": icon tiles; a connected network shows its signal as stars, Bluetooth its battery, the hotspot its devices
        GridLayout {
            HoverRaise {}
            Layout.fillWidth: true
            visible: root.tiles
            columns: 3
            columnSpacing: 8
            rowSpacing: 8
            z: 3
            UTile {
                Layout.fillWidth: true; Layout.preferredHeight: 64
                visible: root.shown("Wifi")
                pal: root.pal
                glyph: String.fromCodePoint(root.net.eth ? 0xF0200 : 0xF0928)
                stars: root.wifiLinked ? root.wifiStars : -1
                caption: root.net.wifi !== "on" && !root.net.eth ? "Off" : (root.net.eth ? "Wired" : "Wi-Fi")
                tipAlign: "left"
                tip: root.net.wifi !== "on" ? "Wi-Fi off  ·  click to turn on"
                   : (root.net.ssid ? "Connected to " + root.net.ssid + "  ·  signal " + Math.round(Number(root.net.signal) || 0) + "%" : (root.net.eth ? "Ethernet" : "Wi-Fi on, not connected"))
                     + "  ·  right-click for networks"
                on: root.net.wifi === "on" || root.menu === "wifi"
                onClicked: { root.toggleWifi(); if (root.menu === "wifi") root.later("wifi", 1500) }
                onRightClicked: root.toggleMenu("wifi")
            }
            UTile {
                Layout.fillWidth: true; Layout.preferredHeight: 64
                visible: root.shown("Bt")
                pal: root.pal
                glyph: String.fromCodePoint(0xF00AF)
                readonly property bool linked: root.net.bt === "on" && !!root.net.btdev
                stars: linked && !root.btPercent ? root.btStars : -1
                caption: root.net.bt !== "on" ? "Off" : (!root.net.btdev ? "Bluetooth" : (root.btBattery >= 0 ? root.btBattery + "%" : "Connected"))
                tip: root.net.bt !== "on" ? "Bluetooth off  ·  click to turn on"
                   : (root.net.btdev ? root.net.btdev + (root.btBattery >= 0 ? "  ·  battery " + root.btBattery + "%" : "") : "Bluetooth on, no device")
                     + "  ·  right-click for devices"
                on: root.net.bt === "on" || root.menu === "bt"
                onClicked: { root.toggleBt(); if (root.menu === "bt") root.later("bt", 1500) }
                onRightClicked: root.toggleMenu("bt")
            }
            UTile {
                Layout.fillWidth: true; Layout.preferredHeight: 64
                visible: root.shown("Audio")
                pal: root.pal
                glyph: root.audioGlyph(root.defaultSink ? root.defaultSink.kind : "speaker")
                caption: root.muted ? "Muted" : Math.round(root.vol) + "%"
                tipAlign: "right"
                tip: (root.defaultSink ? root.defaultSink.desc : "Audio") + "  ·  click to choose, right-click to mute"
                on: root.menu === "audio"
                onClicked: root.toggleMenu("audio")
                onRightClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            }
            UTile {
                Layout.fillWidth: true; Layout.preferredHeight: 64
                visible: root.shown("Hotspot")
                pal: root.pal
                glyph: String.fromCodePoint(0xF0003)
                stars: root.hotspotOn ? Math.min(5, root.hotClients) : -1
                caption: "Off"
                tipAlign: "left"
                tip: root.hotspotOn ? "Hotspot on  ·  " + root.hotClients + (root.hotClients === 1 ? " device" : " devices") + " connected  ·  click to turn off" : "Hotspot off  ·  click to turn on"
                on: root.hotspotOn
                onClicked: root.toggleHotspot()
            }
            UTile {
                Layout.fillWidth: true; Layout.preferredHeight: 64
                visible: root.shown("Airplane")
                pal: root.pal
                glyph: String.fromCodePoint(0xF001D)
                caption: "Airplane"
                tip: root.airplaneOn ? "Airplane mode on  ·  click to bring Wi-Fi and Bluetooth back" : "Airplane mode  ·  switches Wi-Fi and Bluetooth off"
                on: root.airplaneOn
                onClicked: root.toggleAirplane()
            }
            UTile {
                Layout.fillWidth: true; Layout.preferredHeight: 64
                visible: root.chargeLimit > 0 && root.shown("Charge")
                pal: root.pal
                glyph: String.fromCodePoint(0xF0079)
                caption: root.chargeLimit > 0 && root.chargeLimit < 100 ? root.chargeLimit + "%" : "Full"
                tipAlign: "right"
                tip: root.chargeLimit > 0 && root.chargeLimit < 100 ? "Charge limit " + root.chargeLimit + "%  ·  protects the battery, click for full charge"
                                                                   : "Full charge  ·  click to limit charging and protect the battery"
                on: root.chargeLimit > 0 && root.chargeLimit < 100
                onClicked: root.toggleChargeLimit()
            }
        }

        // ===== style "Split": two tall sliders (volume, brightness) beside round buttons and the four power modes
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            visible: root.split
            spacing: 12
            z: 3
            RowLayout {
                spacing: 8
                VBar {
                    visible: root.shown("Volume")
                    Layout.preferredWidth: 52; Layout.preferredHeight: 176
                    pal: root.pal
                    glyph: String.fromCodePoint(root.muted ? 0xF0581 : 0xF057E)
                    value: root.vol / 100
                    dimmed: root.muted
                    onMoved: v => root.volumeMoved(v)
                    onGlyphClicked: root.toggleMute()
                }
                VBar {
                    visible: root.shown("Bright")
                    Layout.preferredWidth: 52; Layout.preferredHeight: 176
                    pal: root.pal
                    glyph: String.fromCodePoint(root.extraDim ? 0xF058F : 0xF00DF)
                    value: root.bright / 100
                    dimmed: root.extraDim
                    onMoved: v => root.brightnessMoved(v)
                    onGlyphClicked: root.toggleExtraDim()
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 176
                spacing: 10
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: 6
                    rowSpacing: 8
                    Chip {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignHCenter
                        visible: root.shown("Wifi"); pal: root.pal; padX: 0; label: ""
                        glyph: String.fromCodePoint(root.net.eth ? 0xF0200 : 0xF0928)
                        tipAlign: "left"
                        tip: root.net.wifi !== "on" ? "Wi-Fi off  ·  click to turn on"
                           : (root.net.ssid ? "Connected to " + root.net.ssid : (root.net.eth ? "Ethernet" : "Wi-Fi on, not connected")) + "  ·  right-click for networks"
                        on: root.net.wifi === "on" || root.menu === "wifi"
                        onClicked: { root.toggleWifi(); if (root.menu === "wifi") root.later("wifi", 1500) }
                        onRightClicked: root.toggleMenu("wifi")
                    }
                    Chip {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignHCenter
                        visible: root.shown("Bt"); pal: root.pal; padX: 0; label: ""
                        glyph: String.fromCodePoint(0xF00AF)
                        tip: root.net.bt !== "on" ? "Bluetooth off  ·  click to turn on"
                           : (root.net.btdev ? root.net.btdev + (root.btBattery >= 0 ? "  ·  " + root.btBattery + "%" : "") : "Bluetooth on, no device") + "  ·  right-click for devices"
                        on: root.net.bt === "on" || root.menu === "bt"
                        onClicked: { root.toggleBt(); if (root.menu === "bt") root.later("bt", 1500) }
                        onRightClicked: root.toggleMenu("bt")
                    }
                    Chip {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignHCenter
                        visible: root.shown("Audio"); pal: root.pal; padX: 0; label: ""
                        glyph: root.audioGlyph(root.defaultSink ? root.defaultSink.kind : "speaker")
                        tipAlign: "right"
                        tip: (root.defaultSink ? root.defaultSink.desc : "Audio") + "  ·  click to choose, right-click to mute"
                        on: root.menu === "audio"
                        onClicked: root.toggleMenu("audio")
                        onRightClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
                    }
                    Chip {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignHCenter
                        visible: root.shown("Hotspot"); pal: root.pal; padX: 0; label: ""
                        glyph: String.fromCodePoint(0xF0003)
                        tipAlign: "left"
                        tip: root.hotspotOn ? "Hotspot on  ·  " + root.hotClients + " connected  ·  click to turn off" : "Hotspot off  ·  click to turn on"
                        on: root.hotspotOn
                        onClicked: root.toggleHotspot()
                    }
                    Chip {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignHCenter
                        visible: root.shown("Airplane"); pal: root.pal; padX: 0; label: ""
                        glyph: String.fromCodePoint(0xF001D)
                        tip: root.airplaneOn ? "Airplane mode on  ·  click to bring Wi-Fi and Bluetooth back" : "Airplane mode  ·  switches Wi-Fi and Bluetooth off"
                        on: root.airplaneOn
                        onClicked: root.toggleAirplane()
                    }
                    Chip {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignHCenter
                        visible: root.shown("Mic"); pal: root.pal; padX: 0; label: ""
                        glyph: String.fromCodePoint(root.micMuted ? 0xF036D : 0xF036C)
                        tipAlign: "right"
                        tip: (root.micMuted ? "Microphone muted" : (root.defaultSource ? root.defaultSource.desc : "Microphone")) + "  ·  click to mute, right-click to choose"
                        on: !root.micMuted
                        onClicked: root.toggleMic()
                        onRightClicked: root.toggleMenu("mic")
                    }
                }
                Item { Layout.fillHeight: true }
                GridLayout {
                    Layout.fillWidth: true
                    visible: root.shown("Power")
                    columns: 2
                    columnSpacing: 6
                    rowSpacing: 6
                    Repeater {
                        model: root.powerModes
                        delegate: Chip {
                            required property var modelData
                            Layout.fillWidth: true; Layout.preferredHeight: 34
                            pal: root.pal; label: ""; padX: 0
                            glyph: String.fromCodePoint(modelData.g)
                            tip: modelData.tip; tipAlign: "right"
                            on: root.modeOn(modelData.id)
                            onClicked: root.modeSet(modelData.id)
                        }
                    }
                }
            }
        }

        DeviceMenu {
            id: wifiMenu
            visible: root.menu === "wifi"
            Layout.fillWidth: true
            pal: root.pal
            title: "Wi-Fi"
            hasPower: true
            powered: root.wifi.on === true
            scanning: root.wifi.scanning === true
            items: root.wifiItems
            emptyText: "No networks in range"
            footer: "Network settings"
            onPowerToggled: { root.toggleWifi(); root.later("wifi", 1500) }
            onRescanClicked: { wifiProc.running = true }
            onFooterClicked: Quickshell.execDetached(["nm-connection-editor"])
            log: root.wifiVerbose ? root.wifiLog : []
            logBusy: root.wifiWorking
            logTitle: root.wifiLogSsid
            onLogDismissed: root.wifiLog = []
            onPicked: i => {
                var n = root.wifi.nets[i]
                if (n.active || root.wifiWorking) return
                if (n.secure && !n.saved) { askFor = n.ssid; return }
                root.connectWifi(n.ssid, "")
            }
            onPasswordSubmitted: pw => {
                if (root.wifiWorking) return
                root.connectWifi(askFor, pw)
                askFor = ""
            }
            onAskCancelled: askFor = ""
        }
        DeviceMenu {
            visible: root.menu === "bt"
            Layout.fillWidth: true
            pal: root.pal
            title: "Bluetooth"
            hasPower: true
            powered: root.bt.on === true
            scanning: root.bt.scanning === true
            items: root.btItems
            emptyText: root.bt.scanning ? "Searching for devices..." : (root.bt.on ? "No devices found" : "Bluetooth is off")
            footer: "Bluetooth settings"
            onPowerToggled: { root.toggleBt(); root.later("bt", 1500) }
            onRescanClicked: { root.sh("bt-set.sh", ["scan"]); btProc.running = true; root.later("bt", 1500) }
            onFooterClicked: Quickshell.execDetached(["blueman-manager"])
            onPicked: i => {
                var it = root.btItems[i]
                if (!it || it.section) return
                var devIdx = (it.devIndex !== undefined) ? it.devIndex : i
                var d = root.bt.devs[devIdx]
                if (!d) return
                root.sh("bt-set.sh", [d.connected ? "disconnect" : "connect", d.mac, d.name])
                root.later("bt", 2500)
            }
        }
        DeviceMenu {
            visible: root.menu === "audio"
            Layout.fillWidth: true
            pal: root.pal
            title: "Sound"
            items: root.audioItems
            emptyText: "No audio devices (is pactl installed?)"
            footer: "Volume mixer"
            onFooterClicked: Quickshell.execDetached(["pavucontrol"])
            onPicked: i => {
                var it = root.audioItems[i]
                root.sh("audio-set.sh", [it.kind, it.name])
                root.later("audio", 500)
            }
        }

        // microphone: pick the input device (round button = mute / unmute, right-click the chip = mute too)
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            spacing: 8
            z: 1
            visible: root.classic && root.shown("Mic")
            RoundBtn {
                pal: root.pal
                size: 36
                glyph: String.fromCodePoint(root.micMuted ? 0xF036D : 0xF036C)
                opacity: root.micMuted ? 0.55 : 1
                onClicked: root.toggleMic()
            }
            Chip {
                Layout.fillWidth: true
                pal: root.pal
                maxLabel: 230
                glyph: String.fromCodePoint(0xF0140)
                label: ""
                tip: (root.defaultSource ? root.defaultSource.desc : "Microphone") + "  ·  click to choose, right-click to mute"
                on: root.menu === "mic"
                onClicked: root.toggleMenu("mic")
                onRightClicked: root.toggleMic()
            }
        }
        DeviceMenu {
            visible: root.menu === "mic"
            Layout.fillWidth: true
            pal: root.pal
            title: "Microphone"
            items: root.micItems
            emptyText: "No input devices (is pactl installed?)"
            footer: "Volume mixer"
            onFooterClicked: Quickshell.execDetached(["pavucontrol"])
            onPicked: i => {
                var it = root.micItems[i]
                root.sh("audio-set.sh", [it.kind, it.name])
                root.later("audio", 500)
            }
        }

        // volume + brightness (Tiles: the mic button sits at the end of the volume line)
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            visible: root.tiles && (root.shown("Volume") || root.shown("Mic"))
            spacing: 8
            Slider {
                Layout.fillWidth: true
                visible: root.shown("Volume")
                pal: root.pal
                glyph: String.fromCodePoint(root.muted ? 0xF0581 : 0xF057E)
                value: root.vol / 100
                dimmed: root.muted
                onMoved: v => root.volumeMoved(v)
                onGlyphClicked: root.toggleMute()
            }
            Chip {
                Layout.preferredWidth: 36; Layout.preferredHeight: 36
                visible: root.shown("Mic"); pal: root.pal; padX: 0; label: ""
                glyph: String.fromCodePoint(root.micMuted ? 0xF036D : 0xF036C)
                tipAlign: "right"
                tip: (root.micMuted ? "Microphone muted" : (root.defaultSource ? root.defaultSource.desc : "Microphone")) + "  ·  click to mute, right-click to choose"
                on: !root.micMuted
                onClicked: root.toggleMic()
                onRightClicked: root.toggleMenu("mic")
            }
        }
        Slider {
            Layout.fillWidth: true
            visible: root.classic && root.shown("Volume")
            pal: root.pal
            glyph: String.fromCodePoint(root.muted ? 0xF0581 : 0xF057E)
            value: root.vol / 100
            dimmed: root.muted
            onMoved: v => root.volumeMoved(v)
            onGlyphClicked: root.toggleMute()
        }
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            spacing: 8
            visible: !root.split && (root.shown("Bright") || root.shown("ExtraDim"))
            Slider {
                Layout.fillWidth: true
                visible: root.shown("Bright")
                pal: root.pal
                glyph: String.fromCodePoint(root.extraDim ? 0xF058F : 0xF00DF)
                value: root.bright / 100
                dimmed: root.extraDim
                onMoved: v => root.brightnessMoved(v)
                onGlyphClicked: root.toggleExtraDim()
            }
            Chip {
                Layout.preferredHeight: 30
                Layout.fillWidth: !root.shown("Bright")
                visible: root.shown("ExtraDim")
                pal: root.pal
                label: root.classic ? "Extra dim" : ""
                tip: "Extra dim  ·  dims the screen below its lowest brightness"
                glyph: String.fromCodePoint(0xF058F)
                on: root.extraDim
                onClicked: root.toggleExtraDim()
            }
        }

        // power mode
        Text { visible: root.classic && root.shown("Power"); text: root.pal.cap("POWER MODE"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.calm ? 12 : 10; font.weight: Font.DemiBold; font.letterSpacing: root.pal.calm ? 0.2 : 1.4; Layout.topMargin: 10 }
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            spacing: 8
            visible: root.classic && root.shown("Power")
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Auto"; on: root.autoPower; onClicked: root.setAuto() }
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Saver"; on: root.profile === "power-saver"; onClicked: root.setProfile("power-saver") }
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Balanced"; on: root.profile === "balanced"; onClicked: root.setProfile("balanced") }
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Perf"; on: root.profile === "performance"; onClicked: root.setProfile("performance") }
        }

        // power mode as four icons (Tiles); Split has them inside its block. The words are in the hover bubble.
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            visible: root.tiles && root.shown("Power")
            spacing: 8
            Repeater {
                model: root.powerModes
                delegate: Chip {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true; Layout.preferredHeight: 38
                    pal: root.pal; label: ""; padX: 0
                    glyph: String.fromCodePoint(modelData.g)
                    tip: modelData.tip; tipAlign: index === 0 ? "left" : (index === 3 ? "right" : "center")
                    on: root.modeOn(modelData.id)
                    onClicked: root.modeSet(modelData.id)
                }
            }
        }

        // two rows (Tiles and Split), so nothing is cramped: the switches as icons (caffeine, record, focus, gaming), then the
        // places you open, with their names (settings, power)
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            Layout.topMargin: 6
            visible: !root.classic
            spacing: 8
            z: 2
            Chip { Layout.fillWidth: true; Layout.preferredHeight: 40; visible: root.shown("Caffeine"); pal: root.pal; padX: 0; label: ""; glyph: String.fromCodePoint(0xF0176)
                tipAlign: "left"; tip: root.caffeine ? "Caffeine on  ·  click to turn off" : "Caffeine  ·  keeps the screen awake  ·  right-click for one hour"
                on: root.caffeine; onClicked: root.toggleCaffeine(); onRightClicked: root.caffeineHour() }
            Chip { Layout.fillWidth: true; Layout.preferredHeight: 40; visible: root.shown("Record"); pal: root.pal; padX: 0; label: ""; glyph: String.fromCodePoint(0xF0481)
                tip: root.isRecording ? "Recording  ·  click to stop" : "Record the screen"
                on: root.isRecording; onClicked: root.toggleRecord() }
            Chip { Layout.fillWidth: true; Layout.preferredHeight: 40; visible: root.shown("Focus"); pal: root.pal; padX: 0; label: ""; glyph: String.fromCodePoint(0xF051B)
                tip: root.focusInfo.on ? "Focus  ·  " + root.focusText : "Focus  ·  a timer with do-not-disturb"
                on: root.focusInfo.on || root.focusOpen; onClicked: root.focusOpen = !root.focusOpen }
            Chip { Layout.fillWidth: true; Layout.preferredHeight: 40; pal: root.pal; padX: 0; label: ""; glyph: String.fromCodePoint(0xF0297)
                tipAlign: "right"; tip: root.gaming ? "Gaming mode on  ·  click to turn off" : "Gaming mode"
                on: root.gaming; onClicked: root.toggleGaming() }
        }
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            visible: !root.classic
            spacing: 8
            z: 2
            Chip { Layout.fillWidth: true; Layout.preferredHeight: 36; pal: root.pal; glyph: String.fromCodePoint(0xF0493); label: "Settings"
                tip: "Settings"; onClicked: root.openSettings() }
            Chip { Layout.fillWidth: true; Layout.preferredHeight: 36; pal: root.pal; primary: true; glyph: String.fromCodePoint(0xF0425); label: "Power"
                tipAlign: "right"; tip: "Lock, log out, restart, shut down"; onClicked: root.openPower() }
        }

        // caffeine (click = on / off, right-click = on for one hour) and record
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            Layout.topMargin: 10
            spacing: 8
            visible: root.classic && (root.shown("Caffeine") || root.shown("Record"))
            Chip {
                Layout.fillWidth: true; pal: root.pal
                visible: root.shown("Caffeine")
                glyph: String.fromCodePoint(0xF0176)
                label: root.caffeine ? "Caffeine on" : "Caffeine"
                on: root.caffeine
                onClicked: root.toggleCaffeine()
                onRightClicked: root.caffeineHour()
            }
            Chip {
                Layout.fillWidth: true; pal: root.pal
                visible: root.shown("Record")
                glyph: String.fromCodePoint(0xF0481)
                label: root.isRecording ? "Recording..." : "Record"
                on: root.isRecording
                onClicked: root.toggleRecord()
            }
        }

        // focus mode: a timer + do-not-disturb + closing the apps on the block list (scripts/focus.sh)
        // One row while folded: "Focus", or the countdown while a session runs. Click it to open / fold the rest.
        Chip {
            Layout.fillWidth: true
            Layout.topMargin: 10
            visible: root.shown("Focus") && (root.classic || root.focusInfo.on)
            pal: root.pal
            glyph: String.fromCodePoint(0xF051B)
            label: (root.focusInfo.on
                    ? root.focusText + "  ·  " + (root.focusInfo.paused ? "Paused" : (root.focusInfo.phase === "work" ? "Focusing" : "Break"))
                    : "Focus") + (root.flyout ? ((root.flyLeft === !root.focusOpen) ? "   \u25C2" : "   \u25B8")
                                 : (root.focusOpen ? "   \u25B4" : "   \u25BE"))
            on: root.focusInfo.on || root.focusOpen
            onClicked: root.focusOpen = !root.focusOpen
        }

        // the Focus controls, folded into the box (when they do not open beside it)
        FocusBody {
            Layout.fillWidth: true
            visible: root.shown("Focus") && root.focusOpen && !root.flyout
            pal: root.pal
            focusInfo: root.focusInfo; focusSecs: root.focusSecs; focusText: root.focusText
            focusMins: root.focusMins; focusPomo: root.focusPomo; focusBlocked: root.focusBlocked
            onFocusStart: (m, p) => root.focusStart(m, p)
            onFocusCommand: w => root.focusCommand(w)
            onFocusPick: (m, p) => root.focusPick(m, p)
            onOpenFocusSettings: root.openFocusSettings()
        }


        // one quiet row: settings gear, gaming mode, power button (classic style; the others have these in their icon row)
        RowLayout {
            HoverRaise {}
            Layout.fillWidth: true
            visible: root.classic
            Layout.topMargin: 10
            spacing: 8
            Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0493); label: "Settings"; onClicked: root.openSettings() }
            Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0297); label: root.gaming ? "Gaming on" : "Gaming"; on: root.gaming; onClicked: root.toggleGaming() }
            RoundBtn { pal: root.pal; glyph: String.fromCodePoint(0xF0425); primary: true; size: 36; onClicked: root.openPower() }
        }
    }
}
