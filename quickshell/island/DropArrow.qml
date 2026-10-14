import QtQuick

// Round chevron button for the drop-down header (DropHeader.qml). Pointer handlers instead of a MouseArea,
// so a swipe that starts on the button still turns the page.
Rectangle {
    id: root
    property var pal
    property string glyph: ""
    property bool live: true            // false: there is no page in that direction
    signal clicked()

    readonly property bool lit: live && hv.hovered

    width: 34
    height: 34
    radius: 17
    color: lit ? Qt.alpha(pal.accent, 0.20) : Qt.alpha(pal.text, 0.05)
    border.width: 1
    border.color: lit ? Qt.alpha(pal.accent, 0.45) : pal.line
    opacity: live ? 1 : 0.28
    scale: (live && tap.pressed) ? 0.9 : 1
    Behavior on opacity { NumberAnimation { duration: pal.dMed } }
    Behavior on color { ColorAnimation { duration: pal.dFast } }
    Behavior on border.color { ColorAnimation { duration: pal.dFast } }
    Behavior on scale { NumberAnimation { duration: pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: pal.curve } }

    Text {
        anchors.centerIn: parent
        text: root.glyph
        color: root.lit ? root.pal.accent : root.pal.text
        font.family: root.pal.font
        font.pixelSize: 18
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
    }
    HoverHandler { id: hv; cursorShape: root.live ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { id: tap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: if (root.live) root.clicked() }
}
