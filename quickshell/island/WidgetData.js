.pragma library

// The desktop widgets' data (Desktop builder = where they sit, Widget builder = how each one looks).
// One place for the list of widget types, their layouts ("styles"), their options and the rules for editing them. Used by
// DeskWidgets.qml (draws them), WidgetHost.qml (the frame), WidgetBuilderWindow.qml (the per-widget editor),
// DesktopBuilderWindow.qml (the overview) and WidgetBuilder.qml (the Settings entry).
//
// Saved in settings.json as opt.deskWidgets = { items: [ item, ... ] } and opt.deskStyles = [ { name, look }, ... ]
//   item = { uid, type, px, py, scale, style, opts: { key: value }, look: { ... } }
//     px, py  0 .. 1: where the widget sits inside the free room of the screen (0 = against the left / top margin,
//             1 = against the right / bottom margin, 0.5 = centred). So a widget can never fall off the screen and the
//             layout still fits on another resolution.
//     scale   0.5 .. 2.5: the whole widget bigger or smaller
//     style   one of the type's layouts (catalog[type].styles)
//     look    the surface and colours: see lookDefaults

// ------------------------------------------------------------------------------------------------ catalog
// size = the widget's rough size at scale 1 [w, h] (only used for the little pictures in the builders)
// opts: kind toggle | chips | slider | text | multi.   chips: options [[id, "Label"], ...]   multi: the same, several may be on
var cats = [["time", "Time"], ["system", "System"], ["media", "Media"], ["focus", "Focus"], ["desk", "Desktop"], ["info", "Info"]]

var catalog = [
    { id: "clock", cat: "time", name: "Clock", icon: 0xF0150, size: [220, 90], hint: "The time, in five looks",
      styles: [["digital", "Digital"], ["big", "Big"], ["stacked", "Stacked"], ["analog", "Analog"], ["minimal", "Minimal"]],
      opts: [
        { k: "h24", kind: "chips", label: "Hours", def: "follow", options: [["follow", "Like the bar"], ["12", "12 h"], ["24", "24 h"]] },
        { k: "seconds", kind: "toggle", label: "Show seconds", def: false },
        { k: "date", kind: "toggle", label: "Show the date", def: true },
        { k: "ampm", kind: "toggle", label: "Show AM / PM", def: true }
      ] },
    { id: "date", cat: "time", name: "Date", icon: 0xF00ED, size: [200, 70], hint: "Day and date",
      styles: [["line", "One line"], ["card", "Card"], ["stack", "Stacked"]],
      opts: [{ k: "year", kind: "toggle", label: "Show the year", def: false }] },
    { id: "month", cat: "time", name: "Month calendar", icon: 0xF0E17, size: [250, 230], hint: "The month, today lit",
      styles: [["grid", "Month grid"], ["week", "Week strip"]],
      opts: [
        { k: "mon", kind: "chips", label: "Week starts", def: "mon", options: [["mon", "Monday"], ["sun", "Sunday"]] },
        { k: "weeks", kind: "toggle", label: "Week numbers", def: false }
      ] },
    { id: "cpu", cat: "system", name: "CPU", icon: 0xF061A, size: [120, 120], hint: "Processor load", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "ram", cat: "system", name: "Memory", icon: 0xF035B, size: [120, 120], hint: "RAM in use", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }, { k: "gb", kind: "toggle", label: "Show GB, not %", def: false }] },
    { id: "temp", cat: "system", name: "Temperature", icon: 0xF050F, size: [120, 120], hint: "CPU temperature", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "gpu", cat: "system", name: "GPU", icon: 0xF0379, size: [120, 120], hint: "Graphics load (when the machine reports it)", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "disk", cat: "system", name: "Disk", icon: 0xF02CA, size: [120, 120], hint: "How full the main disk is", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "battery", cat: "system", name: "Battery", icon: 0xF0079, size: [120, 120], hint: "Charge, and charging", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }, { k: "hideNoBat", kind: "toggle", label: "Hide on a desktop PC", def: true }] },
    { id: "volume", cat: "system", name: "Volume", icon: 0xF057E, size: [120, 120], hint: "Speaker volume (scroll on it to change)", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "brightness", cat: "system", name: "Brightness", icon: 0xF00DF, size: [120, 120], hint: "Screen brightness (scroll on it to change)", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "sysmon", cat: "system", name: "System usage", icon: 0xF04C5, size: [260, 150], hint: "CPU, memory, temperature, disk and network together",
      styles: [["bars", "Bars"], ["rings", "Rings"], ["list", "List"], ["compact", "Compact"]],
      opts: [
        { k: "show", kind: "multi", label: "Show", def: ["cpu", "ram", "temp", "net"], options: [["cpu", "CPU"], ["ram", "Memory"], ["temp", "Temp"], ["disk", "Disk"], ["gpu", "GPU"], ["net", "Network"]] },
        { k: "width", kind: "slider", label: "Width", def: 260, min: 180, max: 460, unit: " px" }
      ] },
    { id: "net", cat: "system", name: "Network", icon: 0xF05A9, size: [220, 90], hint: "Wi-Fi name and signal, and the speed",
      styles: [["card", "Card"], ["speed", "Speed only"], ["signal", "Signal bars"]],
      opts: [{ k: "ssid", kind: "toggle", label: "Show the Wi-Fi name", def: true }] },
    { id: "uptime", cat: "system", name: "Uptime", icon: 0xF0150, size: [200, 70], hint: "How long the computer has been on",
      styles: [["line", "One line"], ["card", "Card"]], opts: [] },
    { id: "music", cat: "media", name: "Now playing", icon: 0xF075A, size: [320, 120], hint: "The song, the cover and the buttons",
      styles: [["card", "Card"], ["compact", "Compact"], ["cover", "Cover"], ["minimal", "Minimal"]],
      opts: [
        { k: "controls", kind: "toggle", label: "Buttons", def: true },
        { k: "progress", kind: "toggle", label: "Progress bar", def: true },
        { k: "width", kind: "slider", label: "Width", def: 320, min: 220, max: 520, unit: " px" },
        { k: "hideIdle", kind: "toggle", label: "Hide while nothing plays", def: false }
      ] },
    { id: "viz", cat: "media", name: "Audio visualizer", icon: 0xF075A, size: [280, 90], hint: "Bars that move with the music (needs cava)",
      styles: [["bars", "Bars"], ["mirror", "Mirror"], ["wave", "Wave"], ["dots", "Dots"], ["circle", "Circle"]],
      opts: [
        { k: "count", kind: "slider", label: "Bars", def: 24, min: 8, max: 48, unit: "" },
        { k: "width", kind: "slider", label: "Width", def: 280, min: 120, max: 700, unit: " px" },
        { k: "height", kind: "slider", label: "Height", def: 90, min: 40, max: 240, unit: " px" },
        { k: "idle", kind: "chips", label: "While silent", def: "dots", options: [["dots", "Resting dots"], ["hide", "Hide it"]] }
      ] },
    { id: "focus", cat: "focus", name: "Focus timer & streak", icon: 0xF051B, size: [220, 120], hint: "The focus session and how many days in a row you kept it",
      styles: [["ring", "Ring"], ["card", "Card"], ["compact", "Compact"], ["streak", "Streak"]],
      opts: [
        { k: "goal", kind: "slider", label: "Minutes that count as a focus day", def: 25, min: 5, max: 180, unit: " min" },
        { k: "streak", kind: "toggle", label: "Show the streak", def: true },
        { k: "buttons", kind: "toggle", label: "Start / stop button", def: true },
        { k: "week", kind: "toggle", label: "Last 7 days", def: true }
      ] },
    { id: "workspaces", cat: "desk", name: "Workspaces", icon: 0xF0208, size: [260, 50], hint: "Switch workspace (click, scroll)",
      styles: [["dots", "Dots"], ["numbers", "Numbers"], ["capsules", "Capsules"], ["pills", "Pills"]],
      opts: [{ k: "min", kind: "slider", label: "Always show at least", def: 5, min: 1, max: 10, unit: "" }] },
    { id: "toggles", cat: "desk", name: "Quick toggles", icon: 0xF0521, size: [300, 70], hint: "Buttons for Wi-Fi, Bluetooth, Do not disturb, Caffeine, Gaming, Num Lock ...",
      styles: [["row", "Row"], ["grid", "Grid"], ["icons", "Icons only"]],
      opts: [
        { k: "show", kind: "multi", label: "Buttons", def: ["wifi", "bt", "dnd", "caffeine", "gaming", "theme"], options: [["wifi", "Wi-Fi"], ["bt", "Bluetooth"], ["dnd", "Do not disturb"], ["caffeine", "Caffeine"], ["gaming", "Gaming"], ["numlock", "Num Lock"], ["theme", "Theme"], ["night", "Night light"], ["lock", "Lock"], ["power", "Power"]] }
      ] },
    { id: "shortcuts", cat: "desk", name: "App shortcuts", icon: 0xF003B, size: [300, 70], hint: "Your own buttons that start apps or commands",
      styles: [["row", "Row"], ["grid", "Grid"], ["list", "List"]],
      opts: [{ k: "items", kind: "text", label: "Buttons", def: "Browser=xdg-open https://;Files=thunar;Terminal=kitty", hintText: "Name=command;Name=command" }] },
    { id: "notes", cat: "desk", name: "Notes & agenda", icon: 0xF03EB, size: [290, 150], hint: "Your pinned notes and today's calendar",
      styles: [["glass", "List"], ["cards", "Cards"]],
      opts: [
        { k: "events", kind: "toggle", label: "Today's calendar", def: false },
        { k: "max", kind: "slider", label: "Most lines", def: 4, min: 1, max: 8, unit: "" },
        { k: "width", kind: "slider", label: "Width", def: 290, min: 200, max: 480, unit: " px" }
      ] },
    { id: "weather", cat: "info", name: "Weather", icon: 0xF0590, size: [220, 100], hint: "Temperature and sky (asks wttr.in every 30 minutes)",
      styles: [["card", "Card"], ["compact", "Compact"], ["big", "Big"]],
      opts: [
        { k: "place", kind: "text", label: "Place (empty = by your address)", def: "", hintText: "Berlin" },
        { k: "unit", kind: "chips", label: "Unit", def: "c", options: [["c", "Celsius"], ["f", "Fahrenheit"]] }
      ] },
    { id: "text", cat: "info", name: "Text & greeting", icon: 0xF0757, size: [260, 60], hint: "A greeting, or any words you want on the desktop",
      styles: [["greeting", "Greeting"], ["plain", "Plain text"], ["quote", "Quote"]],
      opts: [{ k: "text", kind: "text", label: "Your text", def: "Stay curious.", hintText: "what to say" }] }
]

function typeOf(id) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].id === id) return catalog[i]
    return null
}
function nameOf(id) { var t = typeOf(id); return t ? t.name : id }
function iconOf(id) { var t = typeOf(id); return t ? t.icon : 0xF0A1A }
function hintOf(id) { var t = typeOf(id); return t ? t.hint : "" }

// which QML file draws each type
var files = {
    clock: "WClock.qml", date: "WClock.qml", month: "WMonth.qml",
    cpu: "WMetric.qml", ram: "WMetric.qml", temp: "WMetric.qml", gpu: "WMetric.qml", disk: "WMetric.qml", battery: "WMetric.qml", volume: "WMetric.qml", brightness: "WMetric.qml",
    sysmon: "WSysmon.qml", net: "WNet.qml", uptime: "WNet.qml",
    music: "WMusic.qml", viz: "WViz.qml", focus: "WFocus.qml", workspaces: "WWorkspaces.qml", toggles: "WToggles.qml", shortcuts: "WToggles.qml",
    notes: "WNotes.qml", weather: "WWeather.qml", text: "WText.qml"
}
function fileOf(type) { return files[type] || "WText.qml" }

// ------------------------------------------------------------------------------------------------ looks (the surface and the colours)
//   surface  glass | solid | clear | outline | pill
//   op       how solid the surface is, 0.1 .. 1
//   radius   corner radius in px, -1 = automatic
//   pad      room between the surface and the content in px, -1 = automatic
//   tone     theme | second | custom : the colour of lit parts (accent)
//   color    #rrggbb for tone = custom
//   textTone theme | custom   ;  textColor  #rrggbb
//   font     ui | mono
//   fs       0.7 .. 1.6 : text size
//   border   a hairline around it     shadow  a soft shadow
var lookDefaults = { surface: "glass", op: 0.65, radius: -1, pad: -1, tone: "theme", color: "#9aa9d4", textTone: "theme", textColor: "#ffffff", font: "ui", fs: 1, border: true, shadow: true }
var surfaces = [["glass", "Frosted glass"], ["solid", "Solid"], ["clear", "No box"], ["outline", "Outline"], ["pill", "Pill"]]
var tones = [["theme", "Wallpaper accent"], ["second", "Second colour"], ["custom", "My colour"]]
var swatches = ["#9aa9d4", "#f5a623", "#e58a8a", "#8fcfa0", "#7ec8e3", "#c2add8", "#ffd166", "#ffffff"]

// built-in styles (the Widget builder lists these, and your saved ones, under "Styles")
var presets = [
    { name: "Glass", look: { surface: "glass", op: 0.65, radius: -1, pad: -1, tone: "theme", font: "ui", fs: 1, border: true, shadow: true } },
    { name: "Clear", look: { surface: "clear", op: 0.0, radius: -1, pad: 4, tone: "theme", font: "ui", fs: 1, border: false, shadow: false } },
    { name: "Solid card", look: { surface: "solid", op: 0.94, radius: 16, pad: -1, tone: "theme", font: "ui", fs: 1, border: true, shadow: true } },
    { name: "Outline", look: { surface: "outline", op: 0.0, radius: 14, pad: -1, tone: "theme", font: "ui", fs: 1, border: true, shadow: false } },
    { name: "Terminal", look: { surface: "solid", op: 0.88, radius: 6, pad: 12, tone: "second", font: "mono", fs: 0.92, border: true, shadow: false } },
    { name: "Pill", look: { surface: "pill", op: 0.7, radius: 999, pad: 10, tone: "theme", font: "ui", fs: 0.95, border: true, shadow: true } },
    { name: "Neon", look: { surface: "outline", op: 0.0, radius: 12, pad: -1, tone: "custom", color: "#7ef2d0", font: "mono", fs: 1, border: true, shadow: true } }
]

function clamp(v, a, b) { return Math.max(a, Math.min(b, v)) }
function num(v, d) { var n = Number(v); return isNaN(n) ? d : n }

// anything saved -> a complete look
function look(l) {
    var o = {}
    for (var k in lookDefaults) o[k] = lookDefaults[k]
    if (l && typeof l === "object") for (var x in l) if (x in lookDefaults) o[x] = l[x]
    if (["glass", "solid", "clear", "outline", "pill"].indexOf(o.surface) < 0) o.surface = "glass"
    if (["theme", "second", "custom"].indexOf(o.tone) < 0) o.tone = "theme"
    if (["theme", "custom"].indexOf(o.textTone) < 0) o.textTone = "theme"
    if (o.font !== "mono") o.font = "ui"
    o.op = clamp(num(o.op, 0.65), 0, 1)
    o.radius = Math.round(clamp(num(o.radius, -1), -1, 999))
    o.pad = Math.round(clamp(num(o.pad, -1), -1, 60))
    o.fs = clamp(num(o.fs, 1), 0.6, 1.8)
    o.border = o.border !== false
    o.shadow = o.shadow !== false
    if (!/^#[0-9a-fA-F]{6}$/.test(String(o.color))) o.color = lookDefaults.color
    if (!/^#[0-9a-fA-F]{6}$/.test(String(o.textColor))) o.textColor = lookDefaults.textColor
    return o
}

// ------------------------------------------------------------------------------------------------ items
function optDefault(type, k) {
    var t = typeOf(type)
    if (!t) return undefined
    for (var i = 0; i < t.opts.length; i++) if (t.opts[i].k === k) return t.opts[i].def
    return undefined
}
function optOf(item, k) {
    if (item && item.opts && item.opts[k] !== undefined) return item.opts[k]
    return optDefault(item ? item.type : "", k)
}
function styleList(type) { var t = typeOf(type); return t ? t.styles : [] }
function styleOf(item) {
    var l = styleList(item.type)
    for (var i = 0; i < l.length; i++) if (l[i][0] === item.style) return item.style
    return l.length ? l[0][0] : ""
}

function nextUid(items) {
    var n = 1
    for (var i = 0; i < items.length; i++) {
        var m = /^w(\d+)$/.exec(String(items[i].uid))
        if (m) n = Math.max(n, Number(m[1]) + 1)
    }
    return "w" + n
}

function cleanItem(it, used) {
    if (!it || typeof it !== "object" || !typeOf(it.type)) return null
    var o = { uid: String(it.uid || ""), type: it.type }
    if (o.uid === "" || used[o.uid]) return null
    used[o.uid] = true
    o.px = clamp(num(it.px, 0), 0, 1)
    o.py = clamp(num(it.py, 0), 0, 1)
    o.scale = clamp(num(it.scale, 1), 0.5, 2.5)
    o.style = styleOf({ type: it.type, style: it.style })
    o.opts = {}
    if (it.opts && typeof it.opts === "object") for (var k in it.opts) o.opts[k] = it.opts[k]
    o.look = look(it.look)
    return o
}

// whatever was saved -> a clean list: known types only, unique ids
function normalize(d) {
    var out = { items: [] }
    var used = {}
    var a = d && d.items && d.items.length !== undefined ? d.items : []
    for (var i = 0; i < a.length; i++) {
        var c = cleanItem(a[i], used)
        if (c) out.items.push(c)
    }
    return out
}

function copy(d) { return normalize(JSON.parse(JSON.stringify(d || { items: [] }))) }
function find(d, uid) {
    for (var i = 0; i < d.items.length; i++) if (d.items[i].uid === uid) return d.items[i]
    return null
}

// a new widget of this type, in a free-ish spot, with the default style
function add(d, type, look0) {
    var o = copy(d)
    var t = typeOf(type)
    if (!t) return o
    var n = o.items.length
    var it = { uid: nextUid(o.items), type: type, px: clamp(0.04 + (n % 5) * 0.09, 0, 1), py: clamp(0.14 + (n % 6) * 0.08, 0, 1),
               scale: 1, style: t.styles.length ? t.styles[0][0] : "", opts: {}, look: look(look0) }
    o.items.push(it)
    return o
}
function remove(d, uid) {
    var o = copy(d)
    o.items = o.items.filter(function (i) { return i.uid !== uid })
    return o
}
function duplicate(d, uid) {
    var o = copy(d), src = find(o, uid)
    if (!src) return o
    var c = JSON.parse(JSON.stringify(src))
    c.uid = nextUid(o.items)
    c.px = clamp(src.px + 0.04, 0, 1); c.py = clamp(src.py + 0.06, 0, 1)
    o.items.push(c)
    return o
}
function patch(d, uid, fn) {
    var o = copy(d), it = find(o, uid)
    if (it) fn(it)
    return o
}
function setPos(d, uid, px, py) { return patch(d, uid, function (it) { it.px = clamp(px, 0, 1); it.py = clamp(py, 0, 1) }) }
function setScale(d, uid, s) { return patch(d, uid, function (it) { it.scale = clamp(s, 0.5, 2.5) }) }
function setStyle(d, uid, s) { return patch(d, uid, function (it) { it.style = s }) }
function setOpt(d, uid, k, v) { return patch(d, uid, function (it) { it.opts[k] = v }) }
function setLook(d, uid, k, v) { return patch(d, uid, function (it) { it.look[k] = v; it.look = look(it.look) }) }
function applyLook(d, uid, l) { return patch(d, uid, function (it) { it.look = look(l) }) }
function bringFront(d, uid) {
    var o = copy(d), it = find(o, uid)
    if (!it) return o
    o.items = o.items.filter(function (i) { return i.uid !== uid })
    o.items.push(it)
    return o
}

// ------------------------------------------------------------------------------------------------ places
var spots = [["tl", "Top-left", 0, 0], ["tc", "Top", 0.5, 0], ["tr", "Top-right", 1, 0], ["ml", "Left", 0, 0.5], ["mc", "Centre", 0.5, 0.5], ["mr", "Right", 1, 0.5],
             ["bl", "Bottom-left", 0, 1], ["bc", "Bottom", 0.5, 1], ["br", "Bottom-right", 1, 1]]
function placeAt(d, uid, spotId) {
    for (var i = 0; i < spots.length; i++) if (spots[i][0] === spotId) return setPos(d, uid, spots[i][2], spots[i][3])
    return d
}
function spotName(it) {
    for (var i = 0; i < spots.length; i++) if (Math.abs(spots[i][2] - it.px) < 0.06 && Math.abs(spots[i][3] - it.py) < 0.06) return spots[i][1]
    return Math.round(it.px * 100) + " %, " + Math.round(it.py * 100) + " %"
}

// pixel position of a widget: free = the screen minus the margins and the widget itself
function posX(it, screenW, w, margin) { return Math.round(margin + it.px * Math.max(0, screenW - w - 2 * margin)) }
function posY(it, screenH, h, top, bottom) { return Math.round(top + it.py * Math.max(0, screenH - h - top - bottom)) }
function fracX(x, screenW, w, margin) { var r = screenW - w - 2 * margin; return r <= 0 ? 0 : clamp((x - margin) / r, 0, 1) }
function fracY(y, screenH, h, top, bottom) { var r = screenH - h - top - bottom; return r <= 0 ? 0 : clamp((y - top) / r, 0, 1) }

// the old Desktop builder's notes / calendar choice (opt.deskNotes: off | notes | both) -> one notes widget, once
function migrate(opt) {
    if (!opt) return null
    if (opt.deskWidgets && opt.deskWidgets.items) return null
    var m = opt.deskNotes
    if (m !== "notes" && m !== "both") return null
    var o = add({ items: [] }, "notes")
    o.items[0].px = 0.03; o.items[0].py = 0.12
    o.items[0].opts.events = (m === "both")
    return o
}

// "Name=command;Name=command" -> [{ name, cmd }]
function parseShortcuts(s) {
    var out = [], parts = String(s || "").split(";")
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim()
        if (p === "") continue
        var j = p.indexOf("=")
        if (j < 1) continue
        var n = p.substring(0, j).trim(), c = p.substring(j + 1).trim()
        if (n !== "" && c !== "") out.push({ name: n, cmd: c })
        if (out.length >= 8) break
    }
    return out
}

// which feeds the widgets on the desktop need (shell.qml starts a reader only while one of its widgets exists)
function needs(d) {
    var n = { viz: false, ctl: false, disk: false, gpu: false, numlock: false, weather: false, focusLog: false }
    if (!d || !d.items) return n
    for (var i = 0; i < d.items.length; i++) {
        var t = d.items[i].type
        if (t === "viz") n.viz = true
        if (t === "volume" || t === "brightness") n.ctl = true
        if (t === "disk") n.disk = true
        if (t === "gpu") n.gpu = true
        if (t === "focus") n.focusLog = true
        if (t === "weather") n.weather = true
        if (t === "toggles") {
            var s = optOf(d.items[i], "show") || []
            if (s.indexOf("numlock") >= 0) n.numlock = true
        }
        if (t === "sysmon") {
            var sh = optOf(d.items[i], "show") || []
            if (sh.indexOf("disk") >= 0) n.disk = true
            if (sh.indexOf("gpu") >= 0) n.gpu = true
        }
    }
    return n
}
