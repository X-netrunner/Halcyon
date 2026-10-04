import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications

// Notification daemon + right-edge hover panel (like the bottom-right utilities box), popups and notification centre.
// This owns org.freedesktop.Notifications, so only one notification daemon may be running (no dunst/mako).
//
//  POPUPS (toasts)   at most maxToasts on screen, oldest at the top. A popup timing out only hides the popup.
//  HISTORY           every notification stays in the centre until you remove it. At most maxHistory are kept:
//                    when a new one arrives past that, the OLDEST is dropped and the new one takes its place.
//  coalescing        from apps in coalesceApps, same app + same title replaces the earlier one (status toggles
//                    sent by your scripts through notify-send don't pile up). From every other app only an exact
//                    repeat (same title AND text) replaces, so chat messages are all kept.
//  transient         notifications that ask to be transient show a popup but are never stored.
//  do not disturb    no popups (critical ones still show); everything is still stored. DND chip in the panel, or SUPER+SHIFT+D.
//  the panel         no button: touch the right edge of the screen (upper part) and the centre slides out; leave and it
//                    slides back. A thin glowing bar on that edge says something is unread (muted bar = do not disturb).
//
// quickshell ipc ... call island notifcenter | dnd | clearnotifs
Scope {
    id: root
    property var pal
    property int maxToasts: 5
    property int maxHistory: 30
    property bool dnd: false
    property bool clickMode: false          // Edge toggle: false = hover opens it, true = click the edge to open / close it
    property bool autoHide: false           // auto-hide on: it closes as soon as the pointer leaves, in either mode
    property string sysmode: ""             // lockdown / stealth get their background art
    property var starData: null             // other modes: the profile picture as a constellation
    property bool profileStars: true
    property var coalesceApps: ["notify-send"]
    readonly property int cardW: pal ? pal.boxW : 392
    readonly property int topY: 16          // popups and the centre line up with the top of the island

    property bool centerOpen: false
    property var history: []                // Notification objects, newest first
    property var toasts: []                 // Notification objects, oldest first
    property var arrived: ({})              // notification id -> arrival time (ms)
    property int unread: 0
    property real now: Date.now()

    signal dndRequested(bool on)            // shell.qml owns the saved setting

    // ---------- list helpers ----------
    function without(list, n) {
        var i = list.indexOf(n)
        if (i < 0) return list
        var out = list.slice()
        out.splice(i, 1)
        return out
    }
    // gone for good (the app closed it, or we dismissed it): drop it from both lists
    function forget(n) {
        toasts = without(toasts, n)
        history = without(history, n)
        delete arrived[n.id]
    }
    // a popup that is no longer shown and was never stored (transient) has nothing left to live for
    function retire(n) {
        if (history.indexOf(n) < 0) n.expire()
    }

    // ---------- actions ----------
    function dismiss(n) { forget(n); n.dismiss() }

    function hideToasts() {
        var t = toasts
        toasts = []
        for (var i = 0; i < t.length; i++) retire(t[i])
    }
    function toastTimedOut(n) {
        toasts = without(toasts, n)
        retire(n)
    }
    function clearAll() {
        var all = history.slice()
        for (var i = 0; i < toasts.length; i++)
            if (all.indexOf(toasts[i]) < 0) all.push(toasts[i])
        history = []
        toasts = []
        for (var j = 0; j < all.length; j++) all[j].dismiss()
    }
    // hover mode: touching the edge opens it, leaving closes it after a short grace period.
    // click mode: click the edge strip to open it, click it again (or Esc / the keybind) to close it.
    // opened from the keyboard it closes by itself a few seconds after the pointer is not on it (hover mode / auto-hide).
    readonly property real reveal: centerOpen ? 1 : 0
    function setHover(on) {
        if (on) { closeT.stop(); if (!clickMode) centerOpen = true }
        else if (!clickMode || autoHide) { closeT.interval = 450; closeT.restart() }
    }
    function toggleCenter() {
        if (centerOpen) { closeT.stop(); centerOpen = false }
        else { centerOpen = true; if (!clickMode || autoHide) { closeT.interval = 6000; closeT.restart() } }
    }
    Timer { id: closeT; interval: 450; onTriggered: root.centerOpen = false }

    onCenterOpenChanged: if (centerOpen) { unread = 0; hideToasts() }
    onDndChanged: if (dnd) hideToasts()

    // ---------- a new notification ----------
    function add(n) {
        var critical = n.urgency === NotificationUrgency.Critical
        var toast = !centerOpen && (!dnd || critical)
        var keep = !n.transient

        if (!keep && !toast) { n.dismiss(); return }

        if (keep) {
            var coalesce = coalesceApps.indexOf(n.appName) >= 0
            var cur = history
            var kept = []
            var stale = []
            for (var i = 0; i < cur.length; i++) {
                var o = cur[i]
                var same = o.appName === n.appName && o.summary === n.summary && (coalesce || o.body === n.body)
                if (o !== n && same) stale.push(o)
                else kept.push(o)
            }
            kept.unshift(n)
            var over = kept.splice(maxHistory)      // the oldest ones past the limit
            history = kept
            for (var s = 0; s < stale.length; s++) stale[s].dismiss()
            for (var k = 0; k < over.length; k++) over[k].dismiss()
            if (!centerOpen) unread++
        }

        if (toast) {
            var curT = toasts
            var t = []
            var gone = []
            for (var j = 0; j < curT.length; j++) {
                var p = curT[j]
                if (p !== n && p.appName === n.appName && p.summary === n.summary) gone.push(p)
                else t.push(p)
            }
            t.push(n)
            while (t.length > maxToasts) gone.push(t.shift())
            toasts = t
            for (var g = 0; g < gone.length; g++) retire(gone[g])
        }
    }

    NotificationServer {
        id: server
        actionsSupported: true
        bodyMarkupSupported: true
        imageSupported: true
        keepOnReload: false
        onNotification: n => {
            n.tracked = true
            root.arrived[n.id] = Date.now()
            n.closed.connect(function () { root.forget(n) })
            root.add(n)
        }
    }

    // keeps the "5m" labels fresh while the centre is open
    Timer {
        interval: 30000
        running: root.centerOpen
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    PanelWindow {
        id: win
        anchors { top: true; right: true; bottom: true }
        // extra room around the cards so their shadows are not cut off by the window edge
        implicitWidth: root.cardW + 30 + root.pal.boxEdge
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-notifs"
        WlrLayershell.layer: WlrLayer.Top

        // only the edge trigger and the cards / centre take clicks; the rest of the strip is click-through
        mask: root.centerOpen ? maskOpen : maskClosed
        Region { id: maskClosed; regions: [ Region { item: hot }, Region { item: stack } ] }
        Region { id: maskOpen; regions: [ Region { item: hot }, Region { item: panel } ] }

        // ---------- right-edge trigger ----------
        // a strip on the right edge, upper part of the screen (the utilities box owns the bottom-right corner)
        EdgeGrab {
            id: hot
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 90
            width: root.clickMode ? 16 : 12
            height: 260
            clickMode: root.clickMode
            onHoverChanged: on => root.setHover(on)
            onTapped: root.toggleCenter()

            // unread / do-not-disturb hint: a soft bar on the very edge, only while it has something to say
            Rectangle {
                id: hint
                anchors.right: parent.right
                anchors.rightMargin: 3
                anchors.verticalCenter: parent.verticalCenter
                width: 4
                height: root.centerOpen ? 0 : 54
                radius: 2
                color: root.dnd ? root.pal.muted : root.pal.accent
                opacity: (!root.centerOpen && (root.unread > 0 || root.dnd || root.clickMode)) ? (root.dnd ? 0.55 : (root.unread > 0 ? 0.95 : 0.22)) : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }
                Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                // breathes while something is unread
                SequentialAnimation on scale {
                    running: root.unread > 0 && !root.dnd && !root.centerOpen
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.5; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                }
            }
        }

        // ---------- popups ----------
        Column {
            id: stack
            x: 30
            y: root.topY
            width: root.cardW
            spacing: 16
            move: Transition { NumberAnimation { properties: "y"; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

            Repeater {
                model: ScriptModel { values: root.toasts }
                delegate: NotifCard {
                    required property var modelData
                    notif: modelData
                    pal: root.pal
                    width: root.cardW
                    onDismissed: root.dismiss(modelData)
                    onTimedOut: root.toastTimedOut(modelData)
                    onHideAll: root.hideToasts()
                }
            }
        }

        // ---------- notification centre ----------
        Glass {
            id: panel
            pal: root.pal
            x: win.width - width - root.pal.boxEdge + (1 - root.reveal) * (width + 40)
            y: root.topY + 74
            width: root.cardW
            height: col.implicitHeight + 2 * root.pal.boxPad
            radius: root.pal.rXl
            opacityBody: root.pal.glassSolid - 0.06
            opacity: Math.min(1, root.reveal * 1.6)
            visible: opacity > 0.01
            Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            border.color: root.sysmode === "lockdown" || root.sysmode === "stealth" ? Qt.alpha(root.pal.accent, 0.30) : root.pal.line

            // tree-style backdrop: drifting dots + flagship-mode art
            Backdrop {
                anchors.fill: parent
                anchors.margins: 14
                pal: root.pal
                mode: root.sysmode
                avatarStars: root.starData
                profileStars: root.profileStars
                dots: 10
                artStrength: 1
                artFit: 0.78
            }


            HoverHandler { onHoveredChanged: root.setHover(hovered) }
            MouseArea { anchors.fill: parent }      // swallow clicks

            ColumnLayout {
                id: col
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.pal.boxPad }
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        spacing: 0
                        Text {
                            text: "Notifications"
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tTitle
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.history.length + " of " + root.maxHistory + " kept"
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Chip {
                        Layout.preferredHeight: 30
                        pal: root.pal
                        glyph: String.fromCodePoint(0xF009B)
                        label: "DND"
                        on: root.dnd
                        onClicked: root.dndRequested(!root.dnd)
                    }
                    Chip {
                        Layout.preferredHeight: 30
                        visible: root.history.length > 0
                        pal: root.pal
                        label: "Clear"
                        onClicked: root.clearAll()
                    }
                }

                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.pal.lineSoft }

                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 470)
                    visible: root.history.length > 0
                    clip: true
                    spacing: 8
                    boundsBehavior: Flickable.StopAtBounds
                    model: ScriptModel { values: root.history }
                    delegate: NotifRow {
                        required property var modelData
                        notif: modelData
                        pal: root.pal
                        width: list.width
                        arrived: root.arrived[modelData.id] || 0
                        now: root.now
                        onDismissRequested: root.dismiss(modelData)
                    }
                    add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.pal.dMed } }
                    remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: root.pal.dFast } }
                    displaced: Transition { NumberAnimation { property: "y"; duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                }

                // empty: a tree-style node (same look as the SUPER+TAB nodes) with a short branch and a label
                Item {
                    visible: root.history.length === 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: 190
                    Layout.topMargin: 6

                    // branch from the top of the panel down to the node, with a pulse running along it
                    Rectangle {
                        id: branch
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 0
                        width: 2
                        height: 52
                        radius: 1
                        color: Qt.alpha(root.pal.accent, 0.28)
                        Rectangle {
                            id: pulse
                            width: 4; height: 4; radius: 2
                            anchors.horizontalCenter: parent.horizontalCenter
                            color: root.pal.accent
                            SequentialAnimation on y {
                                running: root.centerOpen && root.history.length === 0
                                loops: Animation.Infinite
                                NumberAnimation { from: 0; to: 48; duration: 1800; easing.type: Easing.InOutSine }
                                PauseAnimation { duration: 500 }
                            }
                        }
                    }
                    Rectangle {
                        id: node
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 52
                        width: 76; height: 76; radius: 28
                        color: Qt.alpha(root.pal.surface, 0.97)
                        border.width: 1.5
                        border.color: Qt.alpha(root.dnd ? root.pal.muted : root.pal.accent, 0.7)
                        // soft breathing ring, like the laptop node in the tree
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width + 14; height: width; radius: 34
                            color: "transparent"
                            border.width: 1
                            border.color: Qt.alpha(root.pal.accent, 0.5)
                            SequentialAnimation on opacity {
                                running: root.centerOpen && root.history.length === 0
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.5; duration: 2200; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 0.08; duration: 2200; easing.type: Easing.InOutSine }
                            }
                        }
                        // drawn glyph: a check when all caught up, a crescent moon in do-not-disturb
                        Shape {
                            anchors.centerIn: parent
                            width: 40; height: 40
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                strokeColor: root.pal.accent
                                strokeWidth: 2.6
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                joinStyle: ShapePath.RoundJoin
                                PathSvg { path: root.dnd ? "M26,6 C14,7 7,16 9,26 C11,35 22,39 31,33 C21,32 17,22 21,14 C22,11 24,8 26,6 Z" : "M9,21 L17,29 L32,12" }
                            }
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 140
                        text: root.dnd ? "Do not disturb" : "All caught up"
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tTitle
                        font.weight: Font.DemiBold
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 163
                        text: root.dnd ? "popups are muted, new ones are still kept" : "nothing new"
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tCap
                    }
                }
            }
        }
    }
}
