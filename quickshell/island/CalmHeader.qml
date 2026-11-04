import QtQuick

// The head of every calm centre: one glyph, the name, one short line under it, all three in the middle of the window.
// Actions (icon buttons) go in from the right and never move the middle, so the title stays exactly centred.
//
//   CalmHeader { pal: ...; glyph: 0x...; title: "Game Center"; sub: "8 games"
//       CalmIconBtn { ... }        // the default property is the actions row
//   }
Item {
    id: h
    property var pal
    property int glyph: 0
    property string title: ""
    property string sub: ""
    property string subTone: "muted"          // muted | accent | warn | bad | good
    property bool badge: true
    property int titleSize: 21
    default property alias actions: actRow.data

    implicitWidth: parent ? parent.width : 0
    implicitHeight: Math.max(56, col.implicitHeight, actRow.implicitHeight)

    Column {
        id: col
        anchors.centerIn: parent
        width: Math.min(parent.width - 180, Math.max(titleTxt.implicitWidth, subTxt.implicitWidth))
        spacing: 2

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12
            Rectangle {
                visible: h.badge
                anchors.verticalCenter: parent.verticalCenter
                width: 40; height: 40; radius: 14
                color: Qt.alpha(h.pal.accent, 0.11)
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(h.glyph)
                    color: h.pal.accent
                    font.family: h.pal.font
                    font.pixelSize: 21
                }
            }
            Text {
                id: titleTxt
                anchors.verticalCenter: parent.verticalCenter
                text: h.title
                color: h.pal.text
                font.family: h.pal.uiFont
                font.pixelSize: h.titleSize
                font.weight: Font.Medium
                font.letterSpacing: -0.2
            }
        }
        Text {
            id: subTxt
            width: parent.width
            visible: text !== ""
            horizontalAlignment: Text.AlignHCenter
            text: h.sub
            color: h.subTone === "accent" ? h.pal.accent : h.subTone === "warn" ? h.pal.warn : h.subTone === "bad" ? h.pal.bad
                 : h.subTone === "good" ? h.pal.good : h.pal.muted
            font.family: h.pal.uiFont
            font.pixelSize: h.pal.tCap
            font.weight: Font.Medium
            topPadding: 5
            elide: Text.ElideRight
        }
    }

    Row {
        id: actRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
    }
}
