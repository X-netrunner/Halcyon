import QtQuick

// A thin slider row in the boxes widget (WBoxes.qml): icon, a track you can click or drag, the value. b = the WBase body.
Item {
    id: lv
    property var b: null
    property real v: 0
    property int glyphCp: 0xF057E
    property bool isVol: true
    width: parent ? parent.width : 200
    height: b ? b.sz(30) : 30
    WIco { id: lvIco; b: lv.b; text: lv.b ? lv.b.glyph(lv.glyphCp) : ""; font.pixelSize: lv.b ? lv.b.sz(18) : 18; anchors.verticalCenter: parent.verticalCenter; width: lv.b ? lv.b.sz(24) : 24 }
    Rectangle {
        id: trk
        anchors.left: lvIco.right; anchors.leftMargin: lv.b ? lv.b.sz(8) : 8
        anchors.right: pct.left; anchors.rightMargin: lv.b ? lv.b.sz(8) : 8
        anchors.verticalCenter: parent.verticalCenter
        height: lv.b ? lv.b.sz(6) : 6; radius: height / 2
        color: lv.b ? lv.b.track : "#26ffffff"
        Rectangle { width: parent.width * lv.v; height: parent.height; radius: parent.radius; color: lv.b ? lv.b.accent : "#9aa9d4" }
        Rectangle { x: parent.width * lv.v - width / 2; anchors.verticalCenter: parent.verticalCenter; width: lv.b ? lv.b.sz(14) : 14; height: width; radius: width / 2; color: lv.b ? lv.b.fg : "#fff"; border.width: 1; border.color: Qt.alpha("#000000", 0.4) }
        MouseArea {
            anchors.fill: parent; anchors.margins: -8
            enabled: lv.b && !lv.b.editing && !!lv.b.env
            cursorShape: Qt.PointingHandCursor
            function setTo(m) {
                var p = mapToItem(trk, m.x, m.y)
                var f = Math.max(0, Math.min(1, p.x / Math.max(1, trk.width)))
                if (lv.isVol) lv.b.env.deskSetVol(f); else lv.b.env.deskSetBright(Math.max(0.01, f))
            }
            onPressed: m => setTo(m)
            onPositionChanged: m => { if (pressed) setTo(m) }
        }
    }
    WLbl { id: pct; b: lv.b; text: Math.round(lv.v * 100) + "%"; color: lv.b ? lv.b.dim : "#999"; font.pixelSize: lv.b ? lv.b.sz(12) : 12; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: lv.b ? lv.b.sz(36) : 36; horizontalAlignment: Text.AlignRight }
}
