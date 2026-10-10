import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

RowLayout {
    id: row
    property var pal
    property var stats
    property var net
    property var cava: []
    property bool clock24: false
    property bool clockSeconds: false    // Settings > Bar: seconds in the clock
    property bool clockDate: true        // Settings > Bar: the weekday and date next to the clock
    property bool playing: false
    property string activeSpecial: ""
    property bool caffeine: false
    property string focusText: ""        // Focus mode running: the time left ("" = no session)
    property bool focusPaused: false
    property int bgCount: 0              // apps alive in the background (BgApps.count)
    property bool showBgCount: false     // Settings > Panels > Background apps count: on the bar instead of the bottom-left corner
    signal bgClicked()                   // opens the background-apps box (it stays bottom-left)
    // Settings > Bar style > what the island shows (all on = how it always looked)
    property bool showWs: true
    property bool showSpecials: true
    property string wsLook: "numbers"        // numbers (the island's own) | capsules (the notch's: vertical capsules, current one big and vivid)
    property int wsMin: 5                    // capsules: workspaces 1..N are always drawn
    readonly property int curH: 20
    readonly property int curW: 11
    readonly property int offH: 17
    readonly property int offW: 9
    readonly property int wsCount: {
        var l = Hyprland.workspaces.values, m = Math.max(1, Math.min(10, wsMin))
        for (var i = 0; i < l.length; i++) if (l[i].id > m) m = l[i].id
        return Math.min(10, m)
    }
    function findWs(id) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].id === id) return l[i]
        return null
    }
    function wsWindows(w) {
        try { return w.toplevels.values.length } catch (e) { return 0 }
    }
    property bool showViz: true
    property bool showTime: true
    property bool showWifi: true
    property string wifiLook: "symbol"       // symbol | bars | dots
    property string btMode: "on"             // off | connected | on
    property bool showBat: true
    property bool showBatPct: true
    property bool showCaffeine: true
    property bool combo: true                // Wi-Fi + Bluetooth + battery as one round icon (StatusRing.qml) instead of three
    property int comboSize: 24
    readonly property bool statusAny: focusText !== "" || showWifi || btShown || (showBat && stats.hasBat === true) || (showCaffeine && caffeine) || (showBgCount && bgCount > 0)
    readonly property bool btShown: net.bt === "on" && (btMode === "on" || (btMode === "connected" && (net.btdev || "") !== ""))
    property bool showStats: false       // Settings > Bar: CPU / memory / temperature slide out while the pointer is on the bar
    signal statusClicked()
    signal workspaceClicked(int wsId)
    signal workspaceScrolled(int dir)    // +1 = wheel up, -1 = wheel down (shell.qml runs ws-nav.sh; Settings > Workspaces > invert)
    signal specialClicked(string name)

    readonly property var specials: [
        { name: "special", glyph: 0xF04CE },   // SUPER+S  scratch
        { name: "music", glyph: 0xF075A },     // SUPER+M  music
        { name: "sysmon", glyph: 0xF04C5 },    // CTRL+SHIFT+ESC  performance
        { name: "communication", glyph: 0xF0361 },  // SUPER+D  discord
        { name: "todo", glyph: 0xF05E0 }       // SUPER+R  todoist
    ]
    readonly property var wsList: {
        var l = Hyprland.workspaces.values, out = []
        for (var i = 0; i < l.length; i++) if (l[i].id > 0) out.push(l[i])
        out.sort(function (a, b) { return a.id - b.id })
        return out
    }
    function hasSpecial(n) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].name === "special:" + n) return true
        return false
    }

    readonly property string icoWifi: String.fromCodePoint(0xF0928)
    readonly property string icoEth: String.fromCodePoint(0xF0200)
    readonly property string icoBt: String.fromCodePoint(0xF00AF)

    // ---- layout: [ left slot ] time [ right slot ]. Both slots get the same width, so the time sits dead centre and the
    //      padding is symmetric. Left slot: workspaces at the edge, the music bar floating halfway between them and the time.
    //      Right slot: the day / date floating halfway between the time and the status icons, which sit at the edge.
    //      (The live stats that slide out on hover only grow the right slot, so nothing jumps while you hover.)
    property bool spacious: false            // Settings > Bar style > Bar spacing
    readonly property int g: spacious ? 26 : 14           // smallest gap between neighbours
    readonly property int edgePad: spacious ? 8 : 0       // extra room at both ends of the pill
    readonly property real wsW: wsRow.visible ? wsRow.implicitWidth : 0
    readonly property real vizW: showViz ? vizItem.implicitWidth : 0
    readonly property real statusW: statusAny ? statusBox.width : 0
    readonly property real dateW: (clockDate && showTime) ? dateText.implicitWidth : 0
    readonly property real statsW: statsItem.implicitWidth
    readonly property real leftBase: (wsW > 0 ? wsW + g : 0) + (vizW > 0 ? vizW + g : 0)
    readonly property real rightBase: (dateW > 0 ? g + dateW : 0) + (statusW > 0 ? g + statusW : 0)
    readonly property bool balanced: leftBase > 0 && rightBase > 0
    readonly property real leftSlotW: balanced ? Math.max(leftBase, rightBase) : leftBase
    readonly property real rightSlotW: Math.max(balanced ? Math.max(leftBase, rightBase) : rightBase, rightBase + statsW)

    spacing: 0

    SystemClock { id: clock; precision: row.clockSeconds ? SystemClock.Seconds : SystemClock.Minutes }

    Item { implicitWidth: row.edgePad; implicitHeight: 1 }

    // ---- left slot
    Item {
        id: leftSlot
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: row.leftSlotW
        implicitHeight: 26
        visible: row.leftSlotW > 0

        // ---- workspaces: numbers (current one filled), then icons for special workspaces
        //      SUPER+N -> N     SUPER+S scratch     SUPER+M music     CTRL+SHIFT+ESC performance
        Item {
            id: wsRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: wsInner.implicitWidth
            implicitHeight: 26
            visible: row.showWs || row.showSpecials
            readonly property int spacing: 4

            // index of the focused workspace in the list (-1 while a special workspace has focus)
            readonly property int curIdx: {
                for (var i = 0; i < row.wsList.length; i++) if (row.wsList[i].focused) return i
                return -1
            }
            readonly property int cellW: 26

            // the wheel over the workspace numbers walks through the workspaces
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function (e) {
                    if (e.angleDelta.y !== 0) row.workspaceScrolled(e.angleDelta.y > 0 ? 1 : -1)
                }
            }

            // ONE highlight that slides (and stretches a little on the way) from workspace to workspace,
            // instead of every number fading its own background in and out
            Rectangle {
                id: wsPill
                z: 0
                height: 26
                width: wsRow.cellW
                radius: height / 2
                color: row.pal.accent
                visible: row.showWs && row.wsLook === "numbers" && wsRow.curIdx >= 0
                opacity: wsRow.curIdx >= 0 ? 1 : 0
                property real target: Math.max(0, wsRow.curIdx) * (wsRow.cellW + wsRow.spacing)
                x: target
                Behavior on x {
                    enabled: row.pal.motion > 0.01
                    NumberAnimation { duration: Math.round(row.pal.dMed * 1.15); easing.type: Easing.BezierSpline; easing.bezierCurve: row.pal.curve }
                }
                Behavior on opacity { NumberAnimation { duration: row.pal.dFast } }
            }

            // the numbers and special icons sit in their own Row; the pill above floats over it, outside the layout
            Row {
            id: wsInner
            spacing: row.wsLook === "capsules" ? 6 : wsRow.spacing

            Repeater {
                model: (row.showWs && row.wsLook === "capsules") ? row.wsCount : 0
                delegate: Item {
                    id: cItem
                    required property int index
                    readonly property var ws: row.findWs(index + 1)
                    readonly property bool cur: ws !== null && ws.focused
                    readonly property bool occ: ws !== null && row.wsWindows(ws) > 0
                    z: 1
                    width: cur ? row.curW : row.offW
                    height: 26
                    Behavior on width { enabled: row.pal.motion > 0.01; NumberAnimation { duration: Math.round(row.pal.dMed * 1.1); easing.type: Easing.BezierSpline; easing.bezierCurve: row.pal.curve } }
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: cItem.cur ? row.curH : row.offH
                        radius: width / 2
                        color: cItem.cur ? row.pal.accent
                             : cItem.occ ? Qt.alpha(row.pal.accent, cMa.containsMouse ? 0.55 : 0.36)
                             : Qt.alpha(row.pal.text, cMa.containsMouse ? 0.28 : 0.14)
                        Behavior on height { enabled: row.pal.motion > 0.01; NumberAnimation { duration: Math.round(row.pal.dMed * 1.1); easing.type: Easing.BezierSpline; easing.bezierCurve: row.pal.curve } }
                        Behavior on color { ColorAnimation { duration: row.pal.dMed } }
                    }
                    MouseArea {
                        id: cMa
                        anchors.fill: parent
                        anchors.leftMargin: -3
                        anchors.rightMargin: -3
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: row.workspaceClicked(cItem.index + 1)
                    }
                }
            }

            Repeater {
                model: (row.showWs && row.wsLook === "numbers") ? row.wsList : []
                delegate: Item {
                    id: wsItem
                    required property var modelData
                    readonly property bool cur: modelData.focused
                    z: 1
                    width: wsRow.cellW
                    height: 26
                    // a workspace that was just created fades / grows in instead of popping
                    opacity: 0
                    scale: 0.6
                    Component.onCompleted: { opacity = 1; scale = 1 }
                    Behavior on opacity { NumberAnimation { duration: row.pal.dMed; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: row.pal.dMed; easing.type: Easing.OutCubic } }

                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: (!wsItem.cur && wsMa.containsMouse) ? row.pal.surface : "transparent"
                        Behavior on color { ColorAnimation { duration: row.pal.dFast } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: wsItem.modelData.id
                        color: wsItem.cur ? row.pal.bg : row.pal.muted
                        font.family: row.pal.uiFont
                        font.pixelSize: row.pal.tBody
                        font.weight: wsItem.cur ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: Math.round(row.pal.dMed * 0.8) } }
                    }
                    MouseArea { id: wsMa; anchors.fill: parent; hoverEnabled: true; onClicked: row.workspaceClicked(wsItem.modelData.id) }
                }
            }

            Repeater {
                model: row.showSpecials ? row.specials : []
                delegate: Item {
                    id: spItem
                    required property var modelData
                    readonly property bool lit: row.activeSpecial === modelData.name
                    visible: lit || row.hasSpecial(modelData.name)
                    width: visible ? 28 : 0
                    height: 26

                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: spItem.lit ? row.pal.accent2 : (spMa.containsMouse ? row.pal.surface : "transparent")
                        Behavior on color { ColorAnimation { duration: row.pal.dFast } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(spItem.modelData.glyph)
                        color: spItem.lit ? row.pal.bg : row.pal.muted
                        font.family: row.pal.font
                        font.pixelSize: 14
                        Behavior on color { ColorAnimation { duration: row.pal.dFast } }
                    }
                    MouseArea { id: spMa; anchors.fill: parent; hoverEnabled: true; onClicked: row.specialClicked(spItem.modelData.name) }
                }
            }
            }
        }


        Visualizer {
            id: vizItem
            anchors.verticalCenter: parent.verticalCenter
            // floats halfway between the workspaces and the time
            x: Math.round(row.wsW + (row.leftSlotW - row.wsW - width) / 2)
            visible: row.showViz
            pal: row.pal
            values: row.cava
            active: row.playing
        }
    }

    // ---- the time (dead centre). Without the time, the day / date takes its place.
    Row {
        Layout.alignment: Qt.AlignVCenter
        spacing: 10
        visible: row.showTime || row.clockDate
        Text {
            visible: row.showTime
            text: Qt.formatDateTime(clock.date, (row.clock24 ? "HH:mm" : "hh:mm") + (row.clockSeconds ? ":ss" : "") + (row.clock24 ? "" : " AP"))
            color: row.pal.text
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tTitle
            font.weight: Font.DemiBold
        }
        Text {
            visible: !row.showTime && row.clockDate
            text: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")
            color: row.pal.text
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tTitle
            font.weight: Font.DemiBold
        }
    }

    // ---- right slot
    Item {
        id: rightSlot
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: row.rightSlotW
        implicitHeight: 26
        visible: row.rightSlotW > 0

        // day / date (+ live stats on hover), halfway between the time and the status icons
        Row {
            id: dateCluster
            anchors.verticalCenter: parent.verticalCenter
            x: Math.round((row.rightSlotW - row.statusW - width) / 2)
            spacing: 0
            Text {
                id: dateText
                visible: row.clockDate && row.showTime
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")
                color: row.pal.muted
                font.family: row.pal.uiFont
                font.pixelSize: row.pal.tBody
            }
            // live stats (hover the bar): grows the pill, shrinks back when the pointer leaves
            Item {
                id: statsItem
                implicitHeight: 26
                implicitWidth: row.showStats ? statsRow.implicitWidth + 18 : 0
                clip: true
                opacity: row.showStats ? 1 : 0
                Behavior on implicitWidth { NumberAnimation { duration: row.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: row.pal.curve } }
                Behavior on opacity { NumberAnimation { duration: row.pal.dMed } }
                Row {
                    id: statsRow
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 18
                    spacing: 14
                    Repeater {
                        model: [
                            { k: "CPU", v: Math.round(row.stats.cpu || 0) + "%", frac: (row.stats.cpu || 0) / 100 },
                            { k: "RAM", v: (row.stats.memGb || "0.0") + "G", frac: (row.stats.mem || 0) / 100 },
                            { k: "TEMP", v: Math.round(row.stats.temp || 0) + "°", frac: (row.stats.temp || 0) / 100 }
                        ]
                        delegate: Row {
                            required property var modelData
                            spacing: 5
                            Text { text: modelData.k; color: row.pal.muted; font.family: row.pal.uiFont; font.pixelSize: row.pal.tCap; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: modelData.v; color: modelData.frac > 0.9 ? row.pal.bad : (modelData.frac > 0.75 ? row.pal.warn : row.pal.text); font.family: row.pal.uiFont; font.pixelSize: row.pal.tBody; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
            }

        }

        // wifi / bluetooth / battery  (click -> performance page)
        Item {
            id: statusBox
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: status.implicitWidth
            height: status.implicitHeight
            visible: row.statusAny

            Row {
                id: status
                visible: row.statusAny
                z: 1                                   // above the status MouseArea so the count chip gets its own clicks
                spacing: 10

                // background apps: count in the bar (Settings > Panels > Background apps count), click opens the box in the corner
                Item {
                    id: bgChip
                    visible: row.showBgCount && row.bgCount > 0
                    width: bgRow.implicitWidth
                    height: 20
                    anchors.verticalCenter: parent.verticalCenter
                    Row {
                        id: bgRow
                        spacing: 4
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            text: String.fromCodePoint(0xF003B)
                            color: row.pal.accent
                            font.family: row.pal.font
                            font.pixelSize: 14
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: row.bgCount
                            color: row.pal.text
                            font.family: row.pal.uiFont
                            font.pixelSize: row.pal.tBody
                            font.weight: Font.DemiBold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: row.bgClicked() }
                }

                // Focus mode: the time left (the utilities box has the controls)
                Row {
                    visible: row.focusText !== ""
                    spacing: 5
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: row.focusPaused ? 0.55 : 1
                    Text {
                        text: String.fromCodePoint(0xF051B)
                        color: row.pal.accent
                        font.family: row.pal.font; font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: row.focusText
                        color: row.pal.text
                        font.family: row.pal.uiFont; font.pixelSize: row.pal.tCap; font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                // caffeine is on: the screen will not sleep or lock
                Text {
                    visible: row.showCaffeine && row.caffeine
                    text: String.fromCodePoint(0xF0176)
                    color: row.pal.accent2
                    font.family: row.pal.font
                    font.pixelSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite; running: row.caffeine && row.pal.motion > 0.3
                        NumberAnimation { to: 0.55; duration: 1600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1600; easing.type: Easing.InOutSine }
                    }
                }
                // combined status icon: Wi-Fi in the middle, battery as a ring, Bluetooth devices as dots (Settings > Bar style)
                StatusRing {
                    id: comboRing
                    visible: row.combo && comboRing.any
                    anchors.verticalCenter: parent.verticalCenter
                    pal: row.pal
                    net: row.net
                    stats: row.stats
                    tint: row.pal.accent
                    btTint: row.pal.accent2
                    size: row.comboSize
                    showWifi: row.showWifi
                    showBat: row.showBat
                    btMode: row.btMode
                    showPct: row.showBatPct
                    textColor: row.pal.text
                    textFont: row.pal.uiFont
                    textPx: row.pal.tBody
                }
                WifiIcon {
                    visible: row.showWifi && !row.combo
                    anchors.verticalCenter: parent.verticalCenter
                    pal: row.pal
                    net: row.net
                    look: row.wifiLook
                    tint: row.pal.accent
                    size: 14
                }
                Text {
                    visible: row.btShown && !row.combo
                    text: row.icoBt
                    color: row.net.btdev !== "" ? row.pal.accent2 : row.pal.muted
                    font.family: row.pal.font
                    font.pixelSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                }
                Row {
                    visible: row.showBat && row.stats.hasBat === true && !row.combo
                    spacing: 5
                    anchors.verticalCenter: parent.verticalCenter

                    Item {
                        width: 24; height: 12
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            width: 21; height: 12; radius: 3
                            color: "transparent"
                            border.width: 1.2
                            border.color: row.pal.text
                            Rectangle {
                                x: 2; y: 2
                                height: parent.height - 4
                                width: Math.max(2, (parent.width - 4) * row.stats.bat / 100)
                                radius: 1.5
                                color: row.stats.charging ? row.pal.good : (row.stats.bat <= 20 ? row.pal.bad : row.pal.accent)
                            }
                        }
                        Rectangle { x: 21.5; y: 4; width: 2; height: 4; radius: 1; color: row.pal.text }
                    }
                    Text {
                        visible: row.showBatPct
                        text: row.stats.bat + "%" + (row.stats.batEst ? " (" + row.stats.batEst + ")" : "")
                        color: row.pal.text
                        font.family: row.pal.uiFont
                        font.pixelSize: row.pal.tBody
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
            MouseArea { anchors.fill: parent; onClicked: row.statusClicked() }
        }
    }

    Item { implicitWidth: row.edgePad; implicitHeight: 1 }
}
