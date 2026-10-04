import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam

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
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property string name: ""            // display name (profile name or login)
    property string avatarPath: ""
    property bool locked: false

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

    function lock() { buffer = ""; failure = ""; busy = false; locked = true }
    function tryUnlock() {
        if (busy || buffer === "") return
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
                root.locked = false
            } else {
                root.failure = "Wrong password"
                root.shakeTick++
                root.kick(true)
            }
        }
        onError: err => { root.busy = false; root.buffer = ""; root.failure = "Could not check the password"; root.shakeTick++ }
    }
    onLockedChanged: if (!locked) { buffer = ""; failure = ""; busy = false; pam.abort() }

    SystemClock { id: clock; precision: SystemClock.Seconds }

    WlSessionLock {
        locked: root.locked

        WlSessionLockSurface {
            id: surf
            color: root.pal.bg

            // the whole screen eases in when it locks
            property real appear: 0
            NumberAnimation on appear { from: 0; to: 1; duration: 1100; easing.type: Easing.OutCubic }

            // ---- constellation + drifting dots (same quiet look as everything else)
            Backdrop {
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
            Rectangle {   // soft vignette so the middle reads clearly
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.alpha(root.pal.bg, 0.55) }
                    GradientStop { position: 0.5; color: Qt.alpha(root.pal.bg, 0.10) }
                    GradientStop { position: 1.0; color: Qt.alpha(root.pal.bg, 0.65) }
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
                    // a slow ripple leaves the picture
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
                    Rectangle {
                        anchors.fill: parent; radius: width / 2
                        color: Qt.alpha(root.pal.surface, 0.9)
                        border.width: 2; border.color: Qt.alpha(root.pal.accent, 0.55)
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
                    color: Qt.alpha(root.pal.surface, 0.85)
                    border.width: 1
                    border.color: root.failure !== "" ? "#e07a7a" : (input.activeFocus ? root.pal.lineFocus : root.pal.line)
                    Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }

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
                        border.color: root.failure !== "" ? "#e07a7a" : root.pal.accent
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
                                color: root.failure !== "" ? "#e07a7a" : root.pal.text
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
                    color: root.failure !== "" && !root.busy ? "#e07a7a" : root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap + 1
                }
            }

            // sysmode tag, bottom centre
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 36
                visible: root.sysmode !== ""
                text: "SYSMODE · " + root.sysmode.toUpperCase()
                color: Qt.alpha(root.pal.accent, 0.7)
                font.family: root.pal.uiFont
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 2
            }
        }
    }
}
