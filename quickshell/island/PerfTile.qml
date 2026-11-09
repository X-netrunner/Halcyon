import QtQuick

// One tile of the Performance look "Tiles" (PerfTiles.qml): a soft rounded surface that rises into place when the tab opens.
//   reveal  0 .. 1, how far it has come in (PerfBase.seg)
Rectangle {
    id: root
    property var pal
    property real reveal: 1
    radius: pal.rMd
    color: Qt.alpha(pal.surface, 0.55)
    border.width: pal.calm ? 0 : 1
    border.color: pal.lineSoft
    opacity: reveal
    transform: Translate { y: (1 - root.reveal) * 12 }
}
