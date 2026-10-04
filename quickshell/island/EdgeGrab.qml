import QtQuick

// Trigger for a box that lives on a screen edge / corner. Two ways to use it (the "Edge" toggle):
//   hover   touching it opens the box (hovered(true)), leaving lets the owner close it again
//   drag    hold it and pull the box out: `pull` goes 0..1 while you drag, released(open) tells you where you let go
// With closing: true the same item is a handle ON the box: pull it back towards the edge / corner to close it
// (pull starts at 1 and drops as you push; let go below ~0.6 and it closes, above and it springs back open).
// Direction: (dx, dy) is the way the box opens (e.g. -1,0 for a box that slides in from the right edge).
Item {
    id: eg
    property bool dragMode: false
    property bool closing: false
    property real dx: 1
    property real dy: 0
    property real span: 300
    property real pull: closing ? 1 : 0
    readonly property bool pulling: dh.active
    signal hoverChanged(bool on)
    signal released(bool open)

    HoverHandler {
        enabled: !eg.dragMode && !eg.closing
        onHoveredChanged: eg.hoverChanged(hovered)
    }
    // hovering the box itself also counts, so the handle only matters for drag
    DragHandler {
        id: dh
        enabled: eg.dragMode
        target: null
        grabPermissions: PointerHandler.CanTakeOverFromAnything
        onActiveChanged: {
            if (active) { eg.pull = eg.closing ? 1 : 0; return }
            eg.released(eg.closing ? eg.pull > 0.6 : eg.pull > 0.35)
        }
        onTranslationChanged: {
            if (!active) return
            var p = (translation.x * eg.dx + translation.y * eg.dy) / eg.span
            eg.pull = eg.closing ? Math.max(0, Math.min(1, 1 + p)) : Math.max(0, Math.min(1, p))
        }
    }
}
