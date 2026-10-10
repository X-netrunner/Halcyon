import QtQuick
import QtQuick.Layouts
import "BarLayout.js" as BL

// Settings > Bar style > Bar builder (only while Style = Custom).
// Three zones (left, middle, right). Each widget can be moved up / down inside its zone, sent to the next zone, or taken off the
// bar; the widgets that are not on the bar sit underneath with one button per zone. Every click is saved and shown at once.
ColumnLayout {
    id: bb
    property var pal
    property var layout: null                  // opt.barLayout (anything: it is cleaned up here)
    signal edited(var layout)

    readonly property var cur: BL.normalize(layout)
    readonly property var zoneInfo: [
        { k: "left", t: "Left", d: "Starts at the left edge of the bar" },
        { k: "center", t: "Middle", d: "Always centred on the screen" },
        { k: "right", t: "Right", d: "Ends at the right edge of the bar" }
    ]
    readonly property var spare: {
        var out = []
        for (var i = 0; i < BL.catalog.length; i++) if (!BL.placed(cur, BL.catalog[i].id)) out.push(BL.catalog[i].id)
        return out
    }

    width: parent ? parent.width : 0
    spacing: 12

    component MiniBtn: Rectangle {
        id: mb
        property string t: ""
        property bool ok: true
        signal clicked()
        implicitWidth: 26
        implicitHeight: 24
        radius: 8
        opacity: ok ? 1 : 0.28
        color: ok && ma.containsMouse ? Qt.alpha(bb.pal.accent, 0.28) : Qt.alpha(bb.pal.text, 0.07)
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            anchors.centerIn: parent
            text: mb.t
            color: bb.pal.text
            font.family: bb.pal.uiFont
            font.pixelSize: 13
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            enabled: mb.ok
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.clicked()
        }
    }

    Text {
        Layout.fillWidth: true
        text: "Build your own bar: pick what it shows and where. Left and right grow from the edges, the middle is always centred. Use the arrows to reorder a widget or send it to the next zone, × takes it off, and the buttons under \"Not on the bar\" put it back. Colours, spacing, Wi-Fi look and Bluetooth mode come from the options below."
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
                    // (a Flow cannot centre its rows, so the middle zone is simply read from the centre line outwards)
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

    // ---- the three zones
    Repeater {
        model: bb.zoneInfo
        delegate: ColumnLayout {
            id: zc
            required property var modelData
            readonly property string zk: modelData.k
            readonly property int zi: BL.zones.indexOf(modelData.k)
            Layout.fillWidth: true
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: zc.modelData.t
                    color: bb.pal.text
                    font.family: bb.pal.uiFont
                    font.pixelSize: bb.pal.tBody
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: zc.modelData.d
                    color: bb.pal.muted
                    font.family: bb.pal.uiFont
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }

            Repeater {
                model: bb.cur[zc.zk]
                delegate: Rectangle {
                    id: row
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 11
                    color: Qt.alpha(bb.pal.surfaceHi, 0.55)
                    border.width: 1
                    border.color: Qt.alpha(bb.pal.line, 0.9)

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 6
                        spacing: 4
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: BL.nameOf(row.modelData)
                                color: bb.pal.text
                                font.family: bb.pal.uiFont
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                        }
                        MiniBtn { t: "‹"; ok: zc.zi > 0; onClicked: bb.edited(BL.hop(bb.cur, zc.zk, row.index, -1)) }
                        MiniBtn { t: "↑"; ok: row.index > 0; onClicked: bb.edited(BL.step(bb.cur, zc.zk, row.index, -1)) }
                        MiniBtn { t: "↓"; ok: row.index < bb.cur[zc.zk].length - 1; onClicked: bb.edited(BL.step(bb.cur, zc.zk, row.index, 1)) }
                        MiniBtn { t: "›"; ok: zc.zi < 2; onClicked: bb.edited(BL.hop(bb.cur, zc.zk, row.index, 1)) }
                        MiniBtn { t: "×"; onClicked: bb.edited(BL.remove(bb.cur, row.modelData)) }
                    }
                }
            }
            Text {
                visible: bb.cur[zc.zk].length === 0
                text: "Nothing here yet."
                color: bb.pal.muted
                font.family: bb.pal.uiFont
                font.pixelSize: 11
                font.italic: true
                leftPadding: 4
            }
        }
    }

    // ---- widgets that are not on the bar
    Text {
        Layout.fillWidth: true
        visible: bb.spare.length > 0
        text: "Not on the bar"
        color: bb.pal.text
        font.family: bb.pal.uiFont
        font.pixelSize: bb.pal.tBody
        font.weight: Font.DemiBold
    }
    Repeater {
        model: bb.spare
        delegate: Rectangle {
            id: sp
            required property string modelData
            Layout.fillWidth: true
            implicitHeight: 40
            radius: 11
            color: Qt.alpha(bb.pal.text, 0.04)
            border.width: 1
            border.color: Qt.alpha(bb.pal.line, 0.7)
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 6
                spacing: 4
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: BL.nameOf(sp.modelData)
                        color: bb.pal.text
                        font.family: bb.pal.uiFont
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: BL.hintOf(sp.modelData)
                        color: bb.pal.muted
                        font.family: bb.pal.uiFont
                        font.pixelSize: 9
                        elide: Text.ElideRight
                    }
                }
                MiniBtn { t: "L"; implicitWidth: 28; onClicked: bb.edited(BL.add(bb.cur, sp.modelData, "left")) }
                MiniBtn { t: "M"; implicitWidth: 28; onClicked: bb.edited(BL.add(bb.cur, sp.modelData, "center")) }
                MiniBtn { t: "R"; implicitWidth: 28; onClicked: bb.edited(BL.add(bb.cur, sp.modelData, "right")) }
            }
        }
    }

    Flow {
        Layout.fillWidth: true
        spacing: 12
        ActionChip { pal: bb.pal; label: "Reset to the default layout"; doneLabel: "Reset"; onClicked: bb.edited(BL.defaults()) }
    }
}
