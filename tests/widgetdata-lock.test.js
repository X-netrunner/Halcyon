// Tests for the lock-screen helpers in quickshell/island/WidgetData.js (plain JS, no Qt needed).
//   node tests/widgetdata-lock.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert")
const file = path.join(__dirname, "..", "quickshell", "island", "WidgetData.js")
const src = fs.readFileSync(file, "utf8").replace(/^\.pragma library.*$/m, "")
const ctx = {}
vm.createContext(ctx)
vm.runInContext(src + "\nthis.WD = { catalog, lockPrivate, lockPrivateOf, lockButtons, lockOk, lockPrivateNames, keyOf, onKeyOf, isOn, normalizeFor, normalize, typeSet, mergeNeeds, relLum, needs, add, remove, find, files, linkGroup, widthGroup, siblings, listRows, nextUid, styleOf };", ctx)
const WD = ctx.WD
// values built inside the vm context have another Array/Object prototype: compare plain copies
const plain = x => JSON.parse(JSON.stringify(x))
let n = 0
function t(name, fn) { fn(); n++; console.log("ok  " + name) }

t("every private type exists in the catalog (no typos)", () => {
  for (const k of Object.keys(WD.lockPrivate)) assert.ok(WD.catalog.some(c => c.id === k), k)
})
t("every type has a body file, and every type is offered on the lock screen", () => {
  for (const c of WD.catalog) { assert.ok(WD.files[c.id], c.id); assert.strictEqual(WD.lockOk(c.id), true, c.id) }
  assert.strictEqual(WD.lockOk("nonsense"), false)
})
t("private ones say why, the rest say nothing", () => {
  for (const id of ["notes", "brief", "console", "workspaces"]) assert.ok(WD.lockPrivateOf(id).length > 0, id)
  for (const id of ["clock", "toggles", "utilbox", "music"]) assert.strictEqual(WD.lockPrivateOf(id), "", id)
})
t("music keeps its buttons, nothing else does", () => {
  assert.deepStrictEqual(plain(Object.keys(WD.lockButtons)), ["music"])
})
t("keys per target", () => {
  assert.strictEqual(WD.keyOf("lock"), "lockDeskWidgets")
  assert.strictEqual(WD.keyOf("desktop"), "deskWidgets")
  assert.strictEqual(WD.keyOf(undefined), "deskWidgets")
  assert.strictEqual(WD.onKeyOf("lock"), "lockDeskWidgetsOn")
  assert.strictEqual(WD.onKeyOf(""), "deskWidgetsOn")
})
t("isOn: on unless the switch is exactly false, per target", () => {
  assert.strictEqual(WD.isOn(null, "lock"), true)
  assert.strictEqual(WD.isOn({}, "lock"), true)
  assert.strictEqual(WD.isOn({ lockDeskWidgetsOn: false }, "lock"), false)
  assert.strictEqual(WD.isOn({ lockDeskWidgetsOn: false }, "desktop"), true)
  assert.strictEqual(WD.isOn({ deskWidgetsOn: false }, "desktop"), false)
  assert.strictEqual(WD.isOn({ deskWidgetsOn: false }, "lock"), true)
})
t("normalizeFor lock keeps every type, in order (the same as the desktop)", () => {
  let d = { items: [] }
  for (const ty of ["clock", "console", "weather", "notes", "music"]) d = WD.add(d, ty)
  const l = WD.normalizeFor(d, "lock")
  assert.deepStrictEqual(plain(l.items.map(i => i.type)), ["clock", "console", "weather", "notes", "music"])
  const k = WD.normalizeFor(d, "desktop")
  assert.deepStrictEqual(plain(k.items.map(i => i.type)), plain(l.items.map(i => i.type)))
})
t("normalizeFor lock keeps a link to a private widget", () => {
  const raw = { items: [
    { uid: "w1", type: "notes", px: 0.1, py: 0.1 },
    { uid: "w2", type: "clock", px: 0.2, py: 0.2, link: "w1", linkSide: "below", linkGap: 10 }
  ] }
  const l = WD.normalizeFor(raw, "lock")
  assert.strictEqual(l.items.length, 2)
  assert.strictEqual(l.items[1].link, "w1")
})
t("normalizeFor lock keeps links between allowed widgets", () => {
  const raw = { items: [
    { uid: "w1", type: "clock" },
    { uid: "w2", type: "weather", link: "w1", linkSide: "below", linkGap: 10 }
  ] }
  assert.strictEqual(WD.normalizeFor(raw, "lock").items[1].link, "w1")
})
t("normalizeFor survives junk", () => {
  for (const bad of [null, undefined, 5, "x", {}, { items: 3 }, { items: [null, 1, { type: "nope", uid: "a" }] }])
    assert.deepStrictEqual(plain(WD.normalizeFor(bad, "lock").items), [])
})
t("normalizeFor does not mutate its input", () => {
  const raw = { items: [{ uid: "w1", type: "console" }, { uid: "w2", type: "clock" }] }
  const copy = JSON.stringify(raw)
  WD.normalizeFor(raw, "lock")
  assert.strictEqual(JSON.stringify(raw), copy)
})
t("typeSet ignores switched-off widgets", () => {
  let d = WD.add(WD.add({ items: [] }, "clock"), "music")
  d.items[1].off = true
  assert.deepStrictEqual(plain(WD.typeSet(d)), { clock: true })
  assert.deepStrictEqual(plain(WD.typeSet(null)), {})
})
t("mergeNeeds is an or, both ways, and keeps every key", () => {
  const a = WD.needs(WD.add({ items: [] }, "viz"))
  const b = WD.needs(WD.add({ items: [] }, "weather"))
  const m = WD.mergeNeeds(a, b)
  assert.strictEqual(m.viz, true); assert.strictEqual(m.weather, true); assert.strictEqual(m.disk, false)
  assert.deepStrictEqual(plain(Object.keys(m).sort()), plain(Object.keys(a).sort()))
  assert.deepStrictEqual(plain(WD.mergeNeeds(a, null)), plain(a))
})
t("relLum: black 0, white 1, grey in between", () => {
  assert.strictEqual(WD.relLum({ r: 0, g: 0, b: 0 }), 0)
  assert.ok(Math.abs(WD.relLum({ r: 1, g: 1, b: 1 }) - 1) < 1e-9)
  const g = WD.relLum({ r: 0.5, g: 0.5, b: 0.5 })
  assert.ok(g > 0.18 && g < 0.25, String(g))
})
t("lockPrivateNames lists exactly the private catalog names", () => {
  const names = WD.lockPrivateNames().split(", ")
  assert.strictEqual(names.length, Object.keys(WD.lockPrivate).length)
  assert.ok(names.includes("Notes & agenda") && !names.includes("Quick toggles"))
})
t("null and undefined safety across helpers", () => {
  assert.strictEqual(WD.find(null, "w1"), null)
  assert.strictEqual(WD.find({}, "w1"), null)
  assert.deepStrictEqual(plain(WD.linkGroup(null, "w1")), ["w1"])
  assert.deepStrictEqual(plain(WD.widthGroup(null, "w1")), ["w1"])
  assert.deepStrictEqual(plain(WD.siblings(null, "w1", "below")), [])
  assert.deepStrictEqual(plain(WD.listRows(null)), [])
  assert.strictEqual(WD.nextUid(null), "w1")
  assert.strictEqual(WD.nextUid([]), "w1")
  assert.strictEqual(WD.styleOf(null), "")
  assert.strictEqual(WD.styleOf({}), "")
  assert.strictEqual(WD.relLum(null), 0)
  assert.strictEqual(WD.relLum({}), 0)
  const mn = WD.mergeNeeds(null, null)
  assert.strictEqual(typeof mn, "object")
  assert.strictEqual(mn.viz, false)
  assert.strictEqual(mn.ctl, false)
})
console.log("\n" + n + " passed")

