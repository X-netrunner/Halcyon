import QtQuick

// Performance look "Editorial": quiet and typographic, no Canvas at all. Left: the caption "Busiest right now", then a HUGE number, the load
// of whichever part is busiest, with a small accent percent sign, that part's name under it (in its colour) and one line of detail. Right: a
// table with thin rules and two columns (a muted label, a value): CPU, GPU, Storage, Network, Battery, Power, Sysmode.
// "Busiest" is an activity, so only the parts that can be busy compete: CPU and GPU always, memory only above 75 % and storage only above 90 %
// (those two are mostly "how full", not "how busy"); network has no percent worth a headline. The leader changes only when another part leads
// by 8 points for 3 seconds (no flicker), then the number, name and detail cross-fade in 200 ms. When nothing is above 5 % it shows the CPU
// and the caption "Everything is quiet". Values use the text colour; red (pal.bad) only past a limit (CPU or temperature over 90, memory over 92,
// storage over 90, battery at 20 or below). Motion: opening the tab counts the number up (600 ms, eased) and slides the rows in 40 ms apart.
PerfBase {
    id: root

    readonly property var names: ["CPU", "Memory", "GPU", "Storage"]
    readonly property var cols: pal ? [pal.accent, pal.accent2, pal.accent, pal.accent2] : []
    readonly property var loads: [sCpu, sMem, hasGpu ? sGpu : 0, sSto]
    readonly property var hots: [cpuHot || cpuLoad > 0.9, memHot, false, stoHot]

    property int lead: 0                 // the part that leads (0 CPU, 1 Memory, 2 GPU, 3 Storage)
    property int pending: -1
    property double pendingSince: 0
    property bool quiet: false
    property int shown: 0                // what is on screen (changes in the middle of the cross-fade)
    property bool shownQuiet: false
    property real swap: 1                // 1 .. 0 .. 1 across a change
    property real countUp: 1             // the number counts up when the tab opens

    function evalLead() {
        var best = 0, bv = sCpu
        if (hasGpu && gpuOn && sGpu > bv) { best = 2; bv = sGpu }
        if (sMem > 0.75 && sMem > bv) { best = 1; bv = sMem }
        if (sSto > 0.9 && sSto > bv) { best = 3; bv = sSto }
        var q = bv < 0.05
        if (q) { pending = -1; if (lead !== 0) lead = 0 }
        else if (best === lead) pending = -1
        else if (bv - loads[lead] >= 0.08) {
            if (pending !== best) { pending = best; pendingSince = Date.now() }
            else if (Date.now() - pendingSince >= 3000) { lead = best; pending = -1 }
        } else pending = -1
        quiet = q
        if (lead !== shown || quiet !== shownQuiet) fade.restart()
    }
    Timer { interval: 500; repeat: true; running: root.active && root.visible; triggeredOnStart: true; onTriggered: root.evalLead() }
    SequentialAnimation {
        id: fade
        NumberAnimation { target: root; property: "swap"; to: 0; duration: Math.round(100 * (root.pal ? root.pal.motion : 1)) }
        ScriptAction { script: { root.shown = root.lead; root.shownQuiet = root.quiet } }
        NumberAnimation { target: root; property: "swap"; to: 1; duration: Math.round(100 * (root.pal ? root.pal.motion : 1)) }
    }
    NumberAnimation { id: countAnim; target: root; property: "countUp"; from: 0; to: 1; duration: 600; easing.type: Easing.OutCubic }
    onActiveChanged: { if (active && pal && pal.motion > 0.3) countAnim.restart(); else countUp = 1 }

    // ---------------------------------------------------------------- the headline
    Text {
        x: 40; y: 26
        opacity: root.swap
        text: root.shownQuiet ? "Everything is quiet" : "Busiest right now"
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.letterSpacing: 1.4
        font.capitalization: Font.AllUppercase
    }
    Text {
        id: big
        x: 34; y: 30
        opacity: root.swap * root.seg(0, 0.4)
        text: Math.round(root.loads[root.shown] * 100 * root.countUp)
        color: root.pal.text
        font.family: root.pal.uiFont; font.pixelSize: 168; font.weight: Font.Bold; font.letterSpacing: -6
    }
    Text {
        x: big.x + big.implicitWidth + 2; y: big.y + 52
        opacity: root.swap * root.seg(0, 0.4)
        text: "%"
        color: root.pal.accent
        font.family: root.pal.uiFont; font.pixelSize: 36; font.weight: Font.DemiBold
    }
    Text {
        x: 40; y: 214
        opacity: root.swap * root.seg(0.1, 0.5)
        text: root.names[root.shown]
        color: root.hots[root.shown] ? root.pal.bad : root.cols[root.shown]
        font.family: root.pal.uiFont; font.pixelSize: 26; font.weight: Font.DemiBold
    }
    Text {
        x: 40; y: 250; width: 330
        elide: Text.ElideRight
        opacity: root.swap * root.seg(0.15, 0.55)
        text: root.lanes.length > 0 ? root.lanes[root.shown].detail : ""
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
    }

    // ---------------------------------------------------------------- the table
    readonly property var rowLabel: ["CPU", "GPU", "Storage", "Network", "Battery", "Power", "Sysmode"]
    readonly property var rowValue: [
        Math.round(cpuLoad * 100) + "%" + (temp > 0 ? "   " + Math.round(temp) + "°C" : ""),
        !hasGpu ? "—" : (gpuOn ? Math.round(gpuLoad * 100) + "%" : "asleep"),
        diskRows.length > 0 ? Math.round(stoLoad * 100) + "%   " + bytes(diskRows[0].used) + " of " + bytes(diskRows[0].size) : "—",
        "↓ " + rate(stats.down) + "   ↑ " + rate(stats.up),
        Math.round(batLevel) + "%" + ((stats.batEst && stats.batEst !== "") ? "   " + stats.batEst : ""),
        profileLabel + (autoPower ? " (auto)" : ""),
        sysmode !== "" ? sysmode : "—"
    ]
    readonly property var rowHot: [cpuHot || cpuLoad > 0.9, false, stoHot, false, hasBat && batLevel <= 20, false, false]

    Column {
        x: 408; y: 26
        width: 272
        Repeater {
            model: 7
            Item {
                id: row
                required property int index
                readonly property real e: root.seg(0.2 + index * 0.031, 0.5 + index * 0.031)
                width: 272
                height: (index === 4 && !root.hasBat) ? 0 : 36
                visible: height > 0
                opacity: e
                transform: Translate { x: (1 - row.e) * 28 }
                Rectangle { width: parent.width; height: 1; color: root.pal.line; opacity: 0.8 }
                Text {
                    x: 0; y: 11
                    text: root.rowLabel[row.index]
                    color: root.pal.muted
                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                }
                Text {
                    y: 9; x: 70; width: parent.width - 70
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                    text: root.rowValue[row.index]
                    color: root.rowHot[row.index] ? root.pal.bad : root.pal.text
                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 2; font.weight: Font.Medium
                }
            }
        }
    }
}
