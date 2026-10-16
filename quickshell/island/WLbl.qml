import QtQuick

// A text inside a desktop widget: the colour and the font come from the widget (b = the WBase body that uses it).
// With Readability on (look.contrast) every letter gets a thin outline so it stays legible on a bright or busy wallpaper.
Text {
    property var b: null
    color: b ? b.fg : "#dcdde8"
    font.family: b ? b.face : "sans-serif"
    renderType: Text.NativeRendering
    style: (b && b.boost > 0.05) ? Text.Outline : Text.Normal
    styleColor: b ? b.outlineColor : "transparent"
}
