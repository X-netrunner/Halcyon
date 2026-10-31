import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Pam
import "WidgetData.js" as WD

// Halcyon's own lock screen (replaces hyprlock). A real Wayland session lock (ext-session-lock): the compositor itself
// refuses to show or accept anything else until this unlocks, and if the island crashes the screen STAYS locked
// (from a TTY run `loginctl unlock-session` or restart the island to get back in; the screen is never left open).
//   look      wallpaper-accent constellation (shield / dragon for lockdown / stealth, your profile picture otherwise),
//             big clock, your name + picture, one password pill
//   password  checked by PAM (pam/password.conf = pam_unix, your own login password), Enter submits
//   motion    every key press pops a dot in and flares the constellation, the pill pulses, the whole screen eases in,
//             and the dots ripple while the password is being checked
//   open      SUPER+L, the power menu's Lock, `>lock` in the launcher, scripts/lock.sh (use it as hypridle's lock_cmd)
Scope {
    id: root
    property var pal
    property bool stars: true             // the constellation (Settings > Lock screen: one switch for the lock AND the login screen)
    property int flyCount: 0              // moving stars drifting in this box (0 = none): set by shell.qml from Resource use
    property int flyLoop: 150000          // ms for one slow pass of them
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool splash: true            // Settings > Power & lock > Login splash: play Splash.qml first when this lock screen is the login screen
    property bool splashSound: false      // Settings > Splash, sky & time of day > Soft sounds: a quiet chime goes with the login splash
    property real splashDim: 0.75         // Settings > Splash, sky & time of day > Darken the screen during the splash
    property bool splashArm: false        // set by shell.qml for the lock that starts the session (lock-on-start); cleared when it unlocks
    property bool splashSkip: false       // set by shell.qml: you were away less than splashAwayMin, so the login lock comes up without the splash
    readonly property bool splashWanted: splash && splashArm && !splashSkip && pal && pal.motion > 0.3
    property string name: ""            // display name (profile name or login)
    property string avatarPath: ""
    property bool locked: false
    // ---- extras on the lock screen (all fed by shell.qml; "Lock screen widgets" / "Switch user button" in Settings > Power & lock)
    property bool plain: false            // set by shell.qml (Settings > Power & lock > After sleep = Login-screen look): no widgets of any kind
    property bool widgets: false          // battery / Wi-Fi / notification count (a COUNT only, never the text) and the media card
    property bool allowSwitch: false      // the "Switch user" button
    property var player: null             // the MPRIS player the island already follows (null = nothing playing)
    property bool hasBat: false
    property int batPct: 0
    property bool batCharging: false
    property string ssid: ""
    property int notifCount: 0
    // ---- the widgets you built for this screen (Settings > Appearance > Widget builder > Lock screen; placed with the desktop editor)
    // They only SHOW things: shell.qml hands over `lockEnv` (the same numbers, but every action does nothing), and each widget has a click shield
    // (WidgetHost.inert). Every widget type may be here; WidgetData.js marks the private ones where you add them.
    property var deskOpt: ({})            // the shell's settings: opt.lockDeskWidgets (the list) and opt.lockDeskWidgetsOn (the switch)
    property var deskEnv: null            // shell.qml lockEnv
    property real deskLum: 0.05           // how bright this screen's background is (shell.qml lockBackLum), for the widgets' readability colours
    readonly property var deskLayout: locked ? WD.normalizeFor(deskOpt ? deskOpt.lockDeskWidgets : null, "lock") : ({ items: [] })
    readonly property bool deskShow: !plain && locked && deskEnv !== null && WD.isOn(deskOpt, "lock") && deskLayout.items.length > 0
    // what you placed: the lock screen's own battery / Wi-Fi line and media card step aside for a widget of the same kind
    readonly property var deskTypes: deskShow ? WD.typeSet(deskLayout) : ({})
    property var sessions: []             // other sessions on this seat: [{ id, user, tty }] (scripts/switch-user.sh list)
    property bool switchOpen: false
    readonly property string switchScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/switch-user.sh"
    function mediaAct(a) {
        var p = player
        if (!p) return
        if (a === "prev") {
            if (p.canGoPrevious && typeof p.previous === "function") p.previous()
            else if (typeof p.previous === "function") p.previous()
        } else if (a === "next") {
            if (p.canGoNext && typeof p.next === "function") p.next()
            else if (typeof p.next === "function") p.next()
        } else {
            if (p.canTogglePlaying && typeof p.togglePlaying === "function") p.togglePlaying()
            else if (typeof p.togglePlaying === "function") p.togglePlaying()
            else if (p.isPlaying && typeof p.pause === "function") p.pause()
            else if (!p.isPlaying && typeof p.play === "function") p.play()
        }
    }
    Process {
        id: sessList
        command: [root.switchScript, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], L = text.split("\n")
                for (var i = 0; i < L.length; i++) {
                    var f = L[i].split("\t")
                    if (f.length >= 2 && f[0] !== "") out.push({ id: f[0], user: f[1], tty: f.length > 2 ? f[2] : "" })
                }
                root.sessions = out
            }
        }
    }
    Process {
        id: swRun
        property var args: ["greeter"]
        command: [root.switchScript].concat(args)
    }
    function switchTo(id) {       // id "" = a login screen for someone else
        switchOpen = false
        swRun.command = [root.switchScript].concat(id === "" ? ["greeter"] : ["to", id])
        swRun.running = true
    }

    // background: "solid" = the theme colour (pal.bg); "wallpaper" = the current wallpaper, blurred, with a sheet of the
    // theme colour over it. The sheet's opacity (tint) is the user's: 0 shows the wallpaper as it is. "sky" = LiveSky.qml without the mark.
    property string bgMode: "solid"
    property string wallpaper: ""         // path of the wallpaper on screen (Wallpaper.qml currentPath)
    property real blurRadius: 40          // 4 .. 64
    property real tint: 0.55              // 0 .. 0.95
    readonly property bool useWall: bgMode === "wallpaper" && wallpaper !== ""
    // the picture's address: a space, %, # or ? in the file name must not break it (same rule as the Desktop builder's preview)
    readonly property string wallUrl: wallpaper === "" ? "" : "file://" + encodeURI(wallpaper).replace(/#/g, "%23").replace(/\?/g, "%3F")

    // shared by every screen's surface
    property string buffer: ""
    property bool busy: false
    property string failure: ""
    property int shakeTick: 0

    // 0..1 flare handed to the constellation; every key press kicks it and it settles by itself
    property real energy: 0
    property int kickTick: 0
    function kick(strong) { energy = strong ? 1.0 : 0.65; kickTick++; energyDecay.restart() }
    NumberAnimation { id: energyDecay; target: root; property: "energy"; to: 0; duration: 1100; easing.type: Easing.OutCubic }

    // Wrong-password backoff: the first two misses cost nothing, then 2 s, 4 s, 8 s ... capped at 60 s. It is kept across
    // lock/unlock cycles (re-locking must not reset it) and cleared only by a correct password.
    property int fails: 0
    property real waitUntil: 0            // Date.now() (ms) before which no new attempt is checked
    property int waitLeft: 0              // seconds shown to the person
    function cooldownText() { return "Too many attempts. Wait " + waitLeft + " s" }
    Timer {
        id: cooldownT
        interval: 250; repeat: true
        onTriggered: {
            var left = Math.ceil((root.waitUntil - Date.now()) / 1000)
            if (left <= 0) { root.waitLeft = 0; root.failure = ""; stop() }
            else { root.waitLeft = left; root.failure = root.cooldownText() }
        }
    }
    function startCooldown() {
        if (fails < 3) return
        var secs = Math.min(60, Math.pow(2, fails - 2))      // 3 misses -> 2 s, 4 -> 4 s, 5 -> 8 s ...
        waitUntil = Date.now() + secs * 1000
        waitLeft = secs
        failure = cooldownText()
        cooldownT.restart()
    }

    function lock() {
        buffer = ""
        busy = false
        locked = true
        if (Date.now() < waitUntil) {
            waitLeft = Math.ceil((waitUntil - Date.now()) / 1000)
            failure = cooldownText()
            cooldownT.restart()
        } else {
            failure = ""
        }
    }
    function tryUnlock() {
        if (busy || buffer === "") return
        if (Date.now() < waitUntil) { buffer = ""; shakeTick++; return }      // still cooling down: do not even ask PAM
        busy = true
        failure = ""
        pam.start()
    }

    PamContext {
        id: pam
        configDirectory: Quickshell.shellPath("pam")
        config: "password.conf"
        onPamMessage: { if (responseRequired) respond(root.buffer) }
        onCompleted: result => {
            root.busy = false
            root.buffer = ""
            if (result === PamResult.Success) {
                root.failure = ""
                root.fails = 0
                root.waitUntil = 0
                cooldownT.stop()
                root.locked = false
            } else {
                root.fails++
                root.failure = "Wrong password"
                root.shakeTick++
                root.kick(true)
                root.startCooldown()
            }
        }
        // a PAM error is not a guess, so it does not count as a miss
        onError: err => { root.busy = false; root.buffer = ""; root.failure = "Could not check the password"; root.shakeTick++ }
    }
    onLockedChanged: { switchOpen = false; if (!locked) { buffer = ""; failure = ""; busy = false; splashArm = false; splashSkip = false; pam.abort() } }

    SystemClock { id: clock; precision: SystemClock.Seconds }

    LazyLoader {
        active: root.locked
        WlSessionLock {
            locked: root.locked

            WlSessionLockSurface {
                id: surf
            color: root.pal.bg

            // the whole screen eases in when it locks
            // (with the login splash on, it starts when the splash hands over, so the splash plays on the bare, already locked surface)
            property real appear: 0
            NumberAnimation { id: appearAnim; target: surf; property: "appear"; from: 0; to: 1; duration: 1100; easing.type: Easing.OutCubic }
            Component.onCompleted: {
                if (root.splashWanted) {
                    splashItem.start()
                    // asked every time: at login this runs before the island has read its settings (root.splashSound is still the
                    // default), so the script reads the switch itself, and waits for PipeWire to have an output
                    Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/splash-sound.sh", "login", "--if-on", "--wait"])
                } else appearAnim.start()
            }

            // ---- blurred wallpaper (only exists while locked and only when chosen in Settings > Power & lock)
            // The blur sits in its own layer, so it is drawn once and kept as a texture, not redone every frame the stars move.
            // It is only drawn once the picture has really loaded. Until then, and for good if the file is missing or cannot be read,
            // the plain theme colour of the surface stays: exactly the "Solid colour" look, with no empty full-screen texture behind it.
            // When the picture arrives (the wallpaper path is known a moment later at login, or the wallpaper changes while locked)
            // it fades in instead of popping.
            Item {
                id: wallBox
                anchors.fill: parent
                readonly property bool ready: root.useWall && wallImg.status === Image.Ready
                property real fadeIn: ready ? 1 : 0
                Behavior on fadeIn { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                visible: fadeIn > 0.001
                opacity: surf.appear * fadeIn
                layer.enabled: ready
                Image {
                    id: wallImg
                    anchors.fill: parent
                    visible: false
                    asynchronous: true
                    cache: false          // like Wallpaper.qml: the decoded picture is not kept by Qt once this screen is gone
                    fillMode: Image.PreserveAspectCrop
                    // decode at the screen's size, like Wallpaper.qml does, not at the picture's own (maybe 4K) size.
                    // Empty again the moment the lock ends, so the picture is let go before the surface itself is torn down.
                    source: root.useWall && root.locked && surf.width > 0 ? root.wallUrl : ""
                    sourceSize: Qt.size(Math.max(1, Math.round(surf.width)), Math.max(1, Math.round(surf.height)))
                }
                MultiEffect {
                    anchors.fill: parent
                    source: wallImg
                    visible: wallImg.status === Image.Ready
                    autoPaddingEnabled: false
                    blurEnabled: true
                    blurMax: Math.max(4, Math.min(64, Math.round(root.blurRadius)))
                    blur: 1.0
                }
                // theme-colour sheet: this is the "opacity" of the lock screen
                Rectangle { anchors.fill: parent; color: root.pal.bg; opacity: root.tint }
            }

            // ---- Halcyon sky (Lock screen background: Halcyon sky): the splash's stars keep drifting behind the clock, so the login splash
            // hands over to the same sky. Stars only: the clock and the password box sit where the sparkle would be.
            Loader {
                anchors.fill: parent
                active: root.bgMode === "sky" && root.locked
                opacity: surf.appear
                sourceComponent: LiveSky { pal: root.pal; showMark: false }
            }

            // ---- constellation + drifting dots (same quiet look as everything else)
            Backdrop {
                visible: root.locked && root.stars
                anchors.fill: parent
                pal: root.pal
                mode: root.sysmode
                avatarStars: root.starData
                profileStars: root.profileStars
                dots: 34
                artStrength: 0.9
                artFit: 0.78
                energy: root.energy
                opacity: surf.appear
            }
            BarStars {
                anchors.fill: parent
                anchors.margins: 24
                pal: root.pal
                count: root.flyCount
                loopMs: root.flyLoop
                sizeScale: 1.5
                active: root.locked
                visible: root.locked && root.flyCount > 0
                opacity: surf.appear
            }
            // (no vignette gradient here: bg-over-bg with varying alpha is invisible in theory but Qt's 8-bit premultiplied
            // vertex colours round per row, which showed up as colour bands on a solid background)

            // any mouse movement / click on the lock screen hands keyboard focus to the password box
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.AllButtons
                onPositionChanged: input.forceActiveFocus()
                onPressed: { root.switchOpen = false; input.forceActiveFocus() }
            }

            // ---- your widgets (above the focus catcher, so the music buttons can be clicked; below the clock and the password, which always win)
            Loader {
                anchors.fill: parent
                active: root.deskShow
                opacity: surf.appear
                sourceComponent: DeskWidgets {
                    anchors.fill: parent
                    pal: root.pal
                    env: root.deskEnv
                    opt: root.deskOpt
                    target: "lock"
                    inert: true
                    lockLum: root.deskLum
                    topInset: 24
                }
            }

            // ---- clock
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height * 0.16 - 22 * (1 - surf.appear)
                opacity: surf.appear
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, "HH:mm")
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 112
                    font.weight: Font.Light
                    font.letterSpacing: 2
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, "dddd, d MMMM")
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tTitle + 3
                    font.letterSpacing: 1
                }
            }

            // ---- you + password
            Column {
                id: who
                anchors.horizontalCenter: parent.horizontalCenter
                readonly property real late: Math.max(0, Math.min(1, (surf.appear - 0.3) / 0.7))
                y: parent.height * 0.52 + 22 * (1 - late)
                opacity: late
                spacing: 18

                // profile picture in a ring (falls back to an initial)
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 104; height: 104
                    // a slow ripple leaves the picture while you are idle (dimmer once you start typing)
                    Rectangle {
                        id: ripple
                        anchors.fill: parent; radius: width / 2
                        color: "transparent"
                        border.width: 1.5; border.color: Qt.alpha(root.pal.accent, 0.6)
                        ParallelAnimation {
                            loops: Animation.Infinite
                            running: root.locked && root.pal.motion > 0.3
                            NumberAnimation { target: ripple; property: "scale"; from: 1.0; to: 1.5; duration: 2800; easing.type: Easing.OutCubic }
                            NumberAnimation { target: ripple; property: "opacity"; from: 0.55; to: 0; duration: 2800; easing.type: Easing.OutQuad }
                        }
                    }
                    // ...and every key press sends a ring out of the picture, in step with the constellation: the same kick()
                    // that flares the stars fires it, and a stronger flare (a wrong password: the strongest) makes it bigger,
                    // brighter and red. Three rings take turns, so fast typing gives overlapping rings instead of restarts.
                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            id: keyRing
                            required property int index
                            anchors.fill: parent; radius: width / 2
                            color: "transparent"
                            border.width: 2
                            border.color: root.failure !== "" ? root.pal.bad : root.pal.accent
                            opacity: 0
                            ParallelAnimation {
                                id: keyRingAnim
                                NumberAnimation { target: keyRing; property: "scale"; from: 1.0; to: 1.45 + 0.45 * root.energy; duration: 820; easing.type: Easing.OutCubic }
                                NumberAnimation { target: keyRing; property: "opacity"; from: 0.45 + 0.45 * root.energy; to: 0; duration: 820; easing.type: Easing.OutQuad }
                            }
                            Connections {
                                target: root
                                function onKickTickChanged() { if (root.kickTick % 3 === keyRing.index) keyRingAnim.restart() }
                            }
                        }
                    }
                    // the picture's own rim glows with the same flare as the constellation
                    Rectangle {
                        anchors.fill: parent; radius: width / 2
                        color: root.pal.box(Qt.alpha(root.pal.surface, 0.9))
                        border.width: 2
                        border.color: Qt.alpha(root.failure !== "" ? root.pal.bad : root.pal.accent, 0.55 + 0.45 * root.energy)
                    }
                    Item {
                        id: avBox
                        anchors.centerIn: parent
                        width: 92; height: 92
                        layer.enabled: true
                        layer.effect: MultiEffect { maskEnabled: true; maskSource: avMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                        Image {
                            id: avImg
                            anchors.fill: parent
                            source: root.avatarPath !== "" ? "file://" + root.avatarPath : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize: Qt.size(184, 184)      // shown at 92 px: decode at 2x, not at the picture's own size
                            visible: status === Image.Ready
                        }
                    }
                    Item { id: avMask; width: 92; height: 92; visible: false; layer.enabled: true
                        Rectangle { anchors.fill: parent; radius: width / 2; color: "black" } }
                    Text {
                        anchors.centerIn: parent
                        visible: avImg.status !== Image.Ready
                        text: (root.name || "?").charAt(0).toUpperCase()
                        color: root.pal.accent
                        font.family: root.pal.uiFont
                        font.pixelSize: 40
                        font.weight: Font.DemiBold
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.name
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tDisplay
                    font.weight: Font.DemiBold
                }

                // password pill (shakes on a wrong password)
                Rectangle {
                    id: pill
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 340; height: 48; radius: height / 2
                    color: root.pal.box(Qt.alpha(root.pal.surface, 0.85))
                    border.width: 1
                    border.color: root.failure !== "" ? root.pal.bad : (input.activeFocus ? root.pal.lineFocus : root.pal.line)
                    Behavior on border.color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

                    SequentialAnimation {
                        id: shake
                        NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: -14; duration: 50 }
                        NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: 14; duration: 90 }
                        NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: -8; duration: 80 }
                        NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: 0; duration: 60 }
                    }
                    Connections { target: root; function onShakeTickChanged() { shake.restart() } }

                    // a ring leaves the pill on every key press
                    Rectangle {
                        id: ring
                        anchors.fill: parent; radius: parent.radius
                        color: "transparent"
                        border.width: 2
                        border.color: root.failure !== "" ? root.pal.bad : root.pal.accent
                        opacity: 0
                        ParallelAnimation {
                            id: ringAnim
                            NumberAnimation { target: ring; property: "scale"; from: 1.0; to: 1.14; duration: 440; easing.type: Easing.OutCubic }
                            NumberAnimation { target: ring; property: "opacity"; from: 0.55; to: 0; duration: 440; easing.type: Easing.OutQuad }
                        }
                    }
                    Connections { target: root; function onKickTickChanged() { ringAnim.restart() } }

                    // the password as dots: each one pops in with a little overshoot; they ripple while PAM checks
                    property real wave: 0
                    NumberAnimation on wave { from: 0; to: 6.2832; duration: 900; loops: Animation.Infinite; running: root.busy }
                    Row {
                        id: dotRow
                        anchors.centerIn: parent
                        spacing: 9
                        Repeater {
                            model: Math.min(root.buffer.length, 16)
                            delegate: Rectangle {
                                required property int index
                                width: 9; height: 9; radius: 4.5
                                color: root.failure !== "" ? root.pal.bad : root.pal.text
                                NumberAnimation on scale { from: 0.2; to: 1; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.4 }
                                NumberAnimation on opacity { from: 0; to: 1; duration: 150 }
                                transform: Translate { y: root.busy ? -4 * Math.sin(pill.wave - index * 0.7) : 0 }
                            }
                        }
                    }

                    TextInput {
                        id: input
                        anchors.fill: parent
                        anchors.leftMargin: 22; anchors.rightMargin: 22
                        verticalAlignment: TextInput.AlignVCenter
                        horizontalAlignment: TextInput.AlignHCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        color: "transparent"            // the dots above are the visible password
                        selectionColor: "transparent"
                        selectedTextColor: "transparent"
                        cursorVisible: false
                        cursorDelegate: Item {}
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tTitle + 2
                        enabled: !root.busy
                        focus: true
                        text: root.buffer
                        onTextEdited: { root.buffer = text; root.kick(false) }
                        onAccepted: root.tryUnlock()
                        Component.onCompleted: forceActiveFocus()
                        Connections { target: root; function onLockedChanged() { if (root.locked) input.forceActiveFocus() } }
                        Connections {
                            target: root
                            function onBufferChanged() {
                                if (input.text !== root.buffer) input.text = root.buffer
                            }
                        }
                        // the lock surface only receives keyboard focus after the compositor maps it, which is later than
                        // Component.onCompleted: retry until the box really has focus, and re-take it whenever it is lost
                        Timer {
                            interval: 80; repeat: true
                            running: root.locked && !input.activeFocus
                            onTriggered: input.forceActiveFocus()
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: root.buffer === "" && !root.busy
                        text: "Password"
                        color: Qt.alpha(root.pal.text, 0.35)
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody + 1
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 18
                    text: root.busy ? "Checking…" : root.failure
                    color: root.failure !== "" && !root.busy ? root.pal.bad : root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap + 1
                }
            }

            // ---- status row, top right: battery, Wi-Fi, how many notifications (never what they say)
            Row {
                visible: root.widgets
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 28
                anchors.rightMargin: 32
                spacing: 20
                opacity: surf.appear
                Text {
                    visible: root.hasBat && root.deskTypes.battery !== true
                    text: root.batPct + "%" + (root.batCharging ? " · charging" : "")
                    color: root.batPct <= 15 && !root.batCharging ? root.pal.bad : root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap + 2
                }
                Text {
                    visible: root.ssid !== "" && root.deskTypes.net !== true
                    text: root.ssid
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap + 2
                }
                Text {
                    visible: root.notifCount > 0
                    text: root.notifCount + (root.notifCount === 1 ? " notification" : " notifications")
                    color: root.pal.accent
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap + 2
                }
            }

            // ---- media card, bottom centre: what is playing + previous / play-pause / next
            Rectangle {
                id: mediaCard
                visible: root.widgets && root.deskTypes.music !== true && root.player !== null && root.player !== undefined && (root.player.trackTitle || "") !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 64
                width: 380; height: 64; radius: 18
                color: root.pal.box(Qt.alpha(root.pal.surface, 0.8))
                border.width: root.pal.bw
                border.color: root.pal.line
                opacity: surf.appear
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 18
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 160
                    spacing: 2
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.player ? (root.player.trackTitle || "") : ""
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody
                        font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.player ? (root.player.trackArtist || "") : ""
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tCap + 1
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Repeater {
                        model: [ { t: "‹", a: "prev" }, { t: (root.player && root.player.isPlaying) ? "II" : "▶", a: "toggle" }, { t: "›", a: "next" } ]
                        delegate: Rectangle {
                            width: 38; height: 38; radius: 19
                            color: mediaMa.containsMouse ? Qt.alpha(root.pal.accent, 0.25) : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: modelData.t
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: modelData.a === "toggle" ? root.pal.tBody : root.pal.tTitle + 4
                            }
                            MouseArea { id: mediaMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.mediaAct(modelData.a) }
                        }
                    }
                }
            }

            // ---- Switch user, bottom left: other logged-in users (scripts/switch-user.sh) and a login screen for someone else.
            // This screen stays locked while you are away; coming back to it needs this account's password again.
            Item {
                visible: root.allowSwitch
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: 32
                anchors.bottomMargin: 30
                width: swCol.width
                height: swCol.height
                opacity: surf.appear
                Column {
                    id: swCol
                    spacing: 8
                    Rectangle {
                        visible: root.switchOpen
                        width: 230
                        height: swList.height + 16
                        radius: 14
                        color: root.pal.box(Qt.alpha(root.pal.surface, 0.92))
                        border.width: root.pal.bw
                        border.color: root.pal.line
                        Column {
                            id: swList
                            x: 8; y: 8
                            width: parent.width - 16
                            spacing: 2
                            Repeater {
                                model: root.sessions
                                delegate: Rectangle {
                                    width: swList.width; height: 34; radius: 10
                                    color: swMa.containsMouse ? Qt.alpha(root.pal.accent, 0.2) : "transparent"
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: 10
                                        text: modelData.user + (modelData.tty !== "" ? "  ·  " + modelData.tty : "")
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                    }
                                    MouseArea { id: swMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.switchTo(modelData.id) }
                                }
                            }
                            Rectangle {
                                width: swList.width; height: 34; radius: 10
                                color: swNewMa.containsMouse ? Qt.alpha(root.pal.accent, 0.2) : "transparent"
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: 10
                                    text: "Log in as someone else"
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                }
                                MouseArea { id: swNewMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.switchTo("") }
                            }
                        }
                    }
                    Rectangle {
                        width: 124; height: 34; radius: 17
                        color: swChipMa.containsMouse || root.switchOpen ? Qt.alpha(root.pal.accent, 0.22) : Qt.alpha(root.pal.surface, 0.7)
                        border.width: root.pal.bw
                        border.color: root.pal.line
                        Text {
                            anchors.centerIn: parent
                            text: "Switch user"
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap + 1
                        }
                        MouseArea {
                            id: swChipMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: { root.switchOpen = !root.switchOpen; if (root.switchOpen) sessList.running = true }
                        }
                    }
                }
            }

            // sysmode tag, bottom centre
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 36
                visible: root.sysmode !== ""
                text: root.pal.zen ? "Sysmode · " + root.sysmode : "SYSMODE · " + root.sysmode.toUpperCase()
                color: Qt.alpha(root.pal.accent, 0.7)
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.zen ? 12 : 10
                font.weight: root.pal.zen ? Font.Medium : Font.DemiBold
                font.letterSpacing: root.pal.zen ? 0.2 : 2
            }

            // ---- the login splash: above everything, on this locked surface; typing or a click skips it
            Splash {
                id: splashItem
                anchors.fill: parent
                z: 100
                pal: root.pal
                dim: root.splashDim
                onHandoff: appearAnim.restart()
            }
            Connections { target: root; function onBufferChanged() { if (root.buffer !== "") splashItem.skip() } }
        }
    }
}
}
