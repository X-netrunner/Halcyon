import QtQuick

// Part of QuickChat.qml (the AI chatbox).
Rectangle {
    id: fd
    required property var pal
    property alias text: ti.text
    property string placeholder: ""
    property bool secret: false
    signal committed(string value)
    signal escaped()
    implicitHeight: 26
    radius: 8
    color: pal.field
    border.width: 1
    border.color: ti.activeFocus ? pal.lineFocus : pal.lineSoft
    TextInput {
        id: ti
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 9; rightMargin: 9 }
        color: "#ffffff"
        selectionColor: Qt.alpha(fd.pal.accent, 0.45)
        font.family: fd.pal.mono
        font.pixelSize: 11
        clip: true
        echoMode: fd.secret ? TextInput.Password : TextInput.Normal
        passwordCharacter: "•"
        onEditingFinished: fd.committed(text)
        Keys.onEscapePressed: fd.escaped()
    }
    Text {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 9 }
        visible: ti.text === ""
        text: fd.placeholder
        color: Qt.alpha(fd.pal.muted, 0.8)
        font.family: fd.pal.mono
        font.pixelSize: 11
    }
}
