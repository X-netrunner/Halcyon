import QtQuick

// One toggle row (icon, name, small second line) in the Utilities box widget (WBoxes.qml). t = { id, n, i, on, sub }, b = the WBase body.
Rectangle {
    id: tr
    property var b: null
    property var t: ({})
    width: parent ? parent.width : 200
    height: b ? b.sz(42) : 42
    radius: b ? b.sz(12) : 12
    readonly property bool lit: t.on === true
    color: !b ? "transparent" : (lit ? Qt.alpha(b.accent, 0.22) : (tm.containsMouse ? Qt.alpha(b.fg, 0.12) : Qt.alpha(b.fg, 0.06)))
    border.width: 1; border.color: !b ? "transparent" : (lit ? Qt.alpha(b.accent, 0.75) : Qt.alpha(b.fg, 0.1))
    Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    WIco { b: tr.b; text: tr.b ? tr.b.glyph(tr.t.i || 0) : ""; color: tr.b ? (tr.lit ? tr.b.accent : tr.b.dim) : "white"; font.pixelSize: tr.b ? tr.b.sz(20) : 20; x: tr.b ? tr.b.sz(12) : 12; anchors.verticalCenter: parent.verticalCenter }
    Column {
        x: tr.b ? tr.b.sz(46) : 46; anchors.verticalCenter: parent.verticalCenter; width: parent.width - (tr.b ? tr.b.sz(60) : 60)
        WLbl { b: tr.b; text: tr.t.n || ""; font.pixelSize: tr.b ? tr.b.sz(13) : 13; font.weight: Font.Medium; elide: Text.ElideRight; width: parent.width }
        WLbl { b: tr.b; visible: (tr.t.sub || "") !== ""; text: tr.t.sub || ""; color: tr.b ? tr.b.dim : "#999"; font.pixelSize: tr.b ? tr.b.sz(10.5) : 10.5; elide: Text.ElideRight; width: parent.width }
    }
    MouseArea { id: tm; anchors.fill: parent; hoverEnabled: true; enabled: tr.b && !tr.b.editing; cursorShape: Qt.PointingHandCursor; onClicked: tr.b.press(tr.t.id) }
}
