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
        spacing: 10

        Text {
            text: "BACKGROUND APPS"
            color: root.pal.muted
            font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4
        }

        Text {
            visible: root.count === 0
            Layout.fillWidth: true
            Layout.topMargin: 4; Layout.bottomMargin: 4
            text: "Nothing is running in the background"
            color: Qt.alpha(root.pal.text, 0.55)
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
        }

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
                    Layout.fillWidth: true
                    implicitHeight: 56
                    radius: root.pal.rMd
                    color: Qt.alpha(root.pal.surface, 0.8)
                    border.width: 1
                    border.color: appRow.showMenu ? Qt.alpha(root.pal.accent, 0.40) : root.pal.lineSoft

                    // alive dot: breathes while the box is open
                    Rectangle {
                        id: dot
                        x: 14; anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: appRow.modelData.status === 2   // 2 = NeedsAttention ? root.pal.accent2 : root.pal.accent
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite; running: root.active && root.pal.motion > 0.3
                            NumberAnimation { to: 0.35; duration: 1400; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 1400; easing.type: Easing.InOutSine }
                        }
                    }
                    Image {
                        id: ico
                        anchors.left: dot.right; anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24; height: 24
                        sourceSize.width: 48; sourceSize.height: 48
                        source: appRow.modelData.icon
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                    Text {
                        anchors.left: ico.right; anchors.leftMargin: 10
                        anchors.right: btns.left; anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: root.name(appRow.modelData)
                        color: root.pal.text
                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                    }
                    Row {
                        id: btns
                        anchors.right: parent.right; anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Chip {
                            pal: root.pal; implicitHeight: 28; label: "Open"; on: true
                            onClicked: appRow.modelData.activate()
                        }
                        Chip {
                            visible: appRow.modelData.hasMenu
                            pal: root.pal; implicitHeight: 28; label: "Options"; on: appRow.showMenu
                            onClicked: appRow.showMenu = !appRow.showMenu
                            onRightClicked: appRow.modelData.secondaryActivate()
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
