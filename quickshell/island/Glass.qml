import QtQuick

// The shared surface: translucent body (the compositor blurs behind it), a neutral hairline,
// and a faint top sheen so it reads as a slightly curved pane of frosted glass rather than a flat fill.
Rectangle {
    id: root
    property var pal
    property real opacityBody: pal.glass
    property bool shadow: true
    property color tint: "transparent"   // a colour laid over the body (a widget uses the wallpaper accent here); transparent = none
    property bool flat: false       // no body, no hairline, no sheen: something else draws the surface (the notch shape)

    // the light of the pane: on the dark theme it is the text colour (a soft light edge); on the light theme a dark edge would look like
    // a bruise, so the sheen and the top line are white there and a little stronger (white on pale needs more to show)
    readonly property color sheenCol: pal.light ? "#ffffff" : pal.text
    readonly property real sheenA: pal.light ? 0.50 : 0.055
    readonly property real edgeA: pal.light ? 0.90 : 0.20

    color: flat ? "transparent" : Qt.alpha(Qt.tint(pal.bg, tint), opacityBody)
    // the calm style draws its own neutral hairline (below), so an accent outline a window asks for does not show there
    border.width: flat || pal.calm ? 0 : 1
    border.color: pal.lineTint
    Rectangle {
        visible: !root.flat && root.pal.calm
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1             // the pane keeps its one hairline in every calm style; only what is inside it loses outlines
        border.color: root.pal.line
    }

    // sheen: lighter at the top edge, gone by ~45% height (legacy style; the calm panes are flat)
    Rectangle {
        visible: !root.flat && !root.pal.calm
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.alpha(root.sheenCol, root.sheenA) }
            GradientStop { position: 0.45; color: Qt.alpha(root.sheenCol, 0.0) }
        }
    }

    // top-edge highlight: a crisp 1px light line that fades out toward the corners, so the pane looks raised
    Rectangle {
        visible: !root.flat && !root.pal.calm && root.height > 40
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Math.max(8, root.radius * 0.6)
        anchors.rightMargin: Math.max(8, root.radius * 0.6)
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.alpha(root.sheenCol, 0.0) }
            GradientStop { position: 0.5; color: Qt.alpha(root.sheenCol, root.edgeA) }
            GradientStop { position: 1.0; color: Qt.alpha(root.sheenCol, 0.0) }
        }
    }

    Shadow {
        visible: root.shadow && root.pal.boxShadow
        z: -1
        anchors.fill: parent
        radius: root.radius
        // calm: wider and fainter, the pane floats instead of sitting on a dark edge
        // new: wide, soft and a little deeper, the one pane floats over the wallpaper
        spread: root.pal.zen ? 34 : root.pal.calm ? 28 : 22
        drop: root.pal.zen ? 14 : root.pal.calm ? 10 : 6
        strength: root.pal.zen ? 0.024 : root.pal.calm ? 0.02 : 0.026
    }
}
