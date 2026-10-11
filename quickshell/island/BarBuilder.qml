import QtQuick
import QtQuick.Layouts
import "BarLayout.js" as BL

// Settings > Bar style > Bar builder (only while Style = Custom): a small picture of the bar as it is now and the button that opens the
// builder window (BarBuilderWindow.qml, where widgets are dragged into place). The picture follows every change at once.
ColumnLayout {
    id: bb
    property var pal
    property var layout: null                  // opt.barLayout (anything: it is cleaned up here)
    signal edited(var layout)
    signal openRequested()

    readonly property var cur: BL.normalize(layout)
    readonly property var zoneInfo: [
        { k: "left", t: "Left" },
        { k: "center", t: "Middle" },
        { k: "right", t: "Right" }
    ]

    width: parent ? parent.width : 0
    spacing: 12

    Text {
        Layout.fillWidth: true
        text: "Build your own bar: pick what it shows and where. The builder opens in its own window: drag a widget onto Left, Middle or Right, drag it along to reorder it, drop it on the shelf to take it off. Colours, spacing, Wi-Fi look and Bluetooth mode come from the options below."
        color: bb.pal.muted
        font.family: bb.pal.uiFont
        font.pixelSize: 10
        lineHeight: 1.3
        wrapMode: Text.WordWrap
    }

    // ---- a small picture of the bar as it is now
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: pvRow.implicitHeight + 20
        radius: 14
        color: Qt.alpha(bb.pal.bg, 0.55)
        border.width: 1
        border.color: Qt.alpha(bb.pal.accent, 0.25)
        RowLayout {
            id: pvRow
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8
            Repeater {
                model: bb.zoneInfo
                delegate: Flow {
                    id: pvZone
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 4
                    layoutDirection: modelData.k === "right" ? Qt.RightToLeft : Qt.LeftToRight
                    Repeater {
                        model: bb.cur[pvZone.modelData.k]
                        delegate: Rectangle {
                            required property string modelData
                            width: pvT.implicitWidth + 12
                            height: 20
                            radius: 10
                            color: Qt.alpha(bb.pal.accent, 0.20)
                            Text {
                                id: pvT
                                anchors.centerIn: parent
                                text: BL.shortOf(parent.modelData)
                                color: bb.pal.text
                                font.family: bb.pal.uiFont
                                font.pixelSize: 10
                            }
                        }
                    }
                    Text {
                        visible: bb.cur[pvZone.modelData.k].length === 0
                        text: "empty"
                        color: bb.pal.muted
                        font.family: bb.pal.uiFont
                        font.pixelSize: 10
                        font.italic: true
                    }
                }
            }
        }
    }

    Flow {
        Layout.fillWidth: true
        spacing: 12
        ActionChip { pal: bb.pal; label: "Open the bar builder"; on: true; onClicked: bb.openRequested() }
        ActionChip { pal: bb.pal; label: "Reset to the default layout"; doneLabel: "Reset"; onClicked: bb.edited(BL.defaults()) }
    }
}
