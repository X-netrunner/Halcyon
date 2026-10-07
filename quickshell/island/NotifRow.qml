import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications

// One row in the notification centre (compact version of the popup card).
//   click   run the default action (if any) and remove it
//   ✕       remove it without running anything (shows on hover)
Item {
    id: row
    property var pal
    property var notif
    property string avatar: ""    // profile picture shown as the notification picture ("" = none)
    property bool usePfp: true
    property real arrived: 0      // ms timestamp, set by Notifs.qml
    property real now: 0          // ticks while the centre is open, so "5m" stays fresh
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

    height: bg.height

    // ---- swipe to dismiss: drag the row sideways and let go past ~half the width (or fling it)
    property real swipeX: 0
    property bool leaving: false
    readonly property real swipeP: Math.min(1, Math.abs(swipeX) / Math.max(1, width * 0.5))
    function swipeOut(dir) {
        leaving = true
        outAnim.to = dir * width * 1.1
        outAnim.start()
    }
    NumberAnimation { id: outAnim; target: row; property: "swipeX"; duration: 180; easing.type: Easing.OutCubic; onFinished: row.dismissRequested() }
    NumberAnimation { id: backAnim; target: row; property: "swipeX"; to: 0; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: row.pal.curve }

    // what shows underneath while you drag: an accent wash + a cross on the side you are pulling towards
    Rectangle {
        anchors.fill: bg
        radius: bg.radius
        color: Qt.alpha(row.pal.accent, 0.10 * row.swipeP)
        border.width: 1
        border.color: Qt.alpha(row.pal.accent, 0.5 * row.swipeP)
        visible: row.swipeP > 0.02
        Text {
            anchors.verticalCenter: parent.verticalCenter
            x: row.swipeX > 0 ? 16 : parent.width - width - 16
            text: "✕"
            color: row.pal.accent
            opacity: row.swipeP
            font.pixelSize: 14
        }
    }

    Rectangle {
        id: bg
        transform: Translate { x: row.swipeX }
        opacity: 1 - 0.85 * row.swipeP * (row.leaving ? 1.2 : 0.6)
        width: row.width
        height: content.implicitHeight + 24
        radius: row.pal.rMd
        color: hov.hovered ? Qt.alpha(row.pal.surfaceHi, 0.9) : Qt.alpha(row.pal.surface, 0.7)
        border.width: 1
        border.color: row.critical ? Qt.alpha(row.pal.bad, 0.5) : row.pal.lineSoft
        Behavior on color { ColorAnimation { duration: row.pal.dFast } }

        HoverHandler { id: hov }

        DragHandler {
            id: swipe
            target: null
            xAxis.enabled: true
            yAxis.enabled: false
            grabPermissions: PointerHandler.CanTakeOverFromItems | PointerHandler.ApprovesTakeOverByAnything
            onTranslationChanged: if (active && !row.leaving) row.swipeX = translation.x
            onActiveChanged: {
                if (active || row.leaving) return
                if (Math.abs(row.swipeX) > row.width * 0.5) row.swipeOut(row.swipeX > 0 ? 1 : -1)
                else backAnim.start()
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: { row.runDefault(); row.dismissRequested() }
        }

        RowLayout {
            id: content
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            spacing: 12

            NotifIcon {
                Layout.alignment: Qt.AlignTop
                pal: row.pal
                notif: row.notif
                avatar: row.avatar
                usePfp: row.usePfp
                size: 36
                tone: row.tone
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: row.notif ? row.notif.appName.toUpperCase() : ""
                        color: row.pal.muted
                        font.family: row.pal.uiFont
                        font.pixelSize: 10
                        font.letterSpacing: 0.8
                        elide: Text.ElideRight
                    }
                    Text {
                        text: row.rel()
                        color: Qt.alpha(row.pal.muted, 0.85)
                        font.family: row.pal.uiFont
                        font.pixelSize: row.pal.tCap
                    }
                    // sits above the row's click area, so it only removes
                    Item {
                        implicitWidth: 18
                        implicitHeight: 18
                        opacity: hov.hovered ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: row.pal.dFast } }
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            color: xMa.containsMouse ? row.pal.text : row.pal.muted
                            font.pixelSize: 11
                        }
                        MouseArea {
                            id: xMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: row.dismissRequested()
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: row.notif ? row.notif.summary : ""
                    color: row.pal.text
                    font.family: row.pal.uiFont
                    font.pixelSize: row.pal.tBody + 1
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: row.notif && row.notif.body ? row.notif.body.replace(/\n/g, "<br>") : ""
                    textFormat: Text.StyledText
                    color: Qt.alpha(row.pal.text, 0.72)
                    font.family: row.pal.uiFont
                    font.pixelSize: row.pal.tBody
                    lineHeight: 1.1
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
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
                            onClicked: { modelData.invoke(); row.dismissRequested() }
                        }
                    }
                }
            }
        }
    }
}
