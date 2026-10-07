import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications

// One popup (toast) card. It only controls how long the TOAST is on screen: when it times out the
// notification is NOT deleted, it stays in the notification centre (Notifs.qml owns the history).
//   left click   run the default action and remove the notification completely
//   right click  hide every popup (the notification centre keeps them)
//   hover        pauses the countdown;  critical notifications stay until clicked
Item {
    id: card
    property var pal
    property var notif
    property string avatar: ""   // profile picture shown as the notification picture ("" = none)
    property bool usePfp: true   // Settings > Panels & notifications > Notification picture
    property int override: 0     // seconds from Settings (0 = the app's own timeout, 3..15 s); critical ones still wait for a click
    signal dismissed()      // the user clicked it: remove it everywhere
    signal timedOut()       // the countdown ran out: hide the popup only
    signal hideAll()        // right click

    readonly property bool critical: notif.urgency === NotificationUrgency.Critical
    readonly property int dur: critical ? 0
        : override > 0 ? override * 1000
        : Math.max(3000, Math.min(15000, notif.expireTimeout > 0 ? notif.expireTimeout * 1000
                                         : (notif.urgency === NotificationUrgency.Low ? 4000 : 6000)))
    readonly property color tone: critical ? pal.bad : pal.accent

    property real life: 1
    // swipe either way past ~half the card to dismiss it for good
    property real swipeX: 0
    readonly property real swipeP: Math.min(1, Math.abs(swipeX) / Math.max(1, width * 0.5))
    function swipeOut(dir) {
        if (closing) return
        closing = true
        expired = false
        swipeAnim.to = dir * width * 1.1
        swipeAnim.start()
    }
    NumberAnimation { id: swipeAnim; target: card; property: "swipeX"; duration: 180; easing.type: Easing.OutCubic; onFinished: card.finish() }
    NumberAnimation { id: swipeBack; target: card; property: "swipeX"; to: 0; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
    property bool closing: false
    property bool expired: false

    readonly property var extraActions: {
        var out = []
        var a = notif.actions
        for (var i = 0; i < a.length; i++)
            if (a[i].identifier !== "default") out.push(a[i])
        return out
    }

    width: 392
    height: bubble.height

    function close(byTimeout) {
        if (closing) return
        closing = true
        expired = byTimeout
        exit.start()
    }
    function finish() {
        if (expired) card.timedOut()
        else card.dismissed()
    }
    function runDefault() {
        var a = notif.actions
        for (var i = 0; i < a.length; i++)
            if (a[i].identifier === "default") { a[i].invoke(); return }
    }

    Component.onCompleted: enter.start()

    ParallelAnimation {
        id: enter
        NumberAnimation { target: bubble; property: "x"; from: 36; to: 0; duration: 480; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
        NumberAnimation { target: bubble; property: "opacity"; from: 0; to: 1; duration: 320; easing.type: Easing.OutSine }
    }
    SequentialAnimation {
        id: exit
        ParallelAnimation {
            NumberAnimation { target: bubble; property: "x"; to: 36; duration: 240; easing.type: Easing.InCubic }
            NumberAnimation { target: bubble; property: "opacity"; to: 0; duration: 220 }
        }
        ScriptAction { script: card.finish() }
    }
    NumberAnimation {
        id: lifeAnim
        target: card
        property: "life"
        from: 1
        to: 0
        duration: card.dur
        running: card.dur > 0 && !card.closing
        paused: hov.hovered
        onFinished: card.close(true)
    }

    Glass {
        id: bubble
        transform: Translate { x: card.swipeX }
        pal: card.pal
        width: card.width
        height: content.implicitHeight + 36
        radius: card.pal.rLg
        opacityBody: card.pal.glassSolid - 0.06
        border.color: card.critical ? Qt.alpha(card.pal.bad, 0.6) : card.pal.line

        HoverHandler { id: hov }

        DragHandler {
            target: null
            xAxis.enabled: true
            yAxis.enabled: false
            grabPermissions: PointerHandler.CanTakeOverFromItems | PointerHandler.ApprovesTakeOverByAnything
            onTranslationChanged: if (active && !card.closing) card.swipeX = translation.x
            onActiveChanged: {
                if (active || card.closing) return
                if (Math.abs(card.swipeX) > card.width * 0.5) card.swipeOut(card.swipeX > 0 ? 1 : -1)
                else swipeBack.start()
            }
        }

        // click target sits underneath the content so the action chips keep their own clicks
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) { card.hideAll(); return }
                card.runDefault()
                card.close(false)
            }
        }

        RowLayout {
            id: content
            opacity: 1 - 0.8 * card.swipeP
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
            spacing: 14

            NotifIcon {
                Layout.alignment: Qt.AlignTop
                pal: card.pal
                notif: card.notif
                avatar: card.avatar
                usePfp: card.usePfp
                size: 44
                tone: card.tone
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: card.notif.appName.toUpperCase()
                        color: card.pal.muted
                        font.family: card.pal.uiFont
                        font.pixelSize: 10
                        font.letterSpacing: 0.8
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: hov.hovered
                        text: "✕"
                        color: card.pal.muted
                        font.pixelSize: 11
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: card.notif.summary
                    color: card.pal.text
                    font.family: card.pal.uiFont
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: card.notif.body.replace(/\n/g, "<br>")
                    textFormat: Text.StyledText
                    color: Qt.alpha(card.pal.text, 0.74)
                    font.family: card.pal.uiFont
                    font.pixelSize: 13
                    lineHeight: 1.12
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                RowLayout {
                    visible: card.extraActions.length > 0
                    Layout.topMargin: 6
                    spacing: 6
                    Repeater {
                        model: card.extraActions
                        delegate: Chip {
                            required property var modelData
                            pal: card.pal
                            label: modelData.text
                            maxLabel: 110
                            onClicked: { modelData.invoke(); card.close(false) }
                        }
                    }
                }
            }
        }

        // time left
        Rectangle {
            visible: card.dur > 0
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 24; bottomMargin: 8 }
            height: 2
            radius: 1
            width: (parent.width - 48) * card.life
            color: Qt.alpha(card.tone, 0.45)
        }
    }
}
