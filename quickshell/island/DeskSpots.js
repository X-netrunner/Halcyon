.pragma library
// Which screen corner each corner box opens from (Desktop builder > Where the boxes open). One place for the rules, used by
// shell.qml (to anchor the windows), DesktopBuilderWindow.qml (the picture + the buttons) and DesktopBuilder.qml (the summary).
//   notif the notification centre                                      default top-right
//   util  the utilities box   (Wi-Fi, Bluetooth, volume, power ...)   default bottom-right
//   apps  the background apps box                                      default bottom-left
//   term  the console / quick terminal                                 default top-left
// Four boxes across the four corners: always one box per corner. Moving a box onto a taken corner swaps the two.
var order = ["notif", "util", "apps", "term"]
var corners = ["tr", "tl", "br", "bl"]
var defaults = { notif: "tr", util: "br", apps: "bl", term: "tl" }
var names = { notif: "Notifications", util: "Utilities", apps: "Background apps", term: "Console" }
var cornerNames = { tl: "Top-left", tr: "Top-right", bl: "Bottom-left", br: "Bottom-right" }

// How each box opens (Desktop builder > Opens on): opt.boxTrig = { notif: "hover" | "click", ... }. A box that is not in it
// follows Settings > Edge boxes (the global hover / click). trig(opt, id, globalClick) -> true when that box opens on a click.
function trig(opt, id, globalClick) {
    var t = opt && opt.boxTrig ? opt.boxTrig[id] : undefined
    return t === "click" ? true : (t === "hover" ? false : !!globalClick)
}
// a copy of opt.boxTrig with one box changed ("default" removes it, so it follows Edge boxes again)
function setTrig(opt, id, v) {
    var o = {}, cur = opt && opt.boxTrig ? opt.boxTrig : {}
    for (var k in cur) if (order.indexOf(k) >= 0 && (cur[k] === "hover" || cur[k] === "click")) o[k] = cur[k]
    if (v === "hover" || v === "click") o[id] = v; else delete o[id]
    return o
}

// WAKE SPOTS (Desktop builder: drag the tags on the screen picture). Where the pointer touches (hover) or clicks to wake a box is no longer
// tied to its corner: opt.boxZone = { notif: { edge: "top" | "bottom" | "left" | "right", pos: 0..1 }, ... }, pos = how far along that edge (0 = the
// top / left end, 1 = the bottom / right end). A box that is not in it wakes from its own corner as before. The box itself still opens from its corner.
var edges = ["top", "bottom", "left", "right"]
var edgeNames = { top: "top edge", bottom: "bottom edge", left: "left edge", right: "right edge" }
var shortNames = { notif: "Notif", util: "Utils", apps: "Apps", term: "Console" }
// one valid zone or null
function zoneOf(opt, id) {
    var z = opt && opt.boxZone ? opt.boxZone[id] : null
    if (!z || edges.indexOf(z.edge) < 0) return null
    var p = Number(z.pos)
    if (isNaN(p)) p = 0.5
    return { edge: z.edge, pos: Math.max(0, Math.min(1, p)) }
}
// a copy of opt.boxZone with one box moved (edge = "" puts it back on its corner)
function setZone(opt, id, edge, pos) {
    var o = {}
    for (var i = 0; i < order.length; i++) { var z = zoneOf(opt, order[i]); if (z) o[order[i]] = z }
    if (order.indexOf(id) >= 0) {
        if (edge && edges.indexOf(edge) >= 0) o[id] = { edge: edge, pos: Math.round(Math.max(0, Math.min(1, pos)) * 1000) / 1000 }
        else delete o[id]
    }
    return o
}
function zoneText(opt, id) {
    var z = zoneOf(opt, id)
    return z ? edgeNames[z.edge] + ", " + Math.round(z.pos * 100) + " %" : "its corner"
}
function anyZone(opt) {
    for (var i = 0; i < order.length; i++) if (zoneOf(opt, order[i])) return true
    return false
}

// What "Reset the desktop" puts back (Settings > Desktop builder and the builder window use the same list; boxSpots is reset on its own)
var resetValues = {
    deskWall: true, deskBlur: 0, deskBg: "theme",
    deskStars: false, deskStarCount: 70, deskStarSpeed: 1, deskStarSize: 1, deskStarDir: "right", deskStarTone: "mix", deskStarTwinkle: true, deskStarShoot: false,
    deskNotes: "off", notifSpot: "edge", boxOut: "corner"
}

// true when nothing of the desktop builder differs from the defaults (the "Reset" button greys out then)
function allDefault(opt) {
    if (!opt) return true
    // every value "Reset the desktop" puts back (it only looked at a few of them: changing the stars' speed, size, colour ... while the
    // stars were off left the Reset button greyed out, although there was something to reset)
    for (var k in resetValues) if (opt[k] !== undefined && opt[k] !== resetValues[k]) return false
    if (opt.boxTrig && Object.keys(opt.boxTrig).length > 0) return false
    if (anyZone(opt)) return false
    return isDefault(opt.boxSpots)
}

function clone(o) { return { notif: (o && o.notif) || "tr", util: (o && o.util) || "br", apps: (o && o.apps) || "bl", term: (o && o.term) || "tl" } }

// anything (null, half-filled, duplicated) -> a valid one-box-per-corner map
function normalize(o) {
    if (!o) return clone(defaults)
    var r = {}, seen = {}
    for (var i = 0; i < order.length; i++) {
        var v = o[order[i]]
        if (!v || corners.indexOf(v) < 0 || seen[v]) {
            // If invalid or missing, fill with an unused corner
            for (var c = 0; c < corners.length; c++) {
                if (!seen[corners[c]]) { v = corners[c]; break }
            }
        }
        seen[v] = true
        r[order[i]] = v
    }
    return r
}

function move(o, id, to) {
    var cur = normalize(o)
    if (corners.indexOf(to) < 0 || order.indexOf(id) < 0 || cur[id] === to) return cur
    var r = clone(cur)
    for (var i = 0; i < order.length; i++) if (cur[order[i]] === to) r[order[i]] = cur[id]
    r[id] = to
    return r
}

function isDefault(o) {
    var c = normalize(o)
    for (var i = 0; i < order.length; i++) if (c[order[i]] !== defaults[order[i]]) return false
    return true
}

function boxAt(o, corner) {
    var c = normalize(o)
    for (var i = 0; i < order.length; i++) if (c[order[i]] === corner) return order[i]
    return ""
}

function summary(o, opt) {
    var c = normalize(o)
    var parts = []
    for (var i = 0; i < order.length; i++) parts.push(names[order[i]] + ": " + cornerNames[c[order[i]]].toLowerCase() + (zoneOf(opt, order[i]) ? " (wakes at the " + zoneText(opt, order[i]) + ")" : ""))
    return parts.join("  ·  ")
}
