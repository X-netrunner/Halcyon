// Tour.js: a step about something that is picked at install time is shown with a "not installed, run ./install.sh --choose" card
// when it is missing, and as itself when it is there. node tests/tour-optin.test.js
const fs = require("fs"), path = require("path"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "../quickshell/island/Tour.js"), "utf8").replace(".pragma library", "")
const Tour = new Function(src + "; return { plan: plan }")()
const feats = JSON.parse(fs.readFileSync(path.join(__dirname, "../quickshell/island/features.json"), "utf8"))

let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }
const on = { sysmode: true, firewall: true, antivirus: true, luna: true }
const off = { sysmode: false, firewall: false, antivirus: false, luna: false }
const ids = (p, k) => p.steps.filter(s => k ? s[k] : true).map(s => s.id)

ok("installed: every optional step is itself", () => {
  const p = Tour.plan("fresh", feats, null, on)
  assert(!p.steps.some(s => s.missing))
  for (const id of ["firewall", "antivirus", "luna", "cmds"]) assert(ids(p).includes(id), id)
})
ok("not installed: the step stays and says how to add it", () => {
  const p = Tour.plan("fresh", feats, null, off)
  for (const id of ["firewall", "antivirus", "luna", "cmds"]) {
    const s = p.steps.find(x => x.id === id)
    assert(s && s.missing, id)
    assert(/not installed/.test(s.body) && /--choose/.test(s.body), id)
    assert(!s.demo && !s.target && !s.try, id + " must not open anything")
  }
})
ok("every 'only' value has a name", () => feats.features.filter(f => f.only).forEach(f => assert(["sysmode", "firewall", "antivirus", "luna"].includes(f.only), f.id)))
console.log(n + " passed")
