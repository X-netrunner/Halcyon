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
    property int idleLock: 5
    property int idleSleep: 30

    // default apps (scripts/apps.sh): what is installed per kind, and the one in use
    property var apps: ({ terminal: [], browser: [], files: [], current: ({ terminal: "", browser: "", files: "" }) })
    readonly property string appsScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/apps.sh"
    function setApp(kind, id) {
        Quickshell.execDetached(["bash", appsScript, "set", kind, id])
        var a = JSON.parse(JSON.stringify(apps))
        a.current[kind] = id
        apps = a                     // show it at once; the list is re-read below
        appsAgain.restart()
    }
    onOpenChanged: if (open && !appsProc.running) appsProc.running = true
    Timer { id: appsAgain; interval: 600; onTriggered: if (!appsProc.running) appsProc.running = true }
    Process {
        id: appsProc
        command: ["bash", root.appsScript, "list"]
        stdout: StdioCollector { onStreamFinished: { try { root.apps = JSON.parse(text) } catch (e) {} } }
    }

    signal setting(string key, var value)
    signal action(string id)          // wallpaper | config | cheatsheet | reload

    function show() { open = true }
    function hide() { open = false }
    function toggle() { open = !open }

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
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0976); label: "Next wallpaper"; onClicked: root.action("wallpaper") }
                            }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF0335)
                                value: (root.glassShift + 0.15) / 0.20
                                readout: (root.glassShift >= 0 ? "+" : "") + Math.round(root.glassShift * 100)
                                onMoved: v => root.setting("glassShift", Math.round((v * 0.20 - 0.15) * 100) / 100)
                            }
                            Text { text: "Transparency of the island, panels and overlays"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; Layout.topMargin: -6 }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF0A39)
                                value: root.rounding / 28
                                readout: root.rounding + " px"
                                onMoved: v => root.setting("rounding", Math.round(v * 28))
                            }
                            Text { text: "Window corner rounding"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; Layout.topMargin: -6 }
                            Slider {
                                Layout.fillWidth: true; pal: root.pal
                                glyph: String.fromCodePoint(0xF0B36)
                                value: root.gaps / 20
                                readout: root.gaps + " px"
                                onMoved: v => root.setting("gaps", Math.round(v * 20))
                            }
                            Text { text: "Gap between windows (outer gap is double)"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; Layout.topMargin: -6 }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Blur"; on: root.blur; onClicked: root.setting("blur", !root.blur) }
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Shadows"; on: root.shadows; onClicked: root.setting("shadows", !root.shadows) }
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
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Off"; on: root.motion === 0; onClicked: root.setting("motion", 0) }
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Fast"; on: root.motion === 0.5; onClicked: root.setting("motion", 0.5) }
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Normal"; on: root.motion === 1; onClicked: root.setting("motion", 1) }
                                }
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Window animations"; on: root.hyprAnim; onClicked: root.setting("hyprAnim", !root.hyprAnim) }
                            }

                            Section {
                            pal: root.pal
                                title: "BEHAVIOUR"
                                Layout.fillWidth: true
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Auto-hide bar"; on: root.autoHide; onClicked: root.setting("autoHide", !root.autoHide) }
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Do not disturb"; on: root.dnd; onClicked: root.setting("dnd", !root.dnd) }
                                }
                                Text { text: "Edge boxes (notifications, console, utilities)"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Hover"; on: !root.clickMode; onClicked: root.setting("clickMode", false) }
                                    Chip { Layout.fillWidth: true; pal: root.pal; label: "Click"; on: root.clickMode; onClicked: root.setting("clickMode", true) }
                                }
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Profile picture constellation in the tree"; on: root.profileStars; onClicked: root.setting("profileStars", !root.profileStars) }
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
                                        delegate: Chip {
                                            required property int modelData
                                            Layout.fillWidth: true; pal: root.pal
                                            label: String(modelData)
                                            on: root.notifHistoryMax === modelData
                                            onClicked: root.setting("notifHistoryMax", modelData)
                                        }
                                    }
                                }
                                Text { text: "When it is full the oldest one goes. Lowering it removes the oldest straight away."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            }
                        }

                        // ---------------------------------------------------------------- sleep & lock
                        Section {
                            pal: root.pal
                            title: "SLEEP & LOCK"
                            Layout.columnSpan: 2
                            Layout.fillWidth: true
                            Text { text: "Lock the screen when idle for"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: [0, 2, 5, 10, 15, 30]
                                    delegate: Chip {
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
                                    delegate: Chip {
                                        required property int modelData
                                        Layout.fillWidth: true; pal: root.pal
                                        label: modelData === 0 ? "Never" : (modelData >= 60 ? (modelData / 60) + " h" : modelData + " min")
                                        on: root.idleSleep === modelData
                                        onClicked: root.setting("idleSleep", modelData)
                                    }
                                }
                            }
                            Text {
                                text: "Counted from when you last touched the computer, so sleep comes after the lock. Caffeine stops both. Needs hypridle."
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
                                model: [ { kind: "terminal", title: "Terminal  (SUPER+T)" }, { kind: "browser", title: "Browser  (SUPER+W)" }, { kind: "files", title: "File manager  (SUPER+E)" } ]
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
                                            delegate: Chip {
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
                                text: "Only installed apps are listed. A browser or file manager you pick also becomes the system default for links and folders."
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
                                Chip { Layout.fillWidth: true; pal: root.pal; glyph: String.fromCodePoint(0xF0297); label: root.gaming ? "Gaming mode: on" : "Gaming mode"; on: root.gaming; onClicked: root.setting("gaming", !root.gaming) }
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Edit config"; onClicked: root.action("config") }
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Cheatsheet"; onClicked: root.action("cheatsheet") }
                                Chip { Layout.fillWidth: true; pal: root.pal; label: "Reload Hyprland"; onClicked: root.action("reload") }
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
