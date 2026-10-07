import QtQuick
import Quickshell
import Quickshell.Io

// Wallpaper-derived palette + the design tokens every component shares.
// `hx palette` writes ~/.cache/island/palette.json, we tail it so colours animate
// whenever the wallpaper changes.
Scope {
    id: pal

    // ---------- theme ----------
    // `light` flips every surface, line and text colour at once. The wallpaper palette (`hx palette`) is always made for the
    // dark theme, so it is kept in the raw* values below and the light theme is derived from the same hues:
    // the wallpaper still tints the island, only the lightness is turned around.
    property bool light: false
    onLightChanged: refresh()
    Component.onCompleted: refresh()

    // what `hx palette` last wrote (dark)
    property color rawBg: "#14161f"
    property color rawSurface: "#1e2130"
    property color rawSurfaceHi: "#272b3d"
    property color rawAccent: "#9aa9d4"      // the accent in use right now (= fixedAccent, or the cycling colour)
    property color rawAccent2: "#c2add8"
    property color rawText: "#dcdde8"
    property color rawMuted: "#9496a8"

    // ---------- accent cycling (Settings > Colours) ----------
    // The wallpaper's accent is one colour (its strongest hue). With accentMode "cycle" the accent instead drifts through
    // every colour the wallpaper has (`swatches`, made by scripts/palette.sh): red -> purple -> orange ... and round again,
    // blending smoothly between neighbours and resting a moment on each. accent2 is always the colour one step ahead.
    property string accentMode: "fixed"     // fixed | cycle
    property real cycleSecs: 30             // seconds from one colour to the next
    property bool cyclePaused: false        // Gaming mode: no colour animation at all
    property bool termDrift: false          // repaint the open terminals along with the accent (scripts/term-colors.sh --drift)
    property var swatches: []               // the wallpaper's colours as hex strings, strongest first
    property var ring: []                   // the same, sorted around the colour wheel: [{ h, s, l }]
    property real phase: 0                  // where we are on the ring: 0 .. ring.length
    property color fixedAccent: "#9aa9d4"   // what `hx palette` / palette.sh chose (used when not cycling)
    property color fixedAccent2: "#c2add8"
    property color probe: "#000000"         // scratch: assigning a hex string to a colour lets us read its hue
    readonly property bool cycling: accentMode === "cycle" && ring.length > 1 && !cyclePaused
    onCyclingChanged: syncAccent()
    onSwatchesChanged: rebuildRing()
    function rebuildRing() {
        var l = []
        for (var i = 0; i < swatches.length; i++) {
            probe = swatches[i]
            l.push({ h: hueOf(probe, 0), s: probe.hslSaturation, l: probe.hslLightness })
        }
        l.sort(function (a, b) { return a.h - b.h })
        ring = l
        if (phase >= l.length) phase = 0
        syncAccent()
    }
    function mixHsl(a, b, t) {
        var dh = ((b.h - a.h + 1.5) % 1) - 0.5          // shortest way round the wheel
        return Qt.hsla((a.h + dh * t + 1) % 1, a.s + (b.s - a.s) * t, a.l + (b.l - a.l) * t, 1)
    }
    function applyCycle() {
        var n = ring.length
        if (n < 2) return
        var i = Math.floor(phase) % n
        var f = phase - Math.floor(phase)
        var t = f * f * (3 - 2 * f)                     // smoothstep: lingers on each colour, glides between them
        rawAccent = mixHsl(ring[i], ring[(i + 1) % n], t)
        rawAccent2 = mixHsl(ring[(i + 1) % n], ring[(i + 2) % n], t)
        refresh()
    }
    function syncAccent() {
        if (cycling) { applyCycle(); return }
        rawAccent = fixedAccent
        rawAccent2 = fixedAccent2
        refresh()
    }
    Timer {
        id: cycleT
        interval: 100
        repeat: true
        running: pal.cycling
        property double last: 0
        onRunningChanged: last = Date.now()
        onTriggered: {
            var t = Date.now()
            pal.phase = (pal.phase + (t - last) / 1000 / Math.max(3, pal.cycleSecs)) % pal.ring.length
            last = t
            pal.applyCycle()
        }
    }
    // the terminals that are open follow the cycle too, a few seconds apart (they are repainted with escape codes)
    Timer {
        interval: 5000
        repeat: true
        running: pal.cycling && pal.termDrift
        onTriggered: pal.runTermColors()
    }
    function runTermColors() {
        var cmd = ["bash", Quickshell.env("HOME") + "/.config/Halcyon/scripts/term-colors.sh"]
        if (cycling && termDrift) cmd = cmd.concat(["--drift", String(rawAccent), String(rawAccent2)])
        Quickshell.execDetached(cmd)
    }

    // ---------- colour (what every component uses) ----------
    property color bg: "#14161f"
    property color surface: "#1e2130"        // raised: chips, tracks, cards
    property color surfaceHi: "#272b3d"      // hovered / pressed surface
    property color accent: "#9aa9d4"
    property color accent2: "#c2add8"
    property color text: "#dcdde8"
    property color muted: "#9496a8"

    // status colours (battery, errors, sysmode): tuned separately for dark and light so they stay readable on both
    readonly property color good: light ? "#2e8a4d" : "#8fcfa0"
    readonly property color warn: light ? "#a8730f" : "#e5c07b"
    readonly property color bad: light ? "#c43e3e" : "#e58a8a"
    readonly property var modeColor: ({
        "secure": light ? "#2e8a4d" : "#8fd19e",
        "stealth": light ? "#0f7f8c" : "#56b6c2",
        "cyber": light ? "#a8730f" : "#e5c07b",
        "lockdown": light ? "#c2303c" : "#e06c75"
    })

    function hueOf(c, fallback) { var h = c.hslHue; return (h === undefined || h < 0 || isNaN(h)) ? fallback : h }

    function refresh() {
        if (!light) {
            bg = rawBg; surface = rawSurface; surfaceHi = rawSurfaceHi
            accent = rawAccent; accent2 = rawAccent2; text = rawText; muted = rawMuted
            return
        }
        var h = hueOf(rawBg, hueOf(rawAccent, 0.62))
        var ha = hueOf(rawAccent, h)
        var ha2 = hueOf(rawAccent2, ha)
        var s = Math.min(0.32, rawBg.hslSaturation * 0.8 + 0.06)
        var sa = Math.max(0.30, Math.min(0.62, rawAccent.hslSaturation + 0.14))
        var sa2 = Math.max(0.26, Math.min(0.58, rawAccent2.hslSaturation + 0.10))
        bg = Qt.hsla(h, s, 0.955, 1)
        surface = Qt.hsla(h, s, 0.905, 1)
        surfaceHi = Qt.hsla(h, s, 0.86, 1)
        accent = Qt.hsla(ha, sa, 0.40, 1)
        accent2 = Qt.hsla(ha2, sa2, 0.44, 1)
        text = Qt.hsla(h, 0.20, 0.13, 1)
        muted = Qt.hsla(h, 0.10, 0.38, 1)
    }

    // how see-through the glass is (the compositor blurs what is behind it)
    // Settings > Transparency moves all four together by glassShift (-0.15 .. +0.05; keep the bar above the
    // compositor's blur threshold, see hyprland/rules.lua)
    property real glassShift: 0
    readonly property real glass: 0.80 + glassShift
    readonly property real glassSolid: Math.min(1, 0.94 + glassShift)  // for things that must stay legible over anything (overlays)
    readonly property real glassBar: 0.58 + glassShift      // the top bar at rest: lighter = more wallpaper shows through
    readonly property real glassBarOpen: 0.74 + glassShift  // the bar once it has grown into media / perf / the launcher
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

    // ---------- edge boxes: the utilities panel (bottom-right) and the notification centre (right edge) share these,
    // so their width, inner padding and distance from the screen edge always match ----------
    readonly property int boxW: 392
    readonly property int boxPad: 18
    readonly property int boxEdge: 22
    readonly property int boxTop: 90         // top of the notification centre AND the console, so they line up

    // ---------- type ----------
    // icons / glyphs (Nerd Font)
    readonly property string font: "JetBrainsMono Nerd Font"
    // terminal-style text (quick terminal)
    readonly property string mono: "JetBrainsMono Nerd Font"
    // text everywhere: first of these that is installed (pacman -S inter-font for Inter)
    readonly property var uiFonts: ["Inter Variable", "Noto Sans", "Cantarell", "Roboto", "DejaVu Sans", "Inter", "SF Pro Display"]
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

    // ---------- growth ----------
    // the flagship constellations (and the picture one) grow the longer the island has been running: shell.qml sets
    // growth 0..1 from the saved total minutes (Settings > Constellations); off = the plain constellations
    property real growth: 0
    property bool growthOn: true

    // ---------- motion ----------
    // one signature curve (easeOutQuint): fast start, long soft landing, never bounces
    readonly property var curve: [0.22, 1, 0.36, 1, 1, 1]
    // motion scales every island animation: 1 = normal, 0.5 = fast, 0 = instant (Gaming mode uses 0.25)
    property real motion: 1.0
    readonly property int dFast: Math.round(160 * motion)
    readonly property int dMed: Math.round(300 * motion)
    readonly property int dSlow: Math.round(520 * motion)

    Behavior on bg { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on surface { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on surfaceHi { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on accent { enabled: !pal.cycling; ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on accent2 { enabled: !pal.cycling; ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on text { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }
    Behavior on muted { ColorAnimation { duration: 900; easing.type: Easing.InOutSine } }

    function apply(data) {
        try {
            var p = JSON.parse(data)
            if (p.bg) pal.rawBg = p.bg
            if (p.surface) pal.rawSurface = p.surface
            if (p.surfaceHi) pal.rawSurfaceHi = p.surfaceHi
            if (p.accent) pal.fixedAccent = p.accent
            if (p.accent2) pal.fixedAccent2 = p.accent2
            if (p.text) pal.rawText = p.text
            if (p.muted) pal.rawMuted = p.muted
            var sw = p.swatches || []
            if (JSON.stringify(sw) !== JSON.stringify(pal.swatches)) pal.swatches = sw     // rebuilds the ring, then syncs the accent
            else pal.syncAccent()
            termColors.restart()          // terminals follow the wallpaper too (scripts/term-colors.sh)
        } catch (e) {}
    }

    // a moment after the last palette change: write the terminal colour files and repaint open terminals
    Timer {
        id: termColors
        interval: 400
        onTriggered: pal.runTermColors()
    }

    function reloadFromFile() {
        palProc.running = false
        palProc.running = true
    }

    Process {
        id: palProc
        command: ["sh", "-c", "cat \"$HOME/.cache/island/palette.json\" 2>/dev/null"]
        stdout: SplitParser { onRead: data => pal.apply(data) }
    }

    Process {
        running: true
        command: ["tail", "-F", "-n", "1", Quickshell.env("HOME") + "/.cache/island/palette.json"]
        stdout: SplitParser { onRead: data => pal.apply(data) }
    }
}
