import QtQuick

// One step of the calendar's connect page, drawn like a notification in the Timeline look: a number on the left, a dot on a
// thin rail, the text on the right. Whatever is put inside (buttons) sits under the text.
Item {
    id: st
    property var pal
    property bool live: false
    property int num: 1
    property string title: ""
    property string body: ""
    property bool done: false
    property bool current: false
    property bool last: false
    default property alias extra: slot.data
    readonly property color tone: (done || current) ? pal.accent : Qt.alpha(pal.muted, 0.8)
    height: sc.implicitHeight + 20

    property real glow: 0
    SequentialAnimation on glow {
        running: st.visible && st.current && st.live
        loops: Animation.Infinite
        NumberAnimation { to: 1; duration: 1100; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: 1100; easing.type: Easing.InOutSine }
    }
    Text {
        x: 0; y: 3; width: 38
        horizontalAlignment: Text.AlignRight
        text: st.done ? "✓" : String(st.num)
        color: st.current ? st.pal.accent : Qt.alpha(st.pal.muted, 0.9)
        font.family: st.pal.uiFont; font.pixelSize: st.pal.tCap
    }
    Rectangle { visible: !st.last; x: 52; y: 20; width: 1; height: Math.max(0, st.height - 20); color: Qt.alpha(st.pal.text, 0.10) }
    Rectangle {
        x: 52.5 - width / 2; y: 8 + 5.5 - height / 2
        width: 19; height: 19; radius: 9.5
        color: Qt.alpha(st.tone, 0.14 + 0.30 * st.glow)
    }
    Rectangle { x: 52.5 - 5.5; y: 8; width: 11; height: 11; radius: 5.5; color: st.tone }
    Column {
        id: sc
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 72; rightMargin: 8 }
        spacing: 3
        Text {
            width: parent.width
            text: st.title
            color: st.pal.text
            font.family: st.pal.uiFont; font.pixelSize: st.pal.tBody + 2; font.weight: Font.DemiBold
            wrapMode: Text.WordWrap
        }
        Text {
            width: parent.width
            visible: st.body !== ""
            text: st.body
            color: Qt.alpha(st.pal.text, 0.72)
            font.family: st.pal.uiFont; font.pixelSize: st.pal.tBody
            lineHeight: 1.1
            wrapMode: Text.WordWrap
        }
        Row { id: slot; visible: children.length > 0; topPadding: 6; spacing: 8 }
    }
}
