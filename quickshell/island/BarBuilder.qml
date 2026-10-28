import QtQuick
import QtQuick.Layouts
import "BarLayout.js" as BL

// Settings > Bar style > Bar builder (only while Style = Custom): the bar's shape (Notch, Island or Rail), the edge of the screen it sits
// on (Top, Bottom, Left or Right), a small picture of the bar as it is now and the button that opens the builder window
// (BarBuilderWindow.qml, where widgets are dragged into place and the padding is typed). The picture follows every change at once.
ColumnLayout {
    id: bb
    property var pal
    property var layout: null                  // opt.barLayout (anything: it is cleaned up here)
    signal edited(var layout)
    signal openRequested()

    readonly property var cur: BL.normalize(layout)
    // on a Left / Right bar the three places run from the top of the screen to the bottom
    readonly property var zoneInfo: [
        { k: "left", t: BL.zoneTitle(cur, "left") },
        { k: "center", t: BL.zoneTitle(cur, "center") },
        { k: "right", t: BL.zoneTitle(cur, "right") }
    ]

    width: parent ? parent.width : 0
    spacing: 12

    Hint {
        pal: bb.pal
        Layout.fillWidth: true
        text: "Shape, side, widgets and padding of the bar. Drag widgets along it to move them, onto the shelf to remove them."
        color: bb.pal.muted
        fontFamily: bb.pal.uiFont
        pixelSize: 10
    }

    // ---- the shape
    Row {
        spacing: 8
        Text { anchors.verticalCenter: parent.verticalCenter; text: "Shape"; color: bb.pal.muted; font.family: bb.pal.uiFont; font.pixelSize: 11 }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Notch"; on: bb.cur.shape === "notch"; onClicked: bb.edited(BL.setShape(bb.cur, "notch")) }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Island"; on: bb.cur.shape === "island"; onClicked: bb.edited(BL.setShape(bb.cur, "island")) }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Rail"; on: bb.cur.shape === "rail"; onClicked: bb.edited(BL.setShape(bb.cur, "rail")) }
    }

    // ---- the edge of the screen
    Flow {
        Layout.fillWidth: true
        spacing: 8
        Text { height: 30; verticalAlignment: Text.AlignVCenter; text: "Side"; color: bb.pal.muted; font.family: bb.pal.uiFont; font.pixelSize: 11 }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Top"; on: bb.cur.side === "top"; onClicked: bb.edited(BL.setSide(bb.cur, "top")) }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Bottom"; on: bb.cur.side === "bottom"; onClicked: bb.edited(BL.setSide(bb.cur, "bottom")) }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Left"; on: bb.cur.side === "left"; onClicked: bb.edited(BL.setSide(bb.cur, "left")) }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Right"; on: bb.cur.side === "right"; onClicked: bb.edited(BL.setSide(bb.cur, "right")) }
    }

    // ---- the rail: a soft capsule behind every widget, or none
    Row {
        visible: bb.cur.shape === "rail"
        spacing: 8
        Text { anchors.verticalCenter: parent.verticalCenter; text: "Capsules"; color: bb.pal.muted; font.family: bb.pal.uiFont; font.pixelSize: 11 }
        Chip { pal: bb.pal; implicitHeight: 30; label: "Off"; on: !bb.cur.caps; onClicked: bb.edited(BL.setCaps(bb.cur, false)) }
        Chip { pal: bb.pal; implicitHeight: 30; label: "On"; on: bb.cur.caps; onClicked: bb.edited(BL.setCaps(bb.cur, true)) }
    }

    // ---- a small picture of the bar as it is now
    Rectangle {
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
        Layout.fillWidth: true
        spacing: 12
        ActionChip { pal: bb.pal; label: "Open the bar builder"; on: true; onClicked: bb.openRequested() }
        ActionChip { pal: bb.pal; label: "Reset to the default layout"; doneLabel: "Reset"; onClicked: bb.edited(BL.defaults()) }
    }
}
