import QtQuick
import QtQuick.Layouts
import "WidgetData.js" as WD

// Settings > Appearance > Widget builder: a line about the desktop widgets and the buttons that open the builders.
// (WidgetBuilderWindow.qml: one widget at a time, its style and look.  DesktopEditor.qml: drag them where you want them.)
ColumnLayout {
    id: wb
    property var pal
    property var opt: ({})
    property string target: "desktop"          // which screen's widgets this page is about: "desktop" or "lock"
    readonly property bool lockT: target === "lock"
    signal openRequested(string which)         // which = "desktop" or "lock"
    signal placeRequested(string which)
    signal clearRequested(string which)

    width: parent ? parent.width : 0
    spacing: 10

    readonly property var layout: WD.normalizeFor(opt ? opt[WD.keyOf(target)] : null, target)
    readonly property string names: {
        var n = [], a = layout.items
        for (var i = 0; i < a.length && i < 8; i++) n.push(WD.nameOf(a[i].type))
        return n.join(", ") + (a.length > 8 ? " and " + (a.length - 8) + " more" : "")
    }

    SegSwitch {
        Layout.alignment: Qt.AlignLeft
        pal: wb.pal
        options: [{ k: "desktop", t: "Desktop" }, { k: "lock", t: "Lock screen" }]
        current: wb.target
        onPicked: k => wb.target = k
    }
    Text {
        Layout.fillWidth: true
        text: wb.lockT ? "Put widgets on the lock screen too: the time in a style of your own, the song that plays, system usage, battery, Wi-Fi, weather, the moon and more. They only show things: nothing on the lock screen can be clicked while it is locked (the music buttons stay), and the widgets that run commands or show private things (toggles, shortcuts, console, notes, utilities, workspaces) are not offered there. You build and place them the same way as the desktop ones, and your saved looks work on both."
              : "Put widgets on your desktop: the time, system usage, the song that plays, an audio visualizer, your Focus streak, battery, Wi-Fi, workspaces, quick toggles, notes and more. Each one has several layouts and a look you can change (box, colours, font, size), and you can save looks of your own. With enough of them on the desktop you can switch the top bar off (Settings > Bar style > Style > Off)."
        color: wb.pal.muted; font.family: wb.pal.uiFont; font.pixelSize: 10; lineHeight: 1.3; wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        text: wb.layout.items.length === 0 ? (wb.lockT ? "No widgets on the lock screen yet." : "No widgets yet.") : (wb.layout.items.length + (wb.layout.items.length === 1 ? " widget: " : " widgets: ") + wb.names)
        color: wb.pal.text; font.family: wb.pal.uiFont; font.pixelSize: wb.pal.tCap; lineHeight: 1.3; wrapMode: Text.WordWrap
    }
    Flow {
        Layout.fillWidth: true
        spacing: 8
        ActionChip { pal: wb.pal; label: "Open the widget builder"; on: true; onClicked: wb.openRequested(wb.target) }
        ActionChip { pal: wb.pal; label: wb.lockT ? "Place them on the lock screen" : "Place them on the desktop"; onClicked: wb.placeRequested(wb.target) }
        ActionChip { pal: wb.pal; label: "Remove all"; doneLabel: "Removed"; disabled: wb.layout.items.length === 0; onClicked: wb.clearRequested(wb.target) }
    }
}
