import QtQuick
import QtQuick.Shapes

// The notch silhouette (used for the pages that drop from the notch): flat top on the screen edge, the top corners flare
// outwards into it (radius earR), the bottom corners are rounded (radius cornR). The item is the FULL width including the flares.
Item {
    id: root
    property var pal
    property real earR: 13
    property real cornR: 13
    property color fillCol: Qt.alpha(pal.bg, pal.solid ? 1 : 0.88)

    readonly property real r: Math.max(0, Math.min(earR, height - cornR))
    readonly property real cr: Math.max(0, Math.min(cornR, height / 2, (width - 2 * r) / 2))
    readonly property real bw: width - 2 * r
    readonly property real bh: height

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        antialiasing: true

        ShapePath {
            fillColor: root.fillCol
            strokeColor: "transparent"
            strokeWidth: 0
            startX: 0; startY: 0
            PathArc { x: root.r; y: root.r; radiusX: root.r; radiusY: root.r; direction: PathArc.Clockwise }
            PathLine { x: root.r; y: root.bh - root.cr }
            PathArc { x: root.r + root.cr; y: root.bh; radiusX: root.cr; radiusY: root.cr; direction: PathArc.Counterclockwise }
            PathLine { x: root.r + root.bw - root.cr; y: root.bh }
            PathArc { x: root.r + root.bw; y: root.bh - root.cr; radiusX: root.cr; radiusY: root.cr; direction: PathArc.Counterclockwise }
            PathLine { x: root.r + root.bw; y: root.r }
            PathArc { x: root.width; y: 0; radiusX: root.r; radiusY: root.r; direction: PathArc.Clockwise }
            PathLine { x: 0; y: 0 }
        }
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: 0
            fillGradient: LinearGradient {
                x1: 0; y1: 0; x2: 0; y2: Math.max(1, root.bh)
                GradientStop { position: 0.0; color: Qt.alpha(root.pal.text, 0.05) }
                GradientStop { position: 0.45; color: Qt.alpha(root.pal.text, 0.0) }
            }
            startX: 0; startY: 0
            PathArc { x: root.r; y: root.r; radiusX: root.r; radiusY: root.r; direction: PathArc.Clockwise }
            PathLine { x: root.r; y: root.bh - root.cr }
            PathArc { x: root.r + root.cr; y: root.bh; radiusX: root.cr; radiusY: root.cr; direction: PathArc.Counterclockwise }
            PathLine { x: root.r + root.bw - root.cr; y: root.bh }
            PathArc { x: root.r + root.bw; y: root.bh - root.cr; radiusX: root.cr; radiusY: root.cr; direction: PathArc.Counterclockwise }
            PathLine { x: root.r + root.bw; y: root.r }
            PathArc { x: root.width; y: 0; radiusX: root.r; radiusY: root.r; direction: PathArc.Clockwise }
            PathLine { x: 0; y: 0 }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.pal.line
            strokeWidth: 1
            startX: 0; startY: 0
            PathArc { x: root.r; y: root.r; radiusX: root.r; radiusY: root.r; direction: PathArc.Clockwise }
            PathLine { x: root.r; y: root.bh - root.cr }
            PathArc { x: root.r + root.cr; y: root.bh; radiusX: root.cr; radiusY: root.cr; direction: PathArc.Counterclockwise }
            PathLine { x: root.r + root.bw - root.cr; y: root.bh }
            PathArc { x: root.r + root.bw; y: root.bh - root.cr; radiusX: root.cr; radiusY: root.cr; direction: PathArc.Counterclockwise }
            PathLine { x: root.r + root.bw; y: root.r }
            PathArc { x: root.width; y: 0; radiusX: root.r; radiusY: root.r; direction: PathArc.Clockwise }
        }
    }
}
