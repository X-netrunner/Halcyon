import QtQuick

// Soft shadow made of 10 very faint stacked rounded rectangles that fall off outward.
// Peak alpha stays below 0.3 on purpose: hyprland/rules.lua blurs only pixels above ignore_alpha (0.55),
// so the shadow is never mistaken for glass. Needs `spread + drop` of free room inside its window.
Item {
    id: root
    property real radius: 20
    property real spread: 22        // how far the shadow reaches
    property real drop: 6           // how far it sits below the surface
    property real strength: 0.026   // alpha of each layer (x10 layers at the edge)

    Repeater {
        model: 10
        delegate: Rectangle {
            required property int index
            readonly property real grow: root.spread * (index + 1) / 10
            anchors.fill: parent
            anchors.leftMargin: -grow
            anchors.rightMargin: -grow
            anchors.topMargin: -grow + root.drop
            anchors.bottomMargin: -grow - root.drop
            radius: root.radius + grow
            color: Qt.alpha("black", root.strength)
        }
    }
}
