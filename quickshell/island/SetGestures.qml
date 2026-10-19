import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "gestures" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: gs
    width: parent ? parent.width : 0
    spacing: 10
    property int fingers: 3
    property string openId: ""          // the row whose list is unfolded (one at a time)
    readonly property var dirs: [
        { k: "left",     t: "Swipe left",  i: "←" },
        { k: "right",    t: "Swipe right", i: "→" },
        { k: "up",       t: "Swipe up",    i: "↑" },
        { k: "down",     t: "Swipe down",  i: "↓" },
        { k: "pinchin",  t: "Pinch in",    i: "›‹" },
        { k: "pinchout", t: "Pinch out",   i: "‹›" }
    ]
    Component.onCompleted: { root.inputUsers++; root.inputLoad() }
    Component.onDestruction: root.inputUsers--
    Text {
        Layout.fillWidth: true
        text: "Pick how many fingers, then what each swipe or pinch does. \"Nothing\" leaves a gesture to your apps (a browser can use a 3-finger swipe for back / forward, for example); anything else is taken by Hyprland. Applies at once: Hyprland reloads for a moment. The one-finger edge gestures (volume, brightness, tracks) are under Mouse, touchpad & keyboard > Edge gestures."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; lineHeight: 1.3; wrapMode: Text.WordWrap
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        SChip { pal: root.pal; label: "3 fingers"; on: gs.fingers === 3; onClicked: { gs.fingers = 3; gs.openId = "" } }
        SChip { pal: root.pal; label: "4 fingers"; on: gs.fingers === 4; onClicked: { gs.fingers = 4; gs.openId = "" } }
        Item { Layout.fillWidth: true }
        SChip { pal: root.pal; label: "Restore defaults"; onClicked: { gs.openId = ""; root.resetInput("gestures") } }
    }
    Repeater {
        model: gs.dirs
        delegate: ActionPick {
            id: gr
            required property var modelData
            readonly property string gid: "g" + gs.fingers + "-" + modelData.k
            readonly property var rec: root.inputConf.gestures[gid] || { a: "none", c: "" }
            Layout.fillWidth: true
            pal: root.pal
            title: modelData.t
            icon: modelData.i
            actions: root.gestureActions
            action: rec.a
            cmd: rec.c
            unfolded: gs.openId === gid
            onToggled: gs.openId = (gs.openId === gid ? "" : gid)
            onChosen: (a, c) => {
                root.setInput(gid, a, c)
                if ((a !== "app" && a !== "cmd") || c !== "") gs.openId = ""
            }
        }
    }
    Text {
        Layout.fillWidth: true
        text: "Out of the box: 4 fingers left / right = next / previous workspace (a new one after the last), 3 fingers up / down = scratch workspace, 4 fingers down = sleep, 3-finger pinch = workspace tree."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    component SChip: Chip { maxLabel: 1000 }
}
