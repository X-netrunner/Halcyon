import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

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
    property real glassShift: 0
    property real motion: 1
    property int rounding: 18
    property int gaps: 8
    property bool blur: true
    property bool shadows: true
    property bool hyprAnim: true

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

                Backdrop { anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; dots: 14; artStrength: 0.8; artFit: 0.85 }

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
