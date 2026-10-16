import QtQuick

// The common ground of every desktop widget body (WClock, WMetric, WMusic ...). WidgetHost.qml (the frame) creates the body and
// hands itself over as `w`; everything a body needs comes from there: the palette, the feeds (`env` = the shell), the look
// (colours, font, text size) and the options picked in the Widget builder. A body only has to set its implicitWidth / implicitHeight.
Item {
    id: base
    property var w: null                                   // the WidgetHost that holds this widget

    readonly property var pal: w ? w.pal : null
    readonly property var env: w ? w.env : null
    readonly property string style: w ? w.style : ""
    readonly property string kind: w ? w.type : ""
    readonly property color accent: w ? w.accent : "#9aa9d4"
    readonly property color fg: w ? w.fg : "#dcdde8"
    readonly property color dim: w ? w.dim : "#9496a8"
    readonly property color track: w ? w.track : "#26ffffff"
    readonly property string face: w ? w.face : "sans-serif"
    readonly property string icons: w ? w.iconFont : "JetBrainsMono Nerd Font"
    readonly property real fs: w ? w.fs : 1
    readonly property bool live: w ? w.live : false        // on screen: readers and timers run only then
    readonly property bool editing: w ? w.editing : false
    property bool hidden: false                            // the body asks the frame to hide the whole widget (nothing to show)

    function opt(k, d) {
        var v = (w && w.opts) ? w.opts[k] : undefined
        return v === undefined ? d : v
    }
    function sz(n) { return Math.round(n * fs) }           // a text size, scaled by the look's text size
    function glyph(cp) { return String.fromCodePoint(cp) }
    function clamp01(v) { return Math.max(0, Math.min(1, v)) }
    // colour of a value that can be too high / too low: the lit colour, turning amber then red
    function level(v, hiWarn, hiBad) {
        if (!pal) return accent
        if (v >= hiBad) return pal.bad
        if (v >= hiWarn) return pal.warn
        return accent
    }
}
