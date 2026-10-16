import QtQuick
import Quickshell
import Quickshell.Io

// "Network" (Wi-Fi name, signal, speed) and "Uptime" (how long the computer has been on).
WBase {
    id: root

    readonly property bool isUptime: kind === "uptime"
    function rate(b) {
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s"
        if (b >= 1024) return Math.round(b / 1024) + " KB/s"
        return Math.round(b) + " B/s"
    }

    // ---- network
    readonly property var nt: env ? env.net : ({})
    readonly property var st: env ? env.stats : ({})
    readonly property bool wifiOn: nt && nt.wifi !== undefined && nt.wifi !== "off"
    readonly property string ssid: nt && nt.ssid ? String(nt.ssid) : ""
    readonly property bool linked: ssid !== "" || (nt && nt.eth === true)
    readonly property real sig: nt && nt.signal !== undefined ? Math.max(0, Math.min(100, Number(nt.signal))) : 0
    readonly property string title: (nt && nt.eth === true && ssid === "") ? "Ethernet" : (ssid !== "" ? (opt("ssid", true) === true ? ssid : "Wi-Fi") : (wifiOn ? "Not connected" : "Wi-Fi off"))

    // ---- uptime (read from /proc/uptime once a minute, only while it is on screen)
    property real up: 0
    Process {
        id: upProc
        command: ["cat", "/proc/uptime"]
        stdout: StdioCollector { onStreamFinished: { var v = parseFloat(text.split(" ")[0]); if (!isNaN(v)) root.up = v } }
    }
    Timer { running: root.isUptime && root.live; repeat: true; interval: 60000; triggeredOnStart: true; onTriggered: if (!upProc.running) upProc.running = true }
    readonly property string upText: {
        var s = Math.floor(up), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
        return d > 0 ? d + "d " + h + "h " + m + "m" : (h > 0 ? h + "h " + m + "m" : m + "m")
    }

    implicitWidth: body.item ? body.item.implicitWidth : 160
    implicitHeight: body.item ? body.item.implicitHeight : 50
    Loader {
        id: body
        sourceComponent: isUptime ? (style === "card" ? upCard : upLine) : (style === "speed" ? speedC : (style === "signal" ? signalC : cardC))
    }

    // ---- network looks
    Component {
        id: cardC
        Row {
            spacing: root.sz(14)
            WIco { b: root; text: root.glyph(0xF05A9); color: root.linked ? root.accent : root.dim; font.pixelSize: root.sz(30); anchors.verticalCenter: parent.verticalCenter }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                WLbl { b: root; text: root.title; font.pixelSize: root.sz(16); font.weight: Font.DemiBold }
                WLbl { b: root; text: "↓ " + root.rate(root.st.down || 0) + "    ↑ " + root.rate(root.st.up || 0); color: root.dim; font.pixelSize: root.sz(12) }
            }
        }
    }
    Component {
        id: speedC
        Column {
            spacing: root.sz(2)
            Row { spacing: root.sz(8)
                WLbl { b: root; text: "↓"; color: root.accent; font.pixelSize: root.sz(20); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.rate(root.st.down || 0); font.pixelSize: root.sz(24); font.weight: Font.DemiBold } }
            Row { spacing: root.sz(8)
                WLbl { b: root; text: "↑"; color: root.dim; font.pixelSize: root.sz(20); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.rate(root.st.up || 0); color: root.dim; font.pixelSize: root.sz(18) } }
        }
    }
    Component {
        id: signalC
        Row {
            spacing: root.sz(12)
            Row {
                spacing: root.sz(3)
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: 4
                    delegate: Rectangle {
                        required property int index
                        width: root.sz(6); height: root.sz(8 + index * 6); radius: 2
                        anchors.bottom: parent.bottom
                        color: root.linked && root.sig > index * 25 + 8 ? root.accent : root.track
                    }
                }
            }
            WLbl { b: root; text: root.title; font.pixelSize: root.sz(15); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        }
    }

    // ---- uptime looks
    Component {
        id: upLine
        Row {
            spacing: root.sz(8)
            WIco { b: root; text: root.glyph(0xF0150); font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: "up " + root.upText; font.pixelSize: root.sz(16); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        }
    }
    Component {
        id: upCard
        Column {
            spacing: 0
            WLbl { b: root; text: "UPTIME"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
            WLbl { b: root; text: root.upText; font.pixelSize: root.sz(34); font.weight: Font.Light }
        }
    }
}
