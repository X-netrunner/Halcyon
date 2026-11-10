// The bar builder's data (quickshell/island/BarLayout.js): node tests/bar-layout.test.js
// BarLayout.js is a QML library (".pragma library"), plain JS otherwise, so it loads here with the pragma line removed.
const fs = require("fs"), path = require("path"), vm = require("vm")
const file = path.join(__dirname, "..", "quickshell", "island", "BarLayout.js")
const src = fs.readFileSync(file, "utf8").replace(/^\.pragma library.*$/m, "")
const ctx = {}
vm.createContext(ctx)
vm.runInContext(src + "\nthis.BL = { normalize, defaults, setShape, setSide, setCaps, setNum, setPad, place, add, remove, hop, isVert, zoneTitle, sides, shapes, bestMove, zoneWidth, railMetrics }", ctx)
const BL = ctx.BL

let bad = 0
const eq = (a, b, msg) => { if (JSON.stringify(a) !== JSON.stringify(b)) { bad++; console.log("FAIL " + msg + "\n  got  " + JSON.stringify(a) + "\n  want " + JSON.stringify(b)) } }

// layouts saved before the side bar existed keep working: top edge, capsules on
const old = { left: ["workspaces"], center: ["clock"], right: ["status"], shape: "island", edge: 10, gap: null, clear: null, pads: {} }
const n = BL.normalize(old)
eq(n.side, "top", "an old layout is a top bar")
eq(n.shape, "island", "an old layout keeps its shape")
eq(n.caps, true, "capsules default on")
eq(n.edge, 10, "an old layout keeps its padding")

// nothing / junk -> the default layout
eq(BL.normalize(null).side, "top", "null -> default, top")
eq(BL.normalize("x").shape, "notch", "junk -> default, notch")

// side and shape are validated
eq(BL.normalize({ left: [], center: [], right: [], side: "diagonal" }).side, "top", "unknown side -> top")
eq(BL.normalize({ left: [], center: [], right: [], shape: "blob" }).shape, "notch", "unknown shape -> notch")
for (const s of BL.sides) eq(BL.normalize({ left: [], center: [], right: [], side: s }).side, s, "side " + s + " is kept")
eq(BL.normalize({ left: [], center: [], right: [], shape: "rail" }).shape, "rail", "rail is a shape")
eq(BL.normalize({ left: [], center: [], right: [], caps: false }).caps, false, "caps false is kept")

// every editing function carries the side and caps over (they used to be dropped by build())
let l = BL.normalize({ left: ["workspaces", "clock"], center: ["music"], right: ["status"], shape: "rail", side: "left", caps: false })
for (const [name, o] of Object.entries({
  place: BL.place(l, "clock", "right", 0), add: BL.add(l, "date", "center"), remove: BL.remove(l, "clock"),
  hop: BL.hop(l, "left", 0, 1), setNum: BL.setNum(l, "gap", 9), setPad: BL.setPad(l, "clock", 4), setShape: BL.setShape(l, "island")
})) {
  eq(o.side, "left", name + " keeps the side")
  eq(o.caps, false, name + " keeps caps")
}
eq(BL.setShape(l, "island").shape, "island", "setShape changes the shape")
eq(BL.setSide(l, "bottom").side, "bottom", "setSide changes the side")
eq(BL.setSide(l, "bottom").shape, "rail", "setSide keeps the shape")
eq(BL.setSide(l, "nope").side, "top", "setSide with junk -> top")
eq(BL.setCaps(l, true).caps, true, "setCaps on")
eq(BL.setCaps(BL.setCaps(l, true), false).caps, false, "setCaps off")
eq(BL.setSide(l, "right").left, l.left, "setSide keeps the widgets")

// names of the places
eq(BL.isVert("left"), true, "left is vertical"); eq(BL.isVert("right"), true, "right is vertical")
eq(BL.isVert("top"), false, "top is horizontal"); eq(BL.isVert("bottom"), false, "bottom is horizontal"); eq(BL.isVert(undefined), false, "undefined is horizontal")
eq([BL.zoneTitle({ side: "top" }, "left"), BL.zoneTitle({ side: "top" }, "center"), BL.zoneTitle({ side: "top" }, "right")], ["Left", "Middle", "Right"], "horizontal titles")
eq([BL.zoneTitle({ side: "left" }, "left"), BL.zoneTitle({ side: "right" }, "center"), BL.zoneTitle({ side: "left" }, "right")], ["Top", "Middle", "Bottom"], "vertical titles")

// the default layout is a top notch
const d = BL.defaults()
eq([d.shape, d.side, d.caps], ["notch", "top", true], "defaults")

// the rail's numbers: the capsule plus its two gutters is the rail; every size grows with the bar size; the focused dot is the tallest
for (const h of [26, 32, 40]) {
  const m = BL.railMetrics(h)
  eq(m.capW + 2 * m.gutter, m.thick, "rail: capsule + gutters = thickness (barH " + h + ")")
  eq(m.icoCell > m.ico && m.dotOnH > m.dotOcc && m.dotOcc > m.dotOff, true, "rail: icon cell and dot sizes are ordered (barH " + h + ")")
  eq(m.clockPx * 2 + m.ico + 8 < 400, true, "rail: clock stays small (barH " + h + ")")
  eq(m.dotOnW <= m.capW - 16, true, "rail: the focused dot fits the capsule (barH " + h + ")")
}
eq(BL.railMetrics(32).thick, 48, "rail: 48 px at the normal bar size")
eq(BL.railMetrics(32).capW, 40, "rail: a 40 px capsule at the normal bar size, like Caelestia's")

if (bad) { console.log(bad + " failed"); process.exit(1) }
console.log("bar-layout: ok")
