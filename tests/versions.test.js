// Version Center: the pieces are all there and wired together. node tests/versions.test.js
// (the helper itself is exercised against throw-away git repos by tests/test_halcyon_versions.py)
const fs = require('fs'), path = require('path'), cp = require('child_process'), os = require('os')
const root = path.join(__dirname, '..')
const rd = p => fs.readFileSync(path.join(root, p), 'utf8')
let n = 0, bad = 0
function ok(label, cond) { n++; if (!cond) { bad++; console.log('FAIL ' + label) } else console.log('ok   ' + label) }

const vcMain = rd('quickshell/island/VersionCenter.qml'), vc = vcMain + ['Card', 'Hero', 'Log', 'Commits', 'Actions', 'Tile', 'Badge', 'Btn', 'Text'].map(n => rd('quickshell/island/Version' + n + '.qml')).join('\n'), auto = rd('quickshell/island/SetVersionsAuto.qml')
const shell = rd('quickshell/island/shell.qml'), launcher = rd('quickshell/island/Launcher.qml'), settings = rd('quickshell/island/Settings.qml')
const notch = rd('quickshell/island/NotchBar.qml')

// ---- the files and their registration
ok('VersionCenter.qml and its Settings leaf exist', vc.length > 1000 && auto.length > 500)
ok('shell.qml instantiates the window', /VersionCenter\s*\{\s*\n\s*id: versionCenter/.test(shell))
ok('the launcher command runs it (runCommand "versions")', /case "versions":[^\n]*versionCenter\.toggle\(\)/.test(shell))
ok('IPC: qs ipc call ... versions', /function versions\(\): void \{ root\.runCommand\("versions"\) \}/.test(shell))
ok('Settings action "versions-open" opens it', /id === "versions-open"\) \{ settingsWin\.hide\(\); versionCenter\.show\(\) \}/.test(shell))
ok('Esc closes it like the other centres', /versionCenter\.open && !versionCenter\.asWindow/.test(shell))
const cmd = launcher.match(/\{ id: "versions"[^\n]*\}/)
ok('launcher lists >versions', !!cmd)
ok('>update finds it (keyword)', !!cmd && /kw: "[^"]*\bupdate\b/.test(cmd[0]))
ok('it is in the launcher order list', /"reload", "versions"/.test(launcher))
ok('Settings group "versions" exists and sits on a page', /\{ id: "versions", title: "Version Center"/.test(settings) && /groups: \[[^\]]*"versions"[^\]]*\]/.test(settings))
ok('Settings: the custom leaf is registered', /case "versionsAuto": return cVersionsAuto/.test(settings) && /id: cVersionsAuto; SetVersionsAuto/.test(settings))
ok('the notch bar shows the dot and opens the window on click', /versionsBehind/.test(notch) && /versionsClicked/.test(notch) && /onVersionsClicked: versionCenter\.show\(\)/.test(shell))
ok('the dot reads the daily check\'s file only', /halcyon-versions\/available\.json/.test(shell))

// ---- the rules from the brief
ok('no background polling: no repeating or auto-running Timer', !/repeat:\s*true/.test(vc + auto) && !/running:\s*true/.test(vc + auto))
ok('the commit list is read only when a card is opened (loadLog from toggleList, 30 per page)', /function toggleList[\s\S]{0,300}loadLog\(id, 0\)/.test(vc) && /Load 30 more/.test(vc))
ok('one operation at a time: buttons are disabled while one runs', (vc.match(/(root|vc)\.locked/g) || []).length >= 6 && /disabled: ac\.blocked/.test(rd('quickshell/island/VersionActions.qml')))
ok('the password goes to stdin once, then is cleared', /write\(root\.opPw \+ "\\n"\); root\.opPw = ""/.test(vc) && /--password-stdin/.test(vc))
ok('the password is never put on a command line or in a file', !/command:[^\n]*dlgPw/.test(vc) && !/dlgPw[^\n]*(execDetached|writeFile)/.test(vc))
ok('a confirm dialog comes before anything runs (plan first)', /"plan", id, ref/.test(vc) && /function confirmDialog/.test(vc))
ok('the dialog warns about an older version and backups', /OLDER/.test(vc) && /Kept safe first/.test(vc))
ok('Update all is Halcyon first, same order as install.sh', /\["halcyon", "luna", "ai-firewall", "ai-antivirus"\]/.test(vc))
ok('components not chosen are greyed with an Install button', /greyed/.test(vc) && /askInstallNew/.test(vc))
ok('no emoji in the window or its Settings leaf', !/[\u{1F300}-\u{1FAFF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}]/u.test(vc + auto))
ok('slow, calm animations come from the palette (dMed / dSlow), no fixed fast ones', /pal\.dSlow/.test(vc) && !/duration: [0-9]{1,2}\b/.test(vc))

// ---- the two-column layout with the star corner menu
ok('Halcyon has its own big card (Hero) and the companions are LUNA, ai-antivirus, ai-firewall in that order', /delegate: VersionHero/.test(vc) && /model: root\.loaded \? \["luna", "ai-antivirus", "ai-firewall"\]/.test(vc))
ok('the actions are one button that expands into a pill row (ActionPill), on both card kinds', /ActionPill \{/.test(rd('quickshell/island/VersionActions.qml')) && (vc.match(/VersionActions \{/g) || []).length >= 2)
ok('the actions pill holds Update, Roll back, Pin, Commits and closes on Esc or an outside click', (() => { const a = rd('quickshell/island/VersionActions.qml'), p = rd('quickshell/island/ActionPill.qml'); return /label: "Roll back"/.test(a) && /"Unpin" : "Pin"/.test(a) && /Qt\.Key_Escape/.test(p) && /if \(!inBtn && !inTray\) ap\.close\(\)/.test(p) })())
ok('the Halcyon card shows installed, latest, behind by, pin and the distance bar', ['"Installed"', '"Latest on main"', '"Behind by"', '"Pin"', 'lagPos'].every(x => vc.includes(x)))

ok('the Halcyon card has no pointer-following light: the whole panels (Halcyon card and the companion cards) tip under the pointer with HoverTilt, the tiles inside stay flat', (() => { const h = rd('quickshell/island/VersionHero.qml'), t = rd('quickshell/island/VersionTile.qml'), c = rd('quickshell/island/VersionCard.qml'), l = rd('quickshell/island/HoverTilt.qml'); return !/WGlow|Behavior on gx|HoverLift/.test(h + t) && /HoverTilt/.test(h) && /HoverTilt/.test(c) && /Matrix4x4 \{ matrix: tilt\.matrix \}/.test(h) && /Matrix4x4 \{ matrix: tilt\.matrix \}/.test(c) && !/HoverTilt|Matrix4x4/.test(t) && /HoverHandler/.test(l) && /Qt\.matrix4x4/.test(l) })())
ok('Version Center is unslopped: no gradient, no tracked capitals, tags are rounded rectangles not pills, one accent', (() => { const all = ['Center', 'Card', 'Hero', 'Log', 'Commits', 'Actions', 'Tile', 'Badge', 'Btn', 'Text'].map(n => rd('quickshell/island/Version' + n + '.qml')).join('\n'); return !/Gradient|AllUppercase|letterSpacing|accent2/.test(all) && /Math\.min\(hgt \/ 2, 8\)/.test(rd('quickshell/island/VersionBadge.qml')) })())
// ---- braces balance in the new QML (a cheap compile guard where Quickshell is not installed)
function balanced(src) {
  let d = 0, inStr = null, esc = false, line = false, block = false
  for (let i = 0; i < src.length; i++) {
    const c = src[i], nx = src[i + 1]
    if (line) { if (c === '\n') line = false; continue }
    if (block) { if (c === '*' && nx === '/') { block = false; i++ } continue }
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === inStr) inStr = null; continue }
    if (c === '/' && nx === '/') { line = true; continue }
    if (c === '/' && nx === '*') { block = true; continue }
    if (c === '"' || c === "'") { inStr = c; continue }
    if (c === '{' || c === '(' || c === '[') d++
    if (c === '}' || c === ')' || c === ']') d--
    if (d < 0) return false
  }
  return d === 0 && !inStr
}
ok('VersionCenter.qml and the Version*.qml pieces: brackets balance', ['Center', 'Card', 'Hero', 'Log', 'Commits', 'Actions', 'Tile', 'Badge', 'Btn', 'Text'].every(n => balanced(rd('quickshell/island/Version' + n + '.qml'))))
ok('SetVersionsAuto.qml: brackets balance', balanced(auto))
ok('every id used by the QML processes is declared once', ['statusProc', 'logProc', 'tagsProc', 'planProc', 'autoProc', 'opProc'].every(id => (vc.match(new RegExp('id: ' + id + '\\b', 'g')) || []).length === 1))

// ---- the scripts and the docs
const upd = rd('update.sh'), ext = rd('scripts/update-extras.sh'), inst = rd('install.sh')
ok('update.sh documents --ref and --unpin', /--ref <commit\|tag>/.test(upd) && /--unpin/.test(upd))
ok('update-extras.sh documents --only, --ref, --unpin, --restore', /--only luna\|ai-antivirus\|ai-firewall/.test(ext) && /--ref <commit\|tag>/.test(ext) && /--unpin/.test(ext) && /--restore/.test(ext))
ok('install.sh documents pins and leaves a pinned extra alone', /pins\.env/.test(inst) && (inst.match(/pinned at \$\{pin:0:7\}, left as it is/g) || []).length === 4)   // LUNA, ai-firewall, ai-antivirus, Halcyon Files
ok('install.sh installs the daily-check units', /halcyon-versions-check\.timer/.test(inst))
ok('systemd units exist, timer is not enabled by default', fs.existsSync(path.join(root, 'systemd/halcyon-versions-check.timer')) && !/enable[^\n]*halcyon-versions-check/.test(inst))
ok('docs/versions.md exists', fs.existsSync(path.join(root, 'docs/versions.md')))
ok('changelog.md has an entry for it', /Version Center/.test(rd('changelog.md')))

// ---- the helper answers with JSON and exits 2 on a bad call (no network, throw-away HOME)
if (process.getuid && process.getuid() !== 0) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'hv-'))
  const env = Object.assign({}, process.env, { HOME: home, HALCYON_DIR: path.join(home, 'nothing') })
  const st = cp.spawnSync('python3', [path.join(root, 'scripts/halcyon-versions.py'), 'status'], { env, encoding: 'utf8' })
  let j = null; try { j = JSON.parse(st.stdout) } catch (e) {}
  ok('helper: status prints JSON for the four components, in the window\'s order', !!j && j.components.map(c => c.id).join() === 'halcyon,luna,ai-antivirus,ai-firewall')
  ok('helper: with nothing chosen the extras are "not-chosen"', !!j && j.components.slice(1).every(c => c.state === 'not-chosen'))
  const bd = cp.spawnSync('python3', [path.join(root, 'scripts/halcyon-versions.py'), 'log', 'nonsense'], { env, encoding: 'utf8' })
  ok('helper: an unknown component is exit 2', bd.status === 2)
  fs.rmSync(home, { recursive: true, force: true })
} else console.log('skip helper run (running as root: the helper refuses root)')

console.log('\n' + n + ' checks, ' + bad + ' failed')
process.exit(bad ? 1 : 0)
