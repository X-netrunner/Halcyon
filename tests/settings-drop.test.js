// Settings.qml: every drop-down row (item.drop: true) is a seg or chips row with choices, every `bl:` key (the bar's layout) is read AND written
// by Settings.qml, and the bar's wake-spot insets are 0 except on the edge a rail sits on.
// Reads the QML as text (no Qt needed): node tests/settings-drop.test.js
const fs = require("fs"), path = require("path"), assert = require("assert")
const dir = path.join(__dirname, "../quickshell/island/")
const src = fs.readFileSync(dir + "Settings.qml", "utf8")
const shell = fs.readFileSync(dir + "shell.qml", "utf8")
let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }

const items = [...src.matchAll(/^ {12}\{ type: "(\w+)"([^\n]*)$/gm)].map(m => ({ type: m[1], rest: m[2] }))
const drops = items.filter(i => /\bdrop: true\b/.test(i.rest))

ok("found the drop-down rows", () => assert(drops.length >= 8, "only " + drops.length))
ok("a drop-down row is a seg or chips row with choices", () => drops.forEach(d => {
  assert(d.type === "seg" || d.type === "chips", d.rest.slice(0, 60))
  assert(/opts: \[/.test(d.rest), d.rest.slice(0, 60))
}))
ok("SDrop.qml exists and both Settings layouts use it", () => {
  assert(fs.existsSync(dir + "SDrop.qml"))
  assert.strictEqual((src.match(/^\s+SDrop \{/gm) || []).length, 2)
})
ok("every bl: key used by a row is written by change() and read by get()", () => {
  const keys = new Set([...src.matchAll(/key: "bl:(\w+)"/g)].map(m => m[1]))
  assert(keys.size >= 4)
  keys.forEach(k => {
    if (k !== "isRail") assert(new RegExp('bk === "' + k + '"').test(src), "change() does not write bl:" + k)
  })
  assert(/key\.indexOf\("bl:"\) === 0/.test(src))
})
ok("every bl: value a row offers is one BarLayout.js accepts", () => {
  const BL = new Function("exports", fs.readFileSync(dir + "BarLayout.js", "utf8").replace(/^\.pragma.*$/m, "") + "\nreturn { normalize, setShape, setSide, setRStyle, setCaps, setSpMode }")({})
  const l = BL.normalize(null)
  ;["notch", "island", "rail"].forEach(v => assert.strictEqual(BL.setShape(l, v).shape, v))
  ;["top", "bottom", "left", "right"].forEach(v => assert.strictEqual(BL.setSide(l, v).side, v))
  ;["capsules", "pill", "bare", "split"].forEach(v => assert.strictEqual(BL.setRStyle(l, v).rstyle, v))
  ;["bar", "over"].forEach(v => assert.strictEqual(BL.setSpMode(l, v).spMode, v))
  assert.strictEqual(BL.setCaps(l, false).caps, false)
})
ok("wake spots start on the border: 0 except on the rail's own edge", () => {
  ;["L:left", "T:top", "R:right", "B:bottom"].forEach(x => {
    const [a, side] = x.split(":")
    assert(new RegExp('property real ins' + a + ': \\(railUp && railBar\\.side === "' + side + '"\\) \\? railBar\\.zoneWanted : 0\\b').test(shell), "ins" + a)
  })
})
console.log(n + " passed")
