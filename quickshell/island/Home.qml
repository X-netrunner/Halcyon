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
    property bool playing: false
    property string activeSpecial: ""
    signal statusClicked()
    signal workspaceClicked(int wsId)
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

    SystemClock { id: clock; precision: SystemClock.Minutes }

    // ---- workspaces: numbers (current one filled), then icons for special workspaces
    //      SUPER+N -> N     SUPER+S scratch     SUPER+M music     CTRL+SHIFT+ESC performance
    Row {
        Layout.alignment: Qt.AlignVCenter
        spacing: 4

        Repeater {
            model: row.wsList
            delegate: Item {
                id: wsItem
                required property var modelData
                readonly property bool cur: modelData.focused
                width: cur ? 30 : 24
                height: 26
                Behavior on width { NumberAnimation { duration: row.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: row.pal.curve } }

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: wsItem.cur ? row.pal.accent : (wsMa.containsMouse ? row.pal.surface : "transparent")
                    Behavior on color { ColorAnimation { duration: row.pal.dFast } }
                }
                Text {
                    anchors.centerIn: parent
                    text: wsItem.modelData.id
                    color: wsItem.cur ? row.pal.bg : row.pal.muted
                    font.family: row.pal.uiFont
                    font.pixelSize: row.pal.tBody
                    font.weight: wsItem.cur ? Font.DemiBold : Font.Medium
                    Behavior on color { ColorAnimation { duration: row.pal.dFast } }
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
            text: Qt.formatDateTime(clock.date, "hh:mm AP")
            color: row.pal.text
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tTitle
            font.weight: Font.DemiBold
        }
        Rectangle {
            width: 3; height: 3; radius: 1.5
            color: Qt.alpha(row.pal.muted, 0.7)
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")
            color: row.pal.muted
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tBody
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
                            color: row.stats.charging ? "#8fcfa0" : (row.stats.bat <= 20 ? "#e58a8a" : row.pal.accent)
                        }
                    }
                    Rectangle { x: 21.5; y: 4; width: 2; height: 4; radius: 1; color: row.pal.text }
                }
                Text {
                    text: row.stats.bat + "%"
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
