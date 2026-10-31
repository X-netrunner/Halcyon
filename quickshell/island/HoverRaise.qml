import QtQuick

// Put inside a row of chips: while the pointer is over the row, the row is drawn above its siblings, so the hover bubble of one of its
// chips (Chip.qml) is never covered by the row under it. The row's own `z` is its resting level.
HoverHandler {
    id: hh
    property real rest: 0
    Component.onCompleted: if (parent) rest = parent.z
    onHoveredChanged: if (parent) parent.z = hovered ? 40 : rest
}
