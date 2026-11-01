import QtQuick

// One Nerd Font (Material Design) symbol by its code point, in the theme's icon font. A file of its own rather than an inline
// `component` inside Lock.qml: an inline component there broke Quickshell's live reload ("Glyph is not a type").
Text {
    property var pal: null
    property int code: 0
    text: String.fromCodePoint(code)
    font.family: pal ? pal.font : "JetBrainsMono Nerd Font"
    font.pixelSize: 16
    color: pal ? pal.muted : "#9496a8"
}
