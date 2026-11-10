import QtQuick
import QtQuick.Layouts
import Quickshell

// The notification list for the bar's drop-down page (shell.qml, Settings > Bar style > Drag the bar down).
// Same header (a Do not disturb / Airplane switch, the title, Clear: NotifHeader.qml) and rows as the notification centre (Notifs.qml), but it lives inside the bar
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

        NotifHeader {
            Layout.fillWidth: true
            pal: root.pal
            count: root.items.length
            dnd: root.notifs ? root.notifs.dnd : false
            quick: (root.notifs && root.notifs.quick === "airplane") ? "airplane" : "dnd"
            airplane: root.notifs ? root.notifs.airplane : false
            onQuickClicked: { if (quick === "airplane") root.notifs.airplaneRequested(); else root.notifs.dndRequested(!root.notifs.dnd) }
            onClearClicked: root.notifs.clearAll()
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
