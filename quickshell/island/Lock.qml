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
                y: parent.height * 0.16
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
                y: parent.height * 0.52
                spacing: 18

                // profile picture in a ring (falls back to an initial)
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 104; height: 104
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

                    TextInput {
                        id: input
                        anchors.fill: parent
                        anchors.leftMargin: 22; anchors.rightMargin: 22
                        verticalAlignment: TextInput.AlignVCenter
                        horizontalAlignment: TextInput.AlignHCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tTitle + 2
                        enabled: !root.busy
                        focus: true
                        text: root.buffer
                        onTextEdited: root.buffer = text
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
