import QtQuick
import QtQuick.Layouts
import "WidgetData.js" as WD

// Settings > Appearance > Widget builder: a line about the desktop widgets and the buttons that open the builders.
// (WidgetBuilderWindow.qml: one widget at a time, its style and look.  DesktopEditor.qml: drag them where you want them.)
ColumnLayout {
    id: wb
    property var pal
    property var opt: ({})
    signal openRequested()
    signal placeRequested()
    signal clearRequested()

    width: parent ? parent.width : 0
    spacing: 10

    readonly property var layout: WD.normalize(opt ? opt.deskWidgets : null)
    readonly property string names: {
        var n = [], a = layout.items
        for (var i = 0; i < a.length && i < 8; i++) n.push(WD.nameOf(a[i].type))
        return n.join(", ") + (a.length > 8 ? " and " + (a.length - 8) + " more" : "")
    }

    Text {
        Layout.fillWidth: true
        text: "Put widgets on your desktop: the time, system usage, the song that plays, an audio visualizer, your Focus streak, battery, Wi-Fi, workspaces, quick toggles, notes and more. Each one has several layouts and a look you can change (box, colours, font, size), and you can save looks of your own. With enough of them on the desktop you can switch the top bar off (Settings > Bar style > Style > Off)."
        color: wb.pal.muted; font.family: wb.pal.uiFont; font.pixelSize: 10; lineHeight: 1.3; wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        text: wb.layout.items.length === 0 ? "No widgets yet." : (wb.layout.items.length + (wb.layout.items.length === 1 ? " widget: " : " widgets: ") + wb.names)
        color: wb.pal.text; font.family: wb.pal.uiFont; font.pixelSize: wb.pal.tCap; lineHeight: 1.3; wrapMode: Text.WordWrap
    }
    Flow {
        Layout.fillWidth: true
        spacing: 8
        ActionChip { pal: wb.pal; label: "Open the widget builder"; on: true; onClicked: wb.openRequested() }
        ActionChip { pal: wb.pal; label: "Place them on the desktop"; onClicked: wb.placeRequested() }
        ActionChip { pal: wb.pal; label: "Remove all"; doneLabel: "Removed"; disabled: wb.layout.items.length === 0; onClicked: wb.clearRequested() }
    }
}
