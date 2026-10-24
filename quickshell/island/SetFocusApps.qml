import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "focusApps" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    width: parent ? parent.width : 0
    spacing: 12
    Text { text: "Blocked apps"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
    Flow {
        Layout.fillWidth: true
        spacing: 10
        Repeater {
            model: root.focusApps.blocked || []
            delegate: SChip {
                required property var modelData
                pal: root.pal
                glyph: String.fromCodePoint(0xF0156)
                label: modelData
                on: true
                onClicked: root.focusApp("unblock", modelData)
            }
        }
        Text {
            visible: (root.focusApps.blocked || []).length === 0
            text: "nothing yet: pick an app below (open or installed), or type its window class"
            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
        }
    }
    Text { text: "Open right now (click to block)"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
    Flow {
        Layout.fillWidth: true
        spacing: 10
        Repeater {
            model: root.focusApps.open || []
            delegate: SChip {
                required property var modelData
                visible: !modelData.blocked
                pal: root.pal
                glyph: String.fromCodePoint(0xF0415)
                label: modelData.class
                onClicked: root.focusApp("block", modelData.class)
            }
        }
    }
    Text { text: "Pick from all your installed apps"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
    AppPicker {
        Layout.fillWidth: true
        pal: root.pal
        placeholder: "Search your apps, click one to block it…"
        exclude: (root.focusApps.blocked || []).map(function (x) { return String(x).toLowerCase() })
        onPicked: app => {
            var l = [app.cls]
            if (app.bin !== "" && app.bin.toLowerCase() !== app.cls.toLowerCase()) l.push(app.bin)   // its program name is a second guess for the class
            root.focusApp("block", l)
        }
    }
    Text { text: "Or type a window class yourself"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Rectangle {
            Layout.fillWidth: true
            height: 36; radius: 18
            color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.8))
            border.width: root.pal.zen && !fcIn.activeFocus ? 0 : 1
            border.color: fcIn.activeFocus ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
            TextInput {
                id: fcIn
                anchors.fill: parent
                anchors.leftMargin: 16; anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                clip: true
                selectByMouse: true
                onAccepted: { if (text.trim() !== "") { root.focusApp("block", text.trim()); text = "" } }
                Text {
                    visible: !parent.text && !parent.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: "window class, e.g. discord or steam_app_*"
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
            }
        }
        SChip { pal: root.pal; label: "Add"; onClicked: { if (fcIn.text.trim() !== "") { root.focusApp("block", fcIn.text.trim()); fcIn.text = "" } } }
    }
    Text {
        Layout.fillWidth: true
        text: "Apps from the list are matched by the window class their launcher entry gives (plus the program name). If one still opens, click it under \"Open right now\" while it runs: that is its exact class. The class is what `hyprctl clients` shows; * works as a wildcard and case does not matter. Saved in ~/.config/Halcyon/focus-apps.conf."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    component SChip: Chip { maxLabel: 1000 }
}
