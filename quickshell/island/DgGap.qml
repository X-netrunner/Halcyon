import QtQuick

// A measuring line from a to b along one axis (horiz: left-right, else up-down) at the cross position `at`, a cap at each end and
// the distance d in the middle. Used by DeskGuides.qml.
Item {
    id: gap
    property var pal
    property bool horiz: true
    property real a: 0
    property real b: 0
    property real at: 0
    property real d: 0
    property color tone: "#9aa9d4"
    visible: d >= 1
    Rectangle { x: gap.horiz ? Math.min(gap.a, gap.b) : gap.at - 0.5; y: gap.horiz ? gap.at - 0.5 : Math.min(gap.a, gap.b); width: gap.horiz ? Math.abs(gap.b - gap.a) : 1; height: gap.horiz ? 1 : Math.abs(gap.b - gap.a); color: gap.tone }
    Rectangle { x: gap.horiz ? gap.a - 0.5 : gap.at - 4; y: gap.horiz ? gap.at - 4 : gap.a - 0.5; width: gap.horiz ? 1 : 8; height: gap.horiz ? 8 : 1; color: gap.tone }
    Rectangle { x: gap.horiz ? gap.b - 0.5 : gap.at - 4; y: gap.horiz ? gap.at - 4 : gap.b - 0.5; width: gap.horiz ? 1 : 8; height: gap.horiz ? 8 : 1; color: gap.tone }
    DgTag {
        pal: gap.pal
        x: (gap.horiz ? (gap.a + gap.b) / 2 : gap.at) - width / 2 + (gap.horiz ? 0 : width / 2 + 6)
        y: (gap.horiz ? gap.at : (gap.a + gap.b) / 2) - height / 2 - (gap.horiz ? height / 2 + 4 : 0)
        text: Math.round(gap.d) + ""
        tone: gap.tone
    }
}
