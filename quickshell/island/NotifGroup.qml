import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications
import "NotifOpen.js" as NO

// One app's notifications in the "Grouped by app" look (Settings > Panels & notifications > Notification style):
// a card with the app's icon, its name and three count dots (one lit for 1, two for 2, all three for 3 or more), and its
// notifications listed inside.
//   click on a notification   run its default action (if any) and remove it
//   ✕ in the header           remove all of this app's notifications
Rectangle {
    id: g
    property var pal
    property string iconMode: "symbol"
    property string app: ""
    property var items: []                  // Notification objects, newest first
    property var arrivedMap: ({})
    property real now: 0
    signal dismissItem(var n)
    signal dismissAll()

    readonly property bool critical: {
        for (var i = 0; i < items.length; i++)
            if (items[i].urgency === NotificationUrgency.Critical) return true
        return false
    }
    readonly property color tone: critical ? pal.bad : pal.accent
    function rel(id) {
        var t = arrivedMap[id] || 0
        if (t <= 0) return ""
        var s = Math.max(0, Math.floor((now - t) / 1000))
        if (s < 45) return "now"
        if (s < 3600) return Math.max(1, Math.round(s / 60)) + "m"
        if (s < 86400) return Math.round(s / 3600) + "h"
        return Qt.formatDateTime(new Date(t), "d MMM")
    }

    height: col.implicitHeight + 28
    radius: pal.rMd + 4
    color: pal.zen ? pal.fill : Qt.alpha(pal.surface, 0.66)
    border.width: pal.zen && !critical ? 0 : 1
    border.color: critical ? Qt.alpha(pal.bad, 0.5) : pal.lineSoft

    HoverHandler { id: ghov }

    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 6
            spacing: 10
            NotifIcon {
                pal: g.pal
                notif: g.items.length > 0 ? g.items[0] : null
                usePfp: false
                mode: g.iconMode
                size: 30
                tone: g.tone
            }
            Text {
                Layout.fillWidth: true
                text: g.app
                color: g.pal.text
                font.family: g.pal.uiFont
                font.pixelSize: g.pal.tBody + 1
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            // how many there are, as three dots instead of a number: 1 lights one, 2 lights two, 3 or more light all three
            // (the rest stay dim). The exact number is the list below and the "3 notifications" line at the top of the centre.
            Row {
                spacing: 4
                Layout.alignment: Qt.AlignVCenter
                Repeater {
                    model: 3
                    delegate: Rectangle {
                        required property int index
                        width: 6; height: 6; radius: 3
                        color: g.tone
                        opacity: index < g.items.length ? 1 : 0.2
                        Behavior on opacity { NumberAnimation { duration: g.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                    }
                }
            }
            Rectangle {
                implicitWidth: 20; implicitHeight: 20; radius: 10
                color: xAll.containsMouse ? Qt.alpha(g.pal.text, 0.12) : "transparent"
                opacity: ghov.hovered ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: g.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Text { anchors.centerIn: parent; text: "✕"; color: xAll.containsMouse ? g.pal.text : g.pal.muted; font.pixelSize: 10 }
                MouseArea { id: xAll; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: g.dismissAll() }
            }
        }

        Repeater {
            model: g.items
            delegate: Item {
                id: it
                required property var modelData
                readonly property var n: modelData
                readonly property var extra: {
                    var out = []
                    var a = n ? n.actions : []
                    if (a) for (var i = 0; i < a.length; i++) if (a[i].identifier !== "default") out.push(a[i])
                    return out
                }
                Layout.fillWidth: true
                implicitHeight: itc.implicitHeight + 22

                Rectangle { anchors.fill: parent; anchors.topMargin: 2; radius: g.pal.rSm; color: Qt.alpha(g.pal.surfaceHi, ihov.hovered ? 0.55 : 0); Behavior on color { ColorAnimation { duration: g.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } } }
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: g.pal.lineSoft }
                HoverHandler { id: ihov }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (!it.n) return
                        var p = NO.plan(it.n, Quickshell.env("HOME"))
                        if (p.def) p.def.invoke()
                        Quickshell.execDetached(p.cmd)
                    }
                }
                ColumnLayout {
                    id: itc
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 4; rightMargin: 4; topMargin: 12 }
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: it.n ? it.n.summary : ""
                            color: g.pal.text
                            font.family: g.pal.uiFont
                            font.pixelSize: g.pal.tBody + 1
                            font.weight: Font.Medium
                            wrapMode: Text.Wrap
                        }
                        Text {
                            text: g.rel(it.n ? it.n.id : 0)
                            color: Qt.alpha(g.pal.muted, 0.9)
                            font.family: g.pal.uiFont
                            font.pixelSize: g.pal.tCap
                        }
                    }
                    Text {
                        id: nbody0
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: it.n && it.n.body ? it.n.body.replace(/\n/g, "<br>") : ""
                        textFormat: Text.StyledText
                        color: Qt.alpha(g.pal.text, 0.72)
                        font.family: g.pal.uiFont
                        font.pixelSize: g.pal.tBody
                        lineHeight: 1.1
                        wrapMode: Text.Wrap
                    }
                    RowLayout {
                        visible: it.extra.length > 0
                        Layout.topMargin: 6
                        spacing: 6
                        Repeater {
                            model: it.extra
                            delegate: Chip {
                                required property var modelData
                                pal: g.pal
                                label: modelData.text
                                maxLabel: 100
                                Layout.preferredHeight: 30
                                onClicked: { var n = it.n; modelData.invoke(); if (typeof g !== "undefined" && g) g.dismissItem(n) }     // the action can remove the group first
                            }
                        }
                    }
                }
            }
        }
    }
}
