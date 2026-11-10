import QtQuick

// A small spaced-out caption in the notification box builder.
Text {
    property var pal
    color: pal.muted
    font.family: pal.uiFont
    font.pixelSize: pal.calm ? 12 : 10
    font.weight: pal.calm ? Font.Medium : Font.Normal
    font.letterSpacing: pal.calm ? 0.1 : 0.8
}
