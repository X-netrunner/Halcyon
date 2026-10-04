import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.SystemTray

PanelWindow {
    id: root
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 38
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "topbar"

    property string clockText: ""
    property string battText: ""
    property string wifiText: ""
    property string btText: ""

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var date = new Date();
            root.clockText = Qt.formatDateTime(date, "ddd dd MMM  hh:mm AP");
        }
    }

    Process {
        id: battProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/quickshell/scripts/battery.sh"]
        running: true
        stdout: SplitParser {
            onRead: data => root.battText = data.trim()
        }
    }

    Process {
        id: wifiProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/quickshell/scripts/network.sh"]
        running: true
        stdout: SplitParser {
            onRead: data => root.wifiText = data.trim()
        }
    }

    Process {
        id: btProc
        command: [Quickshell.env("HOME") + "/.config/Halcyon/quickshell/scripts/bluetooth.sh"]
        running: true
        stdout: SplitParser {
            onRead: data => root.btText = data.trim()
        }
    }

    Timer {
        interval: 4000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            battProc.running = true;
            wifiProc.running = true;
            btProc.running = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 4
        radius: 999
        color: "#eb111321"
        border.color: "#26bfc6ff"
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 12

            Row {
                spacing: 6
                Repeater {
                    model: Hyprland.workspaces
                    delegate: Rectangle {
                        width: modelData.active ? 22 : 8
                        height: 8
                        radius: 4
                        color: modelData.active ? "#bfc6ff" : "#555870"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                visible: root.clockText !== ""
                implicitWidth: clockTxt.implicitWidth + 20
                implicitHeight: 24
                radius: 999
                color: "#22ffffff"

                Text {
                    id: clockTxt
                    anchors.centerIn: parent
                    text: root.clockText
                    color: "#e2e1ec"
                    font.pixelSize: 12
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font"
                }
            }

            Item { Layout.fillWidth: true }

            Row {
                spacing: 6

                Rectangle {
                    visible: root.wifiText !== ""
                    implicitWidth: wifiTxt.implicitWidth + 16
                    implicitHeight: 24
                    radius: 999
                    color: "#22ffffff"

                    Text {
                        id: wifiTxt
                        anchors.centerIn: parent
                        text: root.wifiText
                        color: "#8a9ccc"
                        font.pixelSize: 11
                        font.family: "JetBrainsMono Nerd Font"
                    }
                }

                Rectangle {
                    visible: root.btText !== ""
                    implicitWidth: btTxt.implicitWidth + 16
                    implicitHeight: 24
                    radius: 999
                    color: "#22ffffff"

                    Text {
                        id: btTxt
                        anchors.centerIn: parent
                        text: root.btText
                        color: "#c4abdc"
                        font.pixelSize: 11
                        font.family: "JetBrainsMono Nerd Font"
                    }
                }

                Rectangle {
                    visible: root.battText !== ""
                    implicitWidth: battTxt.implicitWidth + 16
                    implicitHeight: 24
                    radius: 999
                    color: "#22ffffff"

                    Text {
                        id: battTxt
                        anchors.centerIn: parent
                        text: root.battText
                        color: "#e2e1ec"
                        font.pixelSize: 11
                        font.bold: true
                        font.family: "JetBrainsMono Nerd Font"
                    }
                }
            }
        }
    }
}
