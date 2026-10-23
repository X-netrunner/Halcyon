import QtQuick
import QtQuick.Layouts

// A box's or window's title and the small line under it (Notifications · "3 notifications", Settings, Bar builder ...).
// Normally it sits on the left and fills the free space of its header row. With Settings > Look > Centred titles
// (pal.centerTitles) each line is centred on the middle of the whole row, as far as the buttons beside it allow.
// overlay: true (headers with a search box after the title): when centred the title leaves the row's flow and sits exactly in
// the middle of the row, so the search box moves up next to the icon instead of pushing the title aside.
Item {
    id: t
    property var pal
    property string title: ""
    property string sub: ""
    property color subColor: pal.muted
    property int size: pal.tTitle
    property string fontFamily: pal.uiFont
    property color titleColor: pal.text
    property bool overlay: false
    property bool subIsHint: false          // the small line is an explanation: Settings > Look > Hide explanations hides it
    readonly property bool centred: !!(pal && pal.centerTitles)
    readonly property bool lifted: centred && overlay

    Layout.fillWidth: !overlay        // an overlay title keeps its own width in the row (the search box after it fills)
    implicitWidth: lifted ? 0 : Math.max(tt.implicitWidth, st.visible ? st.implicitWidth : 0)
    implicitHeight: col.implicitHeight
    z: lifted ? 5 : 0

    // where the middle of the header row is, in this item's own coordinates
    readonly property real mid: t.parent ? t.parent.width / 2 - t.x : t.width / 2
    function place(w) {
        if (!centred) return 0
        if (lifted) return mid - w / 2
        return Math.max(0, Math.min(t.width - w, mid - w / 2))
    }

    Column {
        id: col
        width: t.lifted ? 0 : t.width
        spacing: 1
        Text {
            id: tt
            width: t.lifted ? implicitWidth : Math.min(implicitWidth, t.width)
            x: t.place(width)
            text: t.title
            color: t.titleColor
            font.family: t.fontFamily
            font.pixelSize: t.size
            font.weight: Font.DemiBold
            horizontalAlignment: t.centred ? Text.AlignHCenter : Text.AlignLeft
            wrapMode: Text.Wrap
        }
        Text {
            id: st
            visible: text !== "" && !(t.subIsHint && t.pal.hideHints)
            width: t.lifted ? implicitWidth : Math.min(implicitWidth, t.width)
            x: t.place(width)
            text: t.sub
            color: t.subColor
            font.family: t.fontFamily
            font.pixelSize: t.pal.tCap
            horizontalAlignment: t.centred ? Text.AlignHCenter : Text.AlignLeft
            wrapMode: Text.Wrap
        }
    }
}
