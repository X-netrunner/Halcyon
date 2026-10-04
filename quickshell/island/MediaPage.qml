import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets

Item {
    id: root
    property var pal
    property var player: null
    readonly property bool has: player !== null && player !== undefined
    readonly property real frac: (has && player.length > 0) ? Math.min(1, player.position / player.length) : 0

    readonly property string icoPlay: String.fromCodePoint(0xF040A)
    readonly property string icoPause: String.fromCodePoint(0xF03E4)
    readonly property string icoNext: String.fromCodePoint(0xF04AD)
    readonly property string icoPrev: String.fromCodePoint(0xF04AE)

    function fmt(s) {
        if (!isFinite(s) || s < 0) return "0:00"
        var m = Math.floor(s / 60), r = Math.floor(s % 60)
        return m + ":" + (r < 10 ? "0" : "") + r
    }

    Timer {
        interval: 500
        repeat: true
        running: root.has && root.player.isPlaying && root.visible
        onTriggered: root.player.positionChanged()
    }

    Text {
        anchors.centerIn: parent
        visible: !root.has
        text: "Nothing playing"
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tTitle
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 22
        anchors.leftMargin: 30
        anchors.rightMargin: 30
        spacing: 22
        visible: root.has

        ClippingRectangle {
            Layout.preferredWidth: 104
            Layout.preferredHeight: 104
            Layout.alignment: Qt.AlignVCenter
            radius: 20
            color: root.pal.surface
            Image {
                anchors.fill: parent
                source: root.has ? root.player.trackArtUrl : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: root.has ? (root.player.trackTitle || "Unknown") : ""
                elide: Text.ElideRight
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: 17
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                text: root.has ? (root.player.trackArtist || "") : ""
                elide: Text.ElideRight
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 18
                Layout.topMargin: 8
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
                    enabled: root.has && root.player.canSeek && root.player.lengthSupported
                    onClicked: m => root.player.position = (m.x / width) * root.player.length
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    text: root.has ? root.fmt(root.player.position) : ""
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
                Item { Layout.fillWidth: true }
                RoundBtn {
                    pal: root.pal; size: 30; glyph: root.icoPrev
                    enabledBtn: root.has && root.player.canGoPrevious
                    onClicked: root.player.previous()
                }
                RoundBtn {
                    pal: root.pal; size: 40; primary: true
                    glyph: root.has && root.player.isPlaying ? root.icoPause : root.icoPlay
                    enabledBtn: root.has && root.player.canTogglePlaying
                    onClicked: root.player.togglePlaying()
                }
                RoundBtn {
                    pal: root.pal; size: 30; glyph: root.icoNext
                    enabledBtn: root.has && root.player.canGoNext
                    onClicked: root.player.next()
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: root.has ? root.fmt(root.player.length) : ""
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
            }
        }
    }
}
