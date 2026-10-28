import QtQuick
import Quickshell.Hyprland

// "Special workspaces": the hidden workspaces (scratch, music, chat, monitor) as buttons on the desktop.
// The lit one is on screen right now, a small count shows how many windows it holds. A click shows / hides it
// (music and chat start their app the first time, like SUPER+M / SUPER+D).
// Layouts: pills | icons | dots | outline | segmented | tabs | labels | rings | stack | glow
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
    readonly property bool vertical: style === "stack"
    // segmented: one rounded track holds all the buttons, so the grid sits inside a small inset
    readonly property real inset: style === "segmented" ? sz(4) : 0
    readonly property real gap: style === "dots" ? sz(12) : (style === "labels" ? sz(16) : (style === "segmented" ? sz(2) : (style === "stack" ? sz(4) : (style === "tabs" ? sz(4) : (style === "glow" ? sz(10) : sz(8))))))

    function count(name) {
        var l = Hyprland.toplevels.values, c = 0
        for (var i = 0; i < l.length; i++) {
            try { if (l[i].workspace && l[i].workspace.name === "special:" + name) c++ } catch (e) {}
        }
        return c
    }

    implicitWidth: grid.implicitWidth + inset * 2
    implicitHeight: Math.max(grid.implicitHeight + inset * 2, sz(34))

    // segmented: the track behind all the buttons; tabs: the hairline under all the tabs
    Rectangle {
        visible: root.style === "segmented"
        anchors.fill: parent
        radius: height / 2
        color: root.track
    }
    Rectangle {
        visible: root.style === "tabs"
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 1
        color: root.track
    }

    Grid {
        id: grid
        x: root.inset; y: root.inset
        columns: root.vertical ? 1 : Math.max(1, root.shown.length)
        columnSpacing: root.gap
        rowSpacing: root.gap
        verticalItemAlignment: Grid.AlignVCenter
        Repeater {
            model: root.shown
            delegate: Item {
                id: cell
                required property var modelData
                readonly property string st: root.style
                readonly property bool cur: root.active === modelData.n
                readonly property int n: root.live ? root.count(modelData.n) : 0
                readonly property bool dot: st === "dots"
                readonly property bool hasIcon: st !== "labels" && !dot
                readonly property bool hasLabel: st === "pills" || st === "outline" || st === "segmented" || st === "tabs" || st === "labels" || st === "stack"
                // a lit button that is filled with the accent needs dark text; the others just turn accent-coloured
                readonly property bool filled: st === "pills" || st === "icons" || st === "segmented" || st === "stack"
                readonly property color ink: cur ? (filled ? (root.pal ? root.pal.bg : "black") : root.accent) : (n > 0 ? root.fg : root.dim)
                readonly property real content: (hasIcon ? ic.implicitWidth : 0) + (hasLabel ? lbl.implicitWidth : 0) + (hasIcon && hasLabel ? root.sz(7) : 0)

                implicitWidth: dot ? root.sz(cur ? 24 : 10)
                             : (st === "icons" || st === "rings" ? root.sz(34)
                             : (st === "glow" ? root.sz(30)
                             : (st === "stack" ? root.sz(124)
                             : (st === "labels" ? content + root.sz(6)
                             : (st === "tabs" ? content + root.sz(20)
                             : (st === "segmented" ? content + root.sz(24) : content + root.sz(30)))))))
                implicitHeight: dot ? root.sz(10)
                              : (st === "rings" || st === "glow" ? root.sz(34)
                              : (st === "stack" ? root.sz(30)
                              : (st === "labels" ? root.sz(26) : root.sz(32))))
                width: implicitWidth; height: implicitHeight
                Behavior on implicitWidth { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                // the button itself
                Rectangle {
                    visible: cell.st !== "tabs" && cell.st !== "labels" && cell.st !== "glow"
                    anchors.fill: parent
                    radius: cell.st === "stack" ? root.sz(9) : height / 2
                    color: cell.st === "segmented" ? (cell.cur ? root.accent : "transparent")
                         : (cell.st === "outline" ? (cell.cur ? Qt.alpha(root.accent, 0.18) : "transparent")
                         : (cell.st === "rings" ? (cell.cur ? Qt.alpha(root.accent, 0.16) : "transparent")
                         : (cell.st === "stack" ? (cell.cur ? root.accent : (cell.n > 0 ? Qt.alpha(root.fg, 0.12) : Qt.alpha(root.track, 0.6)))
                         : (cell.cur ? root.accent : (cell.n > 0 ? Qt.alpha(root.fg, 0.16) : root.track)))))
                    border.width: cell.st === "outline" ? 1 : (cell.st === "rings" ? 2 : 0)
                    border.color: cell.cur ? root.accent : (cell.n > 0 ? Qt.alpha(root.fg, 0.5) : Qt.alpha(root.dim, 0.5))
                    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                }
                // tabs: the lit tab has a bar under it
                Rectangle {
                    visible: cell.st === "tabs" && cell.cur
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: Math.max(2, root.sz(2)); radius: height / 2
                    color: root.accent
                }
                // glow and labels: a small dot under the lit one
                Rectangle {
                    visible: (cell.st === "glow" || cell.st === "labels") && cell.cur
                    anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom
                    width: root.sz(5); height: width; radius: width / 2
                    color: root.accent
                }
                Row {
                    visible: !cell.dot
                    x: cell.st === "stack" ? root.sz(12) : (cell.width - width) / 2
                    y: (cell.height - height) / 2 - (cell.st === "glow" || cell.st === "labels" ? root.sz(1) : 0)
                    spacing: root.sz(7)
                    Text {
                        id: ic
                        visible: cell.hasIcon
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.glyph(cell.modelData.glyph)
                        font.family: root.icons; font.pixelSize: root.sz(cell.st === "glow" ? 20 : 16)
                        color: cell.ink
                        scale: cell.st === "glow" && cell.cur ? 1.12 : 1
                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                    }
                    WLbl {
                        id: lbl
                        b: root
                        visible: cell.hasLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: cell.modelData.label
                        color: cell.ink
                        font.pixelSize: root.sz(13)
                        font.weight: cell.cur ? Font.Bold : Font.Medium
                    }
                }
                // how many windows hide in there
                Rectangle {
                    visible: !cell.dot && cell.n > 0
                    x: cell.st === "stack" ? parent.width - width - root.sz(8) : parent.width - width * 0.7
                    y: cell.st === "stack" ? (parent.height - height) / 2 : -height * 0.25
                    width: Math.max(height, bt.implicitWidth + root.sz(8)); height: root.sz(15); radius: height / 2
                    color: cell.cur && cell.filled ? root.fg : root.accent
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
