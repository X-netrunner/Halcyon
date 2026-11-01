import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications

// One popup (toast) card. It only controls how long the TOAST is on screen: when it times out the
// notification is NOT deleted, it stays in the notification centre (Notifs.qml owns the history).
//   look         app icon tile (36 px, rounded square) | "App · time" line (+ "urgent") | title | text | the notification's own
//                actions as small chips (the first one highlighted) | thin time-left line at the bottom | X at the top right
//   left click   run the default action (the popup hides, the notification stays in the centre)
//   right click  hide every popup (the notification centre keeps them)
//   X / a chip   remove the notification completely (a chip runs its action first)
//   hover        pauses the countdown;  critical notifications hide after their own setting (critSecs)
//   grouping     popups of one app fold into one card (Notifs.qml decides with ToastGroups.js): the newest shows "+N more" and a
//                folded layer behind it, the older ones are folded shut (height 0) but stay real cards with their own timers
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
    property bool stacked: false         // more than one card is showing: no time-left bar
    property real arrivedAt: 0           // ms timestamp of the notification (Notifs.qml), for the "App · time" line
    property bool folded: false          // grouped behind a newer popup of the same app: shut (height 0) until the group is opened
    property int more: 0                 // > 0: this is the newest of a group, and this many older ones are folded behind it
    property bool groupOpen: false       // the group is opened: every card shows, and the label says "Show less"
    signal groupToggled()                // the "+N more" label (or the folded layer) was clicked
    property real fold: folded ? 0 : 1   // 1 = open, 0 = folded shut by the group (animated)
    Behavior on fold { NumberAnimation { duration: card.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve } }
    readonly property bool layered: more > 0 && !groupOpen      // the folded layer is peeking out below
    readonly property int layerH: layered ? 10 : 0
    property real grow: 0                // 0 = folded shut, 1 = open
    readonly property real fullH: content.implicitHeight + 36 + layerH
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
    readonly property string timeText: arrivedAt > 0 ? Qt.formatTime(new Date(arrivedAt), Locale.ShortFormat) : ""

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
    NumberAnimation { id: swipeAnim; target: card; property: "swipeX"; duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1]; onFinished: collapse.start() }
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
    height: Math.round(fullH * grow * fold)
    enabled: !folded                 // a folded card takes no clicks or hover
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
        NumberAnimation { target: bubble; property: "opacity"; from: card.pal.frameOn ? 1 : 0; to: 1; duration: card.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] }
        NumberAnimation { target: card; property: "grow"; from: 0; to: 1; duration: card.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: card.pal.curve }
    }
    // leaving: slides out on an accelerating curve; the card folds shut a moment later, so the ones below glide up and the box shrinks
    // smoothly (it is one rounded box, so its corners stay round the whole time)
    SequentialAnimation {
        id: exit
        ParallelAnimation {
            NumberAnimation { target: bubble; property: "x"; to: card.pal.frameOn ? card.hideX : 36; duration: card.pal.dMed + 60; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 0, 0.8, 0.15, 1, 1] }
            NumberAnimation { target: bubble; property: "y"; to: card.pal.frameOn ? card.hideY : 0; duration: card.pal.dMed + 60; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 0, 0.8, 0.15, 1, 1] }
            NumberAnimation { target: bubble; property: "opacity"; to: card.pal.frameOn ? 1 : 0; duration: card.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] }
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

        // stretches a little while the card slides in or out and while its height grows (Jelly.qml)
        Jelly { target: bubble; pal: card.pal; originX: 0.5; originY: 0.5 }

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

        // the folded layer behind the card: older popups of the same app. A click opens the group.
        Rectangle {
            visible: card.layered
            x: 18
            width: parent.width - 36
            y: card.fullH - card.layerH - 2
            height: 22
            radius: 10
            color: Qt.alpha(card.pal.text, 0.07)
            border.width: 1
            border.color: Qt.alpha(card.pal.text, 0.10)
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.groupToggled() }
        }

        RowLayout {
            id: content
            opacity: 1 - 0.8 * card.swipeP
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
            spacing: 12

            NotifIcon {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 2
                pal: card.pal
                notif: card.notif
                avatar: card.avatar
                usePfp: card.usePfp
                size: 36
                tile: true
                urgent: card.critical
                tone: card.tone
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                // "App · time" (and "urgent" for a critical one) in small muted text; the room on the right is the X
                RowLayout {
                    Layout.fillWidth: true
                    Layout.rightMargin: 22
                    spacing: 0
                    Text {
                        Layout.maximumWidth: 170
                        text: (card.notif && card.notif.appName) ? card.notif.appName : ""
                        color: Qt.alpha(card.pal.muted, 0.95)
                        font.family: card.pal.uiFont
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: card.critical
                        text: " · urgent"
                        color: card.pal.bad
                        font.family: card.pal.uiFont
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                    }
                    Text {
                        visible: card.timeText !== ""
                        Layout.fillWidth: true
                        text: " · " + card.timeText
                        color: Qt.alpha(card.pal.muted, 0.95)
                        font.family: card.pal.uiFont
                        font.pixelSize: 11
                        elide: Text.ElideRight
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
                // the notification's own actions (everything but "default"): small chips, the first one highlighted.
                // A chip runs its action and removes the popup (the action can remove the card itself first).
                Flow {
                    visible: card.extraActions.length > 0
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    spacing: 6
                    Repeater {
                        model: card.extraActions
                        delegate: Chip {
                            required property var modelData
                            required property int index
                            pal: card.pal
                            label: modelData.text
                            maxLabel: 110
                            padX: 11
                            implicitHeight: 26
                            on: index === 0
                            onClicked: { modelData.invoke(); if (typeof card !== "undefined" && card) card.close(false) }     // the action can remove the card itself first
                        }
                    }
                }
                // the group label: this is the newest of several popups from the app
                Item {
                    visible: card.more > 0
                    Layout.topMargin: 4
                    implicitWidth: moreRow.implicitWidth
                    implicitHeight: 18
                    Row {
                        id: moreRow
                        spacing: 5
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            text: card.groupOpen ? "Show less" : "+" + card.more + " more"
                            color: moreMa.containsMouse ? card.pal.text : card.tone
                            font.family: card.pal.uiFont
                            font.pixelSize: 11
                            font.weight: Font.Medium
                        }
                        Text {
                            text: card.groupOpen ? "▴" : "▾"
                            color: moreMa.containsMouse ? card.pal.text : card.pal.muted
                            font.pixelSize: 10
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    MouseArea { id: moreMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.groupToggled() }
                }
            }
        }

        // the X at the top right: removes the notification without running the app's default action (a click anywhere else opens the app)
        Item {
            anchors { top: parent.top; right: parent.right; topMargin: 10; rightMargin: 12 }
            width: 22; height: 22
            opacity: 1 - 0.8 * card.swipeP
            Rectangle {
                anchors.fill: parent
                radius: 11
                color: xMa.containsMouse ? Qt.alpha(card.pal.text, 0.12) : "transparent"
            }
            Text {
                anchors.centerIn: parent
                text: "✕"
                color: xMa.containsMouse ? card.pal.text : Qt.alpha(card.pal.muted, hov.hovered ? 1 : 0.7)
                font.pixelSize: 11
            }
            MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.close(false) }
        }

        // time left (a lone popup only: with several the box stays calm)
        Rectangle {
            visible: card.dur > 0
            opacity: card.stacked ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: card.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 24; bottomMargin: 8 + card.layerH }
            height: 2
            radius: 1
            width: (parent.width - 48) * card.life
            color: Qt.alpha(card.tone, 0.45)
        }
    }
}
