import QtQuick
import QtQuick.Layouts
import "DeskSpots.js" as DS

// Settings > Appearance > Desktop builder: a line about what the desktop is now and the button that opens the builder window
// (DesktopBuilderWindow.qml: wallpaper on / off and blur, moving stars, and the corner each box opens from).
ColumnLayout {
    id: db
    property var pal
    property var opt: ({})
    signal openRequested()
    signal resetRequested()

    width: parent ? parent.width : 0
    spacing: 10

    readonly property bool wallOn: !opt || opt.deskWall !== false
    readonly property bool isDefault: wallOn && !(opt && opt.deskBlur > 0) && !(opt && opt.deskStars === true) && DS.isDefault(opt ? opt.boxSpots : null)
                                      && !(opt && opt.deskBg && opt.deskBg !== "theme")

    Text {
        Layout.fillWidth: true
        text: "Build your desktop: switch the wallpaper picture off (you get a plain background, the colours still follow the last wallpaper), blur it, put slowly moving stars over it, and choose which screen corner each box (utilities, background apps, console) opens from. It opens in its own window with a small picture of the screen that changes as you do."
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
              + "\n" + DS.summary(db.opt ? db.opt.boxSpots : null)
        color: db.pal.text
        font.family: db.pal.uiFont
        font.pixelSize: db.pal.tCap
        lineHeight: 1.3
        wrapMode: Text.WordWrap
    }
    RowLayout {
        spacing: 8
        ActionChip { pal: db.pal; label: "Open the desktop builder"; on: true; onClicked: db.openRequested() }
        ActionChip { pal: db.pal; label: "Reset the desktop"; doneLabel: "Reset"; disabled: db.isDefault; onClicked: db.resetRequested() }
    }
}
