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

    // Round chevron button. Defined here (not in its own file) so the header loads even when only some of the island's files were copied.
    component DropArrow: Rectangle {
        id: arrow
        property var pal
        property string glyph: ""
        property bool live: true            // false: there is no page in that direction
        signal clicked()
        readonly property bool lit: live && hv.hovered

        width: 34
        height: 34
        radius: 17
        color: lit ? Qt.alpha(pal.accent, 0.20) : Qt.alpha(pal.text, 0.05)
        border.width: 1
        border.color: lit ? Qt.alpha(pal.accent, 0.45) : pal.line
        opacity: live ? 1 : 0.28
        scale: (live && tap.pressed) ? 0.9 : 1
        Behavior on opacity { NumberAnimation { duration: arrow.pal.dMed } }
        Behavior on color { ColorAnimation { duration: arrow.pal.dFast } }
        Behavior on border.color { ColorAnimation { duration: arrow.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: arrow.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: arrow.pal.curve } }

        Text {
            anchors.centerIn: parent
            text: arrow.glyph
            color: arrow.lit ? arrow.pal.accent : arrow.pal.text
            font.family: arrow.pal.font
            font.pixelSize: 18
            Behavior on color { ColorAnimation { duration: arrow.pal.dFast } }
        }
        HoverHandler { id: hv; cursorShape: arrow.live ? Qt.PointingHandCursor : Qt.ArrowCursor }
        TapHandler { id: tap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: if (arrow.live) arrow.clicked() }
    }

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
        border.width: root.pal.calm ? 0 : 1
        border.color: root.pal.line

        // the sliding highlight
        Rectangle {
            x: root.inset + Math.max(0, Math.min(1, root.pos)) * root.tabW
            y: root.inset
            width: root.tabW
            height: pill.height - root.inset * 2
            radius: height / 2
            border.width: root.pal.bw
            border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.42)
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
                    Badge {
                        visible: tab.index === 1 && root.unread > 0
                        anchors.verticalCenter: parent.verticalCenter
                        pal: root.pal
                        count: root.unread
                        size: 18
                    }
                }
                TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.pick(tab.index) }
            }
        }
    }
}
