import QtQuick
import QtQuick.Layouts
import Quickshell

// The notification list for the bar's drop-down page (shell.qml, Settings > Bar style > Drag the bar down).
// Same header (count, Do not disturb, Clear) and rows as the notification centre (Notifs.qml), but it lives inside the bar
// instead of in its own window. The notification centre on the right edge keeps working as before.
Item {
    id: root
    property var pal
    property var notifs                 // the Notifs scope: history, dnd, arrived, avatar, usePfp, maxHistory, clearAll(), dismiss(n), dndRequested(on)
    property bool active: false         // on screen: keeps the "5m" labels fresh
    property real now: Date.now()
    readonly property int listMax: 440
    readonly property var items: notifs ? notifs.history : []

    width: pal ? pal.boxW : 392
    implicitHeight: col.implicitHeight

    Timer { interval: 30000; running: root.active; repeat: true; triggeredOnStart: true; onTriggered: root.now = Date.now() }

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            BoxTitle {
                pal: root.pal
                title: "Notifications"
                sub: root.items.length === 0 ? "You are all caught up"
                    : root.items.length + (root.items.length === 1 ? " notification" : " notifications") + ((root.notifs && root.notifs.dnd) ? "  ·  muted" : "")
            }
            Chip {
                Layout.preferredHeight: 30
                pal: root.pal
                glyph: String.fromCodePoint(0xF009B)
                label: "DND"
                on: root.notifs ? root.notifs.dnd : false
                onClicked: root.notifs.dndRequested(!root.notifs.dnd)
            }
            Chip {
                Layout.preferredHeight: 30
                visible: root.items.length > 0
                pal: root.pal
                label: "Clear"
                onClicked: root.notifs.clearAll()
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.pal.lineSoft }

        NotifList {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, root.listMax)
            visible: root.items.length > 0
            pal: root.pal
            notifs: root.notifs
            look: root.notifs ? root.notifs.look : "stack"
            now: root.now
            onDismissRequested: n => root.notifs.dismiss(n)
        }

        Item {
            visible: root.items.length === 0
            Layout.fillWidth: true
            Layout.preferredHeight: 120
            Text {
                anchors.centerIn: parent
                text: (root.notifs && root.notifs.dnd) ? "Do not disturb is on" : "Nothing new"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
            }
        }
    }
}
