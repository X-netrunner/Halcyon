import QtQuick
import Quickshell

LazyLoader {
    id: tip
    property var pal
    property Item target
    property string text: ""
    property bool shown: false
    active: shown && text !== "" && target !== null
    PopupWindow {
        anchor.item: tip.target
        anchor.rect.x: Math.round((tip.target.width - implicitWidth) / 2)
        anchor.rect.y: tip.target.height + 6
        implicitWidth: tipTxt.implicitWidth + 20
        implicitHeight: tipTxt.implicitHeight + 12
        color: "transparent"
        visible: true
        Rectangle {
            anchors.fill: parent
            radius: 9
            color: Qt.alpha(tip.pal.surfaceHi, 0.97)
            border.width: 1
            border.color: tip.pal.lineSoft
            Text {
                id: tipTxt
                anchors.centerIn: parent
                text: tip.text
                color: tip.pal.text
                font.family: tip.pal.uiFont
                font.pixelSize: tip.pal.tCap
                font.weight: Font.Medium
            }
        }
    }
}
