import QtQuick
import Quickshell
import Quickshell.Io

// The lyrics of the song that plays, in the music tab of the rail dashboard (Caelestia's LyricList): the line that is sung now sits in the
// middle, lit, and the lines either side fade away from it.
// Halcyon's own lyrics source (scripts/halcyon-music.py: a .lrc next to the file, then lrclib.net, then lyrics.ovh) answers with `times` beside
// `lines`; this follows the player's position, exactly like the Lyrics desktop widget (WLyrics.qml). No time stamps = nothing to light, so
// it says so; no lyrics = a quiet note. It reads nothing until the tab is on screen, and only once per song.
Item {
    id: root
    property var pal
    property var player: null
    property bool active: false              // the tab is on screen
    signal openFull()                        // click on the text: the lyrics and queue panel (MusicMenu.qml)

    readonly property bool has: player !== null && player !== undefined
    readonly property bool playing: has && player.isPlaying
    readonly property string title: has ? (player.trackTitle || "") : ""
    readonly property string artist: has ? (player.trackArtist || "") : ""
    readonly property string album: has ? (player.trackAlbum || "") : ""
    readonly property real duration: (has && player.length > 0) ? player.length : 0
    readonly property string fileUrl: has && player.metadata ? String(player.metadata["xesam:url"] || "") : ""
    readonly property string key: title + "\u0001" + artist
    property var lines: []
    property var times: []
    property string note: ""
    property string askKey: ""
    property string haveKey: ""              // the song the lines on show belong to
    property bool again: false
    readonly property bool synced: lines.length > 1 && times.length === lines.length

    function reload() {
        if (!active || title === "") { lines = []; times = []; haveKey = ""; note = has ? "" : "Nothing playing"; return }
        if (haveKey === key && lines.length > 0) return
        if (proc.running) { again = true; return }
        askKey = key
        note = "Reading the lyrics ..."
        proc.running = true
    }
    onKeyChanged: { lines = []; times = []; haveKey = ""; wait.restart() }
    onActiveChanged: if (active) wait.restart()
    Timer { id: wait; interval: 400; onTriggered: root.reload() }
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
                    root.haveKey = root.key
                    root.note = root.times.length === root.lines.length ? "" : "These lyrics have no time stamps, so no line can be lit"
                } else {
                    root.lines = []; root.times = []
                    root.note = "No lyrics found"
                }
            }
        }
        onExited: if (root.again) { root.again = false; wait.restart() }
    }

    // which line is sung now
    Timer { interval: 250; repeat: true; running: root.playing && root.active && root.synced; onTriggered: root.player.positionChanged() }
    readonly property real now: has ? player.position : 0
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

    readonly property real rowH: 26

    ListView {
        id: lv
        anchors.fill: parent
        visible: root.synced
        interactive: false
        clip: true
        model: root.synced ? root.lines : []
        currentIndex: Math.max(0, root.cur)
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: (height - root.rowH) / 2
        preferredHighlightEnd: (height + root.rowH) / 2
        highlightMoveDuration: 420
        highlightMoveVelocity: -1
        delegate: Item {
            id: row
            required property int index
            required property string modelData
            readonly property int d: Math.abs(index - root.cur)
            readonly property bool on: index === root.cur
            width: lv.width
            height: root.rowH
            opacity: root.cur < 0 ? Math.max(0.08, 0.5 - 0.2 * index) : Math.max(0.1, 1 - 0.42 * d)
            Behavior on opacity { NumberAnimation { duration: 360; easing.type: Easing.OutCubic } }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: row.modelData === "" ? (row.on ? "\u266A" : "") : row.modelData
                color: row.on ? root.pal.accent : root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: row.on ? 16 : 13
                font.weight: row.on ? Font.DemiBold : Font.Normal
                Behavior on color { ColorAnimation { duration: 280; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            }
        }
    }

    // nothing to light: say why, softly
    Text {
        visible: !root.synced
        anchors.centerIn: parent
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.note
        color: root.pal.muted
        opacity: 0.8
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tBody
    }

    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openFull() }
}
