import QtQuick
import QtQuick.Layouts
import Quickshell

// A small "pick one of your installed apps" menu: a search box and a scrollable list of every app that has a launcher entry
// (the same list the app launcher uses). Click one and `picked(app)` fires with
//   app = { name, id, cls, bin, cmd, icon }
//   cls  the window class to expect (what `hyprctl clients` shows): the entry's StartupWMClass, else its desktop id
//   bin  the program's file name when it is a useful second guess for the class ("" for flatpak / env / sh wrappers)
//   cmd  a shell command that starts it (terminal apps are wrapped so they open in your terminal)
// Used by Settings > Focus mode (block an app that is not open right now) and by the shortcut editor (bind a key to an app).
ColumnLayout {
    id: root
    property var pal
    property string placeholder: "Search your apps…"
    property var exclude: []           // window classes (lower case) to leave out, e.g. the ones already blocked
    property int rows: 6               // rows visible at once; the list scrolls
    signal picked(var app)

    spacing: 6

    property string query: ""
    property var results: []

    readonly property var generic: ["env", "sh", "bash", "zsh", "fish", "flatpak", "snap", "gtk-launch", "xdg-open", "python", "python3", "java", "appimage", "uwsm", "uwsm-app"]

    // one argument, quoted for sh -c only when it needs it
    function shq(a) { return /^[A-Za-z0-9_@%+=:,.\/-]+$/.test(a) ? a : "'" + String(a).replace(/'/g, "'\\''") + "'" }

    function info(e) {
        var args = e.command || []
        if (!args || args.length === 0) return null
        var parts = []
        for (var i = 0; i < args.length; i++) parts.push(shq(args[i]))
        var cmd = parts.join(" ")
        if (e.runInTerminal) cmd = "bash $HOME/.config/Halcyon/scripts/apps.sh term-exec " + cmd
        var id = String(e.id || "").replace(/\.desktop$/, "")
        var bin = String(args[0] || "").split("/").pop()
        if (generic.indexOf(bin.toLowerCase()) >= 0) bin = ""
        return { name: e.name || id, id: id, cls: e.startupClass || id, bin: bin, cmd: cmd, icon: e.icon || "" }
    }

    function refresh() {
        var apps = DesktopEntries.applications.values
        var q = query.trim().toLowerCase()
        var out = []
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i]
            if (a.noDisplay) continue
            var d = info(a)
            if (!d || d.cls === "") continue
            if (exclude.indexOf(d.cls.toLowerCase()) >= 0) continue
            if (q !== "" && (d.name + " " + d.id + " " + d.bin).toLowerCase().indexOf(q) < 0) continue
            out.push(d)
        }
        out.sort(function (x, y) { return x.name.toLowerCase().localeCompare(y.name.toLowerCase()) })
        results = out
    }
    function iconFor(ic) {
        if (!ic) return Quickshell.iconPath("application-x-executable")
        if (ic.indexOf("/") === 0) return "file://" + ic
        return Quickshell.iconPath(ic, "application-x-executable")
    }

    onQueryChanged: refresh()
    onExcludeChanged: refresh()
    Component.onCompleted: refresh()
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { refreshT.restart() }
    }
    Timer { id: refreshT; interval: 150; onTriggered: root.refresh() }

    // search box
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 30
        radius: 10
        color: Qt.alpha(root.pal.bg, 0.55)
        border.width: 1
        border.color: apIn.activeFocus ? root.pal.lineFocus : root.pal.line
        Text {
            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
            visible: apIn.text === "" && !apIn.activeFocus
            text: root.placeholder
            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
        }
        TextInput {
            id: apIn
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: root.pal.text
            selectionColor: Qt.alpha(root.pal.accent, 0.4)
            selectedTextColor: root.pal.text
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
            clip: true
            selectByMouse: true
            onTextChanged: root.query = text
            onAccepted: { if (root.results.length > 0) root.picked(root.results[0]) }
        }
    }

    // the list
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: root.rows * 34 + 8
        radius: 10
        color: Qt.alpha(root.pal.bg, 0.35)
        border.width: 1
        border.color: root.pal.lineSoft
        clip: true

        ListView {
            id: list
            anchors.fill: parent
            anchors.margins: 4
            model: root.results
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            delegate: Rectangle {
                id: row
                required property var modelData
                width: list.width
                height: 34
                radius: 8
                color: rowMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.8) : "transparent"
                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                Image {
                    id: ic
                    anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                    width: 20; height: 20
                    sourceSize: Qt.size(40, 40)
                    source: root.iconFor(row.modelData.icon)
                    asynchronous: true
                    smooth: true
                }
                Text {
                    anchors.left: ic.right; anchors.leftMargin: 10
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.name
                    elide: Text.ElideRight
                    color: root.pal.text
                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(row.modelData)
                }
            }
        }
        Text {
            anchors.centerIn: parent
            visible: root.results.length === 0
            text: root.query === "" ? "no apps found" : "no app matches “" + root.query + "”"
            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
        }
    }
}
