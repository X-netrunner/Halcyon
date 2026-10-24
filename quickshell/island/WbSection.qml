import QtQuick
import QtQuick.Layouts

// One calm card in the Widget builder's right column: a small title, an optional line under it, then its rows.
// Put the rows straight inside it (they land in a ColumnLayout, so Layout.fillWidth works on them).
Rectangle {
    id: sec
    property var pal
    property string title: ""
    property string sub: ""
    default property alias rows: body.data
    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + 32
    radius: pal ? pal.rLg : 16
    color: !pal ? "transparent" : (pal.zen ? pal.group : pal.calm ? pal.fill : Qt.alpha(pal.surface, 0.35))
    border.width: pal && pal.calm ? 0 : 1
    border.color: pal ? Qt.alpha(pal.lineSoft, 0.6) : "transparent"

    ColumnLayout {
        id: col
        x: 16; y: 16
        width: sec.width - 32
        spacing: 12
        Column {
            Layout.fillWidth: true
            visible: sec.title !== ""
            spacing: 3
            Text { text: sec.title; color: sec.pal.text; font.family: sec.pal.uiFont; font.pixelSize: sec.pal.tBody + 1; font.weight: Font.DemiBold }
            Text { visible: sec.sub !== "" && !(sec.pal.zen && sec.pal.hideHints); width: parent.width; text: sec.sub; color: sec.pal.muted; font.family: sec.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.2 }
        }
        ColumnLayout {
            id: body
            Layout.fillWidth: true
            spacing: 12
        }
    }
}
