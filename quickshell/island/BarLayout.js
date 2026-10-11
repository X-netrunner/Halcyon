.pragma library

// The bar builder's data (Settings > Bar style = Custom). One list of widgets, three zones, and the rules for editing them.
// The layout is saved in settings.json as opt.barLayout =
//   { left: [ids], center: [ids], right: [ids],
//     shape: "notch" | "island",          the bar's look: hangs from the top edge with flared corners, or floats as a rounded pill
//     edge:  px | null,                   padding between the bar's ends and the first / last widget   (null = automatic)
//     gap:   px | null,                   space between two widgets                                    (null = automatic)
//     clear: px | null,                   space between the left / right widgets and the middle        (null = automatic)
//     pads:  { id: px } }                 extra space on both sides of one widget
// Used by CustomBar.qml (draws it) and BarBuilder.qml (the editor in Settings).

var zones = ["left", "center", "right"]
var shapes = ["notch", "island"]
var padKeys = ["edge", "gap", "clear"]
var padMax = { edge: 80, gap: 60, clear: 120 }
var widgetPadMax = 40

var catalog = [
    { id: "workspaces", name: "Workspaces",         short: "Workspaces", hint: "The capsules: the current one big and vivid" },
    { id: "specials",   name: "Special workspaces", short: "Specials",   hint: "Scratch, music, monitor ... icons (only the ones in use)" },
    { id: "music",      name: "Music bars",         short: "Music",      hint: "The visualizer; dots while nothing plays" },
    { id: "clock",      name: "Clock",              short: "Clock",      hint: "Click = drop-down, right click = 12 / 24 h, middle click = seconds" },
    { id: "date",       name: "Date",               short: "Date",       hint: "Day and date" },
    { id: "stats",      name: "CPU · RAM · TEMP",   short: "Stats",      hint: "Live numbers, always visible" },
    { id: "status",     name: "Status ring",        short: "Status",     hint: "Wi-Fi, battery ring and Bluetooth dots in one round icon" },
    { id: "wifi",       name: "Wi-Fi",              short: "Wi-Fi",      hint: "Look: Settings > Bar style > Wi-Fi look" },
    { id: "bluetooth",  name: "Bluetooth",          short: "BT",         hint: "Follows Settings > Bar style > Bluetooth" },
    { id: "battery",    name: "Battery",            short: "Battery",    hint: "A pill; the percentage is a switch in Bar style" },
    { id: "caffeine",   name: "Caffeine",           short: "Caffeine",   hint: "Shows only while the screen is kept awake" },
    { id: "focus",      name: "Focus timer",        short: "Focus",      hint: "Shows only while a Focus session runs" },
    { id: "bgapps",     name: "Background apps",    short: "Bg apps",    hint: "How many apps are alive in the background (click = list)" }
]

function nameOf(id) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].id === id) return catalog[i].name
    return id
}
function shortOf(id) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].id === id) return catalog[i].short
    return id
}
function hintOf(id) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].id === id) return catalog[i].hint
    return ""
}

function defaults() {
    return {
        left: ["workspaces", "specials"],
        center: ["music", "clock"],
        right: ["bgapps", "focus", "caffeine", "status"],
        shape: "notch", edge: null, gap: null, clear: null, pads: {}
    }
}

// px value or null (= automatic)
function num(v, max) {
    if (v === null || v === undefined || v === "") return null
    var n = Math.round(Number(v))
    if (isNaN(n)) return null
    return Math.max(0, Math.min(max, n))
}

// whatever was saved -> a clean layout: known widgets only, each at most once, three arrays
function normalize(l) {
    if (!l || typeof l !== "object") return defaults()
    var known = {}, seen = {}
    for (var i = 0; i < catalog.length; i++) known[catalog[i].id] = true
    var out = { left: [], center: [], right: [] }
    for (var z = 0; z < zones.length; z++) {
        var a = l[zones[z]]
        if (!a || a.length === undefined) continue
        for (var j = 0; j < a.length; j++) {
            var id = String(a[j])
            if (known[id] && !seen[id]) { seen[id] = true; out[zones[z]].push(id) }
        }
    }
    out.shape = shapes.indexOf(l.shape) >= 0 ? l.shape : "notch"
    out.edge = num(l.edge, padMax.edge)
    out.gap = num(l.gap, padMax.gap)
    out.clear = num(l.clear, padMax.clear)
    out.pads = {}
    if (l.pads && typeof l.pads === "object")
        for (var k in l.pads) {
            var pv = num(l.pads[k], widgetPadMax)
            if (known[k] && pv !== null && pv > 0) out.pads[k] = pv
        }
    return out
}

// the same layout with other zone lists (everything else is carried over)
function build(l, left, center, right) {
    var pads = {}
    for (var k in l.pads) pads[k] = l.pads[k]
    return { left: left, center: center, right: right, shape: l.shape, edge: l.edge, gap: l.gap, clear: l.clear, pads: pads }
}

function setShape(l, s) {
    var o = build(l, l.left.slice(), l.center.slice(), l.right.slice())
    o.shape = shapes.indexOf(s) >= 0 ? s : "notch"
    return o
}

// key: edge | gap | clear ; v: px, or null for automatic
function setNum(l, key, v) {
    var o = build(l, l.left.slice(), l.center.slice(), l.right.slice())
    if (padKeys.indexOf(key) >= 0) o[key] = num(v, padMax[key])
    return o
}

// extra space around one widget (0 = none)
function setPad(l, id, v) {
    var o = build(l, l.left.slice(), l.center.slice(), l.right.slice())
    var n = num(v, widgetPadMax)
    if (n === null || n <= 0) delete o.pads[id]; else o.pads[id] = n
    return o
}

function padOf(l, id) { return l.pads && l.pads[id] ? l.pads[id] : 0 }

// the numbers the bar really uses (the saved ones, or the automatic ones for this bar height and spacing)
function resolve(l, barH, spacious) {
    return {
        edge: l.edge !== null ? l.edge : Math.round(barH * (spacious ? 0.95 : 0.62)),
        gap: l.gap !== null ? l.gap : Math.max(4, Math.round(barH * (spacious ? 0.28 : 0.17))),
        clear: l.clear !== null ? l.clear : Math.round(barH * (spacious ? 1.1 : 0.3)),
        autoRightGap: Math.round(barH * (spacious ? 0.5 : 0.3)),
        autoMidGap: Math.round(barH * (spacious ? 0.7 : 0.3))
    }
}

function copy(l) {
    return build(l, l.left.slice(), l.center.slice(), l.right.slice())
}

function placed(l, id) {
    for (var z = 0; z < zones.length; z++) if (l[zones[z]].indexOf(id) >= 0) return true
    return false
}

function remove(l, id) {
    var o = build(l, [], [], [])
    for (var z = 0; z < zones.length; z++) {
        var a = l[zones[z]]
        for (var i = 0; i < a.length; i++) if (a[i] !== id) o[zones[z]].push(a[i])
    }
    return o
}

// put a widget at the end of a zone (moves it if it was somewhere else)
function add(l, id, zone) {
    var o = remove(l, id)
    o[zone].push(id)
    return o
}

// move the widget at position i of a zone one step up (-1) or down (+1) the list
function step(l, zone, i, d) {
    var o = copy(l), a = o[zone], j = i + d
    if (j < 0 || j >= a.length) return o
    var t = a[i]; a[i] = a[j]; a[j] = t
    return o
}

// move the widget at position i of a zone to the previous (-1) or next (+1) zone
function hop(l, zone, i, d) {
    var zi = zones.indexOf(zone) + d
    if (zi < 0 || zi >= zones.length) return l
    var id = l[zone][i]
    var o = remove(l, id)
    // keep it near the middle of the screen: first in the zone it joins from the right, last when it joins from the left
    if (d > 0) o[zones[zi]].unshift(id); else o[zones[zi]].push(id)
    return o
}

// drop a widget into a zone at position idx (moves it if it was somewhere else). idx counts the zone WITHOUT the widget.
function place(l, id, zone, idx) {
    var o = remove(l, id)
    var a = o[zone]
    var i = Math.max(0, Math.min(a.length, idx))
    a.splice(i, 0, id)
    return o
}

// ---------------------------------------------------------------- symmetry help (used by the builder window)
// width of a list of widgets side by side. widthOf(id) = the widget's own width, gap = space between two widgets.
function zoneWidth(l, ids, widthOf, gap) {
    var w = 0
    for (var i = 0; i < ids.length; i++) w += widthOf(ids[i]) + 2 * padOf(l, ids[i])
    return w + Math.max(0, ids.length - 1) * gap
}

// How far apart the left and right sides are, in px (0 = mirrored). The middle is always centred; this is about the two sides matching.
function sideDiff(l, widthOf, gapL, gapR) {
    return zoneWidth(l, l.left, widthOf, gapL) - zoneWidth(l, l.right, widthOf, gapR)
}

// The one move (a widget from the wider side to the other side, next to the middle) that brings the sides closest to each other.
// null when the sides already match (within tol px) or no move helps.
function bestMove(l, widthOf, gapL, gapR, tol) {
    var d0 = sideDiff(l, widthOf, gapL, gapR)
    if (Math.abs(d0) <= tol) return null
    var from = d0 > 0 ? "left" : "right", to = d0 > 0 ? "right" : "left"
    var best = null, bd = Math.abs(d0)
    for (var i = 0; i < l[from].length; i++) {
        var id = l[from][i]
        var o = hop(l, from, i, from === "left" ? 1 : -1)
        var ad = Math.abs(sideDiff(o, widthOf, gapL, gapR))
        if (ad < bd) { bd = ad; best = { id: id, from: from, to: to, before: Math.abs(d0), after: ad, layout: o } }
    }
    return best
}
