import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.SystemTray

// Bottom-left box: the apps that are open in the background right now, i.e. the ones that sit in the system tray
// after their window is closed (Spotify, Discord, Telegram, ...). Nothing else is listed.
// Each app gets its own options: "Open" raises it, "Options" expands the menu the app itself offers (Settings, Quit, ...).
// The list comes straight from the StatusNotifier tray, so any app that lives in the background shows up without
// being added anywhere. Apps that only run for the shell itself (network / bluetooth applets) are left out: `hiddenIds`.
Glass {
    id: root
    property bool active: false             // the box is open (set by shell.qml)
    property var hiddenIds: ["nm-applet", "blueman", "blueman-applet", "network-manager-applet", "nm-tray"]

    function isHidden(it) {
        var id = String(it.id || "").toLowerCase()
        for (var i = 0; i < hiddenIds.length; i++) if (id === hiddenIds[i]) return true
        return false
    }
    function name(it) {
        var t = String(it.tooltipTitle || it.title || "")
        if (t === "") t = String(it.id || "App")
        return t
    }
    readonly property int count: {
        var v = SystemTray.items.values, n = 0
        for (var i = 0; i < v.length; i++) if (!isHidden(v[i])) n++
        return n
    }

    width: pal.boxW
    height: implicitHeight
    implicitHeight: col.implicitHeight + 2 * pad
    readonly property int pad: pal.boxPad
    radius: pal.rXl
    opacityBody: pal.glassSolid - 0.06

    onActiveChanged: if (!active) closeAll.restart()
    Timer { id: closeAll; interval: 1; onTriggered: root.collapseAll() }
    signal collapseAll()

    MouseArea { anchors.fill: parent }      // swallow clicks

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.pad
        spacing: 12

        // ---- header: the title and how many apps are alive
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                text: "BACKGROUND APPS"
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                visible: root.count > 0
                implicitWidth: Math.max(20, cnt.implicitWidth + 12)
                implicitHeight: 18
                radius: 9
                color: Qt.alpha(root.pal.accent, 0.18)
                border.width: 1
                border.color: Qt.alpha(root.pal.accent, 0.35)
                Text {
                    id: cnt
                    anchors.centerIn: parent
                    text: root.count
                    color: root.pal.accent
                    font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold
                }
            }
        }

        // ---- nothing running
        ColumnLayout {
            visible: root.count === 0
            Layout.fillWidth: true
            Layout.topMargin: 10; Layout.bottomMargin: 10
            spacing: 4
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: "Nothing is running in the background"
                color: Qt.alpha(root.pal.text, 0.7)
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "Apps you close to the tray (Spotify, Discord ...) will show up here."
                color: Qt.alpha(root.pal.muted, 0.9)
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
            }
        }

        // ---- the list: scrolls when there are many apps, so the box never grows off the screen
        Flickable {
            id: scroller
            visible: root.count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(list.implicitHeight, 380)
            contentWidth: width
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: list.implicitHeight > 380

            ColumnLayout {
                id: list
                width: scroller.width
                spacing: 8

                Repeater {
                    model: SystemTray.items
                    delegate: ColumnLayout {
                        id: appRow
                        required property var modelData
                        visible: !root.isHidden(modelData)
                        Layout.fillWidth: true
                        spacing: 6
                        property bool showMenu: false
                        Connections { target: root; function onCollapseAll() { appRow.showMenu = false } }

                        Rectangle {
                            id: card
                            Layout.fillWidth: true
                            implicitHeight: 60
                            radius: root.pal.rMd
                            color: Qt.alpha(root.pal.surface, hov.containsMouse ? 0.95 : 0.8)
                            border.width: 1
                            border.color: appRow.showMenu ? Qt.alpha(root.pal.accent, 0.40) : root.pal.lineSoft
                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                            Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }

                            MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 10
                                spacing: 12

                                // the app's icon on a small tile; the status dot sits on its corner
                                Item {
                                    Layout.preferredWidth: 38
                                    Layout.preferredHeight: 38
                                    Layout.alignment: Qt.AlignVCenter
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 11
                                        color: Qt.alpha(root.pal.bg, 0.55)
                                        border.width: 1
                                        border.color: root.pal.lineSoft
                                    }
                                    Image {
                                        anchors.centerIn: parent
                                        width: 24; height: 24
                                        sourceSize.width: 48; sourceSize.height: 48
                                        source: appRow.modelData.icon
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                    }
                                    Rectangle {
                                        id: dot
                                        anchors.right: parent.right; anchors.bottom: parent.bottom
                                        anchors.rightMargin: -3; anchors.bottomMargin: -3
                                        width: 11; height: 11; radius: 6
                                        color: appRow.modelData.status === 2 ? root.pal.accent2 : root.pal.accent   // 2 = NeedsAttention
                                        border.width: 2
                                        border.color: Qt.rgba(root.pal.surface.r, root.pal.surface.g, root.pal.surface.b, 1)
                                        SequentialAnimation on opacity {
                                            loops: Animation.Infinite; running: root.active && root.pal.motion > 0.3
                                            NumberAnimation { to: 0.45; duration: 1400; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 1.0; duration: 1400; easing.type: Easing.InOutSine }
                                        }
                                    }
                                }

                                // name + one quiet line under it
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 1
                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: root.name(appRow.modelData)
                                        color: root.pal.text
                                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: appRow.modelData.status === 2 ? "Needs your attention" : "Running in the background"
                                        color: appRow.modelData.status === 2 ? root.pal.accent2 : Qt.alpha(root.pal.muted, 0.95)
                                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                    }
                                }

                                Chip {
                                    Layout.alignment: Qt.AlignVCenter
                                    pal: root.pal; implicitHeight: 28; label: "Open"; on: true
                                    onClicked: appRow.modelData.activate()
                                }
                                // round "more" button (three dots): the app's own menu; right click = the app's secondary action
                                Rectangle {
                                    visible: appRow.modelData.hasMenu
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.preferredWidth: 28; Layout.preferredHeight: 28
                                    radius: 14
                                    color: appRow.showMenu ? Qt.alpha(root.pal.accent, 0.18) : (moreMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, 0.8))
                                    border.width: 1
                                    border.color: appRow.showMenu ? Qt.alpha(root.pal.accent, 0.40) : root.pal.lineSoft
                                    scale: moreMa.pressed ? 0.95 : 1
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Row {
                                        anchors.centerIn: parent
                                        spacing: 3
                                        Repeater {
                                            model: 3
                                            Rectangle { width: 3; height: 3; radius: 1.5; color: appRow.showMenu ? root.pal.accent : root.pal.muted }
                                        }
                                    }
                                    MouseArea {
                                        id: moreMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: mouse => { if (mouse.button === Qt.RightButton) appRow.modelData.secondaryActivate(); else appRow.showMenu = !appRow.showMenu }
                                    }
                                }
                            }
                        }

                        // the app's own menu (includes its Quit)
                        Rectangle {
                            visible: appRow.showMenu && appRow.modelData.hasMenu
                            Layout.fillWidth: true
                            implicitHeight: menu.implicitHeight + 12
                            radius: root.pal.rMd
                            color: Qt.alpha(root.pal.surface, 0.55)
                            border.width: 1
                            border.color: root.pal.lineSoft
                            TrayMenu {
                                id: menu
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                                pal: root.pal
                                handle: appRow.showMenu ? appRow.modelData.menu : null
                                onDone: appRow.showMenu = false
                            }
                        }
                    }
                }
            }
        }
    }
}
