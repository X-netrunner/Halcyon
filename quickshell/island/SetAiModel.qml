import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "aiModel" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: am
    width: parent ? parent.width : 0
    spacing: 10
    property bool menu: false
    readonly property var pull: root.ai.pull
    readonly property bool pulling: !!pull && !pull.done
    readonly property var rows: {
        var r = [], ins = root.ai.installed || [], cat = root.ai.catalog || []
        r.push({ k: "head", t: "Installed on this PC  (click to use)" })
        if (!ins.length) r.push({ k: "note", t: root.ai.ollama === false ? "Ollama is not installed: pacman -S ollama" : "nothing downloaded yet" })
        for (var i = 0; i < ins.length; i++) r.push({ k: "inst", n: ins[i].name, gb: ins[i].gb })
        var src = root.ai.source === "online" ? "just fetched from ollama.com" : root.ai.source === "cache" ? "from ollama.com, saved earlier" : "built-in list, you are offline"
        r.push({ k: "head", t: "Online  (click to download and use)  -  " + src })
        for (var j = 0; j < cat.length; j++) if (!cat[j].installed) r.push({ k: "cat", n: cat[j].name, gb: cat[j].gb, fits: cat[j].fits, best: cat[j].best, d: cat[j].desc, caps: cat[j].caps, pulls: cat[j].pulls })
        return r
    }

    Text { text: "AI advisor model"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Rectangle {
            Layout.fillWidth: true
            height: 38; radius: 19
            color: Qt.alpha(root.pal.surface, 0.8)
            border.width: 1
            border.color: am.menu ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
            Text {
                anchors.verticalCenter: parent.verticalCenter
                x: 16; width: parent.width - 48
                elide: Text.ElideRight
                text: root.ai.current !== "" ? root.ai.current : "no model yet"
                color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right; anchors.rightMargin: 16
                text: am.menu ? "\u25b4" : "\u25be"
                color: root.pal.muted; font.pixelSize: 14
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { am.menu = !am.menu; if (am.menu) root.aiLoad(false) } }
        }
        SChip { pal: root.pal; label: "Refresh list"; onClicked: root.aiLoad(true) }
    }
    Text {
        Layout.fillWidth: true
        visible: root.ai.ollama !== false && root.ai.running === false
        text: "Ollama is installed but not running. Downloading a model starts it, or: systemctl start ollama"
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        visible: !!root.ai.envOverride
        text: "HALCYON_AI_MODEL is set in your environment and overrides this choice."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap
    }

    // download in progress
    ColumnLayout {
        Layout.fillWidth: true
        visible: !!am.pull && (am.pulling || am.pull.error !== "" || am.pull.used)
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: !am.pull ? "" : am.pulling ? "Downloading " + am.pull.name + "  " + am.pull.pct + " %" : am.pull.error !== "" ? am.pull.name + ": " + am.pull.error : am.pull.name + " is ready and in use"
                color: (am.pull && !am.pulling && am.pull.error !== "") ? root.pal.bad : root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
            }
            SChip { visible: am.pulling; pal: root.pal; label: "Cancel"; onClicked: root.aiCancel() }
        }
        Rectangle {
            visible: am.pulling
            Layout.fillWidth: true
            height: 6; radius: 3; color: root.pal.lineSoft
            Rectangle { width: parent.width * Math.max(0.02, (am.pull ? am.pull.pct : 0) / 100); height: parent.height; radius: 3; color: root.pal.accent; Behavior on width { NumberAnimation { duration: 300 } } }
        }
    }

    // the drop-down: installed first, then the online catalog
    Rectangle {
        visible: am.menu
        Layout.fillWidth: true
        height: Math.min(320, menuCol.implicitHeight + 12)
        radius: 14
        color: Qt.alpha(root.pal.surface, 0.9)
        border.width: 1; border.color: root.pal.lineSoft
        clip: true
        Flickable {
            anchors.fill: parent; anchors.margins: 6
            contentHeight: menuCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: menuCol
                width: parent.width
                spacing: 2
                Repeater {
                    model: am.rows
                    delegate: Rectangle {
                        id: mr
                        required property var modelData
                        readonly property bool head: modelData.k === "head" || modelData.k === "note"
                        readonly property bool isCur: modelData.k === "inst" && modelData.n === root.ai.current
                        readonly property bool blocked: modelData.k === "cat" && am.pulling
                        width: menuCol.width
                        height: head ? 28 : 44
                        radius: 9
                        color: (!head && !blocked && mma.containsMouse) ? Qt.alpha(root.pal.accent, 0.14) : (isCur ? Qt.alpha(root.pal.accent, 0.10) : "transparent")
                        opacity: blocked ? 0.45 : 1
                        Text {
                            visible: mr.head
                            anchors.verticalCenter: parent.verticalCenter
                            x: 10; width: parent.width - 20; elide: Text.ElideRight
                            text: modelData.t || ""
                            color: modelData.k === "head" ? root.pal.accent : root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: 11; font.bold: modelData.k === "head"
                        }
                        Column {
                            visible: !mr.head
                            anchors.verticalCenter: parent.verticalCenter
                            x: 12; width: parent.width - 150; spacing: 2
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: (mr.isCur ? "\u2713  " : "") + (modelData.n || "") + (modelData.best ? "   \u2605 best for this PC" : "")
                                color: mr.isCur ? root.pal.accent : root.pal.text
                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.bold: mr.isCur
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                visible: modelData.k === "cat"
                                text: (modelData.d || "") + ((modelData.caps && modelData.caps.length) ? "  [" + modelData.caps.join(", ") + "]" : "")
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                            }
                        }
                        Text {
                            visible: !mr.head
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right; anchors.rightMargin: 12
                            horizontalAlignment: Text.AlignRight
                            text: modelData.k === "inst" ? (modelData.gb ? modelData.gb + " GB" : "")
                                  : ((modelData.gb ? "~" + modelData.gb + " GB" : "") + (modelData.fits === false ? "   heavy for this PC" : "") + (modelData.pulls ? "   " + modelData.pulls : ""))
                            color: modelData.fits === false ? root.pal.warn : root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: 11
                        }
                        MouseArea {
                            id: mma
                            anchors.fill: parent
                            enabled: !mr.head && !mr.blocked
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (modelData.k === "inst") root.aiUse(modelData.n)
                                else root.aiPull(modelData.n)
                                am.menu = false
                            }
                        }
                    }
                }
            }
        }
    }
    Text {
        Layout.fillWidth: true
        text: "Used by the AI / LLM Advisor and the `ai` command. Bigger models answer better but need more memory: sizes are estimates for the usual 4-bit download, and the list is sorted so what fits this PC comes first. Downloads keep going if you close Settings."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    component SChip: Chip { maxLabel: 1000 }
}
