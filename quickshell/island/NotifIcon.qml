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
    // symbol (default): one plain symbol in the tone colour (your accent, red when urgent) on a soft tile of the same colour, picked
    //   from what the notification is about (a message, a download, the battery ...), so every popup matches the theme.
    // app: the app's own icon (or the picture it attached). pfp: your profile picture with the app icon as a badge (usePfp).
    property string mode: "symbol"
    readonly property bool symbolOn: mode === "symbol" && !usePfp
    readonly property int tileR: Math.round(size * 0.28)

    // ---- symbol mode: Material Design glyphs from the Nerd Font (checked to render in JetBrainsMono Nerd Font)
    function pickGlyph(n) {
        if (!n) return 0xF009A
        var app = String(n.appName || "").toLowerCase() + " " + String(n.desktopEntry || "").toLowerCase() + " " + String(n.appIcon || "").toLowerCase()
        var txt = (String(n.summary || "") + " " + String(n.body || "")).toLowerCase()
        function has(s, words) { for (var i = 0; i < words.length; i++) if (s.indexOf(words[i]) >= 0) return true; return false }
        if (n.urgency === 2 && has(txt, ["battery", "charge"])) return 0xF0083        // battery-alert
        // Halcyon's own senders
        if (has(app, ["calendar", "remind"])) return 0xF00ED                         // calendar
        if (has(app, ["focus"])) return 0xF13AB                                       // timer
        if (has(app, ["security", "antivirus", "firewall", "clamav"])) return 0xF0498 // shield
        if (has(app, ["notes"])) return 0xF039E                                       // note
        if (has(app, ["study"])) return 0xF0474                                       // school
        var own = has(app, ["luna", "halcyon", "hal"])
        // what kind of app
        if (has(app, ["discord", "telegram", "signal", "whatsapp", "slack", "element", "teams", "vesktop", "webcord", "irc", "matrix", "messenger", "zapzap"])) return 0xF0369
        if (has(app, ["thunderbird", "mail", "geary", "evolution", "betterbird"])) return 0xF01EE
        if (has(app, ["spotify", "music", "player", "mpv", "vlc", "rhythmbox", "elisa", "amberol", "cmus", "mpd", "lollypop"])) return 0xF075A
        if (has(app, ["steam", "lutris", "heroic", "game", "bottles", "prism"])) return 0xF0297
        if (has(app, ["networkmanager", "nm-applet", "network", "wifi", "iwd"])) return 0xF05A9
        if (has(app, ["blue"])) return 0xF00AF
        if (has(app, ["grim", "screenshot", "flameshot", "satty", "swappy", "spectacle"])) return 0xF0100
        if (has(app, ["pacman", "yay", "paru", "update", "package", "discover", "flatpak"])) return 0xF03D7
        if (has(app, ["foot", "kitty", "alacritty", "wezterm", "ghostty", "konsole", "terminal"])) return 0xF018D
        if (has(app, ["code", "codium", "zed", "studio", "jetbrains", "idea"])) return 0xF0169
        if (has(app, ["firefox", "chrom", "brave", "zen", "librewolf", "vivaldi", "browser", "epiphany", "qutebrowser"])) {
            return has(txt, ["download"]) ? 0xF01DA : 0xF059F
        }
        // what it says
        if (has(txt, ["download"])) return 0xF01DA
        if (has(txt, ["battery", "charg", "power"])) return 0xF0079
        if (has(txt, ["screenshot", "screen shot"])) return 0xF0100
        if (has(txt, ["record"])) return 0xF044A
        if (has(txt, ["update", "upgrade", "package"])) return 0xF03D7
        if (has(txt, ["wi-fi", "wifi", "network", "connected", "disconnected"])) return 0xF05A9
        if (has(txt, ["bluetooth"])) return 0xF00AF
        if (has(txt, ["volume", "audio", "microphone"])) return 0xF057E
        if (has(txt, ["copied", "clipboard"])) return 0xF0147
        if (has(txt, ["backup", "sync"])) return 0xF015F
        if (has(txt, ["disk", "storage", "space left"])) return 0xF02CA
        if (has(txt, ["error", "failed", "could not", "warning"])) return 0xF0028
        if (has(txt, ["done", "finished", "complete", "saved"])) return 0xF05E0
        if (has(txt, ["message", "mentioned", "replied"])) return 0xF0369
        return own ? 0xF0AE2 : 0xF009A                                                // Halcyon's sparkle, or a bell
    }
    readonly property int glyph: symbolOn ? pickGlyph(notif) : 0

    implicitWidth: size
    implicitHeight: size

    // Halcyon's own senders (the Calendar worker, the rice's scripts, Luna ...) wear the Halcyon sparkle, not an icon-theme picture or an
    // emoji. Other apps keep their own icon. A sender with an attached image (avatar, album art, screenshot) is never replaced.
    readonly property var halOwn: ["halcyon", "calendar", "hal", "luna", "notes", "study", "focus", "security", "game center", "gamecenter", "games", "hgl", "reminder", "reminders", "island", "sysmode", "firewall", "antivirus"]
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

    // ---- symbol mode: a soft tile of the tone colour with the symbol on it (no border: same look as the utilities tiles)
    Rectangle {
        anchors.fill: parent
        visible: root.symbolOn
        radius: root.tile ? root.tileR : width / 2
        color: Qt.alpha(root.tone, root.urgent ? 0.22 : 0.14)
        antialiasing: true
        Text {
            anchors.centerIn: parent
            visible: !root.isHal
            text: String.fromCodePoint(root.glyph)
            color: root.tone
            font.family: root.pal.font
            font.pixelSize: Math.round(root.size * 0.48)
        }
        // Halcyon's own senders (calendar, Game Center, focus, security ...): the Halcyon mark, not a calendar / timer / shield glyph
        HalMark {
            anchors.centerIn: parent
            visible: root.isHal
            pal: root.pal
            size: Math.round(root.size * 0.58)
        }
    }

    // ---- your profile picture, in a round mask (same technique as the tree's laptop node)
    Item {
        id: pfpBox
        anchors.fill: parent
        visible: root.pfpOn && !root.symbolOn

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
        visible: !root.symbolOn && (!root.pfpOn || ico.visible || mark.visible)

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
            source: root.symbolOn ? "" : root.src
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
