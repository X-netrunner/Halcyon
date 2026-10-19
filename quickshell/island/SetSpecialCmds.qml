import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "specialCmds" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    spacing: 10
    Text {
        Layout.fillWidth: true
        text: "Special workspace commands"
        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
    }
    Text {
        Layout.fillWidth: true
        text: "Your own command, started whenever that special workspace is opened with no window in it (e.g. foot -e btop, firefox --new-window https://...). Empty = the default; music and communication then use the apps chosen in Default apps. Enter or Save applies it at once."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; lineHeight: 1.3; wrapMode: Text.WordWrap
    }
    Repeater {
        model: [ { id: "special", name: "Scratch" }, { id: "music", name: "Music" }, { id: "communication", name: "Communication" },
                 { id: "sysmon", name: "System monitor" } ]
        delegate: RowLayout {
            id: spRow
            required property var modelData
            Layout.fillWidth: true
            spacing: 10
            Text {
                Layout.preferredWidth: 130
                text: spRow.modelData.name
                color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
            }
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 36; radius: 18
                color: Qt.alpha(root.pal.bg, 0.5); border.width: 1; border.color: spIn.activeFocus ? root.pal.accent : root.pal.lineSoft
                TextInput {
                    id: spIn
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                    clip: true; selectByMouse: true
                    text: root.specialCmds[spRow.modelData.id] || ""
                    onAccepted: spSave.clicked()
                    Text { visible: !parent.text && !parent.activeFocus; anchors.verticalCenter: parent.verticalCenter; text: "default"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                }
            }
            SChip {
                id: spSave
                pal: root.pal
                label: "Save"
                onClicked: root.setSpecial(spRow.modelData.id, spIn.text.trim())
            }
        }
    }
    component SChip: Chip { maxLabel: 1000 }
}
