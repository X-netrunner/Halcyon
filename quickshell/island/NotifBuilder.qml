import QtQuick
import QtQuick.Layouts
import "NotifLayout.js" as NL

// Settings > Panels & notifications > Notification box builder: a line about what the box is now and the button that opens the
// builder window (NotifBuilderWindow.qml: a live copy of the box, with every part, the constellations, the spacing and the place
// on the screen under your hands).
ColumnLayout {
    id: nb
    property var pal
    property var layout: null                  // opt.notifLayout
    signal openRequested()
    signal resetRequested()

    width: parent ? parent.width : 0
    spacing: 10

    Text {
        Layout.fillWidth: true
        text: "Parts, order, stars, size and position of the notification box, with a live preview."
        color: nb.pal.muted
        font.family: nb.pal.uiFont
        font.pixelSize: 10
        lineHeight: 1.3
        wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        text: NL.summary(nb.layout)
        color: nb.pal.text
        font.family: nb.pal.uiFont
        font.pixelSize: nb.pal.tCap
        wrapMode: Text.WordWrap
    }
    RowLayout {
        spacing: 8
        ActionChip { pal: nb.pal; label: "Open the notification box builder"; on: true; onClicked: nb.openRequested() }
        ActionChip { pal: nb.pal; label: "Reset the box"; doneLabel: "Reset"; disabled: NL.isDefault(nb.layout); onClicked: nb.resetRequested() }
    }
}
