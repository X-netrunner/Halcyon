import QtQuick

// A card of the rail dashboard (Dashboard.qml): a soft, outline-free fill, like the cards of Caelestia's performance tab.
Rectangle {
    id: root
    property var pal
    radius: pal.rLg
    color: pal.fill
    border.width: pal.calm ? 0 : 1
    border.color: pal.lineSoft
}
