// QML load-breakers that qmllint cannot see here: node tests/qml-types.test.js
// qmllint has no Quickshell type info (not installed in CI, no qmltypes on Arch), so it stops type-checking inside ShellRoot /
// PanelWindow: a misspelled component ("Tourr { }" -> "Tourr is not a type") or one property / handler set twice in the same object
// ("Property value set multiple times") went through CI and broke the island at login. This checks both without Qt.
//  1) every element type is a .qml file of the island, an inline component, or one of the Qt / Quickshell types below
//  2) no object sets the same property or handler twice, and no property is declared twice
// A new Qt / Quickshell type: add it to EXTERNAL.
const fs = require("fs"), path = require("path")
const dir = path.join(__dirname, "..", "quickshell", "island")
const EXTERNAL = new Set(`AnimatedImage Binding MediaPlayer VideoOutput Behavior Canvas ClippingRectangle ColorAnimation Column ColumnLayout Component Connections DragHandler FileView
  Flickable Flow FocusScope FolderListModel FrameAnimation Gradient GradientStop Grid GridLayout GridView HoverHandler Image IntValidator
  IpcHandler Item LazyLoader LinearGradient ListModel ListView Loader MouseArea MultiEffect NotificationServer NumberAnimation PamContext
  PanelWindow ParallelAnimation Path PathAngleArc PathArc PathAttribute PathCubic PathLine PathMove PathPolyline PathSvg PathView PauseAnimation Process
  QsMenuOpener QtObject RadialGradient Rectangle Region Repeater RotationAnimator Row RowLayout Scope ScriptAction ScriptModel
  SequentialAnimation ShaderEffect ShaderEffectSource Shape ShapePath ShellRoot Shortcut SplitParser StdioCollector SystemClock TapHandler Text TextEdit
  TextInput TextMetrics Timer Transition Translate WheelHandler WlSessionLock WlSessionLockSurface
  PropertyAnimation SmoothedAnimation SpringAnimation OpacityAnimator ScaleAnimator XAnimator YAnimator Rotation Scale State
  PropertyChanges AnchorChanges StackView SwipeView Window FloatingWindow PopupWindow Variants TextArea TextField Label Button
  RegularExpressionValidator DoubleValidator ElapsedTimer FontMetrics MultiPointTouchArea PinchHandler PointHandler WheelEvent
  ScrollView ScrollBar Popup Menu MenuItem Instantiator ObjectModel DelegateModel DropArea Drag Keys`.split(/\s+/).filter(Boolean))
const TYPE_BEFORE_BRACE = /(?<![\w.])(?:[A-Z]\w*\.)*([A-Z]\w*)(?:\s+on\s+[\w.]+)?\s*$/

// blank out comments and strings (same length, so positions and line numbers stay right)
function strip(s) {
  const blank = m => m.replace(/[^\n]/g, " ")
  return s.replace(/\/\*[\s\S]*?\*\//g, blank).replace(/\/\/[^\n]*/g, blank)
    .replace(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`/g, m => '"' + blank(m.slice(1, -1)) + '"')
}

const files = fs.readdirSync(dir).filter(f => f.endsWith(".qml"))
const local = new Set(files.map(f => f.slice(0, -4)))
const src = Object.fromEntries(files.map(f => [f, strip(fs.readFileSync(path.join(dir, f), "utf8"))]))
for (const s of Object.values(src)) for (const m of s.matchAll(/\bcomponent\s+(\w+)\s*:/g)) local.add(m[1])

let bad = 0
const fail = msg => { bad++; console.log("FAIL " + msg) }
const lineOf = (s, i) => s.slice(0, i).split("\n").length

for (const f of files) {
  const s = src[f]
  // 1) unknown element types
  for (const m of s.matchAll(/(?<![\w.])(?:[A-Z]\w*\.)*([A-Z]\w*)(?:\s+on\s+[\w.]+)?\s*\{/g)) {
    const t = m[1]
    if (!local.has(t) && !EXTERNAL.has(t)) fail(`${f}:${lineOf(s, m.index)}: unknown type "${t}" (a typo, or a new Qt type: add it to EXTERNAL)`)
  }
  // 2) the same property / handler twice in one object. A stack of braces: object braces (a type before them) get a set of the
  //    names bound directly inside them; code braces (handlers, functions, JS objects) are skipped over.
  const stack = []
  let lineStart = 0
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]
    if (ch === "{") {
      const isObj = TYPE_BEFORE_BRACE.test(s.slice(Math.max(0, i - 120), i)) && (stack.length === 0 || stack[stack.length - 1].obj)
      stack.push({ obj: isObj, names: new Map() })
    } else if (ch === "}") {
      stack.pop()
    } else if (ch === "\n") {
      lineStart = i + 1
      const top = stack[stack.length - 1]
      if (!top || !top.obj) continue
      const rest = s.slice(lineStart, s.indexOf("\n", lineStart) < 0 ? s.length : s.indexOf("\n", lineStart))
      // "name: value", "on.x: value", "readonly property type name: value", "required property var x", "signal x()"
      const m = rest.match(/^\s*(?:(?:readonly\s+|required\s+|default\s+)*property\s+[\w<>.]+\s+(\w+)|([\w.]+)\s*:(?!:))/)
      if (!m) continue
      const name = m[1] || m[2]
      if (/^(anchors|font|border|layer|radius|easing)$/.test(name)) continue     // grouped properties use name.x, not name twice
      const decl = !!m[1]
      const key = (decl ? "decl:" : "set:") + name
      const ln = lineOf(s, lineStart)
      if (top.names.has(key)) fail(`${f}:${ln}: "${name}" is ${decl ? "declared" : "set"} twice in the same object (first on line ${top.names.get(key)}): "Property value set multiple times" stops the island loading`)
      else top.names.set(key, ln)
    }
  }
}
console.log(bad ? `${bad} problem(s)` : `${files.length} QML files: every type is known, nothing is set twice`)
process.exit(bad ? 1 : 0)
