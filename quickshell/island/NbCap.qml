import QtQuick

// A small spaced-out caption in the notification box builder.
Text {
    property var pal
    color: pal.muted
    font.family: pal.uiFont
    font.pixelSize: 10
    font.letterSpacing: 0.8
}
