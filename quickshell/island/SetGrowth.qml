import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "growth" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    width: parent ? parent.width : 0
    spacing: 12
    Text {
        Layout.fillWidth: true
        text: "They grow the longer the island runs: the dragon unfolds two wings, the shield gains a second rim, a crest and a crown, and the profile picture gets more and more stars until it looks like the picture. Fully grown after 72 hours of use."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    Slider {
        Layout.fillWidth: true; pal: root.pal
        glyph: String.fromCodePoint(0xF04CE)
        value: root.growth
        readout: Math.round(root.growth * 100) + " %"
        onMoved: v => root.setting("growthMin", Math.round(v * root.growthFullMin))
    }
    Text {
        Layout.fillWidth: true
        text: "Grown for " + (root.growthMin >= 60 ? Math.floor(root.growthMin / 60) + " h " + Math.round(root.growthMin % 60) + " min" : Math.round(root.growthMin) + " min") + ".  Drag the bar to preview any stage."
        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
    }
    Flow {
        Layout.fillWidth: true
        spacing: 12
        SChip { pal: root.pal; label: root.growthOn ? "Growing: on" : "Growing: off"; on: root.growthOn; onClicked: root.setting("growthOn", !root.growthOn) }
        ActionChip { pal: root.pal; label: "Start over"; doneLabel: "Reset"; onClicked: root.setting("growthReset", true) }
        ActionChip { pal: root.pal; label: "Fully grown"; doneLabel: "Grown"; onClicked: root.setting("growthMin", root.growthFullMin) }
    }
    component SChip: Chip { maxLabel: 1000 }
}
