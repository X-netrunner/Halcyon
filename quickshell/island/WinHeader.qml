import QtQuick
import QtQuick.Layouts

// The one header the windows share, so they all read the same: what the window offers (tabs, modes, a reset) on the left,
// its title in the exact middle of the window, its actions on the right and the close ✕ always last, in the same spot.
//   WinHeader { pal: root.pal; title: "Bar builder"; leading: [ ... ]; trailing: [ ... ]; onClosed: root.closed() }
// The earlier styles keep the title on the left unless Settings > Look > Centred titles is on; the new one always centres it.
Item {
    id: hd
    property var pal
    property string title: ""
    property string sub: ""              // a short status line under the title ("3 games"), never an explanation
    property int size: 20
    property int glyph: 0                // a small mark before the title (0 = none); the builders each have one
    property bool closable: true
    property alias leading: leftRow.data       // (not "left" / "right": those names are taken on Item)
    property alias trailing: rightRow.data
    signal closed()

    readonly property bool centred: pal.zen || pal.centred
    Layout.fillWidth: true
    implicitHeight: Math.max(40, titleCol.implicitHeight, leftRow.implicitHeight, rightRow.implicitHeight)

    RowLayout {
        id: leftRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
    }

    Column {
        id: titleCol
        anchors.verticalCenter: parent.verticalCenter
        // centred on the whole window; it never runs under the buttons on either side
        readonly property real room: hd.width - 2 * Math.max(leftRow.width, rightEnd.width) - 32
        readonly property real natural: Math.max(titleRow.implicitWidth, subT.visible ? subT.implicitWidth : 0)
        width: Math.min(natural, hd.centred ? Math.max(120, room) : hd.width - leftRow.width - rightEnd.width - 48)
        x: hd.centred ? (hd.width - width) / 2 : (leftRow.width > 0 ? leftRow.width + 16 : 0)
        spacing: 2
        Row {
            id: titleRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 10
            Rectangle {
                visible: hd.glyph !== 0
                anchors.verticalCenter: parent.verticalCenter
                width: 30; height: 30; radius: 10
                color: Qt.alpha(hd.pal.accent, 0.11)
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(hd.glyph)
                    color: hd.pal.accent
                    font.family: hd.pal.font
                    font.pixelSize: 16
                }
            }
            Text {
                id: titleT
                anchors.verticalCenter: parent.verticalCenter
                // room for the title beside whatever the leading and trailing actions take; never a binding back to titleCol
                // (that loop made long names elide to "Widg…")
                width: Math.min(implicitWidth, Math.max(60, hd.width - 2 * Math.max(leftRow.width, rightEnd.width) - 48 - (hd.glyph !== 0 ? 40 : 0)))
                elide: Text.ElideRight
                text: hd.title
                color: hd.pal.text
                font.family: hd.pal.uiFont
                font.pixelSize: hd.size
                font.weight: Font.Medium
            }
        }
        Text {
            id: subT
            visible: text !== ""
            width: parent.width
            horizontalAlignment: hd.centred ? Text.AlignHCenter : Text.AlignLeft
            elide: Text.ElideRight
            text: hd.sub
            color: hd.pal.muted
            font.family: hd.pal.uiFont
            font.pixelSize: hd.pal.tCap
        }
    }

    Row {
        id: rightEnd
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 12
        RowLayout {
            id: rightRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
        }
        RoundBtn {
            visible: hd.closable
            anchors.verticalCenter: parent.verticalCenter
            pal: hd.pal
            glyph: "✕"
            size: 32
            onClicked: hd.closed()
        }
    }
}
