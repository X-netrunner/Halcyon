import QtQuick

// An icon (a Nerd Font glyph) inside a desktop widget: lit in the widget's accent unless a colour is given.
Text {
    property var b: null
    color: b ? b.accent : "#9aa9d4"
    font.family: b ? b.icons : "JetBrainsMono Nerd Font"
    renderType: (b && Math.abs(b.zoom - 1) > 0.01) ? Text.QtRendering : Text.NativeRendering   // QtRendering = scalable glyphs: sharp when the widget is bigger
    style: (b && b.outlineColor.a > 0.04) ? Text.Outline : Text.Normal
    styleColor: b ? b.outlineColor : "transparent"
}
