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
    readonly property var pull: (root && root.ai) ? root.ai.pull : null
    readonly property bool pulling: !!pull && !pull.done
    readonly property var rows: {
        if (!root || !root.ai) return []
        var r = [], ins = root.ai.installed || [], cat = root.ai.catalog || []
        r.push({ k: "head", t: "Installed on this PC  (click to use)" })
        if (!ins.length) r.push({ k: "note", t: root.ai.ollama === false ? "Ollama is not installed: pacman -S ollama" : "nothing downloaded yet" })
        for (var i = 0; i < ins.length; i++) r.push({ k: "inst", n: ins[i].name, gb: ins[i].gb })
        var src = root.ai.source === "online" ? "just fetched from ollama.com" : root.ai.source === "cache" ? "from ollama.com, saved earlier" : "built-in list, you are offline"
        r.push({ k: "head", t: "Online  (click to download and use)  -  " + src })
        for (var j = 0; j < cat.length; j++) if (!cat[j].installed) r.push({ k: "cat", n: cat[j].name, gb: cat[j].gb, fits: cat[j].fits, best: cat[j].best, d: cat[j].desc, caps: cat[j].caps, pulls: cat[j].pulls })
        return r
    }

    Text {
        text: "AI advisor model"
        color: root && root.pal ? root.pal.text : "#ffffff"
        font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
        font.pixelSize: root && root.pal ? root.pal.tBody : 13
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Rectangle {
            Layout.fillWidth: true
            height: 38; radius: 19
            color: root && root.pal ? Qt.alpha(root.pal.surface, 0.8) : "#1c1c1c"
            border.width: 1
            border.color: am.menu ? (root && root.pal ? Qt.alpha(root.pal.accent, 0.5) : "#888888") : (root && root.pal ? root.pal.lineSoft : "#333333")
            Text {
                anchors.verticalCenter: parent.verticalCenter
                x: 16; width: parent.width - 48
                elide: Text.ElideRight
                text: (root && root.ai && root.ai.current) ? root.ai.current : "no model yet"
                color: root && root.pal ? root.pal.text : "#ffffff"
                font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
                font.pixelSize: root && root.pal ? root.pal.tBody : 13
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right; anchors.rightMargin: 16
                text: am.menu ? "\u25b4" : "\u25be"
                color: root && root.pal ? root.pal.muted : "#888888"
                font.pixelSize: 14
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    am.menu = !am.menu
                    if (am.menu && root && typeof root.aiLoad === "function") root.aiLoad(false)
                }
            }
        }
        SChip {
            pal: root ? root.pal : null
            label: "Refresh list"
            onClicked: { if (root && typeof root.aiLoad === "function") root.aiLoad(true) }
        }
    }
    Text {
        Layout.fillWidth: true
        visible: !!(root && root.ai && root.ai.ollama !== false && root.ai.running === false)
        text: "Ollama is installed but not running. Downloading a model starts it, or: systemctl start ollama"
        color: root && root.pal ? root.pal.muted : "#888888"
        font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
        font.pixelSize: 11
        wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        visible: !!(root && root.ai && root.ai.envOverride)
        text: "HALCYON_AI_MODEL is set in your environment and overrides this choice."
        color: root && root.pal ? root.pal.muted : "#888888"
        font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
        font.pixelSize: 11
        wrapMode: Text.WordWrap
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
                wrapMode: Text.Wrap
                text: !am.pull ? "" : am.pulling ? "Downloading " + am.pull.name + "  " + am.pull.pct + " %" : am.pull.error !== "" ? am.pull.name + ": " + am.pull.error : am.pull.name + " is ready and in use"
                color: (am.pull && !am.pulling && am.pull.error !== "") ? (root && root.pal ? root.pal.bad : "red") : (root && root.pal ? root.pal.text : "#ffffff")
                font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
                font.pixelSize: root && root.pal ? root.pal.tBody : 13
            }
            SChip {
                visible: am.pulling
                pal: root ? root.pal : null
                label: "Cancel"
                onClicked: { if (root && typeof root.aiCancel === "function") root.aiCancel() }
            }
        }
        Rectangle {
            visible: am.pulling
            Layout.fillWidth: true
            height: 6; radius: 3
            color: root && root.pal ? root.pal.lineSoft : "#333333"
            Rectangle {
                width: parent.width * Math.max(0.02, (am.pull ? am.pull.pct : 0) / 100)
                height: parent.height; radius: 3
                color: root && root.pal ? root.pal.accent : "#00bcd4"
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            }
        }
    }

    // the drop-down: installed first, then the online catalog
    Rectangle {
        visible: am.menu
        Layout.fillWidth: true
        height: Math.min(320, menuCol.implicitHeight + 12)
        radius: 14
        color: root && root.pal ? Qt.alpha(root.pal.surface, 0.95) : "#1c1c1c"
        border.width: 1
        border.color: root && root.pal ? root.pal.lineSoft : "#333333"
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
                        readonly property bool isCur: modelData.k === "inst" && modelData.n === (root && root.ai ? root.ai.current : "")
                        readonly property bool blocked: modelData.k === "cat" && am.pulling
                        width: menuCol.width
                        height: head ? 28 : (modelData.k === "cat" && modelData.d ? 50 : 38)
                        radius: 9
                        color: (!head && !blocked && mma.containsMouse) ? (root && root.pal ? Qt.alpha(root.pal.accent, 0.14) : "#333") : (isCur ? (root && root.pal ? Qt.alpha(root.pal.accent, 0.10) : "#222") : "transparent")
                        opacity: blocked ? 0.45 : 1

                        Text {
                            visible: mr.head
                            anchors.verticalCenter: parent.verticalCenter
                            x: 10; width: parent.width - 20; elide: Text.ElideRight
                            text: modelData.t || ""
                            color: modelData.k === "head" ? (root && root.pal ? root.pal.accent : "#00bcd4") : (root && root.pal ? root.pal.muted : "#888888")
                            font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
                            font.pixelSize: 11; font.bold: modelData.k === "head"
                        }

                        Text {
                            id: rightTxt
                            visible: !mr.head
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right; anchors.rightMargin: 12
                            horizontalAlignment: Text.AlignRight
                            text: modelData.k === "inst" ? (modelData.gb ? modelData.gb + " GB" : "")
                                  : ((modelData.gb ? "~" + modelData.gb + " GB" : "") + (modelData.fits === false ? "   heavy for this PC" : "") + (modelData.pulls ? "   " + modelData.pulls : ""))
                            color: modelData.fits === false ? (root && root.pal ? root.pal.warn : "#e65100") : (root && root.pal ? root.pal.muted : "#888888")
                            font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
                            font.pixelSize: 11
                        }

                        Column {
                            visible: !mr.head
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.leftMargin: 12
                            anchors.right: rightTxt.left; anchors.rightMargin: 10
                            spacing: 2
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: (mr.isCur ? "\u2713  " : "") + (modelData.n || "") + (modelData.best ? "   \u2605 best for this PC" : "")
                                color: mr.isCur ? (root && root.pal ? root.pal.accent : "#00bcd4") : (root && root.pal ? root.pal.text : "#ffffff")
                                font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
                                font.pixelSize: root && root.pal ? root.pal.tBody : 13
                                font.bold: mr.isCur
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                visible: modelData.k === "cat" && !!modelData.d
                                text: (modelData.d || "") + ((modelData.caps && modelData.caps.length) ? "  [" + modelData.caps.join(", ") + "]" : "")
                                color: root && root.pal ? root.pal.muted : "#888888"
                                font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
                                font.pixelSize: 10
                            }
                        }

                        MouseArea {
                            id: mma
                            anchors.fill: parent
                            enabled: !mr.head && !mr.blocked
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root) {
                                    if (modelData.k === "inst") root.aiUse(modelData.n)
                                    else root.aiPull(modelData.n)
                                }
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
        color: root && root.pal ? root.pal.muted : "#888888"
        font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
        font.pixelSize: 10
        wrapMode: Text.WordWrap
    }
    component SChip: Chip { maxLabel: 1000 }
}
