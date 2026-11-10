import QtQuick
import QtQuick.Layouts
import "BarLayout.js" as BL

// Settings > Bar, last row: a small picture of the bar as it is now, the button that opens the builder window (BarBuilderWindow.qml,
// where widgets are dragged into place and the padding is typed) and Reset. Shape, edge, rail look, capsules, special workspaces and
// the Performance tab look are ordinary rows of Settings > Bar now (drop-down menus; the `bl:` keys of Settings.qml), so nothing
// is set twice. The picture follows every change at once.
ColumnLayout {
    id: bb
    property var pal
    property var layout: null                  // opt.barLayout (anything: it is cleaned up here)
    property string barStyle: "island"        // opt.barStyle: only Rail and Custom bars have a layout to edit
    signal edited(var layout)
    signal openRequested()

    readonly property bool editable: barStyle === "rail" || barStyle === "custom"
    readonly property var cur: BL.normalize(layout)
    // on a Left / Right bar the three places run from the top of the screen to the bottom
    readonly property var zoneInfo: [
        { k: "left", t: BL.zoneTitle(cur, "left") },
        { k: "center", t: BL.zoneTitle(cur, "center") },
        { k: "right", t: BL.zoneTitle(cur, "right") }
    ]

    width: parent ? parent.width : 0
    spacing: 12

    Text {
        visible: !bb.editable
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "The present bar is the " + bb.barStyle + ": it has no layout to edit. Set Style to Rail or Custom to place the widgets yourself."
        color: bb.pal.muted
        font.family: bb.pal.uiFont
        font.pixelSize: 11
    }

    // a small picture of the bar as it is now
    Rectangle {
        visible: bb.editable
        Layout.fillWidth: true
        implicitHeight: pvRow.implicitHeight + 20
        radius: bb.cur.shape === "island" ? implicitHeight / 2 : 14
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
        visible: bb.editable
        Layout.fillWidth: true
        spacing: 12
        ActionChip { pal: bb.pal; label: "Open the bar builder"; on: true; onClicked: bb.openRequested() }
        ActionChip { pal: bb.pal; label: "Reset to the default layout"; doneLabel: "Reset"; onClicked: bb.edited(BL.defaults()) }
    }
}
