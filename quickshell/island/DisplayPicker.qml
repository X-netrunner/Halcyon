import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// SUPER + P -> Halcyon Display & Projector Manager
// The same window header as everywhere else and one row per mode (keys: the letter, or 1-6).
Scope {
    id: root
    property var pal
    property bool open: false
    // the window stays a moment after it closes, so its fade-out plays (it used to vanish at once)
    property bool linger: false
    Connections { target: root; function onOpenChanged() { if (!root.open) { root.linger = true; lingerT.restart() } } }
    Timer { id: lingerT; interval: (root.pal ? root.pal.dMed : 300) + 80; onTriggered: root.linger = false }
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
            badge: "M",
            title: "Mirror",
            desc: "Duplicate your screen onto an external projector, TV, or monitor for presentations.",
            icon: "󰍺"
        },
        {
            id: "extend-right",
            num: "2",
            key: Qt.Key_R,
            numKey: Qt.Key_2,
            badge: "R",
            title: "Extend to the right",
            desc: "Dual monitor workspace with external display positioned to the right.",
            icon: "󰍹"
        },
        {
            id: "extend-left",
            num: "3",
            key: Qt.Key_L,
            numKey: Qt.Key_3,
            badge: "L",
            title: "Extend to the left",
            desc: "Dual monitor workspace with external display positioned to the left.",
            icon: "󰍹"
        },
        {
            id: "external-only",
            num: "4",
            key: Qt.Key_P,
            numKey: Qt.Key_4,
            badge: "P",
            title: "Second screen only",
            desc: "Laptop screen turns off. Video outputs exclusively to the projector/monitor.",
            icon: "󰍺"
        },
        {
            id: "internal-only",
            num: "5",
            key: Qt.Key_O,
            numKey: Qt.Key_5,
            badge: "O",
            title: "Laptop screen only",
            desc: "Turn off external projector / display and keep only the built-in laptop screen.",
            icon: "󰌢"
        },
        {
            id: "auto",
            num: "6",
            key: Qt.Key_A,
            numKey: Qt.Key_6,
            badge: "A",
            title: "Automatic",
            desc: "Restore default auto-detected resolutions and layout for all connected displays.",
            icon: "󰑐"
        }
    ]

    LazyLoader {
        active: root.open || root.linger
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
                    color: Qt.alpha(root.pal.bg, root.pal.calm ? 0.55 : 0.45)
                    MouseArea { anchors.fill: parent; onClicked: root.hide() }
                }

                // the card: the same header as every window, then one row per mode. Its height follows the rows (it was a fixed
                // 580 px with a ListView that collapsed to one cut-off row).
                Glass {
                    id: card
                    pal: root.pal
                    anchors.centerIn: parent
                    width: 560
                    height: cardCol.implicitHeight + 56
                    radius: root.pal.rXl
                    opacityBody: root.pal.solid ? 1 : 0.94
                    scale: root.open ? 1 : 0.96
                    Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    MouseArea { anchors.fill: parent } // swallow clicks

                    ColumnLayout {
                        id: cardCol
                        x: 28; y: 28
                        width: card.width - 56
                        spacing: 18

                        WinHeader {
                            pal: root.pal
                            title: "Displays"
                            sub: root.externalMon !== "" ? root.internalMon + "  +  " + root.externalMon : (root.internalMon !== "" ? root.internalMon + " only" : "")
                            onClosed: root.hide()
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: rowsCol.implicitHeight + 8
                            radius: root.pal.rLg
                            color: root.pal.box(Qt.alpha(root.pal.surface, 0.5))
                            Column {
                                id: rowsCol
                                x: 4; y: 4
                                width: parent.width - 8
                                Repeater {
                                    model: root.items
                                    delegate: Rectangle {
                                        id: optRow
                                        required property var modelData
                                        required property int index
                                        readonly property bool isSelected: index === root.selectedIndex
                                        readonly property bool isActive: root.activeMode === modelData.id
                                        // without a second screen only "Laptop screen only" and "Auto" can do anything
                                        readonly property bool usable: root.externalMon !== "" || modelData.id === "internal-only" || modelData.id === "auto"
                                        readonly property bool showDesc: !(root.pal.hideHints && root.pal.zen)
                                        width: rowsCol.width
                                        height: showDesc ? 64 : 52
                                        radius: root.pal.rMd
                                        opacity: usable ? 1 : 0.4
                                        color: isSelected && usable ? root.pal.chosenFill : "transparent"
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 16
                                            anchors.rightMargin: 14
                                            spacing: 14
                                            Text {
                                                text: optRow.modelData.icon
                                                font.family: root.pal.font
                                                font.pixelSize: 20
                                                color: optRow.isActive ? root.pal.good : (optRow.isSelected ? root.pal.chosenText : root.pal.muted)
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2
                                                RowLayout {
                                                    Layout.fillWidth: true          // (a layout is only as wide as its widest child would like otherwise)
                                                    spacing: 8
                                                    Text {
                                                        text: optRow.modelData.title
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tBody + 1
                                                        font.weight: Font.Medium
                                                        color: optRow.isSelected ? root.pal.chosenText : root.pal.text
                                                    }
                                                    Text {
                                                        visible: optRow.isActive
                                                        text: "· in use"
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tCap
                                                        color: root.pal.good
                                                    }
                                                    Item { Layout.fillWidth: true }
                                                }
                                                Text {
                                                    visible: optRow.showDesc
                                                    Layout.fillWidth: true
                                                    text: optRow.usable ? optRow.modelData.desc : "Connect a second screen first."
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                    color: root.pal.muted
                                                    elide: Text.ElideRight
                                                }
                                            }
                                            Text {
                                                text: optRow.modelData.badge
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap
                                                color: root.pal.muted
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            enabled: optRow.usable
                                            cursorShape: Qt.PointingHandCursor
                                            onPositionChanged: root.selectedIndex = optRow.index
                                            onClicked: root.apply(optRow.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
