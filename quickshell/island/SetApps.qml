import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "apps" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    width: parent ? parent.width : 0
    spacing: 14
    Repeater {
        model: [ { kind: "terminal", title: "Terminal" }, { kind: "browser", title: "Browser" }, { kind: "files", title: "File manager" },
                 { kind: "editor", title: "Code editor  (also used by Edit config)" }, { kind: "music", title: "Music player  (opens on the music workspace)" },
                 { kind: "chat", title: "Chat  (SUPER+D, opens on the communication workspace)" } ]
        delegate: ColumnLayout {
            id: appRow
            required property var modelData
            Layout.fillWidth: true
            spacing: 10
            Text { text: appRow.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
            Flow {
                Layout.fillWidth: true
                spacing: 12
                Repeater {
                    model: root.apps[appRow.modelData.kind] || []
                    delegate: Row {
                        id: appChip
                        required property var modelData
                        spacing: 4
                        SChip {
                            pal: root.pal
                            label: appChip.modelData.name
                            on: root.apps.current && root.apps.current[appRow.modelData.kind] === appChip.modelData.id
                            onClicked: root.setApp(appRow.modelData.kind, appChip.modelData.id)
                        }
                        // a website you added yourself: × takes it away again
                        Text {
                            visible: appChip.modelData.custom === true
                            anchors.verticalCenter: parent.verticalCenter
                            text: "×"
                            color: rmMa.containsMouse ? root.pal.accent : root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: 16
                            MouseArea { id: rmMa; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeWebApp(appChip.modelData.id) }
                        }
                    }
                }
                Text {
                    visible: (root.apps[appRow.modelData.kind] || []).length === 0
                    text: "none installed"
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
            }
            // Chat only: any website, opened in your browser as its own window (WhatsApp Web is already in the list)
            RowLayout {
                visible: appRow.modelData.kind === "chat"
                Layout.fillWidth: true
                spacing: 10
                Rectangle {
                    Layout.preferredWidth: 150; Layout.preferredHeight: 36; radius: 18
                    color: Qt.alpha(root.pal.bg, 0.5); border.width: 1; border.color: webName.activeFocus ? root.pal.accent : root.pal.lineSoft
                    TextInput {
                        id: webName
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        verticalAlignment: TextInput.AlignVCenter
                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        clip: true; selectByMouse: true
                        Text { visible: !parent.text && !parent.activeFocus; anchors.verticalCenter: parent.verticalCenter; text: "Name"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 36; radius: 18
                    color: Qt.alpha(root.pal.bg, 0.5); border.width: 1; border.color: webUrl.activeFocus ? root.pal.accent : root.pal.lineSoft
                    TextInput {
                        id: webUrl
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        verticalAlignment: TextInput.AlignVCenter
                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        clip: true; selectByMouse: true
                        onAccepted: addWeb.clicked()
                        Text { visible: !parent.text && !parent.activeFocus; anchors.verticalCenter: parent.verticalCenter; text: "Website, e.g. web.whatsapp.com"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                    }
                }
                SChip {
                    id: addWeb
                    pal: root.pal
                    label: "Add website"
                    onClicked: {
                        if (webName.text.trim() === "" || webUrl.text.trim() === "") return
                        root.addWebApp(webName.text.trim(), webUrl.text.trim())
                        webName.text = ""; webUrl.text = ""
                    }
                }
            }
        }
    }
    Text {
        Layout.fillWidth: true
        text: "Only installed apps are listed. A browser or file manager you pick also becomes the system default for links and folders. Websites (WhatsApp, Telegram, Messenger ...) open in your browser as their own window and are listed whenever a browser is installed; add any other site above. Something else missing? Add a line to ~/.config/Halcyon/apps.custom (see the top of scripts/apps.sh)."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    component SChip: Chip { maxLabel: 1000 }
}
