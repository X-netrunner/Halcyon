import QtQuick
import QtQuick.Layouts
import Quickshell

// An explanation or key-hint line ("Enter saves · Esc closes", "Drag widgets along the bar ..."). Normally it is the whole text,
// wrapped, never cut off with "...". With Settings > Look > Hide explanations (pal.hideHints) it shrinks to a small "?" on the
// side; hovering the "?" shows the text in a bubble beside it. The bubble is its own popup, so a list or a clipped box can not
// cut it off.
Item {
    id: h
    property var pal
    property string text: ""
    property color color: pal ? pal.muted : "#9496a8"
    property int pixelSize: pal ? pal.tCap : 11
    property string fontFamily: pal ? pal.uiFont : ""
    property int horizontalAlignment: Text.AlignLeft
    property bool alignRight: false         // folded: the "?" sits at the right end of the line instead of the left
    readonly property bool folded: !!(pal && pal.hideHints)
    readonly property bool gone: folded && !!pal.zen        // the new style: no "?" either, the line is simply not there (ask > explains)

    visible: text !== "" && !gone
    Layout.fillWidth: true
    implicitWidth: gone ? 0 : folded ? 16 : full.implicitWidth
    implicitHeight: gone ? 0 : folded ? 16 : full.implicitHeight

    Text {
        id: full
        visible: !h.folded
        width: h.width
        text: h.text
        color: h.color
        font.family: h.fontFamily
        font.pixelSize: h.pixelSize
        wrapMode: Text.Wrap
        horizontalAlignment: h.horizontalAlignment
        lineHeight: 1.15
    }

    Rectangle {
        id: dot
        visible: h.folded
        x: h.alignRight ? h.width - width : 0
        width: 16; height: 16; radius: 8
        color: dotHover.hovered ? Qt.alpha(h.pal.accent, 0.22) : "transparent"
        border.width: 1
        border.color: dotHover.hovered ? h.pal.accent : Qt.alpha(h.pal.muted, 0.55)
        Text {
            anchors.centerIn: parent
            text: "?"
            color: dotHover.hovered ? h.pal.accent : h.pal.muted
            font.family: h.fontFamily
            font.pixelSize: 9
            font.weight: Font.Bold
        }
        HoverHandler { id: dotHover; cursorShape: Qt.WhatsThisCursor }
    }

    // the bubble: only exists while the "?" is hovered
    LazyLoader {
        active: h.folded && !h.gone && dotHover.hovered
        PopupWindow {
            anchor.item: dot
            anchor.rect.x: dot.width + 6
            anchor.rect.y: -4
            implicitWidth: tipTxt.width + 24
            implicitHeight: tipTxt.implicitHeight + 16
            color: "transparent"
            visible: true
            Rectangle {
                anchors.fill: parent
                radius: 10
                color: h.pal.surfaceHi
                border.width: h.pal.bw
                border.color: h.pal.lineSoft
                Text {
                    id: tipTxt
                    x: 12; y: 8
                    width: Math.min(316, Math.ceil(tm.advanceWidth) + 2)
                    text: h.text
                    color: h.pal.text
                    font.family: h.fontFamily
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                TextMetrics { id: tm; font: tipTxt.font; text: h.text }
            }
        }
    }
}
