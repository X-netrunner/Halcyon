import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io

// A .exe browser that lives INSIDE the Game Center window (a file-chooser window would open underneath it: the Game Center is an
// overlay layer). Same idea as ImagePicker.qml, for games:
//   places on the left (Downloads, Games, Home, mounted drives), the folders and .exe files of the current folder on the right
//   type to filter   Up / Down move   Enter opens a folder or picks the .exe   Backspace (empty filter) = parent folder   Esc = cancel
//   "Look in subfolders" lists every .exe below the folder (find, 6 levels, hidden folders and Windows system folders skipped),
//   because a game's program is often a few folders down (Binaries/Win64/...). Uninstallers and redistributables sink to the bottom.
// Use:  ExePicker { anchors.fill: parent; pal: pal; onPicked: path => ...; onCancelled: ... }  then  openAt(pathOrFolder)
Item {
    id: root

    property var pal
    property bool open: false
    property string folderPath: ""
    property bool deep: false               // listing every .exe below folderPath instead of the folder itself
    property string filter: ""
    property int cur: 0
    signal picked(string path)
    signal cancelled()

    readonly property string home: Quickshell.env("HOME")
    readonly property string user: Quickshell.env("USER")

    opacity: open ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.InOutSine } }

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
    function pretty(path) { return path.indexOf(home) === 0 ? "~" + path.substring(home.length) : path }
    function isExe(name) { return /\.exe$/i.test(name) }
    // uninstallers, redistributables, crash reporters: still pickable, listed last and dimmed
    function isHelper(name) {
        return /^(unins\d*|uninstall.*|vc_?redist.*|vcredist.*|dxsetup|dxwebsetup|directx.*|dotnet.*|physx.*|oalinst|ue\dprereqsetup.*|.*crash.*|.*setup.*|.*installer.*|.*redist.*|cefprocess|notification_helper|easyanticheat.*)\.exe$/i.test(name)
    }

    // start = an .exe (its folder is opened), a folder, or nothing (the last folder, else Downloads)
    function openAt(start) {
        var s = expand(start)
        if (s === "") s = home + "/Downloads"
        else if (isExe(s)) s = parentOf(s)
        go(s)
        open = true
        Qt.callLater(function () { fin.forceActiveFocus() })
    }
    function go(path) { deep = false; filter = ""; fin.text = ""; folderPath = path; cur = 0 }
    function goUp() { if (folderPath !== "/") go(parentOf(folderPath)) }
    function lookInside() {
        deep = true; cur = 0; found = []
        deepProc.command = ["sh", "-c", "timeout 10 find \"$1\" -mindepth 1 -maxdepth 6 \\( -name '.*' -o -iname windows -o -iname node_modules \\) -prune -o -type f -iname '*.exe' -print 2>/dev/null | head -n 400", "sh", folderPath]
        deepProc.running = true
    }
    function choose(row) {
        if (!row) return
        if (row.dir) go(row.path)
        else picked(row.path)
    }

    // Games only when ~/Games exists
    FolderListModel { id: homeDirs; folder: root.open ? root.urlOf(root.home) : ""; showFiles: false; showDotAndDotDot: false }
    readonly property var places: {
        var hasGames = false
        for (var i = 0; i < homeDirs.count; i++) if (homeDirs.get(i, "fileName") === "Games") hasGames = true
        var out = [{ label: "Downloads", path: home + "/Downloads", glyph: 0xF01DA }]
        if (hasGames) out.push({ label: "Games", path: home + "/Games", glyph: 0xF0297 })
        out.push({ label: "Home", path: home, glyph: 0xF02DC })
        return out
    }

    // the folder, read by Qt (no process)
    FolderListModel {
        id: fm
        folder: root.open && !root.deep ? root.urlOf(root.folderPath) : ""
        nameFilters: ["*.exe"]
        caseSensitive: false
        showDirs: true
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: false
        sortField: FolderListModel.Name
        onStatusChanged: if (status === FolderListModel.Ready) root.readFolder()
        onCountChanged: if (status === FolderListModel.Ready) root.readFolder()
    }
    // mounted drives: /run/media/<user>/* and /mnt/*
    FolderListModel { id: media; folder: root.open ? "file:///run/media/" + root.user : ""; showFiles: false; showDotAndDotDot: false }
    FolderListModel { id: mnt; folder: root.open ? "file:///mnt" : ""; showFiles: false; showDotAndDotDot: false }
    readonly property var drives: {
        var out = [], i
        for (i = 0; i < media.count; i++) out.push({ label: media.get(i, "fileName"), path: media.get(i, "filePath"), glyph: 0xF02CA })
        for (i = 0; i < mnt.count; i++) out.push({ label: mnt.get(i, "fileName"), path: mnt.get(i, "filePath"), glyph: 0xF02CA })
        return out
    }

    property var entries: []
    function readFolder() {
        var dirs = [], exes = [], helpers = []
        for (var i = 0; i < fm.count; i++) {
            var name = fm.get(i, "fileName"), path = fm.get(i, "filePath")
            if (fm.get(i, "fileIsDir")) dirs.push({ name: name, path: path, dir: true, helper: false, sub: "" })
            else if (isHelper(name)) helpers.push({ name: name, path: path, dir: false, helper: true, sub: "" })
            else exes.push({ name: name, path: path, dir: false, helper: false, sub: "" })
        }
        // the .exe files come first: in a game folder they are what you are looking for
        entries = exes.concat(dirs).concat(helpers)
    }

    property var found: []
    Process {
        id: deepProc
        stdout: StdioCollector {
            onStreamFinished: {
                var good = [], helpers = []
                var base = root.folderPath === "/" ? "/" : root.folderPath + "/"
                text.split("\n").forEach(function (p) {
                    if (p === "") return
                    var name = p.substring(p.lastIndexOf("/") + 1)
                    var rel = p.indexOf(base) === 0 ? p.substring(base.length) : p
                    var row = { name: name, path: p, dir: false, helper: root.isHelper(name), sub: root.parentOf("/" + rel).substring(1) }
                    if (row.helper) helpers.push(row); else good.push(row)
                })
                // shallow ones first: the game's own program is rarely the deepest file
                good.sort(function (a, b) { return a.path.split("/").length - b.path.split("/").length || a.path.localeCompare(b.path) })
                root.found = good.concat(helpers)
            }
        }
    }

    readonly property var rows: {
        var src = deep ? found : entries, f = filter.trim().toLowerCase()
        if (f === "") return src
        return src.filter(function (r) { return (r.sub + "/" + r.name).toLowerCase().indexOf(f) >= 0 })
    }
    readonly property int exeCount: {
        var n = 0
        for (var i = 0; i < entries.length; i++) if (!entries[i].dir && !entries[i].helper) n++
        return n
    }

    // dim the Game Center behind; a click outside the card cancels
    Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.55) }
    MouseArea { anchors.fill: parent; onClicked: root.cancelled() }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 860)
        height: Math.min(parent.height - 80, 560)
        radius: root.pal.rXl
        color: Qt.alpha(root.pal.bg, 0.98)
        border.width: 1
        border.color: Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.97
        Behavior on scale { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        MouseArea { anchors.fill: parent }       // clicks on the card itself do not cancel

        RowLayout {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 16

            // ---- places
            ColumnLayout {
                Layout.preferredWidth: 170
                Layout.maximumWidth: 170
                Layout.fillWidth: false             // a child that fills would otherwise make the whole column fill
                Layout.fillHeight: true
                spacing: 4
                Text {
                    Layout.bottomMargin: 8
                    text: "Choose the game"
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tTitle + 1
                    font.weight: Font.DemiBold
                }
                Repeater {
                    model: root.places.concat(root.drives)
                    delegate: Rectangle {
                        id: pl
                        required property var modelData
                        required property int index
                        readonly property bool here: root.folderPath === modelData.path || root.folderPath.indexOf(modelData.path + "/") === 0 && modelData.path !== root.home
                        Layout.fillWidth: true
                        Layout.topMargin: index === root.places.length ? 10 : 0
                        implicitHeight: 34
                        radius: root.pal.rSm
                        color: here ? Qt.alpha(root.pal.accent, 0.18) : (plMa.containsMouse ? Qt.alpha(root.pal.text, 0.06) : "transparent")
                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        Row {
                            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                            spacing: 10
                            Text { text: String.fromCodePoint(pl.modelData.glyph); color: pl.here ? root.pal.accent : root.pal.muted; font.family: root.pal.font; font.pixelSize: 15; anchors.verticalCenter: parent.verticalCenter }
                            Text { width: 120; elide: Text.ElideRight; text: pl.modelData.label; color: pl.here ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; anchors.verticalCenter: parent.verticalCenter }
                        }
                        MouseArea { id: plMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.go(pl.modelData.path); fin.forceActiveFocus() } }
                    }
                }
                Item { Layout.fillHeight: true }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: "Enter opens  ·  Backspace goes up  ·  Esc cancels"
                    color: Qt.alpha(root.pal.muted, 0.8)
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
            }

            Rectangle { Layout.fillHeight: true; width: 1; color: root.pal.lineSoft }

            // ---- the folder
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    RoundBtn { pal: root.pal; size: 34; glyph: String.fromCodePoint(0xF005D); enabledBtn: root.folderPath !== "/"; onClicked: { root.goUp(); fin.forceActiveFocus() } }
                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideLeft
                        text: root.pretty(root.folderPath)
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody
                        font.weight: Font.Medium
                    }
                    RoundBtn { pal: root.pal; size: 30; glyph: String.fromCodePoint(0xF0156); onClicked: root.cancelled() }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        radius: 18
                        color: Qt.alpha(root.pal.surface, 0.8)
                        border.width: 1
                        border.color: fin.activeFocus ? Qt.alpha(root.pal.accent, 0.7) : root.pal.lineSoft
                        Text {
                            id: fGlyph
                            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                            text: String.fromCodePoint(0xF0349)
                            color: root.pal.muted
                            font.family: root.pal.font
                            font.pixelSize: 14
                        }
                        TextInput {
                            id: fin
                            anchors { left: fGlyph.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 10; rightMargin: 14 }
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            color: root.pal.text
                            selectionColor: Qt.alpha(root.pal.accent, 0.45)
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            onTextChanged: { root.filter = text; root.cur = 0 }
                            Keys.onPressed: e => {
                                var n = root.rows.length
                                if (e.key === Qt.Key_Escape) { if (root.deep) root.go(root.folderPath); else root.cancelled(); e.accepted = true }
                                else if (e.key === Qt.Key_Down) { root.cur = Math.min(n - 1, root.cur + 1); e.accepted = true }
                                else if (e.key === Qt.Key_Up) { root.cur = Math.max(0, root.cur - 1); e.accepted = true }
                                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                    // a typed path: go there (a folder) or take it (an .exe)
                                    var t = root.expand(text)
                                    if (t.indexOf("/") === 0) { if (root.isExe(t)) root.picked(t); else root.go(t) }
                                    else root.choose(root.rows[root.cur])
                                    e.accepted = true
                                }
                                else if (e.key === Qt.Key_Backspace && text === "") { if (root.deep) root.go(root.folderPath); else root.goUp(); e.accepted = true }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: fin.text.length === 0
                                text: root.deep ? "Filter the .exe files found" : "Filter this folder, or type a path"
                                color: root.pal.muted
                                font: fin.font
                            }
                        }
                    }
                    Chip {
                        pal: root.pal
                        implicitHeight: 36
                        glyph: String.fromCodePoint(0xF0968)
                        label: "Look in subfolders"
                        on: root.deep
                        onClicked: { if (root.deep) root.go(root.folderPath); else root.lookInside(); fin.forceActiveFocus() }
                    }
                }

                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.rows
                    currentIndex: root.cur
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool sel: index === root.cur
                        width: ListView.view.width
                        height: modelData.sub !== "" ? 48 : 40
                        radius: root.pal.rSm
                        color: sel ? Qt.alpha(root.pal.accent, 0.16) : (rowMa.containsMouse ? Qt.alpha(root.pal.text, 0.05) : "transparent")
                        opacity: modelData.helper ? 0.55 : 1
                        Text {
                            id: rg
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            text: String.fromCodePoint(row.modelData.dir ? 0xF024B : 0xF0297)
                            color: row.modelData.dir ? Qt.alpha(root.pal.accent, 0.75) : root.pal.accent
                            font.family: root.pal.font
                            font.pixelSize: 17
                        }
                        Column {
                            anchors { left: rg.right; right: tag.left; leftMargin: 12; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            spacing: 1
                            Text { width: parent.width; elide: Text.ElideMiddle; text: row.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: row.modelData.dir ? Font.Normal : Font.Medium }
                            Text { width: parent.width; visible: row.modelData.sub !== ""; elide: Text.ElideMiddle; text: row.modelData.sub; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                        }
                        Text {
                            id: tag
                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            text: row.modelData.dir ? String.fromCodePoint(0xF0142) : (row.modelData.helper ? "helper" : (row.sel ? "Enter to choose" : ""))
                            color: root.pal.muted
                            font.family: row.modelData.dir ? root.pal.font : root.pal.uiFont
                            font.pixelSize: row.modelData.dir ? 14 : root.pal.tCap
                        }
                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.cur = row.index; root.choose(row.modelData); fin.forceActiveFocus() }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        width: Math.min(360, parent.width - 40)
                        spacing: 12
                        visible: root.rows.length === 0
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: root.deep ? (deepProc.running ? "Looking through the subfolders" : "No .exe below this folder")
                                            : (root.filter !== "" ? "Nothing here matches that" : "No .exe files or folders here")
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                        }
                    }
                }

                // a folder with no .exe of its own: offer the deep search (the game's program is often a few folders down)
                Rectangle {
                    Layout.fillWidth: true
                    visible: !root.deep && root.exeCount === 0 && root.entries.length > 0 && root.folderPath !== root.home && root.folderPath !== "/"
                    implicitHeight: 44
                    radius: root.pal.rMd
                    color: hintMa.containsMouse ? Qt.alpha(root.pal.accent, 0.16) : Qt.alpha(root.pal.accent, 0.08)
                    border.width: 1
                    border.color: Qt.alpha(root.pal.accent, 0.3)
                    Text {
                        anchors.centerIn: parent
                        text: "No .exe in this folder.  Look in its subfolders"
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody
                    }
                    MouseArea { id: hintMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.lookInside(); fin.forceActiveFocus() } }
                }
            }
        }
    }
}
