import QtQuick

// Round count badge: a filled circle (stretches to a pill for "9+"), a thin ring so it separates from whatever is behind it,
// and a small pop when the number changes. soft: tinted glass look for headers instead of a solid fill.
Item {
    id: root
    required property var pal
    property int count: 0
    property int cap: 9
    property int size: 18
    property color tint: pal.accent
    property color ink: pal.bg
    property bool soft: false
    readonly property string label: count > cap ? cap + "+" : String(count)

    visible: count > 0
    implicitHeight: size
    implicitWidth: Math.max(size, num.implicitWidth + Math.round(size * 0.6))
    width: implicitWidth
    height: implicitHeight
    Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.soft ? Qt.alpha(root.tint, 0.2) : root.tint
        border.width: 1
        border.color: root.soft ? Qt.alpha(root.tint, 0.55) : Qt.alpha(root.ink, 0.28)
    }
    Text {
        id: num
        anchors.centerIn: parent
        text: root.label
        color: root.soft ? root.tint : root.ink
        font.family: root.pal.uiFont
        font.pixelSize: Math.max(9, Math.round(root.size * 0.56))
        font.weight: Font.Bold
    }
    onCountChanged: if (count > 0) pop.restart()
    SequentialAnimation {
        id: pop
        NumberAnimation { target: root; property: "scale"; to: 1.22; duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "scale"; to: 1.0; duration: 160; easing.type: Easing.OutBack }
    }
}
