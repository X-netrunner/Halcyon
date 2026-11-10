// Settings.qml: every group is in exactly one page of the Pages layout, every group has a known section, and every section tab has groups.
// Reads the QML as text (no Qt needed): node tests/settings-groups.test.js
const fs = require("fs"), path = require("path"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "../quickshell/island/Settings.qml"), "utf8")

const sections = JSON.parse(src.match(/readonly property var sections: (\[.*?\])/)[1])
const groups = [...src.matchAll(/^ {8}\{ id: "(\w+)", title: "([^"]+)", section: "([^"]+)", items: \[/gm)].map(m => ({ id: m[1], title: m[2], section: m[3] }))
const pagesSrc = src.slice(src.indexOf("readonly property var pages: ["), src.indexOf("property string page:"))
const pages = [...pagesSrc.matchAll(/\{ id: "([^"]+)", sub: "[^"]*", groups: \[([^\]]*)\] \}/g)].map(m => ({ id: m[1], groups: [...m[2].matchAll(/"(\w+)"/g)].map(x => x[1]) }))

let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }

ok("found groups, sections and pages", () => { assert(groups.length >= 20); assert(sections.length >= 5); assert(pages.length >= 6) })
ok("group ids are unique", () => assert.strictEqual(new Set(groups.map(g => g.id)).size, groups.length))
ok("every group has a known section", () => groups.forEach(g => assert(sections.includes(g.section), g.id + " -> " + g.section)))
ok("every section tab has at least one group", () => sections.forEach(s => assert(groups.some(g => g.section === s), s)))
ok("every group is on exactly one page", () => groups.forEach(g => {
  const on = pages.filter(p => p.groups.includes(g.id)).map(p => p.id)
  assert.strictEqual(on.length, 1, g.id + " is on " + JSON.stringify(on))
}))
ok("pages only name groups that exist", () => pages.forEach(p => p.groups.forEach(id => assert(groups.some(g => g.id === id), p.id + " -> " + id))))
ok("groups come in section order (the tree reads top to bottom)", () => {
  let last = -1
  groups.forEach(g => { const i = sections.indexOf(g.section); assert(i >= last, g.id + " is out of order"); last = i })
})
ok("no group has more than 14 items", () => {
  const re = /^ {8}\{ id: "(\w+)".*?items: \[\n([\s\S]*?)\n {8}\](?: \}|\))/gm
  for (const m of src.matchAll(re)) { const k = (m[2].match(/^ {12}\{ type:/gm) || []).length; assert(k <= 14, m[1] + " has " + k) }
})
console.log(n + " passed")
