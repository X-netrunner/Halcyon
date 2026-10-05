import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// Rice settings: one centred window, blurred backdrop, "node" cards in the same look as the SUPER+TAB tree.
// Everything here is applied live and remembered (settings.json); Hyprland values are re-applied when the island starts.
//   Esc or a click outside closes it.   Open: gear in the utilities panel, `>settings`, SUPER+F11.
Scope {
    id: root
    property var pal
    property string sysmode: ""
    property bool open: false

    // state (owned by shell.qml)
    property bool autoHide: false
    property bool clickMode: false
    property bool dnd: false
    property bool gaming: false
    property bool profileStars: true
    property var starData: null
    property real glassShift: 0
    property real motion: 1
    property int rounding: 18
    property int gaps: 8
    property bool blur: true
    property bool shadows: true
    property bool hyprAnim: true
    property int notifHistoryMax: 30
    property int notifMax: 5
    property bool compactSpecial: true
    property bool routeApps: true
    property bool clock24: false
    property bool growthOn: true
    property double growthMin: 0
    property real growthFullMin: 4320
    readonly property real growth: Math.min(1, growthMin / growthFullMin)
    property int idleLock: 5
    property int idleSleep: 30
    property int idleDim: 3
    property bool osdOn: true
    property string theme: "dark"          // dark | light
    property bool compactWs: true          // windows on workspace 3 move to 1 when nothing is before them
    property string hoverAction: "none"    // what hovering the bar does: none | perf | media | stats
    property string barScroll: "medium"    // how far you scroll / swipe on the bar to change page: low | medium | high
    property real scrollTouch: 0.3         // Hyprland touchpad scroll_factor
    property real scrollMouse: 1.0         // Hyprland (mouse wheel) scroll_factor

    // default apps (scripts/apps.sh): what is installed per kind, and the one in use
    property var apps: ({ terminal: [], browser: [], files: [], editor: [], music: [], chat: [], current: ({ terminal: "", browser: "", files: "", editor: "", music: "", chat: "" }) })
    readonly property string appsScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh"
    function setApp(kind, id) {
        Quickshell.execDetached(["bash", appsScript, "set", kind, id])
        var a = JSON.parse(JSON.stringify(apps))
        a.current[kind] = id
        apps = a                     // show it at once; the list is re-read below
        appsAgain.restart()
    }
    // wallpaper folder (scripts/wallpapers.sh): the folder, the wallpaper in use, every image in it
    property var wp: ({ dir: "", current: "", files: [] })
    property string wpText: ""
    readonly property string wpScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/wallpapers.sh"
    function wpAct(a) {
        // the file manager / picker window opens below this overlay, so get out of its way first
        if (a === "open" || a === "add" || a === "choose-dir") hide()
        Quickshell.execDetached(["bash", wpScript, a])
        wpAgain.restart()
    }
    function pickWallpaper(path) {
        var d = JSON.parse(JSON.stringify(wp))
        d.current = path
        wp = d                           // show the choice at once; the list is re-read below
        wallpaperSet(path)
        wpAgain.restart()
    }
    Timer { id: wpAgain; interval: 1500; onTriggered: if (!wpProc.running) wpProc.running = true }
    Timer { id: wpPoll; interval: 4000; running: root.open; repeat: true; triggeredOnStart: true; onTriggered: if (!wpProc.running) wpProc.running = true }
    Process {
        id: wpProc
        command: ["bash", root.wpScript, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.wpText) return          // nothing changed: keep the thumbnails as they are
                root.wpText = text
                try { root.wp = JSON.parse(text) } catch (e) {}
            }
        }
    }

    onOpenChanged: if (open && !appsProc.running) appsProc.running = true
    Timer { id: appsAgain; interval: 600; onTriggered: if (!appsProc.running) appsProc.running = true }
    Process {
        id: appsProc
        command: ["bash", root.appsScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.apps = JSON.parse(text) } catch (e) {} } }
    }

    signal setting(string key, var value)
    signal wallpaperSet(string path)  // a thumbnail was clicked
    signal action(string id)          // wallpaper | config | cheatsheet | reload

    function show() { open = true }
    function hide() { open = false }
    function toggle() { open = !open }

    component SChip: Chip { maxLabel: 1000 }

    component Section: Rectangle {
        id: sec
        property var pal
        property string title: ""
        default property alias content: col.data
        implicitHeight: col.implicitHeight + 36
        radius: sec.pal.rLg
        color: Qt.alpha(sec.pal.surface, 0.92)
        border.width: 1
        border.color: Qt.alpha(sec.pal.accent, 0.28)
        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
            spacing: 12
            Text {
                text: sec.title
                color: sec.pal.accent
                font.family: sec.pal.uiFont
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
            }
        }
    }

    PanelWindow {
        id: win
        visible: root.open || fade.opacity > 0.01
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "island-settings"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        Item {
            id: fade
            anchors.fill: parent
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            focus: root.open
            Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true } }

            Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.55) }
            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Glass {
                id: card
                pal: root.pal
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 880)
                height: Math.min(parent.height - 80, body.implicitHeight + 96)
                radius: root.pal.rXl
                opacityBody: root.pal.glassSolid - 0.02
                border.color: Qt.alpha(root.pal.accent, 0.35)
                scale: root.open ? 1 : 0.96
                Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                MouseArea { anchors.fill: parent }   // swallow clicks

                Backdrop { anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; avatarStars: root.starData; profileStars: root.profileStars; dots: 14; artStrength: 0.8; artFit: 0.85 }

                RowLayout {
                    id: head
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 26 }
                    Text { text: String.fromCodePoint(0xF0493); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                    Text { text: "Settings"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold; Layout.leftMargin: 6 }
                    Item { Layout.fillWidth: true }
                    RoundBtn { pal: root.pal; glyph: "✕"; size: 32; onClicked: root.hide() }
                }

                Flickable {
                    anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 26; topMargin: 18 }
                    contentWidth: width
                    contentHeight: body.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    GridLayout {
                        id: body
                        width: parent.width
                        columns: 2
                        columnSpacing: 16
                        rowSpacing: 16

                        // ---------------------------------------------------------------- look
                        Section {
                            pal: root.pal
                            title: "LOOK"
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            Text { text: "Theme"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0594); label: "Dark"; on: root.theme !== "light"; onClicked: root.setting("theme", "dark") }
                                SChip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0599); label: "Light"; on: root.theme === "light"; onClicked: root.setting("theme", "light") }
                            }
                            Text { text: "Island, panels, lock screen, window borders and apps (GTK / Qt) follow it. Colours still come from the wallpaper."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.topMargin: -6 }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF0335)
                                value: (root.glassShift + 0.15) / 0.20
                                readout: (root.glassShift >= 0 ? "+" : "") + Math.round(root.glassShift * 100)
                                onMoved: v => root.setting("glassShift", Math.round((v * 0.20 - 0.15) * 100) / 100)
                            }
                            Text { text: "Transparency of the island, panels and overlays"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; Layout.topMargin: -6; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF0A39)
                                value: root.rounding / 28
                                readout: root.rounding + " px"
                                onMoved: v => root.setting("rounding", Math.round(v * 28))
                            }
                            Text { text: "Window corner rounding"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; Layout.topMargin: -6; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF0B36)
                                value: root.gaps / 20
                                readout: root.gaps + " px"
                                onMoved: v => root.setting("gaps", Math.round(v * 20))
                            }
                            Text { text: "Gap between windows (outer gap is double)"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; Layout.topMargin: -6; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Blur"; on: root.blur; onClicked: root.setting("blur", !root.blur) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Shadows"; on: root.shadows; onClicked: root.setting("shadows", !root.shadows) }
                            }
                        }

                        // ---------------------------------------------------------------- motion
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 16

                            Section {
                            pal: root.pal
                                title: "MOTION"
                                Layout.fillWidth: true
                                Text { text: "Island animations"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Off"; on: root.motion === 0; onClicked: root.setting("motion", 0) }
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Fast"; on: root.motion === 0.5; onClicked: root.setting("motion", 0.5) }
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Normal"; on: root.motion === 1; onClicked: root.setting("motion", 1) }
                                }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Window animations"; on: root.hyprAnim; onClicked: root.setting("hyprAnim", !root.hyprAnim) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Compact special workspaces"; on: root.compactSpecial; onClicked: root.setting("compactSpecial", !root.compactSpecial) }
                                Text { text: "On: scratch / music / communication / monitor / tasks windows are smaller. Off: full size. Same switch as in the SUPER+TAB tree."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            }

                            Section {
                            pal: root.pal
                                title: "BEHAVIOUR"
                                Layout.fillWidth: true
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Auto-hide bar"; on: root.autoHide; onClicked: root.setting("autoHide", !root.autoHide) }
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Do not disturb"; on: root.dnd; onClicked: root.setting("dnd", !root.dnd) }
                                }
                                Text { text: "Edge boxes (notifications, console, utilities)"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Hover"; on: !root.clickMode; onClicked: root.setting("clickMode", false) }
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "Click"; on: root.clickMode; onClicked: root.setting("clickMode", true) }
                                }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Profile picture constellation in the tree"; on: root.profileStars; onClicked: root.setting("profileStars", !root.profileStars) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Send Spotify / Discord to their workspace"; on: root.routeApps; onClicked: root.setting("routeApps", !root.routeApps) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Keep workspaces compact"; on: root.compactWs; onClicked: root.setting("compactWs", !root.compactWs) }
                                Text { text: "On workspace 3 with nothing on 1 and 2? Its windows move to workspace 1."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.topMargin: -4 }
                                Text { text: "Clock in the bar"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "12 hour"; on: !root.clock24; onClicked: root.setting("clock24", false) }
                                    SChip { Layout.fillWidth: true; pal: root.pal; label: "24 hour"; on: root.clock24; onClicked: root.setting("clock24", true) }
                                }
                            }

                            Section {
                                pal: root.pal
                                title: "NOTIFICATIONS"
                                Layout.fillWidth: true
                                Text { text: "How many the notification centre keeps"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Repeater {
                                        model: [10, 20, 30, 50, 100]
                                        delegate: SChip {
                                            required property int modelData
                                            Layout.fillWidth: true; pal: root.pal
                                            label: String(modelData)
                                            on: root.notifHistoryMax === modelData
                                            onClicked: root.setting("notifHistoryMax", modelData)
                                        }
                                    }
                                }
                                Text { text: "Popups on screen at once"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Repeater {
                                        model: [1, 2, 3, 5, 8]
                                        delegate: SChip {
                                            required property int modelData
                                            Layout.fillWidth: true; pal: root.pal
                                            label: String(modelData)
                                            on: root.notifMax === modelData
                                            onClicked: root.setting("notifMax", modelData)
                                        }
                                    }
                                }
                                Text { text: "When it is full the oldest one goes. Lowering it removes the oldest straight away."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            }
                        }

                        // ---------------------------------------------------------------- constellations
                        Section {
                            pal: root.pal
                            title: "CONSTELLATIONS"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            Text {
                                text: "They grow the longer the island runs: the dragon unfolds two wings, the shield gains a second rim, a crest and a crown, and the profile picture gets more and more stars until it looks like the picture. Fully grown after 72 hours of use."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF04CE)
                                value: root.growth
                                readout: Math.round(root.growth * 100) + " %"
                                onMoved: v => root.setting("growthMin", Math.round(v * root.growthFullMin))
                            }
                            Text {
                                text: "Grown for " + (root.growthMin >= 60 ? Math.floor(root.growthMin / 60) + " h " + Math.round(root.growthMin % 60) + " min" : Math.round(root.growthMin) + " min") + ".  Drag the bar to preview any stage."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.topMargin: -6
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; label: root.growthOn ? "Growing: on" : "Growing: off"; on: root.growthOn; onClicked: root.setting("growthOn", !root.growthOn) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Start over"; onClicked: root.setting("growthReset", true) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Fully grown"; onClicked: root.setting("growthMin", root.growthFullMin) }
                            }
                        }

                        // ---------------------------------------------------------------- toggles + tools
                        Section {
                            pal: root.pal
                            title: "TOOLS"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Night light"; onClicked: root.action("nightlight") }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Touchpad on / off"; onClicked: root.action("touchpad") }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Edge gestures on / off"; onClicked: root.action("gestures") }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Terminal colours from wallpaper"; onClicked: root.action("termcolors") }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Detect RAM details"; onClicked: root.action("detect-ram") }
                            }
                            Text {
                                text: "Terminal colours: your open terminals and new ones follow the wallpaper colours (also done on every wallpaper change). Detect RAM asks for your password once to read the memory type and speed."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                        }

                        // ---------------------------------------------------------------- wallpaper
                        Section {
                            pal: root.pal
                            title: "WALLPAPER"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { text: String.fromCodePoint(0xF024B); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 16 }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.wp.dir !== "" ? root.wp.dir : "~/Pictures/Wallpapers"
                                    elide: Text.ElideMiddle
                                    color: root.pal.text
                                    font.family: root.pal.mono
                                    font.pixelSize: root.pal.tBody
                                }
                                Text { text: (root.wp.files ? root.wp.files.length : 0) + " images"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { pal: root.pal; glyph: String.fromCodePoint(0xF0976); label: "Next wallpaper"; onClicked: root.action("wallpaper") }
                                SChip { pal: root.pal; glyph: String.fromCodePoint(0xF0770); label: "Open folder"; onClicked: root.wpAct("open") }
                                SChip { pal: root.pal; glyph: String.fromCodePoint(0xF0415); label: "Add wallpapers…"; onClicked: root.wpAct("add") }
                                SChip { pal: root.pal; label: "Change folder…"; onClicked: root.wpAct("choose-dir") }
                                SChip { pal: root.pal; label: "Default folder"; onClicked: root.wpAct("reset-dir") }
                            }
                            Flickable {
                                id: thumbs
                                Layout.fillWidth: true
                                Layout.preferredHeight: 92
                                visible: root.wp.files && root.wp.files.length > 0
                                contentWidth: thumbRow.width
                                contentHeight: height
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                flickableDirection: Flickable.HorizontalFlick
                                Row {
                                    id: thumbRow
                                    spacing: 10
                                    Repeater {
                                        model: root.wp.files || []
                                        delegate: Rectangle {
                                            id: th
                                            required property var modelData
                                            readonly property bool now: root.wp.current === th.modelData.path
                                            width: 140; height: 86; radius: 12
                                            color: root.pal.surface
                                            border.width: th.now ? 2 : 1
                                            border.color: th.now ? root.pal.accent : root.pal.line
                                            Image {
                                                anchors.fill: parent; anchors.margins: 3
                                                source: "file://" + th.modelData.path
                                                sourceSize.width: 280; sourceSize.height: 170
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                cache: false
                                                opacity: thMa.containsMouse ? 1 : 0.92
                                            }
                                            MouseArea { id: thMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickWallpaper(th.modelData.path) }
                                        }
                                    }
                                }
                            }
                            Text {
                                text: root.wp.files && root.wp.files.length > 0 ? "Click one to use it. Drop more images into the folder (or Add wallpapers) and they show up here." : "No images in that folder yet. Use Add wallpapers, or open the folder and drop .jpg / .png / .webp files in."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                        }

                        // ---------------------------------------------------------------- bar
                        Section {
                            pal: root.pal
                            title: "BAR"
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            Text { text: "When you hover the bar"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { pal: root.pal; label: "Nothing"; on: root.hoverAction === "none"; onClicked: root.setting("hoverAction", "none") }
                                SChip { pal: root.pal; label: "Live stats"; on: root.hoverAction === "stats"; onClicked: root.setting("hoverAction", "stats") }
                                SChip { pal: root.pal; label: "Performance"; on: root.hoverAction === "perf"; onClicked: root.setting("hoverAction", "perf") }
                                SChip { pal: root.pal; label: "Media"; on: root.hoverAction === "media"; onClicked: root.setting("hoverAction", "media") }
                            }
                            Text {
                                text: ({ "none": "Hovering does nothing; click the battery / Wi-Fi icons or drag the bar for the pages.",
                                         "stats": "CPU, memory and temperature slide out inside the bar while the pointer is on it.",
                                         "perf": "The performance page opens by itself when the pointer rests on the bar, and closes when it leaves.",
                                         "media": "The media page opens by itself when the pointer rests on the bar, and closes when it leaves." })[root.hoverAction] || ""
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                            Text { text: "Scroll / swipe on the bar to change page"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.topMargin: 4 }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Long swipe"; on: root.barScroll === "low"; onClicked: root.setting("barScroll", "low") }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Medium"; on: root.barScroll === "medium"; onClicked: root.setting("barScroll", "medium") }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Sensitive"; on: root.barScroll === "high"; onClicked: root.setting("barScroll", "high") }
                            }
                        }

                        // ---------------------------------------------------------------- on-screen bar
                        Section {
                            pal: root.pal
                            title: "VOLUME & BRIGHTNESS BAR"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            SChip { Layout.fillWidth: true; pal: root.pal; label: root.osdOn ? "Slide in when volume / brightness / keyboard light changes: on" : "Slide in when volume / brightness / keyboard light changes: off"; on: root.osdOn; onClicked: root.setting("osdOn", !root.osdOn) }
                            Text {
                                text: "A bar slides up from the bottom of the screen for a moment, whether you used the keys, the touchpad edges, the panel sliders or another app. Keyboard light keys: XF86KbdBrightnessUp / Down."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                        }

                        // ---------------------------------------------------------------- scrolling
                        Section {
                            pal: root.pal
                            title: "SCROLL SENSITIVITY"
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            Text { text: "Touchpad scrolling"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF037D)
                                value: (root.scrollTouch - 0.1) / 1.4
                                readout: root.scrollTouch.toFixed(2) + "×"
                                onMoved: v => root.setting("scrollTouch", Math.round((0.1 + v * 1.4) * 20) / 20)
                            }
                            Text { text: "Mouse wheel scrolling"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF037D)
                                value: (root.scrollMouse - 0.25) / 2.75
                                readout: root.scrollMouse.toFixed(2) + "×"
                                onMoved: v => root.setting("scrollMouse", Math.round((0.25 + v * 2.75) * 20) / 20)
                            }
                            Text {
                                text: "How far a page moves for each bit of scrolling, in every app (Hyprland scroll_factor). Higher is faster."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                        }

                        // ---------------------------------------------------------------- sleep & lock
                        Section {
                            pal: root.pal
                            title: "SLEEP & LOCK"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            Text { text: "Dim the screen and keyboard light when idle for"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: [0, 1, 2, 3, 5, 10]
                                    delegate: SChip {
                                        required property int modelData
                                        Layout.fillWidth: true; pal: root.pal
                                        label: modelData === 0 ? "Never" : modelData + " min"
                                        on: root.idleDim === modelData
                                        onClicked: root.setting("idleDim", modelData)
                                    }
                                }
                            }
                            Text { text: "Lock the screen when idle for"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: [0, 2, 5, 10, 15, 30]
                                    delegate: SChip {
                                        required property int modelData
                                        Layout.fillWidth: true; pal: root.pal
                                        label: modelData === 0 ? "Never" : modelData + " min"
                                        on: root.idleLock === modelData
                                        onClicked: root.setting("idleLock", modelData)
                                    }
                                }
                            }
                            Text { text: "Go to sleep when idle for"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: [0, 15, 30, 60, 120, 240]
                                    delegate: SChip {
                                        required property int modelData
                                        Layout.fillWidth: true; pal: root.pal
                                        label: modelData === 0 ? "Never" : (modelData >= 60 ? (modelData / 60) + " h" : modelData + " min")
                                        on: root.idleSleep === modelData
                                        onClicked: root.setting("idleSleep", modelData)
                                    }
                                }
                            }
                            Text {
                                text: "Counted from when you last touched the computer. Dimming goes to the lowest screen brightness and switches the keyboard light off; any key or mouse move puts both back. Caffeine stops all three. Needs hypridle."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                        }

                        // ---------------------------------------------------------------- default apps
                        Section {
                            pal: root.pal
                            title: "DEFAULT APPS"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            Repeater {
                                model: [ { kind: "terminal", title: "Terminal" }, { kind: "browser", title: "Browser" }, { kind: "files", title: "File manager" },
                                         { kind: "editor", title: "Code editor  (also used by Edit config)" }, { kind: "music", title: "Music player  (opens on the music workspace)" },
                                         { kind: "chat", title: "Chat  (opens on the communication workspace)" } ]
                                delegate: ColumnLayout {
                                    id: appRow
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text { text: appRow.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Repeater {
                                            model: root.apps[appRow.modelData.kind] || []
                                            delegate: SChip {
                                                required property var modelData
                                                pal: root.pal
                                                label: modelData.name
                                                on: root.apps.current && root.apps.current[appRow.modelData.kind] === modelData.id
                                                onClicked: root.setApp(appRow.modelData.kind, modelData.id)
                                            }
                                        }
                                        Text {
                                            visible: (root.apps[appRow.modelData.kind] || []).length === 0
                                            text: "none installed"
                                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                        }
                                    }
                                }
                            }
                            Text {
                                text: "Only installed apps are listed. A browser or file manager you pick also becomes the system default for links and folders. Something missing? Add a line to ~/.config/Halcyon/apps.custom (see the top of scripts/apps.sh)."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true
                            }
                        }

                        // ---------------------------------------------------------------- gaming + rice (full width)
                        Section {
                            pal: root.pal
                            title: "PERFORMANCE & RICE"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SChip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0297); label: root.gaming ? "Gaming mode: on" : "Gaming mode"; on: root.gaming; onClicked: root.setting("gaming", !root.gaming) }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Edit config"; onClicked: { root.action("config"); root.hide() } }
                                SChip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF030C); label: "Shortcuts"; onClicked: { root.hide(); root.action("cheatsheet") } }
                                SChip { Layout.fillWidth: true; pal: root.pal; label: "Reload Hyprland"; onClicked: root.action("reload") }
                            }
                            Text {
                                text: "Gaming mode: performance profile, effects off, instant island animations, background helpers stopped (list in ~/.config/Halcyon/gamemode.conf). SUPER+F10 toggles it."
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: 10
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }
    }
}
