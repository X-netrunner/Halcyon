import QtQuick
import QtQuick.Layouts
import Quickshell

Item {
    id: root
    property var pal
    property var stats
    property var net
    property var gpu: ({ gpu: 0, state: "none" })
    property var specs: ({})                  // `hx specs`: cpu, gpus, ram, disks (static)
    property var disks: ({ disks: [] })       // `hx disk`: mounted storage (live)
    property string profile: "balanced"
    property string profileLabel: "Balanced"
    property bool autoPower: false
    property string autoNote: ""      // why Auto picked it: "on battery", "heavy load", "thermal hold", ...
    property string sysmode: ""       // /etc/sysmode.mode: secure | stealth | relaxed | lockdown ("" = not set)
    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()

    function bytes(b) {
        var g = b / 1e9
        return g >= 1000 ? (g / 1000).toFixed(1) + "T" : Math.round(g) + "G"
    }
    readonly property string cpuText: specs.cpu ? specs.cpu + "\n" + specs.cores + " cores · " + specs.threads + " threads" : "…"
    readonly property string gpuText: (specs.gpus && specs.gpus.length > 0) ? specs.gpus.join("\n") : "No GPU found"
    // just the installed amount (no DDR type / channels / speed)
    readonly property string ramText: specs.ram && specs.ram.total ? String(specs.ram.total) : "…"
    readonly property string diskText: {
        var d = specs.disks
        if (!d || d.length === 0) return "…"
        var t = (d[0].model ? d[0].model + " · " : "") + d[0].kind + " " + d[0].size
        return d.length > 1 ? t + "  +" + (d.length - 1) + " more" : t
    }
    readonly property var diskUsage: {
        var out = []
        var d = disks.disks || []
        for (var i = 0; i < d.length && i < 2; i++)
            out.push({ label: d[i].mount, frac: d[i].used / Math.max(1, d[i].size), text: bytes(d[i].used) + " of " + bytes(d[i].size) })
        return out
    }

    function rate(b) {
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s"
        if (b >= 1024) return Math.round(b / 1024) + " KB/s"
        return b + " B/s"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        anchors.leftMargin: 34
        anchors.rightMargin: 34
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 20

            Ring { pal: root.pal; label: "CPU"; text: root.stats.cpu + "%"; value: root.stats.cpu / 100 }
            Ring { pal: root.pal; label: "RAM"; text: root.stats.memGb + "G"; value: root.stats.mem / 100 }
            Ring { pal: root.pal; label: "TEMP"; text: root.stats.temp + "°"; value: (root.stats.temp - 30) / 70 }
            // dGPU load; "off" while it is asleep (reading it never wakes it, see scripts/gpu.sh)
            Ring {
                visible: root.gpu.state !== "none"
                pal: root.pal
                label: "GPU"
                text: root.gpu.state === "on" ? root.gpu.gpu + "%" : "off"
                value: root.gpu.state === "on" ? root.gpu.gpu / 100 : 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 5
                Text {
                    text: "↓  " + root.rate(root.stats.down)
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: "↑  " + root.rate(root.stats.up)
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                // the power mode that is active right now (read-only; change it in the bottom-right panel)
                Text {
                    text: "power · " + root.profileLabel + (root.autoPower ? " (auto" + (root.autoNote !== "" ? ", " + root.autoNote : "") + ")" : "")
                    color: root.pal.accent2
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    visible: !!(root.stats && (root.stats.hasBat || root.stats.bat > 0 || (root.stats.batEst && root.stats.batEst !== "")))
                    text: "battery · " + root.stats.bat + "%" + (root.stats.batEst ? " (" + root.stats.batEst + ")" : "") + (root.stats.charging ? " · charging" : "")
                    color: root.pal.good
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                // active sysmode profile (read-only; switch with the `sysmode` CLI). Colours match `sysmode status`.
                Text {
                    text: "sysmode · " + (root.sysmode !== "" ? root.sysmode : "not set")
                    color: root.pal.modeColor[root.sysmode] || root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.pal.line }

        // what this machine is made of
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 26
            rowSpacing: 12
            SpecItem { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop; pal: root.pal; glyph: String.fromCodePoint(0xF061A); label: "Processor"; value: root.cpuText }
            SpecItem { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop; pal: root.pal; glyph: String.fromCodePoint(0xF08AE); label: "Graphics"; value: root.gpuText }
            SpecItem { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop; pal: root.pal; glyph: String.fromCodePoint(0xF035B); label: "Memory"; value: root.ramText }
            SpecItem { Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop; pal: root.pal; glyph: String.fromCodePoint(0xF02CA); label: "Storage"; value: root.diskText }
        }

        // disk usage bars: one row along the whole bottom, one bar per disk sharing the width
        Row {
            Layout.fillWidth: true
            spacing: 26
            Repeater {
                model: root.diskUsage
                delegate: Column {
                    required property var modelData
                    width: root.diskUsage.length > 1 ? (parent.width - 26 * (root.diskUsage.length - 1)) / root.diskUsage.length : parent.width
                    spacing: 3
                    Text {
                        width: parent.width
                        text: modelData.label + "  ·  " + modelData.text
                        elide: Text.ElideRight
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                    }
                    Rectangle {
                        width: parent.width; height: 4; radius: 2
                        color: root.pal.surface
                        Rectangle {
                            width: parent.width * Math.min(1, Math.max(0.02, modelData.frac))
                            height: parent.height; radius: 2
                            color: modelData.frac > 0.9 ? root.pal.bad : (modelData.frac > 0.75 ? root.pal.warn : root.pal.accent)
                            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        }
                    }
                }
            }
        }
    }
}
