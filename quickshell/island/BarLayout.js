.pragma library

// The bar builder's data (Settings > Bar style = Custom). One list of widgets, three zones, and the rules for editing them.
// The layout is saved in settings.json as opt.barLayout = { left: [ids], center: [ids], right: [ids] }.
// Used by CustomBar.qml (draws it) and BarBuilder.qml (the editor in Settings).

var zones = ["left", "center", "right"]

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
        right: ["bgapps", "focus", "caffeine", "status"]
    }
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
    return out
}

function copy(l) {
    return { left: l.left.slice(), center: l.center.slice(), right: l.right.slice() }
}

function placed(l, id) {
    for (var z = 0; z < zones.length; z++) if (l[zones[z]].indexOf(id) >= 0) return true
    return false
}

function remove(l, id) {
    var o = { left: [], center: [], right: [] }
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
