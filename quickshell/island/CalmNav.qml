import QtQuick
import Quickshell

// The navigation of the calm centres: a floating pill of icon-only segments, in the middle of the window, with the name of the
// open page in one small line under it. Hovering a segment shows its name, so nothing is guessed.
//
//   CalmNav { pal: ...; items: [{ key: "library", glyph: 0x... , label: "Library" }, ...]; current: root.tab; onPicked: ... }
//
// 40 px targets, 2 px between them, the open one is a soft accent wash (no outline, no underline). `accent` is for a centre whose
// nav is the window's only colour; otherwise the calm grey is used.
Item {
    id: nav
    property var pal
    property var items: []
    property string current: ""
    property bool caption: true
    property bool accent: false
    signal picked(string key)

    readonly property var cur: {
        for (var i = 0; i < items.length; i++) if (items[i].key === current) return items[i]
        return null
    }
    implicitWidth: row.implicitWidth + 10
    implicitHeight: 46 + (caption ? 17 : 0)

    Rectangle {
        id: bar
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: row.implicitWidth + 10
        height: 46
        radius: 23
        color: Qt.alpha(nav.pal.text, 0.045)
        border.width: 1
        border.color: nav.pal.lineSoft
    }

    Row {
        id: row
        anchors.top: bar.top
        anchors.topMargin: 3
        anchors.horizontalCenter: bar.horizontalCenter
        spacing: 2

        Repeater {
            model: nav.items
            delegate: Item {
                id: seg
                required property var modelData
                readonly property bool on: modelData.key === nav.current
                width: 40
                height: 40

                Rectangle {
                    anchors.fill: parent
                    radius: 20
                    color: seg.on ? Qt.alpha(nav.pal.accent, nav.accent ? 0.20 : 0.14)
                                  : (sMa.containsMouse ? nav.pal.fillHover : "transparent")
                    Behavior on color { ColorAnimation { duration: nav.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: nav.pal.curveCalm } }
                }
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(seg.modelData.glyph || 0)
                    color: seg.on ? nav.pal.accent : (sMa.containsMouse ? nav.pal.text : nav.pal.muted)
                    font.family: nav.pal.font
                    font.pixelSize: 19
                    Behavior on color { ColorAnimation { duration: nav.pal.dFast } }
                }
                // a small dot for a segment that wants attention (unread alerts, a waiting update): no number, no badge chrome
                Rectangle {
                    visible: !!seg.modelData.dot
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: 6
                    anchors.rightMargin: 6
                    width: 6; height: 6; radius: 3
                    color: seg.modelData.tone ? seg.modelData.tone : nav.pal.warn
                }
                MouseArea {
                    id: sMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: nav.picked(seg.modelData.key)
                }
                LazyLoader {
                    active: sMa.containsMouse && seg.modelData.label !== ""
                    PopupWindow {
                        anchor.item: seg
                        anchor.rect.x: Math.round((seg.width - implicitWidth) / 2)
                        anchor.rect.y: seg.height + 10
                        implicitWidth: tipTxt.implicitWidth + 20
                        implicitHeight: tipTxt.implicitHeight + 12
                        color: "transparent"
                        visible: true
                        Rectangle {
                            anchors.fill: parent
                            radius: 9
                            color: Qt.alpha(nav.pal.surfaceHi, 0.97)
                            border.width: 1
                            border.color: nav.pal.lineSoft
                            Text {
                                id: tipTxt
                                anchors.centerIn: parent
                                text: seg.modelData.label
                                color: nav.pal.text
                                font.family: nav.pal.uiFont
                                font.pixelSize: nav.pal.tCap
                                font.weight: Font.Medium
                            }
                        }
                    }
                }
            }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: bar.bottom
        anchors.topMargin: 4
        height: 13
        visible: nav.caption && nav.cur !== null
        text: nav.cur ? nav.cur.label : ""
        color: Qt.alpha(nav.pal.muted, 0.85)
        font.family: nav.pal.uiFont
        font.pixelSize: nav.pal.tCap - 1
        font.weight: Font.Medium
        font.letterSpacing: 0.4
    }
}
