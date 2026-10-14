import QtQuick

// Trigger strip for a box that lives on a screen edge / corner. Two ways to use it (the "Edge" toggle):
//   hover   touching it opens the box (hoverChanged(true)); the owner closes it after the pointer has left
//   click   a click on it toggles the box (tapped()); nothing opens by accident
Item {
    id: eg
    property bool clickMode: false
    signal hoverChanged(bool on)
    signal tapped()

    HoverHandler {
        enabled: !eg.clickMode
        onHoveredChanged: eg.hoverChanged(hovered)
    }
    TapHandler {
        enabled: eg.clickMode
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: eg.tapped()
    }
}
