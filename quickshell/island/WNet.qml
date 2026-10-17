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

    // ---- uptime: /proc/uptime is read once, then the clock carries it on; it is read again every 10 minutes and whenever the widget
    // comes back on screen after a long time (a suspend or a full-screen app), so the number never drifts and no process runs each minute
    property real up: 0               // the value read
    property real syncAt: 0           // when it was read (ms)
    property real clockTick: 0        // bumped each minute so the text is worked out again
    Process {
        id: upProc
        command: ["cat", "/proc/uptime"]
        stdout: StdioCollector { onStreamFinished: { var v = parseFloat(text.split(" ")[0]); if (!isNaN(v)) { root.up = v; root.syncAt = Date.now(); root.clockTick = root.syncAt } } }
    }
    Timer {
        running: root.isUptime && root.live; repeat: true; interval: 60000; triggeredOnStart: true
        onTriggered: {
            if (root.syncAt === 0 || Date.now() - root.syncAt > 600000) { if (!upProc.running) upProc.running = true }
            else root.clockTick = Date.now()
        }
    }
    readonly property real upNow: up + (clockTick > syncAt ? (clockTick - syncAt) / 1000 : 0)
    readonly property int upD: Math.floor(upNow / 86400)
    readonly property int upH: Math.floor((upNow % 86400) / 3600)
    readonly property int upM: Math.floor((upNow % 3600) / 60)
    readonly property real dayFrac: clamp01((upNow % 86400) / 86400)          // how far through the current 24 h of uptime
    function pad2(n) { return (n < 10 ? "0" : "") + n }
    function plural(n, w) { return n + " " + w + (n === 1 ? "" : "s") }
    readonly property string upWords: upD > 0 ? plural(upD, "day") + ", " + plural(upH, "hour") : (upH > 0 ? plural(upH, "hour") + ", " + plural(upM, "minute") : plural(upM, "minute"))
    readonly property string bootText: syncAt > 0 ? Qt.formatDateTime(new Date(syncAt - up * 1000), "ddd d MMM, HH:mm") : "-"
    readonly property string upShort: upD > 0 ? upD + "d" : (upH > 0 ? upH + "h" : upM + "m")
    readonly property string upText: {
        var s = Math.floor(upNow), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
        return d > 0 ? d + "d " + h + "h " + m + "m" : (h > 0 ? h + "h " + m + "m" : m + "m")
    }

    implicitWidth: body.item ? body.item.implicitWidth : 160
    implicitHeight: body.item ? body.item.implicitHeight : 50
    Loader {
        id: body
        sourceComponent: isUptime ? upComp(style) : (style === "speed" ? speedC : (style === "signal" ? signalC : cardC))
    }

    function upComp(s) {
        return s === "card" ? upCard : (s === "words" ? upWordsC : (s === "digital" ? upDigital : (s === "ring" ? upRing : (s === "bar" ? upBar : (s === "boot" ? upBoot : (s === "dot" ? upDot : upLine))))))
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

    // ---- more uptime looks
    // words: "3 days, 4 hours"
    Component {
        id: upWordsC
        Column {
            spacing: root.sz(1)
            WLbl { b: root; text: "up for"; color: root.dim; font.pixelSize: root.sz(12); font.letterSpacing: 1 }
            WLbl { b: root; text: root.upWords; font.pixelSize: root.sz(22); font.weight: Font.Medium }
        }
    }
    // digital: separate blocks, days / hours / minutes
    Component {
        id: upDigital
        Row {
            spacing: root.sz(10)
            Repeater {
                model: root.upD > 0 ? [[root.upD, "DAYS"], [root.upH, "HRS"], [root.upM, "MIN"]] : [[root.upH, "HRS"], [root.upM, "MIN"]]
                delegate: Column {
                    required property var modelData
                    spacing: 0
                    WLbl { b: root; text: root.pad2(parent.modelData[0]); color: root.accent; font.pixelSize: root.sz(34); font.weight: Font.Light; anchors.horizontalCenter: parent.horizontalCenter }
                    WLbl { b: root; text: parent.modelData[1]; color: root.dim; font.pixelSize: root.sz(9); font.letterSpacing: 2; anchors.horizontalCenter: parent.horizontalCenter }
                }
            }
        }
    }
    // ring: fills over each 24 hours of uptime, the biggest unit inside
    Component {
        id: upRing
        Row {
            spacing: root.sz(12)
            Item {
                width: root.sz(64); height: width
                anchors.verticalCenter: parent.verticalCenter
                Canvas {
                    id: cv
                    anchors.fill: parent
                    canvasSize: Qt.size(width * root.rs, height * root.rs)
                    property real frac: root.dayFrac
                    property color lit: root.accent
                    property color trk: root.track
                    onFracChanged: requestPaint()
                    onLitChanged: requestPaint()
                    onTrkChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.scale(root.rs, root.rs)
                        var lw = Math.max(3, width * 0.1), r = (width - lw) / 2, c = width / 2
                        ctx.lineWidth = lw
                        ctx.lineCap = "round"
                        ctx.strokeStyle = trk
                        ctx.beginPath(); ctx.arc(c, c, r, 0, Math.PI * 2); ctx.stroke()
                        ctx.strokeStyle = lit
                        ctx.beginPath(); ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.015, frac)); ctx.stroke()
                    }
                }
                WLbl { b: root; text: root.upShort; font.pixelSize: root.sz(17); font.weight: Font.DemiBold; anchors.centerIn: parent }
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                WLbl { b: root; text: "UPTIME"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
                WLbl { b: root; text: root.upText; font.pixelSize: root.sz(16); font.weight: Font.Medium }
            }
        }
    }
    // bar: label and time on one line, a thin bar under it that fills over each 24 hours
    Component {
        id: upBar
        Column {
            width: root.sz(200)
            spacing: root.sz(6)
            Item {
                width: parent.width; height: tl.implicitHeight
                WLbl { b: root; id: tl; text: "UPTIME"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
                WLbl { b: root; text: root.upText; font.pixelSize: root.sz(15); font.weight: Font.Medium; anchors.right: parent.right }
            }
            Rectangle {
                width: parent.width; height: root.sz(6); radius: height / 2; color: root.track
                Rectangle { width: Math.max(parent.height, parent.width * root.dayFrac); height: parent.height; radius: height / 2; color: root.accent }
            }
        }
    }
    // boot: when it started, and for how long
    Component {
        id: upBoot
        Column {
            spacing: root.sz(1)
            WLbl { b: root; text: "UP SINCE"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
            WLbl { b: root; text: root.bootText; font.pixelSize: root.sz(18); font.weight: Font.Medium }
            WLbl { b: root; text: root.upText; color: root.dim; font.pixelSize: root.sz(12) }
        }
    }
    // dot: a small pill, a lit dot and the time
    Component {
        id: upDot
        Row {
            spacing: root.sz(8)
            Rectangle { width: root.sz(9); height: width; radius: width / 2; color: root.accent; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.upText; font.pixelSize: root.sz(15); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        }
    }
}
