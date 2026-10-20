import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The weekly sky: your week drawn as stars. One star for every focus session, every note you ticked off and every calendar event
// that has already happened; stars of one day are joined into a small constellation, so the sky slowly fills in from the left as the
// week goes by.  Open it with `>weekly sky` in the launcher, `halcyon weekly-sky`, Settings > Splash, sky & time of day, or
// `quickshell ipc ... call island weeklysky`. Esc / a click outside closes it, Left / Right change the week, S saves a picture.
// "Save picture" writes weekly-sky-YYYY-Www.svg (and a .png when a converter is installed) to ~/Pictures/Halcyon and tells you where.
//
// The data and the picture come from scripts/weekly-sky.py (it only reads what Halcyon already keeps). This file runs that script when
// it opens or when you change the week, draws the answer on one Canvas, and has no timer: the stars twinkle only while it is open,
// from a single 33 ms clock. The window does not exist while it is closed.
Scope {
    id: root
    property var pal
    property bool open: false
    function show() { open = true }
    function hide() { open = false }
    function toggle() { open = !open }

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/weekly-sky.py"

    LazyLoader {
        active: root.open
        PanelWindow {
            id: win
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-weekly-sky"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            Item {
                id: stage
                anchors.fill: parent
                focus: true

                property int offset: 0                 // 0 = this week, -1 = last week ...
                property var sky: null                 // the JSON from weekly-sky.py
                property string status: "Reading your week…"
                property string saved: ""              // where the last picture went (a message)
                property real born: 0                  // 0 .. 1: the stars appear in time order while this runs
                property real tw: 0                    // twinkle clock

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) root.open = false
                    else if (event.key === Qt.Key_Left) stage.go(-1)
                    else if (event.key === Qt.Key_Right) stage.go(1)
                    else if (event.key === Qt.Key_S) stage.save()
                    else return
                    event.accepted = true
                }

                function go(d) {
                    var n = Math.min(0, offset + d)
                    if (n === offset) return
                    offset = n
                    load()
                }
                function load() {
                    saved = ""
                    status = "Reading your week…"
                    reader.running = false
                    reader.command = ["python3", root.script, "json", "--offset", String(offset)]
                    reader.running = true
                }
                function save() {
                    if (!sky || exporter.running) return
                    saved = "Saving…"
                    exporter.command = ["python3", root.script, "export", "--offset", String(offset)]
                    exporter.running = true
                }
                Component.onCompleted: load()

                Process {
                    id: reader
                    stdout: StdioCollector {
                        onStreamFinished: {
                            try {
                                var d = JSON.parse(text)
                                stage.sky = d
                                stage.status = ""
                                stage.born = 0
                                bornAnim.restart()
                            } catch (e) {
                                stage.sky = null
                                stage.status = "Could not read your week (is python3 installed?)"
                            }
                            chart.requestPaint()
                        }
                    }
                }
                Process {
                    id: exporter
                    stdout: StdioCollector {
                        onStreamFinished: {
                            try {
                                var r = JSON.parse(text)
                                if (r.ok) {
                                    var f = r.png !== "" ? r.png : r.svg
                                    stage.saved = "Saved: " + f.replace(Quickshell.env("HOME"), "~")
                                    Quickshell.execDetached(["notify-send", "-a", "Halcyon", "-i", "applications-graphics", "Weekly sky saved", f.replace(Quickshell.env("HOME"), "~") + (r.note ? "\n" + r.note : "")])
                                } else stage.saved = r.error || "Could not save the picture"
                            } catch (e) { stage.saved = "Could not save the picture" }
                        }
                    }
                }
                NumberAnimation { id: bornAnim; target: stage; property: "born"; from: 0; to: 1; duration: 1800; easing.type: Easing.OutCubic }
                // twinkle: one slow clock, only while the card is open
                Timer {
                    interval: 33; repeat: true; running: stage.sky !== null && root.pal.motion > 0.3
                    onTriggered: { stage.tw += 0.033; chart.requestPaint() }
                }
                onBornChanged: chart.requestPaint()

                // ---- the dim sheet behind the card: a click on it closes
                Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.55) }
                MouseArea { anchors.fill: parent; onPressed: root.open = false }

                // ---- the card
                Rectangle {
                    id: card
                    width: Math.min(parent.width - 80, 1180)
                    height: Math.min(parent.height - 80, Math.round(width * 0.62))
                    anchors.centerIn: parent
                    radius: 22
                    color: root.pal.bg
                    border.width: 1
                    border.color: root.pal.line
                    clip: true
                    MouseArea { anchors.fill: parent; onPressed: mouse => mouse.accepted = true }     // clicks on the card do not close it

                    // header
                    Column {
                        id: head
                        x: 34; y: 26
                        spacing: 4
                        Text {
                            text: stage.offset === 0 ? "My week in stars" : "A week in stars"
                            color: root.pal.text
                            font.family: root.pal.uiFont; font.pixelSize: 28; font.weight: Font.Light; font.letterSpacing: 1.5
                        }
                        Text {
                            text: stage.sky ? stage.sky.range + "  ·  " + stage.sky.summary : stage.status
                            color: root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: 14
                        }
                    }

                    // the sky
                    Canvas {
                        id: chart
                        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: foot.top; topMargin: 6; bottomMargin: 4 }
                        renderTarget: Canvas.FramebufferObject
                        renderStrategy: Canvas.Immediate
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var d = stage.sky
                            if (!d) return
                            var W = width, H = height
                            // the sky band in the data is y 0.22 .. 0.78 of a picture that also has a heading and day names; here the
                            // heading is outside the canvas, so use the whole height
                            function px(x) { return x * W }
                            function py(y) { return (y - 0.14) / 0.72 * H }
                            var a1 = root.pal.accent, a2 = root.pal.accent2, tx = root.pal.text
                            var col = { focus: a1, task: a2, event: tx }
                            // day columns
                            ctx.strokeStyle = Qt.rgba(tx.r, tx.g, tx.b, 0.07)
                            ctx.lineWidth = 1
                            for (var i = 1; i < 7; i++) {
                                var gx = Math.round(W * (0.07 + 0.86 * i / 7)) + 0.5
                                ctx.beginPath(); ctx.moveTo(gx, 4); ctx.lineTo(gx, H - 26); ctx.stroke()
                            }
                            ctx.fillStyle = Qt.rgba(root.pal.muted.r, root.pal.muted.g, root.pal.muted.b, 0.7)
                            ctx.font = "11px sans-serif"
                            ctx.textAlign = "center"
                            var names = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
                            for (var j = 0; j < 7; j++) ctx.fillText(names[j], W * (0.07 + 0.86 * (j + 0.5) / 7), H - 8)
                            // dust
                            for (var k = 0; k < d.dust.length; k++) {
                                var u = d.dust[k]
                                var tl = 0.75 + 0.25 * Math.sin(stage.tw * 1.3 + k * 1.7)
                                ctx.fillStyle = Qt.rgba(tx.r, tx.g, tx.b, u[3] * tl)
                                ctx.beginPath(); ctx.arc(px(u[0]), py(u[1] * 0.72 + 0.14), u[2] * 0.8, 0, 6.2832); ctx.fill()
                            }
                            // the stars are born in time order, left to right: `born` (0 .. 1) sweeps across the part of the week that has
                            // happened, and a star takes ~3 % of the week to fade in. At born = 1 even the newest star is fully there.
                            var n = d.stars.length
                            var upto = stage.born * (Math.max(d.fill, 0.0001) + 0.03)
                            function alive(i) {
                                var f = (d.stars[i].t - d.weekStart) / (d.weekEnd - d.weekStart)      // 0 .. 1 through the week
                                return Math.max(0, Math.min(1, (upto - f) / 0.03))
                            }
                            // lines
                            ctx.lineWidth = 1
                            for (var m = 0; m < d.lines.length; m++) {
                                var ln = d.lines[m]
                                var al = Math.min(alive(ln[0]), alive(ln[1]))
                                if (al <= 0) continue
                                ctx.strokeStyle = Qt.rgba(tx.r, tx.g, tx.b, (ln[2] ? 0.10 : 0.26) * al)
                                ctx.beginPath()
                                ctx.moveTo(px(d.stars[ln[0]].x), py(d.stars[ln[0]].y))
                                ctx.lineTo(px(d.stars[ln[1]].x), py(d.stars[ln[1]].y))
                                ctx.stroke()
                            }
                            // stars: a soft glow and a four-point sparkle, a little different twinkle each
                            for (var q = 0; q < n; q++) {
                                var s = d.stars[q]
                                var life = alive(q)
                                if (life <= 0) continue
                                var c = col[s.kind] || tx
                                var x = px(s.x), y = py(s.y)
                                var r = (6 + 12 * s.w) * (0.55 + 0.45 * life) * (1 + 0.06 * Math.sin(stage.tw * 2.1 + q))
                                var g = ctx.createRadialGradient(x, y, 0, x, y, r * 3)
                                g.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 0.45 * life))
                                g.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0))
                                ctx.fillStyle = g
                                ctx.beginPath(); ctx.arc(x, y, r * 3, 0, 6.2832); ctx.fill()
                                var cc = r * 0.16, rh = r * 0.84
                                ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, life)
                                ctx.beginPath()
                                ctx.moveTo(x, y - r)
                                ctx.quadraticCurveTo(x + cc, y - cc, x + rh, y)
                                ctx.quadraticCurveTo(x + cc, y + cc, x, y + r)
                                ctx.quadraticCurveTo(x - cc, y + cc, x - rh, y)
                                ctx.quadraticCurveTo(x - cc, y - cc, x, y - r)
                                ctx.closePath(); ctx.fill()
                                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.9 * life)
                                ctx.beginPath(); ctx.arc(x, y, Math.max(1.2, r * 0.17), 0, 6.2832); ctx.fill()
                            }
                            if (n === 0) {
                                ctx.fillStyle = Qt.rgba(tx.r, tx.g, tx.b, 0.55)
                                ctx.font = "15px sans-serif"
                                ctx.textAlign = "center"
                                ctx.fillText("No stars yet. Finish a Focus session, tick off a note, or go to a meeting.", W / 2, H / 2)
                            }
                        }
                    }

                    // hover: what a star is (nearest one within reach of the pointer)
                    MouseArea {
                        anchors.fill: chart
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                        onPositionChanged: mouse => {
                            var d = stage.sky
                            tip.text = ""
                            if (!d) return
                            var best = -1, bd = 22 * 22
                            for (var i = 0; i < d.stars.length; i++) {
                                var dx = mouse.x - d.stars[i].x * width, dy = mouse.y - (d.stars[i].y - 0.14) / 0.72 * height
                                if (dx * dx + dy * dy < bd) { bd = dx * dx + dy * dy; best = i }
                            }
                            if (best >= 0) {
                                var s = d.stars[best]
                                tip.text = s.label + "  ·  " + Qt.formatDateTime(new Date(s.t * 1000), "ddd HH:mm")
                                tip.x = Math.min(width - tip.width - 8, Math.max(8, mouse.x + 14))
                                tip.y = Math.max(8, mouse.y - 30)
                            }
                        }
                        onExited: tip.text = ""
                        Rectangle {
                            id: tip
                            property alias text: tipText.text
                            visible: text !== ""
                            width: tipText.implicitWidth + 20; height: 26; radius: 13
                            color: Qt.alpha(root.pal.surfaceHi, 0.95)
                            border.width: 1; border.color: root.pal.lineSoft
                            Text { id: tipText; anchors.centerIn: parent; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 12 }
                        }
                    }

                    // footer: legend on the left, buttons on the right
                    Item {
                        id: foot
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 62
                        Row {
                            x: 34; anchors.verticalCenter: parent.verticalCenter
                            spacing: 20
                            Repeater {
                                model: [{ k: "focus", n: "focus session" }, { k: "task", n: "task done" }, { k: "event", n: "calendar event" }]
                                delegate: Row {
                                    required property var modelData
                                    spacing: 7
                                    Rectangle {
                                        width: 9; height: 9; radius: 4.5; anchors.verticalCenter: parent.verticalCenter
                                        color: modelData.k === "focus" ? root.pal.accent : (modelData.k === "task" ? root.pal.accent2 : root.pal.text)
                                    }
                                    Text { text: modelData.n; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                                }
                            }
                            Text {
                                visible: stage.saved !== ""
                                text: stage.saved
                                color: root.pal.accent
                                font.family: root.pal.uiFont; font.pixelSize: 12
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Row {
                            anchors { right: parent.right; rightMargin: 28; verticalCenter: parent.verticalCenter }
                            spacing: 8
                            ActionChip { pal: root.pal; label: "◀ Earlier"; onClicked: stage.go(-1) }
                            ActionChip { pal: root.pal; label: "Later ▶"; disabled: stage.offset >= 0; onClicked: stage.go(1) }
                            ActionChip { pal: root.pal; label: "Save picture"; doneLabel: "Saving…"; disabled: !stage.sky; onClicked: stage.save() }
                            ActionChip { pal: root.pal; label: "Close"; onClicked: root.open = false }
                        }
                    }
                }
            }
        }
    }
}
