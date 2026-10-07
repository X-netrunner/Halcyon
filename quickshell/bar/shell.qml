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

    property string barPadding: "normal"  // "low" | "normal" | "high"

    readonly property int barHeight: ({ "low": 26, "normal": 38, "high": 52 })[barPadding] || 38
    readonly property int outerMargin: ({ "low": 2, "normal": 6, "high": 12 })[barPadding] || 6
    readonly property int innerMargin: ({ "low": 8, "normal": 16, "high": 24 })[barPadding] || 16
    readonly property int itemSpacing: ({ "low": 6, "normal": 12, "high": 18 })[barPadding] || 12

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: root.barHeight + (root.outerMargin * 2)
    exclusionMode: ExclusionMode.Normal
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "topbar"

    property string clockText: ""
    property string battText: ""
    property string wifiText: ""
    property string btText: ""

    readonly property var wsList: {
        var l = Hyprland.workspaces.values, out = []
        for (var i = 0; i < l.length; i++) if (l[i].id > 0) out.push(l[i])
        out.sort(function (a, b) { return a.id - b.id })
        return out
    }

    Process {
        id: settingsProc
        command: ["sh", "-c", "cat \"$HOME/.local/state/island/settings.json\" 2>/dev/null || echo '{}'"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var s = JSON.parse(text)
                    if (s.barPadding && ["low", "normal", "high"].indexOf(s.barPadding) >= 0) {
                        root.barPadding = s.barPadding
                    }
                } catch(e) {}
            }
        }
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        onTriggered: settingsProc.running = true
    }

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
        anchors.margins: root.outerMargin
        radius: 999
        color: "#eb111321"
        border.color: "#26bfc6ff"
        border.width: 1

        Behavior on anchors.margins { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: root.innerMargin
            anchors.rightMargin: root.innerMargin
            spacing: root.itemSpacing

            Behavior on anchors.leftMargin { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on anchors.rightMargin { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on spacing { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

            Row {
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: root.wsList
                    delegate: Rectangle {
                        id: wsPill
                        required property var modelData
                        width: modelData.active ? 26 : 9
                        height: 9
                        radius: 4.5
                        color: modelData.active ? "#bfc6ff" : "#555870"
                        anchors.verticalCenter: parent.verticalCenter

                        Behavior on width {
                            NumberAnimation {
                                duration: 260
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: [0.25, 1, 0.5, 1]
                            }
                        }
                        Behavior on color {
                            ColorAnimation {
                                duration: 260
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                visible: root.clockText !== ""
                implicitWidth: clockTxt.implicitWidth + 20
                implicitHeight: Math.max(20, root.barHeight - 14)
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
                    implicitHeight: Math.max(20, root.barHeight - 14)
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
                    implicitHeight: Math.max(20, root.barHeight - 14)
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
                    implicitHeight: Math.max(20, root.barHeight - 14)
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
