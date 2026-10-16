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
    readonly property string hh: Qt.formatTime(now, wants24 ? "HH" : "h")
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
        sourceComponent: root.isDate ? (root.style === "card" ? dateCard : (root.style === "stack" ? dateStack : dateLine))
                       : (root.style === "big" ? clockBig : (root.style === "stacked" ? clockStacked : (root.style === "analog" ? clockAnalog : (root.style === "minimal" ? clockMinimal : clockDigital))))
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
