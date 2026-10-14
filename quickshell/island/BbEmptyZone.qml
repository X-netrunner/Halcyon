import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "BarLayout.js" as BL

// Part of the bar builder window (BarBuilderWindow.qml). `bb` is that window.
Rectangle {
    required property var bb
    property string title: ""
    anchors.fill: parent
    anchors.topMargin: 3
    anchors.bottomMargin: 3
    radius: 8
    color: Qt.alpha(bb.pal.accent, 0.05)
    border.width: 1
    border.color: Qt.alpha(bb.pal.accent, 0.3)
    Text {
        anchors.centerIn: parent
        text: parent.title + " · drop here"
        color: bb.pal.muted
        font.family: bb.pal.uiFont
        font.pixelSize: 9
        font.italic: true
    }
}
