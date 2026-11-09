import QtQuick

// Text you can select with the mouse and copy (Ctrl + C): a read-only TextEdit set up to look like Text. Used for what an AI or
// the console wrote, so it can be copied out; drawn text that is only a label stays a plain Text.
TextEdit {
    readOnly: true
    selectByMouse: true
    wrapMode: TextEdit.Wrap
    textFormat: TextEdit.PlainText
    selectionColor: Qt.rgba(0.45, 0.65, 0.9, 0.45)
    selectedTextColor: color
    cursorVisible: false
}
