import QtQuick

// Performance look "Forecast" (Part 2): the machine in one short sentence, and very little else.
//   Top left: one verdict of at most four words ('All calm', 'Getting busy', 'CPU is busy', 'Running hot'). It comes from the CPU, memory and GPU loads
//   (storage and network are not "busy"; storage only speaks when it is nearly full) and a new verdict must hold for 3 seconds before it
//   replaces the old one, then the two cross-fade in 200 ms, so it never flickers. Top right: the CPU temperature as a big number and a small
//   pill with the battery percent. Below: five equal tiles (Network, CPU, Memory, GPU, Storage), each with only its name, its value and one
//   thin bar. One tiny muted line in the bottom corner: power mode and sysmode.
//   Colours: the theme's own; red (pal.bad) only past a limit (CPU over 90 C, memory over 92 %, storage over 90 %, battery at 20 % or less).
//   Motion: the tiles rise in one after another when the tab opens; every bar is eased. No Canvas at all, so it costs almost nothing.
PerfBase {
    id: root

    // ---- the verdict
    readonly property string rawKey: {
        if (cpuHot) return "hotcpu"
        if (memHot) return "hotmem"
        if (stoHot) return "hotsto"
        var p = Math.max(cpuLoad, memLoad, gpuLoad)
        if (p > 0.75) return (cpuLoad >= memLoad && cpuLoad >= gpuLoad) ? "busycpu" : (memLoad >= gpuLoad ? "busymem" : "busygpu")
        if (p > 0.40) return "getting"
        return "calm"
    }
    function textFor(k) {
        switch (k) {
        case "hotcpu": return "Running hot"
        case "hotmem": return "Memory is full"
        case "hotsto": return "Disk almost full"
        case "busycpu": return "CPU is busy"
        case "busymem": return "Memory is busy"
        case "busygpu": return "GPU is busy"
        case "getting": return "Getting busy"
        }
        return "All calm"
    }
    function tintFor(k) { return k.indexOf("hot") === 0 ? pal.bad : pal.text }

    // two layers of text that cross-fade: the new verdict is written into the hidden one, then they swap
    property string textA: ""
    property string textB: ""
    property color tintA: "white"
    property color tintB: "white"
    property bool showA: true
    property string shownKey: ""
    function commit() {
        if (!pal) return
        var tx = textFor(rawKey), tn = tintFor(rawKey)
        if (shownKey === "") { textA = tx; tintA = tn; showA = true }          // the first one appears without a fade
        else if (showA) { textB = tx; tintB = tn; showA = false }
        else { textA = tx; tintA = tn; showA = true }
        shownKey = rawKey
    }
    Timer { id: hold; interval: 3000; onTriggered: root.commit() }
    onRawKeyChanged: {
        if (shownKey === "") commit()
        else if (rawKey === shownKey) hold.stop()
        else hold.restart()
    }
    Component.onCompleted: commit()

    PerfBack { pal: root.pal; running: root.active; stars: 14 }

    // ---- the verdict
    Item {
        x: 36; y: 44; width: 440; height: 52
        opacity: root.seg(0.0, 0.5)
        transform: Translate { y: (1 - root.seg(0.0, 0.5)) * 10 }
        Text {
            width: parent.width
            text: root.textA
            color: root.tintA
            opacity: root.showA ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
            font.family: root.pal.uiFont; font.pixelSize: 40; font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            text: root.textB
            color: root.tintB
            opacity: root.showA ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 200 } }
            font.family: root.pal.uiFont; font.pixelSize: 40; font.weight: Font.DemiBold
        }
    }

    // ---- the temperature and the battery
    Text {
        visible: root.temp > 0
        opacity: root.seg(0.05, 0.55)
        anchors.right: parent.right; anchors.rightMargin: 36
        y: 30
        text: Math.round(root.temp) + "°"
        color: root.cpuHot ? root.pal.bad : root.pal.accent
        font.family: root.pal.uiFont; font.pixelSize: 44; font.weight: Font.DemiBold
    }
    Rectangle {
        visible: root.hasBat
        opacity: root.seg(0.2, 0.7)
        width: pillText.implicitWidth + 28; height: 26; radius: 13
        x: root.width - 36 - width
        y: root.temp > 0 ? 88 : 40
        color: Qt.alpha(root.batTint, 0.16)
        Text {
            id: pillText
            anchors.centerIn: parent
            text: Math.round(root.sBat) + "%"
            color: root.batTint
            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 2; font.weight: Font.DemiBold
        }
    }

    // ---- five tiles: Network, CPU, Memory, GPU, Storage
    Repeater {
        model: root.lanes.length === 5 ? 5 : 0
        delegate: PerfTile {
            id: tl
            required property int index
            readonly property int li: [4, 0, 1, 2, 3][index]                 // the lane behind this tile
            readonly property var ln: root.lanes[li]
            readonly property real f: li === 0 ? root.sCpu : (li === 1 ? root.sMem : (li === 2 ? root.sGpu : (li === 3 ? root.sSto : Math.max(root.sDown, root.sUp))))
            pal: root.pal
            reveal: root.seg(0.12 + index * 0.08, 0.62 + index * 0.08)
            width: (root.width - 72 - 4 * 14) / 5
            height: 112
            x: 36 + index * (width + 14)
            y: 140
            Text {
                x: 14; y: 14
                text: tl.ln.name
                color: root.pal.muted
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.letterSpacing: 1.4
                font.capitalization: Font.AllUppercase
            }
            Text {
                x: 14; y: tl.li === 4 ? 42 : 34
                width: tl.width - 28; elide: Text.ElideRight
                text: tl.li === 2 ? (root.hasGpu ? (root.gpuOn ? tl.ln.value : "asleep") : "—") : tl.ln.value
                color: (tl.li === 2 && !root.gpuOn) ? root.pal.muted : (tl.ln.hot ? root.pal.bad : root.pal.text)
                font.family: root.pal.uiFont
                font.pixelSize: tl.li === 4 ? 15 : (tl.li === 2 && !root.gpuOn ? 17 : 22)
                font.weight: Font.DemiBold
            }
            Rectangle { x: 14; y: tl.height - 26; width: tl.width - 28; height: 5; radius: 2.5; color: Qt.alpha(root.pal.text, 0.08) }
            Rectangle {
                x: 14; y: tl.height - 26; height: 5; radius: 2.5
                width: (tl.width - 28) * (tl.li === 2 ? (root.gpuOn ? Math.max(0.02, tl.f) : 0) : Math.max(0.02, Math.min(1, tl.f)))
                color: tl.ln.tint
            }
        }
    }

    // ---- the tiny line
    Text {
        x: 36; y: 276
        opacity: root.seg(0.4, 1.0)
        text: root.profileLabel + (root.sysmode !== "" ? " · " + root.sysmode : "")
        color: root.pal.muted
        font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
    }
}
