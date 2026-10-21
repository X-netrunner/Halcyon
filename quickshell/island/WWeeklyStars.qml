import QtQuick
import Quickshell
import Quickshell.Io

// "Weekly stars": your week as stars, on the desktop. One star for every focus session, every note you ticked off and every calendar
// event that has already happened; the stars of one day are joined into a small constellation. It is the same sky as the full-screen
// Weekly sky (WeeklySky.qml, `halcyon weekly-sky`) and reads the same data: scripts/weekly-sky.py json. It only READS, and only while
// the widget is on screen: once at start, then every 10 minutes.   sky | count
WBase {
    id: root

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/weekly-sky.py"
    readonly property bool showLines: opt("lines", true) === true
    readonly property bool showSummary: opt("summary", true) === true
    readonly property real bw: sz(Number(opt("width", 300)))

    property var sky: null
    property var skyCanvas: null
    property string err: ""
    readonly property var counts: sky && sky.counts ? sky.counts : ({ focusMinutes: 0, focus: 0, tasks: 0, events: 0 })
    readonly property int total: counts.focus + counts.tasks + counts.events

    property bool again: false
    function ask() { if (!proc.running) proc.running = true; else again = true }
    onLiveChanged: if (live && sky === null) ask()
    Timer { running: root.live; repeat: true; interval: 600000; triggeredOnStart: true; onTriggered: root.ask() }
    Process {
        id: proc
        command: ["python3", root.script, "json", "--offset", "0"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.sky = JSON.parse(text); root.err = "" } catch (e) { root.err = "no data" }
                if (root.skyCanvas) root.skyCanvas.requestPaint()
            }
        }
        onExited: code => {
            if (code !== 0 && root.sky === null) root.err = "needs python3"
            if (root.again) { root.again = false; root.ask() }
        }
    }

    function fmtMin(m) { return m >= 60 ? Math.floor(m / 60) + " h " + (m % 60 < 10 ? "0" : "") + (m % 60) + " min" : m + " min" }

    implicitWidth: bw
    implicitHeight: body.item ? body.item.implicitHeight : sz(120)
    Loader { id: body; width: root.bw; sourceComponent: root.style === "count" ? countC : skyC }

    // ---- sky: the stars of the week with a letter for every day under them
    Component {
        id: skyC
        Column {
            spacing: root.sz(6)
            Row {
                width: parent.width
                WLbl { b: root; text: "MY WEEK IN STARS"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold; width: parent.width - rg.implicitWidth }
                WLbl { id: rg; b: root; color: root.dim; font.pixelSize: root.sz(11); text: root.sky ? root.sky.range : "" }
            }
            Canvas {
                id: sc
                width: parent.width; height: Math.round(parent.width * 0.40)
                canvasSize: Qt.size(Math.ceil(width * root.rs), Math.ceil(height * root.rs))
                renderTarget: Canvas.Image
                Component.onCompleted: root.skyCanvas = sc
                onWidthChanged: requestPaint()
                Connections {
                    target: root
                    function onSkyChanged() { sc.requestPaint() }
                    function onAccentChanged() { sc.requestPaint() }
                    function onFgChanged() { sc.requestPaint() }
                    function onShowLinesChanged() { sc.requestPaint() }
                }
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.setTransform(1, 0, 0, 1, 0, 0)
                    ctx.clearRect(0, 0, canvasSize.width, canvasSize.height)
                    ctx.scale(root.rs, root.rs)
                    var W = width, H = height, d = root.sky
                    if (!d) return
                    function px(x) { return x * W }
                    function py(y) { return Math.max(0.06, Math.min(0.94, (y - 0.16) / 0.68)) * H }
                    var ac = root.accent, fg = root.fg
                    // dust
                    for (var k = 0; k < d.dust.length; k++) {
                        var u = d.dust[k]
                        ctx.fillStyle = Qt.alpha(fg, u[3] * 0.6)
                        ctx.beginPath(); ctx.arc(px(u[0]), u[1] * H, u[2] * 0.5, 0, Math.PI * 2); ctx.fill()
                    }
                    // constellation lines
                    if (root.showLines) {
                        ctx.lineWidth = 1
                        for (var m = 0; m < d.lines.length; m++) {
                            var ln = d.lines[m], a = d.stars[ln[0]], b = d.stars[ln[1]]
                            if (!a || !b) continue
                            ctx.strokeStyle = Qt.alpha(ac, ln[2] === 1 ? 0.14 : 0.38)
                            ctx.beginPath(); ctx.moveTo(px(a.x), py(a.y)); ctx.lineTo(px(b.x), py(b.y)); ctx.stroke()
                        }
                    }
                    // stars: a soft glow and a bright core; focus = the lit colour, a ticked note = lighter, an event = text colour
                    for (var q = 0; q < d.stars.length; q++) {
                        var s = d.stars[q]
                        var col = s.kind === "focus" ? ac : (s.kind === "task" ? Qt.lighter(ac, 1.5) : fg)
                        var r = (1.6 + 2.2 * Math.max(0, Math.min(1, s.w)))
                        var x = px(s.x), y = py(s.y)
                        ctx.fillStyle = Qt.alpha(col, 0.16)
                        ctx.beginPath(); ctx.arc(x, y, r * 3, 0, Math.PI * 2); ctx.fill()
                        ctx.fillStyle = Qt.alpha(col, 0.95)
                        ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill()
                    }
                }
            }
            // the seven days under the sky
            Item {
                width: parent.width; height: root.sz(12)
                Repeater {
                    model: ["M", "T", "W", "T", "F", "S", "S"]
                    delegate: WLbl {
                        required property string modelData
                        required property int index
                        b: root; text: modelData; color: root.dim; font.pixelSize: root.sz(9)
                        x: parent.width * (0.07 + 0.86 * (index + 0.5) / 7) - width / 2
                    }
                }
            }
            WLbl {
                visible: root.showSummary
                b: root; width: parent.width; wrapMode: Text.WordWrap; color: root.dim; font.pixelSize: root.sz(11)
                text: root.sky ? root.sky.summary : (root.err !== "" ? root.err : "Reading your week…")
            }
        }
    }

    // ---- count: the numbers only
    Component {
        id: countC
        Column {
            spacing: root.sz(8)
            WLbl { b: root; text: "MY WEEK IN STARS"; color: root.accent; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
            Row {
                spacing: root.sz(10)
                WIco { b: root; text: root.glyph(0xF04CE); color: root.accent; font.pixelSize: root.sz(34); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.total; font.pixelSize: root.sz(48); font.weight: Font.Light; anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.total === 1 ? "star" : "stars"; color: root.dim; font.pixelSize: root.sz(14); anchors.verticalCenter: parent.verticalCenter }
            }
            Row {
                spacing: root.sz(18)
                Repeater {
                    model: [
                        { n: root.fmtMin(root.counts.focusMinutes), l: "FOCUS" },
                        { n: String(root.counts.tasks), l: "TASKS" },
                        { n: String(root.counts.events), l: "EVENTS" }
                    ]
                    delegate: Column {
                        required property var modelData
                        spacing: 0
                        WLbl { b: root; text: modelData.n; font.pixelSize: root.sz(15); font.weight: Font.DemiBold }
                        WLbl { b: root; text: modelData.l; color: root.dim; font.pixelSize: root.sz(9); font.letterSpacing: 1.4 }
                    }
                }
            }
            WLbl { visible: root.err !== "" && root.sky === null; b: root; text: root.err; color: root.dim; font.pixelSize: root.sz(11) }
        }
    }
}
