import QtQuick
import QtQuick.Layouts
import Quickshell

// The options an app puts in its own tray menu (Open, Settings, Quit, ...), drawn in the island's style.
// `handle` is a tray item's `menu` (QsMenuHandle) or a menu entry that has a submenu. Entries that open a submenu
// expand in place. `done()` is emitted after an entry ran, so the box can close the list again.
Item {
    id: root
    property var pal
    property var handle: null
    property int depth: 0
    property int maxHeight: 250
    signal done()

    implicitHeight: Math.min(list.implicitHeight, maxHeight)
    implicitWidth: 100

    QsMenuOpener { id: opener; menu: root.handle }

    Flickable {
        id: fl
        anchors.fill: parent
        contentHeight: list.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: list
            width: fl.width
            spacing: 2

            Repeater {
                model: opener.children
                delegate: Column {
                    id: entryCol
                    required property var modelData
                    width: list.width
                    property bool open: false
                    readonly property bool sep: modelData.isSeparator
                    readonly property bool quit: /^\s*(&?q)uit|^\s*(&?e)xit|^\s*close\b/i.test(String(modelData.text || "").replace(/_/g, ""))

                    Rectangle {
                        visible: entryCol.sep
                        width: parent.width - 16; x: 8
                        height: 9
                        color: "transparent"
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 1; color: root.pal.lineSoft }
                    }

                    Rectangle {
                        id: row
                        visible: !entryCol.sep
                        width: parent.width
                        height: 34
                        radius: root.pal.rMd
                        color: ma.pressed ? root.pal.surfaceHi : (ma.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.8) : "transparent")
                        opacity: entryCol.modelData.enabled ? 1 : 0.4
                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }

                        Text {
                            id: mark
                            x: 10 + root.depth * 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            // check / radio state the app reports
                            text: entryCol.modelData.checkState === Qt.Checked ? "●" : ""
                            color: root.pal.accent
                            font.pixelSize: 9
                        }
                        Text {
                            anchors.left: mark.right; anchors.leftMargin: 4
                            anchors.right: arrow.left; anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: String(entryCol.modelData.text || "").replace(/_(.)/g, "$1")
                            color: entryCol.quit ? Qt.lighter("#e06c75", 1.1) : root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                        }
                        Text {
                            id: arrow
                            anchors.right: parent.right; anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            visible: entryCol.modelData.hasChildren
                            text: entryCol.open ? "▾" : "▸"
                            color: root.pal.muted
                            font.pixelSize: 11
                        }
                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: entryCol.modelData.enabled
                            onClicked: {
                                if (entryCol.modelData.hasChildren) entryCol.open = !entryCol.open
                                else { entryCol.modelData.triggered(); root.done() }
                            }
                        }
                    }

                    Loader {
                        active: entryCol.open && entryCol.modelData.hasChildren
                        width: parent.width
                        height: item ? item.implicitHeight : 0
                        source: "TrayMenu.qml"
                        onLoaded: {
                            item.pal = root.pal
                            item.handle = entryCol.modelData
                            item.depth = root.depth + 1
                            item.maxHeight = 180
                            item.done.connect(root.done)
                        }
                    }
                }
            }
        }
    }
}
