import QtQuick
import "BarLayout.js" as BL

// One place for one widget on the custom bar (CustomBar.qml): it loads the widget, gives it the padding typed in the bar builder and,
// on a rail with capsules, a soft capsule behind it. A widget with nothing to show (no battery, no music bars, no running Focus ...)
// has no length and takes no room and no gap.
//   bar    the CustomBar window      host   its bar body (it knows which component draws which widget)
Item {
    id: slot
    required property string modelData
    required property var bar
    required property var host

    readonly property real pad: BL.padOf(bar.lay, modelData)           // the padding typed for this widget in the builder
    readonly property real capP: bar.caps ? 6 : 0                      // room inside a capsule, in the bar's direction
    readonly property var it: ld.item
    // the widget's length in the bar's direction (a left / right bar measures down, the others across)
    readonly property real along: (ld.status === Loader.Ready && it !== null) ? (bar.vert ? it.implicitHeight : it.implicitWidth) : 0

    visible: along > 0
    width: bar.vert ? bar.bt : along + (pad + capP) * 2
    height: bar.vert ? along + (pad + capP) * 2 : bar.bt

    // the capsule (a rail with "Capsules" on): as thick as the bar's normal height, with a few px of room to the rail's edge
    Rectangle {
        visible: slot.bar.caps
        x: slot.bar.vert ? 4 : 0
        y: slot.bar.vert ? 0 : 4
        width: slot.bar.vert ? slot.width - 8 : slot.width
        height: slot.bar.vert ? slot.height : slot.height - 8
        radius: Math.min(width, height) / 2
        color: Qt.alpha(slot.bar.pal.text, 0.07)
    }

    Loader {
        id: ld
        x: slot.bar.vert ? Math.round((slot.width - width) / 2) : slot.pad + slot.capP
        y: slot.bar.vert ? slot.pad + slot.capP : Math.round((slot.height - height) / 2)
        sourceComponent: slot.host.comp(slot.modelData)
    }
}
