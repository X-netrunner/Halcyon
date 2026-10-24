import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "discover" (Settings > Discover): everything Halcyon can do, one line each, a click shows the rest.
// It reads features.json, the same file the guided tour is built from, so a feature announced there shows up here too.
// Entries that are new since the tour was last seen (state/island/features.seen.json) get a "New" mark.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: dv
    width: parent ? parent.width : 0
    spacing: 4

    readonly property var pal: root ? root.pal : null
    property var feats: []
    property var seenIds: ({})
    property bool seenRead: false
    property string openId: ""

    FileView {
        path: Quickshell.shellDir + "/features.json"
        onLoaded: {
            try {
                var d = JSON.parse(text())
                dv.feats = (d.features || []).filter(function (f) { return f.id !== "hello" && f.id !== "done" })
            } catch (e) { dv.feats = [] }
        }
    }
    FileView {
        path: Quickshell.env("HOME") + "/.local/state/island/features.seen.json"
        onLoaded: {
            try {
                var m = {}
                ;(JSON.parse(text()).features || []).forEach(function (f) { m[f.id] = f.rev || 1 })
                dv.seenIds = m
                dv.seenRead = true
            } catch (e) { }
        }
    }
    function isNew(f) { return seenRead && (seenIds[f.id] === undefined || seenIds[f.id] < (f.rev || 1)) }
    // a body's first sentence, the rest on a click
    function lead(b) {
        var m = String(b || "").match(/^.{20,170}?[.!?](\s|$)/)
        return m ? m[0].trim() : String(b || "")
    }

    Repeater {
        model: dv.feats
        delegate: Rectangle {
            id: row
            required property var modelData
            readonly property bool expanded: dv.openId === modelData.id
            Layout.fillWidth: true
            implicitHeight: rc.implicitHeight + 18
            radius: dv.pal ? dv.pal.rMd : 12
            color: rowMa.containsMouse || expanded ? Qt.alpha(dv.pal.text, 0.05) : "transparent"
            ColumnLayout {
                id: rc
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9; leftMargin: 12; rightMargin: 12 }
                spacing: 3
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: row.modelData.title
                        color: dv.pal.text
                        font.family: dv.pal.uiFont
                        font.pixelSize: dv.pal.tBody
                        font.weight: Font.Medium
                    }
                    Repeater {
                        model: row.modelData.keys || []
                        delegate: Rectangle {
                            required property var modelData
                            implicitWidth: kt.implicitWidth + 12
                            implicitHeight: 20
                            radius: 5
                            color: Qt.alpha(dv.pal.text, 0.07)
                            border.width: dv.pal.bw
                            border.color: Qt.alpha(dv.pal.text, 0.12)
                            Text { id: kt; anchors.centerIn: parent; text: modelData; color: dv.pal.muted; font.family: dv.pal.mono || dv.pal.font; font.pixelSize: 10 }
                        }
                    }
                    Rectangle {
                        visible: dv.isNew(row.modelData)
                        implicitWidth: nt.implicitWidth + 14
                        implicitHeight: 20
                        radius: 10
                        color: Qt.alpha(dv.pal.accent, 0.2)
                        Text { id: nt; anchors.centerIn: parent; text: "New"; color: dv.pal.accent; font.family: dv.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    // the new style lists the titles only; a click opens the whole text
                    visible: row.expanded || !(dv.pal.zen && dv.pal.hideHints)
                    wrapMode: Text.WordWrap
                    text: row.expanded ? row.modelData.body : dv.lead(row.modelData.body)
                    color: dv.pal.muted
                    font.family: dv.pal.uiFont
                    font.pixelSize: dv.pal.tCap + 1
                    lineHeight: 1.15
                }
            }
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: dv.openId = row.expanded ? "" : row.modelData.id
            }
        }
    }
}
