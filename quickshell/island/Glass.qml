import QtQuick

// The shared surface: translucent body (the compositor blurs behind it), a neutral hairline,
// and a faint top sheen so it reads as a slightly curved pane of frosted glass rather than a flat fill.
Rectangle {
    id: root
    property var pal
    property real opacityBody: pal.glass
    property bool shadow: true
    property bool flat: false       // no body, no hairline, no sheen: something else draws the surface (the notch shape)

    color: flat ? "transparent" : Qt.alpha(pal.bg, opacityBody)
    border.width: flat ? 0 : 1
    border.color: pal.lineTint

    // sheen: lighter at the top edge, gone by ~45% height
    Rectangle {
        visible: !root.flat
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.alpha(root.pal.text, 0.055) }
            GradientStop { position: 0.45; color: Qt.alpha(root.pal.text, 0.0) }
        }
    }

    // top-edge highlight: a crisp 1px light line that fades out toward the corners, so the pane looks raised
    Rectangle {
        visible: !root.flat && root.height > 40
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Math.max(8, root.radius * 0.6)
        anchors.rightMargin: Math.max(8, root.radius * 0.6)
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.alpha(root.pal.text, 0.0) }
            GradientStop { position: 0.5; color: Qt.alpha(root.pal.text, 0.20) }
            GradientStop { position: 1.0; color: Qt.alpha(root.pal.text, 0.0) }
        }
    }

    Shadow {
        visible: root.shadow
        z: -1
        anchors.fill: parent
        radius: root.radius
    }
}
