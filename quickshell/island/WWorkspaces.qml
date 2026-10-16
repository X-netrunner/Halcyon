import QtQuick
import Quickshell.Hyprland

// "Workspaces": the same switcher as the bar, on the desktop. A click goes to that workspace, the wheel walks through them.
//   dots | numbers | capsules | pills
WBase {
    id: root

    readonly property int cnt: {
        var l = Hyprland.workspaces.values, m = Math.round(opt("min", 5))
        for (var i = 0; i < l.length; i++) if (l[i].id > m) m = l[i].id
        return Math.max(1, Math.min(10, m))
    }
    function findWs(id) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].id === id) return l[i]
        return null
    }
    function wins(ws) { try { return ws.toplevels.values.length } catch (e) { return 0 } }

    implicitWidth: row.implicitWidth
    implicitHeight: Math.max(row.implicitHeight, 24)
    Row {
        id: row
        spacing: root.style === "capsules" ? root.sz(6) : root.sz(8)
        anchors.verticalCenter: parent.verticalCenter
        Repeater {
            model: root.cnt
            delegate: Item {
                id: cell
                required property int index
                readonly property int wid: index + 1
                readonly property var ws: root.findWs(wid)
                readonly property bool cur: ws !== null && ws.focused
                readonly property bool used: ws !== null && root.wins(ws) > 0
                readonly property bool num: root.style === "numbers" || root.style === "pills"
                implicitWidth: root.style === "capsules" ? root.sz(cur ? 10 : 8)
                             : (root.style === "dots" ? root.sz(cur ? 26 : 10) : (root.style === "pills" ? root.sz(cur ? 40 : 30) : root.sz(28)))
                implicitHeight: root.style === "capsules" ? root.sz(cur ? 26 : 18) : (root.style === "dots" ? root.sz(10) : root.sz(root.style === "pills" ? 26 : 28))
                width: implicitWidth; height: implicitHeight
                anchors.verticalCenter: parent.verticalCenter
                Behavior on implicitWidth { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Rectangle {
                    anchors.fill: parent
                    radius: root.style === "numbers" ? width / 2 : Math.min(width, height) / 2
                    color: cell.cur ? root.accent : (cell.used ? Qt.alpha(root.fg, 0.55) : root.track)
                    opacity: cell.cur || cell.used ? 1 : 0.8
                    visible: !(root.style === "numbers" && !cell.cur)
                    Behavior on color { ColorAnimation { duration: 160 } }
                }
                WLbl {
                    b: root
                    anchors.centerIn: parent
                    visible: cell.num
                    text: cell.wid
                    color: cell.cur ? (root.pal ? root.pal.bg : "black") : (cell.used ? root.fg : root.dim)
                    font.pixelSize: root.sz(13)
                    font.weight: cell.cur ? Font.Bold : Font.Medium
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -3
                    enabled: !root.editing
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.env) root.env.hypr("hl.dsp.focus({ workspace = " + cell.wid + " })")
                }
            }
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: !root.editing
        acceptedButtons: Qt.NoButton
        onWheel: w => { if (root.env) root.env.deskAct(w.angleDelta.y > 0 ? "ws-up" : "ws-down") }
    }
}
