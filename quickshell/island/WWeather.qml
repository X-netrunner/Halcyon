import QtQuick
import Quickshell.Io

// "Weather": the temperature and the sky from wttr.in (one small request every 30 minutes while the widget is on the desktop; nothing is
// asked when it is not). Place empty = found by your internet address.   card | compact | big
WBase {
    id: root

    property var cur: null
    property string err: ""
    readonly property bool f: opt("unit", "c") === "f"
    readonly property string place: String(opt("place", "")).trim()

    function ask() { if (!proc.running) proc.running = true }
    onPlaceChanged: if (live) ask()
    Timer { running: root.live; repeat: true; interval: 1800000; triggeredOnStart: true; onTriggered: root.ask() }
    Process {
        id: proc
        command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + encodeURIComponent(root.place) + "?format=j1"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.cur = JSON.parse(text).current_condition[0]; root.err = "" } catch (e) { root.err = "no data" }
            }
        }
        onExited: code => { if (code !== 0) root.err = "offline" }
    }

    readonly property string desc: cur && cur.weatherDesc && cur.weatherDesc.length ? String(cur.weatherDesc[0].value) : (err !== "" ? err : "…")
    readonly property string temp: cur ? (f ? cur.temp_F : cur.temp_C) + "°" : "--°"
    readonly property string feels: cur ? (f ? cur.FeelsLikeF : cur.FeelsLikeC) + "°" : ""
    readonly property int icon: {
        var d = desc.toLowerCase()
        if (d.indexOf("thunder") >= 0) return 0xF0593
        if (d.indexOf("snow") >= 0 || d.indexOf("sleet") >= 0 || d.indexOf("blizzard") >= 0 || d.indexOf("ice") >= 0) return 0xF0598
        if (d.indexOf("rain") >= 0 || d.indexOf("drizzle") >= 0 || d.indexOf("shower") >= 0) return 0xF0597
        if (d.indexOf("fog") >= 0 || d.indexOf("mist") >= 0 || d.indexOf("haze") >= 0) return 0xF0591
        if (d.indexOf("partly") >= 0) return 0xF0595
        if (d.indexOf("cloud") >= 0 || d.indexOf("overcast") >= 0) return 0xF0590
        return 0xF0599
    }

    implicitWidth: body.item ? body.item.implicitWidth : 150
    implicitHeight: body.item ? body.item.implicitHeight : 60
    Loader { id: body; sourceComponent: root.style === "compact" ? compactC : (root.style === "big" ? bigC : (root.style === "whisper" ? whisperC : cardC)) }

    Component {
        id: whisperC
        Column {
            spacing: root.sz(6)
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.temp; font.pixelSize: root.sz(64); font.weight: Font.ExtraLight }
            Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(28); height: 1; color: Qt.alpha(root.accent, 0.75) }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.desc.toLowerCase(); color: root.dim; font.pixelSize: root.sz(12); font.letterSpacing: 3 }
        }
    }

    Component {
        id: cardC
        Row {
            spacing: root.sz(14)
            WIco { b: root; text: root.glyph(root.icon); font.pixelSize: root.sz(46); anchors.verticalCenter: parent.verticalCenter }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                WLbl { b: root; text: root.temp; font.pixelSize: root.sz(34); font.weight: Font.Light }
                WLbl { b: root; text: root.desc; color: root.dim; font.pixelSize: root.sz(13) }
                WLbl { b: root; visible: root.cur !== null; text: "feels " + root.feels + "  ·  " + (root.cur ? root.cur.humidity : "") + "% humidity"; color: root.dim; font.pixelSize: root.sz(11) }
            }
        }
    }
    Component {
        id: compactC
        Row {
            spacing: root.sz(8)
            WIco { b: root; text: root.glyph(root.icon); font.pixelSize: root.sz(22); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.temp; font.pixelSize: root.sz(20); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.desc; color: root.dim; font.pixelSize: root.sz(13); anchors.verticalCenter: parent.verticalCenter }
        }
    }
    Component {
        id: bigC
        Column {
            spacing: 0
            Row {
                spacing: root.sz(10)
                WIco { b: root; text: root.glyph(root.icon); font.pixelSize: root.sz(60); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.temp; font.pixelSize: root.sz(76); font.weight: Font.Light; anchors.verticalCenter: parent.verticalCenter }
            }
            WLbl { b: root; text: root.desc; color: root.accent; font.pixelSize: root.sz(16); font.weight: Font.Medium }
        }
    }
}
