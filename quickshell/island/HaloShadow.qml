import QtQuick

// Shadow for translucent surfaces: a HOLLOW halo (nested rings), so nothing is drawn underneath the
// surface itself and see-through glass is not darkened from behind. Rings fade outward.
// peak must stay below the layer's ignore_alpha (hyprland/rules.lua) so the halo is never blurred.
Item {
    id: root
    property real radius: 20
    property real spread: 22
    property real peak: 0.18
    readonly property int rings: 10
    readonly property real step: spread / rings

    Repeater {
        model: root.rings
        delegate: Rectangle {
            required property int index
            readonly property real grow: root.step * (index + 1)
            anchors.fill: parent
            anchors.margins: -grow
            radius: root.radius + grow
            color: "transparent"
            border.width: root.step + 0.6               // tiny overlap so no hairline gaps show between rings
            border.color: Qt.alpha("black", root.peak * Math.pow(1 - (index + 0.5) / root.rings, 2.2))
        }
    }
}
