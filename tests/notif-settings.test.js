// The notification box rework, checked as text (no Qt needed): node tests/notif-settings.test.js
//  - Settings.qml: the Quiet / Popups / Centre groups, every old key kept, no hidden (adv) rows, Wi-Fi details in the Utilities box
//  - NotifCard.qml / Notifs.qml: every property and signal Notifs.qml sets on a card exists on the card; the spec's parts are present
// This does NOT run Quickshell: how it looks and behaves must be checked on screen.
const fs = require("fs"), path = require("path"), assert = require("assert")
const dir = path.join(__dirname, "../quickshell/island/")
const settings = fs.readFileSync(dir + "Settings.qml", "utf8")
const card = fs.readFileSync(dir + "NotifCard.qml", "utf8")
const notifs = fs.readFileSync(dir + "Notifs.qml", "utf8")
const icon = fs.readFileSync(dir + "NotifIcon.qml", "utf8")
const shell = fs.readFileSync(dir + "shell.qml", "utf8")
let n = 0
const ok = (name, fn) => { fn(); n++; console.log("ok  ", name) }

// the rows of a group, as text lines
function groupLines(id) {
  const i = settings.indexOf('{ id: "' + id + '", title:')
  assert(i >= 0, "group " + id + " not found")
  const j = settings.indexOf("\n        ] },", i)
  return settings.slice(i, j).split("\n").filter(l => /^ {12}\{ type:/.test(l))
}
const keysOf = lines => lines.map(l => (l.match(/key: "([^"]+)"/) || [])[1])
const labelOf = l => (l.match(/label: "([^"]+)"/) || [])[1]

ok("three notification groups, in this order, on the Notifications & panels page (with the utilities box and edge boxes after them)", () => {
  const page = settings.match(/\{ id: "Notifications & panels", sub: "[^"]*", groups: \[([^\]]*)\] \}/)[1]
  assert.deepStrictEqual([...page.matchAll(/"(\w+)"/g)].map(m => m[1]), ["notifquiet", "notifpopups", "notifcentre", "utilbox", "osd"])
  assert(!/id: "notifications"/.test(settings), "the old single group is still there")
})
ok("Quiet: Do not disturb (Off / Errors only / On) and Quiet while a window is fullscreen", () => {
  const l = groupLines("notifquiet")
  assert.deepStrictEqual(l.map(labelOf), ["Do not disturb", "Quiet while a window is fullscreen"])
  assert(/opts: \[o\("off", "Off"\), o\("errors", "Errors only"\), o\("on", "On"\)\]/.test(l[0]))
  assert.strictEqual(keysOf(l)[1], "opt:dndFullscreen")
})
ok("Popups: Stay for, At once, Urgent ones hide after (drop-downs), Picture", () => {
  const l = groupLines("notifpopups")
  assert.deepStrictEqual(l.map(labelOf), ["Stay for", "At once", "Urgent ones hide after", "Icon"])
  assert.deepStrictEqual(keysOf(l), ["opt:toastSecs", "notifMax", "opt:critSecs", "opt:notifIcon"])
  assert(l.slice(0, 3).every(x => /\bdrop: true\b/.test(x)))
  assert(/o\("symbol", "Symbol"\), o\("app", "App icon"\), o\("pfp", "Profile picture"\)/.test(l[3]))
})
ok("Centre: Header switch (Do not disturb / Airplane mode), Style (Stack / Timeline), Keeps (drop-down), Opens from", () => {
  const l = groupLines("notifcentre")
  assert.deepStrictEqual(l.map(labelOf), ["Header switch", "Style", "Keeps", "Opens from"])
  assert.deepStrictEqual(keysOf(l), ["opt:notifQuick", "opt:notifStyle", "notifHistoryMax", "opt:notifSpot"])
  assert(/o\("stack", "Stack"\), o\("timeline", "Timeline"\)\]/.test(l[1]) && !/grouped/.test(l[1].split("desc:")[0]))
  assert(/o\("dnd", "Do not disturb"\), o\("airplane", "Airplane mode"\)\]/.test(l[0]))
  assert(/\bdrop: true\b/.test(l[2]))
})
ok("every old key and its values are kept (saved configs keep working)", () => {
  const all = [...groupLines("notifquiet"), ...groupLines("notifpopups"), ...groupLines("notifcentre")].join("\n")
  const util = groupLines("utilbox").join("\n")
  ;["opt:dndFullscreen", "opt:toastSecs", "notifMax", "opt:critSecs", "opt:notifIcon", "opt:notifQuick", "opt:notifStyle", "notifHistoryMax", "opt:notifSpot"].forEach(k => assert(all.includes('key: "' + k + '"'), k))
  assert(util.includes('ch("opt:wifiVerbose"'), "wifiVerbose")
  // the same choices as before (values), so a saved value still lights its button
  assert(/o\(0, "App decides"\), o\(3, "3 s"\), o\(5, "5 s"\), o\(8, "8 s"\), o\(12, "12 s"\)/.test(all))
  assert(/o\(1, "1"\), o\(2, "2"\), o\(3, "3"\), o\(5, "5"\), o\(8, "8"\)/.test(all))
  assert(/o\(15, "15 s"\), o\(30, "30 s"\), o\(60, "1 min"\), o\(0, "Wait for a click"\)/.test(all))
  assert(/o\(10, "[^"]*"\), o\(20, "[^"]*"\), o\(30, "[^"]*"\), o\(50, "[^"]*"\), o\(100, "[^"]*"\)/.test(all))
  assert(/o\("edge", "Right edge"\), o\("corner", "Top-right corner"\)/.test(all))
  // the shell still owns the defaults
  ;[/toastSecs: 0,/, /critSecs: 30,/, /notifSpot: "edge",/, /notifStyle: "stack",/, /notifQuick: "dnd",/, /notifIcon: "symbol",/, /connErrOnly: false,/, /wifiVerbose: true,/, /dndFullscreen: true,/].forEach(re => assert(re.test(shell), String(re)))
})
ok("UI/UX round 7: only Do not disturb, Quiet while fullscreen, Stay for and the centre Style stay in the default view; the rest is under Debug / Advanced", () => {
  const visible = []
  ;["notifquiet", "notifpopups", "notifcentre"].forEach(id => groupLines(id).forEach(l => { if (!/\badv: true\b/.test(l)) visible.push(labelOf(l)) }))
  assert.deepStrictEqual(visible, ["Do not disturb", "Quiet while a window is fullscreen", "Stay for", "Style"])
})
ok("Wi-Fi details moved to the Utilities box", () => {
  assert.strictEqual(groupLines("utilbox").filter(l => labelOf(l) === "Wi-Fi details").length, 1)
  ;["notifquiet", "notifpopups", "notifcentre"].forEach(id => assert(!groupLines(id).some(l => labelOf(l) === "Wi-Fi details")))
  assert.strictEqual((settings.match(/label: "Wi-Fi details"/g) || []).length, 1)
})
ok("Do not disturb: one row read from and written to the two saved keys", () => {
  assert(/key === "quiet:mode"\) return dnd \? "on" : \(\(opt && opt\.connErrOnly === true\) \? "errors" : "off"\)/.test(settings))
  const w = settings.slice(settings.indexOf('if (key === "quiet:mode") {'), settings.indexOf('if (key === "ai:enabled") {'))
  assert(w.includes('setting("dnd", true)') && w.includes('setting("dnd", false)') && w.includes('setting("opt:connErrOnly", wantErr)'))
  assert(settings.indexOf('key === "quiet:mode") {') < settings.lastIndexOf("setting(key, v)"), "the quiet:mode branch must come before the generic write")
})
ok("the Off / Errors only / On rules, as a small model: every click from every starting state reads back right", () => {
  // the same rules as get() / change() above, run on a tiny model
  const read = s => s.dnd ? "on" : (s.connErrOnly === true ? "errors" : "off")
  const click = (s, v) => { const o = { ...s }; if (v === "on") { o.dnd = true; return o } o.dnd = false; o.connErrOnly = v === "errors"; return o }
  ;[{ dnd: false, connErrOnly: false }, { dnd: true, connErrOnly: false }, { dnd: false, connErrOnly: true }, { dnd: true, connErrOnly: true }].forEach(s =>
    ["off", "errors", "on"].forEach(v => assert.strictEqual(read(click(s, v)), v, JSON.stringify(s) + " -> " + v)))
  assert.strictEqual(click({ dnd: true, connErrOnly: true }, "off").connErrOnly, false)
})

// ---- the popup card
ok("every property / signal Notifs.qml sets on a card exists on the card", () => {
  const i = notifs.indexOf("delegate: NotifCard {")
  let depth = 0, k = notifs.indexOf("{", i), j = k
  for (; j < notifs.length; j++) { if (notifs[j] === "{") depth++; else if (notifs[j] === "}" && --depth === 0) break }
  const body = notifs.slice(k + 1, j)
  const names = [...body.split("\n").map(l => l.match(/^ {24}(?:readonly property \w+ |required property \w+ )?(on[A-Z]\w*|\w+):/)).filter(Boolean).map(m => m[1])]
  assert(names.length >= 15, names.join())
  const builtin = new Set(["width", "height", "grp", "modelData"])
  names.forEach(nm => {
    if (builtin.has(nm)) return
    if (/^on[A-Z]/.test(nm)) { const sig = nm[2].toLowerCase() + nm.slice(3); assert(new RegExp("signal " + sig + "\\(").test(card), "signal " + sig) }
    else assert(new RegExp("property \\w+ " + nm + "\\b").test(card), "property " + nm)
  })
})
ok("popup card: 36 px rounded-square tile, picture choice still passed through", () => {
  assert(/size: 36/.test(card) && /tile: true/.test(card) && /usePfp: card\.usePfp/.test(card) && /avatar: card\.avatar/.test(card))
  assert(/property bool tile: false/.test(icon) && /root\.usePfp/.test(icon))
  assert(/usePfp: root\.opt\.notifIcon === "pfp"/.test(shell)); assert(/iconMode: root\.opt\.notifIcon/.test(shell))
  // the centre's rows keep the round picture: only the card asks for the tile
  const rows = ["NotifRow.qml", "NotifGroup.qml"].map(f => fs.readFileSync(dir + f, "utf8")).join("\n")
  assert(!/tile: true/.test(rows))
})
ok("popup card: header line, urgent word, red tile", () => {
  assert(/text: " · urgent"/.test(card) && /visible: card\.critical/.test(card))
  assert(/" · " \+ card\.timeText/.test(card) && /urgent: card\.critical/.test(card) && /tone: card\.tone/.test(card))
  assert(/readonly property color tone: critical \? pal\.bad : pal\.accent/.test(card))
})
ok("popup card: the notification's own actions (not default) as chips, first one highlighted, click runs it and dismisses", () => {
  assert(/a\[i\]\.identifier !== "default"/.test(card))
  assert(/model: card\.extraActions/.test(card) && /on: index === 0/.test(card))
  assert(/modelData\.invoke\(\); .*card\.close\(false\)/.test(card))
})
ok("popup card: X dismisses, left click = default action, right click = hide all, swipe, time-left line, hover pause", () => {
  assert(/onClicked: card\.close\(false\) \}/.test(card))
  assert(/mouse\.button === Qt\.RightButton\) \{ card\.hideAll\(\); return \}/.test(card) && /card\.runDefault\(\)/.test(card))
  assert(/DragHandler/.test(card) && /swipeOut/.test(card) && /paused: hov\.hovered/.test(card))
  assert(/width: \(parent\.width - 48\) \* card\.life/.test(card))
  assert(/running: card\.dur > 0 && !card\.closing/.test(card) && /critical \? critSecs \* 1000/.test(card))
})
ok("the shared box is kept: one Glass, one Column, the slide / join / star hooks are still there", () => {
  assert((notifs.match(/Glass \{/g) || []).length >= 1 && /Column \{\s*id: col/.test(notifs))
  ;[/cornerJoin/, /fromRight: root\.atR/, /stars: root\.stars && root\.cfg\.toastStars/, /pal\.frameOn/].forEach(re => assert(re.test(notifs), String(re)))
  ;[/BarStars \{/, /hideX/, /hideY/, /id: enter/, /id: exit/, /id: collapse/].forEach(re => assert(re.test(card), String(re)))
})
ok("grouping: one card per popup stays (no model of groups), folded cards keep their height at 0", () => {
  assert(/model: ScriptModel \{ values: root\.toasts \}/.test(notifs))
  assert(/import "ToastGroups\.js" as TG/.test(notifs) && /TG\.plan\(toasts, openGroups, isCrit\)/.test(notifs) && /TG\.prune/.test(notifs))
  assert(/height: Math\.round\(fullH \* grow \* fold\)/.test(card) && /enabled: !folded/.test(card))
  assert(/signal groupToggled\(\)/.test(card) && /\+" \+ card\.more \+ " more"/.test(card))
})
console.log(n + " passed")
