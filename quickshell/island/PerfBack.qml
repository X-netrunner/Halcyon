import QtQuick

// The backdrop of every Performance look: the soft accent gradient of the box and the pane's own drifting stars (NoteStars.qml, which
// follows Settings > Appearance > Desktop builder and stops with Motion off).
Rectangle {
    id: root
    property var pal
    property bool running: false
    property int stars: 30
    anchors.fill: parent
    radius: pal.rLg
    clip: true
    border.width: pal.calm ? 0 : 1
    border.color: pal.lineSoft
    gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.alpha(root.pal.accent, 0.10) }
        GradientStop { position: 0.6; color: Qt.alpha(root.pal.accent2, 0.05) }
        GradientStop { position: 1.0; color: Qt.alpha(root.pal.text, 0.04) }
    }
    NoteStars {
        anchors.fill: parent
        pal: root.pal
        opt: ({})
        running: root.running
        count: root.stars
        speed: 0.6
    }
}
