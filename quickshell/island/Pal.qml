import QtQuick
import Quickshell
import Quickshell.Io

// Wallpaper-derived palette + the design tokens every component shares.
// `hx palette` writes ~/.cache/island/palette.json, we tail it so colours animate
// whenever the wallpaper changes.
Scope {
    id: pal

    // ---------- interface style (Settings > Look > Interface) ----------
    // "new" (the default): the quiet redesign. One soft pane, no outlines inside it: groups are a faint fill, buttons are pills,
    // the active choice is an accent wash and the one main action (Done, Play ...) is solid accent. No explanations (> ask).
    // "legacy": the first calm look (flat frosted panes with a hairline on every box, borderless controls).
    // "classic": the original look (sheen and accent outlines on every pane, outlined chips).
    // `calm` = not classic (legacy and new share it), `zen` = new only. The shared pieces (Glass, Chip, ActionChip, Toggle,
    // Slider, Hint, BoxTitle, Shadow, the stars) switch by themselves.
    property string uiStyle: "new"
    readonly property bool calm: uiStyle !== "classic"
    readonly property bool zen: uiStyle === "new"
    // Settings > Look: explanations / key hints shrink to a "?" dot (Hint.qml; the new style hides them completely),
    // box titles sit in the middle (BoxTitle.qml)
    property bool hideHints: true
    property bool boxShadow: true           // Settings > Look > Soft shadow around boxes (Glass.qml)
    property bool deskWin: false            // Settings > Windows: centres open as ordinary windows on the workspace instead of an overlay (Host.qml)
    // every title sits in the middle of its header, in every style (the Centred titles switch is gone: one rule everywhere)
    readonly property bool centred: true

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
            // Every colour is pulled into the band the fixed accent lives in (pastel: lightness ~0.74, saturation 0.30 .. 0.55), so a
            // dark navy or a neon swatch still gives a readable accent with the same calm look while cycling. The hue is untouched.
            l.push({ h: hueOf(probe, 0), s: Math.max(0.30, Math.min(0.58, probe.hslSaturation)), l: Math.max(0.66, Math.min(0.78, probe.hslLightness)) })
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

    // WCAG relative luminance of a colour (0 black .. 1 white)
    function relLum(c) {
        function f(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }
    // The light theme's accents: HSL "lightness" over-reports how light yellow, green and cyan look, so the same 0.40 that reads well
    // for blue or purple is too pale for a yellow wallpaper. This keeps the hue and saturation and only lowers the lightness until
    // the colour reaches 4.5 : 1 on the pale boxes (relative luminance <= 0.105); blue / purple accents are left exactly as they were.
    function readableOnLight(h, s, l) {
        var c = Qt.hsla(h, s, l, 1)
        if (relLum(c) <= 0.105) return c
        var lo = 0.15, hi = l
        for (var i = 0; i < 8; i++) {
            var mid = (lo + hi) / 2
            if (relLum(Qt.hsla(h, s, mid, 1)) <= 0.105) lo = mid; else hi = mid
        }
        return Qt.hsla(h, s, lo, 1)
    }

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
        accent = readableOnLight(ha, sa, 0.40)
        accent2 = readableOnLight(ha2, sa2, 0.41)    // was 0.44, which gave a yellow or green second accent only ~3 : 1
        text = Qt.hsla(h, 0.20, 0.13, 1)
        muted = Qt.hsla(h, 0.10, 0.35, 1)            // 0.38 dropped to ~4.5 : 1 on surfaceHi
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
    readonly property real glass: solid ? 1 : ((zen ? 0.90 : calm ? 0.85 : 0.80) + glassShift + glassBoost)
    readonly property real glassSolid: solid ? 1 : Math.min(1, 0.94 + glassShift + glassBoost)  // for things that must stay legible over anything (overlays)
    readonly property real glassBar: solid ? 1 : (0.58 + glassShift + glassBoost)      // the top bar at rest: lighter = more wallpaper shows through
    // the border around the screen (ScreenFrame.qml) and everything that hangs from it: the notch bar and its pages share this one fill
    readonly property color frameCol: Qt.alpha(bg, 1)
    // set by shell.qml from Settings > Bar style > Border around the screen: when on, the boxes that open from a screen edge
    // (Glass.qml: joinH / joinV) are drawn in frameCol and flare into the border instead of floating beside it
    property bool frameOn: false
    property int frameT: 0
    property bool cornerOut: false          // Desktop builder > Boxes come out of: the corner (top / bottom AND side) instead of the side only
    readonly property real glassBarOpen: solid ? 1 : (0.74 + glassShift + glassBoost)  // the bar once it has grown into media / perf / the launcher
    // hairlines are neutral and work with every wallpaper; panels (Glass.qml) add a faint accent tint on top (lineTint)
    readonly property bool matchBox: !light && surfaceStyle === "match"     // box outlines in the accent colour too
    readonly property color line: matchBox ? Qt.alpha(accent, 0.30) : Qt.alpha(text, zen ? 0.065 : calm ? 0.08 : 0.09)
    readonly property color lineTint: calm && !matchBox ? line : Qt.tint(line, Qt.alpha(accent, 0.12))
    readonly property color lineSoft: matchBox ? Qt.alpha(accent, 0.16) : Qt.alpha(text, calm ? 0.04 : 0.05)
    // the calm style's quiet fills: a resting control, and one under the pointer (no outline needed)
    readonly property color fill: Qt.alpha(text, light ? 0.06 : 0.055)
    readonly property color fillHover: Qt.alpha(text, light ? 0.10 : 0.095)
    readonly property color lineFocus: Qt.alpha(accent, 0.55)
    // the new style's pieces: a group of rows / a card inside a pane (a faint fill instead of an outline), a field (search box),
    // the chosen option (accent wash + a lighter accent label) and the one main action of a window (solid accent, dark label)
    readonly property color group: Qt.alpha(text, light ? 0.045 : 0.032)
    readonly property color field: Qt.alpha(text, light ? 0.07 : 0.05)
    readonly property color chosenFill: Qt.alpha(accent, light ? 0.16 : 0.16)
    readonly property color chosenText: light ? accent : Qt.tint(accent, Qt.alpha("#ffffff", 0.30))
    readonly property color primary: accent
    readonly property color primaryText: light ? "#ffffff" : Qt.hsla(hueOf(accent, 0.62), 0.30, 0.10, 1)
    // an outline the earlier styles draw around a box: none in the new style (a fill marks it instead)
    readonly property int bw: zen ? 0 : 1
    // a box's fill: the new style's faint group fill, or what the earlier styles used there (`was`)
    function box(was) { return zen ? group : was }
    // a small caption: "Power mode" in the new style, as given otherwise
    function capOf(t) { return zen ? cap(t) : t }

    // ---------- shape (concentric: inner radius = outer radius - padding) ----------
    readonly property int rSm: calm ? 12 : 10
    readonly property int rMd: calm ? 16 : 14
    readonly property int rLg: zen ? 20 : calm ? 22 : 20
    readonly property int rXl: zen ? 28 : calm ? 30 : 28

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
    readonly property int tTitle: zen ? 18 : calm ? 16 : 15
    readonly property int tDisplay: calm ? 24 : 22
    // a small heading: "POWER MODE" stays as written in the legacy style, the calm one says "Power mode"
    // (short words people only know in capitals stay that way: CPU, GPU, RAM, AI ...)
    readonly property var acronyms: ["CPU", "GPU", "RAM", "AI", "PSS", "BT", "DND", "VPN", "IP", "OSD", "USB", "PDF", "GTK", "QT", "SSH", "UI", "PIN"]
    function cap(t) {
        t = String(t)
        if (!calm) return t
        var acr = acronyms
        return t.split(" ").map(function (w, i) {
            var bare = w.replace(/[^A-Za-z]/g, "")
            if (acr.indexOf(bare) >= 0) return w
            w = w.toLowerCase()
            return i === 0 ? w.charAt(0).toUpperCase() + w.substring(1) : w
        }).join(" ")
    }
    // how strongly the moving stars and constellations show behind dialogs (the calm style keeps them, softly)
    readonly property real decor: zen ? 0.35 : calm ? 0.55 : 1

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
    // the Halcyon sky's dithered glow (sky.frag compiled, LiveSky.qml); "" = the Canvas gradients
    property string skyShader: ""
    property string lastRawPalette: ""

    // ---------- motion ----------
    // one signature curve: a gentle spring. It slips about 3 % past its target and settles slowly (calm, because the times below are long).
    // curveSoft:
    // curveCalm: no overshoot. A box joined to the screen border (frameOn) must not overshoot or it would pull away from the border
    // for a moment, so the border uses the calm one. Want it bouncier? Raise the second number of curveSoft (1.32 = soft, 1.38 = a little more, 1.6 = playful, about 11 %).
    readonly property var curveCalm: [0.33, 0.85, 0.4, 1, 1, 1]
    readonly property var curveSoft: [0.34, 1.32, 0.3, 1, 1, 1]
    readonly property var curve: frameOn ? curveCalm : curveSoft
    // motion scales every island animation: 1 = normal, 0.5 = fast, 0 = instant (Gaming mode uses 0.25)
    property real motion: 1.0
    readonly property int dFast: Math.round(200 * motion)
    readonly property int dMed: Math.round(300 * motion)
    readonly property int dSlow: Math.round(420 * motion)
    // boxes folding back in: a touch quicker than they came out, and a gentle ease-in-out (starts soft, settles soft) instead of the sharp ease-out they open with
    readonly property int dClose: Math.round(320 * motion)
    readonly property var curveClose: [0.45, 0, 0.3, 1, 1, 1]

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
