import QtQuick
import QtQuick.Layouts
import Quickshell

import "Binds.js" as Binds

// Settings custom leaf "voiceKey": change the key that starts / stops a voice note (default SUPER + SHIFT + V).
// `root` is the Settings scope; root.env is the shell, which owns the shortcut list (keyMap) and saves it (setBind) for
// hyprland/keybinds.lua. It is the same list the cheatsheet (SUPER + /) edits, so a key changed here shows up there too.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: vk
    width: parent ? parent.width : 0
    spacing: 8

    readonly property string bindId: "voicenote"
    readonly property string defKeys: "SUPER + SHIFT + V"
    readonly property var shell: root ? root.env : null
    readonly property string current: {
        var m = shell && shell.keyMap ? shell.keyMap : ({})
        return m[bindId] !== undefined ? m[bindId] : defKeys
    }
    readonly property bool isOff: current === "none" || current === ""
    readonly property bool isDefault: Binds.norm(current) === Binds.norm(defKeys)
    property bool capturing: false
    property string error: ""

    function apply(keys) {
        if (!shell || !shell.setBind) { error = "The shell is not ready yet, try again in a moment."; return }
        var other = keys === "none" || keys === "" ? "" : Binds.conflict(keys, bindId, shell.keyMap, shell.customBinds)
        if (other !== "") { error = "Already used by \u201c" + other + "\u201d. Pick another key."; return }
        error = ""
        // the default is stored as \"no change\", so a later change of the default in Binds.js still reaches this user
        shell.setBind(bindId, Binds.norm(keys) === Binds.norm(defKeys) ? "" : keys)
    }

    Text {
        text: "Voice note hotkey"
        color: root && root.pal ? root.pal.text : "#ffffff"
        font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
        font.pixelSize: root && root.pal ? root.pal.tBody : 13
    }
    Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "Press it once to start recording, again to save the voice note (and write it down when speech-to-text is installed). It also works without the Notes panel open. Click the box, then press the keys you want, for example Super + Alt + V."
        color: root && root.pal ? root.pal.muted : "#aaaaaa"
        font.family: root && root.pal ? root.pal.uiFont : "sans-serif"
        font.pixelSize: 12
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        // press-a-key box: click, then press the keys
        Rectangle {
            id: cap
            Layout.preferredWidth: 220
            height: 34; radius: 17
            color: vk.capturing ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.surfaceHi, 0.9)
            border.width: root.pal.zen && !(vk.capturing) ? 0 : 1
            border.color: vk.capturing ? root.pal.accent : root.pal.line
            focus: vk.capturing
            Text {
                anchors.centerIn: parent
                text: vk.capturing ? "press the keys\u2026" : (vk.isOff ? "Off  (click to set a key)" : Binds.parts(vk.current).join(" + "))
                color: vk.capturing || vk.isOff ? root.pal.muted : root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: vk.capturing || vk.isOff ? Font.Normal : Font.DemiBold
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { vk.capturing = true; vk.error = ""; cap.forceActiveFocus() }
            }
            onActiveFocusChanged: if (!activeFocus) vk.capturing = false
            Keys.onPressed: e => {
                if (!vk.capturing) return
                e.accepted = true
                if (e.key === Qt.Key_Escape) { vk.capturing = false; return }
                if (Binds.isModifierKey(e.key)) return                // wait for the real key
                var name = Binds.qtKey(e.key, e.modifiers)
                if (name === "") { vk.error = "That key can not be used."; return }
                var mods = Binds.qtMods(e.modifiers)
                var any = false
                for (var k in mods) any = true
                if (!any && !Binds.mayBeAlone(name)) {
                    vk.error = "Add Super, Alt, Ctrl or Shift, or that key would stop working everywhere."
                    return
                }
                vk.capturing = false
                vk.apply(Binds.build(mods, name))
            }
        }

        Rectangle {
            visible: !vk.isDefault
            height: 30; radius: 15; width: resetTxt.implicitWidth + 28
            color: resetMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 1) : Qt.alpha(root.pal.surface, 0.8)
            border.width: root.pal.calm ? 0 : 1; border.color: root.pal.line
            Text {
                id: resetTxt
                anchors.centerIn: parent
                text: "Reset to " + Binds.parts(vk.defKeys).join(" + ")
                color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 12
            }
            MouseArea { id: resetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { vk.capturing = false; vk.apply(vk.defKeys) } }
        }
        Rectangle {
            visible: !vk.isOff
            height: 30; radius: 15; width: offTxt.implicitWidth + 28
            color: offMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 1) : Qt.alpha(root.pal.surface, 0.8)
            border.width: root.pal.calm ? 0 : 1; border.color: root.pal.line
            Text {
                id: offTxt
                anchors.centerIn: parent
                text: "Turn off"
                color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 12
            }
            MouseArea { id: offMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { vk.capturing = false; vk.apply("none") } }
        }
        Item { Layout.fillWidth: true }
    }

    Text {
        visible: vk.error !== ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: vk.error
        color: "#ff6b6b"
        font.family: root.pal.uiFont
        font.pixelSize: 12
    }
}
