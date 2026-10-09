import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// SUPER+TAB: a live tree of this laptop -> workspaces -> windows (special workspaces included).
// Nodes drift slightly, a small pulse travels along every branch, click a node to jump to it.
//   Esc / Q  close      S  toggle compact special workspaces      E  edit profile (or click the laptop node)
//   Drag a window node onto a workspace node (or the "+ new workspace" pill) to move that window there.
Item {
    id: ov

    property var pal: ({
        accent: "#eda578", accent2: "#d29da1", surface: "#1e2130", bg: "#14161f",
        text: "#e9e2dd", muted: "#aca19a", font: "JetBrainsMono Nerd Font", uiFont: "Inter Variable",
        motion: 1.0, growth: 0, growthOn: false
    })
    property bool open: false
    property bool compactSpecial: true
    property string profileName: ""
    property string profileAvatar: ""
    property string sysmode: ""         // lockdown / stealth show their constellation behind the tree
    property bool profileStars: true    // other modes: your profile picture as a constellation
    property var starData: null         // owned by shell.qml (picture constellation, or a sky from your name)
    property string avatarFile: ""      // the picture shell.qml found (scripts/avatar.sh); "" = none

    signal closeRequested()
    signal workspaceClicked(int wsId)
    signal specialClicked(string name)
    signal windowClicked(var win)
    signal compactToggled(bool on)
    signal windowMoved(string address, string target)   // target: workspace id as text, or "special:<name>"
    signal profileSaved(string name, string avatar)

    readonly property string home: Quickshell.env("HOME")
    readonly property real tau: 6.283185307179586

    // ---------------------------------------------------------------- identity
    property string userName: ""
    property string fullName: ""
    property string hostName: "arch"
    property string osName: "Arch Linux"
    property string model: ""
    readonly property string shownName: profileName !== "" ? profileName : (fullName !== "" ? fullName : userName)
    readonly property string avatarPath: avatarFile

    Process {
        id: idProc
        command: ["bash", Quickshell.shellPath("scripts/identity.sh")]
        stdout: StdioCollector {
            onStreamFinished: {
                var l = text.split("\n")
                ov.userName = l[0] || ""
                ov.fullName = l[1] || ""
                ov.hostName = l[2] || "arch"
                ov.osName = l[3] || "Arch Linux"
                ov.model = l[4] || ""
            }
        }
    }

    // ---------------------------------------------------------------- the tree
    readonly property var specialInfo: ({
        "special": { label: "Scratchpad", glyph: 0xF04CE },
        "music": { label: "Music", glyph: 0xF075A },
        "sysmon": { label: "System monitor", glyph: 0xF04C5 },
        "communication": { label: "Communication", glyph: 0xF0361 },
        "todo": { label: "Tasks", glyph: 0xF05E0 }
    })

    property var nodes: []
    property var edges: []
    property string sig: ""
    property int winCount: 0
    property int wsCount: 0

    // time in seconds, wraps seamlessly (every drift frequency is a whole number of cycles per 1000 s)
    property real tt: 0
    NumberAnimation on tt {
        from: 0; to: 1000; duration: 1000000
        loops: Animation.Infinite
        running: ov.open || ov.opacity > 0.01
    }
    // Settings > Performance. fps 0 = every frame of the screen (smoothest); a number = the animation steps that many times a
    // second (the branch curves are the expensive part, they are only redrawn when a step happens).
    // quality: 0 low (no floating dots, no travelling lights, no glow), 1 medium (fewer dots), 2 high.
    readonly property int fps: pal && pal.artFps !== undefined ? pal.artFps : 0
    readonly property int quality: pal && pal.artQuality !== undefined ? pal.artQuality : 2
    readonly property real ttq: fps > 0 ? Math.floor(tt * fps) / fps : tt
    readonly property bool gpuBranch: pal && pal.gpuLines === true && pal.branchShader !== undefined && pal.branchShader !== ""

    // ---------------------------------------------------------------- drag physics
    // Hold the laptop node to make the tree shake, drag it and every branch trails behind on springs.
    property bool held: false          // pointer is down on the laptop node (long enough, or moved)
    property bool dragging: false      // ...and actually moving it
    property real dragX: 0
    property real dragY: 0
    property bool moving: false        // something is still wobbling
    property var offs: []              // per node [dx, dy]
    property var vel: []
    property var rot: []               // per node tilt (degrees)
    property var rotv: []

    function resetPhys(n) {
        var z = [], vz = [], rz = [], rvz = []
        for (var i = 0; i < n; i++) { z.push([0, 0]); vz.push([0, 0]); rz.push(0); rvz.push(0) }
        offs = z; vel = vz; rot = rz; rotv = rvz
    }

    function step(dt) {
        dt = Math.min(dt, 0.033)
        var n = nodes.length
        if (dt <= 0 || n === 0 || offs.length !== n) return
        var o = offs, v = vel, r = rot, rv = rotv
        var live = held
        var rs = Math.sqrt(v[0][0] * v[0][0] + v[0][1] * v[0][1])
        // 0.3 just holding it, up to 1 when thrown around
        var amp = live ? Math.min(1, 0.3 + rs / 900) : 0
        var energy = 0

        for (var i = 0; i < n; i++) {
            var nd = nodes[i]
            var tx, ty, k, c
            if (i === 0) {                       // the head: stiff while held, loose bounce back on release
                tx = dragging ? dragX : 0
                ty = dragging ? dragY : 0
                k = dragging ? 420 : 60
                c = dragging ? 34 : 6
            } else {                             // everything else chases its parent, a little less each level
                var po = o[nd.par >= 0 ? nd.par : 0]
                var f = nd.depth === 1 ? 0.82 : 0.88
                tx = po[0] * f
                ty = po[1] * f
                k = nd.depth === 1 ? 75 : 52
                c = nd.depth === 1 ? 6.2 : 4.6
            }
            var ax = k * (tx - o[i][0]) - c * v[i][0]
            var ay = k * (ty - o[i][1]) - c * v[i][1]
            if (i > 0 && live) {                 // the shake
                ax += (Math.random() - 0.5) * 2600 * amp
                ay += (Math.random() - 0.5) * 2600 * amp
            }
            v[i][0] += ax * dt
            v[i][1] += ay * dt
            o[i][0] += v[i][0] * dt
            o[i][1] += v[i][1] * dt

            if (i > 0) {                         // tilt with horizontal speed, plus a jitter while shaking
                var want = Math.max(-16, Math.min(16, v[i][0] * 0.03))
                if (live) want += (Math.random() - 0.5) * 16 * amp
                rv[i] += (160 * (want - r[i]) - 14 * rv[i]) * dt
                r[i] += rv[i] * dt
            }
            energy += Math.abs(v[i][0]) + Math.abs(v[i][1]) + Math.abs(o[i][0]) + Math.abs(o[i][1]) + Math.abs(r[i]) * 4
        }

        if (!live && energy < 1.2) {             // settled: snap to rest and stop the loop
            resetPhys(n)
            moving = false
            return
        }
        offs = o.slice(); rot = r.slice()        // new array objects so bindings notice
    }

    // ---------------------------------------------------------------- resource use per workspace / window
    // `hx wsres`, only while the tree is open. ws is keyed by workspace name ("1", "special:music"),
    // win by window address (no 0x). Kept out of the node list so the tree doesn't rebuild every 2 s.
    property var wsRes: ({})
    property var winRes: ({})
    Process {
        running: ov.open
        command: [Quickshell.env("HOME") + "/.config/Halcyon/bin/hx", "wsres", "2"]
        stdout: SplitParser {
            onRead: d => {
                try {
                    var r = JSON.parse(d)
                    ov.wsRes = r.ws || {}
                    ov.winRes = r.win || {}
                } catch (e) {}
            }
        }
    }
    function fmtMem(mb) { return mb >= 1024 ? (mb / 1024).toFixed(1) + "G" : Math.round(mb) + "M" }
    function fmtRes(r) {
        if (!r) return ""
        return (r.cpu >= 10 ? Math.round(r.cpu) : r.cpu.toFixed(1)) + "% · " + fmtMem(r.mem)
    }
    function resOfWs(key) { return fmtRes(wsRes[key]) }
    function resOfWin(addr) { return fmtRes(winRes[String(addr || "").toLowerCase().replace(/^0x/, "")]) }
    readonly property string totalRes: {
        var c = 0, m = 0
        for (var k in wsRes) { c += wsRes[k].cpu; m += wsRes[k].mem }
        return fmtRes({ cpu: c, mem: m })
    }

    // ---------------------------------------------------------------- move a window by dragging its node
    // Pick a window node up and its branch is cut (the line retracts to the workspace it came from).
    // Bring it close to a workspace and a tether reaches out for it; once it is near enough the tether
    // joins, solid, and the workspace lights up. Let go while joined and the window moves there.
    // Let go anywhere else and the node is tossed back to where it was and its old branch grows back.
    property int dragIdx: -1
    property string dragState: "none"      // none | drag | return | dock
    property real dragWX: 0                // node centre while it is held
    property real dragWY: 0
    property real landP: 0                 // 0..1 progress of the fly-back / dock animation
    property real landFromX: 0
    property real landFromY: 0
    property real dockX: 0                 // where a joined node settles while Hyprland moves the window
    property real dockY: 0
    property int reachIdx: -1              // nearest workspace node within reach (the tether stretches towards it)
    property real reachK: 0                // 0..1 how close it is
    property int dropIdx: -1               // workspace node it is joined to (-1 none, -2 the "+ new workspace" pill)
    property int newWsId: 1                // id the "+ new workspace" pill would create
    property bool rebuildDeferred: false
    property string toast: ""

    readonly property real reachR: 300     // tether starts reaching out
    readonly property real connectR: 120   // tether joins
    readonly property real pillW: 190
    readonly property real pillH: 40
    readonly property real pillX: nodes.length > 1 ? nodes[1].x : width * 0.43
    readonly property real pillY: height - 104

    function pxBase(i, t) {
        var n = nodes[i]
        if (!n) return 0
        var o = offs[i]
        return n.x + (o ? o[0] : 0) + n.ax * Math.sin(tau * n.kx * t / 1000 + n.p1)
    }
    function pyBase(i, t) {
        var n = nodes[i]
        if (!n) return 0
        var o = offs[i]
        return n.y + (o ? o[1] : 0) + n.ay * Math.sin(tau * n.ky * t / 1000 + n.p2)
    }
    function px(i, t) {
        if (i !== dragIdx) return pxBase(i, t)
        if (dragState === "drag") return dragWX
        var tx = dragState === "return" ? pxBase(i, t) : dockX
        return landFromX + (tx - landFromX) * landP
    }
    function py(i, t) {
        if (i !== dragIdx) return pyBase(i, t)
        if (dragState === "drag") return dragWY
        var ty = dragState === "return" ? pyBase(i, t) : dockY
        return landFromY + (ty - landFromY) * landP
    }

    // all node centres, computed once per frame: [x0, y0, x1, y1 ...]. The nodes and the edges read this instead of each calling
    // px() / py() themselves (an edge used to do four sine evaluations per frame on top of its two nodes' own)
    readonly property var pos: {
        var n = nodes.length, t = ttq, out = new Array(n * 2)
        for (var i = 0; i < n; i++) { out[i * 2] = px(i, t); out[i * 2 + 1] = py(i, t) }
        return out
    }

    function snapUpdate() {
        var d = nodes[dragIdx]
        if (!d) return
        if (Math.abs(dragWX - pillX) < pillW / 2 + 20 && Math.abs(dragWY - pillY) < pillH / 2 + 16) {
            dropIdx = -2; reachIdx = -1; reachK = 0
            return
        }
        var lx = dragWX - d.w / 2, ly = dragWY            // the node's left edge is what reaches for a workspace
        var best = -1, bd = 1e9
        for (var i = 1; i < nodes.length; i++) {
            var n = nodes[i]
            if (n.depth !== 1) continue
            var ax = pxBase(i, ttq) + n.w / 2, ay = pyBase(i, ttq)
            var dist = Math.sqrt((lx - ax) * (lx - ax) + (ly - ay) * (ly - ay))
            if (dist < bd) { bd = dist; best = i }
        }
        if (best >= 0 && bd < reachR) {
            reachIdx = best
            reachK = Math.min(1, (reachR - bd) / (reachR - connectR))
            dropIdx = bd < connectR ? best : -1
        } else {
            reachIdx = -1; reachK = 0; dropIdx = -1
        }
    }

    function beginDrag(idx, x, y) {
        landAnim.stop(); dockT.stop()
        dragIdx = idx; dragState = "drag"
        dragWX = x; dragWY = y
        reachIdx = -1; reachK = 0; dropIdx = -1
        snapUpdate()
    }
    function moveDrag(x, y) {
        if (dragState !== "drag") return
        dragWX = Math.max(60, Math.min(width - 60, x))
        dragWY = Math.max(80, Math.min(height - 40, y))
        snapUpdate()
    }
    function flyBack() {
        landFromX = px(dragIdx, ttq); landFromY = py(dragIdx, ttq)
        dragState = "return"
        reachIdx = -1; reachK = 0; dropIdx = -1
        landP = 0
        landAnim.restart()
    }
    function cancelDrag() { if (dragState === "drag") flyBack() }
    function dropDrag() {
        if (dragState !== "drag") return
        var w = nodes[dragIdx]
        var t = dropIdx
        if (!w) { flyBack(); return }
        var target = ""
        var label = ""
        if (t === -2) {
            target = String(newWsId); label = "Workspace " + newWsId
            dockX = pillX; dockY = pillY
        } else if (t >= 1 && nodes[t] && w.par !== t) {
            var tn = nodes[t]
            target = tn.special ? "special:" + tn.spName : String(tn.wsId)
            label = tn.label
            dockX = w.x; dockY = tn.y
        } else {
            flyBack()                                   // not joined to anything new: back where it came from
            return
        }
        landFromX = dragWX; landFromY = dragWY
        dragState = "dock"
        landP = 0
        landAnim.restart()
        dockT.restart()
        var ttl = String(w.label)
        if (ttl.length > 30) ttl = ttl.substring(0, 29) + "…"
        toast = "Moved " + ttl + "  →  " + label
        toastT.restart()
        windowMoved(w.address, target)
    }
    function dockTimeout() {                            // the move never showed up in the tree: put the node back
        if (dragState !== "dock") return
        landFromX = landFromX + (dockX - landFromX) * landP
        landFromY = landFromY + (dockY - landFromY) * landP
        dragState = "return"
        landP = 0
        landAnim.restart()
        dropIdx = -1
        toast = ""
    }
    function dragDone() {
        landAnim.stop(); dockT.stop()
        dragIdx = -1; dragState = "none"
        reachIdx = -1; reachK = 0; dropIdx = -1
        if (rebuildDeferred) { rebuildDeferred = false; rebuild() }
    }

    NumberAnimation {
        id: landAnim
        target: ov
        property: "landP"
        from: 0; to: 1
        duration: ov.dragState === "return" ? 560 : 300
        easing.type: ov.dragState === "return" ? Easing.OutBack : Easing.OutCubic
        easing.overshoot: 1.2
        onFinished: { if (ov.dragState === "return") ov.dragDone() }
    }
    Timer { id: dockT; interval: 1400; onTriggered: ov.dockTimeout() }
    Timer { id: toastT; interval: 2600; onTriggered: ov.toast = "" }

    FrameAnimation {
        running: ov.open && (ov.held || ov.moving)
        onTriggered: ov.step(frameTime)
    }
    function bez(a, b, c, d, u) {
        var v = 1 - u
        return v * v * v * a + 3 * v * v * u * b + 3 * v * u * u * c + u * u * u * d
    }
    function plural(n, w) { return n + " " + w + (n === 1 ? "" : "s") }
    function iconFor(cls) {
        if (!cls) return Quickshell.iconPath("application-x-executable")
        var e = DesktopEntries.heuristicLookup(cls)
        var ic = e && e.icon ? e.icon : cls.toLowerCase()
        if (!ic) return Quickshell.iconPath("application-x-executable")
        if (ic.indexOf("/") === 0) return "file://" + ic
        return Quickshell.iconPath(ic, "application-x-executable")
    }

    function collect() {
        if (dragState === "drag" || dragState === "return") { rebuildDeferred = true; return }
        var wsl = Hyprland.workspaces.values
        var tl = Hyprland.toplevels.values
        var groups = {}
        var list = []

        function ensure(id, name) {
            if (!name) return null
            if (!groups[name]) {
                groups[name] = { id: id, name: name, special: name.indexOf("special:") === 0, wins: [] }
                list.push(groups[name])
            }
            return groups[name]
        }

        for (var i = 0; i < wsl.length; i++) {
            var w0 = wsl[i]
            if (w0.id > 0 || String(w0.name).indexOf("special:") === 0) ensure(w0.id, w0.name)
        }
        var act = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
        for (var j = 0; j < tl.length; j++) {
            var t = tl[j]
            var ipc = t.lastIpcObject || {}
            if (ipc.mapped === false) continue
            var w = ipc.workspace || (t.workspace ? { id: t.workspace.id, name: t.workspace.name } : null)
            if (!w) continue
            var g = ensure(w.id, String(w.name))
            if (!g) continue
            g.wins.push({
                title: t.title || ipc.title || "(untitled)",
                cls: ipc["class"] || ipc.initialClass || "",
                address: t.address,
                focused: t.address === act,
                ref: t
            })
        }

        var normal = list.filter(function (g) { return !g.special }).sort(function (a, b) { return a.id - b.id })
        var specials = list.filter(function (g) { return g.special }).sort(function (a, b) { return a.name < b.name ? -1 : 1 })
        var all = normal.concat(specials)

        // ---- geometry
        var W = ov.width, H = ov.height
        var top = 96, bottom = 64
        var availH = Math.max(200, H - top - bottom)
        var gap = 14, sepGap = specials.length > 0 && normal.length > 0 ? 26 : 0
        var slotN = 54, slotS = ov.compactSpecial ? 42 : 54

        // If every workspace's windows do not fit in one column, lay the windows out in 2 or 3 columns
        // so all workspaces stay on screen (instead of running off the bottom).
        function totalFor(cols) {
            var t = sepGap
            for (var a = 0; a < all.length; a++)
                t += Math.max(1, Math.ceil(all[a].wins.length / cols)) * (all[a].special ? slotS : slotN) + (a > 0 ? gap : 0)
            return t
        }
        var cols = 1
        while (cols < 3 && availH / Math.max(1, totalFor(cols)) < 0.62) cols++
        var total = totalFor(cols)
        var sc = Math.max(0.5, Math.min(1, availH / Math.max(1, total)))

        var rootX = Math.max(170, W * 0.15)
        var wsX = W * 0.43
        var winX = Math.min(W - 170, W * 0.72)
        // window columns: share the space right of the workspace nodes
        var colLeft = wsX + 102 + 56, colRight = W - 28
        var colW = cols > 1 ? Math.min(260, (colRight - colLeft - (cols - 1) * 10) / cols) : 260

        var out = []
        var eds = []
        var cursor = top + Math.max(0, (availH - total * sc) / 2)

        out.push({
            kind: "root", depth: 0, order: 0, par: -1,
            x: rootX, y: top + availH / 2, w: 262, h: 96,
            label: ov.shownName, sub: ov.userName + "@" + ov.hostName
        })

        var winTotal = 0
        for (var gi = 0; gi < all.length; gi++) {
            var gr = all[gi]
            var sp = gr.special
            var spName = sp ? gr.name.replace("special:", "") : ""
            var slot = (sp ? slotS : slotN) * sc
            if (gi > 0) cursor += gap * sc
            if (sp && gi === normal.length) cursor += sepGap * sc
            var n = Math.max(1, Math.ceil(gr.wins.length / cols))
            var gh = n * slot
            var info = sp ? (ov.specialInfo[spName] || { label: spName, glyph: 0xF04CE }) : null

            var wsIdx = out.length
            var focusedWs = false
            for (var q = 0; q < gr.wins.length; q++) if (gr.wins[q].focused) focusedWs = true
            out.push({
                kind: sp ? "special" : "ws", depth: 1, order: gi, par: 0,
                x: wsX, y: cursor + gh / 2,
                w: sp && ov.compactSpecial ? 184 : 204,
                h: (sp && ov.compactSpecial ? 38 : 48) * sc,
                label: sp ? info.label : "Workspace " + gr.id,
                sub: gr.wins.length === 0 ? "empty" : ov.plural(gr.wins.length, "window"),
                glyph: sp ? info.glyph : 0,
                wsId: gr.id, spName: spName, special: sp, focused: focusedWs, key: gr.name
            })
            eds.push({ a: 0, b: wsIdx, tint: sp ? "accent2" : "accent", ph: (gi * 0.37) % 1 })

            for (var k = 0; k < gr.wins.length; k++) {
                var win = gr.wins[k]
                var wi = out.length
                out.push({
                    kind: "win", depth: 2, order: gi * 4 + k, par: wsIdx,
                    x: cols > 1 ? colLeft + colW / 2 + (k % cols) * (colW + 10) : winX,
                    y: cursor + (Math.floor(k / cols) + 0.5) * slot,
                    w: Math.min(colW, sp && ov.compactSpecial ? 214 : 260),
                    h: (sp && ov.compactSpecial ? 34 : 42) * sc,
                    label: win.title, sub: win.cls, cls: win.cls,
                    address: win.address, ref: win.ref, focused: win.focused,
                    special: sp, spName: spName
                })
                eds.push({ a: wsIdx, b: wi, tint: sp ? "accent2" : "accent", ph: ((gi + k) * 0.29) % 1 })
                winTotal++
            }
            cursor += gh
        }

        // gentle, deterministic drift per node
        for (var d = 0; d < out.length; d++) {
            var nd = out[d]
            var big = nd.kind === "root"
            nd.ax = (big ? 2 : 3) + (d * 7) % 5
            nd.ay = (big ? 3 : 4) + (d * 5) % 6
            nd.kx = 60 + (d * 37) % 80
            nd.ky = 60 + (d * 53) % 80
            nd.p1 = d * 1.7
            nd.p2 = d * 2.3
        }

        var maxId = 0
        for (var m = 0; m < normal.length; m++) maxId = Math.max(maxId, normal[m].id)
        newWsId = maxId + 1

        var s = JSON.stringify([W, H, out.map(function (o) {
            return [o.kind, o.label, o.sub, o.x, o.y, o.w, o.h, o.focused, o.cls, o.address]
        })])
        if (s === sig) return
        sig = s
        winCount = winTotal
        wsCount = all.length
        nodes = out
        edges = eds
        if (offs.length !== out.length) resetPhys(out.length)
        if (dragState === "dock") dragDone()          // the window landed: the fresh tree has it on its new branch
    }

    function rebuild() { collect() }
    function refreshHypr() {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
        rebuildT.restart()
    }

    Timer { id: rebuildT; interval: 160; onTriggered: ov.rebuild() }
    Timer { id: eventT; interval: 120; onTriggered: ov.refreshHypr() }

    Connections { target: Hyprland.workspaces; function onValuesChanged() { if (ov.open) rebuildT.restart() } }
    Connections { target: Hyprland.toplevels; function onValuesChanged() { if (ov.open) rebuildT.restart() } }
    // events that never change workspaces or windows (the island's own layers fire openlayer/closelayer a lot)
    readonly property var quietEvents: ({ openlayer: 1, closelayer: 1, activelayout: 1, keyboardlayout: 1, submap: 1,
                                          screencast: 1, bell: 1, ignoregrouplock: 1, lockgroups: 1, configreloaded: 1 })
    Connections { target: Hyprland; function onRawEvent(e) { if (ov.open && !ov.quietEvents[e.name]) eventT.restart() } }

    onWidthChanged: rebuildT.restart()
    onHeightChanged: rebuildT.restart()
    onCompactSpecialChanged: ov.rebuild()
    onShownNameChanged: ov.rebuild()
    onOpenChanged: {
        held = false; dragging = false; moving = false
        dragDone(); toast = ""
        if (!open) picker.open = false
        if (open) {
            resetPhys(nodes.length)
            idProc.running = true
            sig = ""
            refreshHypr()
            ov.rebuild()
            editing = false
            Qt.callLater(function () { ov.forceActiveFocus() })
        }
    }
    Component.onCompleted: ov.rebuild()

    // ---------------------------------------------------------------- profile editing
    property bool editing: false
    onEditingChanged: {
        if (editing) {
            nameIn.text = ov.profileName
            avIn.text = ov.profileAvatar
            Qt.callLater(function () { nameIn.forceActiveFocus() })
        } else {
            Qt.callLater(function () { ov.forceActiveFocus() })
        }
    }
    // The avatar browser is drawn by the island itself (ImagePicker.qml, at the bottom of this file) so it opens ON TOP of
    // the tree. A zenity / kdialog window cannot: it is an ordinary window, the tree is an overlay layer above all of them.
    function browseAvatar() {
        picker.openAt(avIn.text.trim() !== "" ? avIn.text.trim() : (ov.avatarFile !== "" ? ov.avatarFile : ""))
    }
    function saveProfile() {
        ov.profileSaved(nameIn.text.trim(), avIn.text.trim())
        ov.editing = false
    }

    // ---------------------------------------------------------------- visuals
    focus: true
    opacity: open ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

    Keys.onPressed: e => {
        if (e.key === Qt.Key_Escape && ov.dragState === "drag") { ov.cancelDrag(); e.accepted = true }
        else if (e.key === Qt.Key_Escape || e.key === Qt.Key_Q) { ov.closeRequested(); e.accepted = true }
        else if (e.key === Qt.Key_S) { ov.compactToggled(!ov.compactSpecial); e.accepted = true }
        else if (e.key === Qt.Key_E || e.key === Qt.Key_P) { ov.editing = true; e.accepted = true }
    }

    Rectangle { anchors.fill: parent; color: Qt.alpha(ov.pal.bg, 0.72) }

    // your profile picture, turned into a constellation (`hx stars`); redone when the avatar or the tree changes

    // flagship sysmodes: a constellation shield (lockdown) / dragon (stealth) behind the tree; any other mode shows your
    // profile picture as one. Stars in the wallpaper accent colour.
    ModeArt {
        anchors.fill: parent
        anchors.margins: 60
        clip: true          // same as Backdrop (which draws its lines fine): keeps the line Shapes inside a clip node
        pal: ov.pal
        mode: (ov.sysmode === "lockdown" || ov.sysmode === "stealth") ? ov.sysmode : (ov.profileStars && ov.starData ? "avatar" : "")
        custom: ov.starData
        strength: ov.open ? 1 : 0
        fit: 0.82
        Behavior on strength { NumberAnimation { duration: 500 } }
    }

    // faint drifting dots so the empty space feels alive too
    Repeater {
        model: ov.quality >= 2 ? 26 : (ov.quality === 1 ? 12 : 0)
        delegate: Rectangle {
            required property int index
            readonly property real fx: ((index * 0.6180339) % 1)
            readonly property real fy: ((index * 0.4142135 + 0.17) % 1)
            width: 2 + index % 3
            height: width
            radius: width / 2
            color: Qt.alpha(ov.pal.accent, 0.10 + (index % 4) * 0.03)
            x: ov.width * fx + 14 * Math.sin(ov.tau * (40 + index * 11 % 50) * ov.ttq / 1000 + index)
            y: ov.height * fy + 14 * Math.cos(ov.tau * (40 + index * 17 % 50) * ov.ttq / 1000 + index * 2)
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: { if (ov.editing) ov.editing = false; else ov.closeRequested() }
    }

    // ---- branches (drawn under the nodes)
    Repeater {
        model: ov.edges
        delegate: Item {
            id: eg
            required property var modelData
            readonly property var nA: ov.nodes[modelData.a]
            readonly property var nB: ov.nodes[modelData.b]
            readonly property real sx: (ov.pos[modelData.a * 2] || 0) + (nA ? nA.w / 2 : 0)
            readonly property real sy: ov.pos[modelData.a * 2 + 1] || 0
            readonly property real ex0: (ov.pos[modelData.b * 2] || 0) - (nB ? nB.w / 2 : 0)
            readonly property real ey0: ov.pos[modelData.b * 2 + 1] || 0
            // the branch of a held leaf is cut: it retracts to the workspace, and grows back if the leaf returns
            readonly property bool cut: ov.dragIdx >= 0 && ov.dragIdx === modelData.b && (ov.dragState === "drag" || ov.dragState === "dock")
            property real link: cut ? 0 : 1
            Behavior on link { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            readonly property real ex: sx + (ex0 - sx) * link
            readonly property real ey: sy + (ey0 - sy) * link
            readonly property real dx: (ex - sx) * 0.5
            readonly property color tint: modelData.tint === "accent2" ? ov.pal.accent2 : ov.pal.accent
            readonly property real u: ov.quality >= 1 ? (ov.ttq * 0.1 + modelData.ph) % 1 : 0
            property real appear: 0

            opacity: appear * Math.min(1, link * 1.8)
            SequentialAnimation on appear {
                running: true
                PauseAnimation { duration: eg.nB ? eg.nB.depth * 110 + 60 : 100 }
                NumberAnimation { to: 1; duration: 500; easing.type: Easing.OutCubic }
            }

            // GPU line drawing (Settings > Performance > Line drawing): one small quad per branch, the curve is computed by
            // branch.frag on the GPU, so nothing is tessellated while the tree floats. Falls back to the Shape below when
            // the shader could not be built (no `qsb` installed) or when CPU drawing is chosen.
            ShaderEffect {
                id: fx
                visible: ov.gpuBranch
                readonly property real pad: 4
                readonly property real minX: Math.min(eg.sx, eg.ex, eg.sx + eg.dx, eg.ex - eg.dx)
                readonly property real maxX: Math.max(eg.sx, eg.ex, eg.sx + eg.dx, eg.ex - eg.dx)
                readonly property real minY: Math.min(eg.sy, eg.ey)
                readonly property real maxY: Math.max(eg.sy, eg.ey)
                x: minX - pad; y: minY - pad
                width: Math.max(1, maxX - minX + 2 * pad)
                height: Math.max(1, maxY - minY + 2 * pad)
                property color color: Qt.alpha(eg.tint, 0.42)
                property vector2d p0: Qt.vector2d(eg.sx - x, eg.sy - y)
                property vector2d p1: Qt.vector2d(eg.sx + eg.dx - x, eg.sy - y)
                property vector2d p2: Qt.vector2d(eg.ex - eg.dx - x, eg.ey - y)
                property vector2d p3: Qt.vector2d(eg.ex - x, eg.ey - y)
                property vector2d dim: Qt.vector2d(width, height)
                property real lw: 1.6
                fragmentShader: ov.gpuBranch ? ov.pal.branchShader : ""
            }
            Loader {
                active: !ov.gpuBranch || fx.status === ShaderEffect.Error
                sourceComponent: Shape {
                    asynchronous: true
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: Qt.alpha(eg.tint, 0.42)
                        strokeWidth: 1.6
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        startX: eg.sx
                        startY: eg.sy
                        PathCubic {
                            x: eg.ex
                            y: eg.ey
                            control1X: eg.sx + eg.dx
                            control1Y: eg.sy
                            control2X: eg.ex - eg.dx
                            control2Y: eg.ey
                        }
                    }
                }
            }
            // pulse travelling parent -> child
            Rectangle {
                visible: ov.quality >= 1
                width: 6; height: 6; radius: 3
                color: eg.tint
                opacity: Math.sin(Math.PI * eg.u) * 0.85
                x: ov.bez(eg.sx, eg.sx + eg.dx, eg.ex - eg.dx, eg.ex, eg.u) - 3
                y: ov.bez(eg.sy, eg.sy, eg.ey, eg.ey, eg.u) - 3
            }
        }
    }

    // ---- tether: the held leaf reaching out for the nearest workspace; solid once it has joined
    Item {
        id: tether
        readonly property bool live: (ov.dragState === "drag" && ov.reachIdx >= 1) || (ov.dragState === "dock" && ov.dropIdx >= 1)
        readonly property int ti: ov.dragState === "dock" ? ov.dropIdx : ov.reachIdx
        readonly property var tn: ti >= 1 ? ov.nodes[ti] : null
        readonly property var dn: ov.dragIdx >= 0 ? ov.nodes[ov.dragIdx] : null
        readonly property bool joined: ti >= 1 && ov.dropIdx === ti
        readonly property real sx: tn ? ov.px(ti, ov.ttq) + tn.w / 2 : 0
        readonly property real sy: tn ? ov.py(ti, ov.ttq) : 0
        readonly property real tx: dn ? ov.px(ov.dragIdx, ov.ttq) - dn.w / 2 : 0
        readonly property real ty: dn ? ov.py(ov.dragIdx, ov.ttq) : 0
        // not joined yet: the line only stretches part of the way, further the closer the leaf gets
        readonly property real frac: joined ? 1 : 0.18 + 0.62 * ov.reachK
        readonly property real fx: sx + (tx - sx) * frac
        readonly property real fy: sy + (ty - sy) * frac
        readonly property real dx: (fx - sx) * 0.5
        property real shown: live ? 1 : 0
        Behavior on shown { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        opacity: shown
        visible: shown > 0.01

        Shape {
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: Qt.alpha(ov.pal.accent, tether.joined ? 0.95 : 0.55)
                strokeWidth: tether.joined ? 2.2 : 1.6
                strokeStyle: tether.joined ? ShapePath.SolidLine : ShapePath.DashLine
                dashPattern: [2, 3]
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: tether.sx
                startY: tether.sy
                PathCubic {
                    x: tether.fx
                    y: tether.fy
                    control1X: tether.sx + tether.dx
                    control1Y: tether.sy
                    control2X: tether.fx - tether.dx
                    control2Y: tether.fy
                }
            }
        }
        // the searching tip of the tether
        Rectangle {
            visible: !tether.joined
            width: 8; height: 8; radius: 4
            color: ov.pal.accent
            opacity: 0.85
            x: tether.fx - 4
            y: tether.fy - 4
        }
    }

    // ---- nodes
    Repeater {
        model: ov.nodes
        delegate: Item {
            id: nd
            required property var modelData
            required property int index
            readonly property var d: modelData
            readonly property bool isRoot: d.kind === "root"
            readonly property bool isWin: d.kind === "win"
            readonly property bool isSpecial: d.kind === "special" || (isWin && d.special)
            readonly property color tint: isSpecial ? ov.pal.accent2 : ov.pal.accent
            property real appear: 0

            readonly property bool beingDragged: ov.dragIdx === index && ov.dragState !== "return"
            readonly property bool dropHot: ov.dropIdx === index
            readonly property bool reachHot: ov.reachIdx === index && ov.dragState === "drag" && ov.dropIdx !== index
            z: beingDragged ? 50 : 0
            width: d.w
            height: d.h
            x: (ov.pos[index * 2] || 0) - width / 2
            y: (ov.pos[index * 2 + 1] || 0) - height / 2
            opacity: Math.min(1, appear * 1.6)

            SequentialAnimation on appear {
                running: true
                PauseAnimation { duration: nd.d.depth * 110 + nd.d.order * 26 }
                NumberAnimation { to: 1; duration: 460; easing.type: Easing.OutBack; easing.overshoot: 1.3 }
            }

            Item {
                id: body
                anchors.fill: parent
                rotation: nd.isRoot ? 0 : (ov.rot[nd.index] || 0)
                scale: (0.55 + 0.45 * nd.appear) * ((nd.isRoot && ov.held) ? 1.07 : (nd.beingDragged ? 1.06 : (nd.dropHot ? 1.08 : (ma.pressed ? 0.97 : (ma.containsMouse ? 1.05 : 1)))))
                opacity: nd.beingDragged ? 0.92 : 1
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                // breathing glow behind the laptop node
                Rectangle {
                    visible: nd.isRoot
                    anchors.fill: card
                    anchors.margins: -12
                    radius: card.radius + 12
                    color: nd.tint
                    opacity: 0.06
                    scale: ov.held ? 1.12 : 1
                    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: nd.isRoot && ov.open && ov.quality >= 1
                        NumberAnimation { to: 0.2; duration: 2200; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 0.05; duration: 2200; easing.type: Easing.InOutSine }
                    }
                }

                Rectangle {
                    id: card
                    anchors.fill: parent
                    radius: nd.isRoot ? 28 : (nd.isWin ? 13 : height / 2)
                    color: nd.dropHot ? Qt.alpha(nd.tint, 0.38)
                         : nd.d.focused && !nd.isWin ? nd.tint
                         : nd.isRoot ? Qt.alpha(ov.pal.surface, 0.97)
                         : nd.isWin ? Qt.alpha(ov.pal.surface, ma.containsMouse ? 0.95 : 0.8)
                         : Qt.alpha(ov.pal.surface, 0.95)
                    border.width: nd.isRoot || nd.d.focused ? 1.5 : 1
                    border.color: Qt.alpha(nd.tint, nd.dropHot ? 1 : (nd.reachHot ? 0.7 : (nd.isRoot ? 0.7 : (nd.d.focused ? 0.95 : (ma.containsMouse ? 0.7 : 0.3)))))
                    Behavior on color { ColorAnimation { duration: 160 } }
                    Behavior on border.color { ColorAnimation { duration: 160 } }
                }

                // ---- laptop node: avatar + name + user@host + OS/model
                Item {
                    visible: nd.isRoot
                    anchors.fill: parent

                    Rectangle {
                        id: avatarBg
                        x: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 60; height: 60; radius: 30
                        color: Qt.alpha(nd.tint, 0.2)
                        border.width: 1
                        border.color: Qt.alpha(nd.tint, 0.6)

                        Text {
                            anchors.centerIn: parent
                            visible: avatarImg.status !== Image.Ready
                            text: (ov.shownName || "?").charAt(0).toUpperCase()
                            color: nd.tint
                            font.family: ov.pal.uiFont
                            font.pixelSize: 26
                            font.bold: true
                        }
                        Image {
                            id: avatarImg
                            anchors.fill: parent
                            visible: false
                            source: ov.avatarPath !== "" ? "file://" + ov.avatarPath : ""
                            sourceSize: Qt.size(240, 240)       // 4x the size it is drawn at, so the scale-down is clean
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            smooth: true
                            mipmap: true
                        }
                        // anti-aliased round mask: multisampled, and the mask edge is softened over about a pixel
                        Item {
                            id: avatarMask
                            anchors.fill: parent
                            visible: false
                            layer.enabled: true
                            layer.smooth: true
                            layer.samples: 8
                            Rectangle { anchors.fill: parent; radius: width / 2; color: "black"; antialiasing: true }
                        }
                        MultiEffect {
                            anchors.fill: parent
                            visible: avatarImg.status === Image.Ready
                            source: avatarImg
                            maskEnabled: true
                            maskSource: avatarMask
                            maskThresholdMin: 0.5
                            maskSpreadAtMin: 1.0
                        }
                        // the ring is drawn over the picture's edge, so the rim is as clean as the holder itself
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: "transparent"
                            antialiasing: true
                            border.width: 1.5
                            border.color: Qt.alpha(nd.tint, 0.7)
                        }
                    }

                    Column {
                        anchors.left: avatarBg.right
                        anchors.leftMargin: 14
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: nd.d.label
                            color: ov.pal.text
                            font.family: ov.pal.uiFont
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: String.fromCodePoint(0xF0322) + "  " + nd.d.sub
                            color: nd.tint
                            font.family: ov.pal.font
                            font.pixelSize: 11
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: ov.osName + (ov.model !== "" ? " · " + ov.model : "")
                            color: ov.pal.muted
                            font.family: ov.pal.uiFont
                            font.pixelSize: 10
                        }
                    }
                }

                // ---- workspace / special workspace node
                Row {
                    visible: !nd.isRoot && !nd.isWin
                    anchors.centerIn: parent
                    spacing: 10
                    Text {
                        visible: nd.d.kind === "special"
                        anchors.verticalCenter: parent.verticalCenter
                        text: nd.d.glyph ? String.fromCodePoint(nd.d.glyph) : ""
                        color: nd.d.focused ? ov.pal.bg : nd.tint
                        font.family: ov.pal.font
                        font.pixelSize: 16
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0
                        Text {
                            text: nd.d.label
                            color: nd.d.focused ? ov.pal.bg : ov.pal.text
                            font.family: ov.pal.uiFont
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                        }
                        Text {
                            visible: nd.height > 34
                            text: nd.d.sub + (nd.d.sub !== "empty" && ov.resOfWs(nd.d.key) !== "" ? "  ·  " + ov.resOfWs(nd.d.key) : "")
                            color: nd.d.focused ? Qt.alpha(ov.pal.bg, 0.75) : ov.pal.muted
                            font.family: ov.pal.uiFont
                            font.pixelSize: 10
                        }
                    }
                }

                // ---- window node
                Row {
                    visible: nd.isWin
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 12
                    spacing: 9
                    Image {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(24, nd.height - 10); height: width
                        sourceSize: Qt.size(48, 48)
                        source: nd.isWin ? ov.iconFor(nd.d.cls) : ""
                        asynchronous: true
                        smooth: true
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 33
                        spacing: 0
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: nd.d.label
                            color: nd.d.focused ? nd.tint : ov.pal.text
                            font.family: ov.pal.uiFont
                            font.pixelSize: 12
                            font.weight: nd.d.focused ? Font.DemiBold : Font.Normal
                        }
                        Text {
                            visible: nd.height > 30 && nd.d.sub !== ""
                            width: parent.width
                            elide: Text.ElideRight
                            text: nd.d.sub + (ov.resOfWin(nd.d.address) !== "" ? "  ·  " + ov.resOfWin(nd.d.address) : "")
                            color: ov.pal.muted
                            font.family: ov.pal.uiFont
                            font.pixelSize: 10
                        }
                    }
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: nd.isRoot || nd.isWin
                    cursorShape: !nd.isRoot ? (nd.isWin ? (nd.beingDragged ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.PointingHandCursor)
                               : (ov.held ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

                    property real startX: 0
                    property real startY: 0
                    property bool moved: false
                    property real grabX: 0      // pointer offset from the node centre when the drag began
                    property real grabY: 0

                    // holding still for a moment already wakes the tree up
                    Timer { id: holdT; interval: 180; onTriggered: { ov.held = true; ov.moving = true } }

                    function release() {
                        holdT.stop()
                        var wasHeld = ov.held
                        ov.held = false
                        ov.dragging = false
                        return wasHeld
                    }

                    onPressed: m => {
                        var p = mapToItem(ov, m.x, m.y)
                        startX = p.x; startY = p.y
                        moved = false
                        if (!nd.isRoot) return
                        holdT.restart()
                    }
                    onPositionChanged: m => {
                        if (nd.isWin && pressed) {                 // drag a window node towards another workspace
                            var q = mapToItem(ov, m.x, m.y)
                            if (!moved && Math.sqrt((q.x - startX) * (q.x - startX) + (q.y - startY) * (q.y - startY)) > 8) {
                                moved = true
                                grabX = startX - ov.px(nd.index, ov.ttq)
                                grabY = startY - ov.py(nd.index, ov.ttq)
                                ov.beginDrag(nd.index, q.x - grabX, q.y - grabY)
                            }
                            if (moved) ov.moveDrag(q.x - grabX, q.y - grabY)
                            return
                        }
                        if (!nd.isRoot || !pressed) return
                        var p = mapToItem(ov, m.x, m.y)
                        var dx = p.x - startX, dy = p.y - startY
                        if (!moved && Math.sqrt(dx * dx + dy * dy) > 6) {
                            moved = true
                            holdT.stop()
                            ov.held = true
                            ov.dragging = true
                            ov.moving = true
                        }
                        if (moved) {
                            // keep the head on screen
                            var n0 = ov.nodes[0]
                            ov.dragX = Math.max(14 + n0.w / 2 - n0.x, Math.min(ov.width - 14 - n0.w / 2 - n0.x, dx))
                            ov.dragY = Math.max(70 + n0.h / 2 - n0.y, Math.min(ov.height - 50 - n0.h / 2 - n0.y, dy))
                        }
                    }
                    onReleased: {
                        if (nd.isWin) { if (moved) ov.dropDrag(); return }
                        if (!nd.isRoot) return
                        var wasHeld = release()
                        if (!moved && !wasHeld) ov.editing = true      // a plain tap still opens the profile editor
                    }
                    onCanceled: { if (nd.isRoot) release(); else if (nd.isWin) ov.cancelDrag() }
                    onClicked: {
                        if (nd.isRoot || moved) return
                        if (nd.isWin) ov.windowClicked({ ref: nd.d.ref, address: nd.d.address, special: nd.d.special, spName: nd.d.spName })
                        else if (nd.d.kind === "special") ov.specialClicked(nd.d.spName)
                        else ov.workspaceClicked(nd.d.wsId)
                    }
                }
            }
        }
    }

    // ---- drop target for "make a new workspace for this window"
    Rectangle {
        width: ov.pillW; height: ov.pillH; radius: height / 2
        x: ov.pillX - width / 2
        y: ov.pillY - height / 2
        opacity: ov.dragState === "drag" ? 1 : 0
        visible: opacity > 0.01
        scale: ov.dropIdx === -2 ? 1.08 : 1
        color: ov.dropIdx === -2 ? Qt.alpha(ov.pal.accent, 0.30) : Qt.alpha(ov.pal.surface, 0.85)
        border.width: 1
        border.color: ov.dropIdx === -2 ? ov.pal.accent : Qt.alpha(ov.pal.accent, 0.35)
        Behavior on opacity { NumberAnimation { duration: ov.pal.dMed } }
        Behavior on scale { NumberAnimation { duration: ov.pal.dFast; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: ov.pal.dFast } }
        Text {
            anchors.centerIn: parent
            text: "+  New workspace " + ov.newWsId
            color: ov.pal.text
            font.family: ov.pal.uiFont
            font.pixelSize: ov.pal.tBody
            font.weight: Font.Medium
        }
    }

    // ---- toast after a move
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 38
        height: 34
        width: toastTxt.implicitWidth + 36
        radius: height / 2
        color: Qt.alpha(ov.pal.surface, 0.92)
        border.width: 1
        border.color: Qt.alpha(ov.pal.accent, 0.4)
        opacity: ov.toast !== "" ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutSine } }
        Text {
            id: toastTxt
            anchors.centerIn: parent
            text: ov.toast
            color: ov.pal.text
            font.family: ov.pal.uiFont
            font.pixelSize: ov.pal.tBody
            font.weight: Font.Medium
        }
    }

    // ---- header
    Column {
        x: 40
        y: 34
        spacing: 2
        Text {
            text: "Overview"
            color: ov.pal.text
            font.family: ov.pal.uiFont
            font.pixelSize: 22
            font.weight: Font.DemiBold
        }
        Text {
            text: ov.plural(ov.wsCount, "workspace") + " · " + ov.plural(ov.winCount, "window") + " · " + ov.hostName
                  + (ov.totalRes !== "" ? "  ·  apps use " + ov.totalRes : "")
            color: ov.pal.muted
            font.family: ov.pal.uiFont
            font.pixelSize: 12
        }
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: 40
        y: 36
        spacing: 10

        // compact specials toggle
        Rectangle {
            height: 34
            width: tglRow.implicitWidth + 28
            radius: 17
            color: Qt.alpha(ov.pal.surface, tglMa.containsMouse ? 1 : 0.85)
            border.width: 1
            border.color: Qt.alpha(ov.pal.accent2, 0.35)
            Behavior on color { ColorAnimation { duration: 140 } }
            Row {
                id: tglRow
                anchors.centerIn: parent
                spacing: 10
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Compact special workspaces"
                    color: ov.pal.text
                    font.family: ov.pal.uiFont
                    font.pixelSize: 12
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34; height: 18; radius: 9
                    color: ov.compactSpecial ? ov.pal.accent2 : Qt.alpha(ov.pal.muted, 0.35)
                    Behavior on color { ColorAnimation { duration: 160 } }
                    Rectangle {
                        y: 2
                        x: ov.compactSpecial ? parent.width - width - 2 : 2
                        width: 14; height: 14; radius: 7
                        color: ov.pal.bg
                        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    }
                }
            }
            MouseArea {
                id: tglMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ov.compactToggled(!ov.compactSpecial)
            }
        }

        Rectangle {
            height: 34
            width: edTxt.implicitWidth + 28
            radius: 17
            color: Qt.alpha(ov.pal.surface, edMa.containsMouse ? 1 : 0.85)
            border.width: 1
            border.color: Qt.alpha(ov.pal.accent, 0.35)
            Behavior on color { ColorAnimation { duration: 140 } }
            Text {
                id: edTxt
                anchors.centerIn: parent
                text: String.fromCodePoint(0xF03EB) + "  Edit profile"
                color: ov.pal.text
                font.family: ov.pal.font
                font.pixelSize: 12
            }
            MouseArea {
                id: edMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ov.editing = true
            }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 26
        text: "Esc close"
        color: ov.pal.muted
        font.family: ov.pal.uiFont
        font.pixelSize: 11
    }

    // ---- profile editor
    Rectangle {
        id: editCard
        anchors.centerIn: parent
        width: 400
        height: 262
        radius: ov.pal.rXl
        color: Qt.alpha(ov.pal.bg, ov.pal.glassSolid)
        border.width: 1
        border.color: ov.pal.line
        opacity: ov.editing ? 1 : 0
        visible: opacity > 0.01
        scale: ov.editing ? 1 : 0.96
        Behavior on opacity { NumberAnimation { duration: ov.pal.dMed; easing.type: Easing.InOutSine } }
        Behavior on scale { NumberAnimation { duration: ov.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: ov.pal.curve } }

        MouseArea { anchors.fill: parent }   // don't let clicks fall through to the backdrop

        Column {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 10

            Text {
                text: "Profile"
                color: ov.pal.text
                font.family: ov.pal.uiFont
                font.pixelSize: 17
                font.weight: Font.DemiBold
            }
            Text {
                text: "Shown on the laptop node. Leave empty to use your system name."
                color: ov.pal.muted
                font.family: ov.pal.uiFont
                font.pixelSize: 11
            }

            Text { text: "Display name"; color: ov.pal.muted; font.family: ov.pal.uiFont; font.pixelSize: 11 }
            Rectangle {
                width: parent.width; height: 38; radius: 19
                color: ov.pal.surface
                border.width: 1
                border.color: nameIn.activeFocus ? ov.pal.accent : Qt.alpha(ov.pal.accent, 0.25)
                Behavior on border.color { ColorAnimation { duration: 140 } }
                TextInput {
                    id: nameIn
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    verticalAlignment: TextInput.AlignVCenter
                    color: ov.pal.text
                    selectionColor: ov.pal.accent
                    font.family: ov.pal.uiFont
                    font.pixelSize: 13
                    clip: true
                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Escape) { ov.editing = false; e.accepted = true }
                        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Tab) { avIn.forceActiveFocus(); e.accepted = true }
                    }
                }
            }

            Text { text: "Avatar image (default ~/.face)"; color: ov.pal.muted; font.family: ov.pal.uiFont; font.pixelSize: 11 }
            Row {
                width: parent.width
                spacing: 8
                Rectangle {
                    width: parent.width - 86 - parent.spacing; height: 38; radius: 19
                    color: ov.pal.surface
                    border.width: 1
                    border.color: avIn.activeFocus ? ov.pal.accent : Qt.alpha(ov.pal.accent, 0.25)
                    Behavior on border.color { ColorAnimation { duration: 140 } }
                    TextInput {
                        id: avIn
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        verticalAlignment: TextInput.AlignVCenter
                        color: ov.pal.text
                        selectionColor: ov.pal.accent
                        font.family: ov.pal.uiFont
                        font.pixelSize: 13
                        clip: true
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Escape) { ov.editing = false; e.accepted = true }
                            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { ov.saveProfile(); e.accepted = true }
                            else if (e.key === Qt.Key_Backtab) { nameIn.forceActiveFocus(); e.accepted = true }
                        }
                    }
                }
                Rectangle {
                    width: 86; height: 38; radius: 19
                    color: browseMa.containsMouse ? Qt.alpha(ov.pal.accent, 0.28) : Qt.alpha(ov.pal.accent, 0.14)
                    border.width: 1
                    border.color: Qt.alpha(ov.pal.accent, 0.45)
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF024B) + "  Browse"; color: ov.pal.text; font.family: ov.pal.font; font.pixelSize: 12 }
                    MouseArea { id: browseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ov.browseAvatar() }
                }
            }

            Row {
                anchors.right: parent.right
                spacing: 8
                Rectangle {
                    width: 78; height: 34; radius: 17
                    color: cancelMa.containsMouse ? Qt.alpha(ov.pal.surface, 1) : "transparent"
                    border.width: 1
                    border.color: Qt.alpha(ov.pal.muted, 0.4)
                    Text { anchors.centerIn: parent; text: "Cancel"; color: ov.pal.muted; font.family: ov.pal.uiFont; font.pixelSize: 12 }
                    MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; onClicked: ov.editing = false }
                }
                Rectangle {
                    width: 78; height: 34; radius: 17
                    color: saveMa.containsMouse ? Qt.lighter(ov.pal.accent, 1.1) : ov.pal.accent
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text { anchors.centerIn: parent; text: "Save"; color: ov.pal.bg; font.family: ov.pal.uiFont; font.pixelSize: 12; font.weight: Font.DemiBold }
                    MouseArea { id: saveMa; anchors.fill: parent; hoverEnabled: true; onClicked: ov.saveProfile() }
                }
            }
        }
    }
    // ---- image browser for the avatar (drawn above everything else in the tree)
    ImagePicker {
        id: picker
        anchors.fill: parent
        pal: ov.pal
        onPicked: path => { avIn.text = path; picker.open = false; Qt.callLater(function () { avIn.forceActiveFocus() }) }
        onCancelled: { picker.open = false; Qt.callLater(function () { avIn.forceActiveFocus() }) }
    }
}
