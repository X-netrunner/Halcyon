import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Bottom-right utilities panel (wifi, bluetooth, audio, volume, mic, brightness, power mode; gear = Settings, gaming toggle, power button = PowerMenu).
// Wi-Fi / Bluetooth / Audio chips: click opens a drawn list to pick from, right-click is the quick action
// (radio on/off, mute). The lists come from `hx wifi`, `hx bt` and `hx audio`.
Glass {
    id: root
    property var stats
    property var net
    property string profile: "balanced"
    property bool autoPower: false
    property bool autoHide: false
    property bool gaming: false
    property bool caffeine: false
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

    function toggleMenu(name) {
        wifiMenu.askFor = ""
        menu = menu === name ? "" : name
        if (menu === "wifi") { wifiProc.running = true; wifiAgain.restart() }
        else if (menu === "bt") btProc.running = true
        else if (menu === "audio" || menu === "mic") audioProc.running = true
    }
    onActiveChanged: {
        if (active) audioProc.running = true      // fills the Audio chip
        else { menu = ""; wifiMenu.askFor = "" }
    }

    Process {
        id: wifiProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "wifi"]
        stdout: StdioCollector { onStreamFinished: { try { root.wifi = JSON.parse(text) } catch (e) {} } }
    }
    Timer { id: wifiAgain; interval: 3500; onTriggered: if (root.menu === "wifi") wifiProc.running = true }
    Process {
        id: btProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "bt"]
        stdout: StdioCollector { onStreamFinished: { try { root.bt = JSON.parse(text) } catch (e) {} } }
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
        for (var i = 0; i < d.length; i++) {
            var ic = String(d[i].icon || "")
            var g = 0xF00AF
            for (var k in glyphs) if (ic.indexOf(k) === 0) g = glyphs[k]
            out.push({ title: d[i].name, sub: d[i].connected ? "Connected" : "Paired", glyph: String.fromCodePoint(g), active: d[i].connected })
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
    signal openApps()
    signal openPower()
    signal micMoved(real v)
    signal toggleMic()
    signal toggleMute()
    signal volumeMoved(real v)
    signal brightnessMoved(real v)

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

        // connectivity: click = pick from a list, right-click = quick on/off
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Chip {
                Layout.fillWidth: true
                pal: root.pal
                maxLabel: 52
                glyph: String.fromCodePoint(root.net.eth ? 0xF0200 : 0xF0928)
                label: root.net.wifi === "on" ? (root.net.ssid || (root.net.eth ? "Ethernet" : "On")) : "Wi-Fi off"
                on: root.net.wifi === "on" || root.menu === "wifi"
                onClicked: root.toggleMenu("wifi")
                onRightClicked: root.toggleWifi()
            }
            Chip {
                Layout.fillWidth: true
                pal: root.pal
                maxLabel: 52
                glyph: String.fromCodePoint(0xF00AF)
                label: root.net.bt === "on" ? (root.net.btdev || "On") : "BT off"
                on: root.net.bt === "on" || root.menu === "bt"
                onClicked: root.toggleMenu("bt")
                onRightClicked: root.toggleBt()
            }
            Chip {
                Layout.fillWidth: true
                pal: root.pal
                maxLabel: 52
                glyph: root.audioGlyph(root.defaultSink ? root.defaultSink.kind : "speaker")
                label: root.defaultSink ? root.defaultSink.desc : "Audio"
                on: root.menu === "audio"
                onClicked: root.toggleMenu("audio")
                onRightClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
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
            items: root.wifiItems
            emptyText: "No networks in range"
            footer: "Network settings"
            onPowerToggled: { root.toggleWifi(); root.later("wifi", 1500) }
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
            items: root.btItems
            emptyText: "No paired devices"
            footer: "Pair a new device"
            onPowerToggled: { root.toggleBt(); root.later("bt", 1500) }
            onFooterClicked: Quickshell.execDetached(["blueman-manager"])
            onPicked: i => {
                var d = root.bt.devs[i]
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

        // volume + brightness
        Slider {
            Layout.fillWidth: true
            pal: root.pal
            glyph: String.fromCodePoint(root.muted ? 0xF0581 : 0xF057E)
            value: root.vol / 100
            dimmed: root.muted
            onMoved: v => root.volumeMoved(v)
            onGlyphClicked: root.toggleMute()
        }
        // microphone: pick the input device (round button = mute / unmute, right-click the chip = mute too)
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
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
        Slider {
            Layout.fillWidth: true
            pal: root.pal
            glyph: String.fromCodePoint(0xF00DF)
            value: root.bright / 100
            onMoved: v => root.brightnessMoved(v)
        }

        // power mode
        Text { text: "POWER MODE"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4; Layout.topMargin: 10 }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
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
            Chip {
                Layout.fillWidth: true; pal: root.pal
                glyph: String.fromCodePoint(0xF0176)
                label: root.caffeine ? "Caffeine on" : "Caffeine"
                on: root.caffeine
                onClicked: root.toggleCaffeine()
                onRightClicked: root.caffeineHour()
            }
            Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF003B); label: "Background apps"; onClicked: root.openApps() }
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
