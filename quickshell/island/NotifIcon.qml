import QtQuick
import Quickshell

// App icon (or the image the app attached: avatar, album art, screenshot) with a bell as fallback.
// Used by the popup cards and the notification-centre rows.
Rectangle {
    id: root
    property var pal
    property var notif
    property int size: 44
    property color tone: pal.accent

    readonly property bool hasImage: !!notif && notif.image !== ""
    // an icon theme name, a file path, or the image the app attached
    readonly property string src: {
        if (!notif) return ""
        if (notif.image !== "") return notif.image
        var a = notif.appIcon
        if (!a) return ""
        if (a.indexOf("/") === 0 || a.indexOf("file:") === 0 || a.indexOf("image:") === 0) return a
        return Quickshell.iconPath(a, true)
    }

    implicitWidth: size
    implicitHeight: size
    radius: Math.round(size * 0.32)
    color: pal.surface
    clip: true

    Image {
        id: ico
        anchors.centerIn: parent
        width: root.hasImage ? root.size : Math.round(root.size * 0.6)
        height: width
        sourceSize: Qt.size(96, 96)
        fillMode: root.hasImage ? Image.PreserveAspectCrop : Image.PreserveAspectFit
        source: root.src
        asynchronous: true
        visible: status === Image.Ready
    }
    Text {
        anchors.centerIn: parent
        visible: !ico.visible
        text: String.fromCodePoint(0xF009A)
        color: root.tone
        font.family: root.pal.font
        font.pixelSize: Math.round(root.size * 0.4)
    }
}
