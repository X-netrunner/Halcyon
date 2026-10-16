import QtQuick

// A text inside a desktop widget: the colour and the font come from the widget (b = the WBase body that uses it).
Text {
    property var b: null
    color: b ? b.fg : "#dcdde8"
    font.family: b ? b.face : "sans-serif"
    renderType: Text.NativeRendering
}
