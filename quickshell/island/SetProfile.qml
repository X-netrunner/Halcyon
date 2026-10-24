import QtQuick
import QtQuick.Layouts
import Quickshell

// Settings custom leaf "profile" (Settings > Appearance > Profile; it used to be the Overview's "Edit profile" card): the name
// on the laptop node of the Overview and the picture its constellation is made from. `root` is the Settings scope, root.env the
// shell, which keeps both (profileName / profileAvatar) and saves them (setProfileInfo). Browse opens the island's own picture
// picker over Settings (root.browseImage): a file dialog would be an ordinary window, under the Settings layer.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: pf
    width: parent ? parent.width : 0
    spacing: 10

    readonly property var shell: root ? root.env : null
    readonly property var pal: root ? root.pal : null
    readonly property string savedName: shell ? String(shell.profileName || "") : ""
    readonly property string savedAvatar: shell ? String(shell.profileAvatar || "") : ""
    readonly property bool changed: nameIn.text.trim() !== savedName || avIn.text.trim() !== savedAvatar
    Component.onCompleted: { nameIn.text = savedName; avIn.text = savedAvatar }

    component Field: Rectangle {
        property var pal                 // (an inline component can not see the ids of this file)
        default property alias content: inner.data
        Layout.fillWidth: true
        implicitHeight: 38
        radius: height / 2
        color: pal.zen ? pal.field : Qt.alpha(pal.bg, 0.55)
        Item { id: inner; anchors { fill: parent; leftMargin: 16; rightMargin: 16 } }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        Text { Layout.preferredWidth: 110; text: "Name"; color: pf.pal.muted; font.family: pf.pal.uiFont; font.pixelSize: pf.pal.tBody }
        Field {
            pal: pf.pal
            TextInput {
                id: nameIn
                anchors.fill: parent
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: pf.pal.text
                selectionColor: Qt.alpha(pf.pal.accent, 0.4)
                font.family: pf.pal.uiFont; font.pixelSize: pf.pal.tBody
                Keys.onReturnPressed: pf.save()
                Text { anchors.verticalCenter: parent.verticalCenter; visible: nameIn.text === ""; text: Quickshell.env("USER"); color: pf.pal.muted; font: nameIn.font }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        Text { Layout.preferredWidth: 110; text: "Picture"; color: pf.pal.muted; font.family: pf.pal.uiFont; font.pixelSize: pf.pal.tBody }
        Field {
            pal: pf.pal
            TextInput {
                id: avIn
                anchors.fill: parent
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: pf.pal.text
                selectionColor: Qt.alpha(pf.pal.accent, 0.4)
                font.family: pf.pal.uiFont; font.pixelSize: pf.pal.tBody
                Keys.onReturnPressed: pf.save()
                Text { anchors.verticalCenter: parent.verticalCenter; visible: avIn.text === ""; text: "~/.face"; color: pf.pal.muted; font: avIn.font }
            }
        }
        Chip { pal: pf.pal; label: "Browse"; onClicked: pf.root.browseImage(avIn.text.trim() !== "" ? avIn.text.trim() : Quickshell.env("HOME") + "/Pictures", function (p) { avIn.text = p }) }
    }
    RowLayout {
        Layout.fillWidth: true
        visible: pf.changed
        Item { Layout.fillWidth: true }
        Chip { pal: pf.pal; label: "Undo"; onClicked: { nameIn.text = pf.savedName; avIn.text = pf.savedAvatar } }
        Chip { pal: pf.pal; label: "Save"; primary: true; onClicked: pf.save() }
    }

    function save() {
        if (shell && shell.setProfileInfo) shell.setProfileInfo(nameIn.text.trim(), avIn.text.trim())
    }
}
