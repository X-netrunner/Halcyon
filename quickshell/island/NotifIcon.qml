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
//   tile (the popup cards): the same two pictures in a rounded square instead of a circle, on a faint tile of the tone colour
//       (red for an urgent notification). The centre's rows keep the round look.
Item {
    id: root
    property var pal
    property var notif
    property int size: 44
    property color tone: pal.accent
    property string avatar: ""          // path of the profile picture, "" = none (shell.qml: avatarPath)
    property bool usePfp: true
    property bool tile: false           // rounded square (popup cards) instead of round
    property bool urgent: false         // tile only: a stronger wash of the tone colour (red for an urgent one)
    readonly property int tileR: Math.round(size * 0.28)

    implicitWidth: size
    implicitHeight: size

    // Halcyon's own senders (the Calendar worker, the rice's scripts, Luna ...) wear the Halcyon sparkle, not an icon-theme picture or an
    // emoji. Other apps keep their own icon. A sender with an attached image (avatar, album art, screenshot) is never replaced.
    readonly property var halOwn: ["halcyon", "calendar", "hal", "luna", "notes", "study", "focus", "security"]
    readonly property bool isHal: !!notif && !hasImage && halOwn.indexOf(String(notif.appName || "").trim().toLowerCase()) >= 0

    readonly property bool hasImage: !!notif && notif.image !== ""
    // an icon theme name, a file path, or the image the app attached
    readonly property string src: {
        if (!notif) return ""
        if (notif.image && notif.image !== "") return notif.image
        var cands = []
        if (notif.appIcon) cands.push(notif.appIcon)
        if (notif.desktopEntry) cands.push(notif.desktopEntry)
        if (notif.appName) cands.push(notif.appName)

        for (var i = 0; i < cands.length; i++) {
            var raw = String(cands[i]).trim()
            if (!raw) continue
            if (raw.indexOf("/") === 0 || raw.indexOf("file:") === 0 || raw.indexOf("image:") === 0) return raw
            var cleaned = raw.replace(/\.desktop$/i, "")
            // 1. Try DesktopEntries lookup if available
            try {
                if (typeof DesktopEntries !== "undefined" && DesktopEntries.heuristicLookup) {
                    var de = DesktopEntries.heuristicLookup(cleaned)
                    if (de && de.icon) {
                        var dIcon = de.icon
                        if (dIcon.indexOf("/") === 0) return "file://" + dIcon
                        var p = Quickshell.iconPath(dIcon, true)
                        if (p) return p
                    }
                }
            } catch (e) {}
            // 2. Try exact name in Quickshell.iconPath
            var p1 = Quickshell.iconPath(cleaned, true)
            if (p1) return p1
            // 3. Try lowercase
            var p2 = Quickshell.iconPath(cleaned.toLowerCase(), true)
            if (p2) return p2
        }
        return Quickshell.iconPath("application-x-executable", true) || ""
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
            Rectangle { anchors.fill: parent; radius: root.tile ? root.tileR : width / 2; color: "black"; antialiasing: true }
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
            radius: root.tile ? root.tileR : width / 2
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
        radius: root.pfpOn ? (root.tile ? 6 : width / 2) : (root.tile ? root.tileR : Math.round(root.size * 0.32))
        color: (root.tile && !root.pfpOn) ? Qt.alpha(root.tone, root.urgent ? 0.26 : 0.12) : root.pal.surface
        border.width: root.pfpOn ? 1.5 : (root.tile ? 1 : 0)
        border.color: (root.tile && !root.pfpOn) ? Qt.alpha(root.tone, root.urgent ? 0.75 : 0.35) : root.pal.line
        clip: true
        // with the badge there is nothing to show when the app has no icon at all: no bell on top of your face
        visible: !root.pfpOn || ico.visible || mark.visible

        HalMark {
            id: mark
            anchors.centerIn: parent
            pal: root.pal
            size: Math.round(appBox.width * 0.56)
            visible: root.isHal
        }
        Image {
            id: ico
            anchors.centerIn: parent
            width: root.hasImage && !root.pfpOn ? appBox.width : Math.round(appBox.width * 0.6)
            height: width
            sourceSize: Qt.size(96, 96)
            fillMode: root.hasImage && !root.pfpOn ? Image.PreserveAspectCrop : Image.PreserveAspectFit
            source: root.src
            asynchronous: true
            visible: !root.isHal && status === Image.Ready
        }
        Text {
            anchors.centerIn: parent
            visible: !ico.visible && !mark.visible && !root.pfpOn
            text: String.fromCodePoint(0xF009A)
            color: root.tone
            font.family: root.pal.font
            font.pixelSize: Math.round(root.size * 0.4)
        }
    }
}
