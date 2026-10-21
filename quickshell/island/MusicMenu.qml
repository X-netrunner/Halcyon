import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Lyrics and queue.   The Lyrics / Queue chips on the media page, >lyrics and >queue in the launcher, `halcyon music` (and the IPC calls
// `lyrics`, `queue`, `music`).
// A panel on the side of the screen (same place and look as the clipboard and new-note panels) with two tabs: the lyrics of the song
// that is playing, and what plays next. Tab (or Left / Right) switches, Up / Down / Page Up / Page Down scroll, R reads again, Esc closes.
//
// The data is scripts/halcyon-music.py. LYRICS work with any player that speaks MPRIS: the panel hands the helper the title, artist,
// album, length and file of what plays, and the helper asks (music.conf LYRICS_SOURCE, default auto): a .lrc / .txt next to the song
// file, then lrclib.net (free, no account), then api.lyrics.ovh, then `spotify_player` if it is installed. spotify_player is optional.
// The QUEUE is still Spotify's (`spotify_player get key queue`), so that tab needs it. The queue is read-only: spotify_player has
// no "play this one now" command, so a row is not a button.
//
// Nothing runs while the panel is closed (LazyLoader, no surface, no timer, no process). While it is open it asks once when it opens,
// once more when the song changes, and when you press R. Lyrics already read for a song are kept in memory (the last few songs) until
// the island restarts, so closing and reopening the panel on the same song does not ask again.
Scope {
    id: root
    property var pal
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property var opt: ({})                  // the island's settings: the stars follow the Desktop builder's direction, speed and colour
    property string spot: "tl"              // where the pop-out console opens (the panel goes to the other side)
    property string title: ""               // what the media page shows (only used to notice a song change)
    property string artist: ""
    property string album: ""
    property real duration: 0               // seconds, 0 = unknown (helps pick the right version of a song)
    property string fileUrl: ""             // file:// address of the song when the player plays a local file (for a .lrc next to it)
    property bool open: false
    property string tab: "lyrics"           // lyrics | queue

    readonly property bool panelRight: spot.charAt(1) !== "r"
    readonly property bool panelBottom: spot.charAt(0) === "b"
    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-music.py"
    readonly property string trackKey: title + "\u0001" + artist

    // ---- what is shown
    property var lyr: ({ ok: false, state: "", message: "", title: "", artist: "", lines: [] })
    property var que: ({ ok: false, state: "", message: "", now: null, total: 0, items: [] })
    property bool lyrLoaded: false
    property bool queLoaded: false
    property bool lyrStale: true            // the song changed since it was read
    property bool queStale: true
    property var lyrCache: ({})             // trackKey -> a good (or "no lyrics") answer; the last few songs
    property var lyrOrder: []

    function show(t) {
        tab = (t === "queue") ? "queue" : "lyrics"
        open = true
        ensure()
    }
    function hide() { open = false }
    function close() { hide() }
    function toggle() { if (open) hide(); else show(tab) }
    // `>lyrics` / `>queue`: the same command again closes; the other one switches tab
    function toggleTab(t) {
        if (open && tab === t) { hide(); return }
        tab = t
        open = true
        ensure()
    }
    function pick(t) { if (t === tab) return; tab = t; ensure() }

    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    // ---- a new song while the panel is open: read again, after a moment (the player updates title and artist one after the other)
    onTrackKeyChanged: { lyrStale = true; queStale = true; aiView = ""; aiOut = ""; aiFor = ""; if (open) songT.restart() }
    Timer { id: songT; interval: 900; onTriggered: if (root.open) root.ensure() }

    // ---- reading
    function ensure() {
        if (tab === "lyrics") {
            if (lyrStale || !lyrLoaded) loadLyrics(false)
        } else if (queStale || !queLoaded) loadQueue()
    }
    function reload() { if (tab === "lyrics") loadLyrics(true); else loadQueue() }

    property string lyrAsk: ""              // the song the running lyrics read was started for
    property bool lyrAgain: false
    function loadLyrics(force) {
        var k = trackKey
        if (!force && k !== "\u0001" && lyrCache[k]) {
            lyr = lyrCache[k]; lyrLoaded = true; lyrStale = false
            return
        }
        if (lyrProc.running) { lyrAgain = true; return }
        lyrAsk = k
        lyrLoaded = false
        lyrProc.running = true
    }
    Process {
        id: lyrProc
        command: ["python3", root.script, "lyrics", "json", "--title", root.title, "--artist", root.artist, "--album", root.album,
                  "--duration", String(Math.round(root.duration)), "--url", root.fileUrl]
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (d === null) d = { ok: false, state: "error", message: "The lyrics answer could not be read.", title: "", artist: "", lines: [] }
                root.lyr = d
                root.lyrLoaded = true
                root.lyrStale = false
                // keep a good answer (and "this song has no lyrics") for the last few songs; errors are never kept, so R retries.
                // Only when the song did not change during the read: the answer is the account's CURRENT song, so it could belong to the next one
                if ((d.ok || d.state === "none") && root.lyrAsk !== "\u0001" && root.lyrAsk === root.trackKey) {
                    var c = root.lyrCache, o = root.lyrOrder.filter(function (x) { return x !== root.lyrAsk })
                    c[root.lyrAsk] = d
                    o.push(root.lyrAsk)
                    while (o.length > 6) delete c[o.shift()]
                    root.lyrCache = c
                    root.lyrOrder = o
                }
            }
        }
        onExited: {
            if (!root.lyrLoaded) {          // it could not even start (python missing ...): say so instead of loading for ever
                root.lyr = { ok: false, state: "error", message: "The lyrics could not be read.", title: "", artist: "", lines: [] }
                root.lyrLoaded = true
            }
            if (root.lyrAgain) { root.lyrAgain = false; root.lyrStale = true; if (root.open && root.tab === "lyrics") root.loadLyrics(false) }
        }
    }

    property bool queAgain: false
    function loadQueue() {
        if (queProc.running) { queAgain = true; return }
        queLoaded = false
        queProc.running = true
    }
    Process {
        id: queProc
        command: ["python3", root.script, "queue", "json", "50"]
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (d === null) d = { ok: false, state: "error", message: "The queue answer could not be read.", now: null, total: 0, items: [] }
                root.que = d
                root.queLoaded = true
                root.queStale = false
            }
        }
        onExited: {
            if (!root.queLoaded) {
                root.que = { ok: false, state: "error", message: "The queue could not be read.", now: null, total: 0, items: [] }
                root.queLoaded = true
            }
            if (root.queAgain) { root.queAgain = false; root.queStale = true; if (root.open && root.tab === "queue") root.loadQueue() }
        }
    }

    // ---- small helpers for the text
    function clock(ms) {
        if (!(ms > 0)) return ""
        var s = Math.floor(ms / 1000)
        var r = s % 60
        return Math.floor(s / 60) + ":" + (r < 10 ? "0" : "") + r
    }
    readonly property bool busy: tab === "lyrics" ? !lyrLoaded : !queLoaded

    // ---- the AI on the song (scripts/halcyon-ai.py lyrics meaning): what it is about.
    // Shown in place of the lyrics until "Lyrics" is picked again or the song changes; answers are cached by the script per song.
    property string aiView: ""              // "" (the lyrics) | meaning
    property string aiOut: ""
    property bool aiOk: true
    property string aiFor: ""               // trackKey + view the answer is for
    readonly property string aiScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-ai.py"
    function aiShow(v) {
        if (v === "" || v === aiView) { aiView = ""; return }
        aiView = v
        if (aiFor === trackKey + "\u0001" + v && aiOut !== "") return
        if (aiProc.running) return
        aiOut = ""; aiOk = true; aiFor = trackKey + "\u0001" + v
        aiProc.command = ["python3", aiScript, "lyrics", v, "--json", "--title", title, "--artist", artist, "--album", album,
                          "--duration", String(Math.round(duration)), "--url", fileUrl]
        aiProc.running = true
    }
    Process {
        id: aiProc
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                root.aiOk = !!d && d.ok === true
                root.aiOut = !d ? "No answer (is python3 there?)" : (d.ok ? d.text : d.error)
            }
        }
    }
    readonly property var cur: tab === "lyrics" ? lyr : que
    // the song the answer is about (the script's own words, so a mismatch with the media page is visible)
    readonly property string subject: {
        if (tab === "lyrics") return (lyr.title || "") + (lyr.artist ? "   \u00b7   " + lyr.artist : "")
        var n = que.now
        return n ? (n.title + (n.artist ? "   \u00b7   " + n.artist : "")) : ""
    }
    readonly property string counter: {
        if (busy) return "Reading ..."
        if (tab === "lyrics") return lyr.ok ? lyr.lines.filter(function (l) { return l !== "" }).length + " lines" + (lyr.source ? "   \u00b7   " + ({ lrclib: "LRCLIB", ovh: "lyrics.ovh", local: "local file", spotify: "Spotify" }[lyr.source] || lyr.source) : "") : ""
        return que.ok ? (que.total + (que.total === 1 ? " song next" : " songs next")) : ""
    }

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-music"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // a click anywhere outside the panel closes it
            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { keys.forceActiveFocus() }) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: 520
                    height: Math.min(qp.height - root.pal.boxTop - root.pal.boxEdge, 620)
                    radius: root.pal.rXl
                    opacityBody: root.pal.solid ? 1 : 0.90
                    border.color: Qt.alpha(root.pal.accent, 0.40)
                    opacity: qp.reveal
                    x: root.panelRight ? qp.width - width - 22 + (1 - qp.reveal) * width * 0.4
                                       : 22 - (1 - qp.reveal) * width * 0.4
                    y: root.panelBottom ? qp.height - height - root.pal.boxEdge : root.pal.boxTop
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    NoteStars {
                        anchors.fill: parent
                        anchors.margins: 1
                        pal: root.pal
                        opt: root.opt
                        running: root.stars && root.open
                        count: 30
                    }

                    // the keys (the panel has no text field, so this is what holds the keyboard focus)
                    FocusScope {
                        id: keys
                        anchors.fill: parent
                        focus: true
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                            else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Left || e.key === Qt.Key_Right) {
                                root.pick(root.tab === "lyrics" ? "queue" : "lyrics"); e.accepted = true
                            }
                            else if (e.key === Qt.Key_R) { root.reload(); e.accepted = true }
                            else if (e.key === Qt.Key_Down || e.key === Qt.Key_Up || e.key === Qt.Key_PageDown || e.key === Qt.Key_PageUp) {
                                var v = root.tab === "lyrics" ? (root.aiView !== "" ? aiFlick : lyrList) : queList
                                var step = (e.key === Qt.Key_PageDown || e.key === Qt.Key_PageUp) ? v.height * 0.85 : 60
                                var dir = (e.key === Qt.Key_Down || e.key === Qt.Key_PageDown) ? 1 : -1
                                v.contentY = Math.max(0, Math.min(Math.max(0, v.contentHeight - v.height), v.contentY + dir * step))
                                e.accepted = true
                            }
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 20
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                color: root.busy ? root.pal.warn : (root.cur.ok ? root.pal.accent : root.pal.muted)
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                            }
                            SegSwitch {
                                pal: root.pal
                                options: [{ k: "lyrics", t: "Lyrics" }, { k: "queue", t: "Queue" }]
                                current: root.tab
                                onPicked: k => root.pick(k)
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.counter
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                            }
                            RoundBtn {
                                pal: root.pal
                                size: 28
                                glyph: String.fromCodePoint(0xF0450)
                                enabledBtn: !root.busy
                                onClicked: root.reload()
                            }
                            RoundBtn {
                                pal: root.pal
                                size: 28
                                glyph: String.fromCodePoint(0xF0156)
                                onClicked: root.hide()
                            }
                        }

                        // which song this is about
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: root.subject
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tTitle
                            font.weight: Font.DemiBold
                        }

                        // ---- the lyrics, or what the AI says about them
                        Flow {
                            Layout.fillWidth: true
                            visible: root.tab === "lyrics" && root.title !== ""
                            spacing: 8
                            Repeater {
                                model: [["", "Lyrics"], ["meaning", "Meaning"]]
                                delegate: Chip {
                                    required property var modelData
                                    pal: root.pal; implicitHeight: 28
                                    label: modelData[1]
                                    on: root.aiView === modelData[0]
                                    onClicked: root.aiShow(modelData[0])
                                }
                            }
                        }
                        Flickable {
                            id: aiFlick
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "lyrics" && root.aiView !== ""
                            contentWidth: width
                            contentHeight: aiTxt.implicitHeight
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            Text {
                                id: aiTxt
                                width: aiFlick.width - 12
                                wrapMode: Text.Wrap
                                text: aiProc.running ? "Thinking about the song…" : root.aiOut
                                color: aiProc.running ? root.pal.muted : (root.aiOk ? root.pal.text : root.pal.warn)
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody + 1
                                lineHeight: 1.3
                            }
                        }

                        ListView {
                            id: lyrList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "lyrics" && root.lyrLoaded && root.lyr.ok && root.aiView === ""
                            clip: true
                            spacing: 4
                            model: root.tab === "lyrics" && root.lyr.ok ? root.lyr.lines : []
                            boundsBehavior: Flickable.StopAtBounds
                            // a new song starts at the top
                            onModelChanged: contentY = 0
                            delegate: Text {
                                required property var modelData
                                width: ListView.view.width - 12
                                height: modelData === "" ? 12 : implicitHeight
                                text: modelData
                                wrapMode: Text.Wrap
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tTitle + 1
                                lineHeight: 1.1
                            }
                        }

                        // ---- queue (read-only rows)
                        ListView {
                            id: queList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.tab === "queue" && root.queLoaded && root.que.ok
                            clip: true
                            spacing: 4
                            model: root.tab === "queue" && root.que.ok ? root.que.items : []
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Rectangle {
                                id: qrow
                                required property var modelData
                                required property int index
                                width: ListView.view.width - 8
                                height: 46
                                radius: root.pal.rSm
                                color: Qt.alpha(root.pal.surface, 0.55)
                                border.width: 1
                                border.color: root.pal.lineSoft
                                RowLayout {
                                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                    spacing: 10
                                    Text {
                                        Layout.preferredWidth: 22
                                        horizontalAlignment: Text.AlignRight
                                        text: qrow.index + 1
                                        color: Qt.alpha(root.pal.muted, 0.85)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: qrow.modelData.title
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            visible: text !== ""
                                            text: qrow.modelData.artist
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                    }
                                    Text {
                                        text: root.clock(qrow.modelData.ms)
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                    }
                                }
                            }
                        }

                        // ---- loading, or why there is nothing to show (a sibling of the lists: a ListView would scroll it)
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: (root.busy || !root.cur.ok) && !(root.tab === "lyrics" && root.aiView !== "")
                            spacing: 14
                            Item { Layout.fillHeight: true }
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                text: root.busy ? (root.tab === "lyrics" ? "Reading the lyrics ..." : "Reading the queue ...")
                                                : root.cur.message
                                color: root.busy || root.cur.state === "none" || root.cur.state === "idle" ? root.pal.muted : root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: root.busy && root.tab === "queue"
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                text: "The first read can take a few seconds when spotify_player is not already running."
                                color: Qt.alpha(root.pal.muted, 0.85)
                                font.family: root.pal.uiFont
                                font.pixelSize: 10
                            }
                            ActionChip {
                                Layout.alignment: Qt.AlignHCenter
                                visible: !root.busy && !root.cur.ok && root.cur.state !== "missing" && root.cur.state !== "old"
                                pal: root.pal
                                label: "Try again"
                                implicitHeight: 30
                                onClicked: root.reload()
                            }
                            Item { Layout.fillHeight: true }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Tab switches   \u00b7   Up / Down scroll   \u00b7   R reads again   \u00b7   Esc closes"
                            elide: Text.ElideRight
                            color: Qt.alpha(root.pal.muted, 0.85)
                            font.family: root.pal.uiFont
                            font.pixelSize: 10
                        }
                    }
                }
            }
        }
    }
}
