import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd

// Halcyon's login screen (a greetd greeter). Installed by scripts/halcyon-greeter.sh, started by greetd as
//     cage -s -d -- quickshell -p /usr/local/share/halcyon-greeter
// It is the lock screen's twin: the same layout, sizes, fonts, colours, the same constellation art (Backdrop / ModeArt / BarStars are the
// island's own files, copied here by the installer) and the same password pill. The island writes everything it needs to look the same
// (palette, fonts, sizes, your picture's constellation, the lock screen's background settings) to ~/.cache/island/greeter-look.json;
// `halcyon-greeter.sh sync` copies it to /var/lib/halcyon-greeter/theme.json, which this greeter reads.
//
//   security   it runs as the unprivileged `greeter` user and never reads your home. Users come from `getent`, sessions from the
//              root-owned /usr/share/wayland-sessions. theme.json (yours) only DECORATES: it cannot name a user, a session or a
//              command, and pictures load only from the greeter's own data folder.
//   keys       type the password, Enter logs in, Left / Right (empty box) change user, Tab changes session, Esc clears
//   switch     bottom left: "Switch user" and the session (desktop) chip open a list to pick from, like the lock screen's Switch user
//   no widgets the Widget builder's widgets exist on the lock screen only
//   try it     scripts/halcyon-greeter.sh preview   (a window in your desktop, nothing is logged in; the password is "preview")
//   safety     a crash is restarted by greetd; Ctrl+Alt+F2 is always a plain text login
FloatingWindow {
    id: win
    visible: true
    title: "Halcyon login"
    color: pal.bg

    readonly property bool preview: Quickshell.env("HALCYON_GREETER_PREVIEW") === "1"
    readonly property string dir: Quickshell.env("HALCYON_GREETER_DIR") || "/var/lib/halcyon-greeter"

    // ---------------------------------------------------------------- the look (a stand-in for the island's Pal, filled from theme.json)
    QtObject {
        id: pal
        property bool zen: true
        property bool calm: true
        property bool solid: false
        property color bg: "#14161f"
        property color surface: "#1e2130"
        property color accent: "#9aa9d4"
        property color accent2: "#c2add8"
        property color text: "#dcdde8"
        property color muted: "#9496a8"
        property color bad: "#e58a8a"
        property color boxFill: "#08ffffff"
        property color line: "#11ffffff"
        property color lineFocus: "#8c9aa9d4"
        property color ringFill: "#e61e2130"
        property string uiFont: "sans-serif"
        property int tCap: 11
        property int tBody: 13
        property int tTitle: 18
        property int tDisplay: 24
        property int dFast: 140
        property real motion: 1
        property real decor: 0.35
        property real starSlow: 1
        property real growth: 0
        property bool growthOn: true
        property int artQuality: 2
        property int artFps: 0
        property bool gpuLines: true
    }
    // the lock screen's own settings, plus the greeter's small switches (Settings > Login screen)
    property bool optStars: true          // the constellation: the SAME switch as the lock screen's (opt.starsLock)
    property bool optAvatar: true
    property bool optClock: true
    property bool optSeconds: false
    property bool optPower: true
    property bool optSession: true
    property bool optBattery: false
    property bool optWifi: false
    property int flyCount: 0
    property int flyLoop: 150000
    property string sysmode: ""
    property bool profileStars: true
    property var starData: null
    property string lookName: ""          // the display name of the user who synced (profile name), shown for that user
    property string lookUser: ""
    property string wallpaper: ""
    property string bgMode: "solid"       // solid | wallpaper | sky: the lock screen's background (sky = the same drifting stars)
    property real blurRadius: 40
    property real tint: 0.55

    property var users: []            // [{ name, full }]
    property var sessions: []         // [{ name, exec, desk, id }]
    property var avatars: ({})        // { name: path }, checked by okPath()
    property int userIdx: 0
    property int sessIdx: 0
    property string lastUser: ""
    property string lastSession: ""

    function okPath(p) {      // pictures only from the greeter's data folder (or AccountsService's icons), never anywhere else
        if (typeof p !== "string" || p === "" || p.indexOf("..") >= 0) return false
        return p.indexOf(win.dir + "/") === 0 || p.indexOf("/var/lib/AccountsService/icons/") === 0
    }
    function fileUrl(p) { return "file://" + encodeURI(p).replace(/#/g, "%23").replace(/\?/g, "%3F") }

    FileView { id: themeFile; path: win.dir + "/theme.json"; blockLoading: true }
    FileView { id: lastFile;  path: win.dir + "/state/last.json"; blockLoading: true }

    function loadTheme() {
        var j = {}
        try { j = JSON.parse(themeFile.text()) } catch (e) { j = {} }
        var L = (j.look && typeof j.look === "object") ? j.look : {}
        var cols = ["bg", "surface", "accent", "accent2", "text", "muted", "bad", "boxFill", "line", "lineFocus", "ringFill"]
        var hex = function (v) { return typeof v === "string" && /^#[0-9A-Fa-f]{6,8}$/.test(v) }
        // the lock screen's own look first; the wallpaper palette (top level of theme.json) until the island has written that look
        for (var i = 0; i < cols.length; i++) {
            if (hex(L[cols[i]])) pal[cols[i]] = L[cols[i]]
            else if (hex(j[cols[i]])) pal[cols[i]] = j[cols[i]]
        }
        var bools = ["zen", "calm", "solid", "growthOn", "gpuLines"]
        for (var b = 0; b < bools.length; b++) if (typeof L[bools[b]] === "boolean") pal[bools[b]] = L[bools[b]]
        var nums = ["tCap", "tBody", "tTitle", "tDisplay", "motion", "decor", "starSlow", "growth", "artQuality", "artFps"]
        for (var n = 0; n < nums.length; n++) if (typeof L[nums[n]] === "number" && isFinite(L[nums[n]])) pal[nums[n]] = L[nums[n]]
        if (typeof j.font === "string" && j.font !== "") pal.uiFont = j.font
        // the island's wallpaper background (lock screen settings); sky / solid = the plain theme colour
        if (okPath(j.wallpaper)) wallpaper = j.wallpaper
        if (j.bgMode === "solid" || j.bgMode === "wallpaper" || j.bgMode === "sky") bgMode = j.bgMode
        if (typeof j.blur === "number") blurRadius = Math.max(4, Math.min(64, j.blur))
        if (typeof j.tint === "number") tint = Math.max(0, Math.min(0.95, j.tint))
        var sw = { stars: "optStars", avatar: "optAvatar", clock: "optClock", seconds: "optSeconds", power: "optPower", session: "optSession", battery: "optBattery", wifi: "optWifi" }
        for (var k in sw) if (typeof j[k] === "boolean") win[sw[k]] = j[k]
        if (typeof L.flyCount === "number") flyCount = Math.max(0, Math.min(40, Math.round(L.flyCount)))
        if (typeof L.flyLoop === "number" && L.flyLoop > 1000) flyLoop = L.flyLoop
        if (typeof L.sysmode === "string" && /^[a-z-]{0,20}$/.test(L.sysmode)) sysmode = L.sysmode
        if (typeof L.profileStars === "boolean") profileStars = L.profileStars
        if (L.starData && typeof L.starData === "object" && L.starData.stars) starData = L.starData
        if (typeof L.name === "string") lookName = L.name.slice(0, 60)
        if (typeof L.user === "string") lookUser = L.user
        if (j.avatars && typeof j.avatars === "object") avatars = j.avatars
        var l = {}
        try { l = JSON.parse(lastFile.text()) } catch (e2) { l = {} }
        lastUser = typeof l.user === "string" ? l.user : ""; lastSession = typeof l.session === "string" ? l.session : ""
    }
    function pickLast() {
        for (var u = 0; u < users.length; u++) if (users[u].name === lastUser) userIdx = u
        for (var s = 0; s < sessions.length; s++) if (sessions[s].name === lastSession) sessIdx = s
    }
    Component.onCompleted: { loadTheme(); appearAnim.start(); input.forceActiveFocus() }

    Process {
        id: usersP
        running: true
        command: ["sh", Quickshell.shellPath("users.sh")]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], L = text.split("\n")
                for (var i = 0; i < L.length; i++) {
                    var f = L[i].split("\t")
                    if (f[0] && /^[A-Za-z0-9_.-]+$/.test(f[0])) out.push({ name: f[0], full: f[1] || "" })
                }
                if (out.length === 0 && win.lastUser !== "") out.push({ name: win.lastUser, full: "" })
                win.users = out; win.pickLast()
            }
        }
    }
    Process {
        id: sessP
        running: true
        command: ["sh", Quickshell.shellPath("sessions.sh")]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], L = text.split("\n")
                for (var i = 0; i < L.length; i++) {
                    var f = L[i].split("\t")
                    if (f[0] && f[1]) out.push({ name: f[0], exec: f[1], desk: /^[A-Za-z0-9_.;:-]*$/.test(f[2] || "") ? (f[2] || "") : "",
                                                 id: /^[A-Za-z0-9_.@-]+$/.test(f[3] || "") ? f[3] : "" })
                }
                out.sort(function (a, b) { return (a.name === "Halcyon" ? 0 : 1) - (b.name === "Halcyon" ? 0 : 1) || (a.name < b.name ? -1 : 1) })
                if (out.length === 0) out.push({ name: "Halcyon", exec: "/usr/local/bin/start-halcyon", desk: "Hyprland", id: "halcyon" })
                win.sessions = out; win.pickLast()
            }
        }
    }

    readonly property var curUser: users.length > 0 ? users[userIdx] : ({ name: "", full: "" })
    readonly property string shownName: (curUser.name === lookUser && lookName !== "") ? lookName : (curUser.full && curUser.full !== "" ? curUser.full : curUser.name)
    readonly property string curAvatar: (avatars && okPath(avatars[curUser.name])) ? avatars[curUser.name] : ""
    readonly property var curSess: sessions.length > 0 ? sessions[sessIdx] : ({ name: "Halcyon", exec: "/usr/local/bin/start-halcyon", desk: "Hyprland", id: "halcyon" })
    function avatarOf(name) { return (avatars && okPath(avatars[name])) ? avatars[name] : "" }
    function nameOf(u) { return (u.name === lookUser && lookName !== "") ? lookName : (u.full && u.full !== "" ? u.full : u.name) }

    // ---------------------------------------------------------------- login state
    property bool busy: false
    property string failure: ""
    property string notice: ""          // a message from PAM (for example a second prompt)
    property string pending: ""
    property string buffer: ""
    property int fails: 0
    property real waitUntil: 0
    property int shakeTick: 0
    property int kickTick: 0
    property real energy: 0
    property bool leaving: false
    property real exitT: 0
    function kick(strong) { energy = strong ? 1.0 : 0.65; kickTick++; energyDecay.restart() }
    NumberAnimation { id: energyDecay; target: win; property: "energy"; to: 0; duration: 1100; easing.type: Easing.OutCubic }

    function resetAuth() {          // drop a half-finished PAM conversation: nothing is kept waiting for a password
        pending = ""; notice = ""; busy = false; buffer = ""
        if (!win.preview && Greetd.state !== GreetdState.Inactive) Greetd.cancelSession()
    }
    function cycleUser(d) {
        if (users.length < 2 || busy || leaving) return
        resetAuth(); userIdx = (userIdx + d + users.length) % users.length
        failure = ""; kick(false)
        for (var s = 0; s < sessions.length; s++) if (sessions[s].name === lastSession && curUser.name === lastUser) sessIdx = s
    }
    function cycleSession(d) { if (sessions.length > 1) sessIdx = (sessIdx + d + sessions.length) % sessions.length }

    function submit() {
        if (busy || leaving) return
        if (Date.now() < waitUntil) { buffer = ""; shakeTick++; return }
        var pw = buffer
        if (pw === "" && notice === "") return
        if (curUser.name === "") { failure = "No user to log in"; shakeTick++; return }
        if (win.preview) {
            buffer = ""
            if (pw === "preview") startLeave(); else wrong("Wrong password (preview: type \"preview\")")
            return
        }
        failure = ""
        // the next question of a PAM chain (a token, say): the session already exists, only answer it
        if (Greetd.state === GreetdState.Authenticating && notice !== "") { busy = true; notice = ""; buffer = ""; Greetd.respond(pw); idleT.restart(); return }
        busy = true
        pending = pw
        buffer = ""                 // the password lives only in `pending` until PAM asks for it
        if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession()
        Greetd.createSession(curUser.name)
        idleT.restart()
    }
    function wrong(msg) {
        busy = false; pending = ""; fails++
        failure = msg; shakeTick++; kick(true)
        if (fails >= 3) {      // 3 misses -> 2 s, 4 -> 4 s ... capped at 30 s (greetd and pam_faillock apply their own limits as well)
            var secs = Math.min(30, Math.pow(2, fails - 2))
            waitUntil = Date.now() + secs * 1000
            cooldownT.restart()
        }
    }
    function startLeave() { leaving = true; exitAnim.start(); launchT.restart() }
    Timer {
        id: cooldownT
        interval: 250; repeat: true
        onTriggered: {
            var left = Math.ceil((win.waitUntil - Date.now()) / 1000)
            if (left <= 0) { win.failure = ""; stop() } else win.failure = "Too many attempts. Wait " + left + " s"
        }
    }
    // a conversation nobody answers is cancelled after a minute
    Timer { id: idleT; interval: 60000; onTriggered: if (!win.leaving) { win.resetAuth(); win.failure = "Timed out" } }
    NumberAnimation { id: exitAnim; target: win; property: "exitT"; from: 0; to: 1; duration: 450; easing.type: Easing.InOutCubic }
    Timer {
        id: launchT
        interval: 380
        onTriggered: {
            if (win.preview) { Qt.quit(); return }
            // the desktop's own names, so Plasma, GNOME, Hyprland ... start as themselves (from the root-owned session file)
            var env = ["XDG_SESSION_TYPE=wayland", "HALCYON_FROM_GREETER=1"]
            if (win.curSess.desk) env.push("XDG_CURRENT_DESKTOP=" + win.curSess.desk.replace(/;+$/, "").replace(/;/g, ":"))
            if (win.curSess.id) env.push("XDG_SESSION_DESKTOP=" + win.curSess.id)
            Greetd.launch(["/bin/sh", "-c", "exec " + win.curSess.exec], env, true)
        }
    }

    Connections {
        target: Greetd
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                if (win.pending !== "") { var p = win.pending; win.pending = ""; Greetd.respond(p) }
                else { win.busy = false; win.notice = message; idleT.restart() }      // another question: shown under the name, the next Enter answers it
            } else if (error) win.failure = message
            else win.notice = message
        }
        function onAuthFailure(message) {
            idleT.stop()
            win.wrong("Wrong password")
            if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession()
        }
        function onReadyToLaunch() {
            idleT.stop()
            // remember the choice (the greeter user owns state/); only names, no secrets
            Quickshell.execDetached(["sh", "-c", "printf '{\"user\":\"%s\",\"session\":\"%s\"}\\n' \"$1\" \"$2\" > \"$3/state/last.json\"",
                                     "sh", win.curUser.name, win.curSess.name, win.dir])
            win.startLeave()
        }
        function onError(error) { idleT.stop(); win.busy = false; win.pending = ""; win.failure = "Login service error" }
    }

    SystemClock { id: clock; precision: win.optSeconds ? SystemClock.Seconds : SystemClock.Minutes }
    property real appear: 0
    NumberAnimation { id: appearAnim; target: win; property: "appear"; from: 0; to: 1; duration: 1100; easing.type: Easing.OutCubic }

    // ---------------------------------------------------------------- blurred wallpaper (when the lock screen is set to wallpaper), else the plain theme colour
    Item {
        id: wallBox
        anchors.fill: parent
        readonly property bool ready: win.bgMode === "wallpaper" && win.wallpaper !== "" && wall.status === Image.Ready
        property real fadeIn: ready ? 1 : 0
        Behavior on fadeIn { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
        visible: fadeIn > 0.001
        opacity: win.appear * fadeIn
        layer.enabled: ready
        Image {
            id: wall
            anchors.fill: parent
            visible: false
            asynchronous: true
            cache: false
            fillMode: Image.PreserveAspectCrop
            source: win.bgMode === "wallpaper" && win.wallpaper !== "" && win.width > 0 ? win.fileUrl(win.wallpaper) : ""
            sourceSize: Qt.size(Math.max(1, Math.round(win.width)), Math.max(1, Math.round(win.height)))
        }
        MultiEffect {
            anchors.fill: parent
            source: wall
            visible: wall.status === Image.Ready
            autoPaddingEnabled: false
            blurEnabled: true
            blurMax: Math.max(4, Math.min(64, Math.round(win.blurRadius)))
            blur: 1.0
        }
        Rectangle { anchors.fill: parent; color: pal.bg; opacity: win.tint }
    }

    // ---------------------------------------------------------------- the lock screen's "Halcyon sky" background (its own LiveSky.qml, stars only)
    Loader {
        anchors.fill: parent
        active: win.bgMode === "sky"
        opacity: win.appear * (1 - win.exitT)
        sourceComponent: LiveSky { pal: pal; showMark: false }
    }

    // ---------------------------------------------------------------- constellation: the lock screen's own Backdrop (your picture as stars, the flagship art, drifting dots) and flying stars
    Backdrop {
        visible: win.optStars
        anchors.fill: parent
        pal: pal
        mode: win.sysmode
        avatarStars: win.starData
        profileStars: win.profileStars
        dots: 34
        artStrength: 0.9
        artFit: 0.78
        energy: win.energy
        opacity: win.appear * (1 - win.exitT)
    }
    BarStars {
        anchors.fill: parent
        anchors.margins: 24
        pal: pal
        count: win.flyCount
        loopMs: win.flyLoop
        sizeScale: 1.5
        active: true
        visible: win.optStars && win.flyCount > 0
        opacity: win.appear * (1 - win.exitT)
    }
    // any mouse movement / click hands keyboard focus to the password box
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onPositionChanged: input.forceActiveFocus()
        onPressed: { win.menu = ""; input.forceActiveFocus() }
    }

    // ---------------------------------------------------------------- clock
    Column {
        visible: win.optClock
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.16 - 22 * (1 - win.appear)
        opacity: win.appear * (1 - win.exitT)
        spacing: 4
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(clock.date, win.optSeconds ? "HH:mm:ss" : "HH:mm")
            color: pal.text
            font.family: pal.uiFont
            font.pixelSize: 112
            font.weight: Font.Light
            font.letterSpacing: 2
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(clock.date, "dddd, d MMMM")
            color: pal.muted
            font.family: pal.uiFont
            font.pixelSize: pal.tTitle + 3
            font.letterSpacing: 1
        }
    }

    // ---------------------------------------------------------------- you + password (same as the lock screen)
    Column {
        id: who
        anchors.horizontalCenter: parent.horizontalCenter
        readonly property real late: Math.max(0, Math.min(1, (win.appear - 0.3) / 0.7))
        y: parent.height * 0.52 + 22 * (1 - late)
        opacity: late * (1 - win.exitT)
        spacing: 18

        // profile picture in a ring (falls back to an initial); Settings can hide it (the name and password then sit where they were)
        Item {
            visible: win.optAvatar
            anchors.horizontalCenter: parent.horizontalCenter
            width: 104; height: 104
            Rectangle {
                id: ripple
                anchors.fill: parent; radius: width / 2
                color: "transparent"
                border.width: 1.5; border.color: Qt.alpha(pal.accent, 0.6)
                ParallelAnimation {
                    loops: Animation.Infinite
                    running: win.visible && pal.motion > 0.3 && !win.leaving
                    NumberAnimation { target: ripple; property: "scale"; from: 1.0; to: 1.5; duration: 2800; easing.type: Easing.OutCubic }
                    NumberAnimation { target: ripple; property: "opacity"; from: 0.55; to: 0; duration: 2800; easing.type: Easing.OutQuad }
                }
            }
            Repeater {
                model: 3
                delegate: Rectangle {
                    id: keyRing
                    required property int index
                    anchors.fill: parent; radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: win.failure !== "" ? pal.bad : pal.accent
                    opacity: 0
                    ParallelAnimation {
                        id: keyRingAnim
                        NumberAnimation { target: keyRing; property: "scale"; from: 1.0; to: 1.45 + 0.45 * win.energy; duration: 820; easing.type: Easing.OutCubic }
                        NumberAnimation { target: keyRing; property: "opacity"; from: 0.45 + 0.45 * win.energy; to: 0; duration: 820; easing.type: Easing.OutQuad }
                    }
                    Connections {
                        target: win
                        function onKickTickChanged() { if (win.kickTick % 3 === keyRing.index) keyRingAnim.restart() }
                    }
                }
            }
            Rectangle {
                anchors.fill: parent; radius: width / 2
                color: pal.ringFill
                border.width: 2
                border.color: Qt.alpha(win.failure !== "" ? pal.bad : pal.accent, 0.55 + 0.45 * win.energy)
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
                    source: win.curAvatar !== "" ? win.fileUrl(win.curAvatar) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize: Qt.size(184, 184)
                    visible: status === Image.Ready
                }
            }
            Item { id: avMask; width: 92; height: 92; visible: false; layer.enabled: true
                Rectangle { anchors.fill: parent; radius: width / 2; color: "black" } }
            Text {
                anchors.centerIn: parent
                visible: avImg.status !== Image.Ready
                text: (win.shownName || "?").charAt(0).toUpperCase()
                color: pal.accent
                font.family: pal.uiFont
                font.pixelSize: 40
                font.weight: Font.DemiBold
            }
        }

        // name; with more than one user, quiet arrows on both sides (Left / Right work too)
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 16
            Text {
                visible: win.users.length > 1
                anchors.verticalCenter: parent.verticalCenter
                text: "‹"; color: pal.muted
                font.family: pal.uiFont; font.pixelSize: pal.tDisplay
                MouseArea { anchors.fill: parent; anchors.margins: -12; onClicked: { win.cycleUser(-1); input.forceActiveFocus() } }
            }
            Text {
                text: win.shownName
                color: pal.text
                font.family: pal.uiFont
                font.pixelSize: pal.tDisplay
                font.weight: Font.DemiBold
            }
            Text {
                visible: win.users.length > 1
                anchors.verticalCenter: parent.verticalCenter
                text: "›"; color: pal.muted
                font.family: pal.uiFont; font.pixelSize: pal.tDisplay
                MouseArea { anchors.fill: parent; anchors.margins: -12; onClicked: { win.cycleUser(1); input.forceActiveFocus() } }
            }
        }

        // password pill (shakes on a wrong password)
        Rectangle {
            id: pill
            anchors.horizontalCenter: parent.horizontalCenter
            width: 340; height: 48; radius: height / 2
            color: pal.boxFill
            border.width: 1
            border.color: win.failure !== "" ? pal.bad : (input.activeFocus ? pal.lineFocus : pal.line)
            Behavior on border.color { ColorAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

            SequentialAnimation {
                id: shake
                NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: -14; duration: 50 }
                NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: 14; duration: 90 }
                NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: -8; duration: 80 }
                NumberAnimation { target: pill; property: "anchors.horizontalCenterOffset"; to: 0; duration: 60 }
            }
            Connections { target: win; function onShakeTickChanged() { shake.restart() } }

            // a ring leaves the pill on every key press
            Rectangle {
                id: ring
                anchors.fill: parent; radius: parent.radius
                color: "transparent"
                border.width: 2
                border.color: win.failure !== "" ? pal.bad : pal.accent
                opacity: 0
                ParallelAnimation {
                    id: ringAnim
                    NumberAnimation { target: ring; property: "scale"; from: 1.0; to: 1.14; duration: 440; easing.type: Easing.OutCubic }
                    NumberAnimation { target: ring; property: "opacity"; from: 0.55; to: 0; duration: 440; easing.type: Easing.OutQuad }
                }
            }
            Connections { target: win; function onKickTickChanged() { ringAnim.restart() } }

            // the password as dots: each one pops in with a little overshoot; they ripple while PAM checks
            property real wave: 0
            NumberAnimation on wave { from: 0; to: 6.2832; duration: 900; loops: Animation.Infinite; running: win.busy }
            Row {
                anchors.centerIn: parent
                spacing: 9
                Repeater {
                    model: Math.min(win.buffer.length, 16)
                    delegate: Rectangle {
                        required property int index
                        width: 9; height: 9; radius: 4.5
                        color: win.failure !== "" ? pal.bad : pal.text
                        NumberAnimation on scale { from: 0.2; to: 1; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.4 }
                        NumberAnimation on opacity { from: 0; to: 1; duration: 150 }
                        transform: Translate { y: win.busy ? -4 * Math.sin(pill.wave - index * 0.7) : 0 }
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
                font.family: pal.uiFont
                font.pixelSize: pal.tTitle + 2
                enabled: !win.busy && !win.leaving
                focus: true
                maximumLength: 256
                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                text: win.buffer
                onTextEdited: { win.buffer = text; if (text.length > 0 && win.failure !== "" && !cooldownT.running) win.failure = ""; win.kick(false) }
                onAccepted: win.submit()
                Connections { target: win; function onBufferChanged() { if (input.text !== win.buffer) input.text = win.buffer } }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) { if (win.menu !== "") win.menu = ""; else { win.buffer = ""; win.failure = "" } event.accepted = true }
                    else if (event.key === Qt.Key_Tab) { win.cycleSession(1); event.accepted = true }
                    else if (win.buffer.length === 0 && event.key === Qt.Key_Left) { win.cycleUser(-1); event.accepted = true }
                    else if (win.buffer.length === 0 && event.key === Qt.Key_Right) { win.cycleUser(1); event.accepted = true }
                }
                // keep the keyboard on the box (the window only gets focus once the compositor maps it)
                Timer { interval: 80; repeat: true; running: !input.activeFocus && !win.leaving; onTriggered: input.forceActiveFocus() }
            }
            Text {
                anchors.centerIn: parent
                visible: win.buffer === "" && !win.busy
                text: win.notice !== "" ? "Answer" : "Password"
                color: Qt.alpha(pal.text, 0.35)
                font.family: pal.uiFont
                font.pixelSize: pal.tBody + 1
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 18
            text: win.busy ? "Checking…" : (win.failure !== "" ? win.failure : win.notice)
            color: win.failure !== "" && !win.busy ? pal.bad : pal.muted
            font.family: pal.uiFont
            font.pixelSize: pal.tCap + 1
        }
    }

    // ---------------------------------------------------------------- sysmode tag, bottom centre (as on the lock screen)
    Text {
        visible: win.sysmode !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 36
        opacity: win.appear * (1 - win.exitT)
        text: pal.zen ? "Sysmode · " + win.sysmode : "SYSMODE · " + win.sysmode.toUpperCase()
        color: Qt.alpha(pal.accent, 0.7)
        font.family: pal.uiFont
        font.pixelSize: pal.zen ? 12 : 10
        font.weight: pal.zen ? Font.Medium : Font.DemiBold
        font.letterSpacing: pal.zen ? 0.2 : 2
    }

    // ---------------------------------------------------------------- Wi-Fi name / battery, top right (switches in Settings; system data only)
    property string wifiName: ""
    property string batText: ""
    Process {
        id: sysPoll
        command: ["sh", "-c", "w=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -n1); [ -n \"$w\" ] || w=$(iwgetid -r 2>/dev/null); "
                 + "b=''; for d in /sys/class/power_supply/BAT*; do [ -r \"$d/capacity\" ] && { b=\"$(cat \"$d/capacity\")%\"; case \"$(cat \"$d/status\" 2>/dev/null)\" in Charging) b=\"$b · charging\";; esac; break; }; done; "
                 + "printf '%s\\n%s\\n' \"$w\" \"$b\""]
        stdout: StdioCollector {
            onStreamFinished: { var l = text.split("\n"); win.wifiName = l[0] || ""; win.batText = l[1] || "" }
        }
    }
    Timer { interval: 30000; repeat: true; running: (win.optWifi || win.optBattery) && !win.leaving; triggeredOnStart: true; onTriggered: sysPoll.running = true }
    Row {
        visible: (win.optWifi && win.wifiName !== "") || (win.optBattery && win.batText !== "")
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 28
        anchors.rightMargin: 32
        spacing: 20
        opacity: win.appear * (1 - win.exitT)
        Text { visible: win.optBattery && win.batText !== ""; text: win.batText; color: pal.muted; font.family: pal.uiFont; font.pixelSize: pal.tCap + 2 }
        Text { visible: win.optWifi && win.wifiName !== ""; text: win.wifiName; color: pal.muted; font.family: pal.uiFont; font.pixelSize: pal.tCap + 2 }
    }

    // ---------------------------------------------------------------- bottom left: Switch user + the desktop (session), as chips like the lock screen's
    // "Switch user"; each opens a small list above it. Left / Right and Tab still work from the keyboard. Power stays bottom right.
    property string menu: ""              // "" | "user" | "session"
    function pickUser(i) { if (i !== userIdx) cycleUser(i - userIdx); menu = ""; input.forceActiveFocus() }
    function pickSession(i) { sessIdx = i; menu = ""; input.forceActiveFocus() }
    component SwChip: Rectangle {
        id: chip
        property string label: ""
        property string glyph: ""
        property bool on: false
        signal clicked()
        width: chipRow.implicitWidth + 30; height: 34; radius: 17
        color: chipMa.containsMouse || on ? Qt.alpha(pal.accent, 0.22) : Qt.alpha(pal.surface, 0.7)
        border.width: 1
        border.color: pal.line
        Behavior on color { ColorAnimation { duration: pal.dFast } }
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 8
            Text { visible: chip.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: chip.glyph; color: pal.accent; font.family: pal.uiFont; font.pixelSize: pal.tCap + 2 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: chip.label; color: pal.text; font.family: pal.uiFont; font.pixelSize: pal.tCap + 1 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: chip.on ? "▾" : "▴"; color: pal.muted; font.family: pal.uiFont; font.pixelSize: pal.tCap }
        }
        MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
    }
    component SwRow: Rectangle {
        id: sr
        property string label: ""
        property string sub: ""
        property string pic: ""
        property string initial: ""
        property bool current: false
        property bool showPic: true
        signal clicked()
        width: parent ? parent.width : 230; height: 40; radius: 10
        color: srMa.containsMouse ? Qt.alpha(pal.accent, 0.2) : (current ? Qt.alpha(pal.accent, 0.1) : "transparent")
        Item {
            id: srPic
            visible: sr.showPic
            x: 8; anchors.verticalCenter: parent.verticalCenter
            width: sr.showPic ? 26 : 0; height: 26
            Rectangle { anchors.fill: parent; radius: width / 2; color: Qt.alpha(pal.surface, 0.9); border.width: 1; border.color: Qt.alpha(pal.accent, 0.5) }
            Image {
                id: srImg
                anchors.fill: parent; anchors.margins: 2
                source: sr.pic !== "" ? win.fileUrl(sr.pic) : ""
                sourceSize: Qt.size(48, 48); fillMode: Image.PreserveAspectCrop; asynchronous: true
                visible: false
            }
            Item { id: srMask; anchors.fill: srImg; visible: false; layer.enabled: true; Rectangle { anchors.fill: parent; radius: width / 2 } }
            MultiEffect { anchors.fill: srImg; source: srImg; visible: srImg.status === Image.Ready; maskEnabled: true; maskSource: srMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
            Text { anchors.centerIn: parent; visible: srImg.status !== Image.Ready; text: sr.initial; color: pal.accent; font.family: pal.uiFont; font.pixelSize: pal.tCap + 1; font.weight: Font.DemiBold }
        }
        Column {
            anchors { left: srPic.right; leftMargin: sr.showPic ? 10 : 12; right: srDot.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            Text { width: parent.width; elide: Text.ElideRight; text: sr.label; color: pal.text; font.family: pal.uiFont; font.pixelSize: pal.tBody; font.weight: sr.current ? Font.DemiBold : Font.Normal }
            Text { width: parent.width; elide: Text.ElideRight; visible: sr.sub !== ""; text: sr.sub; color: pal.muted; font.family: pal.uiFont; font.pixelSize: pal.tCap }
        }
        Rectangle { id: srDot; anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter } width: 6; height: 6; radius: 3; color: pal.accent; visible: sr.current }
        MouseArea { id: srMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sr.clicked() }
    }
    Item {
        anchors.left: parent.left; anchors.bottom: parent.bottom
        anchors.leftMargin: 32; anchors.bottomMargin: 30
        width: swCol.width; height: swCol.height
        opacity: win.appear * (1 - win.exitT)
        visible: opacity > 0.01
        Column {
            id: swCol
            spacing: 8
            // the open list (users or sessions), above the chips
            Rectangle {
                id: listBox
                visible: win.menu !== ""
                width: 250
                height: listCol.height + 16
                radius: 14
                color: Qt.alpha(pal.surface, 0.92)
                border.width: 1
                border.color: pal.line
                Column {
                    id: listCol
                    x: 8; y: 8
                    width: parent.width - 16
                    spacing: 2
                    Text {
                        x: 6; height: 22
                        verticalAlignment: Text.AlignVCenter
                        text: win.menu === "user" ? "Log in as" : "Desktop"
                        color: pal.muted; font.family: pal.uiFont; font.pixelSize: pal.tCap
                    }
                    Repeater {
                        model: win.menu === "user" ? win.users : []
                        delegate: SwRow {
                            required property var modelData
                            required property int index
                            label: win.nameOf(modelData)
                            sub: modelData.full !== "" && modelData.full !== label ? modelData.name : (label !== modelData.name ? modelData.name : "")
                            pic: win.avatarOf(modelData.name)
                            initial: (label || "?").charAt(0).toUpperCase()
                            current: index === win.userIdx
                            onClicked: win.pickUser(index)
                        }
                    }
                    Repeater {
                        model: win.menu === "session" ? win.sessions : []
                        delegate: SwRow {
                            required property var modelData
                            required property int index
                            showPic: false
                            label: modelData.name
                            current: index === win.sessIdx
                            onClicked: win.pickSession(index)
                        }
                    }
                }
            }
            Row {
                spacing: 10
                SwChip {
                    glyph: "◎"
                    label: win.users.length > 1 ? "Switch user" : win.curUser.name
                    on: win.menu === "user"
                    onClicked: { win.menu = win.menu === "user" ? "" : "user"; input.forceActiveFocus() }
                }
                SwChip {
                    visible: win.optSession
                    glyph: "▣"
                    label: win.curSess.name
                    on: win.menu === "session"
                    onClicked: { win.menu = win.menu === "session" ? "" : "session"; input.forceActiveFocus() }
                }
            }
        }
    }
    Row {
        visible: win.optPower
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: 32; anchors.bottomMargin: 26
        opacity: win.appear * (1 - win.exitT)
        spacing: 22
        Repeater {
            model: [{ t: "Sleep", c: ["systemctl", "suspend"] }, { t: "Restart", c: ["systemctl", "reboot"] }, { t: "Shut down", c: ["systemctl", "poweroff"] }]
            delegate: Text {
                required property var modelData
                text: modelData.t
                color: hov.containsMouse ? pal.text : pal.muted
                font.family: pal.uiFont
                font.pixelSize: pal.tCap + 2
                Behavior on color { ColorAnimation { duration: pal.dFast } }
                MouseArea {
                    id: hov
                    anchors.fill: parent; anchors.margins: -8; hoverEnabled: true
                    onClicked: { if (win.preview) win.failure = modelData.t + " (not in preview)"; else Quickshell.execDetached(modelData.c) }
                }
            }
        }
    }

    // success: the screen settles into the theme colour as the session starts
    Rectangle { anchors.fill: parent; color: pal.bg; opacity: win.exitT * win.exitT; z: 50 }
}
