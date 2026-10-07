import QtQuick
import QtQuick.Effects
import Quickshell

// The picture next to a notification. Used by the popup cards and the notification-centre rows.
//
//   usePfp (default, Settings > Panels & notifications > "Notification picture"):
//       YOUR profile picture, round, with the app's own icon as a small badge in the corner so you still see who sent it.
//       No profile picture found (scripts/avatar.sh)? Then it is the app icon, as below.
//   app icon:
//       the app's icon (or the image the app attached: avatar, album art, screenshot), a bell as the last fallback.
Item {
    id: root
    property var pal
    property var notif
    property int size: 44
    property color tone: pal.accent
    property string avatar: ""          // path of the profile picture, "" = none (shell.qml: avatarPath)
    property bool usePfp: true

    implicitWidth: size
    implicitHeight: size

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
    // the profile picture is shown once it has really loaded; until then (or when it never does) the app icon is
    readonly property bool pfpOn: usePfp && avatar !== "" && pfp.status === Image.Ready

    // ---- your profile picture, in a round mask (same technique as the tree's laptop node)
    Item {
        id: pfpBox
        anchors.fill: parent
        visible: root.pfpOn

        Image {
            id: pfp
            anchors.fill: parent
            visible: false
            source: root.usePfp && root.avatar !== "" ? "file://" + root.avatar : ""
            sourceSize: Qt.size(Math.max(96, root.size * 2), Math.max(96, root.size * 2))
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            mipmap: true
        }
        Item {
            id: pfpMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            layer.smooth: true
            layer.samples: 8
            Rectangle { anchors.fill: parent; radius: width / 2; color: "black"; antialiasing: true }
        }
        MultiEffect {
            anchors.fill: parent
            visible: root.pfpOn
            source: pfp
            maskEnabled: true
            maskSource: pfpMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
        // a thin ring over the edge keeps the rim clean on any picture
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            antialiasing: true
            border.width: 1.5
            border.color: Qt.alpha(root.tone, 0.7)
        }
    }

    // ---- the app's own icon: the whole icon, or (next to the profile picture) a small badge in the corner
    Rectangle {
        id: appBox
        readonly property real badge: Math.round(root.size * 0.46)
        width: root.pfpOn ? badge : root.size
        height: width
        x: root.pfpOn ? root.size - width + 2 : 0
        y: root.pfpOn ? root.size - height + 2 : 0
        radius: root.pfpOn ? width / 2 : Math.round(root.size * 0.32)
        color: root.pal.surface
        border.width: root.pfpOn ? 1.5 : 0
        border.color: root.pal.line
        clip: true
        // with the badge there is nothing to show when the app has no icon at all: no bell on top of your face
        visible: !root.pfpOn || ico.visible

        Image {
            id: ico
            anchors.centerIn: parent
            width: root.hasImage && !root.pfpOn ? appBox.width : Math.round(appBox.width * 0.6)
            height: width
            sourceSize: Qt.size(96, 96)
            fillMode: root.hasImage && !root.pfpOn ? Image.PreserveAspectCrop : Image.PreserveAspectFit
            source: root.src
            asynchronous: true
            visible: status === Image.Ready
        }
        Text {
            anchors.centerIn: parent
            visible: !ico.visible && !root.pfpOn
            text: String.fromCodePoint(0xF009A)
            color: root.tone
            font.family: root.pal.font
            font.pixelSize: Math.round(root.size * 0.4)
        }
    }
}
