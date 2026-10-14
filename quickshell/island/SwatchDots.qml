import QtQuick
import Quickshell

// The colours of a wallpaper as filled circles, hung in a small glass capsule (WallpaperGallery.qml).
//   - each circle is a soft top-to-bottom gradient of its colour with a thin light edge and a little sheen
//   - circles pop in one after the other when the colours arrive; until then pulsing placeholders hold their place
//   - hover = the circle grows, click = copy its hex code (wl-copy)
Item {
    id: root

    property var pal
    property var colors: []             // ["#rrggbb", ...]
    property int size: 14
    property int slots: 5               // placeholders while the colours are being read
    property bool lit: false            // the front card: a soft halo behind every circle
    property bool capsule: true         // false: just the circles
    signal copied(string hex)

    readonly property int n: colors ? colors.length : 0
    readonly property int count: n > 0 ? n : slots
    readonly property real gap: Math.round(size * 0.5)
    readonly property real pad: capsule ? Math.round(size * 0.55) : 0

    width: row.width + pad * 2
    height: size + pad * 2

    Rectangle {
        visible: root.capsule
        anchors.fill: parent
        radius: height / 2
        antialiasing: true
        color: Qt.alpha(root.pal.bg, 0.55)
        border.width: 1
        border.color: Qt.alpha(root.pal.text, 0.10)
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: root.gap

        Repeater {
            model: root.count

            delegate: Item {
                id: dot
                required property int index
                readonly property bool has: index < root.n
                readonly property color c: has ? root.colors[index] : Qt.alpha(root.pal.text, 0.18)

                width: root.size
                height: root.size
                scale: !has ? 0.7 : (ma.pressed ? 0.88 : (ma.containsMouse ? 1.28 : 1.0))
                Behavior on scale {
                    SequentialAnimation {
                        PauseAnimation { duration: (dot.has && !ma.containsMouse && !ma.pressed) ? dot.index * 50 : 0 }
                        NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
                    }
                }

                // placeholder (colours not read yet)
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    antialiasing: true
                    visible: !dot.has
                    color: Qt.alpha(root.pal.text, 0.16)
                    SequentialAnimation on opacity {
                        running: !dot.has && root.visible
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                }

                // halo (front card only)
                Rectangle {
                    visible: root.lit && dot.has
                    anchors.centerIn: parent
                    width: parent.width * 1.9; height: width; radius: width / 2
                    color: Qt.alpha(dot.c, 0.13)
                }
                Rectangle {
                    visible: root.lit && dot.has
                    anchors.centerIn: parent
                    width: parent.width * 1.4; height: width; radius: width / 2
                    color: Qt.alpha(dot.c, 0.20)
                }

                // the circle
                Rectangle {
                    visible: dot.has
                    anchors.fill: parent
                    radius: width / 2
                    antialiasing: true
                    border.width: 1
                    border.color: Qt.alpha(Qt.lighter(dot.c, 1.6), 0.55)
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.lighter(dot.c, 1.16) }
                        GradientStop { position: 1.0; color: Qt.darker(dot.c, 1.12) }
                    }
                    // sheen
                    Rectangle {
                        x: parent.width * 0.2; y: parent.height * 0.1
                        width: parent.width * 0.6; height: parent.height * 0.34
                        radius: height / 2
                        antialiasing: true
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#60ffffff" }
                            GradientStop { position: 1.0; color: "#00ffffff" }
                        }
                    }
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    anchors.margins: -3
                    enabled: dot.has
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        var hex = String(dot.c)
                        Quickshell.execDetached(["wl-copy", hex])
                        root.copied(hex)
                    }
                }
            }
        }
    }
}
