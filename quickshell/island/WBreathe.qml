import QtQuick

// "Breathe": a flower (or a ring, or a dot) that slowly opens and closes: breathe in as it opens, out as it closes.
// The animation runs only while the widget is on the desktop.   bloom | ring | dot | orbs | bars
WBase {
    id: root

    readonly property real secs: Math.max(4, Math.min(20, Number(opt("secs", 10))))
    readonly property bool words: opt("words", true) === true
    property real ph: 0            // 0 = closed, 1 = open
    property bool inhaling: true

    SequentialAnimation {
        running: root.live
        loops: Animation.Infinite
        ScriptAction { script: root.inhaling = true }
        NumberAnimation { target: root; property: "ph"; from: 0; to: 1; duration: Math.round(root.secs * 500); easing.type: Easing.InOutSine }
        ScriptAction { script: root.inhaling = false }
        NumberAnimation { target: root; property: "ph"; from: 1; to: 0; duration: Math.round(root.secs * 500); easing.type: Easing.InOutSine }
    }

    readonly property real d: sz(120)
    implicitWidth: d + sz(24)
    implicitHeight: d + sz(16) + (words ? sz(20) : 0)

    Item {
        id: stage
        width: root.d; height: root.d
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.sz(8)
        WGlow { anchors.centerIn: parent; width: parent.width * 1.9; height: width; color: root.accent; strength: 0.06 + 0.16 * root.ph }

        // bloom: eight petals that open
        WPetals {
            visible: root.style === "bloom"
            anchors.fill: parent
            b: root
            count: 8
            open: root.ph
            lit: 1
            color: Qt.alpha(root.fg, 0.55 + 0.45 * root.ph)
        }
        Rectangle {
            visible: root.style === "bloom"
            anchors.centerIn: parent
            width: root.sz(8 + 6 * root.ph); height: width; radius: width / 2
            color: root.accent
        }
        // ring: a hairline circle that grows
        Rectangle {
            visible: root.style === "ring"
            anchors.centerIn: parent
            width: parent.width * (0.4 + 0.6 * root.ph); height: width; radius: width / 2
            color: Qt.alpha(root.accent, 0.05 + 0.08 * root.ph)
            border.width: 1.5; border.color: Qt.alpha(root.fg, 0.5 + 0.4 * root.ph)
        }
        // orbs: three soft rings, one inside the other, that swell one after the other like ripples
        Repeater {
            model: root.style === "orbs" ? 3 : 0
            delegate: Rectangle {
                required property int index
                readonly property real lag: Math.max(0, Math.min(1, root.ph * (1.25 - 0.2 * index) - 0.1 * index))
                anchors.centerIn: parent
                width: parent.width * (0.28 + 0.2 * index + (0.36 - 0.06 * index) * lag); height: width; radius: width / 2
                color: Qt.alpha(root.accent, 0.04 + 0.06 * lag)
                border.width: 1.5; border.color: Qt.alpha(root.fg, 0.25 + 0.5 * lag - 0.08 * index)
            }
        }
        // bars: five calm bars that rise and fall together
        Repeater {
            model: root.style === "bars" ? 5 : 0
            delegate: Rectangle {
                required property int index
                readonly property real part: [0.55, 0.8, 1.0, 0.8, 0.55][index]
                width: root.sz(8); radius: width / 2
                height: parent.height * part * (0.18 + 0.62 * root.ph)
                x: (parent.width - (5 * width + 4 * root.sz(8))) / 2 + index * (width + root.sz(8))
                y: (parent.height - height) / 2
                color: Qt.alpha(root.fg, 0.4 + 0.5 * root.ph)
            }
        }
        // dot: a single light that swells
        Rectangle {
            visible: root.style === "dot"
            anchors.centerIn: parent
            width: parent.width * (0.18 + 0.34 * root.ph); height: width; radius: width / 2
            color: Qt.alpha(root.fg, 0.35 + 0.6 * root.ph)
        }
    }
    WLbl {
        b: root
        visible: root.words
        anchors.horizontalCenter: parent.horizontalCenter
        y: stage.y + stage.height + root.sz(6)
        text: root.inhaling ? "BREATHE IN" : "BREATHE OUT"
        color: root.dim
        font.pixelSize: root.sz(10)
        font.letterSpacing: 3
    }
}
