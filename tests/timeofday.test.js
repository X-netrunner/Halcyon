// Tests for quickshell/island/TimeOfDay.js (plain JS, no Qt needed):  node tests/timeofday.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "quickshell", "island", "TimeOfDay.js"), "utf8").replace(/^\.pragma library.*$/m, "")
const ctx = {}
vm.createContext(ctx)
vm.runInContext(src + "\nthis.T = { at, phaseName, wrap, hourOf, KEYS };", ctx)
const T = ctx.T
let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }
const near = (a, b, e = 1e-9) => assert(Math.abs(a - b) <= e, a + " vs " + b)

ok("noon is untouched", () => { const x = T.at(12, 1); near(x.tint, 0); near(x.dim, 0) })
ok("midnight is the deepest blue and the darkest", () => {
    const x = T.at(0, 1); assert(x.b > x.r && x.b > x.g); near(x.tint, 0.34); near(x.dim, 0.18)
})
ok("24:00 is the same as 00:00, negative and big hours wrap", () => {
    const a = T.at(0, 1), b = T.at(24, 1), c = T.at(-24 + 0, 1), d = T.at(48, 1)
    ;[b, c, d].forEach(x => { near(x.tint, a.tint); near(x.b, a.b) })
    near(T.at(-1, 1).tint, T.at(23, 1).tint)
})
ok("a key hour gives exactly that key", () => {
    const x = T.at(18, 1); near(x.r, 1); near(x.g, 0.62); near(x.b, 0.30); near(x.tint, 0.22); near(x.dim, 0.03)
})
ok("strength scales the wash and the dimming, not the colour", () => {
    const f = T.at(19.5, 1), h = T.at(19.5, 0.5), z = T.at(19.5, 0)
    near(h.tint, f.tint / 2); near(h.dim, f.dim / 2); near(h.r, f.r); near(h.g, f.g); near(h.b, f.b)
    near(z.tint, 0); near(z.dim, 0)
})
ok("strength outside 0..1 or not a number is clamped / ignored", () => {
    near(T.at(0, 5).tint, 0.34); near(T.at(0, -3).tint, 0); near(T.at(0, "x").tint, 0.34); near(T.at(0).tint, 0.34)
})
ok("a bad hour does not throw (it reads as noon)", () => {
    near(T.at(NaN, 1).tint, 0); near(T.at(undefined, 1).tint, 0); near(T.at("abc", 1).tint, 0)
})
ok("the change is continuous: no jump bigger than 0.02 in a minute, all day", () => {
    let prev = T.at(0, 1)
    for (let m = 1; m <= 1440; m++) {
        const x = T.at(m / 60, 1)
        ;["r", "g", "b", "tint", "dim"].forEach(k => assert(Math.abs(x[k] - prev[k]) < 0.02, k + " jumps at minute " + m))
        prev = x
    }
})
ok("every value stays in range", () => {
    for (let m = 0; m <= 1440; m += 7) {
        const x = T.at(m / 60, 1)
        ;["r", "g", "b"].forEach(k => assert(x[k] >= 0 && x[k] <= 1)); assert(x.tint >= 0 && x.tint <= 0.4); assert(x.dim >= 0 && x.dim <= 0.2)
    }
})
ok("phase names", () => {
    assert.strictEqual(T.phaseName(2), "night"); assert.strictEqual(T.phaseName(6.5), "dawn"); assert.strictEqual(T.phaseName(13), "day")
    assert.strictEqual(T.phaseName(17), "golden hour"); assert.strictEqual(T.phaseName(20), "dusk"); assert.strictEqual(T.phaseName(23), "night")
    assert.strictEqual(T.at(17, 1).name, "golden hour")
})
ok("keys are sorted, start at 0 and end at 24", () => {
    assert.strictEqual(T.KEYS[0][0], 0); assert.strictEqual(T.KEYS[T.KEYS.length - 1][0], 24)
    for (let i = 1; i < T.KEYS.length; i++) assert(T.KEYS[i][0] > T.KEYS[i - 1][0])
})
ok("hourOf", () => near(T.hourOf(new Date(2026, 9, 20, 7, 30)), 7.5))
console.log(n + " passed")
