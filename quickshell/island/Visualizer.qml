import QtQuick

// Symmetric visualizer: mirrored left/right (lows in the middle),
// every bar grows up and down from the centre line.
Item {
    id: root
    property var pal
    property var values: []
    property bool active: false

    readonly property int n: 6
    readonly property int barW: 3
    readonly property int gap: 2
    readonly property int maxH: 18

    implicitWidth: active ? (2 * n * barW + (2 * n - 1) * gap + 12) : 0
    implicitHeight: maxH
    opacity: active ? 1 : 0
    clip: true

    Behavior on implicitWidth { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 250 } }

    Row {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
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
                    var x = root.values[src]
                    return x === undefined ? 0 : Math.min(1, x / 100)
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: Math.max(3, bar.v * root.maxH)
                    radius: width / 2
                    color: Qt.alpha(root.pal.accent, 0.5 + 0.5 * bar.v)
                    Behavior on height { NumberAnimation { duration: 80 } }
                }
            }
        }
    }
}
