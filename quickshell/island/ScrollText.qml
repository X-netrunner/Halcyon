import QtQuick

// Holds one Text (or WLbl) that may be too long for its place: normally it ends in "…"; while the pointer is on it, the
// whole text slides by slowly (pause, slide to the end, pause, back) so a long window title or song name can be read.
// Put the size / layout properties on the ScrollText and leave the Text's own width and elide alone: they are set here.
Item {
    id: s
    default property Item content
    readonly property bool over: !!content && content.implicitWidth > width + 1
    readonly property bool sliding: hh.hovered && over
    property real shift: 0

    clip: true
    implicitWidth: content ? content.implicitWidth : 0
    implicitHeight: content ? content.implicitHeight : 0
    onContentChanged: if (content) content.parent = s

    Binding { target: s.content; property: "width"; value: s.sliding ? s.content.implicitWidth : s.width; when: !!s.content }
    Binding { target: s.content; property: "elide"; value: s.sliding ? Text.ElideNone : Text.ElideRight; when: !!s.content }
    Binding { target: s.content; property: "x"; value: -s.shift; when: !!s.content }
    Binding { target: s.content; property: "y"; value: (s.height - s.content.height) / 2; when: !!s.content }

    HoverHandler { id: hh }
    onSlidingChanged: if (!sliding) shift = 0
    SequentialAnimation on shift {
        running: s.sliding
        loops: Animation.Infinite
        PauseAnimation { duration: 500 }
        NumberAnimation { to: Math.max(0, s.content ? s.content.implicitWidth - s.width : 0); duration: Math.max(600, (s.content ? s.content.implicitWidth - s.width : 0) * 22) }
        PauseAnimation { duration: 1100 }
        NumberAnimation { to: 0; duration: 350; easing.type: Easing.OutCubic }
    }
}
