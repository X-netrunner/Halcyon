import QtQuick
import Quickshell
import Quickshell.Wayland

// The background apps as a pop-out menu next to the rail bar (Caelestia style): the icon above the clock (BgApps cell of CustomBar.qml)
// opens this card beside the rail, level with the icon, on the side of the screen the rail is on. It is the same list as the bottom-left
// box (BgApps.qml: the apps that sit in the system tray after their window is closed, Open, and each app's own menu with its Quit);
// only where it appears differs. A click outside, Esc, or Open on an app closes it. Other bars keep the bottom-left box.
// Nothing exists while it is closed (LazyLoader: no window, no tray menu, no timer).
Scope {
    id: root
    property var pal
    property bool open: false
    property bool linger: false
    property string side: "left"            // the bar's edge: top | bottom | left | right
    property real along: 0                  // where the icon is along that edge (y on a left / right rail), in screen px
    property real edge: 0                   // the bar's inner edge, in screen px (x of a left rail's right side ...)

    function show(s, a, e) {
        if (open) { hide(); return }        // a second click on the icon closes it
        side = s || "left"; along = a || 0; edge = e || 0
        open = true
    }
    function hide() { open = false }
    onOpenChanged: {
        if (open) { linger = true; lingerT.stop() }
        else lingerT.restart()
    }
    Timer { id: lingerT; interval: 300; onTriggered: root.linger = false }

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-bgpop"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region { item: catcher }

            Item {
                id: catcher
                anchors.fill: parent
                MouseArea { anchors.fill: parent; onClicked: root.hide() }

                BgApps {
                    id: card
                    readonly property real gap: 8
                    pal: root.pal
                    active: root.open
                    onOpened: root.hide()
                    // beside the bar, level with the icon, always inside the screen
                    x: {
                        if (root.side === "left") return root.edge + gap
                        if (root.side === "right") return catcher.width - root.edge - width - gap
                        return Math.max(gap, Math.min(catcher.width - width - gap, root.along - width / 2))
                    }
                    y: {
                        if (root.side === "top") return root.edge + gap
                        if (root.side === "bottom") return catcher.height - root.edge - height - gap
                        return Math.max(gap, Math.min(catcher.height - height - gap, root.along - height / 2))
                    }
                    // grows out of the bar: the side it opens from sets where it scales from
                    transformOrigin: root.side === "top" ? Item.Top : root.side === "bottom" ? Item.Bottom : root.side === "left" ? Item.Left : Item.Right
                    opacity: root.open ? 1 : 0
                    scale: root.open ? 1 : 0.94
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                    Behavior on scale { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                }
            }
        }
    }
}
