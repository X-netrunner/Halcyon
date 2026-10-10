import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland

// WallpaperGallery: A sleek, interactive wallpaper selector inspired by Tide-island
// - Live search query filtering
// - Coverflow Carousel (PathView) & Card Grid views
// - Active selection halo & checkmark badge
// - Keyboard navigation (Left/Right to browse, Enter to apply, Esc to close, / to search)
// - One-click folder actions (Add, Open, Change dir)
Item {
    id: root

    property var pal
    property bool open: false
    property var wp: ({ dir: "", current: "", files: [] })
    property string searchQuery: ""
    property string viewMode: "carousel" // carousel | grid

    signal picked(string path)
    signal action(string name)
    signal closed()

    function show() {
        open = true
        searchQuery = ""
        searchInput.text = ""
        root.forceActiveFocus()
    }

    function hide() {
        open = false
        closed()
    }

    function toggle() {
        if (open) hide()
        else show()
    }

    // Filtered list based on searchQuery
    readonly property var filteredFiles: {
        var all = (wp && wp.files) ? wp.files : []
        if (!searchQuery || searchQuery.trim() === "") return all
        var q = searchQuery.trim().toLowerCase()
        var res = []
        for (var i = 0; i < all.length; i++) {
            var item = all[i]
            var name = (item.name || "").toLowerCase()
            if (name.indexOf(q) !== -1) res.push(item)
        }
        return res
    }

    readonly property int activeIndex: {
        var cur = wp ? wp.current : ""
        for (var i = 0; i < filteredFiles.length; i++) {
            if (filteredFiles[i].path === cur) return i
        }
        return 0
    }

    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open

    Behavior on opacity {
        NumberAnimation { duration: root.pal ? root.pal.dMed : 220; easing.type: Easing.OutCubic }
    }

    Keys.onPressed: function(e) {
        if (e.key === Qt.Key_Escape) {
            if (searchInput.activeFocus && searchInput.text !== "") {
                searchInput.text = ""
            } else {
                root.hide()
            }
            e.accepted = true
        } else if (e.key === Qt.Key_Slash && !searchInput.activeFocus) {
            searchInput.forceActiveFocus()
            e.accepted = true
        } else if (e.key === Qt.Key_Left && !searchInput.activeFocus) {
            if (viewMode === "carousel" && carousel.count > 0) {
                carousel.decrementCurrentIndex()
            }
            e.accepted = true
        } else if (e.key === Qt.Key_Right && !searchInput.activeFocus) {
            if (viewMode === "carousel" && carousel.count > 0) {
                carousel.incrementCurrentIndex()
            }
            e.accepted = true
        } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
            if (!searchInput.activeFocus && filteredFiles.length > 0) {
                var idx = viewMode === "carousel" ? carousel.currentIndex : 0
                if (idx >= 0 && idx < filteredFiles.length) {
                    root.picked(filteredFiles[idx].path)
                }
            }
            e.accepted = true
        }
    }

    // Backdrop blur / dim
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal ? root.pal.bg : "#0f111a", 0.72)

        MouseArea {
            anchors.fill: parent
            onClicked: root.hide()
        }
    }

    // Main Modal Card
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 960)
        height: Math.min(parent.height - 80, 620)
        radius: root.pal ? root.pal.rXl : 24
        color: Qt.alpha(root.pal ? root.pal.surface : "#1a1c28", root.pal ? root.pal.glassSolid : 0.94)
        border.width: 1
        border.color: root.pal ? root.pal.line : "#22ffffff"

        scale: root.open ? 1 : 0.96
        Behavior on scale {
            NumberAnimation { duration: root.pal ? root.pal.dMed : 260; easing.type: Easing.OutQuint }
        }

        MouseArea { anchors.fill: parent } // Prevent clicks on card from closing

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 16

            // ── Top Header: Title, Search bar, View toggle, Close ─────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Row {
                    spacing: 10
                    Layout.alignment: Qt.AlignVCenter
                    Text {
                        text: String.fromCodePoint(0xF024B) // Picture icon
                        font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                        font.pixelSize: 20
                        color: root.pal ? root.pal.accent : "#8aadf4"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Wallpaper Gallery"
                        font.family: root.pal ? root.pal.uiFont : "Inter"
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                        color: root.pal ? root.pal.text : "#ffffff"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "(" + root.filteredFiles.length + (root.filteredFiles.length !== (root.wp.files ? root.wp.files.length : 0) ? " of " + (root.wp.files ? root.wp.files.length : 0) : "") + ")"
                        font.family: root.pal ? root.pal.uiFont : "Inter"
                        font.pixelSize: 13
                        color: root.pal ? root.pal.muted : "#888888"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Item { Layout.fillWidth: true }

                // Search Bar
                Rectangle {
                    Layout.preferredWidth: 260
                    Layout.preferredHeight: 34
                    radius: 12
                    color: Qt.alpha(root.pal ? root.pal.bg : "#10121c", 0.6)
                    border.width: 1
                    border.color: searchInput.activeFocus ? (root.pal ? root.pal.accent : "#8aadf4") : (root.pal ? root.pal.line : "#22ffffff")

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 8
                        spacing: 6

                        Text {
                            text: "\uf002"
                            font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                            font.pixelSize: 12
                            color: root.pal ? root.pal.muted : "#888888"
                        }

                        TextInput {
                            id: searchInput
                            Layout.fillWidth: true
                            color: root.pal ? root.pal.text : "#ffffff"
                            font.family: root.pal ? root.pal.uiFont : "Inter"
                            font.pixelSize: 12
                            clip: true
                            selectByMouse: true
                            onTextChanged: root.searchQuery = text

                            Text {
                                text: "Search wallpapers…"
                                visible: parent.text === "" && !parent.activeFocus
                                color: root.pal ? root.pal.muted : "#666666"
                                font.family: parent.font.family
                                font.pixelSize: parent.font.pixelSize
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Rectangle {
                            visible: searchInput.text !== ""
                            width: 18
                            height: 18
                            radius: 9
                            color: clearMa.containsMouse ? Qt.alpha(root.pal.text, 0.2) : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                font.pixelSize: 10
                                color: root.pal ? root.pal.muted : "#888"
                            }
                            MouseArea {
                                id: clearMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: searchInput.text = ""
                            }
                        }
                    }
                }

                // View Mode Toggle (Carousel vs Grid)
                Rectangle {
                    Layout.preferredWidth: 64
                    Layout.preferredHeight: 34
                    radius: 12
                    color: Qt.alpha(root.pal ? root.pal.bg : "#10121c", 0.6)
                    border.width: 1
                    border.color: root.pal ? root.pal.line : "#22ffffff"

                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Rectangle {
                            width: 24; height: 24; radius: 8
                            color: root.viewMode === "carousel" ? (root.pal ? root.pal.accent : "#8aadf4") : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: "\uf03e" // Carousel icon
                                font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                                font.pixelSize: 12
                                color: root.viewMode === "carousel" ? (root.pal ? root.pal.bg : "#000") : (root.pal ? root.pal.muted : "#888")
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.viewMode = "carousel"
                            }
                        }
                        Rectangle {
                            width: 24; height: 24; radius: 8
                            color: root.viewMode === "grid" ? (root.pal ? root.pal.accent : "#8aadf4") : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: "\uf00a" // Grid icon
                                font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                                font.pixelSize: 12
                                color: root.viewMode === "grid" ? (root.pal ? root.pal.bg : "#000") : (root.pal ? root.pal.muted : "#888")
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.viewMode = "grid"
                            }
                        }
                    }
                }

                // Close Button
                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    radius: 16
                    color: closeMa.containsMouse ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.bg, 0.5)
                    border.width: 1
                    border.color: root.pal ? root.pal.line : "#22ffffff"

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: root.pal ? root.pal.text : "#fff"
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.hide()
                    }
                }
            }

            // ── Main Content Area: Carousel or Grid ──────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // Empty state
                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    visible: root.filteredFiles.length === 0

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "\uf03e"
                        font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                        font.pixelSize: 36
                        color: Qt.alpha(root.pal ? root.pal.muted : "#888", 0.4)
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.searchQuery !== "" ? "No wallpapers match \"" + root.searchQuery + "\"" : "No wallpapers found in directory"
                        font.family: root.pal ? root.pal.uiFont : "Inter"
                        font.pixelSize: 14
                        color: root.pal ? root.pal.muted : "#888"
                    }
                }

                // MODE 1: 3D Coverflow Carousel (Tide-island style PathView)
                PathView {
                    id: carousel
                    anchors.fill: parent
                    visible: root.viewMode === "carousel" && root.filteredFiles.length > 0
                    model: root.filteredFiles
                    pathItemCount: Math.min(root.filteredFiles.length, 5)
                    snapMode: PathView.SnapToItem
                    preferredHighlightBegin: 0.5
                    preferredHighlightEnd: 0.5
                    highlightRangeMode: PathView.StrictlyEnforceRange
                    highlightMoveDuration: 280

                    property real itemW: Math.round(width * 0.46)
                    property real itemH: Math.round(itemW * 0.60)
                    property real cardSpacing: itemW * 0.70

                    path: Path {
                        startX: carousel.width / 2 - carousel.cardSpacing * 2
                        startY: carousel.height / 2
                        PathAttribute { name: "itemScale"; value: 0.65 }
                        PathAttribute { name: "itemOpacity"; value: 0.40 }
                        PathAttribute { name: "itemZ"; value: 1 }

                        PathLine {
                            x: carousel.width / 2
                            y: carousel.height / 2
                        }
                        PathAttribute { name: "itemScale"; value: 1.0 }
                        PathAttribute { name: "itemOpacity"; value: 1.0 }
                        PathAttribute { name: "itemZ"; value: 10 }

                        PathLine {
                            x: carousel.width / 2 + carousel.cardSpacing * 2
                            y: carousel.height / 2
                        }
                        PathAttribute { name: "itemScale"; value: 0.65 }
                        PathAttribute { name: "itemOpacity"; value: 0.40 }
                        PathAttribute { name: "itemZ"; value: 1 }
                    }

                    delegate: Item {
                        id: cDelegate
                        required property var modelData
                        required property int index
                        width: carousel.itemW
                        height: carousel.itemH
                        scale: PathView.itemScale !== undefined ? PathView.itemScale : 1.0
                        opacity: PathView.itemOpacity !== undefined ? PathView.itemOpacity : 1.0
                        z: PathView.itemZ !== undefined ? PathView.itemZ : 1

                        readonly property bool isCurrent: root.wp.current === cDelegate.modelData.path
                        readonly property bool isSelected: carousel.currentIndex === cDelegate.index

                        Rectangle {
                            anchors.fill: parent
                            radius: root.pal ? root.pal.rLg : 16
                            color: root.pal ? root.pal.surface : "#1e2130"
                            border.width: cDelegate.isCurrent ? 3 : (cDelegate.isSelected ? 2 : 1)
                            border.color: cDelegate.isCurrent ? (root.pal ? root.pal.accent : "#8aadf4") : (cDelegate.isSelected ? (root.pal ? root.pal.accent2 : "#c6a0f6") : (root.pal ? root.pal.line : "#22ffffff"))

                            Image {
                                anchors.fill: parent
                                anchors.margins: cDelegate.isCurrent ? 4 : 2
                                source: "file://" + cDelegate.modelData.path
                                sourceSize.width: 640
                                sourceSize.height: 360
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                mipmap: true

                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    height: 36
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 1.0; color: Qt.alpha(root.pal.bg, 0.85) }
                                    }
                                    Text {
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        text: cDelegate.modelData.name || ""
                                        elide: Text.ElideMiddle
                                        color: root.pal ? root.pal.text : "#fff"
                                        font.family: root.pal ? root.pal.uiFont : "Inter"
                                        font.pixelSize: 11
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }

                            // Active checkmark badge
                            Rectangle {
                                visible: cDelegate.isCurrent
                                anchors { right: parent.right; top: parent.top; margins: 10 }
                                width: 24; height: 24; radius: 12
                                color: root.pal ? root.pal.accent : "#8aadf4"
                                Text {
                                    anchors.centerIn: parent
                                    text: "✓"
                                    color: root.pal ? root.pal.bg : "#000"
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (carousel.currentIndex === cDelegate.index) {
                                        root.picked(cDelegate.modelData.path)
                                    } else {
                                        carousel.currentIndex = cDelegate.index
                                    }
                                }
                            }
                        }
                    }
                }

                // MODE 2: Card Grid View
                GridView {
                    id: grid
                    anchors.fill: parent
                    visible: root.viewMode === "grid" && root.filteredFiles.length > 0
                    model: root.filteredFiles
                    cellWidth: Math.floor(width / Math.max(3, Math.floor(width / 220)))
                    cellHeight: Math.round(cellWidth * 0.65)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        id: gDelegate
                        required property var modelData
                        required property int index
                        width: grid.cellWidth
                        height: grid.cellHeight

                        readonly property bool isCurrent: root.wp.current === gDelegate.modelData.path

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 8
                            radius: root.pal ? root.pal.rMd : 12
                            color: root.pal ? root.pal.surface : "#1e2130"
                            border.width: gDelegate.isCurrent ? 2 : 1
                            border.color: gDelegate.isCurrent ? (root.pal ? root.pal.accent : "#8aadf4") : (gMa.containsMouse ? (root.pal ? root.pal.accent2 : "#c6a0f6") : (root.pal ? root.pal.line : "#22ffffff"))

                            Image {
                                anchors.fill: parent
                                anchors.margins: 2
                                source: "file://" + gDelegate.modelData.path
                                sourceSize.width: 380
                                sourceSize.height: 220
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                opacity: gMa.containsMouse ? 1.0 : 0.90

                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    height: 28
                                    color: Qt.alpha(root.pal.bg, 0.75)
                                    Text {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        text: gDelegate.modelData.name || ""
                                        elide: Text.ElideMiddle
                                        color: root.pal ? root.pal.text : "#fff"
                                        font.family: root.pal ? root.pal.uiFont : "Inter"
                                        font.pixelSize: 10
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }

                            Rectangle {
                                visible: gDelegate.isCurrent
                                anchors { right: parent.right; top: parent.top; margins: 6 }
                                width: 20; height: 20; radius: 10
                                color: root.pal ? root.pal.accent : "#8aadf4"
                                Text {
                                    anchors.centerIn: parent
                                    text: "✓"
                                    color: root.pal ? root.pal.bg : "#000"
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                }
                            }

                            MouseArea {
                                id: gMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.picked(gDelegate.modelData.path)
                            }
                        }
                    }
                }
            }

            // ── Bottom Toolbar: Folder location & Action Chips ──────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Text {
                    text: root.wp.dir || "~/Pictures/Wallpapers"
                    elide: Text.ElideMiddle
                    font.family: root.pal ? root.pal.mono : "JetBrainsMono Nerd Font"
                    font.pixelSize: 11
                    color: root.pal ? root.pal.muted : "#888"
                    Layout.maximumWidth: 320
                }

                Item { Layout.fillWidth: true }

                // Quick Action Buttons
                Row {
                    spacing: 8

                    Rectangle {
                        height: 30
                        width: randRow.implicitWidth + 20
                        radius: 10
                        color: randMa.containsMouse ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.surfaceHi, 0.7)
                        border.width: 1
                        border.color: root.pal ? root.pal.line : "#22ffffff"

                        Row {
                            id: randRow
                            anchors.centerIn: parent
                            spacing: 6
                            Text { text: "\uf074"; font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: root.pal.accent }
                            Text { text: "Random Next"; font.family: root.pal.uiFont; font.pixelSize: 11; color: root.pal.text }
                        }
                        MouseArea {
                            id: randMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.action("wallpaper")
                        }
                    }

                    Rectangle {
                        height: 30
                        width: addRow.implicitWidth + 20
                        radius: 10
                        color: addMa.containsMouse ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.surfaceHi, 0.7)
                        border.width: 1
                        border.color: root.pal ? root.pal.line : "#22ffffff"

                        Row {
                            id: addRow
                            anchors.centerIn: parent
                            spacing: 6
                            Text { text: "\uf067"; font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: root.pal.accent }
                            Text { text: "Add Wallpapers"; font.family: root.pal.uiFont; font.pixelSize: 11; color: root.pal.text }
                        }
                        MouseArea {
                            id: addMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.action("add")
                        }
                    }

                    Rectangle {
                        height: 30
                        width: openRow.implicitWidth + 20
                        radius: 10
                        color: openMa.containsMouse ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.surfaceHi, 0.7)
                        border.width: 1
                        border.color: root.pal ? root.pal.line : "#22ffffff"

                        Row {
                            id: openRow
                            anchors.centerIn: parent
                            spacing: 6
                            Text { text: "\uf07c"; font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: root.pal.accent }
                            Text { text: "Open Folder"; font.family: root.pal.uiFont; font.pixelSize: 11; color: root.pal.text }
                        }
                        MouseArea {
                            id: openMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.action("open")
                        }
                    }
                }
            }
        }
    }
}
