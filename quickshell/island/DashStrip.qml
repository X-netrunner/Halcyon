import QtQuick

// The stat strip under the calendar page of the Tabs dashboard style (Dashboard.qml, Settings > Bar > Dashboard stat strip):
// CPU, memory, GPU and temperature as four small cards, and what is playing (a click pauses / plays) in the rest of the row.
Item {
    id: root
    property var pal
    property var player: null
    property var stats: ({})
    property var gpu: ({ gpu: 0, state: "none" })
    readonly property bool has: player !== null && player !== undefined
    readonly property real chipW: 84
    readonly property real gapW: 8
    function pct(v) { return Math.round(Number(v) || 0) + "%" }
    readonly property var items: [
        { k: "CPU", v: pct(stats.cpu) },
        { k: "RAM", v: (stats.memGb || "0.0") + " GB" },
        { k: "GPU", v: (gpu && gpu.state !== "none") ? pct(gpu.gpu) : "n/a" },
        { k: "Temp", v: Number(stats.temp) > 0 ? Math.round(Number(stats.temp)) + " °C" : "n/a" }
    ]
    implicitHeight: 56

    Repeater {
        model: root.items
        delegate: DashCard {
            required property var modelData
            required property int index
            pal: root.pal
            x: index * (root.chipW + root.gapW)
            width: root.chipW
            height: root.height
            Column {
                anchors.centerIn: parent
                spacing: 1
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.v
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody + 2
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.k
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
            }
        }
    }
    DashCard {
        pal: root.pal
        x: 4 * (root.chipW + root.gapW)
        width: root.width - x
        height: root.height
        DashBtn {
            id: pp
            pal: root.pal
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 36; height: 36
            glyph: String.fromCodePoint(root.has && root.player.isPlaying ? 0xF03E4 : 0xF040A)
            on: root.has && root.player.isPlaying
            onClicked: { if (root.has && root.player.canTogglePlaying) root.player.togglePlaying() }
        }
        Column {
            x: pp.x + pp.width + 10
            width: parent.width - x - 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.has ? (root.player.trackTitle || "Unknown track") : "Nothing playing"
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.has ? (root.player.trackArtist || "") : "Now playing"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
    }
}
