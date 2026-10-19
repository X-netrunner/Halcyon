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
    // Settings > Look > Box background: tint (the wallpaper colours every box, subtly) | match (the boxes AND their outlines take the
    // wallpaper's accent colour, clearly) | matte (dark grey, no tint) | black (pitch black).
    // matte / black make every box solid (no see-through glass) and only apply to the dark theme.
    property string surfaceStyle: "tint"
    onSurfaceStyleChanged: refresh()
    readonly property bool solid: !light && (surfaceStyle === "matte" || surfaceStyle === "black")
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
        interval: 200
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
        "relaxed": light ? "#a8730f" : "#e5c07b",
        "lockdown": light ? "#c2303c" : "#e06c75"
    })

    function hueOf(c, fallback) { var h = c.hslHue; return (h === undefined || h < 0 || isNaN(h)) ? fallback : h }

    function refresh() {
        if (!light) {
            if (surfaceStyle === "black") { bg = "#000000"; surface = "#0c0c0e"; surfaceHi = "#18181b" }
            else if (surfaceStyle === "matte") { bg = "#0f0f11"; surface = "#19191c"; surfaceHi = "#232327" }
            else if (surfaceStyle === "match") {
                // the hue AND most of the saturation of the wallpaper's accent (it drifts along with it while the accent cycles);
                // still dark and see-through, so text keeps its contrast
                var hm = hueOf(rawAccent, hueOf(rawBg, 0.62))
                var sm = Math.max(0.32, Math.min(0.62, rawAccent.hslSaturation * 0.8))
                bg = Qt.hsla(hm, sm * 0.8, 0.10, 1)
                surface = Qt.hsla(hm, sm, 0.175, 1)
                surfaceHi = Qt.hsla(hm, sm, 0.235, 1)
            }
            else { bg = rawBg; surface = rawSurface; surfaceHi = rawSurfaceHi }
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
    // A bright wallpaper makes dark see-through glass look grey and muddy, so the glass gets a little more body the brighter the
    // picture is (wallLum: 0 = black .. 1 = white, from scripts/palette.sh). Only on the dark theme; at most +0.12.
    property real wallLum: 0.3
    // 12 x 8 grid of the wallpaper's real luminance (0 black .. 1 white, linear), row by row: palette.sh. The desktop widgets ask
    // lumAt() what is right behind them and switch to dark, accent-tinted text on a bright patch (WidgetHost.qml)
    property var wallGrid: []
    // the same 12 x 8 grid in colour ("#rrggbb" per cell, palette.sh "cgrid"): colorAt() is what the widgets' Auto text colour looks at
    property var wallColors: []
    function colorAt(fx, fy, fw, fh) {
        var cg = wallColors
        if (!cg || cg.length !== 96) return null
        var x0 = Math.max(0, Math.min(11, Math.floor(fx * 12))), x1 = Math.max(x0, Math.min(11, Math.floor((fx + fw) * 12)))
        var y0 = Math.max(0, Math.min(7, Math.floor(fy * 8))), y1 = Math.max(y0, Math.min(7, Math.floor((fy + fh) * 8)))
        var r = 0, g = 0, b = 0, n = 0
        for (var y = y0; y <= y1; y++) for (var x = x0; x <= x1; x++) {
            var h = String(cg[y * 12 + x])
            r += parseInt(h.substr(1, 2), 16); g += parseInt(h.substr(3, 2), 16); b += parseInt(h.substr(5, 2), 16); n++
        }
        return n ? [r / n / 255, g / n / 255, b / n / 255] : null
    }
    function lumAt(fx, fy, fw, fh): real {
        var g = wallGrid
        if (!g || g.length !== 96) return wallLum
        var x0 = Math.max(0, Math.min(11, Math.floor(fx * 12))), x1 = Math.max(x0, Math.min(11, Math.floor((fx + fw) * 12)))
        var y0 = Math.max(0, Math.min(7, Math.floor(fy * 8))), y1 = Math.max(y0, Math.min(7, Math.floor((fy + fh) * 8)))
        var sum = 0, n = 0
        for (var y = y0; y <= y1; y++) for (var x = x0; x <= x1; x++) { sum += g[y * 12 + x]; n++ }
        return n ? sum / n : wallLum
    }
    // brightest minus darkest cell under the same rectangle: a big number = a mixed patch (pink next to black), where neither
    // dark nor light text alone reads, so the widgets use light text with a strong dark outline there
    function lumSpreadAt(fx, fy, fw, fh): real {
        var g = wallGrid
        if (!g || g.length !== 96) return 0
        var x0 = Math.max(0, Math.min(11, Math.floor(fx * 12))), x1 = Math.max(x0, Math.min(11, Math.floor((fx + fw) * 12)))
        var y0 = Math.max(0, Math.min(7, Math.floor(fy * 8))), y1 = Math.max(y0, Math.min(7, Math.floor((fy + fh) * 8)))
        var lo = 9, hi = -1
        for (var y = y0; y <= y1; y++) for (var x = x0; x <= x1; x++) { var v = g[y * 12 + x]; if (v < lo) lo = v; if (v > hi) hi = v }
        return hi < 0 ? 0 : hi - lo
    }
    function lumMaxAt(fx, fy, fw, fh): real {
        var g = wallGrid
        if (!g || g.length !== 96) return wallLum
        var x0 = Math.max(0, Math.min(11, Math.floor(fx * 12))), x1 = Math.max(x0, Math.min(11, Math.floor((fx + fw) * 12)))
        var y0 = Math.max(0, Math.min(7, Math.floor(fy * 8))), y1 = Math.max(y0, Math.min(7, Math.floor((fy + fh) * 8)))
        var hi = 0
        for (var y = y0; y <= y1; y++) for (var x = x0; x <= x1; x++) if (g[y * 12 + x] > hi) hi = g[y * 12 + x]
        return hi
    }
    readonly property real glassBoost: light ? 0 : Math.max(0, Math.min(0.12, (wallLum - 0.45) * 0.45))
    Behavior on wallLum { NumberAnimation { duration: 900; easing.type: Easing.InOutSine } }
    readonly property real glass: solid ? 1 : (0.80 + glassShift + glassBoost)
    readonly property real glassSolid: solid ? 1 : Math.min(1, 0.94 + glassShift + glassBoost)  // for things that must stay legible over anything (overlays)
    readonly property real glassBar: solid ? 1 : (0.58 + glassShift + glassBoost)      // the top bar at rest: lighter = more wallpaper shows through
    readonly property real glassBarOpen: solid ? 1 : (0.74 + glassShift + glassBoost)  // the bar once it has grown into media / perf / the launcher
    // hairlines are neutral and work with every wallpaper; panels (Glass.qml) add a faint accent tint on top (lineTint)
    readonly property bool matchBox: !light && surfaceStyle === "match"     // box outlines in the accent colour too
    readonly property color line: matchBox ? Qt.alpha(accent, 0.30) : Qt.alpha(text, 0.09)
    readonly property color lineTint: Qt.tint(line, Qt.alpha(accent, 0.12))
    readonly property color lineSoft: matchBox ? Qt.alpha(accent, 0.16) : Qt.alpha(text, 0.05)
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
    // a serif face for the quiet, elegant desktop widgets (Widget builder > Font > Serif): first of these that is installed
    readonly property var serifFonts: ["Cormorant Garamond", "Playfair Display", "Source Serif 4", "Noto Serif", "DejaVu Serif", "Liberation Serif"]
    readonly property string serifFont: {
        var have = Qt.fontFamilies()
        for (var i = 0; i < serifFonts.length; i++)
            if (have.indexOf(serifFonts[i]) >= 0) return serifFonts[i]
        return "Serif"
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

    // Settings > Performance: artQuality 0 = low, 1 = medium, 2 = high (how much the tree view and the constellations
    // animate); artFps = how often they update, 0 = every frame of the screen
    property int artQuality: 2
    property int artFps: 0
    // On battery (a laptop that is not plugged in) the moving stars redraw half as often: same drift speed (it follows the clock),
    // half the repaints. Every star timer multiplies its interval by this.
    property bool lowPower: false
    readonly property real starSlow: lowPower ? 2 : 1
    // Settings > Performance > Tree view: the constellation behind the tree (full | corner | off) and where its floating dots gather
    property string treeConst: "full"
    property string treeConstCorner: "br"
    property real treeConstSize: 0.30
    property string treeDots: "load"
    // Settings > Performance > Line drawing: true = the GPU draws the constellation lines (plain quads) and the tree branches
    // (a small shader, branchShader = the compiled .qsb, "" until it is ready); false = the old Shape paths (CPU)
    property bool gpuLines: true
    property string branchShader: ""
    property string lastRawPalette: ""

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
        var s = String(data || "").trim()
        if (!s || s === pal.lastRawPalette) return
        try {
            var p = JSON.parse(s)
            pal.lastRawPalette = s
            if (p.bg) pal.rawBg = p.bg
            if (p.surface) pal.rawSurface = p.surface
            if (p.surfaceHi) pal.rawSurfaceHi = p.surfaceHi
            if (p.accent) pal.fixedAccent = p.accent
            if (p.accent2) pal.fixedAccent2 = p.accent2
            if (p.text) pal.rawText = p.text
            if (p.muted) pal.rawMuted = p.muted
            if (p.lum !== undefined) pal.wallLum = p.lum
            if (p.grid && p.grid.length === 96) pal.wallGrid = p.grid
            if (p.cgrid && p.cgrid.length === 96) pal.wallColors = p.cgrid
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
        palFile.reload()
    }

    FileView {
        id: palFile
        path: Quickshell.env("HOME") + "/.cache/island/palette.json"
        watchChanges: true
        onLoaded: pal.apply(palFile.text())
        onFileChanged: palFile.reload()
    }
}
