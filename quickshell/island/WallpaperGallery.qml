import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import QtQuick.Effects

// WallpaperGallery: A sleek, interactive wallpaper selector inspired by Tide-island
// - Live search query filtering
// - Cascade (the default): cards step down and back from the front one, the colours of each wallpaper hang under it as circles
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
    property string viewMode: "cascade" // cascade | carousel | grid
    // the colours of every wallpaper ({ path: ["#accent", "#accent2", ...swatches] }, filled by scripts/wallpapers.sh colors)
    property var colors: ({})
    readonly property int maxDots: 5

    // up to maxDots clearly different colours of one wallpaper (the accent and the strongest swatch are often the same colour)
    function colorsFor(path) {
        var raw = (colors && colors[path]) ? colors[path] : []
        var out = [], rgb = []
        for (var i = 0; i < raw.length && out.length < maxDots; i++) {
            var c = String(raw[i])
            if (!/^#[0-9a-fA-F]{6}$/.test(c)) continue
            var a = [parseInt(c.substr(1, 2), 16), parseInt(c.substr(3, 2), 16), parseInt(c.substr(5, 2), 16)]
            var dup = false
            for (var j = 0; j < rgb.length; j++) {
                var dr = a[0] - rgb[j][0], dg = a[1] - rgb[j][1], db = a[2] - rgb[j][2]
                if (dr * dr + dg * dg + db * db < 1444) { dup = true; break }
            }
            if (!dup) { out.push(c); rgb.push(a) }
        }
        return out
    }

    signal picked(string path)
    signal action(string name)
    signal closed()

    // `open` is set from outside (Settings.galleryOpen); the gallery only asks to be closed (closed()).
    function enter() {
        searchQuery = ""
        searchInput.text = ""
        cascade.snap(activeIndex)            // open on the wallpaper in use, without a sweep
        Qt.callLater(function () { root.forceActiveFocus() })
    }
    onOpenChanged: if (open) enter()
    Component.onCompleted: if (open) enter()

    function hide() { closed() }

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
            if (viewMode === "cascade") cascade.step(-1)
            else if (viewMode === "carousel" && carousel.count > 0) carousel.decrementCurrentIndex()
            e.accepted = true
        } else if (e.key === Qt.Key_Right && !searchInput.activeFocus) {
            if (viewMode === "cascade") cascade.step(1)
            else if (viewMode === "carousel" && carousel.count > 0) carousel.incrementCurrentIndex()
            e.accepted = true
        } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
            if (!searchInput.activeFocus && filteredFiles.length > 0) {
                var idx = viewMode === "cascade" ? cascade.cur : (viewMode === "carousel" ? carousel.currentIndex : 0)
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

                // View Mode Toggle (Cascade / Carousel / Grid)
                Rectangle {
                    Layout.preferredWidth: 100
                    Layout.preferredHeight: 34
                    radius: 12
                    color: Qt.alpha(root.pal ? root.pal.bg : "#10121c", 0.6)
                    border.width: 1
                    border.color: root.pal ? root.pal.line : "#22ffffff"

                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Repeater {
                            model: [
                                { mode: "cascade", glyph: "\uf24d" },
                                { mode: "carousel", glyph: "\uf03e" },
                                { mode: "grid", glyph: "\uf00a" }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: 26; height: 24; radius: 8
                                color: root.viewMode === modelData.mode ? (root.pal ? root.pal.accent : "#8aadf4") : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.glyph
                                    font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                                    font.pixelSize: 12
                                    color: root.viewMode === modelData.mode ? (root.pal ? root.pal.bg : "#000") : (root.pal ? root.pal.muted : "#888")
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.viewMode = modelData.mode
                                }
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

                // MODE 0: Cascade. The pictures step down and back from the front card, a little tilted and overlapping; the colours
                //   of every wallpaper hang under its card as circles. Drag, scroll, click a card, or Left / Right.
                Item {
                    id: cascade
                    anchors.fill: parent
                    visible: root.viewMode === "cascade" && root.filteredFiles.length > 0

                    readonly property int count: root.filteredFiles.length
                    readonly property real cardW: Math.round(Math.min(width * 0.48, (height * 0.86 - 72) / 0.62))
                    readonly property real cardH: Math.round(cardW * 0.62)
                    readonly property real cardR: 20
                    readonly property real unitH: cardH + 70                // card + colour capsule + name
                    readonly property real pitch: cardW * 0.60              // one card to the next, for dragging

                    property int cur: 0                                     // the front card
                    property bool snapping: false
                    property real base: cur
                    Behavior on base { enabled: !pan.active && !cascade.snapping; NumberAnimation { duration: 480; easing.type: Easing.OutQuint } }
                    property real dragN: 0                                  // how far a drag has pulled it, in cards
                    Behavior on dragN { enabled: !pan.active && !cascade.snapping; NumberAnimation { duration: 480; easing.type: Easing.OutQuint } }
                    readonly property real pos: base + dragN

                    function snap(i) { snapping = true; cur = Math.max(0, Math.min(count - 1, i)); dragN = 0; snapping = false }
                    function step(d) { cur = Math.max(0, Math.min(count - 1, cur + d)) }
                    Connections { target: root; function onFilteredFilesChanged() { cascade.snap(cascade.cur) } }

                    // the look of a card at distance |d| from the front (0 = front); in between it is blended
                    readonly property var tX: [0, 0.60, 0.93, 1.12, 1.24]      // sideways, in card widths
                    readonly property var tY: [0, 0.05, 0.09, 0.12, 0.14]      // down, in view heights
                    readonly property var tS: [1, 0.84, 0.70, 0.58, 0.50]      // size
                    readonly property var tO: [1, 0.92, 0.68, 0.34, 0]         // opacity
                    readonly property var tR: [0, 5, 8, 10, 12]                // tilt, degrees
                    function tab(arr, a) {
                        a = Math.max(0, Math.min(arr.length - 1.0001, a))
                        var i = Math.floor(a), t = a - i
                        return arr[i] * (1 - t) + arr[i + 1] * t
                    }

                    // ambient glow behind the front card, in that wallpaper's accent
                    Rectangle {
                        readonly property int fi: Math.max(0, Math.min(cascade.count - 1, Math.round(cascade.pos)))
                        readonly property var fc: cascade.count > 0 ? root.colorsFor(root.filteredFiles[fi].path) : []
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: (cascade.height - cascade.unitH) / 2 + cascade.cardH * 0.1
                        width: cascade.cardW * 1.5
                        height: cascade.cardH * 1.1
                        radius: height / 2
                        color: fc.length > 0 ? fc[0] : (root.pal ? root.pal.accent : "#8aadf4")
                        opacity: 0.22
                        Behavior on color { ColorAnimation { duration: 500 } }
                        layer.enabled: true
                        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 64 }
                    }

                    // nine cards are enough: a card only changes picture while it is far off to the side and invisible
                    Repeater {
                        model: 9
                        delegate: Item {
                            id: cd
                            required property int index
                            readonly property int front: Math.round(cascade.pos)
                            readonly property int f: {
                                var r = ((index - front) % 9 + 9) % 9
                                if (r > 4) r -= 9
                                return front + r
                            }
                            readonly property real d: f - cascade.pos
                            readonly property real ad: Math.abs(d)
                            readonly property real sg: d < 0 ? -1 : 1
                            readonly property bool valid: f >= 0 && f < cascade.count
                            readonly property var file: (f >= 0 && f < cascade.count) ? root.filteredFiles[f] : null
                            readonly property bool isFront: ad < 0.5
                            readonly property bool isCurrent: file !== null && root.wp.current === file.path
                            readonly property var cols: file !== null ? root.colorsFor(file.path) : []

                            visible: valid && opacity > 0.01
                            width: cascade.cardW
                            height: cascade.unitH
                            x: (cascade.width - width) / 2 + sg * cascade.tab(cascade.tX, ad) * cascade.cardW
                            y: (cascade.height - height) / 2 + cascade.tab(cascade.tY, ad) * cascade.height
                            scale: cascade.tab(cascade.tS, ad)
                            opacity: cascade.tab(cascade.tO, ad)
                            z: 1000 - ad * 100

                            Item {
                                id: cardBox
                                width: parent.width
                                height: cascade.cardH
                                rotation: cd.sg * cascade.tab(cascade.tR, cd.ad)
                                antialiasing: true

                                // body + soft shadow (also what shows while the picture is still loading)
                                Rectangle {
                                    id: body
                                    anchors.fill: parent
                                    radius: cascade.cardR
                                    color: root.pal ? root.pal.surface : "#1e2130"
                                    visible: false
                                }
                                MultiEffect {
                                    anchors.fill: body
                                    source: body
                                    visible: cd.ad < 1.6
                                    shadowEnabled: true
                                    shadowColor: "#000000"
                                    shadowOpacity: 0.55
                                    shadowBlur: 1.0
                                    shadowVerticalOffset: 16
                                    shadowScale: 0.96
                                }

                                // the picture, cut to the rounded shape with a soft (anti-aliased) mask
                                Image {
                                    id: img
                                    anchors.fill: parent
                                    source: cd.file !== null ? "file://" + cd.file.path : ""
                                    sourceSize.width: 720
                                    sourceSize.height: 450
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: true
                                    mipmap: true
                                    smooth: true
                                    visible: false
                                }
                                Item {
                                    id: maskItem
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: true
                                    Rectangle { anchors.fill: parent; radius: cascade.cardR; color: "black"; antialiasing: true }
                                }
                                MultiEffect {
                                    anchors.fill: img
                                    source: img
                                    maskEnabled: true
                                    maskSource: maskItem
                                    maskThresholdMin: 0.5
                                    maskSpreadAtMin: 1.0
                                    opacity: img.status === Image.Ready ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 260 } }
                                }

                                // edge: a fine light line, the wallpaper's own accent when it is the one in use
                                Rectangle {
                                    anchors.fill: parent
                                    radius: cascade.cardR
                                    color: "transparent"
                                    antialiasing: true
                                    border.width: cd.isCurrent ? 2 : 1
                                    border.color: cd.isCurrent ? (cd.cols.length > 0 ? cd.cols[0] : (root.pal ? root.pal.accent : "#8aadf4"))
                                                  : Qt.alpha(root.pal ? root.pal.text : "#ffffff", cd.isFront ? 0.30 : 0.12)
                                    Behavior on border.color { ColorAnimation { duration: 200 } }
                                }

                                // "in use" badge
                                Rectangle {
                                    visible: cd.isCurrent
                                    anchors { right: parent.right; top: parent.top; margins: 12 }
                                    width: 26; height: 26; radius: 13
                                    antialiasing: true
                                    color: cd.cols.length > 0 ? cd.cols[0] : (root.pal ? root.pal.accent : "#8aadf4")
                                    Text {
                                        anchors.centerIn: parent
                                        text: "\u2713"
                                        color: root.pal ? root.pal.bg : "#000"
                                        font.pixelSize: 14
                                        font.weight: Font.Bold
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (cd.isFront) root.picked(cd.file.path)
                                        else cascade.cur = cd.f
                                    }
                                }
                            }

                            // the wallpaper's colours, under its card
                            SwatchDots {
                                id: dots
                                pal: root.pal
                                colors: cd.cols
                                size: 18
                                lit: cd.isFront
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: cardBox.bottom
                                anchors.topMargin: 14
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: dots.bottom
                                anchors.topMargin: 8
                                width: parent.width - 24
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideMiddle
                                text: cd.file !== null ? cd.file.name.replace(/\.[^.]+$/, "") : ""
                                opacity: Math.max(0, 1 - cd.ad * 2.4)
                                color: root.pal ? root.pal.text : "#fff"
                                font.family: root.pal ? root.pal.uiFont : "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                        }
                    }

                    // drag sideways, or scroll, to move through the cards
                    DragHandler {
                        id: pan
                        target: null
                        yAxis.enabled: false
                        onTranslationChanged: if (active) cascade.dragN = -translation.x / cascade.pitch
                        onActiveChanged: {
                            if (active) return
                            var n = cascade.dragN
                            var k = Math.abs(n) < 1 ? (Math.abs(n) > 0.18 ? (n > 0 ? 1 : -1) : 0) : Math.round(n)
                            cascade.cur = Math.max(0, Math.min(cascade.count - 1, cascade.cur + k))
                            cascade.dragN = 0
                        }
                    }
                    WheelHandler {
                        property real acc: 0
                        onWheel: e => {
                            acc += (e.angleDelta.x !== 0 ? -e.angleDelta.x : e.angleDelta.y)
                            if (Math.abs(acc) >= 100) { cascade.step(acc < 0 ? 1 : -1); acc = 0 }
                        }
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
                                    SwatchDots {
                                        pal: root.pal
                                        colors: root.colorsFor(cDelegate.modelData.path)
                                        capsule: false
                                        size: 9
                                        slots: 0
                                        anchors.right: parent.right
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        anchors.rightMargin: 100
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
                                    SwatchDots {
                                        pal: root.pal
                                        colors: root.colorsFor(gDelegate.modelData.path)
                                        capsule: false
                                        size: 8
                                        slots: 0
                                        anchors.right: parent.right
                                        anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        anchors.rightMargin: 84
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
