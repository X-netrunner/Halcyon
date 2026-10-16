import QtQuick

// Desktop widgets "Clock" and "Date" (one file: both read the same clock). The look is the widget's style:
//   clock: digital | big | stacked | analog | minimal      date: line | card | stack
WBase {
    id: root

    property date now: new Date()
    readonly property bool isDate: kind === "date"
    readonly property bool secs: !isDate && opt("seconds", false) === true
    readonly property bool wants24: {
        var m = opt("h24", "follow")
        if (m === "24") return true
        if (m === "12") return false
        return env ? env.clock24 === true : false
    }
    // (Qt's "h" shows 0-23 unless the format also has AM/PM, so the 12 hour clock is worked out here)
    readonly property int hour12: now.getHours() % 12 === 0 ? 12 : now.getHours() % 12
    readonly property string hh: wants24 ? Qt.formatTime(now, "HH") : String(hour12)
    function roman(n) {
        if (n <= 0) return "—"
        var m = [[50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]], s = ""
        for (var i = 0; i < m.length; i++) while (n >= m[i][0]) { s += m[i][1]; n -= m[i][0] }
        return s
    }
    readonly property string kanjiDay: "日月火水木金土".charAt(now.getDay())
    readonly property string mm: Qt.formatTime(now, "mm")
    readonly property string ss: Qt.formatTime(now, "ss")
    readonly property string ap: (!wants24 && opt("ampm", true) === true) ? Qt.formatTime(now, "AP") : ""
    readonly property string timeText: hh + ":" + mm + (secs ? ":" + ss : "")
    readonly property string dateText: Qt.formatDate(now, "dddd, MMMM d") + (opt("year", false) === true ? Qt.formatDate(now, " yyyy") : "")

    Timer {
        running: root.live
        repeat: true
        interval: 1000
        onTriggered: {
            root.now = new Date()
            interval = root.secs ? 1000 : Math.max(250, 60000 - (root.now.getSeconds() * 1000 + root.now.getMilliseconds()) + 40)
        }
    }

    implicitWidth: body.item ? body.item.implicitWidth : 100
    implicitHeight: body.item ? body.item.implicitHeight : 40

    Loader {
        id: body
        sourceComponent: {
            if (root.isDate) {
                switch (root.style) {
                case "card": return dateCard
                case "stack": return dateStack
                case "hairline": return dateHair
                case "kanji": return dateKanji
                default: return dateLine
                }
            }
            switch (root.style) {
            case "big": return clockBig
            case "stacked": return clockStacked
            case "analog": return clockAnalog
            case "minimal": return clockMinimal
            case "glow": return clockGlow
            case "eclipse": return clockEclipse
            case "roman": return clockRoman
            default: return clockDigital
            }
        }
    }

    // ------------------------------------------------------------ the quiet looks (made for a dark, monochrome wallpaper)
    Component {
        id: clockGlow
        Item {
            implicitWidth: gcol.implicitWidth
            implicitHeight: gcol.implicitHeight
            WGlow { anchors.centerIn: parent; width: parent.width * 1.5 + root.sz(60); height: parent.height * 1.9 + root.sz(40); color: root.accent; strength: 0.10 }
            Column {
                id: gcol
                spacing: root.sz(8)
                WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.timeText + (root.ap !== "" ? " " + root.ap : ""); font.pixelSize: root.sz(84); font.weight: Font.ExtraLight; font.letterSpacing: root.sz(3) }
                Rectangle { visible: root.opt("date", true) === true; anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(36); height: 1; color: Qt.alpha(root.accent, 0.7) }
                WLbl { b: root; visible: root.opt("date", true) === true; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "dddd  ·  d MMMM").toUpperCase(); color: root.dim; font.pixelSize: root.sz(12); font.letterSpacing: 4 }
            }
        }
    }
    Component {
        id: clockEclipse
        Column {
            spacing: root.sz(10)
            Item {
                id: ef
                width: root.sz(150); height: width
                anchors.horizontalCenter: parent.horizontalCenter
                WGlow { anchors.centerIn: parent; width: parent.width * 1.7; height: width; color: root.accent; strength: 0.10 }
                Rectangle { anchors.fill: parent; radius: width / 2; color: "transparent"; border.width: 1; border.color: Qt.alpha(root.fg, 0.35) }
                Repeater {
                    model: 4
                    delegate: Item {
                        required property int index
                        anchors.fill: parent
                        rotation: index * 90
                        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: 7; width: 3; height: 3; radius: 1.5; color: root.fg }
                    }
                }
                Item { x: ef.width / 2; y: ef.height / 2; width: 0; height: 0; rotation: (root.now.getHours() % 12) * 30 + root.now.getMinutes() * 0.5
                    Rectangle { x: -1; y: -ef.height * 0.27; width: 2; height: ef.height * 0.27; radius: 1; color: root.fg } }
                Item { x: ef.width / 2; y: ef.height / 2; width: 0; height: 0; rotation: root.now.getMinutes() * 6 + root.now.getSeconds() * 0.1
                    Rectangle { x: -0.5; y: -ef.height * 0.40; width: 1; height: ef.height * 0.40; color: root.fg } }
                Item { visible: root.secs; x: ef.width / 2; y: ef.height / 2; width: 0; height: 0; rotation: root.now.getSeconds() * 6
                    Rectangle { x: -0.5; y: -ef.height * 0.43; width: 1; height: ef.height * 0.46; color: root.accent } }
                Rectangle { anchors.centerIn: parent; width: 9; height: 9; radius: 4.5; color: "transparent"; border.width: 1.5; border.color: root.accent }
            }
            WLbl { b: root; visible: root.opt("date", true) === true; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "ddd  ·  d MMM").toUpperCase(); color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 3 }
        }
    }
    Component {
        id: clockRoman
        Column {
            spacing: root.sz(6)
            Row {
                spacing: root.sz(16)
                anchors.horizontalCenter: parent.horizontalCenter
                WLbl { b: root; text: root.roman(parseInt(root.hh, 10)); font.pixelSize: root.sz(44); font.weight: Font.Light; font.letterSpacing: 2; anchors.verticalCenter: parent.verticalCenter }
                Rectangle { width: 1; height: root.sz(40); color: Qt.alpha(root.accent, 0.7); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.roman(parseInt(root.mm, 10)); color: root.accent; font.pixelSize: root.sz(44); font.weight: Font.Light; font.letterSpacing: 2; anchors.verticalCenter: parent.verticalCenter }
            }
            WLbl { b: root; visible: root.opt("date", true) === true; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "dddd, d MMMM").toLowerCase(); color: root.dim; font.pixelSize: root.sz(13); font.letterSpacing: 2 }
        }
    }
    Component {
        id: dateHair
        Column {
            spacing: root.sz(4)
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "dddd").toUpperCase(); color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 5 }
            Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(28); height: 1; color: Qt.alpha(root.accent, 0.75) }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "d"); font.pixelSize: root.sz(64); font.weight: Font.ExtraLight }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: (Qt.formatDate(root.now, "MMMM") + (root.opt("year", false) === true ? Qt.formatDate(root.now, " yyyy") : "")).toUpperCase(); color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 5 }
        }
    }
    Component {
        id: dateKanji
        Row {
            spacing: root.sz(16)
            WLbl { b: root; text: root.kanjiDay; font.pixelSize: root.sz(64); font.weight: Font.Light; anchors.verticalCenter: parent.verticalCenter }
            Rectangle { width: 1; height: root.sz(48); color: Qt.alpha(root.accent, 0.7); anchors.verticalCenter: parent.verticalCenter }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.sz(2)
                WLbl { b: root; text: Qt.formatDate(root.now, "M") + " · " + Qt.formatDate(root.now, "d"); font.pixelSize: root.sz(22); font.weight: Font.Light }
                WLbl { b: root; text: Qt.formatDate(root.now, "dddd").toUpperCase() + (root.opt("year", false) === true ? "  " + Qt.formatDate(root.now, "yyyy") : ""); color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3 }
            }
        }
    }

    // ------------------------------------------------------------ clock
    Component {
        id: clockDigital
        Column {
            spacing: 2
            Row {
                spacing: 6
                WLbl { b: root; text: root.timeText; font.pixelSize: root.sz(46); font.weight: Font.DemiBold; anchors.baseline: ap1.baseline }
                WLbl { b: root; id: ap1; visible: root.ap !== ""; text: root.ap; color: root.accent; font.pixelSize: root.sz(16); font.weight: Font.Medium }
            }
            WLbl { b: root; visible: root.opt("date", true) === true; text: Qt.formatDate(root.now, "dddd, MMMM d"); color: root.dim; font.pixelSize: root.sz(14) }
        }
    }
    Component {
        id: clockBig
        Column {
            spacing: 0
            Row {
                spacing: 8
                WLbl { b: root; text: root.timeText; font.pixelSize: root.sz(88); font.weight: Font.Light; anchors.baseline: ap2.baseline }
                WLbl { b: root; id: ap2; visible: root.ap !== ""; text: root.ap; color: root.accent; font.pixelSize: root.sz(24); font.weight: Font.Medium }
            }
            WLbl { b: root; visible: root.opt("date", true) === true; text: Qt.formatDate(root.now, "dddd, MMMM d"); color: root.accent; font.pixelSize: root.sz(18); font.weight: Font.Medium }
        }
    }
    Component {
        id: clockStacked
        Row {
            spacing: root.sz(16)
            Column {
                spacing: -root.sz(10)
                WLbl { b: root; text: root.hh; font.pixelSize: root.sz(70); font.weight: Font.DemiBold }
                WLbl { b: root; text: root.mm; color: root.accent; font.pixelSize: root.sz(70); font.weight: Font.Light }
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                WLbl { b: root; visible: root.secs; text: root.ss; color: root.dim; font.pixelSize: root.sz(20) }
                WLbl { b: root; visible: root.ap !== ""; text: root.ap; color: root.dim; font.pixelSize: root.sz(14) }
                WLbl { b: root; visible: root.opt("date", true) === true; text: Qt.formatDate(root.now, "ddd") + "\n" + Qt.formatDate(root.now, "MMM d"); color: root.dim; font.pixelSize: root.sz(13); lineHeight: 1.15 }
            }
        }
    }
    Component {
        id: clockMinimal
        Row {
            spacing: root.sz(10)
            WLbl { b: root; text: root.timeText + (root.ap !== "" ? " " + root.ap : ""); font.pixelSize: root.sz(28); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
            Rectangle { visible: root.opt("date", true) === true; width: 1; height: root.sz(22); color: root.track; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; visible: root.opt("date", true) === true; text: Qt.formatDate(root.now, "ddd d MMM"); color: root.dim; font.pixelSize: root.sz(14); anchors.verticalCenter: parent.verticalCenter }
        }
    }
    Component {
        id: clockAnalog
        Column {
            spacing: root.sz(8)
            Item {
                id: face
                width: root.sz(150); height: width
                anchors.horizontalCenter: parent.horizontalCenter
                Rectangle { anchors.fill: parent; radius: width / 2; color: "transparent"; border.width: 2; border.color: root.track }
                Repeater {
                    model: 12
                    delegate: Item {
                        required property int index
                        anchors.fill: parent
                        rotation: index * 30
                        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: 6; width: index % 3 === 0 ? 3 : 2; height: index % 3 === 0 ? 10 : 5; radius: 1; color: index % 3 === 0 ? root.fg : root.dim }
                    }
                }
                // hands: a zero-size item at the centre, turned; the bar is drawn upwards from it
                Item { x: face.width / 2; y: face.height / 2; width: 0; height: 0; rotation: (root.now.getHours() % 12) * 30 + root.now.getMinutes() * 0.5
                    Rectangle { x: -2.5; y: -face.height * 0.26; width: 5; height: face.height * 0.26; radius: 2.5; color: root.fg } }
                Item { x: face.width / 2; y: face.height / 2; width: 0; height: 0; rotation: root.now.getMinutes() * 6 + root.now.getSeconds() * 0.1
                    Rectangle { x: -1.75; y: -face.height * 0.38; width: 3.5; height: face.height * 0.38; radius: 1.75; color: root.fg } }
                Item { visible: root.secs; x: face.width / 2; y: face.height / 2; width: 0; height: 0; rotation: root.now.getSeconds() * 6
                    Rectangle { x: -0.75; y: -face.height * 0.42; width: 1.5; height: face.height * 0.46; radius: 1; color: root.accent } }
                Rectangle { anchors.centerIn: parent; width: 9; height: 9; radius: 4.5; color: root.accent }
            }
            WLbl { b: root; visible: root.opt("date", true) === true; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "ddd, MMM d"); color: root.dim; font.pixelSize: root.sz(13) }
        }
    }

    // ------------------------------------------------------------ date
    Component {
        id: dateLine
        WLbl { b: root; text: root.dateText; font.pixelSize: root.sz(22); font.weight: Font.Medium }
    }
    Component {
        id: dateCard
        Row {
            spacing: root.sz(14)
            WLbl { b: root; text: Qt.formatDate(root.now, "d"); color: root.accent; font.pixelSize: root.sz(60); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                WLbl { b: root; text: Qt.formatDate(root.now, "dddd"); font.pixelSize: root.sz(18); font.weight: Font.Medium }
                WLbl { b: root; text: Qt.formatDate(root.now, "MMMM") + (root.opt("year", false) === true ? Qt.formatDate(root.now, " yyyy") : ""); color: root.dim; font.pixelSize: root.sz(14) }
            }
        }
    }
    Component {
        id: dateStack
        Column {
            spacing: 0
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "dddd").toUpperCase(); color: root.accent; font.pixelSize: root.sz(12); font.weight: Font.DemiBold; font.letterSpacing: 2 }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "d"); font.pixelSize: root.sz(54); font.weight: Font.Light }
            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.now, "MMMM") + (root.opt("year", false) === true ? Qt.formatDate(root.now, " yyyy") : ""); color: root.dim; font.pixelSize: root.sz(14) }
        }
    }
}
