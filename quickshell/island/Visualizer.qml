import QtQuick

// Symmetric visualizer: mirrored left/right (lows in the middle),
// every bar grows up and down from the centre line.
// It always takes the same room, playing or not: while nothing plays the bars rest as a row of small dots,
// so the bar never changes width (and nothing shifts) when the music starts or stops.
Item {
    id: root
    property var pal
    property var values: []
    property bool active: false      // something is playing: the bars move, otherwise they rest as dots

    readonly property int n: 6
    readonly property int barW: 3
    readonly property int gap: 2
    readonly property int maxH: 18

    implicitWidth: 2 * n * barW + (2 * n - 1) * gap + 12
    implicitHeight: maxH
    clip: true

    Row {
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter      // centred in its room, so "halfway between" really is halfway
        spacing: root.gap

        Repeater {
            model: root.n * 2
            delegate: Item {
                id: bar
                required property int index
                width: root.barW
                height: root.maxH
                readonly property int src: index < root.n ? root.n - 1 - index : index - root.n
                readonly property real v: {
                    if (!root.active) return 0
                    var x = root.values[src]
                    return x === undefined ? 0 : Math.min(1, x / 100)
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: Math.max(3, bar.v * root.maxH)     // 3 x 3 = a dot
                    radius: width / 2
                    color: root.active ? Qt.alpha(root.pal.accent, 0.5 + 0.5 * bar.v) : Qt.alpha(root.pal.text, 0.30)
                    Behavior on height { NumberAnimation { duration: 80 } }
                }
            }
        }
    }
}
