import QtQuick
import Quickshell.Hyprland

// "Special workspaces": the hidden workspaces (scratch, music, chat, monitor) as buttons on the desktop.
// The lit one is on screen right now, a small count shows how many windows it holds. A click shows / hides it
// (music and chat start their app the first time, like SUPER+M / SUPER+D). Layouts: pills | icons | dots
WBase {
    id: root

    readonly property var all: [
        { n: "special",       label: "Scratch",  glyph: 0xF03EB },
        { n: "music",         label: "Music",    glyph: 0xF075A },
        { n: "communication", label: "Chat",     glyph: 0xF066F },
        { n: "sysmon",        label: "Monitor",  glyph: 0xF04C5 }
    ]
    readonly property var shown: all.filter(function (e) { var s = opt("show", ["special", "music", "communication", "sysmon"]); return s.indexOf(e.n) >= 0 })
    readonly property string active: env ? env.activeSpecial : ""

    function count(name) {
        var l = Hyprland.toplevels.values, c = 0
        for (var i = 0; i < l.length; i++) {
            try { if (l[i].workspace && l[i].workspace.name === "special:" + name) c++ } catch (e) {}
        }
        return c
    }

    implicitWidth: row.implicitWidth
    implicitHeight: Math.max(row.implicitHeight, sz(34))
    Row {
        id: row
        spacing: root.sz(root.style === "dots" ? 12 : 8)
        anchors.verticalCenter: parent.verticalCenter
        Repeater {
            model: root.shown
            delegate: Item {
                id: cell
                required property var modelData
                readonly property bool cur: root.active === modelData.n
                readonly property int n: root.live ? root.count(modelData.n) : 0
                readonly property bool pill: root.style === "pills"
                readonly property bool dot: root.style === "dots"
                implicitWidth: dot ? root.sz(cur ? 24 : 10) : (pill ? lbl.implicitWidth + ic.implicitWidth + root.sz(30) : root.sz(34))
                implicitHeight: dot ? root.sz(10) : root.sz(32)
                width: implicitWidth; height: implicitHeight
                anchors.verticalCenter: parent.verticalCenter
                Behavior on implicitWidth { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: cell.cur ? root.accent : (cell.n > 0 ? Qt.alpha(root.fg, 0.16) : root.track)
                    Behavior on color { ColorAnimation { duration: 160 } }
                }
                Row {
                    visible: !cell.dot
                    anchors.centerIn: parent
                    spacing: root.sz(7)
                    Text {
                        id: ic
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.glyph(cell.modelData.glyph)
                        font.family: root.icons; font.pixelSize: root.sz(16)
                        color: cell.cur ? (root.pal ? root.pal.bg : "black") : (cell.n > 0 ? root.fg : root.dim)
                    }
                    WLbl {
                        id: lbl
                        b: root
                        visible: cell.pill
                        anchors.verticalCenter: parent.verticalCenter
                        text: cell.modelData.label
                        color: cell.cur ? (root.pal ? root.pal.bg : "black") : (cell.n > 0 ? root.fg : root.dim)
                        font.pixelSize: root.sz(13)
                        font.weight: cell.cur ? Font.Bold : Font.Medium
                    }
                }
                // how many windows hide in there
                Rectangle {
                    visible: !cell.dot && cell.n > 0
                    x: parent.width - width * 0.7; y: -height * 0.25
                    width: Math.max(height, bt.implicitWidth + root.sz(8)); height: root.sz(15); radius: height / 2
                    color: cell.cur ? root.fg : root.accent
                    Text { id: bt; anchors.centerIn: parent; text: cell.n; font.pixelSize: root.sz(10); font.bold: true; color: root.pal ? root.pal.bg : "black" }
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -3
                    enabled: !root.editing
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.env) root.env.toggleSpecial(cell.modelData.n)
                }
            }
        }
    }
}
