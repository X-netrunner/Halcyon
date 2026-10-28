import QtQuick

// A small round "?" that explains a word when you hover it. It draws no bubble itself: the window that uses it shows ONE
// bubble (StartupWindow.qml: showTip) so the text is never cut off by a list or a row, and nothing extra is kept per marker.
Item {
    id: h
    property var pal
    property string tip: ""
    readonly property bool hovered: hh.hovered

    // the new style with Hide explanations: no "?" at all (ask > explains)
    visible: !(pal && pal.zen && pal.hideHints)
    implicitWidth: visible ? 15 : 0
    implicitHeight: 15

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: h.hovered ? Qt.alpha(h.pal.accent, 0.22) : "transparent"
        border.width: 1
        border.color: h.hovered ? h.pal.accent : Qt.alpha(h.pal.muted, 0.7)   // (only shown in the styles that keep the ?)
        Behavior on color { ColorAnimation { duration: h.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Behavior on border.color { ColorAnimation { duration: h.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Text {
            anchors.centerIn: parent
            text: "?"
            color: h.hovered ? h.pal.accent : h.pal.muted
            font.family: h.pal.uiFont
            font.pixelSize: 9
            font.weight: Font.Bold
        }
    }
    HoverHandler { id: hh; cursorShape: Qt.WhatsThisCursor }
}
