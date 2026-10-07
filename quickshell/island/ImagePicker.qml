import QtQuick
import Qt.labs.folderlistmodel
import Quickshell

// An image browser that lives INSIDE the island, so it can open on top of the SUPER+TAB tree.
// (A normal file-chooser window cannot do that: the tree is an overlay layer, a zenity / kdialog window is an ordinary
// window and would open on a workspace underneath it.)
//   folders and pictures of the current folder as a thumbnail grid; click a folder to go in, a picture to choose it
//   Up / Backspace = parent folder    Esc or a click outside = cancel    the chips on top jump to common folders
// Use:  ImagePicker { anchors.fill: parent; pal: pal; onPicked: path => ...; onCancelled: ... }  then  openAt(pathOrFolder)
Item {
    id: root

    property var pal: ({
        accent: "#eda578", accent2: "#d29da1", surface: "#1e2130", bg: "#14161f",
        text: "#e9e2dd", muted: "#aca19a", font: "JetBrainsMono Nerd Font", uiFont: "Inter Variable",
        rSm: 8, rMd: 12, rLg: 16, dMed: 200
    })
    property bool open: false
    property string folderPath: ""
    signal picked(string path)
    signal cancelled()

    readonly property string home: Quickshell.env("HOME")

    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal ? root.pal.dMed : 300; easing.type: Easing.InOutSine } }

    // "/a b/c#1" -> file:///a%20b/c%231
    function urlOf(path) {
        return "file://" + String(path).split("/").map(function (s) { return encodeURIComponent(s) }).join("/")
    }
    function parentOf(path) {
        var i = String(path).lastIndexOf("/")
        return i <= 0 ? "/" : String(path).substring(0, i)
    }
    function expand(p) {
        p = String(p || "").trim()
        if (p === "~") return home
        if (p.indexOf("~/") === 0) return home + p.substring(1)
        return p
    }
    function isImage(name) { return /\.(png|jpe?g|webp|gif|bmp|svg)$/i.test(name) }

    // start = a picture (its folder is opened), a folder, or nothing (Pictures)
    function openAt(start) {
        var s = expand(start)
        if (s === "") s = home + "/Pictures"
        else if (isImage(s)) s = parentOf(s)
        folderPath = s
        open = true
        Qt.callLater(function () { root.forceActiveFocus() })
    }
    function goUp() { if (folderPath !== "/") folderPath = parentOf(folderPath) }

    readonly property var places: [
        { label: "Pictures", path: home + "/Pictures" },
        { label: "Wallpapers", path: home + "/Pictures/Wallpapers" },
        { label: "Downloads", path: home + "/Downloads" },
        { label: "Home", path: home }
    ]

    Keys.onPressed: e => {
        if (e.key === Qt.Key_Escape) root.cancelled()
        else if (e.key === Qt.Key_Backspace || (e.key === Qt.Key_Up && (e.modifiers & Qt.AltModifier))) root.goUp()
        e.accepted = true            // nothing may leak to the tree underneath (Q closes it, E edits, S toggles)
    }

    // dim everything behind; a click outside the card cancels
    Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal ? root.pal.bg : "black", 0.62) }
    MouseArea { anchors.fill: parent; onClicked: root.cancelled() }

    FolderListModel {
        id: fm
        folder: root.open ? root.urlOf(root.folderPath) : "file:///"
        nameFilters: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.bmp", "*.svg", "*.PNG", "*.JPG", "*.JPEG", "*.WEBP", "*.GIF", "*.BMP", "*.SVG"]
        showDirs: true
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: false
        sortField: FolderListModel.Name
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 120, 880)
        height: Math.min(parent.height - 120, 580)
        radius: root.pal ? root.pal.rXl : 28
        color: Qt.alpha(root.pal ? root.pal.bg : "black", root.pal ? root.pal.glassSolid : 0.95)
        border.width: 1
        border.color: root.pal ? root.pal.line : "#22ffffff"
        scale: root.open ? 1 : 0.97
        Behavior on scale { NumberAnimation { duration: root.pal ? root.pal.dSlow : 520; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal ? root.pal.curve : [0.22, 1, 0.36, 1, 1, 1] } }

        MouseArea { anchors.fill: parent }       // clicks on the card itself do not cancel

        // ---- header: title, close
        Text {
            x: 24; y: 20
            text: "Choose a profile picture"
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: 17
            font.weight: Font.DemiBold
        }
        Rectangle {
            anchors.right: parent.right; anchors.rightMargin: 18
            y: 16; width: 32; height: 32; radius: 16
            color: closeMa.containsMouse ? root.pal.surface : "transparent"
            Text { anchors.centerIn: parent; text: "✕"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 13 }
            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelled() }
        }

        // ---- path row: up button, the folder, quick places
        Row {
            id: bar
            x: 24; y: 58
            width: parent.width - 48
            height: 34
            spacing: 8

            Rectangle {
                width: 34; height: 34; radius: 17
                color: upMa.containsMouse ? Qt.alpha(root.pal.accent, 0.28) : Qt.alpha(root.pal.accent, 0.14)
                border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.4)
                Behavior on color { ColorAnimation { duration: 120 } }
                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF005D); color: root.pal.text; font.family: root.pal.font; font.pixelSize: 14 }
                MouseArea { id: upMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.goUp() }
            }
            Rectangle {
                width: parent.width - 34 - parent.spacing - placeRow.width - parent.spacing
                height: 34; radius: 17
                color: root.pal.surface
                border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.25)
                Text {
                    anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                    verticalAlignment: Text.AlignVCenter
                    text: root.folderPath.indexOf(root.home) === 0 ? "~" + root.folderPath.substring(root.home.length) : root.folderPath
                    elide: Text.ElideLeft
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 12
                }
            }
            Row {
                id: placeRow
                spacing: 6
                Repeater {
                    model: root.places
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool here: root.folderPath === modelData.path
                        height: 34; width: plTxt.implicitWidth + 24; radius: 17
                        color: here ? Qt.alpha(root.pal.accent, 0.30) : (plMa.containsMouse ? Qt.alpha(root.pal.accent, 0.18) : "transparent")
                        border.width: 1; border.color: Qt.alpha(root.pal.accent, here ? 0.6 : 0.3)
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text { id: plTxt; anchors.centerIn: parent; text: modelData.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 12 }
                        MouseArea { id: plMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.folderPath = modelData.path }
                    }
                }
            }
        }

        // ---- the grid
        GridView {
            id: grid
            x: 18; y: 104
            width: parent.width - 36
            height: parent.height - 104 - 40
            clip: true
            cellWidth: Math.floor(width / Math.max(3, Math.floor(width / 150)))
            cellHeight: 138
            model: fm
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: cell
                required property string fileName
                required property string filePath
                required property bool fileIsDir
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 6
                    radius: root.pal.rMd
                    color: cellMa.containsMouse ? Qt.alpha(root.pal.accent, 0.16) : "transparent"
                    border.width: cellMa.containsMouse ? 1 : 0
                    border.color: Qt.alpha(root.pal.accent, 0.5)
                    Behavior on color { ColorAnimation { duration: 120 } }

                    // picture thumbnail (decoded small, so a big folder stays light)
                    Rectangle {
                        id: thumb
                        visible: !cell.fileIsDir
                        x: 8; y: 8
                        width: parent.width - 16; height: parent.height - 38
                        radius: root.pal.rSm
                        color: root.pal.surface
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: cell.fileIsDir ? "" : root.urlOf(cell.filePath)
                            sourceSize: Qt.size(220, 220)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                            opacity: status === Image.Ready ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                    // folder
                    Item {
                        visible: cell.fileIsDir
                        x: 8; y: 8
                        width: parent.width - 16; height: parent.height - 38
                        Text {
                            anchors.centerIn: parent
                            text: String.fromCodePoint(0xF024B)
                            color: Qt.alpha(root.pal.accent, 0.85)
                            font.family: root.pal.font
                            font.pixelSize: 46
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 8
                        width: parent.width - 16
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideMiddle
                        text: cell.fileName
                        color: cell.fileIsDir ? root.pal.text : root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: cellMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (cell.fileIsDir) root.folderPath = cell.filePath
                            else root.picked(cell.filePath)
                        }
                    }
                }
            }
        }

        Text {
            anchors.centerIn: grid
            visible: fm.count === 0
            text: "No pictures or folders here"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 13
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 14
            text: "click a picture to use it   ·   click a folder to open it   ·   Backspace = up   ·   Esc = cancel"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 11
        }
    }
}
