// Commands and widget files must stay in step (a slip here is a command that silently does nothing, or a widget that draws nothing).
// Reads the sources as text (no Qt or fish needed):  node tests/commands-widgets.test.js
const fs = require("fs"), path = require("path"), assert = require("assert"), vm = require("vm")
const root = path.join(__dirname, "..")
const rd = p => fs.readFileSync(path.join(root, p), "utf8")
let n = 0
const t = (name, fn) => { fn(); n++; console.log("ok  " + name) }

const fish = rd("config/fish/functions/halcyon.fish").split("\n")
const words = l => l.trim().split(/\s+/).slice(3)                       // after "set -l NAME"
const names = words(fish.find(l => /set -l names /.test(l))), calls = words(fish.find(l => /set -l calls /.test(l)))
const what = (fish.find(l => /set -l what /.test(l)).match(/"[^"]*"/g) || [])
const shell = rd("quickshell/island/shell.qml"), launcher = rd("quickshell/island/Launcher.qml")

t("halcyon CLI: names, IPC calls and descriptions line up one to one", () => {
  assert.strictEqual(names.length, calls.length, "names vs calls")
  assert.strictEqual(names.length, what.length, "names vs descriptions")
})
t("halcyon CLI: every IPC call exists in shell.qml", () => {
  const known = (shell.match(/function (\w+)\(/g) || []).map(x => x.slice(9, -1))
  const missing = calls.filter(c => !known.includes(c))
  assert.deepStrictEqual(missing, [], "no IPC function for: " + missing)
})
t("focus graph: CLI name, IPC function, launcher entry and shell case are all there", () => {
  assert.strictEqual(calls[names.indexOf("focus-graph")], "focusgraph")
  assert.match(shell, /function focusgraph\(\): void/)
  assert.match(shell, /case "focusgraph":/)
  assert.match(launcher, /id: "focusgraph"/)
  assert.match(rd("config/fish/completions/halcyon.fish"), /focus-graph:/)
})
t("launcher: every id in the command order has an entry", () => {
  const order = launcher.match(/readonly property var cmdOrder: \[([\s\S]*?)\n    \]/)[1].match(/"[\w-]+"/g).map(s => s.slice(1, -1))
  const ids = new Set([...launcher.matchAll(/\{ id: "([\w-]+)", name:/g)].map(m => m[1]))
  const missing = order.filter(i => !ids.has(i) && !i.startsWith("profile-"))
  assert.deepStrictEqual(missing, [], "no launcher entry for: " + missing)
})
t("everyday tools: every launcher tool-* entry has its arguments in shell.qml, and every key has its Binds.js entry", () => {
  const ids = [...launcher.matchAll(/\{ id: "tool-([\w-]+)", name:/g)].map(m => m[1])
  assert.ok(ids.length >= 10, "the tool entries are there")
  const map = shell.match(/readonly property var toolArgs: \(\{([\s\S]*?)\}\)/)[1]
  const keys = [...map.matchAll(/"([\w-]+)":/g)].map(m => m[1])
  assert.deepStrictEqual(ids.filter(i => !keys.includes(i)), [], "launcher entries without arguments")
  assert.deepStrictEqual(keys.filter(i => !ids.includes(i)), [], "arguments without a launcher entry")
  const binds = rd("quickshell/island/Binds.js"), lua = rd("hyprland/keybinds.lua")
  for (const id of ["colorpick", "measure", "zoom", "snippets", "winlast", "winpick"]) {
    assert.match(binds, new RegExp(`id: "${id}"`), id + " is missing from Binds.js")
    assert.match(lua, new RegExp(`bind\\("${id}"`), id + " is missing from keybinds.lua")
  }
})
t("widgets: every catalog type has a body file that exists", () => {
  const ctx = {}; vm.createContext(ctx); vm.runInContext(rd("quickshell/island/WidgetData.js").replace(/^\.pragma.*$/m, ""), ctx)
  for (const c of ctx.catalog) assert.ok(fs.existsSync(path.join(root, "quickshell/island", ctx.files[c.id] || "")), c.id + " -> " + ctx.files[c.id])
  const g = ctx.catalog.find(c => c.id === "focusgraph")
  assert.deepStrictEqual(JSON.parse(JSON.stringify(g.styles.map(s => s[0]))), ["rail", "bars"])
  assert.strictEqual(ctx.needs({ items: [{ type: "focusgraph" }] }).focusLog, true, "the graph needs the focus-days feed")
})
console.log(n + " passed")
