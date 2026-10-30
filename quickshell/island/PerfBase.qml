import QtQuick

// The shared data of the Performance tab's newer looks (PerfOrbit, PerfPulse, PerfTiles). PerfTab.qml picks the look and hands each one
// itself as `src`; everything below only READS from it (the four signals of the tab are never emitted by a look).
//   - the loads (CPU, memory, GPU, storage, network) as 0 .. 1 numbers, and eased copies (sCpu ...) that glide instead of jumping
//   - the last minute of every load, sampled once a second (cpuHist ...), only while the tab is on screen
//   - `lanes`: name, value, detail and colour of the five machine parts, the same words in every look
//   - `frame()`: the signal a look repaints its Canvas on (about 28 a second while it is on screen and Motion allows it; once per
//     change otherwise), `t` (seconds, for slow motion) and `intro` (0 .. 1 while the tab lights up; seg(a, b) takes a slice of it)
Item {
    id: base
    property var src: null

    readonly property var pal: src ? src.pal : null
    readonly property var stats: (src && src.stats) ? src.stats : ({})
    readonly property var gpu: (src && src.gpu) ? src.gpu : ({ gpu: 0, state: "none" })
    readonly property var specs: (src && src.specs) ? src.specs : ({})
    readonly property var disks: (src && src.disks) ? src.disks : ({ disks: [] })
    readonly property string profileLabel: src ? src.profileLabel : "Balanced"
    readonly property bool autoPower: src ? src.autoPower : false
    readonly property string autoNote: src ? src.autoNote : ""
    readonly property string sysmode: src ? src.sysmode : ""
    readonly property bool active: src ? src.active : false

    implicitWidth: 704
    implicitHeight: 316

    // ------------------------------------------------------------ what the machine says
    readonly property bool hasBat: !!(stats && (stats.hasBat || stats.bat > 0 || (stats.batEst && stats.batEst !== "")))
    readonly property bool hasGpu: gpu.state !== "none"
    readonly property bool gpuOn: gpu.state === "on"
    readonly property real temp: Number(stats.temp || 0)
    readonly property real cpuLoad: Math.max(0, Math.min(1, Number(stats.cpu || 0) / 100))
    readonly property real memLoad: Math.max(0, Math.min(1, Number(stats.mem || 0) / 100))
    readonly property real gpuLoad: gpuOn ? Math.max(0, Math.min(1, Number(gpu.gpu || 0) / 100)) : 0
    readonly property var diskRows: {
        var out = []
        var d = (disks && disks.disks) ? disks.disks : []
        for (var i = 0; i < d.length; i++)
            out.push({ label: d[i].mount, frac: d[i].used / Math.max(1, d[i].size), used: d[i].used, size: d[i].size })
        return out
    }
    readonly property real stoLoad: diskRows.length > 0 ? Math.max(0, Math.min(1, diskRows[0].frac)) : 0
    // 1 KB/s is a faint glow, 1 MB/s a bright one, 10 MB/s the brightest
    function netScale(b) { return Math.max(0, Math.min(1, Math.log(1 + Math.max(0, Number(b) || 0) / 1024) / Math.LN10 / 4)) }
    readonly property real downLoad: netScale(stats.down)
    readonly property real upLoad: netScale(stats.up)
    readonly property real netLoad: netScale(Number(stats.down || 0) + Number(stats.up || 0))
    readonly property real batLevel: Math.max(0, Math.min(100, Number(stats.bat || 0)))
    readonly property bool charging: stats.charging === true
    readonly property color batTint: pal ? (charging ? pal.good : (batLevel <= 20 ? pal.bad : pal.accent)) : "white"
    readonly property bool cpuHot: temp > 90
    readonly property bool memHot: memLoad > 0.92
    readonly property bool stoHot: stoLoad > 0.9

    function rate(b) {
        b = b || 0
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s"
        if (b >= 1024) return Math.round(b / 1024) + " KB/s"
        return Math.round(b) + " B/s"
    }
    function bytes(b) {
        var g = b / 1e9
        return g >= 1000 ? (g / 1000).toFixed(1) + "T" : Math.round(g) + "G"
    }
    function rgba(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }
    function mix(c1, c2, m) { return { r: c1.r + (c2.r - c1.r) * m, g: c1.g + (c2.g - c1.g) * m, b: c1.b + (c2.b - c1.b) * m } }

    // the five parts, in the same words in every look: name, value, a line of detail, the colour, the load (0 .. 1), too hot or not
    readonly property var lanes: pal ? [
        { name: "CPU", value: Math.round(cpuLoad * 100) + "%",
          detail: (temp > 0 ? Math.round(temp) + "°C" : "") + (specs.cores ? (temp > 0 ? " · " : "") + specs.cores + " cores" : ""),
          tint: cpuHot ? pal.bad : pal.accent, load: cpuLoad, hot: cpuHot, small: false },
        { name: "Memory", value: Math.round(memLoad * 100) + "%",
          detail: (stats.memGb || "0.0") + "G" + ((specs.ram && specs.ram.total) ? " of " + specs.ram.total : ""),
          tint: memHot ? pal.bad : pal.accent2, load: memLoad, hot: memHot, small: false },
        { name: "GPU", value: !hasGpu ? "—" : (gpuOn ? Math.round(gpuLoad * 100) + "%" : "off"),
          detail: !hasGpu ? "none found" : (gpuOn ? "awake" : "asleep, saving power"),
          tint: gpuOn ? pal.accent : pal.muted, load: gpuLoad, hot: false, small: false },
        { name: "Storage", value: diskRows.length > 0 ? Math.round(stoLoad * 100) + "%" : "—",
          detail: diskRows.length > 0
                  ? bytes(diskRows[0].used) + " of " + bytes(diskRows[0].size) + (diskRows.length > 1 ? "  +" + (diskRows.length - 1) : "")
                  : "no disks found",
          tint: stoHot ? pal.bad : pal.accent2, load: stoLoad, hot: stoHot, small: false },
        { name: "Network", value: "↓ " + rate(stats.down), detail: "↑ " + rate(stats.up),
          tint: pal.accent, load: netLoad, hot: false, small: true }
    ] : []

    // ------------------------------------------------------------ eased values (what the looks actually draw)
    readonly property bool live: active && visible && (pal ? pal.motion > 0.3 : true)
    property real sCpu: cpuLoad
    property real sMem: memLoad
    property real sGpu: gpuLoad
    property real sSto: stoLoad
    property real sDown: downLoad
    property real sUp: upLoad
    property real sBat: batLevel
    Behavior on sCpu { enabled: base.live; NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
    Behavior on sMem { enabled: base.live; NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    Behavior on sGpu { enabled: base.live; NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
    Behavior on sSto { enabled: base.live; NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    Behavior on sDown { enabled: base.live; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
    Behavior on sUp { enabled: base.live; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
    Behavior on sBat { enabled: base.live; NumberAnimation { duration: 2000; easing.type: Easing.InOutSine } }

    // ------------------------------------------------------------ the last minute
    readonly property int samples: 60
    property var cpuHist: []
    property var memHist: []
    property var gpuHist: []
    property var downHist: []
    property var upHist: []
    property double lastSampleMs: 0                      // when the newest point was added: the graphs glide left from then on
    function pushed(a, v) { var b = a.slice(); b.push(v); if (b.length > base.samples + 1) b.shift(); return b }
    // 0 .. 1: how far the graphs have glided since the last sample (0 while nothing moves)
    function glide() {
        if (!base.live || base.lastSampleMs <= 0) return 0
        return Math.max(0, Math.min(1, (Date.now() - base.lastSampleMs) / 1000))
    }
    Timer {
        interval: 1000
        repeat: true
        running: base.active && base.visible
        triggeredOnStart: true
        onTriggered: {
            base.cpuHist = base.pushed(base.cpuHist, base.sCpu)
            base.memHist = base.pushed(base.memHist, base.sMem)
            base.gpuHist = base.pushed(base.gpuHist, base.sGpu)
            base.downHist = base.pushed(base.downHist, base.sDown)
            base.upHist = base.pushed(base.upHist, base.sUp)
            base.lastSampleMs = Date.now()
            base.frame()
        }
    }

    // ------------------------------------------------------------ the clock of the looks
    signal frame()
    property real t: 0
    Timer {
        interval: Math.round(36 * (base.pal ? base.pal.starSlow : 1))
        repeat: true
        running: base.live
        onTriggered: { base.t += interval / 1000; base.frame() }
    }
    onCpuLoadChanged: if (!live) frame()
    onMemLoadChanged: if (!live) frame()
    onGpuLoadChanged: if (!live) frame()
    onStoLoadChanged: if (!live) frame()
    onNetLoadChanged: if (!live) frame()
    onBatLevelChanged: if (!live) frame()
    onPalChanged: frame()

    // intro runs 0 .. 1 in one go when the tab opens; every part takes its own slice of it
    property real intro: 1
    function ease(x) { x = Math.max(0, Math.min(1, x)); return 1 - Math.pow(1 - x, 3) }
    function back(x) { x = Math.max(0, Math.min(1, x)); var c1 = 1.7, c3 = c1 + 1; return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2) }
    function seg(a, b) { return ease((intro - a) / (b - a)) }
    NumberAnimation {
        id: introAnim
        target: base
        property: "intro"
        from: 0
        to: 1
        duration: Math.max(1, Math.round(1300 * (base.pal ? base.pal.motion : 1)))
        easing.type: Easing.Linear
    }
    onIntroChanged: if (!live) frame()
    onActiveChanged: {
        if (active) { if (pal && pal.motion > 0.3) introAnim.restart(); else { introAnim.stop(); intro = 1 } }
        frame()
    }
}
