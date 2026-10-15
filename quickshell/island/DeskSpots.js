.pragma library
// Which screen corner each corner box opens from (Desktop builder > Where the boxes open). One place for the rules, used by
// shell.qml (to anchor the windows), DesktopBuilderWindow.qml (the picture + the buttons) and DesktopBuilder.qml (the summary).
//   util  the utilities box   (Wi-Fi, Bluetooth, volume, power ...)   default bottom-right
//   apps  the background apps box                                      default bottom-left
//   term  the console / quick terminal                                 default top-left
// The top-right corner belongs to the notification centre, so these three share top-left, bottom-left and bottom-right:
// always one box per corner. Moving a box onto a taken corner swaps the two.
var order = ["util", "apps", "term"]
var corners = ["tl", "bl", "br"]
var defaults = { util: "br", apps: "bl", term: "tl" }
var names = { util: "Utilities", apps: "Background apps", term: "Console" }
var cornerNames = { tl: "Top-left", tr: "Top-right", bl: "Bottom-left", br: "Bottom-right" }

function clone(o) { return { util: o.util, apps: o.apps, term: o.term } }

// anything (null, half-filled, duplicated) -> a valid one-box-per-corner map
function normalize(o) {
    if (!o) return clone(defaults)
    var r = {}, seen = {}
    for (var i = 0; i < order.length; i++) {
        var v = o[order[i]]
        if (corners.indexOf(v) < 0 || seen[v]) return clone(defaults)
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

function summary(o) {
    var c = normalize(o)
    var parts = []
    for (var i = 0; i < order.length; i++) parts.push(names[order[i]] + ": " + cornerNames[c[order[i]]].toLowerCase())
    return parts.join("  ·  ")
}
