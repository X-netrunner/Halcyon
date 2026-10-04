import QtQuick
import Quickshell
import Quickshell.Io

// Wallpaper-derived palette + the design tokens every component shares.
// `hx palette` writes ~/.cache/island/palette.json, we tail it so colours animate
// whenever the wallpaper changes.
Scope {
    id: pal

    // ---------- colour ----------
    property color bg: "#14161f"
    property color surface: "#1e2130"        // raised: chips, tracks, cards
    property color surfaceHi: "#272b3d"      // hovered / pressed surface
    property color accent: "#9aa9d4"
    property color accent2: "#c2add8"
    property color text: "#dcdde8"
    property color muted: "#9496a8"

    // how see-through the glass is (the compositor blurs what is behind it)
    readonly property real glass: 0.80
    readonly property real glassSolid: 0.94  // for things that must stay legible over anything (overlays)
    readonly property real glassBar: 0.58     // the top bar at rest: lighter = more wallpaper shows through
    readonly property real glassBarOpen: 0.74 // the bar once it has grown into media / perf / the launcher
    // hairlines are neutral, never tinted: they work with every wallpaper
    readonly property color line: Qt.alpha(text, 0.09)
    readonly property color lineSoft: Qt.alpha(text, 0.05)
    readonly property color lineFocus: Qt.alpha(accent, 0.55)

    // ---------- shape (concentric: inner radius = outer radius - padding) ----------
    readonly property int rSm: 10
    readonly property int rMd: 14
    readonly property int rLg: 20
    readonly property int rXl: 28

    // ---------- space (4px rhythm) ----------
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 20
    readonly property int s6: 28

    // ---------- type ----------
    // icons / glyphs (Nerd Font)
    readonly property string font: "JetBrainsMono Nerd Font"
    // terminal-style text (quick terminal)
    readonly property string mono: "JetBrainsMono Nerd Font"
    // text everywhere: first of these that is installed (pacman -S inter-font for Inter)
    readonly property var uiFonts: ["Inter", "Inter Variable", "SF Pro Display", "Noto Sans", "Cantarell", "Roboto", "DejaVu Sans"]
    readonly property string uiFont: {
        var have = Qt.fontFamilies()
        for (var i = 0; i < uiFonts.length; i++)
            if (have.indexOf(uiFonts[i]) >= 0) return uiFonts[i]
        return "Sans Serif"
    }
    // size scale: caption / body / title / display
    readonly property int tCap: 11
    readonly property int tBody: 13
    readonly property int tTitle: 15
    readonly property int tDisplay: 22

    // ---------- motion ----------
    // one signature curve (easeOutQuint): fast start, long soft landing, never bounces
    readonly property var curve: [0.22, 1, 0.36, 1, 1, 1]
    readonly property int dFast: 160
    readonly property int dMed: 300
    readonly property int dSlow: 520

    Behavior on bg { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on surface { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on surfaceHi { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on accent { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on accent2 { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on text { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on muted { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }

    function apply(data) {
        try {
            var p = JSON.parse(data)
            if (p.bg) pal.bg = p.bg
            if (p.surface) pal.surface = p.surface
            if (p.surfaceHi) pal.surfaceHi = p.surfaceHi
            if (p.accent) pal.accent = p.accent
            if (p.accent2) pal.accent2 = p.accent2
            if (p.text) pal.text = p.text
            if (p.muted) pal.muted = p.muted
        } catch (e) {}
    }

    Process {
        running: true
        command: ["tail", "-F", "-n", "1", Quickshell.env("HOME") + "/.cache/island/palette.json"]
        stdout: SplitParser { onRead: data => pal.apply(data) }
    }
}
