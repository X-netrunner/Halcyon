import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "swatches" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    width: parent ? parent.width : 0
    spacing: 10
    Row {
        spacing: 12
        Repeater {
            model: [ root.pal.accent, root.pal.accent2, root.pal.surfaceHi, root.pal.surface, root.pal.bg ]
            delegate: Rectangle { required property var modelData; width: 34; height: 18; radius: 9; color: modelData; border.width: 1; border.color: root.pal.line }
        }
    }
    Text { text: "Now in use: accent, second accent, surfaces"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
    Row {
        spacing: 10
        Repeater {
            model: root.pal.ring
            delegate: Rectangle {
                required property var modelData
                width: 22; height: 22; radius: 11
                color: Qt.hsla(modelData.h, modelData.s, modelData.l, 1)
                border.width: 1; border.color: root.pal.line
            }
        }
    }
    Text {
        text: root.pal.ring.length > 0 ? "The wallpaper's colours" + (root.pal.cycling ? " (the accent is moving through them)" : "") : "Colours of the wallpaper show up here"
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
    }
}
