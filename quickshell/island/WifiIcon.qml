import QtQuick

// The Wi-Fi icon, in three looks (Settings > Bar style > Wi-Fi look), shared by the island and the notch:
//   symbol: the classic Wi-Fi glyph   bars: four rounded bars that rise   dots: four dots that climb
// A cable shows a plug glyph whatever the look. Bars / dots light up with the signal strength (net.signal, 0..100).
Item {
    id: root
    property var pal
    property var net: ({})
    property string look: "symbol"        // symbol | bars | dots
    property color tint: pal.accent       // colour when connected (lit parts)
    property color offTint: Qt.alpha(pal.muted, 0.5)
    property int size: 14                 // height of the icon in px

    readonly property bool wired: net.eth === true
    readonly property bool up: net.wifi === "on" && (net.ssid || "") !== ""
    readonly property real sig: Number(net.signal || 0)
    // connected but no strength reading (0 / missing): all lit rather than one bar
    readonly property int lit: !up ? 0 : (sig <= 0 ? 4 : (sig >= 75 ? 4 : (sig >= 50 ? 3 : (sig >= 25 ? 2 : 1))))
    readonly property bool glyphMode: wired || look === "symbol"
    readonly property int bw: Math.max(3, Math.round(size * 0.22))
    readonly property int gap: Math.max(2, Math.round(size * 0.14))
    readonly property int dot: Math.max(3, Math.round(size * 0.3))

    implicitWidth: glyphMode ? glyph.implicitWidth : (look === "bars" ? 4 * bw + 3 * gap : 4 * dot + 3 * gap)
    implicitHeight: size

    Text {
        id: glyph
        visible: root.glyphMode
        anchors.centerIn: parent
        text: String.fromCodePoint(root.wired ? 0xF0200 : 0xF0928)
        color: (root.up || root.wired) ? root.tint : root.offTint
        font.family: root.pal.font
        font.pixelSize: root.size
    }
    Repeater {
        model: (!root.glyphMode && root.look === "bars") ? 4 : 0
        delegate: Rectangle {
            required property int index
            x: index * (root.bw + root.gap)
            width: root.bw
            height: Math.round(root.size * (0.4 + 0.2 * index))
            y: root.size - height
            radius: width / 2
            antialiasing: true
            color: index < root.lit ? root.tint : Qt.alpha(root.tint, 0.28)
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }
    Repeater {
        model: (!root.glyphMode && root.look === "dots") ? 4 : 0
        delegate: Rectangle {
            required property int index
            x: index * (root.dot + root.gap)
            width: root.dot
            height: root.dot
            y: root.size - root.dot - index * Math.round((root.size - root.dot) / 3)
            radius: width / 2
            antialiasing: true
            color: index < root.lit ? root.tint : Qt.alpha(root.tint, 0.28)
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }
}
