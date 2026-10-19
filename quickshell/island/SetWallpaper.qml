import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "wallpaper" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: wpCol
    width: parent ? parent.width : 0
    spacing: 12
    readonly property bool onlineOnly: root.opt.wpSource === "online"      // Online: the folder tools step out of the way
    // the search word for Online category "Search…"
    RowLayout {
        Layout.fillWidth: true
        visible: root.opt.wpSource !== "local" && root.opt.wpCat === "custom"
        spacing: 10
        Timer { id: wpFetchSoon; interval: 450; onTriggered: root.action("wallpaper") }       // the flag file is written first
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 36; radius: 18
            color: Qt.alpha(root.pal.bg, 0.5); border.width: 1; border.color: wpQueryIn.activeFocus ? root.pal.accent : root.pal.lineSoft
            TextInput {
                id: wpQueryIn
                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                verticalAlignment: TextInput.AlignVCenter
                color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                clip: true; selectByMouse: true
                text: root.opt.wpQuery || ""
                onEditingFinished: root.change("opt:wpQuery", text.trim())
                onAccepted: { root.change("opt:wpQuery", text.trim()); wpFetchSoon.restart() }
                Text { visible: !parent.text && !parent.activeFocus; anchors.verticalCenter: parent.verticalCenter; text: "Search word, e.g. cyberpunk, mountains, gengar"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
            }
        }
        ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0976); label: "Fetch"; onClicked: { root.change("opt:wpQuery", wpQueryIn.text.trim()); wpFetchSoon.restart() } }
    }
    RowLayout {
        Layout.fillWidth: true
        visible: !wpCol.onlineOnly
        spacing: 14
        Text { text: String.fromCodePoint(0xF024B); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 16 }
        Text {
            Layout.fillWidth: true
            text: root.wp.dir !== "" ? root.wp.dir : "~/Pictures/Wallpapers"
            elide: Text.ElideMiddle
            color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tBody
        }
        Text { text: (root.wp.files ? root.wp.files.length : 0) + " images"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
    }
    Flow {
        Layout.fillWidth: true
        spacing: 12
        ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF03E); label: "Gallery (Cascade, Carousel & Grid)"; onClicked: root.galleryOpen = true }
        ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0976); label: "Next wallpaper"; onClicked: root.action("wallpaper") }
        ActionChip { pal: root.pal; glyph: String.fromCodePoint(0xF0E2); label: "Back"; onClicked: root.action("wallpaper-back") }
        ActionChip { visible: root.opt.wpSource !== "local"; pal: root.pal; glyph: String.fromCodePoint(0xF0C7); label: "Keep this one"; onClicked: root.action("wallpaper-keep") }
        ActionChip { visible: !wpCol.onlineOnly; pal: root.pal; glyph: String.fromCodePoint(0xF0770); label: "Open folder"; onClicked: root.wpAct("open") }
        ActionChip { visible: !wpCol.onlineOnly; pal: root.pal; glyph: String.fromCodePoint(0xF0415); label: "Add wallpapers…"; onClicked: root.wpAct("add") }
        ActionChip { visible: !wpCol.onlineOnly; pal: root.pal; label: "Change folder…"; onClicked: root.wpAct("choose-dir") }
        ActionChip { visible: !wpCol.onlineOnly; pal: root.pal; label: "Default folder"; doneLabel: "Done"; onClicked: root.wpAct("reset-dir") }
    }
    Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: 92
        visible: !wpCol.onlineOnly && root.wp.files && root.wp.files.length > 0
        contentWidth: thumbRow.width
        contentHeight: height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick
        Row {
            id: thumbRow
            spacing: 14
            Repeater {
                model: root.wp.files || []
                delegate: Rectangle {
                    id: th
                    required property var modelData
                    readonly property bool now: root.wp.current === th.modelData.path
                    width: 140; height: 86; radius: 12
                    color: root.pal.surface
                    border.width: th.now ? 2 : 1
                    border.color: th.now ? root.pal.accent : root.pal.line
                    Image {
                        anchors.fill: parent; anchors.margins: 3
                        source: "file://" + th.modelData.path
                        sourceSize.width: 280; sourceSize.height: 170
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        opacity: thMa.containsMouse ? 1 : 0.92
                    }
                    Rectangle {
                        visible: th.now
                        anchors { right: parent.right; top: parent.top; margins: 6 }
                        width: 18; height: 18; radius: 9; color: root.pal.accent
                        Text { anchors.centerIn: parent; text: "✓"; color: root.pal.bg; font.pixelSize: 11; font.weight: Font.Bold }
                    }
                    MouseArea { id: thMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickWallpaper(th.modelData.path) }
                }
            }
        }
    }
    Text {
        Layout.fillWidth: true
        visible: !wpCol.onlineOnly
        text: root.wp.files && root.wp.files.length > 0 ? "Click one to use it. Drop more images into the folder (or Add wallpapers) and they show up here." : "No images in that folder yet. Use Add wallpapers, or open the folder and drop .jpg / .png / .webp files in."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        visible: wpCol.onlineOnly
        text: "Online: Next wallpaper fetches a new " + (root.opt.wpCat || "nature") + " picture. The next one is downloaded in the background, so it is instant. Keep this one saves the current picture into your folder. Switch Source to Local or Mixed to use your own folder again."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
}
