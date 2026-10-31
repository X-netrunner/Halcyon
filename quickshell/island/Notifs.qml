import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "NotifLayout.js" as NL
import "DeskSpots.js" as DS

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
    property bool fsQuiet: false            // a window is fullscreen (shell.qml): popups stay quiet like Do not disturb, but Halcyon's own and urgent ones show
    property bool gameQuiet: false          // a game is fullscreen (shell.qml): no popup at all, not even Halcyon's own or urgent ones; all still go to the centre
    property bool asleep: false             // a window is fullscreen (shell.qml): the edge strip ignores the pointer, so the centre never slides over it
    property var layout: null               // opt.notifLayout: the notification box builder's layout (NotifLayout.js)
    readonly property var cfg: NL.normalize(layout)
    property string look: "stack"           // Settings > Panels & notifications > Notification style: stack | timeline | grouped
    property string avatar: ""              // your profile picture (shell.qml avatarPath): the picture of every notification
    property bool usePfp: true              // Settings > Panels & notifications > Notification picture: profile picture / app icon
    property string spot: "edge"            // Settings > Panels & notifications > Notification trigger spot: edge = strip on the right edge, corner = the top-right corner
    property string cornerId: "tr"
    readonly property bool corner: spot === "corner"
    readonly property bool atR: cornerId.charAt(1) === "r"
    readonly property bool atB: cornerId.charAt(0) === "b"
    property bool edgeOn: true              // false while the bar's drop-down is on (Settings > Bar > Drag the bar down): no edge strip, no edge box; popups still show
    property bool customZone: false         // the centre wakes from a wake spot (ActivationZone), not from its edge / corner
    // set by shell.qml (DS.originOf): the tag the centre was dragged to in the Desktop builder (any edge, anywhere along it). The centre then
    // opens from there (pAtR / pAtB say which side of the screen it is on); the popups (toasts) stay in the corner.
    property var origin: ({ custom: false })
    readonly property bool custom: origin.custom === true
    readonly property bool oSide: custom && origin.side === true
    readonly property bool oVert: custom && origin.side !== true
    readonly property bool pAtR: custom ? origin.atR === true : atR
    readonly property bool pAtB: custom ? origin.atB === true : atB
    readonly property real oMargin: pal.frameOn ? pal.frameT + 12 : 16
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

    // where the centre sits on the screen (the guided tour spotlights it); null when the edge box is switched off
    function tourRect(sw) {
        if (!edgeOn) return null
        var px = pAtR ? (sw - panel.width - pal.boxEdge) : pal.boxEdge
        if (oVert) px = DS.along(origin.pos, sw, panel.width, oMargin)
        var py = oSide ? DS.along(origin.pos, win.height, panel.height, oMargin) : panel.y
        return { x: px, y: py, w: panel.width, h: panel.height }
    }

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
        if (unread > history.length) unread = history.length      // there can not be more unread ones than there are notifications
    }
    // the limit was lowered in Settings: drop the oldest ones now instead of at the next notification
    onMaxHistoryChanged: {
        if (history.length <= maxHistory) return
        var over = history.slice(maxHistory)
        history = history.slice(0, maxHistory)
        for (var k = 0; k < over.length; k++) { delete arrived[over[k].id]; over[k].dismiss() }
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
        arrived = ({})
        unread = 0                         // "clear all" from the keyboard while the centre was shut left the unread bar lit for nothing
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
    // The edge strip and the panel are two things that each report the pointer. Moving from the strip onto the panel gives
    // "panel entered" and "strip left" in either order; when the strip's "left" came last it started the close timer while the
    // pointer was on the panel, and the centre closed under it. So each reports into its own flag and only the sum counts.
    property bool stripHover: false
    property bool panelHover: false
    readonly property bool pointerOn: stripHover || panelHover
    onPointerOnChanged: setHover(pointerOn)
    function setHover(on) {
        if (!edgeOn) return
        if (on && asleep) return
        if (!on && cycling) return          // the window is being re-mapped by raise(): that is not the pointer leaving
        if (on) { closeT.stop(); if (!clickMode && !centerOpen && !lockT.running) openT.restart() }
        else { openT.stop(); if (centerOpen && (!clickMode || autoHide)) { closeT.interval = 700; closeT.restart() } }
    }
    onEdgeOnChanged: if (!edgeOn) { openT.stop(); closeT.stop(); centerOpen = false }
    onAsleepChanged: if (asleep) { openT.stop(); closeT.stop(); centerOpen = false }
    function toggleCenter() {
        if (!edgeOn) return
        if (centerOpen) { closeT.stop(); centerOpen = false }
        else { centerOpen = true; if (!clickMode || autoHide) { closeT.interval = 6000; closeT.restart() } }
    }
    Timer { id: openT; interval: 140; onTriggered: root.centerOpen = true }
    Timer { id: lockT; interval: 600 }
    // never close under the pointer: a centre opened from the keyboard (or a timer that was running when the pointer arrived) stays
    // while the pointer is on it; the pointer leaving starts the timer again
    Timer { id: closeT; interval: 700; onTriggered: { if (!root.pointerOn) root.centerOpen = false } }

    // the unread bar used to breathe for as long as anything stayed unread: an endless animation = a new frame on every refresh,
    // all day. It now breathes for a few seconds after each new notification and then rests (the bar itself stays lit).
    property bool breathe: false
    onUnreadChanged: { if (unread > 0) { breathe = true; breatheT.restart() } else breathe = false }
    Timer { id: breatheT; interval: 12000; onTriggered: root.breathe = false }

    onCenterOpenChanged: { if (centerOpen) { unread = 0; hideToasts() } else { openT.stop(); lockT.restart() } }
    onDndChanged: if (dnd) hideToasts()
    onFsQuietChanged: if (fsQuiet) hideToasts()
    onGameQuietChanged: if (gameQuiet) hideToasts()

    // ---------- a new notification ----------
    function add(n) {
        var critical = n.urgency === NotificationUrgency.Critical
        var quiet = dnd || (fsQuiet && n.appName !== "Halcyon")
        var toast = !centerOpen && !gameQuiet && (!quiet || critical)
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
            for (var s = 0; s < stale.length; s++) { delete arrived[stale[s].id]; stale[s].dismiss() }
            for (var k = 0; k < over.length; k++) { delete arrived[over[k].id]; over[k].dismiss() }
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

    // Notifications show on top of everything, the tree view, Settings, the shortcuts... included: while a toast or the centre is
    // showing, this window is on the Overlay layer (the same one those big windows use). Windows that open later land above it,
    // so shell.qml calls raise() when that happens: the window is unmapped for a moment and mapped again, which puts it on top.
    property bool cycling: false
    function raise() { cycling = true; raiseT.restart() }
    Timer { id: raiseT; interval: 60; onTriggered: root.cycling = false }

    property bool surfaceLinger: false
    Connections {
        target: root
        function onCenterOpenChanged() {
            if (root.centerOpen) { root.surfaceLinger = true; surfLingerT.stop() }
            else surfLingerT.restart()
        }
    }
    Timer { id: surfLingerT; interval: root.pal.dSlow + 100; onTriggered: { root.surfaceLinger = false; gc() } }
    readonly property bool needFullSurface: root.centerOpen || root.surfaceLinger || root.toasts.length > 0

    PanelWindow {
        id: win
        visible: !root.cycling
        // a centre that opens from a dragged tag uses the whole screen (the mask keeps all but the box click-through)
        anchors { top: true; bottom: true; right: root.custom ? true : root.atR; left: root.custom ? true : !root.atR }
        // FIXED size on purpose. Shrinking this surface when idle made every open / close / toast re-send the pointer enter / leave
        // on the edge strip, so the centre popped in and out by itself. The mask below keeps the idle surface click-through, and
        // the blur rule ignores the transparent part (ignore_alpha), so an idle surface costs next to nothing.
        implicitWidth: Math.max(root.cardW, root.cfg.width) + 30 + root.pal.boxEdge
        implicitHeight: 900
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-notifs"
        // with the border around the screen the boxes stay UNDER the border (an overlay window would be drawn over it)
        WlrLayershell.layer: (!root.pal.frameOn && (root.toasts.length > 0 || root.centerOpen)) ? WlrLayer.Overlay : WlrLayer.Top

        // only the edge trigger and the cards / centre take clicks; the rest of the strip is click-through
        // one fixed mask (the closed panel sits outside the window): swapping masks on open / close re-sent the pointer
        // enter / leave and could set the centre flickering while the pointer rested on the edge
        mask: Region { regions: [ Region { item: hot }, Region { item: stack }, Region { item: panel } ] }

        // ---------- trigger (screen edge or corner) ----------
        // edge: a strip on the chosen edge (left or right)
        // corner: a small spot in the chosen corner of the screen
        EdgeGrab {
            id: hot
            visible: root.edgeOn
            anchors.right: root.atR ? parent.right : undefined
            anchors.left: !root.atR ? parent.left : undefined
            anchors.top: !root.atB ? parent.top : undefined
            anchors.bottom: root.atB ? parent.bottom : undefined
            anchors.rightMargin: root.pal.insR
            anchors.leftMargin: root.pal.insL
            anchors.topMargin: root.corner ? root.pal.insT : (root.atB ? 0 : (cfg.vpos === "middle" ? Math.round((win.height - 260) / 2) : root.pal.boxTop))
            anchors.bottomMargin: root.corner ? root.pal.insB : (!root.atB ? 0 : (cfg.vpos === "middle" ? Math.round((win.height - 260) / 2) : root.pal.boxTop))
            width: !root.edgeOn || root.asleep || root.customZone ? 0 : root.corner ? (root.clickMode ? 28 : 22) : (root.clickMode ? 16 : 12)
            height: !root.edgeOn || root.asleep || root.customZone ? 0 : root.corner ? (root.clickMode ? 28 : 22) : 260
            clickMode: root.clickMode
            onHoverChanged: on => root.stripHover = on
            onTapped: root.toggleCenter()

            // unread / do-not-disturb hint.
            //   edge mode:   a soft bar on the very edge
            //   corner mode: a small round dot tucked into the corner; it grows a little and turns solid while something is unread (no number)
            Rectangle {
                id: hint
                readonly property bool badge: root.corner && root.unread > 0 && !root.dnd
                anchors.right: root.atR ? parent.right : undefined
                anchors.left: !root.atR ? parent.left : undefined
                anchors.rightMargin: root.atR ? (root.corner ? 6 : 3) : 0
                anchors.leftMargin: !root.atR ? (root.corner ? 6 : 3) : 0
                anchors.top: root.corner ? (!root.atB ? parent.top : undefined) : undefined
                anchors.bottom: root.corner ? (root.atB ? parent.bottom : undefined) : undefined
                anchors.topMargin: root.corner ? (!root.atB ? 6 : 0) : 0
                anchors.bottomMargin: root.corner ? (root.atB ? 6 : 0) : 0
                anchors.verticalCenter: root.corner ? undefined : parent.verticalCenter
                width: root.corner ? (root.centerOpen ? 0 : (badge ? 11 : 8)) : 4
                height: root.corner ? (root.centerOpen ? 0 : (badge ? 11 : 8)) : (root.centerOpen ? 0 : 54)
                radius: root.corner ? height / 2 : 2
                color: root.dnd ? root.pal.muted : root.pal.accent
                border.width: badge ? 1.5 : 0
                border.color: badge ? Qt.alpha(root.pal.line, 0.7) : Qt.alpha(root.pal.bg, 0.35)
                opacity: (!root.centerOpen && (root.unread > 0 || root.dnd || root.clickMode)) ? (root.dnd ? 0.55 : (root.unread > 0 ? 0.95 : 0.22)) : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Behavior on width { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                // breathes while something is unread (edge bar only: the badge stays still so it reads cleanly)
                SequentialAnimation on scale {
                    running: root.breathe && root.unread > 0 && !root.dnd && !root.centerOpen && !root.corner
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) hint.scale = 1
                    NumberAnimation { to: 1.5; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                }
            }
        }

        // ---------- popups ----------
        // ONE rounded box holds every popup: it grows when one arrives and shrinks when one leaves (the cards fold open / shut
        // inside it), so its corners stay round the whole time and nothing jumps
        Item {
            id: stack
            // with the border: the box sits against it (and flares into it)
            x: root.pal.frameOn ? (root.atR ? (win.width - root.cardW - root.pal.frameT) : root.pal.frameT)
                                : (root.atR ? (win.width - root.cardW - 30) : 30)
            y: root.atB ? (win.height - height - (root.pal.cornerOut ? root.pal.frameT : root.pal.frameOn ? root.pal.frameT + 16 : 30))
                        : (root.pal.cornerOut ? root.pal.frameT : root.pal.frameOn ? root.pal.frameT + 16 : root.topY)
            width: root.cardW
            height: col.height

            Glass {
                anchors.fill: parent
                visible: col.height > 1
                pal: root.pal
                joinH: root.pal.frameOn ? (root.atR ? "r" : "l") : ""
                joinV: root.pal.cornerOut ? (root.atB ? "b" : "t") : ""
                earR: 10
                radius: root.pal.rLg
                opacityBody: root.pal.glassSolid - 0.06
            }

            Column {
                id: col
                width: parent.width
                spacing: 0

                Repeater {
                    model: ScriptModel { values: root.toasts }
                    delegate: NotifCard {
                        required property var modelData
                        required property int index
                        // out of the corner: the card next to the screen corner slides in from / out to that corner's border
                        cornerJoin: root.pal.cornerOut ? (root.atB ? (index === root.toasts.length - 1 ? "b" : "") : (index === 0 ? "t" : "")) : ""
                        notif: modelData
                        stacked: root.toasts.length > 1
                        pal: root.pal
                        avatar: root.avatar
                        usePfp: root.usePfp
                        override: root.toastSecs
                        critSecs: root.critSecs
                        stars: root.stars && root.cfg.toastStars
                        fromRight: root.atR
                        width: root.cardW
                        onDismissed: root.dismiss(modelData)
                        onTimedOut: root.toastTimedOut(modelData)
                        onHideAll: root.hideToasts()
                    }
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
            // corner mode pops out of the chosen corner; edge mode slides in from its screen edge
            readonly property real edgeGap: root.pal.frameOn ? root.pal.frameT : root.pal.boxEdge     // flush with the border when there is one
            joinH: root.pal.frameOn ? (root.oVert ? "" : (root.pAtR ? "r" : "l")) : ""
            readonly property bool outCorner: root.pal.cornerOut && root.corner && !root.custom      // the centre only sits in a corner with the Corner trigger
            joinV: root.oVert ? (root.pal.frameOn ? (root.pAtB ? "b" : "t") : "") : (root.oSide ? "" : (outCorner ? (root.atB ? "b" : "t") : ""))
            property real slideY: root.reveal
            Behavior on slideY { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            // out of a corner with the border: along the border too (out of a top / bottom edge it slides by its y, below, so the closed box is always outside the window)
            transform: Translate { y: (!root.custom && panel.outCorner) ? (root.atB ? 1 : -1) * (1 - panel.slideY) * (panel.height + root.pal.frameT + 40) : 0 }
            x: root.oVert ? DS.along(root.origin.pos, win.width, width, root.oMargin)
             : root.pAtR
                ? (win.width - width - edgeGap + (1 - root.reveal) * (width + 40))
                : (edgeGap - (1 - root.reveal) * (width + 40))
            scale: ((root.corner || root.custom) && !root.pal.frameOn) ? 0.97 + 0.03 * root.reveal : 1
            transformOrigin: root.oSide ? (root.pAtR ? Item.Right : Item.Left) : root.oVert ? (root.pAtB ? Item.Bottom : Item.Top)
                           : (root.atB ? (root.atR ? Item.BottomRight : Item.BottomLeft) : (root.atR ? Item.TopRight : Item.TopLeft))
            Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            y: root.oSide ? DS.along(root.origin.pos, win.height, height, root.oMargin)
             : root.oVert ? (root.pAtB ? win.height - height - edgeGap + (1 - panel.slideY) * (height + edgeGap + 40)
                                       : (root.pal.frameOn ? root.pal.frameT : root.pal.boxTop) - (1 - panel.slideY) * (height + root.pal.boxTop + 40))
             : outCorner ? (root.atB ? win.height - height - root.pal.frameT : root.pal.frameT)
             : cfg.vpos === "middle" ? Math.round((win.height - height) / 2)
             : (root.atB || cfg.vpos === "bottom") ? win.height - height - Math.max(8, root.pal.boxTop + cfg.offY)
             : Math.max(8, root.pal.boxTop + cfg.offY)
            opacity: root.pal.frameOn ? 1 : Math.min(1, root.reveal * 1.6)
            visible: root.pal.frameOn ? (root.oVert ? panel.slideY > 0.002 : (root.pAtR ? x < win.width - 1 : x > -width + 1)) : opacity > 0.01
            Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            border.color: root.sysmode === "lockdown" || root.sysmode === "stealth" ? Qt.alpha(root.pal.accent, 0.30) : root.pal.line

            HoverHandler { onHoveredChanged: root.panelHover = hovered }
            MouseArea { z: -1; anchors.fill: parent }      // swallow clicks (under the content, so the buttons keep theirs)

            onDndRequested: on => root.dndRequested(on)
            onClearRequested: root.clearAll()
            onDismissRequested: n => root.dismiss(n)
        }
    }
}
