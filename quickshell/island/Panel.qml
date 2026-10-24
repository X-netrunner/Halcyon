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
        else { menu = ""; wifiMenu.askFor = "" }
    }
    function refreshExtras() {
        batProc.running = true
        hotProc.running = true
        chargeProc.running = true
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


    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.pad
        spacing: 12

        // connectivity: Wi-Fi / Bluetooth click = on / off, right-click = the list (scan and pick); Audio click = the list, right-click = mute
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.shown("Wifi") || root.shown("Bt") || root.shown("Audio")
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Wifi")
                pal: root.pal
                maxLabel: 52
                glyph: String.fromCodePoint(root.net.eth ? 0xF0200 : 0xF0928)
                label: root.net.wifi === "on" ? (root.net.ssid || (root.net.eth ? "Ethernet" : "On")) : "Wi-Fi off"
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
                label: root.net.bt === "on" ? (root.net.btdev ? (root.btBattery >= 0 ? root.btBattery + "%  " : "") + root.net.btdev : "On") : "BT off"
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
                label: root.defaultSink ? root.defaultSink.desc : "Audio"
                on: root.menu === "audio"
                onClicked: root.toggleMenu("audio")
                onRightClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            }
        }

        // hotspot, airplane mode, charge limit (the last only on laptops that have one)
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.shown("Hotspot") || root.shown("Airplane") || (root.chargeLimit > 0 && root.shown("Charge"))
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Hotspot")
                pal: root.pal
                maxLabel: 62
                glyph: String.fromCodePoint(0xF0003)
                label: "Hotspot"
                on: root.hotspotOn
                onClicked: root.toggleHotspot()
            }
            Chip {
                Layout.fillWidth: true
                visible: root.shown("Airplane")
                pal: root.pal
                maxLabel: 62
                glyph: String.fromCodePoint(0xF001D)
                label: "Airplane"
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
                label: root.chargeLimit > 0 && root.chargeLimit < 100 ? "Limit " + root.chargeLimit + "%" : "Charge"
                on: root.chargeLimit > 0 && root.chargeLimit < 100
                onClicked: root.toggleChargeLimit()
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
            onPicked: i => {
                var n = root.wifi.nets[i]
                if (n.active) return
                if (n.secure && !n.saved) { askFor = n.ssid; return }
                root.sh("wifi-connect.sh", [n.ssid])
                root.later("wifi", 3500)
            }
            onPasswordSubmitted: pw => {
                root.sh("wifi-connect.sh", [askFor, pw])
                askFor = ""
                root.later("wifi", 5000)
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
            Layout.fillWidth: true
            spacing: 8
            visible: root.shown("Mic")
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
                label: root.defaultSource ? root.defaultSource.desc : "Microphone"
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

        // volume + brightness
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
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.shown("Bright") || root.shown("ExtraDim")
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
                label: "Extra dim"
                glyph: String.fromCodePoint(0xF058F)
                on: root.extraDim
                onClicked: root.toggleExtraDim()
            }
        }

        // power mode
        Text { text: root.pal.cap("POWER MODE"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.calm ? 12 : 10; font.weight: Font.DemiBold; font.letterSpacing: root.pal.calm ? 0.2 : 1.4; Layout.topMargin: 10; visible: root.shown("Power") }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.shown("Power")
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Auto"; on: root.autoPower; onClicked: root.setAuto() }
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Saver"; on: root.profile === "power-saver"; onClicked: root.setProfile("power-saver") }
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Balanced"; on: root.profile === "balanced"; onClicked: root.setProfile("balanced") }
            Chip { Layout.fillWidth: true; pal: root.pal; label: "Perf"; on: root.profile === "performance"; onClicked: root.setProfile("performance") }
        }

        // caffeine (click = on / off, right-click = on for one hour) and the background-apps box (bottom-left corner)
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 10
            spacing: 8
            visible: root.shown("Caffeine") || root.shown("Record") || root.shown("Apps")
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
            Chip { Layout.fillWidth: true; visible: root.shown("Apps"); pal: root.pal; glyph: String.fromCodePoint(0xF003B); label: "Apps"; onClicked: root.openApps() }
        }

        // focus mode: a timer + do-not-disturb + closing the apps on the block list (scripts/focus.sh)
        // One row while folded: "Focus", or the countdown while a session runs. Click it to open / fold the rest.
        Chip {
            Layout.fillWidth: true
            Layout.topMargin: 10
            visible: root.shown("Focus")
            pal: root.pal
            glyph: String.fromCodePoint(0xF051B)
            label: (root.focusInfo.on
                    ? root.focusText + "  ·  " + (root.focusInfo.paused ? "Paused" : (root.focusInfo.phase === "work" ? "Focusing" : "Break"))
                    : "Focus") + (root.focusOpen ? "   \u25B4" : "   \u25BE")
            on: root.focusInfo.on || root.focusOpen
            onClicked: root.focusOpen = !root.focusOpen
        }

        // idle: pick a length, then start
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.shown("Focus") && !root.focusInfo.on && root.focusOpen
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: [25, 50, 90]
                    delegate: Chip {
                        required property int modelData
                        Layout.fillWidth: true; pal: root.pal
                        label: modelData + "m"
                        on: root.focusMins === modelData
                        onClicked: root.focusPick(modelData, root.focusPomo)
                    }
                }
                Chip {
                    Layout.fillWidth: true; pal: root.pal
                    label: "Pomodoro"
                    on: root.focusPomo
                    onClicked: root.focusPick(root.focusMins, !root.focusPomo)
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Chip {
                    Layout.fillWidth: true; pal: root.pal
                    glyph: String.fromCodePoint(0xF040A)
                    label: "Start focus"
                    onClicked: root.focusStart(root.focusMins, root.focusPomo)
                }
                Chip {
                    Layout.fillWidth: true; pal: root.pal
                    glyph: String.fromCodePoint(0xF009E)
                    label: root.focusBlocked > 0 ? "Blocked apps · " + root.focusBlocked : "Block apps"
                    onClicked: root.openFocusSettings()
                }
            }
        }

        // running: a countdown card with the phase, a progress line and the controls
        Rectangle {
            Layout.fillWidth: true
            visible: root.shown("Focus") && root.focusInfo.on && root.focusOpen
            implicitHeight: runCol.implicitHeight + 24
            radius: root.pal.rLg
            color: Qt.alpha(root.pal.accent, 0.10)
            border.width: root.pal.bw
            border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)

            ColumnLayout {
                id: runCol
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: 12
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: root.focusText
                        color: root.pal.text
                        font.family: root.pal.uiFont; font.pixelSize: 30; font.weight: Font.DemiBold
                        opacity: root.focusInfo.paused ? 0.55 : 1
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: root.focusInfo.paused ? "Paused" : (root.focusInfo.phase === "work" ? "Focusing" : (root.focusInfo.phase === "long" ? "Long break" : "Break"))
                            color: root.pal.accent
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: (root.focusInfo.pomodoro ? "Round " + root.focusInfo.cycle + " of " + root.focusInfo.cycles + " · " : "")
                                  + (root.focusInfo.blocking ? "apps blocked" : "apps allowed")
                                  + (root.focusInfo.closed > 0 ? " · " + root.focusInfo.closed + " closed" : "")
                            color: root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: 11
                        }
                    }
                }

                // progress of the running phase
                Rectangle {
                    Layout.fillWidth: true
                    height: 4; radius: 2
                    color: Qt.alpha(root.pal.text, 0.10)
                    Rectangle {
                        height: parent.height; radius: 2
                        color: root.pal.accent
                        width: parent.width * (root.focusInfo.total > 0 ? Math.max(0, Math.min(1, 1 - root.focusSecs / root.focusInfo.total)) : 0)
                        Behavior on width { NumberAnimation { duration: 900 } }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Chip { Layout.fillWidth: true; pal: root.pal; label: root.focusInfo.paused ? "Resume" : "Pause"; onClicked: root.focusCommand(root.focusInfo.paused ? "resume" : "pause") }
                    Chip { Layout.fillWidth: true; pal: root.pal; label: "+5 min"; onClicked: root.focusCommand("add 5") }
                    Chip { Layout.fillWidth: true; pal: root.pal; label: root.focusInfo.pomodoro ? "Skip" : "Done"; onClicked: root.focusCommand("skip") }
                    RoundBtn { pal: root.pal; glyph: String.fromCodePoint(0xF0156); size: 36; onClicked: root.focusCommand("stop") }
                }
            }
        }

        // one quiet row: settings gear, gaming mode, power button
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 10
            spacing: 8
            Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0493); label: "Settings"; onClicked: root.openSettings() }
            Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0297); label: root.gaming ? "Gaming on" : "Gaming"; on: root.gaming; onClicked: root.toggleGaming() }
            RoundBtn { pal: root.pal; glyph: String.fromCodePoint(0xF0425); primary: true; size: 36; onClicked: root.openPower() }
        }
    }
}
