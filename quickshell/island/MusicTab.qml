import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris

// The Music tab of the rail dashboard (Caelestia's Media.qml): the cover with the visualiser round it on the left; on the right the track,
// the progress, the controls, the synced lyrics and the player selector.
// Keeps what MediaPage.qml (the island's page) does: the seek bar, previous / play / next, and the Lyrics / Queue chips that open the lyrics and
// queue panel (`openMusic`). New: the lyrics are read here too, and when more than one player is running you can pick which one this shows.
Item {
    id: root
    property var pal
    property var player: null                // shell.qml's choice (the one that plays, else the first)
    property var cava: []
    property bool active: false              // the tab is on screen
    signal openMusic(string tab)

    // the player picked in the selector (null = shell.qml's choice); forgotten when that player goes away
    property var picked: null
    readonly property var list: Mpris.players.values
    readonly property var cur: {
        if (picked) { for (var i = 0; i < list.length; i++) if (list[i] === picked) return picked }
        return player
    }
    readonly property bool has: cur !== null && cur !== undefined
    readonly property real frac: (has && cur.length > 0) ? Math.min(1, cur.position / cur.length) : 0

    readonly property string icoPlay: String.fromCodePoint(0xF040A)
    readonly property string icoPause: String.fromCodePoint(0xF03E4)
    readonly property string icoNext: String.fromCodePoint(0xF04AD)
    readonly property string icoPrev: String.fromCodePoint(0xF04AE)

    implicitWidth: 704
    implicitHeight: 296

    function fmt(s) {
        if (!isFinite(s) || s < 0) return "0:00"
        var m = Math.floor(s / 60), r = Math.floor(s % 60)
        return m + ":" + (r < 10 ? "0" : "") + r
    }
    Timer {
        interval: 500
        repeat: true
        running: root.has && root.cur.isPlaying && root.active
        onTriggered: root.cur.positionChanged()
    }

    RowLayout {
        anchors.fill: parent
        spacing: 22

        MusicCover {
            Layout.preferredWidth: 232
            Layout.preferredHeight: 232
            Layout.alignment: Qt.AlignVCenter
            pal: root.pal
            player: root.cur
            values: root.cava
            active: root.active && root.has && root.cur.isPlaying
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6

            // nothing is playing
            Item {
                visible: !root.has
                Layout.fillWidth: true
                Layout.fillHeight: true
                Column {
                    anchors.centerIn: parent
                    spacing: 4
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Nothing playing"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Play something and it shows up here"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                }
            }

            // the track
            ScrollText {                 // hover: a long song title slides by
                visible: root.has
                Layout.fillWidth: true
                Layout.topMargin: 6
                Text {
                    text: root.has ? (root.cur.trackTitle || "Unknown") : ""
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 22
                    font.weight: Font.DemiBold
                }
            }
            Text {
                visible: root.has
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.has ? ((root.cur.trackArtist || "") + ((root.cur.trackAlbum || "") !== "" && (root.cur.trackArtist || "") !== "" ? "  ·  " : "") + (root.cur.trackAlbum || "")) : ""
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody + 1
            }

            // progress
            Item {
                visible: root.has
                Layout.fillWidth: true
                Layout.preferredHeight: 18
                Layout.topMargin: 6
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 5
                    radius: 2.5
                    color: root.pal.surface
                    Rectangle {
                        width: parent.width * root.frac
                        height: parent.height
                        radius: 2.5
                        color: root.pal.accent
                        Behavior on width { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: root.has && root.cur.canSeek && root.cur.lengthSupported
                    onClicked: m => root.cur.position = (m.x / width) * root.cur.length
                }
            }
            RowLayout {
                visible: root.has
                Layout.fillWidth: true
                spacing: 4
                Text { text: root.has ? root.fmt(root.cur.position) : ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                Item { Layout.fillWidth: true }
                RoundBtn { pal: root.pal; size: 34; glyph: root.icoPrev; enabledBtn: root.has && root.cur.canGoPrevious; onClicked: root.cur.previous() }
                RoundBtn { pal: root.pal; size: 44; primary: true; glyph: root.has && root.cur.isPlaying ? root.icoPause : root.icoPlay; enabledBtn: root.has && root.cur.canTogglePlaying; onClicked: root.cur.togglePlaying() }
                RoundBtn { pal: root.pal; size: 34; glyph: root.icoNext; enabledBtn: root.has && root.cur.canGoNext; onClicked: root.cur.next() }
                Item { Layout.fillWidth: true }
                Text { text: root.has ? root.fmt(root.cur.length) : ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
            }

            // the lyrics (synced when halcyon-music.py finds time stamps)
            MusicLyrics {
                visible: root.has
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 60
                pal: root.pal
                player: root.cur
                active: root.active
                onOpenFull: root.openMusic("lyrics")
            }

            // the player selector + the panel chips
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: root.list.length > 1 ? root.list : []
                    delegate: ActionChip {
                        required property var modelData
                        pal: root.pal
                        label: modelData.identity || "Player"
                        maxLabel: 120
                        implicitHeight: 28
                        on: modelData === root.cur
                        onClicked: root.picked = modelData
                    }
                }
                Item { Layout.fillWidth: true }
                ActionChip { visible: root.has; pal: root.pal; label: "Lyrics"; implicitHeight: 28; onClicked: root.openMusic("lyrics") }
                ActionChip { visible: root.has; pal: root.pal; label: "Queue"; implicitHeight: 28; onClicked: root.openMusic("queue") }
            }
        }
    }
}
