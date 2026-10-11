import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "BarLayout.js" as BL

// Part of the bar builder window (BarBuilderWindow.qml). `bb` is that window.
Row {
    required property var bb
    id: nb
    property string label: ""
    property var value: null            // px, or null = automatic
    property int shown: 0               // what automatic comes to, in px
    property int maxV: 80
    property string autoWord: "auto"
    signal commit(var v)
    spacing: 6
    function now() { return value === null ? shown : value }
    onValueChanged: fld.text = value === null ? "" : String(value)
    Component.onCompleted: fld.text = value === null ? "" : String(value)

    Text { anchors.verticalCenter: parent.verticalCenter; text: nb.label; color: bb.pal.muted; font.family: bb.pal.uiFont; font.pixelSize: 11 }
    Rectangle {
        width: 26; height: 28; radius: 14
        anchors.verticalCenter: parent.verticalCenter
        color: mma.containsMouse ? Qt.alpha(bb.pal.surfaceHi, 0.9) : Qt.alpha(bb.pal.surface, 0.8)
        border.width: 1; border.color: bb.pal.lineSoft
        Text { anchors.centerIn: parent; text: "−"; color: bb.pal.text; font.family: bb.pal.uiFont; font.pixelSize: 14 }
        MouseArea { id: mma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: nb.commit(Math.max(0, nb.now() - 1)) }
    }
    Rectangle {
        width: 76; height: 28; radius: 14
        anchors.verticalCenter: parent.verticalCenter
        color: Qt.alpha(bb.pal.bg, 0.5)
        border.width: 1
        border.color: fld.activeFocus ? bb.pal.accent : Qt.alpha(bb.pal.accent, nb.value === null ? 0.18 : 0.4)
        TextInput {
            id: fld
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            horizontalAlignment: TextInput.AlignHCenter
            verticalAlignment: TextInput.AlignVCenter
            color: bb.pal.text
            selectByMouse: true
            clip: true
            font.family: bb.pal.uiFont
            font.pixelSize: 12
            font.weight: Font.Medium
            inputMethodHints: Qt.ImhDigitsOnly
            validator: IntValidator { bottom: 0; top: nb.maxV }
            onEditingFinished: { nb.commit(text === "" ? null : parseInt(text)); bb.forceActiveFocus() }
        }
        Text {
            visible: fld.text === "" && !fld.activeFocus
            anchors.centerIn: parent
            text: nb.autoWord + " · " + nb.shown
            color: bb.pal.muted
            font.family: bb.pal.uiFont
            font.pixelSize: 11
            font.italic: true
        }
    }
    Rectangle {
        width: 26; height: 28; radius: 14
        anchors.verticalCenter: parent.verticalCenter
        color: pma.containsMouse ? Qt.alpha(bb.pal.surfaceHi, 0.9) : Qt.alpha(bb.pal.surface, 0.8)
        border.width: 1; border.color: bb.pal.lineSoft
        Text { anchors.centerIn: parent; text: "+"; color: bb.pal.text; font.family: bb.pal.uiFont; font.pixelSize: 14 }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: nb.commit(Math.min(nb.maxV, nb.now() + 1)) }
    }
    Text { anchors.verticalCenter: parent.verticalCenter; text: "px"; color: bb.pal.muted; font.family: bb.pal.uiFont; font.pixelSize: 11 }
    Text {
        visible: nb.value !== null && nb.autoWord === "auto"
        anchors.verticalCenter: parent.verticalCenter
        text: "↺ auto"
        color: ama.containsMouse ? bb.pal.accent : bb.pal.muted
        font.family: bb.pal.uiFont
        font.pixelSize: 11
        MouseArea { id: ama; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: nb.commit(null) }
    }
}
