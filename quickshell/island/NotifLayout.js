.pragma library

// The notification box builder's layout (opt.notifLayout). Anything stored there is cleaned up by normalize(), so an old or
// hand-edited value can never break the box. null / missing = the default box (what it looked like before the builder).
//
//   blocks    the parts of the box, top to bottom; each can be switched off and moved up or down
//               sky     the constellation band (drifting dots, your profile constellation or the mode art)
//               header  the title, the count, the DND and Clear buttons
//               list    the notifications (the look comes from Settings > Notification style)
//   skyH      height of the constellation band in px (0 = automatic). The band only takes room while there is a constellation to draw
//   art       (kept for old settings, not used any more: switch the band off with its Shown / Hidden button)
//   dots      drifting dots behind the whole box (they take no room)
//   behind    the constellation also fills the whole box, faintly, behind everything
//   fly       small stars flying across the whole box (the ones on the bar), 0 = none
//   toastStars  the same flying stars in the popups
//   pad       space between the box's edge and what is inside, px
//   gap       space between the blocks, px
//   rowGap    space between notifications, px (Stack and Grouped looks)
//   radius    roundness of the box's corners, px
//   width     width of the box, px
//   vpos      top | middle | bottom : where the box sits on its edge of the screen
//   offY      distance from the top or bottom edge, relative to the default (px, negative = closer to the edge; the box never goes
//             nearer than 8 px to it). Not used for middle.

var ids = ["sky", "header", "list"]
var names = { sky: "Constellation band", header: "Title and buttons", list: "Notifications" }
var limits = {
    skyH: [0, 260], dots: [0, 24], fly: [0, 20],
    pad: [8, 36], gap: [4, 28], rowGap: [2, 24], radius: [8, 40], width: [320, 560], offY: [-120, 300]
}

function defaults() {
    return {
        v: 1,
        blocks: [{ id: "sky", on: true }, { id: "header", on: true }, { id: "list", on: true }],
        skyH: 0, art: true, dots: 10, behind: false, fly: 9, toastStars: true,
        pad: 18, gap: 12, rowGap: 10, radius: 28, width: 392, vpos: "top", offY: 0,
        corner: "tr", spot: "edge"
    }
}

function clamp(k, v) {
    var lim = limits[k], n = Math.round(Number(v))
    if (isNaN(n)) return defaults()[k]
    return Math.max(lim[0], Math.min(lim[1], n))
}

function normalize(l) {
    var d = defaults()
    if (!l || typeof l !== "object") return d
    var out = JSON.parse(JSON.stringify(d))
    // blocks: keep the order and the on/off of the ones that are valid, then add any that are missing at their default place
    var seen = {}, list = []
    // not Array.isArray: once the layout has been through a QML property (the saved settings) the list is an array-like, not a
    // real array, and that test fails: every edit of the parts was thrown away and the default order came back
    var src = (l.blocks && typeof l.blocks.length === "number") ? l.blocks : []
    for (var i = 0; i < src.length; i++) {
        var b = src[i]
        if (b && ids.indexOf(b.id) >= 0 && !seen[b.id]) { seen[b.id] = true; list.push({ id: b.id, on: b.on !== false }) }
    }
    for (var j = 0; j < ids.length; j++) if (!seen[ids[j]]) list.push({ id: ids[j], on: true })
    out.blocks = list
    var nums = ["skyH", "dots", "fly", "pad", "gap", "rowGap", "radius", "width", "offY"]
    for (var k = 0; k < nums.length; k++) if (l[nums[k]] !== undefined) out[nums[k]] = clamp(nums[k], l[nums[k]])
    out.art = l.art !== false
    out.behind = l.behind === true
    out.toastStars = l.toastStars !== false
    out.vpos = (l.vpos === "middle" || l.vpos === "bottom") ? l.vpos : "top"
    out.corner = (l.corner === "tl" || l.corner === "bl" || l.corner === "br") ? l.corner : "tr"
    out.spot = (l.spot === "corner") ? "corner" : "edge"
    return out
}

function edit(cur, key, val) {
    var o = JSON.parse(JSON.stringify(normalize(cur)))
    o[key] = limits[key] ? clamp(key, val) : val
    return o
}
function toggleBlock(cur, id) {
    var o = JSON.parse(JSON.stringify(normalize(cur)))
    for (var i = 0; i < o.blocks.length; i++) if (o.blocks[i].id === id) o.blocks[i].on = !o.blocks[i].on
    return o
}
// dir: -1 = up, +1 = down
function moveBlock(cur, id, dir) {
    var o = JSON.parse(JSON.stringify(normalize(cur)))
    var i = -1
    for (var k = 0; k < o.blocks.length; k++) if (o.blocks[k].id === id) i = k
    var j = i + dir
    if (i < 0 || j < 0 || j >= o.blocks.length) return o
    var t = o.blocks[i]; o.blocks[i] = o.blocks[j]; o.blocks[j] = t
    return o
}
function isDefault(cur) { return JSON.stringify(normalize(cur)) === JSON.stringify(defaults()) }
function summary(cur) {
    var c = normalize(cur), on = []
    for (var i = 0; i < c.blocks.length; i++) if (c.blocks[i].on) on.push(names[c.blocks[i].id])
    var cornerNames = { tl: "Top-left", tr: "Top-right", bl: "Bottom-left", br: "Bottom-right" }
    var spotNames = { edge: "screen edge", corner: "corner trigger" }
    return c.width + " px wide · " + cornerNames[c.corner] + " (" + spotNames[c.spot] + ") · " + (c.fly > 0 ? c.fly + " flying stars" : "no flying stars") + " · " + on.join(", ")
}
