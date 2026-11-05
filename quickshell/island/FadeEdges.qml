import QtQuick
import QtQuick.Effects

// Soft top / bottom edges for a scrolling list: instead of the content being cut by a hard line right under a header,
// it fades out over `fadeTop` / `fadeBottom` pixels. The fade is a mask on this item, so it works on any background
// (glass, light or dark) and nothing is painted on top.
//
//   FadeEdges { Layout.fillWidth: true; Layout.fillHeight: true
//       GridView { anchors.fill: parent; ... }      // the default property is the content
//   }
//
// `horizontal: true` fades the left / right edges instead (fadeTop = the left edge, fadeBottom = the right edge), for a shelf.
//
// Fades only while there is something to scroll: the top edge fades once the list has moved down, the bottom edge while
// more is below (pass the Flickable as `flick`); with no `flick` both edges always fade a little.
Item {
    id: fe
    property real fadeTop: 28
    property real fadeBottom: 28
    property Item flick: null
    property bool horizontal: false
    readonly property real len: horizontal ? width : height
    default property alias content: holder.data

    readonly property real topNow: flick ? Math.min(1, Math.max(0, flick.contentY - flick.originY) / 12) : 1
    readonly property real botNow: flick ? Math.min(1, Math.max(0, (flick.contentHeight - flick.height) - (flick.contentY - flick.originY)) / 12) : 1
    readonly property real ft: fadeTop * topNow
    readonly property real fb: fadeBottom * botNow

    Item {
        id: holder
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect { maskEnabled: true; maskSource: maskItem; maskThresholdMin: 0.0; maskSpreadAtMin: 0.0 }
    }
    Item {
        id: maskItem
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: fe.horizontal ? Gradient.Horizontal : Gradient.Vertical
                GradientStop { position: 0.0; color: fe.ft > 0.5 ? "transparent" : "black" }
                GradientStop { position: fe.len > 0 ? Math.min(0.49, fe.ft / fe.len) : 0.0; color: "black" }
                GradientStop { position: fe.len > 0 ? Math.max(0.51, 1 - fe.fb / fe.len) : 1.0; color: "black" }
                GradientStop { position: 1.0; color: fe.fb > 0.5 ? "transparent" : "black" }
            }
        }
    }
}
