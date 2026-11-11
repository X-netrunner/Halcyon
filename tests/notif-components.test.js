const fs = require("fs"), path = require("path"), assert = require("assert")
const dir = path.join(__dirname, "../quickshell/island/")
const load = (f, names) => new Function(fs.readFileSync(dir + f, "utf8").replace(/^\.pragma.*$/m, "") + "\nreturn { " + names + " }")()
const NC = load("NotifComponent.js", "componentFor")
const Tok = load("Tokens.js", "icon")
const vc = fs.readFileSync(dir + "VersionCenter.qml", "utf8")
let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }

const senders = { "AI Antivirus": "ai-antivirus", "ai-firewall": "ai-firewall", "Luna": "luna", "Halcyon Files": "halcyon-fm", "Halcyon Music": "halcyon-music" }
for (const [app, component] of Object.entries(senders)) {
  ok(`notifications from "${app}" use the ${component} icon`, () => {
    assert.strictEqual(NC.componentFor(app), component)
    assert.ok(Tok.icon[component], `Tokens.js has an icon for ${component}`)
  })
}
ok("other apps keep their own icon", () => assert.strictEqual(NC.componentFor("Firefox"), ""))
ok("Version Center takes its icons from the same tokens", () => assert.ok(/function iconFor\(id\) \{ return pal\.iconFor\(id\) \}/.test(vc)))
console.log(`${n} checks, 0 failed`)
