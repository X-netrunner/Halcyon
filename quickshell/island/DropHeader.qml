import QtQuick

// Header of the bar's drop-down in "Swipe pages" mode (Settings > Bar > Drag the bar down):
//
//     (‹)   [ Utilities | Notifications ]   (›)
//
// The highlight inside the pill follows `pos`, so it travels with your finger while you swipe the page.
// The arrows and the two tabs do the same as a swipe.
Item {
    id: root
    property var pal
    property real pos: 0                // 0 = utilities ... 1 = notifications (fractions while swiping)
    property int unread: 0
    property bool dnd: false
    signal step(int dir)                // the arrows: -1 / +1
    signal pick(int index)              // a tab was tapped

    readonly property int btn: 34
    readonly property int inset: 4
    readonly property real pillW: width - (btn + 10) * 2
    readonly property real tabW: (pillW - inset * 2) / 2
    readonly property var tabs: [
        { label: "Utilities", glyph: String.fromCodePoint(0xF062E) },
        { label: "Notifications", glyph: String.fromCodePoint(0xF009A) }
    ]

    height: 44

    DropArrow {
        pal: root.pal
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        glyph: String.fromCodePoint(0xF0141)
        live: root.pos > 0.5
        onClicked: root.step(-1)
    }
    DropArrow {
        pal: root.pal
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        glyph: String.fromCodePoint(0xF0142)
        live: root.pos < 0.5
        onClicked: root.step(1)
    }

    Rectangle {
        id: pill
        anchors.centerIn: parent
        width: root.pillW
        height: 38
        radius: height / 2
        color: Qt.alpha(root.pal.text, 0.05)
        border.width: 1
        border.color: root.pal.line

        // the sliding highlight
        Rectangle {
            x: root.inset + Math.max(0, Math.min(1, root.pos)) * root.tabW
            y: root.inset
            width: root.tabW
            height: pill.height - root.inset * 2
            radius: height / 2
            border.width: 1
            border.color: Qt.alpha(root.pal.accent, 0.42)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.alpha(root.pal.accent, 0.28) }
                GradientStop { position: 1.0; color: Qt.alpha(root.pal.accent2, 0.20) }
            }
        }

        Repeater {
            model: root.tabs
            delegate: Item {
                id: tab
                required property int index
                required property var modelData
                // 1 while this tab is the current one, fading to 0 as the page slides away
                readonly property real act: Math.max(0, 1 - Math.abs(root.pos - index))
                readonly property color ink: Qt.tint(root.pal.muted, Qt.alpha(root.pal.accent, act))

                x: root.inset + index * root.tabW
                y: root.inset
                width: root.tabW
                height: pill.height - root.inset * 2

                Row {
                    anchors.centerIn: parent
                    spacing: 7

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        // the bell shows "off" while Do not disturb is on
                        text: (tab.index === 1 && root.dnd) ? String.fromCodePoint(0xF009B) : tab.modelData.glyph
                        color: tab.ink
                        font.family: root.pal.font
                        font.pixelSize: 15
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.modelData.label
                        color: tab.ink
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody
                        font.weight: tab.act > 0.5 ? Font.DemiBold : Font.Medium
                    }
                    // unread count
                    Rectangle {
                        visible: tab.index === 1 && root.unread > 0
                        anchors.verticalCenter: parent.verticalCenter
                        height: 16
                        width: Math.max(16, badge.implicitWidth + 10)
                        radius: 8
                        color: root.pal.accent
                        Text {
                            id: badge
                            anchors.centerIn: parent
                            text: root.unread > 9 ? "9+" : root.unread
                            color: root.pal.bg
                            font.family: root.pal.uiFont
                            font.pixelSize: 10
                            font.weight: Font.Bold
                        }
                    }
                }
                TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.pick(tab.index) }
            }
        }
    }
}
