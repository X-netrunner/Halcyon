import QtQuick

// Same quiet look as the SUPER+TAB tree: a few faint drifting dots, plus the flagship-mode art
// (shield for lockdown, dragon for stealth) fading in behind the content. Put it first inside a box.
Item {
    id: root
    property var pal
    property string mode: ""
    property int dots: 12
    property real artStrength: 1.0
    property real artFit: 0.9
    property real artShift: 0          // push the art sideways (px), e.g. towards a corner
    property real energy: 0            // 0..1 flare of the constellation (the lock screen kicks it on every key press)
    // secure / relaxed (and any non-flagship mode): the user's profile picture as a constellation (`hx stars`, owned by shell.qml)
    property var avatarStars: null
    property bool profileStars: true
    property bool paused: false        // freeze the animation clocks (e.g. while the page above scrolls); nothing is torn down
    readonly property bool flagship: mode === "lockdown" || mode === "stealth"
    clip: true

    readonly property bool live: visible && opacity > 0.01 && (pal ? pal.motion > 0.3 : true)
    property real tt: 0
    NumberAnimation on tt { from: 0; to: 1000000; duration: 1000000000; loops: Animation.Infinite; running: root.live && !root.paused }

    ModeArt {
        anchors.fill: parent
        anchors.leftMargin: root.artShift
        anchors.rightMargin: -root.artShift
        pal: root.pal
        mode: root.flagship ? root.mode : (root.profileStars && root.avatarStars ? "avatar" : "")
        custom: root.avatarStars
        strength: root.artStrength
        fit: root.artFit
        energy: root.energy
        alive: root.live
        paused: root.paused
    }

    Repeater {
        model: root.live ? root.dots : 0
        delegate: Rectangle {
            required property int index
            readonly property real fx: ((index * 0.6180339) % 1)
            readonly property real fy: ((index * 0.4142135 + 0.17) % 1)
            width: 2 + index % 3
            height: width
            radius: width / 2
            color: Qt.alpha(root.pal.accent, 0.10 + (index % 4) * 0.03)
            x: root.width * fx + 8 * Math.sin(6.2832 * (40 + index * 11 % 50) * root.tt / 1000 + index)
            y: root.height * fy + 8 * Math.cos(6.2832 * (40 + index * 17 % 50) * root.tt / 1000 + index * 2)
        }
    }
}
