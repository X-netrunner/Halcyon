import QtQuick

// Dashboard style "Bento" (Settings > Bar > Dashboard style): no tabs, everything at once in a grid of soft cards.
//   today's agenda (left, two cards tall)   what is playing, with the controls   CPU ring + memory   four quick switches
// Same data as the Tabs style (the Calendar scope, the player, the stats); a click on the agenda opens the full calendar.
Item {
    id: root
    property var pal
    property var player: null
    property var stats: ({})
    property var cal: null
    property bool wifiOn: false
    property bool btOn: false
    property bool dndOn: false
    property bool caffeineOn: false
    property bool open: false

    signal openCalendar()
    signal toggleWifi()
    signal toggleBt()
    signal runCmd(string id)

    readonly property int pad: 16
    readonly property int gap: 8
    readonly property int cw: 170
    readonly property int ch: 104
    implicitWidth: pad * 2 + cw * 4 + gap * 3          // 736: as wide as the Tabs style
    implicitHeight: pad * 2 + ch * 2 + gap

    readonly property bool ok: cal !== null && cal !== undefined
    readonly property bool linked: ok && cal.cfg && cal.cfg.configured === true
    readonly property date nowD: new Date(ok ? cal.now : Date.now())
    readonly property var events: linked ? (cal.dayMap[cal.keyOf(cal.today)] || []) : []
    readonly property bool has: player !== null && player !== undefined

    // ---- today's agenda
    DashCard {
        pal: root.pal
        x: root.pad; y: root.pad
        width: root.cw * 2 + root.gap
        height: root.ch * 2 + root.gap
        Text {
            id: agTitle
            x: 16; y: 14
            text: "Today"
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tTitle
            font.weight: Font.DemiBold
        }
        Text {
            anchors { right: parent.right; rightMargin: 16; baseline: agTitle.baseline }
            text: Qt.formatDate(root.nowD, "ddd d MMM")
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
        }
        Column {
            x: 12; y: 50
            width: parent.width - 24
            spacing: 6
            Repeater {
                model: root.events.slice(0, 4)
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool live: modelData.start * 1000 <= root.cal.now && modelData.end * 1000 > root.cal.now
                    readonly property bool past: modelData.end * 1000 < root.cal.now
                    width: parent.width
                    height: 40
                    radius: root.pal.rMd
                    color: live ? Qt.alpha(root.pal.accent, 0.16) : Qt.alpha(root.pal.text, 0.06)
                    opacity: past ? 0.55 : 1
                    Rectangle {
                        x: 0; y: 8
                        width: 3; height: parent.height - 16; radius: 1.5
                        color: row.live ? root.pal.accent : Qt.alpha(root.pal.accent, 0.45)
                    }
                    Column {
                        x: 14
                        width: parent.width - 24
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: row.modelData.title
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody - 1
                            font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: row.modelData.allDay ? "All day" : root.cal.clock(row.modelData.start) + " – " + root.cal.clock(row.modelData.end)
                            color: row.live ? root.pal.accent : root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                        }
                    }
                }
            }
        }
        Text {
            visible: root.events.length === 0
            x: 16; y: 58
            text: root.linked ? "Nothing planned" : "Calendar not connected"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
        }
        Text {
            anchors { left: parent.left; leftMargin: 16; bottom: parent.bottom; bottomMargin: 12 }
            text: root.events.length > 4 ? "+" + (root.events.length - 4) + " more · open calendar" : "Open calendar"
            color: agMa.containsMouse ? root.pal.accent : root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tCap
        }
        MouseArea {
            id: agMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openCalendar()
            z: -1
        }
    }

    // ---- what is playing
    DashCard {
        pal: root.pal
        x: root.pad + root.cw * 2 + root.gap * 2; y: root.pad
        width: root.cw * 2 + root.gap
        height: root.ch
        Rectangle {
            id: cover
            x: 14; anchors.verticalCenter: parent.verticalCenter
            width: 56; height: 56
            radius: root.pal.rSm
            color: Qt.alpha(root.pal.accent2, 0.16)
            Text {
                anchors.centerIn: parent
                text: String.fromCodePoint(0xF075A)
                color: root.pal.accent2
                font.family: root.pal.font
                font.pixelSize: 24
            }
        }
        Column {
            x: cover.x + cover.width + 12
            width: parent.width - x - 104 - 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.has ? (root.player.trackTitle || "Unknown track") : "Nothing playing"
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.has ? (root.player.trackArtist || "") : "Now playing"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
        Row {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            spacing: 4
            DashBtn {
                pal: root.pal; width: 32; height: 32
                glyph: String.fromCodePoint(0xF04AE)
                onClicked: { if (root.has && root.player.canGoPrevious) root.player.previous() }
            }
            DashBtn {
                pal: root.pal; width: 32; height: 32
                glyph: String.fromCodePoint(root.has && root.player.isPlaying ? 0xF03E4 : 0xF040A)
                on: root.has && root.player.isPlaying
                onClicked: { if (root.has && root.player.canTogglePlaying) root.player.togglePlaying() }
            }
            DashBtn {
                pal: root.pal; width: 32; height: 32
                glyph: String.fromCodePoint(0xF04AD)
                onClicked: { if (root.has && root.player.canGoNext) root.player.next() }
            }
        }
    }

    // ---- CPU and memory
    DashCard {
        pal: root.pal
        x: root.pad + root.cw * 2 + root.gap * 2; y: root.pad + root.ch + root.gap
        width: root.cw
        height: root.ch
        Ring {
            id: cpuRing
            pal: root.pal
            x: 10; anchors.verticalCenter: parent.verticalCenter
            width: 80; height: 80
            value: Math.min(1, Math.max(0, (Number(root.stats.cpu) || 0) / 100))
            text: Math.round(Number(root.stats.cpu) || 0) + "%"
            label: "CPU"
        }
        Column {
            x: cpuRing.x + cpuRing.width + 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                text: (root.stats.memGb || "0.0") + " GB"
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: Font.DemiBold
            }
            Text {
                text: "RAM"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
    }

    // ---- quick switches
    DashCard {
        pal: root.pal
        x: root.pad + root.cw * 3 + root.gap * 3; y: root.pad + root.ch + root.gap
        width: root.cw
        height: root.ch
        Grid {
            anchors.centerIn: parent
            columns: 2
            spacing: 6
            DashBtn { pal: root.pal; width: 70; height: 37; glyph: String.fromCodePoint(0xF05A9); on: root.wifiOn; onClicked: root.toggleWifi() }
            DashBtn { pal: root.pal; width: 70; height: 37; glyph: String.fromCodePoint(0xF00AF); on: root.btOn; onClicked: root.toggleBt() }
            DashBtn { pal: root.pal; width: 70; height: 37; glyph: String.fromCodePoint(0xF009B); on: root.dndOn; onClicked: root.runCmd("dnd") }
            DashBtn { pal: root.pal; width: 70; height: 37; glyph: String.fromCodePoint(0xF0176); on: root.caffeineOn; onClicked: root.runCmd("caffeine") }
        }
    }
}
