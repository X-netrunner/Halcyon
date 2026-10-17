import QtQuick

// A small one-line text field for the Widget builder (a button list, a place name, your own words, a colour like #7ef2d0).
// `committed(text)` fires while you type (after a short pause) and when you press Enter or leave the field.
Rectangle {
    id: f
    property var pal
    property string text: ""
    property string hintText: ""
    signal committed(string t)

    implicitHeight: 34
    radius: 17
    color: Qt.alpha(pal.bg, 0.55)
    border.width: 1
    border.color: inp.activeFocus ? pal.lineFocus : pal.line

    // the last value sent: the typing pause AND leaving the field both commit, and the second one used to send the same text again
    // (every send rewrites and saves the whole widget layout)
    property string sent: ""
    function send(v) { if (v === sent) return; sent = v; committed(v) }
    onTextChanged: { sent = text; if (inp.text !== text && !inp.activeFocus) inp.text = text }
    Component.onCompleted: { inp.text = text; sent = text }

    Text {
        anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
        visible: inp.text === ""
        text: f.hintText
        color: f.pal.muted; font.family: f.pal.uiFont; font.pixelSize: f.pal.tBody
    }
    TextInput {
        id: inp
        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
        verticalAlignment: TextInput.AlignVCenter
        color: f.pal.text
        selectionColor: Qt.alpha(f.pal.accent, 0.4)
        font.family: f.pal.uiFont; font.pixelSize: f.pal.tBody
        clip: true
        onTextEdited: pause.restart()
        onEditingFinished: { pause.stop(); f.send(text) }
        Keys.onEscapePressed: focus = false
    }
    Timer { id: pause; interval: 450; onTriggered: f.send(inp.text) }
}
