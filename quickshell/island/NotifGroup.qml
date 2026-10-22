import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications

// One app's notifications in the "Grouped by app" look (Settings > Panels & notifications > Notification style):
// a card with the app's icon, its name and a count, and its notifications listed inside.
//   click on a notification   run its default action (if any) and remove it
//   ✕ in the header           remove all of this app's notifications
Rectangle {
    id: g
    property var pal
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
    color: Qt.alpha(pal.surface, 0.66)
    border.width: 1
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
                size: 30
                tone: g.tone
            }
            Text {
                Layout.fillWidth: true
                text: g.app
                color: g.pal.text
                font.family: g.pal.uiFont
                font.pixelSize: g.pal.tBody + 1
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Rectangle {
                implicitWidth: cnt.implicitWidth + 16; implicitHeight: 20; radius: 10
                color: Qt.alpha(g.tone, 0.18)
                Text { id: cnt; anchors.centerIn: parent; text: g.items.length; color: g.tone; font.family: g.pal.uiFont; font.pixelSize: 11; font.weight: Font.Bold }
            }
            Rectangle {
                implicitWidth: 20; implicitHeight: 20; radius: 10
                color: xAll.containsMouse ? Qt.alpha(g.pal.text, 0.12) : "transparent"
                opacity: ghov.hovered ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: g.pal.dFast } }
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

                Rectangle { anchors.fill: parent; anchors.topMargin: 2; radius: g.pal.rSm; color: Qt.alpha(g.pal.surfaceHi, ihov.hovered ? 0.55 : 0); Behavior on color { ColorAnimation { duration: g.pal.dFast } } }
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: g.pal.lineSoft }
                HoverHandler { id: ihov }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        var a = it.n && it.n.actions ? it.n.actions : []
                        for (var i = 0; i < a.length; i++) if (a[i].identifier === "default") { a[i].invoke(); break }
                        g.dismissItem(it.n)
                    }
                }
                ColumnLayout {
                    id: itc
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 4; rightMargin: 4; topMargin: 11 }
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
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            wrapMode: Text.Wrap
                            maximumLineCount: ihov.hovered ? 4 : 2
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
                        maximumLineCount: ihov.hovered ? 80 : 3          // hover shows the whole message
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !ihov.hovered && nbody0.truncated
                        text: "hover to read all"
                        color: Qt.alpha(g.pal.muted, 0.9)
                        font.family: g.pal.uiFont
                        font.pixelSize: 10
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
                                onClicked: { modelData.invoke(); g.dismissItem(it.n) }
                            }
                        }
                    }
                }
            }
        }
    }
}
