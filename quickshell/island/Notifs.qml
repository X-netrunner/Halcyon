import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "NotifLayout.js" as NL

// Notification daemon + right-edge hover panel (like the bottom-right utilities box), popups and notification centre.
// This owns org.freedesktop.Notifications, so only one notification daemon may be running (no dunst/mako).
//
//  POPUPS (toasts)   at most maxToasts on screen, oldest at the top. A popup timing out only hides the popup.
//  HISTORY           every notification stays in the centre until you remove it. At most maxHistory are kept:
//                    when a new one arrives past that, the OLDEST is dropped and the new one takes its place.
//  coalescing        from apps in coalesceApps (Halcyon's own status messages: -a Halcyon), same app + same title replaces
//                    the earlier one, so the toggles of the rice's scripts don't pile up. From every other app, notify-send
//                    included, only an exact repeat (same title AND text) replaces, so every message you send is kept.
//  transient         kept too: some apps mark everything transient, and "not in the box" was the result.
//  closed by the app an app may withdraw its own notification (read in the chat, tab focused ...). The popup goes, but the
//                    centre keeps a copy until YOU remove it (see snapshot() below).
//  urgent popups     critical ones used to wait for a click for ever (browsers send "requires interaction" as critical).
//                    They now hide after critSecs; the notification itself stays in the centre.
//  do not disturb    no popups (critical ones still show); everything is still stored. DND chip in the panel, or SUPER+SHIFT+D.
//  the panel         no button: touch the right edge of the screen (upper part) and the centre slides out; leave and it
//                    slides back. A thin glowing bar on that edge says something is unread (muted bar = do not disturb).
//
// quickshell ipc ... call island notifcenter | dnd | clearnotifs
Scope {
    id: root
    property var pal
    property bool stars: true             // constellations in this box (Settings > Constellations)
    property int maxToasts: 5
    property int maxHistory: 30
    property int toastSecs: 0               // Settings > Notifications > "How long a popup stays": 0 = what the app asks for (else this many seconds)
    property int critSecs: 30               // Settings > Notifications > "Urgent popups": seconds before an urgent popup hides itself (0 = waits for a click)
    property bool dnd: false
    property var layout: null               // opt.notifLayout: the notification box builder's layout (NotifLayout.js)
    readonly property var cfg: NL.normalize(layout)
    property string look: "stack"           // Settings > Panels & notifications > Notification style: stack | timeline | grouped
    property string avatar: ""              // your profile picture (shell.qml avatarPath): the picture of every notification
    property bool usePfp: true              // Settings > Panels & notifications > Notification picture: profile picture / app icon
    property string spot: "edge"            // Settings > Panels & notifications > Notification trigger spot: edge = strip on the right edge, corner = the top-right corner
    readonly property bool corner: spot === "corner"
    property bool edgeOn: true              // false while the bar's drop-down is on (Settings > Bar > Drag the bar down): no edge strip, no edge box; popups still show
    property bool clickMode: false          // Edge toggle: false = hover opens it, true = click the edge to open / close it
    property bool autoHide: false           // auto-hide on: it closes as soon as the pointer leaves, in either mode
    property string sysmode: ""             // lockdown / stealth get their background art
    property var starData: null             // other modes: the profile picture as a constellation
    property bool profileStars: true
    property var coalesceApps: ["Halcyon"]
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
    // the limit was lowered in Settings: drop the oldest ones now instead of at the next notification
    onMaxHistoryChanged: {
        if (history.length <= maxHistory) return
        var over = history.slice(maxHistory)
        history = history.slice(0, maxHistory)
        for (var k = 0; k < over.length; k++) over[k].dismiss()
    }
    // a popup that is no longer shown and was never stored (transient) has nothing left to live for
    function retire(n) {
        if (history.indexOf(n) < 0) n.expire()
    }

    // When an app withdraws its notification the Notification object dies with it. Keeping that object in the list would show
    // an empty row (or throw), so the centre swaps it for a plain copy of what it said. Same property names, so the rows and
    // the icon do not care. The app's picture is dropped (its image provider goes away with the notification).
    function snapshot(n) {
        var acts = []
        return {
            id: n.id, appName: n.appName || "", summary: n.summary || "", body: n.body || "", appIcon: n.appIcon || "",
            image: "", urgency: n.urgency, desktopEntry: n.desktopEntry || "", actions: acts, transient: false,
            dismiss: function () {}, expire: function () {}
        }
    }
    // the app closed it (not us: our own dismiss already took it out of both lists before this runs)
    function closedByApp(n) {
        var i = history.indexOf(n)
        toasts = without(toasts, n)
        if (i < 0) { delete arrived[n.id]; return }
        var snap = snapshot(n)
        arrived[snap.id] = arrived[n.id] || Date.now()
        var h = history.slice()
        h[i] = snap
        history = h
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
    // hover is debounced both ways so a pointer resting on (or flicking across) the edge can not make the centre pop in and out:
    //   open   only after the pointer has stayed on the strip for a moment (openT)
    //   close  only after it has been away for a moment (closeT)
    //   after closing, the strip ignores the pointer for a short while (lockT)
    function setHover(on) {
        if (!edgeOn) return
        if (on) { closeT.stop(); if (!clickMode && !centerOpen && !lockT.running) openT.restart() }
        else { openT.stop(); if (centerOpen && (!clickMode || autoHide)) { closeT.interval = 700; closeT.restart() } }
    }
    onEdgeOnChanged: if (!edgeOn) { openT.stop(); closeT.stop(); centerOpen = false }
    function toggleCenter() {
        if (!edgeOn) return
        if (centerOpen) { closeT.stop(); centerOpen = false }
        else { centerOpen = true; if (!clickMode || autoHide) { closeT.interval = 6000; closeT.restart() } }
    }
    Timer { id: openT; interval: 140; onTriggered: root.centerOpen = true }
    Timer { id: lockT; interval: 600 }
    Timer { id: closeT; interval: 700; onTriggered: root.centerOpen = false }

    // the unread bar used to breathe for as long as anything stayed unread: an endless animation = a new frame on every refresh,
    // all day. It now breathes for a few seconds after each new notification and then rests (the bar itself stays lit).
    property bool breathe: false
    onUnreadChanged: { if (unread > 0) { breathe = true; breatheT.restart() } else breathe = false }
    Timer { id: breatheT; interval: 12000; onTriggered: root.breathe = false }

    onCenterOpenChanged: { if (centerOpen) { unread = 0; hideToasts() } else { openT.stop(); lockT.restart() } }
    onDndChanged: if (dnd) hideToasts()

    // ---------- a new notification ----------
    function add(n) {
        var critical = n.urgency === NotificationUrgency.Critical
        var toast = !centerOpen && (!dnd || critical)
        var keep = true                          // transient ones are stored too

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
            n.closed.connect(function () { root.closedByApp(n) })
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
        implicitWidth: Math.max(root.cardW, root.cfg.width) + 30 + root.pal.boxEdge
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-notifs"
        WlrLayershell.layer: WlrLayer.Top

        // only the edge trigger and the cards / centre take clicks; the rest of the strip is click-through
        // one fixed mask (the closed panel sits outside the window): swapping masks on open / close re-sent the pointer
        // enter / leave and could set the centre flickering while the pointer rested on the edge
        mask: Region { regions: [ Region { item: hot }, Region { item: stack }, Region { item: panel } ] }

        // ---------- right-edge trigger ----------
        // edge: a strip on the right edge, upper part of the screen (the utilities box owns the bottom-right corner)
        // corner: a small spot in the very top-right corner of the screen
        EdgeGrab {
            id: hot
            visible: root.edgeOn
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: root.corner ? 0 : root.pal.boxTop
            width: !root.edgeOn ? 0 : root.corner ? (root.clickMode ? 28 : 16) : (root.clickMode ? 16 : 12)
            height: !root.edgeOn ? 0 : root.corner ? (root.clickMode ? 28 : 16) : 260
            clickMode: root.clickMode
            onHoverChanged: on => root.setHover(on)
            onTapped: root.toggleCenter()

            // unread / do-not-disturb hint: a soft bar on the very edge, only while it has something to say
            Rectangle {
                id: hint
                anchors.right: parent.right
                anchors.rightMargin: 3
                anchors.top: root.corner ? parent.top : undefined
                anchors.topMargin: 3
                anchors.verticalCenter: root.corner ? undefined : parent.verticalCenter
                width: root.corner ? (root.centerOpen ? 0 : 10) : 4
                height: root.corner ? 4 : (root.centerOpen ? 0 : 54)
                radius: 2
                color: root.dnd ? root.pal.muted : root.pal.accent
                opacity: (!root.centerOpen && (root.unread > 0 || root.dnd || root.clickMode)) ? (root.dnd ? 0.55 : (root.unread > 0 ? 0.95 : 0.22)) : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }
                Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                // breathes while something is unread
                SequentialAnimation on scale {
                    running: root.breathe && root.unread > 0 && !root.dnd && !root.centerOpen
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) hint.scale = 1
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
                    avatar: root.avatar
                    usePfp: root.usePfp
                    override: root.toastSecs
                    critSecs: root.critSecs
                    stars: root.stars && root.cfg.toastStars
                    width: root.cardW
                    onDismissed: root.dismiss(modelData)
                    onTimedOut: root.toastTimedOut(modelData)
                    onHideAll: root.hideToasts()
                }
            }
        }

        // ---------- notification centre ----------
        // the box itself (glass, constellation, flying stars and the blocks) is NotifSurface.qml, sized and arranged by the layout
        // from the notification box builder (Settings > Panels & notifications > Notification box builder)
        NotifSurface {
            id: panel
            pal: root.pal
            layout: root.layout
            src: root
            look: root.look
            active: root.centerOpen
            now: root.now
            maxH: win.height - 2 * root.pal.boxTop - 2 * cfg.pad
            stars: root.stars
            sysmode: root.sysmode
            starData: root.starData
            profileStars: root.profileStars
            x: win.width - width - root.pal.boxEdge + (1 - root.reveal) * (width + 40)
            y: cfg.vpos === "middle" ? Math.round((win.height - height) / 2)
             : cfg.vpos === "bottom" ? win.height - height - root.pal.boxTop - cfg.offY
             : root.pal.boxTop + cfg.offY
            opacity: Math.min(1, root.reveal * 1.6)
            visible: opacity > 0.01
            Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            border.color: root.sysmode === "lockdown" || root.sysmode === "stealth" ? Qt.alpha(root.pal.accent, 0.30) : root.pal.line

            HoverHandler { onHoveredChanged: root.setHover(hovered) }
            MouseArea { z: -1; anchors.fill: parent }      // swallow clicks (under the content, so the buttons keep theirs)

            onDndRequested: on => root.dndRequested(on)
            onClearRequested: root.clearAll()
            onDismissRequested: n => root.dismiss(n)
        }
    }
}
