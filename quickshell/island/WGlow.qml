import QtQuick
import QtQuick.Shapes

// A soft round glow (the white bloom around the flowers on the wallpaper): a radial fade from `color` at the middle to nothing at the edge.
// Size it bigger than what it sits behind. `strength` 0..1 is how bright the middle is.
Shape {
    id: glow
    property color color: "white"
    property real strength: 0.14
    ShapePath {
        strokeColor: "transparent"
        strokeWidth: -1
        fillGradient: RadialGradient {
            centerX: glow.width / 2; centerY: glow.height / 2
            centerRadius: Math.max(1, Math.min(glow.width, glow.height) / 2)
            focalX: centerX; focalY: centerY
            GradientStop { position: 0.0; color: Qt.alpha(glow.color, glow.strength) }
            GradientStop { position: 0.55; color: Qt.alpha(glow.color, glow.strength * 0.35) }
            GradientStop { position: 1.0; color: Qt.alpha(glow.color, 0) }
        }
        startX: 0; startY: 0
        PathLine { x: glow.width; y: 0 }
        PathLine { x: glow.width; y: glow.height }
        PathLine { x: 0; y: glow.height }
        PathLine { x: 0; y: 0 }
    }
}
