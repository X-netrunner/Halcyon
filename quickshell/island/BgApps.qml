import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Routes.js" as Routes

// Bottom-left box: the apps that keep running after you close their window (Spotify, Discord, ...).
// Each running app shows whether it still has a window or only lives in the background, with Open and Quit.
// Apps that are not running are offered as small "start" chips. The list of known apps is Routes.js.
Glass {
    id: root
    property bool active: false             // the box is open (set by shell.qml); polls faster then
    readonly property int count: running.length
    property var rows: []                    // [{ app, running, wins, ws }]
    readonly property var running: rows.filter(function (r) { return r.running })
    readonly property var stopped: rows.filter(function (r) { return !r.running })

    width: pal.boxW
    height: implicitHeight
    implicitHeight: col.implicitHeight + 2 * pad
    readonly property int pad: pal.boxPad
    radius: pal.rXl
    opacityBody: pal.glassSolid - 0.06

    readonly property string home: Quickshell.env("HOME")
    property var procLines: []
    property var clients: []

    function refresh() {
        if (!psProc.running) psProc.running = true
        if (!clientsProc.running) clientsProc.running = true
    }
    function rebuild() {
        var out = []
        for (var i = 0; i < Routes.apps.length; i++) {
            var app = Routes.apps[i]
            var re = new RegExp(app.match)
            var run = false
            for (var k = 0; k < procLines.length; k++) if (re.test(procLines[k])) { run = true; break }
            var wins = [], ws = ""
            for (var j = 0; j < clients.length; j++) {
                var c = clients[j]
                if (app.classes.indexOf(String(c["class"] || "").toLowerCase()) >= 0) {
                    wins.push(c)
                    if (ws === "" && c.workspace) ws = c.workspace.name
                }
            }
            out.push({ app: app, running: run || wins.length > 0, wins: wins.length, ws: ws })
        }
        rows = out
    }
    Process {
        id: psProc
        command: ["ps", "-u", Quickshell.env("USER"), "-o", "args="]
        stdout: StdioCollector { onStreamFinished: { root.procLines = text.split("\n").filter(function (l) { return l.indexOf("--type=") < 0 }); root.rebuild() } }
    }
    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector { onStreamFinished: { try { root.clients = JSON.parse(text) } catch (e) { root.clients = [] } root.rebuild() } }
    }
    // quick while the box is open, slow in the background (it feeds the little count on the corner)
    Timer { interval: root.active ? 2000 : 8000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    onActiveChanged: if (active) refresh()

    function openApp(app) {
        Quickshell.execDetached(["env", "SPECIAL_CMD=" + app.cmd, "bash", home + "/.config/Halcyon/scripts/special.sh", app.ws, "--show"])
        later.restart()
    }
    function quitApp(app) {
        Quickshell.execDetached(["pkill", "-f", app.match])
        later.restart()
    }
    function startApp(app) {
        Quickshell.execDetached(["env", "SPECIAL_CMD=" + app.cmd, "bash", home + "/.config/Halcyon/scripts/special.sh", app.ws, "--show"])
        later.restart()
    }
    Timer { id: later; interval: 1400; onTriggered: root.refresh() }

    function where(r) {
        if (r.wins === 0) return "Running in the background"
        var w = r.ws.indexOf("special:") === 0 ? r.ws.substring(8) : "workspace " + r.ws
        return (r.wins > 1 ? r.wins + " windows" : "Window open") + " · " + w
    }

    MouseArea { anchors.fill: parent }      // swallow clicks

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.pad
        spacing: 10

        Text {
            text: "BACKGROUND APPS"
            color: root.pal.muted
            font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4
        }

        Text {
            visible: root.running.length === 0
            Layout.fillWidth: true
            Layout.topMargin: 4; Layout.bottomMargin: 4
            text: "Nothing is running in the background"
            color: Qt.alpha(root.pal.text, 0.55)
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
        }

        Repeater {
            model: root.running
            delegate: Rectangle {
                id: rowItem
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: 56
                radius: root.pal.rMd
                color: Qt.alpha(root.pal.surface, 0.8)
                border.width: 1
                border.color: root.pal.lineSoft

                // alive dot: breathes while the app is up
                Rectangle {
                    id: dot
                    x: 14; anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 4
                    color: rowItem.modelData.wins > 0 ? root.pal.accent : root.pal.accent2
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite; running: root.active && root.pal.motion > 0.3
                        NumberAnimation { to: 0.35; duration: 1400; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1400; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    id: gl
                    anchors.left: dot.right; anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(rowItem.modelData.app.glyph)
                    color: root.pal.text
                    font.family: root.pal.font; font.pixelSize: 20
                }
                Column {
                    anchors.left: gl.right; anchors.leftMargin: 10
                    anchors.right: btns.left; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text {
                        width: parent.width; elide: Text.ElideRight
                        text: rowItem.modelData.app.name
                        color: root.pal.text
                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width; elide: Text.ElideRight
                        text: root.where(rowItem.modelData)
                        color: root.pal.muted
                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                    }
                }
                Row {
                    id: btns
                    anchors.right: parent.right; anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Chip { pal: root.pal; implicitHeight: 28; label: "Open"; on: true; onClicked: root.openApp(rowItem.modelData.app) }
                    Chip { pal: root.pal; implicitHeight: 28; label: "Quit"; onClicked: root.quitApp(rowItem.modelData.app) }
                }
            }
        }

        // apps that are not running: one tap starts them in their own workspace
        Flow {
            visible: root.stopped.length > 0
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 6
            Text {
                text: "START"
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4
                height: 28; verticalAlignment: Text.AlignVCenter
                rightPadding: 4
            }
            Repeater {
                model: root.stopped
                delegate: Chip {
                    required property var modelData
                    pal: root.pal
                    implicitHeight: 28
                    glyph: String.fromCodePoint(modelData.app.glyph)
                    label: modelData.app.name
                    onClicked: root.startApp(modelData.app)
                }
            }
        }
    }
}
