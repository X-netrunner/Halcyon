import QtQuick
import QtQuick.Layouts
import "DeskSpots.js" as DS
import "WidgetData.js" as WD

// Settings > Appearance > Desktop builder: a line about what the desktop is now and the button that opens the builder window
// (DesktopBuilderWindow.qml: wallpaper on / off and blur, moving stars, and the corner each box opens from; its Lock screen side builds the
// lock screen: background, blur and tint, stars and splash, its widgets).
ColumnLayout {
    id: db
    property var pal
    property var opt: ({})
    signal openRequested(string which)         // which = "desktop" or "lock"
    signal resetRequested()

    width: parent ? parent.width : 0
    spacing: 10

    readonly property bool wallOn: !opt || opt.deskWall !== false
    readonly property bool isDefault: DS.allDefault(opt)
    readonly property int widgetCount: WD.normalize(opt ? opt.deskWidgets : null).items.length
    readonly property string barName: (opt && opt.barStyle === "off") ? "top bar off" : "top bar on"

    Text {
        Layout.fillWidth: true
        text: "Build your desktop: switch the wallpaper picture off (you get a plain background, the colours still follow the last wallpaper), blur it, put slowly moving stars over it, see where your widgets sit and move them, switch the top bar off, and choose the activation zone of each box (notifications, utilities, background apps, console): the screen corner it opens from. It opens in its own window with a small picture of the screen that changes as you do. What each widget looks like is the Widget builder (next entry)."
        color: db.pal.muted
        font.family: db.pal.uiFont
        font.pixelSize: 10
        lineHeight: 1.3
        wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        text: (db.wallOn ? ("Wallpaper on" + (db.opt && db.opt.deskBlur > 0 ? ", blurred " + db.opt.deskBlur + " %" : "")) : "Wallpaper off")
              + "  ·  " + (db.opt && db.opt.deskStars === true ? "Moving stars on" : "Moving stars off")
              + "  ·  " + db.widgetCount + (db.widgetCount === 1 ? " widget" : " widgets") + "  ·  " + db.barName
              + "\n" + DS.summary(db.opt ? db.opt.boxSpots : null)
        color: db.pal.text
        font.family: db.pal.uiFont
        font.pixelSize: db.pal.tCap
        lineHeight: 1.3
        wrapMode: Text.WordWrap
    }
    RowLayout {
        spacing: 8
        ActionChip { pal: db.pal; label: "Open the desktop builder"; on: true; onClicked: db.openRequested("desktop") }
        ActionChip { pal: db.pal; label: "Lock screen"; onClicked: db.openRequested("lock") }
        ActionChip { pal: db.pal; label: "Reset the desktop"; doneLabel: "Reset"; disabled: db.isDefault; onClicked: db.resetRequested() }
    }
}
