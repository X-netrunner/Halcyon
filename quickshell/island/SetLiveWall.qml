import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "liveWalls": pick the live wallpaper. The Halcyon sky first, then your videos / GIFs from ~/Pictures/Wallpapers/live
// (or ~/Pictures/Live), listed with thumbnails by scripts/live-wallpapers.sh. A click picks it and switches the live wallpaper on;
// Super + Alt + W switches it on and off. `root` is the Settings scope.
ColumnLayout {
    id: lw
    property var root
    width: parent ? parent.width : 0
    spacing: 10
    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/quickshell/island/scripts/live-wallpapers.sh"
    readonly property bool on: root.opt.deskLive === "on" || root.opt.deskLive === "sky"
    readonly property string pick: root.opt.deskLivePick || "sky"
    property var files: []
    property bool loading: true
    function pickIt(p) {
        root.change("opt:deskLivePick", p)
        if (!on) root.change("opt:deskLive", "on")
    }

    Process {
        id: listProc
        running: true
        command: ["bash", lw.script, "list"]
        stdout: StdioCollector { onStreamFinished: { try { lw.files = JSON.parse(text) } catch (e) { lw.files = [] } lw.loading = false } }
    }

    Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: 92
        contentWidth: tiles.width
        contentHeight: height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick
        Row {
            id: tiles
            spacing: 14
            Repeater {
                model: [{ path: "sky", name: "Halcyon sky", thumb: "" }].concat(lw.files)
                delegate: Rectangle {
                    id: tile
                    required property var modelData
                    readonly property bool now: lw.on && lw.pick === tile.modelData.path
                    width: 140; height: 86; radius: 12
                    color: lw.root.pal.surface
                    border.width: tile.now ? 2 : 1
                    border.color: tile.now ? lw.root.pal.accent : lw.root.pal.line
                    clip: true
                    // the sky: a tiny still of it (dark stage, accent glow, the sparkle)
                    Rectangle {
                        visible: tile.modelData.path === "sky"
                        anchors.fill: parent; anchors.margins: 3; radius: 10
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.tint(lw.root.pal.bg, Qt.alpha(lw.root.pal.accent, 0.18)) }
                            GradientStop { position: 1; color: lw.root.pal.bg }
                        }
                        Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -6; text: "✦"; color: lw.root.pal.text; font.pixelSize: 26 }
                    }
                    Image {
                        visible: tile.modelData.thumb !== ""
                        anchors.fill: parent; anchors.margins: 3
                        source: tile.modelData.thumb !== "" ? "file://" + tile.modelData.thumb : ""
                        sourceSize.width: 280; sourceSize.height: 170
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                    }
                    Text {
                        visible: tile.modelData.path !== "sky" && tile.modelData.thumb === ""
                        anchors.centerIn: parent; anchors.verticalCenterOffset: -6
                        text: String.fromCodePoint(0xF0567); color: lw.root.pal.muted; font.family: lw.root.pal.font; font.pixelSize: 22
                    }
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 3 }
                        height: 20; radius: 8
                        color: Qt.alpha("black", 0.45)
                        Text {
                            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                            verticalAlignment: Text.AlignVCenter
                            text: tile.modelData.name; elide: Text.ElideRight
                            color: "white"; font.family: lw.root.pal.uiFont; font.pixelSize: 10
                        }
                    }
                    Rectangle {
                        visible: tile.now
                        anchors { right: parent.right; top: parent.top; margins: 6 }
                        width: 18; height: 18; radius: 9; color: lw.root.pal.accent
                        Text { anchors.centerIn: parent; text: "✓"; color: lw.root.pal.bg; font.pixelSize: 11; font.weight: Font.Bold }
                    }
                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: lw.pickIt(tile.modelData.path) }
                }
            }
        }
    }
    Flow {
        Layout.fillWidth: true
        spacing: 12
        ActionChip { pal: lw.root.pal; glyph: String.fromCodePoint(0xF0770); label: "Open live folder"
            onClicked: { lw.root.hide(); Quickshell.execDetached(["sh", "-c", "d=$(bash \"$0\" dirs | head -n1) && xdg-open \"$d\"", lw.script]) } }
        ActionChip { pal: lw.root.pal; glyph: String.fromCodePoint(0xF0450); label: "Look again"; onClicked: { lw.loading = true; listProc.running = true } }
    }
    Text {
        Layout.fillWidth: true
        text: lw.loading ? "Looking for live wallpapers…"
            : (lw.files.length === 0 ? "Put videos (.mp4 .webm .mkv .mov) or GIFs in ~/Pictures/Wallpapers/live (or ~/Pictures/Live) and press Look again. "
                                     : "Click one to use it. ")
              + "Super + Alt + W switches the live wallpaper on and off. Videos play without sound and pause whenever the desktop is hidden."
        color: lw.root.pal.muted; font.family: lw.root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
}
