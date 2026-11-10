import QtQuick
import QtQuick.Shapes

// The Halcyon sparkle as a single mark: the splash's four-point star (four curved sides pinched towards the centre, a slightly longer
// upright arm), filled from accent to accent 2. Used where a Halcyon-owned sender needs a picture (NotifIcon: Calendar, Halcyon, ...)
// so it is the shell's own symbol instead of an icon-theme picture or an emoji. Drawn as a GPU shape, no Canvas.
Item {
    id: root
    property var pal
    property color c1: pal ? pal.accent : "white"
    property color c2: pal ? pal.accent2 : "white"
    property int size: 20
    implicitWidth: size
    implicitHeight: size

    readonly property real r: width / 2
    readonly property real rv: r * 0.98           // upright arm
    readonly property real rh: r * 0.82           // sideways arm
    readonly property real c: Math.min(rv, rh) * 0.16   // how far the sides pinch in

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: "transparent"
            fillGradient: LinearGradient {
                x1: 0; y1: 0; x2: root.width; y2: root.height
                GradientStop { position: 0; color: root.c1 }
                GradientStop { position: 1; color: root.c2 }
            }
            startX: root.r; startY: root.r - root.rv
            PathQuad { x: root.r + root.rh; y: root.r; controlX: root.r + root.c; controlY: root.r - root.c }
            PathQuad { x: root.r; y: root.r + root.rv; controlX: root.r + root.c; controlY: root.r + root.c }
            PathQuad { x: root.r - root.rh; y: root.r; controlX: root.r - root.c; controlY: root.r + root.c }
            PathQuad { x: root.r; y: root.r - root.rv; controlX: root.r - root.c; controlY: root.r - root.c }
        }
    }
}
