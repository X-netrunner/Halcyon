import QtQuick

// The little segmented switch of the wallpaper gallery's view mode: the picked option is filled with the accent.
// options: [{ k, t }]   current: the picked k   picked(k): the click
Rectangle {
    id: seg
    property var pal
    property var options: []
    property string current: ""
    signal picked(string k)

    implicitHeight: 34
    implicitWidth: segRow.implicitWidth + 12
    radius: 12
    color: Qt.alpha(pal.bg, 0.6)
    border.width: pal.calm ? 0 : 1
    border.color: pal.line

    Row {
        id: segRow
        anchors.centerIn: parent
        spacing: 4
        Repeater {
            model: seg.options
            delegate: Rectangle {
                id: opt
                required property var modelData
                readonly property bool sel: seg.current === modelData.k
                width: lbl.implicitWidth + 24
                height: 26
                radius: 9
                color: sel ? seg.pal.accent : (ma.containsMouse ? Qt.alpha(seg.pal.surfaceHi, 0.9) : "transparent")
                Behavior on color { ColorAnimation { duration: seg.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Text {
                    id: lbl
                    anchors.centerIn: parent
                    text: opt.modelData.t
                    color: opt.sel ? seg.pal.bg : seg.pal.muted
                    font.family: seg.pal.uiFont; font.pixelSize: 12; font.weight: Font.Medium
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(opt.modelData.k)
                }
            }
        }
    }
}
