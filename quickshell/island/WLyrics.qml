import QtQuick
import Quickshell
import Quickshell.Io

// "Lyrics": the words of the song that plays, the line being sung lit and the others fading away from it.
// Needs lyrics with time stamps (LRCLIB has them for most songs; a .lrc next to a local file works too): scripts/halcyon-music.py
// answers with `times` (seconds) beside `lines`, and this widget follows the player's position.   fade | karaoke | spotlight | single
WBase {
    id: root

    readonly property var pl: env ? env.player : null
    readonly property bool has: pl !== null && pl !== undefined
    readonly property bool playing: has && pl.isPlaying
    readonly property real wide: opt("width", 380)
    readonly property real lw: Math.max(wide, width)
    readonly property int shown: Math.round(opt("lines", 5))            // lines on screen (spotlight and single ignore it)
    readonly property real lead: opt("sync", 0) / 10                    // seconds (the slider is in tenths): + lights a line earlier, - later
    readonly property real fall: opt("fall", 3) / 10                    // how fast the lines away from the sung one fade
    readonly property bool center: style !== "karaoke"
    hidden: !has && opt("hideIdle", true) === true

    // ---- the song and its words
    readonly property string title: has ? (pl.trackTitle || "") : ""
    readonly property string artist: has ? (pl.trackArtist || "") : ""
    readonly property string album: has ? (pl.trackAlbum || "") : ""
    readonly property real duration: has && pl.length > 0 ? pl.length : 0
    readonly property string fileUrl: has && pl.metadata ? String(pl.metadata["xesam:url"] || "") : ""
    readonly property string key: title + "\u0001" + artist
    property var lines: []
    property var times: []
    property string note: ""                                            // what to say when there is nothing to light
    property string askKey: ""
    property bool again: false
    readonly property bool synced: lines.length > 1 && times.length === lines.length

    function reload() {
        if (!live || title === "") { lines = []; times = []; note = has ? "" : "Nothing plays"; return }
        if (proc.running) { again = true; return }
        askKey = key
        note = "Reading the lyrics ..."
        proc.running = true
    }
    onKeyChanged: { lines = []; times = []; wait.restart() }
    onLiveChanged: if (live) wait.restart()
    Timer { id: wait; interval: 500; onTriggered: root.reload() }
    Process {
        id: proc
        command: ["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-music.py", "lyrics", "json",
                  "--title", root.title, "--artist", root.artist, "--album", root.album,
                  "--duration", String(Math.round(root.duration)), "--url", root.fileUrl]
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (root.askKey !== root.key) return                  // the song changed while it was read
                if (d && d.ok && d.lines && d.lines.length) {
                    root.lines = d.lines
                    root.times = d.times || []
                    root.note = root.times.length === root.lines.length ? "" : "These lyrics have no time stamps, so no line can be lit"
                } else {
                    root.lines = []; root.times = []
                    root.note = "No lyrics found"
                }
            }
        }
        onExited: if (root.again) { root.again = false; wait.restart() }
    }

    // ---- which line is sung now
    Timer { interval: 250; repeat: true; running: root.playing && root.live && root.synced; onTriggered: root.pl.positionChanged() }
    readonly property real now: has ? pl.position + lead : 0
    property int cur: -1
    function find() {
        var t = times, n = t.length
        if (!synced || now < t[0]) return -1
        var lo = 0, hi = n - 1
        while (lo < hi) { var mid = (lo + hi + 1) >> 1; if (t[mid] <= now) lo = mid; else hi = mid - 1 }
        return lo
    }
    onNowChanged: { var i = find(); if (i !== cur) cur = i }
    onTimesChanged: cur = find()
    // how far through the sung line (0..1), for the karaoke sweep
    readonly property real prog: {
        if (cur < 0 || !synced) return 0
        var a = times[cur], b = cur + 1 < times.length ? times[cur + 1] : a + 4
        return Math.max(0, Math.min(1, (now - a) / Math.max(0.3, Math.min(b - a, 8))))
    }

    readonly property real fsz: sz(opt("size", 20))
    readonly property real rowH: fsz * 1.55
    readonly property int rows: style === "spotlight" ? 3 : (style === "single" ? 1 : Math.max(3, shown))
    implicitWidth: wide
    implicitHeight: Math.round(rowH * rows)

    // the line list: the sung line is kept in the middle (or at the top for karaoke); the others fade with their distance from it
    ListView {
        id: lv
        visible: root.synced
        width: root.lw
        height: root.implicitHeight
        x: Math.max(0, (root.width - width) / 2)
        interactive: false
        clip: true
        model: root.synced ? root.lines : []
        currentIndex: Math.max(0, root.cur)
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: root.center ? (height - root.rowH) / 2 : root.rowH * 0.4
        preferredHighlightEnd: root.center ? (height + root.rowH) / 2 : root.rowH * 1.4
        highlightMoveDuration: 520
        highlightMoveVelocity: -1
        delegate: Item {
            id: row
            required property int index
            required property string modelData
            readonly property int d: Math.abs(index - root.cur)
            readonly property bool on: index === root.cur
            readonly property real lim: root.style === "single" ? 0 : (root.style === "spotlight" ? 1 : 99)
            width: lv.width
            height: modelData === "" ? root.rowH * 0.6 : Math.max(root.rowH, txt.implicitHeight + root.fsz * 0.3)
            opacity: root.cur < 0 ? Math.max(0.07, 0.5 - 0.2 * index) : (d > lim ? 0 : Math.max(0.06, 1 - root.fall * d))
            scale: on ? 1 : Math.max(0.82, 1 - 0.045 * d)
            transformOrigin: root.center ? Item.Center : Item.Left
            Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

            // the glow under the lit line, then the line itself (dim), then the lit copy that is swept in for karaoke
            Text {
                visible: row.on && root.style !== "karaoke"
                anchors.fill: txt
                text: txt.text; font: txt.font; wrapMode: txt.wrapMode; horizontalAlignment: txt.horizontalAlignment
                color: "transparent"
                style: Text.Outline
                styleColor: Qt.alpha(root.accent, 0.38)
            }
            Text {
                id: txt
                width: parent.width - root.fsz
                x: root.fsz / 2
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData === "" ? (row.on ? "\u266A" : "") : row.modelData
                font.family: root.face
                font.pixelSize: root.fsz
                font.weight: row.on ? Font.DemiBold : Font.Normal
                wrapMode: Text.WordWrap
                horizontalAlignment: root.center ? Text.AlignHCenter : Text.AlignLeft
                color: row.on ? (root.style === "karaoke" ? root.dim : root.fg) : root.dim
                Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            }
            Item {
                visible: row.on && root.style === "karaoke"
                x: txt.x; y: txt.y
                width: txt.width * root.prog; height: txt.height
                clip: true
                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Text {
                    width: txt.width; height: txt.height
                    text: txt.text; font: txt.font; wrapMode: txt.wrapMode
                    color: root.accent
                }
            }
        }
    }

    // nothing to light: say why, softly
    Text {
        visible: !root.synced
        width: root.lw
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        text: root.note !== "" ? root.note : (root.title !== "" ? root.title : "")
        color: root.dim
        opacity: 0.7
        font.family: root.face
        font.pixelSize: root.sz(14)
        wrapMode: Text.WordWrap
    }
}
