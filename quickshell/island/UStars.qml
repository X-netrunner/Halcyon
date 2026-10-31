import QtQuick
import QtQuick.Shapes

// Five small Halcyon sparkles; `lit` of them are lit (0..5). Used by the utilities box tiles: Wi-Fi signal, Bluetooth battery, hotspot devices.
// The sparkle is the splash's four-point star (four curved sides pinched towards the centre, a slightly longer upright arm), not a plain
// star: the lit ones carry the accent colours, the rest are dim. Drawn as a GPU shape (no Canvas), 5 of them cost next to nothing.
Row {
    id: root
    property var pal
    property int lit: 0
    property int total: 5
    property int size: 13
    spacing: 2
    Repeater {
        model: root.total
        delegate: Item {
            id: sp
            required property int index
            readonly property bool on: index < root.lit
            width: root.size; height: root.size
            readonly property real r: width / 2
            readonly property real rv: r * 0.98          // upright arm
            readonly property real rh: r * 0.82          // sideways arm
            readonly property real c: Math.min(rv, rh) * 0.16    // how far the sides pinch in (the splash's value is 0.11; a touch more so it reads at this size)
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: "transparent"
                    fillGradient: LinearGradient {
                        x1: 0; y1: 0; x2: sp.width; y2: sp.height
                        GradientStop { position: 0; color: sp.on ? root.pal.accent : Qt.alpha(root.pal.text, 0.22); Behavior on color { ColorAnimation { duration: root.pal.dFast } } }
                        GradientStop { position: 1; color: sp.on ? root.pal.accent2 : Qt.alpha(root.pal.text, 0.22); Behavior on color { ColorAnimation { duration: root.pal.dFast } } }
                    }
                    startX: sp.r; startY: sp.r - sp.rv
                    PathQuad { x: sp.r + sp.rh; y: sp.r; controlX: sp.r + sp.c; controlY: sp.r - sp.c }
                    PathQuad { x: sp.r; y: sp.r + sp.rv; controlX: sp.r + sp.c; controlY: sp.r + sp.c }
                    PathQuad { x: sp.r - sp.rh; y: sp.r; controlX: sp.r - sp.c; controlY: sp.r + sp.c }
                    PathQuad { x: sp.r; y: sp.r - sp.rv; controlX: sp.r - sp.c; controlY: sp.r - sp.c }
                }
            }
        }
    }
}
