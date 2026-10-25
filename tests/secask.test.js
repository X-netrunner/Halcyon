// Security center > Ask gate (quickshell/island/SecAsk.js, plain JS, no Qt needed):  node tests/secask.test.js
// Only security questions and /test may reach ai-firewall / ai-antivirus: they run live checks on this machine.
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "quickshell", "island", "SecAsk.js"), "utf8").replace(/^\.pragma library.*$/m, "")
const ctx = {}
vm.createContext(ctx)
vm.runInContext(src + "\nthis.S = { route };", ctx)
const S = ctx.S
let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }
const sends = (q, t) => S.route(q, t).send === true
const local = (q, t) => { const r = S.route(q, t); return r.send === false && r.reply !== "" }

ok("/test always goes to the firewall's checks", () => {
    ;["/test", "/test ports", "/test health"].forEach(q => assert(sends(q, "firewall") && sends(q, "antivirus"), q))
})
ok("small talk is answered here, never sent", () => {
    ;["hi", "Hello!", "thanks", "Thank you so much.", "ok", "bye", "how are you?", "what can you do?"].forEach(q => {
        assert(local(q, "firewall"), q); assert(local(q, "antivirus"), q)
    })
})
ok("general questions are answered here, never sent", () => {
    ;["write me a poem", "what is the capital of france", "how many ml in a cup", "rules of chess", "recommend a movie",
      "how do I change the wallpaper", "fix my python code"].forEach(q => {
        assert(local(q, "firewall"), q); assert(local(q, "antivirus"), q)
    })
})
ok("firewall questions are sent", () => {
    ;["which ports are open", "why was 10.0.0.5 banned", "unban my laptop", "my ssh connection is blocked", "is my network safe",
      "why can't my VM reach the internet", "show the traffic"].forEach(q => assert(sends(q, "firewall"), q))
})
ok("antivirus questions are sent", () => {
    ;["is this file malware", "what did the last scan find", "why was install.sh flagged", "add an exception for cargo",
      "explain the newest alert", "any viruses on this computer"].forEach(q => assert(sends(q, "antivirus"), q))
})
ok("a question for the other module still counts as security", () => {
    assert(sends("which ports are open", "antivirus"))
    assert(sends("is this file malware", "firewall"))
})
ok("empty input does nothing", () => { const r = S.route("   ", "firewall"); assert(r.send === false && r.reply === "") })

console.log(n + " passed")
