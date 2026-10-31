import QtQuick

// Dashboard style "Command" (Settings > Bar > Dashboard style): a search bar on top that opens the launcher (a click, or Enter once the box has the
// keyboard), five quick switches under it, then a short list of places to go on the left and what is next on the right.
//   Wi-Fi, Bluetooth, Do not disturb, Caffeine and the light / dark theme work in place (the box stays open); the list closes the box and opens the page.
Item {
    id: root
    property var pal
    property var player: null
    property var cal: null
    property bool wifiOn: false
    property bool btOn: false
    property bool dndOn: false
    property bool caffeineOn: false
    property bool open: false

    signal openLauncher()
    signal openCalendar()
    signal toggleWifi()
    signal toggleBt()
    signal runCmd(string id)          // a switch: runs and the box stays
    signal launch(string id)          // a place: the box closes, then it runs

    readonly property int pad: 16
    readonly property int innerW: 560
    readonly property int listW: 330
    readonly property int listH: 192
    implicitWidth: innerW + pad * 2
    implicitHeight: pad + 44 + 10 + 42 + 12 + listH + pad

    readonly property bool ok: cal !== null && cal !== undefined
    readonly property bool linked: ok && cal.cfg && cal.cfg.configured === true
    readonly property bool has: player !== null && player !== undefined
    readonly property var upcoming: {
        if (!linked) return null
        var evs = cal.dayMap[cal.keyOf(cal.today)] || []
        for (var i = 0; i < evs.length; i++)
            if (!evs[i].allDay && evs[i].end * 1000 > cal.now) return evs[i]
        return null
    }
    function whenText(e) {
        var d = e.start * 1000 - cal.now
        if (d <= 0) return "Now, until " + cal.clock(e.end)
        var m = Math.round(d / 60000)
        return m < 60 ? "In " + m + " min" : "At " + cal.clock(e.start)
    }
    function isOn(id) {
        return id === "wifi" ? wifiOn : id === "bluetooth" ? btOn : id === "dnd" ? dndOn : id === "caffeine" ? caffeineOn : false
    }
    function press(id) {
        if (id === "wifi") toggleWifi()
        else if (id === "bluetooth") toggleBt()
        else runCmd(id)
    }

    // ---- the search bar
    Rectangle {
        id: bar
        x: root.pad; y: root.pad
        width: root.innerW; height: 44
        radius: root.pal.rMd
        color: barMa.containsMouse ? Qt.alpha(root.pal.text, 0.09) : Qt.alpha(root.pal.text, 0.06)
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Text {
            id: mag
            x: 16; anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF0349)
            color: root.pal.muted
            font.family: root.pal.font
            font.pixelSize: 18
        }
        Text {
            x: mag.x + mag.width + 10
            anchors.verticalCenter: parent.verticalCenter
            text: "Search apps, files, settings, commands"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
        }
        Rectangle {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            width: hint.implicitWidth + 14; height: 22
            radius: 7
            color: Qt.alpha(root.pal.text, 0.07)
            Text {
                id: hint
                anchors.centerIn: parent
                text: "Super"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
        MouseArea {
            id: barMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openLauncher()
        }
    }

    // ---- the switches
    Row {
        id: sw
        x: root.pad; y: bar.y + bar.height + 10
        width: root.innerW
        spacing: 8
        Repeater {
            model: [
                { g: 0xF05A9, id: "wifi" }, { g: 0xF00AF, id: "bluetooth" }, { g: 0xF009B, id: "dnd" },
                { g: 0xF0176, id: "caffeine" }, { g: 0xF050E, id: "theme" }
            ]
            delegate: DashBtn {
                required property var modelData
                pal: root.pal
                width: (sw.width - 4 * sw.spacing) / 5
                height: 42
                glyph: String.fromCodePoint(modelData.g)
                on: root.isOn(modelData.id)
                onClicked: root.press(modelData.id)
            }
        }
    }

    // ---- places
    Column {
        x: root.pad; y: sw.y + sw.height + 12
        width: root.listW
        spacing: 0
        Text {
            leftPadding: 10
            height: 22
            text: "Go to"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap
        }
        Repeater {
            model: [
                { t: "Terminal", g: 0xF018D, id: "quickterm" },
                { t: "Clipboard", g: 0xF014C, id: "clipboard" },
                { t: "Cheat sheet", g: 0xF030C, id: "cheatsheet" },
                { t: "Security center", g: 0xF099D, id: "security" },
                { t: "Settings", g: 0xF0493, id: "settings" }
            ]
            delegate: Rectangle {
                id: li
                required property var modelData
                width: root.listW
                height: 34
                radius: root.pal.rSm
                color: lma.containsMouse ? Qt.alpha(root.pal.accent, 0.14) : "transparent"
                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                Text {
                    id: lg
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    width: 22
                    text: String.fromCodePoint(li.modelData.g)
                    color: lma.containsMouse ? root.pal.accent : root.pal.muted
                    font.family: root.pal.font
                    font.pixelSize: 16
                }
                Text {
                    x: lg.x + lg.width + 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: li.modelData.t
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                }
                MouseArea {
                    id: lma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.launch(li.modelData.id)
                }
            }
        }
    }

    // ---- what is next
    DashCard {
        pal: root.pal
        x: root.pad + root.listW + 10; y: sw.y + sw.height + 12
        width: root.innerW - root.listW - 10
        height: root.listH
        Text {
            x: 14; y: 12
            text: "Next up"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap
        }
        Column {
            x: 14; y: 32
            width: parent.width - 28
            spacing: 2
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.upcoming ? root.upcoming.title : (root.linked ? "Nothing planned" : "Calendar not connected")
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: Font.DemiBold
            }
            Text {
                visible: root.upcoming !== null
                width: parent.width
                elide: Text.ElideRight
                text: root.upcoming ? root.whenText(root.upcoming) : ""
                color: root.pal.accent
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
        MouseArea {
            x: 0; y: 0
            width: parent.width; height: 90
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openCalendar()
        }
        Rectangle {
            x: 14; y: 98
            width: parent.width - 28; height: 1
            color: root.pal.line
        }
        Text {
            x: 14; y: 108
            text: "Now playing"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap
        }
        DashBtn {
            id: pp
            pal: root.pal
            x: 14; y: 130
            width: 36; height: 36
            glyph: String.fromCodePoint(root.has && root.player.isPlaying ? 0xF03E4 : 0xF040A)
            on: root.has && root.player.isPlaying
            onClicked: { if (root.has && root.player.canTogglePlaying) root.player.togglePlaying() }
        }
        Text {
            x: pp.x + pp.width + 10
            width: parent.width - x - 14
            anchors.verticalCenter: pp.verticalCenter
            elide: Text.ElideRight
            text: root.has ? (root.player.trackTitle || "Unknown track") : "Nothing playing"
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
        }
    }
}
