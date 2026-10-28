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
    property int override: 0     // seconds from Settings (0 = the app's own timeout, 3..15 s)
    property bool stars: true    // the drifting stars behind the popup (Settings > Constellations)
    property int critSecs: 30    // critical ones: seconds before the popup hides itself (0 = they wait for a click); the notification stays in the centre
    signal dismissed()      // the user clicked it: remove it everywhere
    signal timedOut()       // the countdown ran out: hide the popup only
    signal hideAll()        // right click
    // several popups at once share ONE box (Notifs.qml draws it once, rounded, and it grows / shrinks with them): this card draws
    // no surface of its own, it only opens (height 0 -> full) when it arrives and folds shut when it leaves, so the box never goes square
    property bool stacked: false         // more than one popup is showing: no time-left bar
    property real grow: 0                // 0 = folded shut, 1 = open
    readonly property real fullH: content.implicitHeight + 36
    property bool fromRight: true   // the side of the screen the popups sit on: with the border around the screen they slide out of it
    property string cornerJoin: ""    // "t" / "b": this card is the one in the screen corner, flush with the top / bottom border too
    readonly property real hideY: cornerJoin === "t" ? -(fullH + (pal ? pal.frameT : 0) + 30) : (cornerJoin === "b" ? (fullH + (pal ? pal.frameT : 0) + 30) : 0)
    readonly property real hideX: (fromRight ? 1 : -1) * (width + (pal ? pal.frameT : 0) + 30)

    readonly property bool critical: notif ? notif.urgency === NotificationUrgency.Critical : false
    readonly property int dur: critical ? critSecs * 1000
        : override > 0 ? override * 1000
        : Math.max(3000, Math.min(15000, notif && notif.expireTimeout > 0 ? notif.expireTimeout * 1000
                                         : (notif && notif.urgency === NotificationUrgency.Low ? 4000 : 6000)))
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
    NumberAnimation { id: swipeAnim; target: card; property: "swipeX"; duration: 180; easing.type: Easing.OutCubic; onFinished: collapse.start() }
    NumberAnimation { id: swipeBack; target: card; property: "swipeX"; to: 0; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
    property bool closing: false
    property bool expired: false

    readonly property var extraActions: {
        var out = []
        var a = (notif && notif.actions) ? notif.actions : []
        for (var i = 0; i < a.length; i++)
            if (a[i].identifier !== "default") out.push(a[i])
        return out
    }

    width: 392
    height: Math.round(fullH * grow)
    clip: true                       // what slides out stays inside the box, and a card that folds shut hides its text

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
        var a = (notif && notif.actions) ? notif.actions : []
        for (var i = 0; i < a.length; i++)
            if (a[i].identifier === "default") { a[i].invoke(); return }
    }

    Component.onCompleted: enter.start()

    // arriving: slides in on a long soft landing (fast start, no bounce) while the box opens to make room
    ParallelAnimation {
        id: enter
        NumberAnimation { target: bubble; property: "x"; from: card.pal.frameOn ? card.hideX : 36; to: 0; duration: card.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0.7, 0.1, 1, 1, 1] }
        NumberAnimation { target: bubble; property: "y"; from: card.pal.frameOn ? card.hideY : 0; to: 0; duration: card.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0.7, 0.1, 1, 1, 1] }
        NumberAnimation { target: bubble; property: "opacity"; from: card.pal.frameOn ? 1 : 0; to: 1; duration: card.pal.dMed; easing.type: Easing.InOutSine }
        NumberAnimation { target: card; property: "grow"; from: 0; to: 1; duration: card.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
    }
    // leaving: slides out on an accelerating curve; the card folds shut a moment later, so the ones below glide up and the box shrinks
    // smoothly (it is one rounded box, so its corners stay round the whole time)
    SequentialAnimation {
        id: exit
        ParallelAnimation {
            NumberAnimation { target: bubble; property: "x"; to: card.pal.frameOn ? card.hideX : 36; duration: card.pal.dMed + 60; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 0, 0.8, 0.15, 1, 1] }
            NumberAnimation { target: bubble; property: "y"; to: card.pal.frameOn ? card.hideY : 0; duration: card.pal.dMed + 60; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 0, 0.8, 0.15, 1, 1] }
            NumberAnimation { target: bubble; property: "opacity"; to: card.pal.frameOn ? 1 : 0; duration: card.pal.dMed; easing.type: Easing.InOutSine }
            SequentialAnimation {
                PauseAnimation { duration: Math.round(card.pal.dMed * 0.35) }
                NumberAnimation { target: card; property: "grow"; to: 0; duration: card.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curveClose }
            }
        }
        ScriptAction { script: card.finish() }
    }
    // after a swipe the card is already out of sight: just fold it shut
    SequentialAnimation {
        id: collapse
        NumberAnimation { target: card; property: "grow"; to: 0; duration: card.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curveClose }
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

    Item {
        id: bubble
        transform: Translate { x: card.swipeX }
        width: card.width
        height: card.fullH

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

        BarStars {
            anchors.fill: parent
            anchors.margins: 4
            pal: card.pal
            count: 3
            loopMs: 110000
            sizeScale: 1.2
            active: card.stars
            visible: card.stars
        }

        // urgent ones: a red stripe on the inner edge (the box around them is shared, so it has no outline of its own to turn red)
        Rectangle {
            visible: card.critical
            x: 6; y: 12
            width: 3; height: parent.height - 24
            radius: 1.5
            color: Qt.alpha(card.pal.bad, 0.8)
        }

        // click target sits underneath the content so the action chips keep their own clicks
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) { card.hideAll(); return }
                card.runDefault()
                card.close(true)
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
                        text: (card.notif && card.notif.appName) ? card.notif.appName : ""
                        color: card.tone
                        font.family: card.pal.uiFont
                        font.pixelSize: 11
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }
                    // a real button: removes it without running the app's default action (a click anywhere else opens the app)
                    Item {
                        visible: hov.hovered
                        implicitWidth: 20; implicitHeight: 20
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            color: xMa.containsMouse ? card.pal.text : card.pal.muted
                            font.pixelSize: 12
                        }
                        MouseArea { id: xMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.close(false) }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: (card.notif && card.notif.summary) ? card.notif.summary : ""
                    color: card.pal.text
                    font.family: card.pal.uiFont
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                }
                Text {
                    id: nbody0
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: (card.notif && card.notif.body) ? card.notif.body.replace(/\n/g, "<br>") : ""
                    textFormat: Text.StyledText
                    color: Qt.alpha(card.pal.text, 0.74)
                    font.family: card.pal.uiFont
                    font.pixelSize: 13
                    lineHeight: 1.12
                    wrapMode: Text.Wrap
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
                            onClicked: { modelData.invoke(); if (typeof card !== "undefined" && card) card.close(false) }     // the action can remove the card itself first
                        }
                    }
                }
            }
        }

        // time left (a lone popup only: with several the box stays calm)
        Rectangle {
            visible: card.dur > 0
            opacity: card.stacked ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: card.pal.dMed; easing.type: Easing.InOutSine } }
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 24; bottomMargin: 8 }
            height: 2
            radius: 1
            width: (parent.width - 48) * card.life
            color: Qt.alpha(card.tone, 0.45)
        }
    }
}
