import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "mouseButtons" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: mb
    width: parent ? parent.width : 0
    spacing: 10
    property string openId: ""
    property bool more: false
    readonly property var mice: root.inputConf.mice || []
    readonly property bool has: mice.length > 0
    readonly property var buttons: [
        { id: "m275", t: "Back button" },
        { id: "m276", t: "Forward button" },
        { id: "m274", t: "Middle click (wheel press)" },
        { id: "m277", t: "Extra button 1" },
        { id: "m278", t: "Extra button 2" },
        { id: "m279", t: "Extra button 3" }
    ]
    Component.onCompleted: { root.inputUsers++; root.inputLoad() }
    Component.onDestruction: root.inputUsers--
    Text {
        Layout.fillWidth: true
        text: mb.has ? "Connected: " + mb.mice.join(", ") : "No mouse connected. Plug one in (or connect it by Bluetooth) and its buttons show up here by themselves."
        color: mb.has ? root.pal.good : root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; wrapMode: Text.WordWrap
    }
    ColumnLayout {
        Layout.fillWidth: true
        visible: mb.has
        spacing: 10
        Text {
            Layout.fillWidth: true
            text: "What each extra button of the mouse does. \"Default\" leaves it to the app under the pointer (back / forward in a browser, a file manager ...); anything else is taken by Hyprland, so the app no longer sees that button. It does not change SUPER + drag. Left and right click are never touched (Left-handed buttons swaps them). It applies to every connected mouse."
            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; lineHeight: 1.3; wrapMode: Text.WordWrap
        }
        Repeater {
            model: mb.buttons.filter(function (b) { return mb.more || ["m274", "m275", "m276"].indexOf(b.id) >= 0 })
            delegate: ActionPick {
                id: mr
                required property var modelData
                readonly property var rec: root.inputConf.mouse[modelData.id] || { a: "none", c: "" }
                Layout.fillWidth: true
                pal: root.pal
                titleWidth: 170
                title: modelData.t
                actions: root.mouseActions
                action: rec.a
                cmd: rec.c
                unfolded: mb.openId === modelData.id
                onToggled: mb.openId = (mb.openId === modelData.id ? "" : modelData.id)
                onChosen: (a, c) => {
                    root.setInput(modelData.id, a, c)
                    if ((a !== "app" && a !== "cmd") || c !== "") mb.openId = ""
                }
            }
        }
        Text {
            Layout.fillWidth: true
            visible: ((root.inputConf.mouse || {}).m274 || { a: "none" }).a !== "none"
            text: "Middle click is set to something: it no longer pastes the selection or opens a link in a new tab."
            color: root.pal.bad; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            SChip { pal: root.pal; label: mb.more ? "Hide the extra buttons" : "Mice with more buttons"; onClicked: mb.more = !mb.more }
            Item { Layout.fillWidth: true }
            SChip { pal: root.pal; label: "Restore defaults"; onClicked: { mb.openId = ""; root.resetInput("mouse") } }
        }
        Text {
            Layout.fillWidth: true
            text: "Not sure which button is which? The usual numbers are 275 = back, 276 = forward, 274 = the wheel press, and 277 and up for a gaming mouse's extra buttons. `wev` (a small Wayland tool) shows the number of whatever you press."
            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
        }
    }
    component SChip: Chip { maxLabel: 1000 }
}
