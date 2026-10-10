import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// One bar for everything:
//   <text>   search apps (clutter like qv4l2 / avahi / Qt tools is hidden)
//   .        every installed app, A-Z  (".fire" filters that list)
//   >        list of commands (random wallpaper, calculator, settings, power options, ...)
//   =        calculator, e.g.  =2*(3+4)   (Enter copies the result)
Item {
    id: root
    property var pal
    property bool active: false
    signal closeRequested()
    signal commandRequested(string cmdId)

    // ---- query history (Up / Down while typing). Newest last; saved in ~/.local/state/island/launcher-history.log
    property var history: []
    property int histIdx: -1            // -1 = what you are typing now, 0 = newest entry, 1 = the one before ...
    property string histDraft: ""
    property bool histBusy: false       // true while history itself is changing the text
    property real hx: -1                // last REAL pointer position, so scrolling under a resting pointer does not move the selection
    property real hy: -1
    function pushHistory(q) {
        q = (q || "").trim()
        if (q === "") return false
        var h = history.filter(function (x) { return x !== q })
        h.push(q)
        if (h.length > 100) h = h.slice(h.length - 100)
        history = h
        return true
    }
    function saveHistory(q) {
        if (pushHistory(q))
            Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.local/state/island && printf '%s\\n' \"$0\" >> ~/.local/state/island/launcher-history.log", q.trim()])
    }
    function histStep(d) {                 // d = +1 older (Up), -1 newer (Down)
        if (history.length === 0) return
        var ni = Math.min(history.length - 1, histIdx + d)
        if (ni < -1 || ni === histIdx) return
        if (histIdx === -1) histDraft = input.text
        histIdx = ni
        histBusy = true
        input.text = ni === -1 ? histDraft : history[history.length - 1 - ni]
        input.cursorPosition = input.text.length
        histBusy = false
    }
    function stepResult(d) {               // Tab / Shift+Tab: next / previous result, wraps around
        var n = results.length
        if (n === 0) return
        grid.currentIndex = (grid.currentIndex + d + n) % n
    }

    property var usage: ({})
    property int serial: 0
    property string query: ""
    property var results: []
    property var cmdResults: []
    property string pendingConfirm: ""
    property bool stagger: false        // staggered entrance only right after opening
    readonly property real decay: 0.97

    // Apps hidden from the normal list and search; they only show up after typing "."
    // (lower-case substrings, matched against the app name and its desktop id). Edit freely.
    readonly property var hiddenPatterns: [
        "avahi", "bssh", "bvnc", "qv4l2", "qvidcap", "lstopo", "hardware locality",
        "xwayland", "qt assistant", "qt designer", "qt linguist", "qdbusviewer", "qdbus",
        "cmake", "jconsole", "jshell", "java policy", "java web", "openjdk", "ibus", "fcitx",
        "uxterm", "xterm", "xfce4-", "nm-connection", "kbuildsycoca", "org.freedesktop",
        "gtk3 icon browser", "gtk-demo", "gtk4 ", "adwaita", "pcmanfm-desktop", "polkit",
        "cups", "system-config-printer", "vim", "electron", "bluetooth adapters", "blueman-adapters",
        "kvantum", "qt5 settings", "qt6 settings", "qt5ct", "qt6ct", "nwg-", "lsp-plugins"
    ]
    // search index per app, built once (cleared when the app list changes): lower-cased name, lower-cased extra text, hidden or not
    property var appIdx: ({})
    function info(a) {
        var k = a.id || a.name
        var x = appIdx[k]
        if (x) return x
        x = { name: (a.name || "").toLowerCase(),
              extra: ((a.genericName || "") + " " + (a.comment || "") + " " + String(a.keywords || "")).toLowerCase(),
              hidden: isHidden(a) }
        appIdx[k] = x
        return x
    }
    // same entries in the same order? then the model is left alone (replacing it rebuilds every delegate)
    function sameList(a, b) {
        if (a.length !== b.length) return false
        for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
        return true
    }
    function isHidden(a) {
        var hay = ((a.name || "") + " " + (a.id || "")).toLowerCase()
        for (var i = 0; i < hiddenPatterns.length; i++)
            if (hay.indexOf(hiddenPatterns[i]) >= 0) return true
        return false
    }

    // ---- commands (">" mode). confirm = needs Enter twice.
    readonly property var commands: [
        { id: "wallpaper", name: "Random wallpaper", desc: "Switch to a new wallpaper now", glyph: 0xF02E9, kw: "background change image" },
        { id: "calc", name: "Calculator", desc: "Type = then an expression", glyph: 0xF00EB, kw: "math calculate" },
        { id: "theme", name: "Light / dark theme", desc: "Switch the whole desktop between the dark and the light theme (toggle)", glyph: 0xF0594, kw: "dark light mode appearance colours day night" },
        { id: "settings", name: "Settings", desc: "Theme, wallpaper, scrolling, default apps, transparency, motion, gaming", glyph: 0xF0493, kw: "rice options look theme gear config" },
        { id: "power", name: "Power options", desc: "Lock, sleep, log out, restart, shut down", glyph: 0xF0425, kw: "session" },
        { id: "gaming", name: "Gaming mode", desc: "Performance profile, effects off, helpers stopped (toggle)", glyph: 0xF0297, kw: "game fast performance snappy" },
        { id: "caffeine", name: "Caffeine (keep screen awake)", desc: "No dimming, idle lock or idle sleep until you turn it off (toggle)", glyph: 0xF0176, kw: "coffee awake sleep idle lock inhibit stay on" },
        { id: "apps", name: "Background apps", desc: "Spotify, Discord ... running without a window: open or quit them", glyph: 0xF003B, kw: "running tray spotify discord quit close processes" },
        { id: "routing", name: "App routing on / off", desc: "Send Spotify to the music workspace and Discord to communication when they open (toggle)", glyph: 0xF0A2D, kw: "spotify discord music communication workspace automatic move" },
        { id: "cheatsheet", name: "Shortcuts (cheatsheet)", desc: "Tree of every shortcut and gesture; change them or add your own", glyph: 0xF030C, kw: "keybinds keys shortcuts bindings gestures help" },
        { id: "notifications", name: "Notifications", desc: "Open the notification centre", glyph: 0xF009A, kw: "notifs inbox bell history" },
        { id: "quickterm", name: "Quick terminal", desc: "Pop-out terminal for one-shot commands and sysmode", glyph: 0xF0489, kw: "terminal shell command console sysmode run" },
        { id: "edgemode", name: "Edge boxes: hover / click", desc: "Open notifications, console and utilities by hovering the edge, or by clicking it", glyph: 0xF0A2D, kw: "edge hover click corner notifications console utilities toggle" },
        { id: "dnd", name: "Toggle do not disturb", desc: "Silence popups, keep storing notifications", glyph: 0xF009B, kw: "notifications mute quiet focus" },
        { id: "barstyle", name: "Switch bar style", desc: "Island (floating pill) or Notch (hangs from the top edge)", glyph: 0xF0208, kw: "bar style notch island" },
        { id: "autohide", name: "Toggle bar auto-hide", desc: "Hide the bar until you touch the top edge", glyph: 0xF0208, kw: "bar hide" },
        { id: "profile-auto", name: "Power mode: Auto", desc: "Let the power manager decide (load, battery, heat)", glyph: 0xF0079, kw: "battery profile" },
        { id: "profile-power-saver", name: "Power mode: Battery saver", desc: "", glyph: 0xF0079, kw: "battery profile" },
        { id: "profile-balanced", name: "Power mode: Balanced", desc: "", glyph: 0xF0079, kw: "battery profile" },
        { id: "profile-performance", name: "Power mode: Performance", desc: "", glyph: 0xF04C5, kw: "battery profile speed" },
        { id: "wifi", name: "Toggle Wi-Fi", desc: "", glyph: 0xF0928, kw: "network wireless" },
        { id: "bluetooth", name: "Toggle Bluetooth", desc: "", glyph: 0xF00AF, kw: "bt" },
        { id: "lock", name: "Lock screen", desc: "", glyph: 0xF033E, kw: "" },
        { id: "suspend", name: "Sleep", desc: "", glyph: 0xF04B2, kw: "suspend" },
        { id: "logout", name: "Log out", desc: "", glyph: 0xF0343, kw: "exit", confirm: true },
        { id: "reboot", name: "Restart", desc: "", glyph: 0xF0709, kw: "reboot", confirm: true },
        { id: "shutdown", name: "Shut down", desc: "", glyph: 0xF0425, kw: "poweroff", confirm: true }
    ]

    // ---- mode
    readonly property string q0: query.replace(/^\s+/, "")
    readonly property string mode: q0.charAt(0) === ">" ? "cmd"
                                 : (q0.charAt(0) === "=" ? "calc"
                                 : (q0.charAt(0) === "." ? "all" : "apps"))
    readonly property bool gridMode: mode === "apps" || mode === "all"
    readonly property var calcOut: evalCalc(q0.substring(1))

    // ---- size the bar should grow to (the island follows these)
    readonly property int rows: mode === "all" ? Math.max(1, Math.min(4, Math.ceil(results.length / 6)))
                              : (query.trim() === "" ? 2 : Math.max(1, Math.min(3, Math.ceil(results.length / 6))))
    readonly property real wantedWidth: gridMode ? 680 : 540
    readonly property real wantedHeight: {
        // margins 36 + search 46 + header 14 + footer 16 + 4 gaps of 12 = 160 + content
        if (mode === "calc") return 36 + 46 + 12 + 64
        if (mode === "cmd") return 160 + Math.max(1, Math.min(7, cmdResults.length)) * 46
        return 160 + (results.length === 0 ? 40 : rows * 92)
    }

    // ---- usage ranking (decayed launch count, log in ~/.local/state/island/usage.log)
    property bool dirty: true           // the result list is out of date (usage changed); rebuilt on the next open
    function bumpScore(id) {
        dirty = true
        serial++
        var u = usage[id]
        usage[id] = { s: (u ? u.s * Math.pow(decay, serial - u.n) : 0) + 1, n: serial }
    }
    function score(id) {
        var u = usage[id]
        return u ? u.s * Math.pow(decay, serial - u.n) : 0
    }
    function fuzzy(q, s) {
        var j = 0
        for (var i = 0; i < s.length && j < q.length; i++) if (s[i] === q[j]) j++
        return j === q.length
    }

    function evalCalc(expr) {
        var e = expr.trim().toLowerCase()
        if (e === "") return { ok: false, text: "" }
        var s = e.replace(/\^/g, "**")
                 .replace(/\b(sqrt|sin|cos|tan|abs|floor|ceil|round|pow)\b/g, "Math.$1")
                 .replace(/\b(ln|log)\b/g, "Math.log")
                 .replace(/\bpi\b/g, "Math.PI")
        // whatever is left (after removing the Math.* names) may only be digits, operators, brackets
        if (!/^[0-9+\-*\/%().,\s]*$/.test(s.replace(/Math\.[A-Za-z]+/g, "0")))
            return { ok: false, text: "…" }
        try {
            var v = eval(s)
            if (typeof v !== "number" || !isFinite(v)) return { ok: false, text: "…" }
            return { ok: true, text: String(parseFloat(v.toPrecision(12))) }
        } catch (err) {
            return { ok: false, text: "…" }
        }
    }

    function refresh() {
        dirty = false
        if (mode === "cmd") {
            var cq = q0.substring(1).trim().toLowerCase()
            var outc = []
            for (var c = 0; c < commands.length; c++) {
                var cm = commands[c]
                var nm = cm.name.toLowerCase()
                var r = 1
                if (cq !== "") {
                    if (nm.indexOf(cq) === 0) r = 4
                    else if (nm.indexOf(cq) >= 0) r = 3
                    else if ((cm.kw + " " + cm.desc).toLowerCase().indexOf(cq) >= 0) r = 2
                    else if (cq.length > 1 && fuzzy(cq, nm)) r = 1
                    else continue
                }
                outc.push({ c: cm, r: r, i: c })
            }
            outc.sort(function (x, y) { return (y.r - x.r) || (x.i - y.i) })
            var ncmd = outc.map(function (o) { return o.c })
            if (!sameList(ncmd, cmdResults)) cmdResults = ncmd
            cmdList.currentIndex = 0
            return
        }
        if (mode === "calc") return

        var showAll = mode === "all"
        var apps = DesktopEntries.applications.values
        var q = (showAll ? q0.substring(1) : query).trim().toLowerCase()
        var out = []
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i]
            if (a.noDisplay) continue
            var ix = info(a)
            if (!showAll && ix.hidden) continue
            var name = ix.name
            var rank = 1
            if (q !== "") {
                if (name.indexOf(q) === 0) rank = 5
                else if (name.indexOf(" " + q) >= 0) rank = 4
                else if (name.indexOf(q) >= 0) rank = 3
                else if (ix.extra.indexOf(q) >= 0) rank = 2
                else if (q.length > 1 && fuzzy(q, name)) rank = 1
                else continue
            }
            out.push({ e: a, rank: rank, s: score(a.id) })
        }
        if (showAll && q === "") {
            out.sort(function (x, y) { return x.e.name.localeCompare(y.e.name) })
        } else {
            out.sort(function (x, y) {
                return (y.rank - x.rank) || (y.s - x.s) || x.e.name.localeCompare(y.e.name)
            })
        }
        // nothing typed: only what you actually use (padded a little on a fresh install)
        if (!showAll && q === "") {
            var used = out.filter(function (o) { return o.s > 0.02 }).slice(0, 12)
            if (used.length < 6) {
                var have = {}
                used.forEach(function (o) { have[o.e.id] = true })
                var pad = out.filter(function (o) { return !have[o.e.id] })
                    .sort(function (x, y) { return x.e.name.localeCompare(y.e.name) })
                used = used.concat(pad.slice(0, 12 - used.length))
            }
            out = used
        }
        var nres = out.map(function (o) { return o.e })
        if (!sameList(nres, results)) results = nres
        grid.currentIndex = 0
    }

    function iconFor(e) {
        var ic = e && e.icon ? e.icon : ""
        if (!ic) return Quickshell.iconPath("application-x-executable")
        if (ic.indexOf("/") === 0) return "file://" + ic
        return Quickshell.iconPath(ic, "application-x-executable")
    }

    function launch(i) {
        var e = results[i]
        if (!e) return
        saveHistory(query)
        bumpScore(e.id)
        Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.local/state/island && echo \"$0\" >> ~/.local/state/island/usage.log", e.id])
        e.execute()
        closeRequested()
    }

    function runCmd(i) {
        var c = cmdResults[i]
        if (!c) return
        if (c.confirm && pendingConfirm !== c.id) { pendingConfirm = c.id; return }
        pendingConfirm = ""
        saveHistory(query)
        if (c.id === "calc") {            // stay in the bar, switch to calculator mode
            input.text = "="
            input.cursorPosition = 1
            return
        }
        commandRequested(c.id)
        closeRequested()
    }

    function copyCalc() {
        if (!calcOut.ok) return
        saveHistory(query)
        Quickshell.execDetached(["wl-copy", calcOut.text])
        closeRequested()
    }

    Timer { id: staggerT; interval: 600; onTriggered: root.stagger = false }

    onActiveChanged: {
        if (active) {
            stagger = true
            staggerT.restart()
            var had = query
            input.text = ""
            query = ""
            pendingConfirm = ""
            histIdx = -1; histDraft = ""
            // rebuilding the grid while the island starts to grow is what made opening choppy: only do it when it is needed
            if (had !== "" || dirty) refresh()
            Qt.callLater(function () { input.forceActiveFocus() })
        }
    }

    Component.onCompleted: refresh()

    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { root.appIdx = ({}); refreshT.restart() }
    }
    Timer { id: refreshT; interval: 150; onTriggered: root.refresh() }

    Process {
        running: true
        command: ["sh", "-c", "tail -n 100 ~/.local/state/island/launcher-history.log 2>/dev/null"]
        stdout: SplitParser { onRead: d => root.pushHistory(d) }
    }

    Process {
        running: true
        command: ["sh", "-c", "tail -n 3000 ~/.local/state/island/usage.log 2>/dev/null"]
        stdout: SplitParser {
            onRead: d => {
                var id = d.trim()
                if (id) root.bumpScore(id)
            }
        }
        onExited: root.refresh()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        // ---------- search bar ----------
        Rectangle {
            id: bar
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            radius: 23
            color: Qt.alpha(root.pal.surface, 0.85)
            border.width: 1
            border.color: input.activeFocus ? root.pal.lineFocus : root.pal.line
            Behavior on border.color { ColorAnimation { duration: 180 } }

            // soft glow while typing
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 4
                color: "transparent"
                border.width: 4
                border.color: root.pal.accent
                opacity: input.activeFocus ? 0.07 : 0
                Behavior on opacity { NumberAnimation { duration: 240 } }
            }

            Text {
                id: mag
                x: 18
                anchors.verticalCenter: parent.verticalCenter
                text: String.fromCodePoint(root.mode === "cmd" ? 0xF0493 : (root.mode === "calc" ? 0xF00EB : (root.mode === "all" ? 0xF003B : 0xF0349)))
                color: root.pal.accent
                font.family: root.pal.font
                font.pixelSize: 18
            }
            Text {
                visible: input.text === ""
                anchors.left: input.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Search apps…"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 15
            }
            TextInput {
                id: input
                anchors.left: mag.right
                anchors.leftMargin: 12
                anchors.right: badge.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                color: root.pal.text
                selectionColor: root.pal.accent
                selectedTextColor: root.pal.bg
                font.family: root.pal.uiFont
                font.pixelSize: 15
                clip: true
                onTextChanged: { root.query = text; root.pendingConfirm = ""; if (!root.histBusy) root.histIdx = -1; root.refresh() }

                // Up / Down / Left / Right: with something typed they walk through the apps; with the box empty, Up / Down are older / newer
                // searches (in the command list Up / Down move the selection) and Left / Right move the text cursor
                // Tab / Shift+Tab (or Ctrl+N / Ctrl+P): next / previous result;  Ctrl+Up / Ctrl+Down: a row up / down
                Keys.onPressed: e => {
                    var cmd = root.mode === "cmd", calc = root.mode === "calc"
                    var ctrl = (e.modifiers & Qt.ControlModifier) !== 0
                    // once something is typed (and you are not paging through old searches), the arrow keys walk through the apps:
                    // Up / Down a row, Left / Right one app. Shift / Alt + Left / Right and Ctrl + Left / Right still move the text cursor.
                    var nav = root.gridMode && root.results.length > 0 && root.query !== "" && root.histIdx === -1
                    var plain = (e.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
                    if (e.key === Qt.Key_Escape) { root.closeRequested(); e.accepted = true }
                    else if (e.key === Qt.Key_Down) {
                        if (cmd) { cmdList.incrementCurrentIndex(); root.pendingConfirm = "" }
                        else if (ctrl) { if (!calc) grid.moveCurrentIndexDown() }
                        else if (nav) grid.moveCurrentIndexDown()
                        else root.histStep(-1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Up) {
                        if (cmd) { cmdList.decrementCurrentIndex(); root.pendingConfirm = "" }
                        else if (ctrl) { if (!calc) grid.moveCurrentIndexUp() }
                        else if (nav) grid.moveCurrentIndexUp()
                        else root.histStep(1)
                        e.accepted = true
                    }
                    else if (nav && plain && e.key === Qt.Key_Right) { grid.moveCurrentIndexRight(); e.accepted = true }
                    else if (nav && plain && e.key === Qt.Key_Left) { grid.moveCurrentIndexLeft(); e.accepted = true }
                    else if (e.key === Qt.Key_Tab || (ctrl && e.key === Qt.Key_N)) {
                        if (cmd) { cmdList.incrementCurrentIndex(); root.pendingConfirm = "" } else if (!calc) root.stepResult(1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Backtab || (ctrl && e.key === Qt.Key_P)) {
                        if (cmd) { cmdList.decrementCurrentIndex(); root.pendingConfirm = "" } else if (!calc) root.stepResult(-1)
                        e.accepted = true
                    }
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (cmd) root.runCmd(cmdList.currentIndex)
                        else if (calc) root.copyCalc()
                        else root.launch(grid.currentIndex)
                        e.accepted = true
                    }
                }
            }

            // current mode, so "." / ">" / "=" are never a mystery
            Rectangle {
                id: badge
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                height: 24
                width: badgeTxt.implicitWidth + 20
                radius: 12
                color: Qt.alpha(root.pal.accent, 0.14)
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Text {
                    id: badgeTxt
                    anchors.centerIn: parent
                    text: root.mode === "cmd" ? "commands" : (root.mode === "calc" ? "calculator" : (root.mode === "all" ? "all apps" : "apps"))
                    color: root.pal.accent
                    font.family: root.pal.uiFont
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    font.letterSpacing: 0.4
                }
            }
        }

        // ---------- section label ----------
        Text {
            visible: root.mode !== "calc"
            text: root.mode === "cmd" ? "COMMANDS"
                : root.mode === "all" ? "ALL APPS · " + root.results.length
                : (root.query === "" ? "MOST USED" : "RESULTS")
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.letterSpacing: 1.4
            Layout.leftMargin: 10
        }

        // ---------- apps ----------
        GridView {
            id: grid
            visible: root.gridMode && root.results.length > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: Math.floor(width / 6)
            cellHeight: 92
            model: root.results
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 260
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, GridView.Contain)

            // one pill that slides between apps instead of every cell lighting up on its own
            highlight: Item {
                width: grid.cellWidth
                height: grid.cellHeight
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: 18
                    color: Qt.alpha(root.pal.accent, 0.13)
                    border.width: 1
                    border.color: Qt.alpha(root.pal.accent, 0.28)
                }
            }

            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool cur: GridView.isCurrentItem
                width: grid.cellWidth
                height: grid.cellHeight

                // entrance: slide up + fade, staggered right after opening, quick otherwise
                property real appear: 0
                opacity: appear
                transform: Translate { y: (1 - cell.appear) * (root.stagger ? 10 : 3) }
                Component.onCompleted: enterAnim.start()
                SequentialAnimation {
                    id: enterAnim
                    PauseAnimation { duration: root.stagger ? 70 + Math.min(cell.index, 17) * 14 : 0 }
                    NumberAnimation {
                        target: cell; property: "appear"; to: 1
                        duration: root.stagger ? 240 : 120
                        easing.type: Easing.OutCubic
                    }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 7
                    scale: ma.pressed ? 0.94 : 1
                    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                    Image {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 42
                        height: 42
                        sourceSize: Qt.size(84, 84)
                        source: root.iconFor(cell.modelData)
                        asynchronous: true
                        smooth: true
                        scale: cell.cur ? 1.12 : 1
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
                    }
                    Text {
                        width: cell.width - 16
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: cell.modelData.name
                        color: cell.cur ? root.pal.text : Qt.alpha(root.pal.text, 0.78)
                        font.family: root.pal.uiFont
                        font.pixelSize: 11
                        font.weight: cell.cur ? Font.DemiBold : Font.Medium
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: m => {
                        var g = mapToItem(root, m.x, m.y)
                        if (Math.abs(g.x - root.hx) > 1 || Math.abs(g.y - root.hy) > 1) { root.hx = g.x; root.hy = g.y; grid.currentIndex = cell.index }
                    }
                    onClicked: root.launch(cell.index)
                }
            }
        }
        Text {
            visible: root.gridMode && root.results.length === 0
            text: root.mode === "all" ? "No app matches that" : "No apps found — type  .  to see every app,  >  for commands"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 13
            Layout.leftMargin: 10
            Layout.fillHeight: true
            verticalAlignment: Text.AlignVCenter
        }

        // ---------- commands ----------
        ListView {
            id: cmdList
            visible: root.mode === "cmd"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.cmdResults
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 150
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            highlight: Rectangle {
                width: cmdList.width
                height: 46
                radius: 14
                color: Qt.alpha(root.pal.accent, 0.13)
                border.width: 1
                border.color: Qt.alpha(root.pal.accent, 0.28)
            }

            delegate: Item {
                id: crow
                required property var modelData
                required property int index
                width: cmdList.width
                height: 46

                property real appear: 0
                opacity: appear
                transform: Translate { x: (1 - crow.appear) * 10 }
                Component.onCompleted: cEnter.start()
                SequentialAnimation {
                    id: cEnter
                    PauseAnimation { duration: Math.min(crow.index, 8) * 20 }
                    NumberAnimation { target: crow; property: "appear"; to: 1; duration: 180; easing.type: Easing.OutCubic }
                }

                Text {
                    id: cg
                    x: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(crow.modelData.glyph)
                    color: root.pal.accent
                    font.family: root.pal.font
                    font.pixelSize: 18
                }
                Text {
                    id: cname
                    anchors.left: cg.right
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: crow.modelData.name
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }
                Text {
                    // never runs into the title: starts after it, right-aligned, cut with … when too long
                    anchors.left: cname.right
                    anchors.leftMargin: 18
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: root.pendingConfirm === crow.modelData.id ? "press Enter again to confirm" : crow.modelData.desc
                    color: root.pendingConfirm === crow.modelData.id ? root.pal.accent2 : root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: 11
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: m => {
                        var g = mapToItem(root, m.x, m.y)
                        if (Math.abs(g.x - root.hx) > 1 || Math.abs(g.y - root.hy) > 1) { root.hx = g.x; root.hy = g.y; cmdList.currentIndex = crow.index }
                    }
                    onClicked: root.runCmd(crow.index)
                }
            }
        }

        // ---------- calculator ----------
        Rectangle {
            visible: root.mode === "calc"
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            radius: 18
            color: Qt.alpha(root.pal.accent, 0.12)
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: root.calcOut.text === "" ? "type an expression" : "= " + root.calcOut.text
                color: root.calcOut.ok ? root.pal.text : root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 22
                font.bold: root.calcOut.ok
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                visible: root.calcOut.ok
                text: "Enter to copy"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 11
            }
        }

        // ---------- footer hints ----------
        Row {
            visible: root.mode !== "calc"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 16
            spacing: 18
            Repeater {
                model: root.mode === "cmd"
                    ? [["↑↓", "move"], ["⏎", "run"], ["esc", "close"]]
                    : [["↑↓", "history"], ["←→", "cursor"], ["tab", "move"], ["⏎", "open"], [".", "all apps"], [">", "commands"], ["=", "calc"]]
                delegate: Row {
                    required property var modelData
                    spacing: 5
                    Text {
                        text: modelData[0]
                        color: root.pal.accent
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: modelData[1]
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                    }
                }
            }
        }
    }
}
