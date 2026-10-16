import QtQuick

// An icon (a Nerd Font glyph) inside a desktop widget: lit in the widget's accent unless a colour is given.
Text {
    property var b: null
    color: b ? b.accent : "#9aa9d4"
    font.family: b ? b.icons : "JetBrainsMono Nerd Font"
    renderType: Text.NativeRendering
    style: (b && b.boost > 0.05) ? Text.Outline : Text.Normal
    styleColor: b ? b.outlineColor : "transparent"
}
