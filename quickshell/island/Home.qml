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

    spacing: 0

    SystemClock { id: clock; precision: row.clockSeconds ? SystemClock.Seconds : SystemClock.Minutes }

    // ---- workspaces: numbers (current one filled), then icons for special workspaces
    //      SUPER+N -> N     SUPER+S scratch     SUPER+M music     CTRL+SHIFT+ESC performance
    Item {
        id: wsRow
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: wsInner.implicitWidth
        implicitHeight: 26
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
            visible: wsRow.curIdx >= 0
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
        spacing: wsRow.spacing

        Repeater {
            model: row.wsList
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
            model: row.specials
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

    Item { implicitWidth: 18 }

    Visualizer {
        Layout.alignment: Qt.AlignVCenter
        pal: row.pal
        values: row.cava
        active: row.playing
    }

    // time · day · date
    Row {
        Layout.alignment: Qt.AlignVCenter
        spacing: 10
        Text {
            text: Qt.formatDateTime(clock.date, (row.clock24 ? "HH:mm" : "hh:mm") + (row.clockSeconds ? ":ss" : "") + (row.clock24 ? "" : " AP"))
            color: row.pal.text
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tTitle
            font.weight: Font.DemiBold
        }
        Rectangle {
            visible: row.clockDate
            width: 3; height: 3; radius: 1.5
            color: Qt.alpha(row.pal.muted, 0.7)
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: row.clockDate
            text: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")
            color: row.pal.muted
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tBody
        }
    }

    // live stats (hover the bar): grows the pill, shrinks back when the pointer leaves
    Item {
        Layout.alignment: Qt.AlignVCenter
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

    Item { implicitWidth: 18 }

    // wifi / bluetooth / battery  (click -> performance page)
    Item {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: status.implicitWidth
        Layout.preferredHeight: status.implicitHeight

        Row {
            id: status
            spacing: 10

            // caffeine is on: the screen will not sleep or lock
            Text {
                visible: row.caffeine
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
            Text {
                text: row.net.eth ? row.icoEth : row.icoWifi
                color: (row.net.wifi === "on" && row.net.ssid !== "") || row.net.eth ? row.pal.accent : Qt.alpha(row.pal.muted, 0.5)
                font.family: row.pal.font
                font.pixelSize: 14
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                visible: row.net.bt === "on"
                text: row.icoBt
                color: row.net.btdev !== "" ? row.pal.accent2 : row.pal.muted
                font.family: row.pal.font
                font.pixelSize: 14
                anchors.verticalCenter: parent.verticalCenter
            }
            Row {
                visible: row.stats.hasBat === true
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
