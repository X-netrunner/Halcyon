import QtQuick
import Quickshell.Widgets

// "Now playing": the song, the cover, the buttons and the progress of whatever plays (any MPRIS player: spotify-player, a browser ...).
//   card | compact | cover | minimal
WBase {
    id: root

    readonly property var pl: env ? env.player : null
    readonly property bool has: pl !== null && pl !== undefined
    readonly property bool playing: has && pl.isPlaying
    readonly property real frac: (has && pl.length > 0) ? Math.min(1, pl.position / pl.length) : 0
    readonly property bool showBtn: opt("controls", true) === true
    readonly property bool showBar: opt("progress", true) === true
    readonly property real wide: opt("width", 320)
    hidden: !has && opt("hideIdle", false) === true

    readonly property string icoPlay: glyph(0xF040A)
    readonly property string icoPause: glyph(0xF03E4)
    readonly property string icoNext: glyph(0xF04AD)
    readonly property string icoPrev: glyph(0xF04AE)

    Timer { interval: 500; repeat: true; running: root.playing && root.live && (root.showBar || root.style === "cover"); onTriggered: root.pl.positionChanged() }

    implicitWidth: body.item ? body.item.implicitWidth : 200
    implicitHeight: body.item ? body.item.implicitHeight : 60
    Loader {
        id: body
        sourceComponent: root.style === "compact" ? compactC : (root.style === "cover" ? coverC : (root.style === "minimal" ? minimalC : cardC))
    }

    // the three round buttons (previous, play / pause, next)
    Component {
        id: btnRow
        Row {
            spacing: root.sz(6)
            Repeater {
                model: [0, 1, 2]
                delegate: Rectangle {
                    required property int modelData
                    readonly property bool mid: modelData === 1
                    width: root.sz(mid ? 40 : 32); height: width; radius: width / 2
                    color: mid ? root.accent : (bm.containsMouse ? root.track : "transparent")
                    opacity: root.has ? 1 : 0.35
                    scale: bm.pressed ? 0.93 : 1
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    WIco {
                        b: root
                        anchors.centerIn: parent
                        text: parent.modelData === 0 ? root.icoPrev : (parent.modelData === 1 ? (root.playing ? root.icoPause : root.icoPlay) : root.icoNext)
                        color: parent.mid ? (root.pal ? root.pal.bg : "black") : root.fg
                        font.pixelSize: root.sz(parent.mid ? 20 : 17)
                    }
                    MouseArea {
                        id: bm
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: root.has && !root.editing
                        onClicked: { if (modelData === 0) root.pl.previous(); else if (modelData === 1) root.pl.togglePlaying(); else root.pl.next() }
                    }
                }
            }
        }
    }
    Component {
        id: progressC
        Item {
            implicitWidth: 10; implicitHeight: root.sz(14)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: root.sz(4); radius: height / 2; color: root.track
                Rectangle { width: parent.width * root.frac; height: parent.height; radius: height / 2; color: root.accent
                    Behavior on width { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } } }
            }
            MouseArea {
                anchors.fill: parent
                enabled: root.has && root.pl.canSeek && root.pl.lengthSupported && !root.editing
                onClicked: m => root.pl.position = (m.x / width) * root.pl.length
            }
        }
    }

    // ---- card: cover on the left, text, progress, buttons
    Component {
        id: cardC
        Row {
            spacing: root.sz(16)
            ClippingRectangle {
                width: root.sz(96); height: width; radius: root.sz(16)
                color: root.track
                anchors.verticalCenter: parent.verticalCenter
                Image { anchors.fill: parent; source: root.has ? root.pl.trackArtUrl : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize: Qt.size(192, 192) }
                WIco { b: root; anchors.centerIn: parent; visible: !root.has || root.pl.trackArtUrl === ""; text: root.glyph(0xF075A); color: root.dim; font.pixelSize: root.sz(34) }
            }
            Column {
                width: root.wide - root.sz(96) - root.sz(16)
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.sz(2)
                WLbl { b: root; width: parent.width; text: root.has ? (root.pl.trackTitle || "Unknown") : "Nothing playing"; elide: Text.ElideRight; font.pixelSize: root.sz(17); font.weight: Font.DemiBold }
                WLbl { b: root; width: parent.width; text: root.has ? (root.pl.trackArtist || "") : "Start some music"; elide: Text.ElideRight; color: root.dim; font.pixelSize: root.sz(13) }
                Loader { visible: root.showBar; width: parent.width; sourceComponent: progressC }
                Loader { visible: root.showBtn; sourceComponent: btnRow }
            }
        }
    }
    // ---- compact: a small cover, the title, one play button
    Component {
        id: compactC
        Row {
            spacing: root.sz(12)
            ClippingRectangle {
                width: root.sz(46); height: width; radius: root.sz(12); color: root.track
                anchors.verticalCenter: parent.verticalCenter
                Image { anchors.fill: parent; source: root.has ? root.pl.trackArtUrl : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize: Qt.size(96, 96) }
            }
            Column {
                width: root.wide - root.sz(46) - root.sz(12) - (root.showBtn ? root.sz(52) : 0)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                WLbl { b: root; width: parent.width; text: root.has ? (root.pl.trackTitle || "Unknown") : "Nothing playing"; elide: Text.ElideRight; font.pixelSize: root.sz(14); font.weight: Font.DemiBold }
                WLbl { b: root; width: parent.width; text: root.has ? (root.pl.trackArtist || "") : ""; elide: Text.ElideRight; color: root.dim; font.pixelSize: root.sz(12) }
            }
            Rectangle {
                visible: root.showBtn
                width: root.sz(40); height: width; radius: width / 2; color: root.accent; anchors.verticalCenter: parent.verticalCenter
                opacity: root.has ? 1 : 0.35
                WIco { b: root; anchors.centerIn: parent; text: root.playing ? root.icoPause : root.icoPlay; color: root.pal ? root.pal.bg : "black"; font.pixelSize: root.sz(20) }
                MouseArea { anchors.fill: parent; enabled: root.has && !root.editing; onClicked: root.pl.togglePlaying() }
            }
        }
    }
    // ---- cover: the big picture with the title on it
    Component {
        id: coverC
        ClippingRectangle {
            width: root.sz(190); height: width; radius: root.sz(20); color: root.track
            Image { anchors.fill: parent; source: root.has ? root.pl.trackArtUrl : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize: Qt.size(380, 380) }
            WIco { b: root; anchors.centerIn: parent; visible: !root.has || root.pl.trackArtUrl === ""; text: root.glyph(0xF075A); color: root.dim; font.pixelSize: root.sz(60) }
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: root.sz(76)
                gradient: Gradient { GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.72) } }
            }
            Column {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: root.sz(12)
                spacing: 0
                WLbl { b: root; width: parent.width; text: root.has ? (root.pl.trackTitle || "Unknown") : "Nothing playing"; elide: Text.ElideRight; color: "white"; font.pixelSize: root.sz(15); font.weight: Font.DemiBold }
                WLbl { b: root; width: parent.width; text: root.has ? (root.pl.trackArtist || "") : ""; elide: Text.ElideRight; color: Qt.rgba(1, 1, 1, 0.75); font.pixelSize: root.sz(12) }
            }
            Rectangle { anchors.left: parent.left; anchors.bottom: parent.bottom; height: 3; width: parent.width * root.frac; color: root.accent; visible: root.showBar }
            MouseArea { anchors.fill: parent; enabled: root.has && root.showBtn && !root.editing; onClicked: root.pl.togglePlaying() }
        }
    }
    // ---- minimal: one line of text
    Component {
        id: minimalC
        Row {
            spacing: root.sz(10)
            WIco { b: root; text: root.glyph(0xF075A); color: root.playing ? root.accent : root.dim; font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; width: Math.min(root.wide, implicitWidth); text: root.has ? ((root.pl.trackTitle || "Unknown") + (root.pl.trackArtist ? "  ·  " + root.pl.trackArtist : "")) : "Nothing playing"
                   elide: Text.ElideRight; font.pixelSize: root.sz(15); anchors.verticalCenter: parent.verticalCenter }
        }
    }
}
