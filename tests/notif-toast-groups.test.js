// Popup grouping (quickshell/island/ToastGroups.js) and the notification box builder's layouts (NotifLayout.js), run in node (no Qt needed):
//   node tests/notif-toast-groups.test.js
// ToastGroups.js decides which popups of one app fold behind the newest one; NotifLayout.js is what the builder saves and Notifs.qml loads.
const fs = require("fs"), path = require("path"), assert = require("assert")
const dir = path.join(__dirname, "../quickshell/island/")
const load = (f, exportsList) => new Function(fs.readFileSync(dir + f, "utf8").replace(/^\.pragma.*$/m, "") + "\nreturn { " + exportsList + " }")()
const TG = load("ToastGroups.js", "plan, prune, toggle")
const NL = load("NotifLayout.js", "defaults, normalize, edit, toggleBlock, moveBlock, isDefault, summary, ids, limits")
let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }
const t = (id, appName, urgent) => ({ id, appName, urgent: !!urgent })
const crit = x => x.urgent

ok("a lone popup is not grouped", () => {
  const p = TG.plan([t(1, "Mail")], {}, crit)
  assert.deepStrictEqual(p.byId[1], { folded: false, lead: false, more: 0, open: false })
  assert.strictEqual(p.shown, 1); assert.strictEqual(p.first, 1); assert.strictEqual(p.last, 1)
})
ok("three from one app: the newest leads with +2, the older two fold", () => {
  const p = TG.plan([t(1, "Mail"), t(2, "Mail"), t(3, "Mail")], {}, crit)
  assert.deepStrictEqual([p.byId[1].folded, p.byId[2].folded, p.byId[3].folded], [true, true, false])
  assert.strictEqual(p.byId[3].lead, true); assert.strictEqual(p.byId[3].more, 2)
  assert.strictEqual(p.shown, 1); assert.strictEqual(p.first, 3); assert.strictEqual(p.last, 3)
})
ok("two apps interleaved: each app folds on its own, the order of the cards stays", () => {
  const p = TG.plan([t(1, "Mail"), t(2, "Chat"), t(3, "Mail"), t(4, "Chat"), t(5, "Files")], {}, crit)
  assert.deepStrictEqual([1, 2, 3, 4, 5].map(i => p.byId[i].folded), [true, true, false, false, false])
  assert.strictEqual(p.byId[3].more, 1); assert.strictEqual(p.byId[4].more, 1); assert.strictEqual(p.byId[5].more, 0)
  assert.strictEqual(p.shown, 3); assert.strictEqual(p.first, 3); assert.strictEqual(p.last, 5)
})
ok("an opened group shows every card, the newest says it is open", () => {
  const p = TG.plan([t(1, "Mail"), t(2, "Mail")], { Mail: true }, crit)
  assert.strictEqual(p.byId[1].folded, false); assert.strictEqual(p.byId[2].open, true); assert.strictEqual(p.byId[2].more, 1)
  assert.strictEqual(p.shown, 2); assert.strictEqual(p.first, 1); assert.strictEqual(p.last, 2)
})
ok("urgent popups are never folded and never fold others", () => {
  const p = TG.plan([t(1, "Mail", true), t(2, "Mail"), t(3, "Mail")], {}, crit)
  assert.strictEqual(p.byId[1].folded, false)             // the urgent one stays on its own
  assert.strictEqual(p.byId[2].folded, true); assert.strictEqual(p.byId[3].more, 1)
  const q = TG.plan([t(1, "Mail"), t(2, "Mail", true)], {}, crit)
  assert.strictEqual(q.byId[1].folded, false); assert.strictEqual(q.byId[2].more, 0)    // only one quiet one: no group
})
ok("popups without an app name are never grouped", () => {
  const p = TG.plan([t(1, ""), t(2, ""), t(3, undefined)], {}, crit)
  assert.strictEqual(p.shown, 3); assert([1, 2, 3].every(i => !p.byId[i].folded && p.byId[i].more === 0))
})
ok("an empty list and a missing expanded map are fine", () => {
  const p = TG.plan([], undefined, undefined)
  assert.strictEqual(p.shown, 0); assert.strictEqual(p.first, null); assert.strictEqual(p.last, null)
  assert.strictEqual(TG.plan([t(1, "A"), t(2, "A")], null).byId[2].more, 1)
})
ok("nothing is lost: folded + showing is every popup", () => {
  const list = [t(1, "A"), t(2, "B"), t(3, "A"), t(4, "A", true), t(5, "B"), t(6, "")]
  const p = TG.plan(list, {}, crit)
  assert.strictEqual(Object.keys(p.byId).length, list.length)
  assert.strictEqual(list.filter(x => !p.byId[x.id].folded).length, p.shown)
})
ok("prune drops opened groups that shrank to one and keeps the object when nothing changes", () => {
  const open = { Mail: true }
  assert.strictEqual(TG.prune([t(1, "Mail"), t(2, "Mail")], open, crit), open)
  assert.deepStrictEqual(TG.prune([t(1, "Mail")], open, crit), {})
  assert.deepStrictEqual(TG.prune([], open, crit), {})
  assert.deepStrictEqual(TG.prune([t(1, "Mail", true), t(2, "Mail")], open, crit), {})        // an urgent one does not count
})
ok("toggle opens and closes without changing the old object", () => {
  const a = {}, b = TG.toggle(a, "Mail"), c = TG.toggle(b, "Mail")
  assert.deepStrictEqual(a, {}); assert.deepStrictEqual(b, { Mail: true }); assert.deepStrictEqual(c, {})
})

// ---- the notification box builder's layouts must still load (NotifLayout.js was not changed; this keeps it that way)
ok("builder: no layout / junk gives the default box", () => {
  assert.deepStrictEqual(NL.normalize(null), NL.defaults())
  assert.deepStrictEqual(NL.normalize("x"), NL.defaults())
  assert(NL.isDefault(undefined))
})
ok("builder: an old saved layout (extra and missing keys, array-like blocks) loads and keeps its choices", () => {
  const old = { v: 1, art: false, width: 9999, pad: "20", vpos: "bottom", corner: "bl", spot: "corner", toastStars: false,
                blocks: { 0: { id: "list", on: true }, 1: { id: "sky", on: false }, 2: { id: "nope", on: true }, length: 3 }, junk: 1 }
  const c = NL.normalize(old)
  assert.strictEqual(c.width, NL.limits.width[1]); assert.strictEqual(c.pad, 20); assert.strictEqual(c.vpos, "bottom")
  assert.strictEqual(c.corner, "bl"); assert.strictEqual(c.spot, "corner"); assert.strictEqual(c.toastStars, false); assert.strictEqual(c.art, false)
  assert.deepStrictEqual(c.blocks.map(b => b.id), ["list", "sky", "header"]); assert.strictEqual(c.blocks[1].on, false)
  assert.strictEqual(c.junk, undefined)
  assert.deepStrictEqual(NL.normalize(c), c)                    // loading twice changes nothing
  assert(typeof NL.summary(c) === "string")
})
ok("builder: edit / toggle / move still work on a loaded layout", () => {
  let c = NL.edit(null, "width", 480); assert.strictEqual(c.width, 480)
  c = NL.toggleBlock(c, "sky"); assert.strictEqual(c.blocks.find(b => b.id === "sky").on, false)
  c = NL.moveBlock(c, "list", -1); assert.strictEqual(c.blocks[1].id, "list")
})
ok("builder: its files are all still there", () => {
  const files = fs.readdirSync(dir).filter(f => /^NotifBuilder.*\.qml$|^NotifLayout\.js$/.test(f))
  assert(files.length >= 3, files.join())
  files.forEach(f => assert(fs.statSync(dir + f).size > 0, f))
})
console.log(n + " passed")
