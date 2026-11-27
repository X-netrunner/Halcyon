import QtQuick
import Quickshell.Widgets

// The cover with the visualiser around it (Caelestia's CoverVisualiser): a round cover, and a ring of bars that grow outwards with the music.
// The bars are the same six cava values the bar's equaliser uses (shell.qml `cava`, 0 .. 100), mirrored round the ring and blended between
// neighbours; while nothing plays (or the music bars are off in Settings) they rest as a ring of dots.
Item {
    id: root
    property var pal
    property var player: null
    property var values: []
    property bool active: false              // the tab is on screen and something plays: the bars move
    readonly property bool has: player !== null && player !== undefined
    readonly property int n: 40
    property real cover: 148
    implicitWidth: 232
    implicitHeight: 232

    // how far bar i is out: 0 .. 1 (the six values are laid over half the ring and mirrored over the other half)
    function level(i) {
        if (!active || !values || values.length === 0) return 0
        var t = (i / n) * 2
        if (t > 1) t = 2 - t
        var pos = t * (values.length - 1)
        var lo = Math.floor(pos), hi = Math.min(values.length - 1, lo + 1), f = pos - lo
        var v = (Number(values[lo] || 0) * (1 - f) + Number(values[hi] || 0) * f) / 100
        return Math.max(0, Math.min(1, v))
    }

    Repeater {
        model: root.n
        delegate: Item {
            id: spoke
            required property int index
            width: 0; height: 0
            anchors.centerIn: root
            rotation: index * 360 / root.n
            property real lvl: root.level(index)
            Behavior on lvl { NumberAnimation { duration: 110 } }
            Rectangle {
                x: root.cover / 2 + 9
                y: -1.5
                width: 4 + spoke.lvl * 20
                height: 3
                radius: 1.5
                color: Qt.alpha(root.pal.accent, 0.35 + 0.6 * spoke.lvl)
            }
        }
    }

    ClippingRectangle {
        anchors.centerIn: parent
        width: root.cover; height: root.cover
        radius: width / 2
        color: root.pal.surface
        Image {
            anchors.fill: parent
            source: root.has ? root.player.trackArtUrl : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize: Qt.size(root.cover * 2, root.cover * 2)      // shown at 148 px: decode at 2x
        }
        Text {
            anchors.centerIn: parent
            visible: !root.has || root.player.trackArtUrl === ""
            text: String.fromCodePoint(0xF075A)
            color: Qt.alpha(root.pal.accent, 0.6)
            font.family: root.pal.font
            font.pixelSize: 54
        }
    }
}
