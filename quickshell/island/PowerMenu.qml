import QtQuick
import Quickshell
import Quickshell.Wayland

// Power button -> everything behind blurs and the session options appear in the middle of the screen.
//   click an option (restart / shut down / log out ask "Sure?" first)   L lock  S sleep  O log out  R restart  P shut down
//   Esc or a click anywhere else closes it
Scope {
    id: root
    property var pal
    property string sysmode: ""
    property bool open: false
    property string pending: ""
    signal session(string action)

    property string clock: ""
    function show() { pending = ""; clock = Qt.formatDateTime(new Date(), "HH:mm"); open = true }
    function hide() { open = false; pending = "" }
    function pick(id, confirm) {
        if (confirm && pending !== id) { pending = id; confirmT.restart(); return }
        hide()
        root.session(id)
    }
    Timer { id: confirmT; interval: 3000; onTriggered: root.pending = "" }

    readonly property var items: [
        { id: "lock",     label: "Lock",      glyph: 0xF033E, confirm: false, key: Qt.Key_L },
        { id: "suspend",  label: "Sleep",     glyph: 0xF04B2, confirm: false, key: Qt.Key_S },
        { id: "logout",   label: "Log out",   glyph: 0xF0343, confirm: true,  key: Qt.Key_O },
        { id: "reboot",   label: "Restart",   glyph: 0xF0709, confirm: true,  key: Qt.Key_R },
        { id: "shutdown", label: "Shut down", glyph: 0xF0425, confirm: true,  key: Qt.Key_P }
    ]

    PanelWindow {
        id: win
        visible: root.open || fade.opacity > 0.01
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "island-power"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Item {
            id: fade
            anchors.fill: parent
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            focus: root.open
            Keys.onPressed: e => {
                if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true; return }
                for (var i = 0; i < root.items.length; i++)
                    if (root.items[i].key === e.key) { root.pick(root.items[i].id, root.items[i].confirm); e.accepted = true }
            }

            // dim + (compositor) blur of everything behind; the layer rule in hyprland/rules.lua turns the blur on
            Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.55) }
            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Backdrop { anchors.fill: parent; pal: root.pal; mode: root.sysmode; dots: 26; artStrength: 0.8; artFit: 0.7 }

            Column {
                anchors.centerIn: parent
                spacing: 34
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.clock
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 54
                    font.weight: Font.Light
                    opacity: 0.9
                }
                Row {
                    spacing: 22
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: root.items
                        delegate: Item {
                            required property var modelData
                            width: 104; height: 128
                            readonly property bool sure: root.pending === modelData.id
                            readonly property bool hot: ma.containsMouse || sure
                            Rectangle {
                                id: node
                                width: 96; height: 96; radius: 28
                                anchors.horizontalCenter: parent.horizontalCenter
                                scale: ma.pressed ? 0.95 : (hot ? 1.06 : 1)
                                Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                                color: sure ? Qt.alpha(root.pal.accent, 0.30) : Qt.alpha(root.pal.surface, 0.95)
                                border.width: 1.5
                                border.color: Qt.alpha(root.pal.accent, hot ? 0.95 : 0.35)
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                                Text {
                                    anchors.centerIn: parent
                                    text: String.fromCodePoint(modelData.glyph)
                                    color: hot ? root.pal.accent : root.pal.text
                                    font.family: root.pal.font
                                    font.pixelSize: 36
                                }
                            }
                            Text {
                                anchors.top: node.bottom
                                anchors.topMargin: 14
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: sure ? "Sure?" : modelData.label
                                color: sure ? root.pal.accent : root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                                font.weight: sure ? Font.DemiBold : Font.Normal
                            }
                            MouseArea {
                                id: ma
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.pick(modelData.id, modelData.confirm)
                            }
                        }
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Esc to cancel"
                    color: Qt.alpha(root.pal.muted, 0.7)
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
            }
        }
    }
}
