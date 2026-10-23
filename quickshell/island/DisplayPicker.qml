import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// SUPER + P -> Halcyon Display & Projector Manager
// Native Quickshell modal styled with Halcyon glass cards and moving stars.
Scope {
    id: root
    property var pal
    property bool open: false
    property int selectedIndex: 0
    property string activeMode: "auto"
    property string monitorInfo: "Detecting displays..."
    property string internalMon: ""
    property string externalMon: ""

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/display-manager.sh"

    function show() {
        selectedIndex = 0
        readStateProc.running = true
        detectProc.running = true
        open = true
    }

    function hide() {
        open = false
    }

    function toggle() {
        if (open) hide(); else show()
    }

    function apply(mode) {
        hide()
        Quickshell.execDetached([root.script, mode])
    }

    // Process to read current saved display mode
    Process {
        id: readStateProc
        command: ["sh", "-c", "f=\"$HOME/.local/state/island/display-mode.env\"; if [ -f \"$f\" ]; then grep '^MODE=' \"$f\" | cut -d= -f2; else echo auto; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = text.trim()
                if (m) root.activeMode = m
            }
        }
    }

    // Process to detect connected displays via hyprctl
    Process {
        id: detectProc
        command: ["hyprctl", "monitors", "all", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var mons = JSON.parse(text)
                    if (!mons || mons.length === 0) {
                        root.monitorInfo = "No displays detected"
                        return
                    }
                    var intName = "", extName = ""
                    for (var i = 0; i < mons.length; i++) {
                        var n = mons[i].name
                        if (/^(eDP|LVDS|DSI)/.test(n) && !intName) intName = n
                    }
                    if (!intName && mons.length > 0) intName = mons[0].name
                    for (var j = 0; j < mons.length; j++) {
                        if (mons[j].name !== intName) { extName = mons[j].name; break }
                    }
                    root.internalMon = intName
                    root.externalMon = extName
                    if (extName) {
                        root.monitorInfo = "Laptop: " + intName + "  •  External: " + extName
                    } else {
                        root.monitorInfo = "Single Display: " + intName + " (No external projector/monitor)"
                    }
                } catch (e) {
                    root.monitorInfo = "Displays ready"
                }
            }
        }
    }

    readonly property var items: [
        {
            id: "mirror",
            num: "1",
            key: Qt.Key_M,
            numKey: Qt.Key_1,
            badge: "M / 1",
            title: "Mirror Screen (Projector Clone)",
            desc: "Duplicate your screen onto an external projector, TV, or monitor for presentations.",
            icon: "󰍺"
        },
        {
            id: "extend-right",
            num: "2",
            key: Qt.Key_R,
            numKey: Qt.Key_2,
            badge: "R / 2",
            title: "Extend Right",
            desc: "Dual monitor workspace with external display positioned to the right.",
            icon: "󰍹"
        },
        {
            id: "extend-left",
            num: "3",
            key: Qt.Key_L,
            numKey: Qt.Key_3,
            badge: "L / 3",
            title: "Extend Left",
            desc: "Dual monitor workspace with external display positioned to the left.",
            icon: "󰍹"
        },
        {
            id: "external-only",
            num: "4",
            key: Qt.Key_P,
            numKey: Qt.Key_4,
            badge: "P / 4",
            title: "Projector / External Only",
            desc: "Laptop screen turns off. Video outputs exclusively to the projector/monitor.",
            icon: "󰍺"
        },
        {
            id: "internal-only",
            num: "5",
            key: Qt.Key_O,
            numKey: Qt.Key_5,
            badge: "O / 5",
            title: "Laptop Screen Only",
            desc: "Turn off external projector / display and keep only the built-in laptop screen.",
            icon: "󰌢"
        },
        {
            id: "auto",
            num: "6",
            key: Qt.Key_A,
            numKey: Qt.Key_6,
            badge: "A / 6",
            title: "Auto-Detect & Reset",
            desc: "Restore default auto-detected resolutions and layout for all connected displays.",
            icon: "󰑐"
        }
    ]

    LazyLoader {
        active: root.open
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-display"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: fade
                anchors.fill: parent
                opacity: root.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal ? root.pal.dMed : 180; easing.type: Easing.InOutSine } }
                focus: root.open

                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true; return }
                    if (e.key === Qt.Key_Up) {
                        root.selectedIndex = (root.selectedIndex - 1 + root.items.length) % root.items.length
                        e.accepted = true; return
                    }
                    if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) {
                        root.selectedIndex = (root.selectedIndex + 1) % root.items.length
                        e.accepted = true; return
                    }
                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Space) {
                        if (root.items[root.selectedIndex]) {
                            root.apply(root.items[root.selectedIndex].id)
                        }
                        e.accepted = true; return
                    }
                    for (var i = 0; i < root.items.length; i++) {
                        var it = root.items[i]
                        if (e.key === it.key || e.key === it.numKey) {
                            root.apply(it.id)
                            e.accepted = true
                            return
                        }
                    }
                }

                // Dimmed backdrop
                Rectangle {
                    anchors.fill: parent
                    color: Qt.alpha(root.pal ? root.pal.bg : "#0f0f14", 0.55)
                    MouseArea { anchors.fill: parent; onClicked: root.hide() }
                }

                // Center Card
                Rectangle {
                    id: card
                    anchors.centerIn: parent
                    width: 660
                    height: 580
                    radius: root.pal ? root.pal.rXl : 28
                    color: Qt.alpha(root.pal ? root.pal.surface : "#1a1d28", root.pal && root.pal.solid ? 1 : 0.88)
                    border.width: 1.5
                    border.color: Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.35)
                    scale: root.open ? 1 : 0.95
                    Behavior on scale { NumberAnimation { duration: root.pal ? root.pal.dSlow : 240; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal ? root.pal.curve : [0.16, 1, 0.3, 1] } }
                    clip: true
                    MouseArea { anchors.fill: parent } // swallow click

                    // Moving Stars drifting in background (Halcyon signature)
                    BarStars {
                        z: 1
                        anchors.fill: parent
                        anchors.margins: 12
                        pal: root.pal
                        count: 14
                        loopMs: 120000
                        sizeScale: 1.35
                        active: root.open
                        visible: root.open
                    }

                    ColumnLayout {
                        z: 2
                        anchors.fill: parent
                        anchors.margins: 28
                        spacing: 16

                        // Header
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14

                            Rectangle {
                                width: 44
                                height: 44
                                radius: root.pal ? root.pal.rMd : 14
                                color: Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.16)
                                border.width: 1
                                border.color: Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.35)

                                Text {
                                    anchors.centerIn: parent
                                    text: "󰍹"
                                    font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                                    font.pixelSize: 22
                                    color: root.pal ? root.pal.accent : "#9aa9d4"
                                }
                            }

                            BoxTitle {
                                pal: root.pal
                                size: 18
                                title: "Display & Projector Manager"
                                sub: root.monitorInfo
                            }

                            // Close Button
                            Rectangle {
                                width: 32
                                height: 32
                                radius: 16
                                color: closeMa.containsMouse ? Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.2) : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "✕"
                                    font.pixelSize: 13
                                    font.family: root.pal ? root.pal.uiFont : "Sans Serif"
                                    color: root.pal ? root.pal.muted : "#9496a8"
                                }
                                MouseArea {
                                    id: closeMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.hide()
                                }
                            }
                        }

                        // Divider
                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.14)
                        }

                        // Options list
                        ListView {
                            id: listView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 8
                            clip: true
                            model: root.items
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                id: optRow
                                required property var modelData
                                required property int index
                                readonly property bool isSelected: index === root.selectedIndex
                                readonly property bool isActive: root.activeMode === modelData.id
                                readonly property bool hovered: itemMa.containsMouse

                                width: listView.width
                                height: 58
                                radius: root.pal ? root.pal.rMd : 14
                                color: isSelected
                                    ? Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.22)
                                    : (hovered
                                        ? Qt.alpha(root.pal ? root.pal.surfaceHi : "#272b3d", 0.7)
                                        : Qt.alpha(root.pal ? root.pal.bg : "#14161f", 0.45))
                                border.width: isSelected || isActive ? 1.5 : 1
                                border.color: isActive
                                    ? (root.pal ? root.pal.good : "#8fcfa0")
                                    : (isSelected
                                        ? Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.8)
                                        : Qt.alpha(root.pal ? root.pal.line : "#272b3d", 0.35))

                                Behavior on color { ColorAnimation { duration: 120 } }
                                Behavior on border.color { ColorAnimation { duration: 120 } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 16
                                    anchors.rightMargin: 16
                                    spacing: 14

                                    // Icon
                                    Text {
                                        text: modelData.icon
                                        font.family: root.pal ? root.pal.font : "JetBrainsMono Nerd Font"
                                        font.pixelSize: 22
                                        color: isActive
                                            ? (root.pal ? root.pal.good : "#8fcfa0")
                                            : (isSelected ? (root.pal ? root.pal.accent : "#9aa9d4") : (root.pal ? root.pal.text : "#dcdde8"))
                                    }

                                    // Title & Desc
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        RowLayout {
                                            spacing: 8
                                            Text {
                                                text: modelData.title
                                                font.family: root.pal ? root.pal.uiFont : "Sans Serif"
                                                font.pixelSize: 13
                                                font.weight: isSelected ? Font.DemiBold : Font.Medium
                                                color: root.pal ? root.pal.text : "#dcdde8"
                                            }

                                            // Active Badge
                                            Rectangle {
                                                visible: isActive
                                                width: 52
                                                height: 18
                                                radius: 9
                                                color: Qt.alpha(root.pal ? root.pal.good : "#8fcfa0", 0.2)
                                                border.width: 1
                                                border.color: Qt.alpha(root.pal ? root.pal.good : "#8fcfa0", 0.5)
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.pal.cap("ACTIVE")
                                                    font.family: root.pal ? root.pal.uiFont : "Sans Serif"
                                                    font.pixelSize: 9
                                                    font.weight: Font.Bold
                                                    color: root.pal ? root.pal.good : "#8fcfa0"
                                                }
                                            }
                                        }

                                        Text {
                                            text: modelData.desc
                                            font.family: root.pal ? root.pal.uiFont : "Sans Serif"
                                            font.pixelSize: 11
                                            color: root.pal ? root.pal.muted : "#9496a8"
                                            wrapMode: Text.Wrap
                                            Layout.fillWidth: true
                                        }
                                    }

                                    // Key badge
                                    Rectangle {
                                        width: 44
                                        height: 24
                                        radius: 6
                                        color: isSelected
                                            ? Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.3)
                                            : Qt.alpha(root.pal ? root.pal.surface : "#1e2130", 0.8)
                                        border.width: 1
                                        border.color: Qt.alpha(root.pal ? root.pal.accent : "#9aa9d4", 0.35)

                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData.badge
                                            font.family: root.pal ? root.pal.mono : "JetBrainsMono Nerd Font"
                                            font.pixelSize: 10
                                            font.weight: Font.Bold
                                            color: root.pal ? root.pal.accent : "#9aa9d4"
                                        }
                                    }
                                }

                                MouseArea {
                                    id: itemMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onPositionChanged: { root.selectedIndex = index }
                                    onClicked: {
                                        root.selectedIndex = index
                                        root.apply(modelData.id)
                                    }
                                }
                            }
                        }

                        // Footer hint
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 18

                            Hint {
                                pal: root.pal
                                text: "↑↓ / Tab navigate • Enter / Click select • Esc close • Hotkeys: 1-6 or M, R, L, P, O, A"
                                fontFamily: root.pal ? root.pal.uiFont : "Sans Serif"
                                pixelSize: 11
                                color: root.pal ? root.pal.muted : "#9496a8"
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }
    }
}
