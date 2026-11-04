// Jelly motion (squash and stretch) is on every box, not only the island and the toasts. node tests/jelly.test.js
const fs = require('fs'), path = require('path')
const rd = n => fs.readFileSync(path.join(__dirname, '..', 'quickshell', 'island', n), 'utf8')
let n = 0, bad = 0
function ok(label, cond) { n++; if (!cond) { bad++; console.log('FAIL ' + label) } else console.log('ok   ' + label) }

const glass = rd('Glass.qml'), jelly = rd('Jelly.qml')
ok('Glass carries a Jelly aimed at itself, switched by jellyOn (default: not for a flat pane)', /Jelly \{[^}]*target: root/.test(glass) && /on: root\.jellyOn/.test(glass) && /property bool jellyOn: !flat/.test(glass))
ok('a pane joined to a border is pinned to that border while it deforms', /originX: root\.joinH === "l" \? 0 : root\.joinH === "r" \? 1 : 0\.5/.test(glass) && /originY: root\.joinV === "t" \? 0 : root\.joinV === "b" \? 1 : 0\.5/.test(glass))
ok('Jelly senses a Translate slide, scale pops, and has an off switch', /_tr/.test(jelly) && /onScaleChanged/.test(jelly) && /popBoost/.test(jelly) && /allowed: on &&/.test(jelly))
ok('Jelly does not pulse for what happened while it was off or while the box was being built', /_armed/.test(jelly) && /else _sync\(\)/.test(jelly))

// who must NOT deform twice or at all
ok('the island keeps its own Jelly (halos follow it) and switches the built-in one off', /id: island[\s\S]{0,200}jellyOn: false/.test(rd('shell.qml')) && /Jelly \{ id: islandJelly/.test(rd('shell.qml')))
ok('the toast plate, desktop widgets and the ticking game chip are off', /jellyOn: false/.test(rd('Notifs.qml')) && /jellyOn: false/.test(rd('WidgetHost.qml')) && /jellyOn: false/.test(rd('GamePill.qml')))
ok('the toast cards keep their swipe feel (their Translate is the drag)', /followTranslate: false/.test(rd('NotifCard.qml')))

// plain Rectangle cards (not Glass) get their own Jelly
ok('StatusPop, ExePicker and ImagePicker cards have a Jelly', ['StatusPop.qml', 'ExePicker.qml', 'ImagePicker.qml'].every(f => /Jelly \{ target: card/.test(rd(f))))

// no other box asks for a second Jelly on a Glass (that would deform twice)
const dup = fs.readdirSync(path.join(__dirname, '..', 'quickshell', 'island')).filter(f => f.endsWith('.qml')).filter(f => {
  const s = rd(f); return /Jelly \{ target: (\w+)/.test(s) && f !== 'shell.qml' && f !== 'NotifCard.qml' && !/^(StatusPop|ExePicker|ImagePicker)\.qml$/.test(f) && f !== 'Jelly.qml' && f !== 'Glass.qml'
})
ok('no file besides the known ones adds a second Jelly (' + dup.join(', ') + ')', dup.length === 0)

console.log(`\n${n - bad} passed${bad ? ', ' + bad + ' FAILED' : ''}`)
process.exit(bad ? 1 : 0)
