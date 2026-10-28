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
    // several popups at once are ONE box: no gap, the corners that touch are square, a thin divider in the border colour between them
    property bool mergedAbove: false     // another popup sits directly above this one
    property bool mergedBelow: false     // another popup sits directly below this one
    property bool fromRight: true   // the side of the screen the popups sit on: with the border around the screen they slide out of it
    property string cornerJoin: ""    // "t" / "b": this card is the one in the screen corner, flush with the top / bottom border too
    readonly property real hideY: cornerJoin === "t" ? -(height + (pal ? pal.frameT : 0) + 30) : (cornerJoin === "b" ? (height + (pal ? pal.frameT : 0) + 30) : 0)
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
    NumberAnimation { id: swipeAnim; target: card; property: "swipeX"; duration: 180; easing.type: Easing.OutCubic; onFinished: card.finish() }
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
        var a = (notif && notif.actions) ? notif.actions : []
        for (var i = 0; i < a.length; i++)
            if (a[i].identifier === "default") { a[i].invoke(); return }
    }

    Component.onCompleted: enter.start()

    ParallelAnimation {
        id: enter
        NumberAnimation { target: bubble; property: "x"; from: card.pal.frameOn ? card.hideX : 36; to: 0; duration: 640; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
        NumberAnimation { target: bubble; property: "y"; from: card.pal.frameOn ? card.hideY : 0; to: 0; duration: 640; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
        NumberAnimation { target: bubble; property: "opacity"; from: card.pal.frameOn ? 1 : 0; to: 1; duration: 440; easing.type: Easing.InOutSine }
    }
    SequentialAnimation {
        id: exit
        ParallelAnimation {
            NumberAnimation { target: bubble; property: "x"; to: card.pal.frameOn ? card.hideX : 36; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curveClose }
            NumberAnimation { target: bubble; property: "y"; to: card.pal.frameOn ? card.hideY : 0; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curveClose }
            NumberAnimation { target: bubble; property: "opacity"; to: card.pal.frameOn ? 1 : 0; duration: 320; easing.type: Easing.InOutSine }
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
        joinH: card.pal.frameOn ? (card.fromRight ? "r" : "l") : ""
        joinV: card.pal.frameOn ? card.cornerJoin : ""
        earR: 10
        width: card.width
        height: content.implicitHeight + 36
        radius: card.pal.rLg
        sqTop: card.mergedAbove
        sqBot: card.mergedBelow
        shadow: !card.mergedAbove
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

        // the divider between two popups
        Rectangle {
            visible: card.mergedAbove
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 22; rightMargin: 22 }
            height: 2
            radius: 1
            color: Qt.alpha(card.pal.accent, 0.45)
        }

        // time left (a lone popup only: in a stack the divider takes its place)
        Rectangle {
            visible: card.dur > 0 && !card.mergedAbove && !card.mergedBelow
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 24; bottomMargin: 8 }
            height: 2
            radius: 1
            width: (parent.width - 48) * card.life
            color: Qt.alpha(card.tone, 0.45)
        }
    }
}
