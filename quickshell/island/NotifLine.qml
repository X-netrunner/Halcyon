import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications

// One notification in the "Timeline" look (Settings > Panels & notifications > Notification style): the time on the left,
// a dot on a thin rail, the text on the right. No card around it.
//   click   run the default action (if any) and remove it
//   ✕       remove it without running anything (shows on hover)
Item {
    id: row
    property var pal
    property var notif
    property real arrived: 0      // ms timestamp, set by Notifs.qml
    property real now: 0
    signal dismissRequested()

    readonly property bool critical: notif ? notif.urgency === NotificationUrgency.Critical : false
    readonly property color tone: critical ? pal.bad : pal.accent
    readonly property var extraActions: {
        var out = []
        var a = notif ? notif.actions : []
        if (a) {
            for (var i = 0; i < a.length; i++)
                if (a[i].identifier !== "default") out.push(a[i])
        }
        return out
    }
    function rel() {
        if (arrived <= 0) return ""
        var s = Math.max(0, Math.floor((now - arrived) / 1000))
        if (s < 45) return "now"
        if (s < 3600) return Math.max(1, Math.round(s / 60)) + "m"
        if (s < 86400) return Math.round(s / 3600) + "h"
        return Qt.formatDateTime(new Date(arrived), "d MMM")
    }
    function runDefault() {
        if (!notif || !notif.actions) return
        var a = notif.actions
        for (var i = 0; i < a.length; i++)
            if (a[i].identifier === "default") { a[i].invoke(); return }
    }

    // a notification that has just arrived makes its dot glow for a moment
    property real flash: 0
    NumberAnimation { id: flashAnim; target: row; property: "flash"; from: 1; to: 0; duration: 1800; easing.type: Easing.OutCubic }
    Component.onCompleted: if (arrived > 0 && Date.now() - arrived < 4000) flashAnim.start()

    height: content.implicitHeight + 18

    Rectangle {
        anchors { fill: parent; leftMargin: 62; bottomMargin: 6 }
        radius: row.pal.rSm
        color: Qt.alpha(row.pal.surfaceHi, hov.hovered ? 0.55 : 0)
        Behavior on color { ColorAnimation { duration: row.pal.dFast } }
    }
    HoverHandler { id: hov }
    MouseArea { anchors.fill: parent; onClicked: { row.runDefault(); row.dismissRequested() } }

    Text {
        x: 0; y: 3; width: 38
        horizontalAlignment: Text.AlignRight
        text: row.rel()
        color: Qt.alpha(row.pal.muted, 0.9)
        font.family: row.pal.uiFont
        font.pixelSize: row.pal.tCap
    }
    // the rail, and the dot with a soft ring
    Rectangle { x: 52; y: 20; width: 1; height: Math.max(0, row.height - 20); color: Qt.alpha(row.pal.text, 0.10) }
    Rectangle {
        x: 52.5 - width / 2; y: 8 + 5.5 - height / 2
        width: 19; height: 19; radius: 9.5
        color: Qt.alpha(row.tone, 0.14 + 0.30 * row.flash)
    }
    Rectangle { x: 52.5 - 5.5; y: 8; width: 11; height: 11; radius: 5.5; color: row.tone }

    ColumnLayout {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 72; rightMargin: 8 }
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text {
                Layout.fillWidth: true
                text: row.notif && row.notif.appName ? row.notif.appName : ""
                color: row.tone
                font.family: row.pal.uiFont
                font.pixelSize: 11
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Rectangle {
                implicitWidth: 20; implicitHeight: 20; radius: 10
                color: xMa.containsMouse ? Qt.alpha(row.pal.text, 0.12) : "transparent"
                opacity: hov.hovered ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: row.pal.dFast } }
                Text { anchors.centerIn: parent; text: "✕"; color: xMa.containsMouse ? row.pal.text : row.pal.muted; font.pixelSize: 10 }
                MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: row.dismissRequested() }
            }
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: row.notif ? row.notif.summary : ""
            color: row.pal.text
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tBody + 2
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }
        Text {
            id: nbody0
            Layout.fillWidth: true
            visible: text !== ""
            text: row.notif && row.notif.body ? row.notif.body.replace(/\n/g, "<br>") : ""
            textFormat: Text.StyledText
            color: Qt.alpha(row.pal.text, 0.72)
            font.family: row.pal.uiFont
            font.pixelSize: row.pal.tBody
            lineHeight: 1.1
            wrapMode: Text.Wrap
        }
        RowLayout {
            visible: row.extraActions.length > 0
            Layout.topMargin: 6
            spacing: 6
            Repeater {
                model: row.extraActions
                delegate: Chip {
                    required property var modelData
                    pal: row.pal
                    label: modelData.text
                    maxLabel: 100
                    Layout.preferredHeight: 30
                    onClicked: { modelData.invoke(); if (typeof row !== "undefined" && row) row.dismissRequested() }     // the action can remove the row itself first
                }
            }
        }
    }
}
