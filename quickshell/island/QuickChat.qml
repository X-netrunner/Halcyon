import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

// The AI chatbox: what the console corner opens when Desktop builder > Console shows "AI Chatbox".
// It is drawn like the console (same glass box, constellation, mono type, `❯` prompt) and talks to one provider at a time:
//
//   Luna        the local assistant. Used by default whenever she is installed ("auto"); her chat is the same session as the >luna window
//   Ollama      a model on this machine
//   OpenRouter, OpenAI, Anthropic, Gemini, Groq, DeepSeek    hosted models, one API key each
//   Custom      any OpenAI-compatible endpoint
//
// Switching provider: Tab (next ready one), Ctrl+P or the pill in the top right (the list), or `/provider <name>`. It applies at once.
// API keys go to scripts/halcyon-aichat.py, which keeps them in a 0600 file; this window never holds one after you press Enter.
//
//   quickshell ipc -p ~/.config/Halcyon/quickshell/island call island quickchat
//
// Keys: Enter send  ·  Esc stops an answer, then closes the list, then the box  ·  Tab next provider  ·  Ctrl+P provider list
//       Ctrl+L clears  ·  Up/Down earlier questions  ·  /help
Scope {
    id: root
    property var pal
    property bool stars: true             // constellations in this box (Settings > Constellations)
    property int flyCount: 0              // moving stars drifting in this box (0 = none)
    property int flyLoop: 150000
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool clickMode: false
    property bool autoHide: false
    property string spot: "tl"            // the corner it opens from: tl | bl | br
    property bool fsActive: false

    readonly property bool atRight: spot.charAt(1) === "r"
    readonly property bool atBottom: spot.charAt(0) === "b"
    readonly property int boxW: 620
    // the tallest the box ever gets: well under half the screen, so it never covers the work behind it (it grows with the conversation up to here, then scrolls)
    readonly property int fullH: Math.round(Math.min(440, Math.max(300, (win.screen ? win.screen.height : 1080) * 0.40)))
    readonly property string mono: pal.mono
    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-aichat.py"

    signal openLunaRequested()

    // ---------- open / close ----------
    property bool open: false
    property bool pinned: false
    property bool unpinned: false         // the pin button was switched off by hand: the box now closes when the pointer leaves, even in click mode
    property bool ddOpen: false           // the provider dropdown
    property bool focused: false
    property bool grabKeys: false
    property bool zoneHover: false
    readonly property real reveal: open ? 1 : 0
    readonly property bool shown: open
    readonly property bool typing: input.text !== ""
    readonly property bool mayAutoClose: !busy && !panelOpen && !ddOpen && input.text === "" && (autoHide || (!pinned && (!clickMode || unpinned)))

    property bool linger: false
    onOpenChanged: {
        if (open) { linger = true; lingerT.stop(); refresh() }
        else lingerT.restart()
    }
    Timer { id: lingerT; interval: root.pal.dSlow + 160; onTriggered: root.linger = false }   // (the window stays until the slide-out has finished)
    Timer { id: closeT; interval: 550; onTriggered: if (root.mayAutoClose) root.close() }
    Timer { id: autoFocusT; interval: 150; onTriggered: if (root.open && root.zoneHover && !root.focused) root.takeFocus() }
    Timer { id: grabT; interval: 350; onTriggered: root.grabKeys = false }

    readonly property bool wsHasFullscreen: {
        if (fsActive) return true
        var w = Hyprland.workspaces.values
        for (var i = 0; i < w.length; i++)
            if (w[i].focused && (w[i].hasfullscreen || w[i].hasFullscreen)) return true
        return false
    }
    onWsHasFullscreenChanged: if (wsHasFullscreen && !pinned && open) close()

    function takeFocus() {
        focused = true
        grabKeys = true
        grabT.restart()
        Qt.callLater(function () { input.forceActiveFocus() })
    }
    function close() {
        closeT.stop()
        open = false
        focused = false
        pinned = false
        unpinned = false
        grabKeys = false
        panelOpen = false
        ddOpen = false
    }
    // the pin button: pinning keeps the box up; unpinning lets it close as soon as the pointer is off it (at once when it already is)
    function setPinned(on) {
        pinned = on
        unpinned = !on
        if (on) closeT.stop()
        else if (!zoneHover) closeT.restart()
    }
    function toggle() {
        if (open && focused) { close(); return }
        closeT.stop()
        open = true
        pinned = true
        unpinned = false
        takeFocus()
    }
    // a click on the console corner (click mode): open it NOT pinned (the pin button pins it); it closes by itself once the pointer leaves, or on a second click
    function cornerToggle() {
        if (open) { close(); return }
        closeT.stop()
        open = true
        pinned = false
        unpinned = true            // not pinned: it folds back in by itself when the pointer leaves, even in click mode
        takeFocus()
    }
    // the console corner asks for the box by hovering: open it and take the keyboard, never close it again from there
    function summon() {
        closeT.stop()
        if (!open) open = true
        if (!focused) takeFocus()
    }
    function setHover(on) {
        if (on) closeT.stop()
        else { autoFocusT.stop(); ddOpen = false; if (mayAutoClose) closeT.restart() }   // leaving the box folds the dropdown too
    }

    // ---------- providers ----------
    property var providers: []             // [{ id, name, kind, presets }] from the script
    property string provider: "ollama"     // the one in use now (Luna when she is installed and nothing else was chosen)
    property string chosen: "auto"
    property var models: ({})
    property string ollamaHost: "http://127.0.0.1:11434"
    property string customEndpoint: ""
    property var ollamaModels: []
    property bool ollamaUp: false
    property var luna: ({ installed: false, blocked: "", ready: false })
    property var keySet: ({})
    property var ready: ({})
    property bool panelOpen: false

    function infoOf(id) {
        for (var i = 0; i < providers.length; i++) if (providers[i].id === id) return providers[i]
        return { id: id, name: id, kind: "openai", presets: [] }
    }
    function nameOf(id) { return infoOf(id).name }
    readonly property var curInfo: infoOf(provider)
    readonly property string curModel: provider === "luna" ? "" : (models[provider] || "")
    readonly property string curLabel: curInfo.name + (curModel !== "" ? "  " + curModel : "")

    function applyStatus(j) {
        providers = j.providers || providers
        provider = j.provider || provider
        chosen = j.chosen || chosen
        models = j.models || {}
        ollamaHost = j.ollamaHost || ollamaHost
        customEndpoint = j.customEndpoint || ""
        ollamaModels = j.ollamaModels || []
        ollamaUp = j.ollamaUp === true
        luna = j.luna || luna
        keySet = j.keySet || {}
        ready = j.ready || {}
    }
    function refresh() { if (!statusProc.running) statusProc.running = true }
    Process {
        id: statusProc
        command: ["python3", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.applyStatus(JSON.parse(text)) } catch (e) {} }
        }
    }
    Component.onCompleted: refresh()

    // saves go out one after the other so a quick pair of changes never races
    property var saveQ: []
    function save(obj) { saveQ = saveQ.concat([JSON.stringify(obj)]); pumpSave() }
    function pumpSave() {
        if (saveProc.running || saveQ.length === 0) return
        saveProc.command = ["python3", root.script, "set-config", saveQ[0]]
        saveQ = saveQ.slice(1)
        saveProc.running = true
    }
    Process { id: saveProc; onExited: root.pumpSave() }

    function setProvider(id) {
        if (id === provider && chosen === id) return
        provider = id
        chosen = id
        save({ provider: id })
        say(nameOf(id) + (curModel !== "" ? " · " + curModel : "") + (ready[id] === false ? "   (not ready: set it up below)" : ""), false)
        if (ready[id] === false) { panelOpen = true; refresh() }
    }
    function setModel(id, m) {
        var nm = {}
        for (var k in models) nm[k] = models[k]
        nm[id] = m
        models = nm
        var one = {}
        one[id] = m
        save({ models: one })
    }
    function cycleProvider() {
        var order = providers.map(function (p) { return p.id })
        if (order.length === 0) return
        var i = order.indexOf(provider)
        for (var n = 1; n <= order.length; n++) {
            var id = order[(i + n) % order.length]
            if (ready[id]) { setProvider(id); return }
        }
    }

    // keys: typed here, handed to the script on its standard input, forgotten by this window at once
    property string keyFor: ""
    Process {
        id: keyProc
        property string payload: ""
        stdinEnabled: true
        onStarted: { write(payload); closeStdin() }
        onExited: { payload = ""; root.refresh() }
    }
    function setKey(id, value) {
        if (keyProc.running) return
        keyProc.command = ["python3", root.script, "set-key", id]
        keyProc.payload = value
        keyProc.running = true
    }
    Process { id: newLunaProc; command: ["python3", root.script, "luna-new"] }

    // ---------- transcript ----------
    ListModel { id: mm }                   // role: you | ai | sys ; text ; tools ; meta ; live ; bad
    property bool busy: false
    property string streamText: ""
    property string phase: "thinking"
    property var asked: []
    property int askIdx: -1

    function say(t, bad) {
        mm.append({ role: "sys", text: t, tools: "", meta: "", live: false, bad: bad === true })
        scrollEnd()
    }
    function scrollEnd() { Qt.callLater(function () { view.positionViewAtEnd() }) }
    function clearChat() {
        mm.clear()
        if (provider === "luna") { newLunaProc.running = false; newLunaProc.running = true }
    }

    function send(raw) {
        var t = raw.trim()
        if (t === "") return
        if (asked[asked.length - 1] !== t) asked = asked.concat([t]).slice(-60)
        askIdx = -1
        if (t.charAt(0) === "/") { slash(t); return }
        if (busy) return
        var hist = []
        for (var i = Math.max(0, mm.count - 10); i < mm.count; i++) {
            var r = mm.get(i)
            if ((r.role === "you" || r.role === "ai") && r.text !== "" && !r.bad)
                hist.push({ role: r.role === "you" ? "user" : "assistant", content: r.text })
        }
        mm.append({ role: "you", text: t, tools: "", meta: "", live: false, bad: false })
        mm.append({ role: "ai", text: "", tools: "", meta: "", live: true, bad: false })
        streamText = ""
        phase = "thinking"
        busy = true
        chatProc.payload = JSON.stringify({ provider: provider, model: models[provider] || "", prompt: t, history: hist,
                                            ollamaHost: ollamaHost, endpoint: customEndpoint })
        chatProc.command = ["python3", root.script, "stream"]
        chatProc.running = true
        scrollEnd()
    }
    function stopChat() { if (chatProc.running) chatProc.signal(15) }

    function slash(t) {
        var p = t.split(/\s+/), c = p[0].toLowerCase(), arg = p.slice(1).join(" ").trim()
        if (c === "/clear" || c === "/new") { clearChat(); return }
        if (c === "/luna") { root.openLunaRequested(); return }
        if (c === "/provider" || c === "/p") {
            if (arg === "") { ddOpen = true; return }
            var want = arg.toLowerCase()
            if (want === "auto") { chosen = "auto"; save({ provider: "auto" }); refresh(); say("auto: Luna when she is installed, otherwise Ollama", false); return }
            for (var i = 0; i < providers.length; i++)
                if (providers[i].id === want || providers[i].name.toLowerCase() === want) { setProvider(providers[i].id); return }
            say("No provider called " + arg + ". Try: " + providers.map(function (x) { return x.id }).join(", "), true)
            return
        }
        if (c === "/model" || c === "/m") {
            if (provider === "luna") { say("Luna picks her own models: change them in her settings (>luna).", true); return }
            if (arg === "") { say("model: " + (models[provider] || "none set") + "   (" + nameOf(provider) + ")", false); return }
            setModel(provider, arg)
            say("model: " + arg, false)
            return
        }
        if (c === "/key") { say("Keys are not typed into the chat. Open the provider list (Ctrl+P) and paste it there.", true); return }
        say("/provider [name]   /model [name]   /clear   /luna\nTab: next provider    Ctrl+P: provider dropdown    Esc: stop, then close", false)
    }

    Process {
        id: chatProc
        property string payload: ""
        stdinEnabled: true
        onStarted: { write(payload); closeStdin() }
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                var i = mm.count - 1
                if (i < 0 || mm.get(i).role !== "ai") return
                if (o.type === "delta") {
                    root.streamText += o.text
                    root.phase = "writing"
                    mm.setProperty(i, "text", root.streamText)
                    root.scrollEnd()
                } else if (o.type === "think") {
                    if (root.streamText === "") root.phase = "thinking"
                } else if (o.type === "tool") {
                    if (o.state === "start") {
                        root.phase = "running " + o.name
                        var cur = mm.get(i).tools
                        mm.setProperty(i, "tools", (cur !== "" ? cur + "\n" : "") + o.name + (o.summary ? "   " + o.summary : ""))
                    }
                } else if (o.type === "done") {
                    mm.setProperty(i, "text", o.text || root.streamText)
                    mm.setProperty(i, "meta", root.nameOf(o.provider || root.provider) + (o.model ? " · " + o.model : "") + (o.secs ? " · " + o.secs + " s" : ""))
                    mm.setProperty(i, "live", false)
                    root.busy = false
                    root.scrollEnd()
                } else if (o.type === "error") {
                    mm.setProperty(i, "text", o.error)
                    mm.setProperty(i, "bad", true)
                    mm.setProperty(i, "live", false)
                    root.busy = false
                    root.scrollEnd()
                }
            }
        }
        onExited: {
            root.busy = false
            var i = mm.count - 1
            if (i >= 0 && mm.get(i).live) {
                mm.setProperty(i, "live", false)
                if (mm.get(i).text === "") mm.setProperty(i, "text", "stopped")
                mm.setProperty(i, "meta", "stopped")
            }
        }
    }

    // ---------- the window ----------
    PanelWindow {
        id: win
        visible: root.linger
        anchors { top: !root.atBottom; bottom: root.atBottom; left: !root.atRight; right: root.atRight }
        implicitWidth: root.boxW + 60
        implicitHeight: root.fullH + root.pal.boxTop + 60
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-chat"
        // (with the border around the screen it stays under the border, so it slides out from it, like the console)
        WlrLayershell.layer: (root.pinned && !root.pal.frameOn) ? WlrLayer.Overlay : WlrLayer.Top
        WlrLayershell.keyboardFocus: !root.focused ? WlrKeyboardFocus.None
                                   : ((root.grabKeys || root.zoneHover || root.typing || root.panelOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)

        mask: Region { item: zone }

        // one hover zone for the whole box (it has no corner trigger of its own: the console corner opens it)
        Item {
            id: zone
            anchors.top: root.atBottom ? undefined : parent.top
            anchors.bottom: root.atBottom ? parent.bottom : undefined
            anchors.left: root.atRight ? undefined : parent.left
            anchors.right: root.atRight ? parent.right : undefined
            width: root.shown ? root.boxW + 40 : 0
            height: root.shown ? (root.atBottom ? box.height + root.pal.boxEdge + 24 : box.y + box.height + 24) : 0
            HoverHandler { onHoveredChanged: { root.zoneHover = hovered; root.setHover(hovered) } }

            Glass {
                id: box
                pal: root.pal
                // the same as the console and the other boxes: border on = flush with it, flared into it, sliding out from under it
                // (from the corner or the side, as set in the Desktop builder); border off = floating, 22 px from the edge
                property real slide: root.reveal
                Behavior on slide { NumberAnimation { duration: root.open ? root.pal.dSlow : root.pal.dClose; easing.type: Easing.BezierSpline; easing.bezierCurve: root.open ? root.pal.curve : root.pal.curveClose } }
                joinH: root.pal.frameOn ? (root.atRight ? "r" : "l") : ""
                joinV: root.pal.frameOn ? (root.atBottom ? "b" : (root.pal.cornerOut ? "t" : "")) : ""
                transform: Translate { y: root.pal.cornerOut ? (root.atBottom ? 1 : -1) * (1 - box.slide) * (box.height + root.pal.frameT + 40) : 0 }
                x: root.pal.frameOn ? (root.atRight ? 40 - root.pal.frameT + (1 - slide) * (root.boxW + 40) : root.pal.frameT - (1 - slide) * (root.boxW + 40))
                                    : (root.atRight ? 18 + (1 - root.reveal) * (root.boxW * 0.5) : 22 - (1 - root.reveal) * (root.boxW * 0.5))
                y: root.pal.frameOn ? (root.atBottom ? zone.height - root.pal.frameT - height : (root.pal.cornerOut ? root.pal.frameT : root.pal.boxTop))
                 : root.atBottom ? (zone.height - root.pal.boxEdge - height + (1 - root.reveal) * (height + root.pal.boxEdge + 14))
                                 : (root.pal.boxTop - (1 - root.reveal) * (height + root.pal.boxTop + 14))
                width: root.boxW
                // grows with the conversation: head + input + the messages (+ the setup panel when it is open), up to fullH, then the list scrolls
                readonly property real wantH: mm.count === 0 ? 230 + panel.height
                                            : Math.min(root.fullH, Math.max(170, 118 + panel.height + view.contentHeight))
                // while it folds away the height is held, so the setup panel / dropdown closing does not squash it mid-slide
                property real heldH: 230
                Binding { target: box; property: "heldH"; value: box.height; when: root.open }
                height: root.open ? Math.max(wantH, root.ddOpen ? ddList.height + 70 : 0) : heldH
                radius: root.pal.rLg
                opacityBody: 0.94
                opacity: root.pal.frameOn ? 1 : Math.min(1, root.reveal * 1.6)
                visible: root.pal.frameOn ? slide > 0.002 : opacity > 0.01
                border.color: root.focused ? root.pal.lineFocus : Qt.alpha(root.pal.accent, 0.40)
                Behavior on x { enabled: !root.pal.frameOn; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Behavior on y { enabled: !root.pal.frameOn; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

                MouseArea { anchors.fill: parent; onClicked: root.takeFocus() }
                Rectangle { visible: !root.pal.frameOn; anchors.fill: parent; radius: root.pal.rLg; color: Qt.rgba(0, 0, 0, 0.45) }   // (the border's own colour is the backing there)

                // resting the pointer on the box is enough to type (hover mode)
                HoverHandler { onHoveredChanged: { if (hovered && root.open && !root.focused && !root.clickMode) dwellT.restart(); else dwellT.stop() } }
                Timer { id: dwellT; interval: 250; onTriggered: if (root.open && !root.focused) root.takeFocus() }

                Backdrop {
                    visible: root.shown && root.stars
                    anchors.fill: parent
                    anchors.margins: 14
                    pal: root.pal
                    mode: root.sysmode
                    avatarStars: root.starData
                    profileStars: root.profileStars
                    dots: 6
                    artStrength: 0.25
                    artFit: 0.95
                    artShift: 90
                }
                BarStars { anchors.fill: parent; anchors.margins: 14; pal: root.pal; count: root.flyCount; loopMs: root.flyLoop; sizeScale: 1.3; active: root.shown; visible: root.shown && root.flyCount > 0 }

                // ---------- provider dropdown (click anywhere else to close it) ----------
                MouseArea { anchors.fill: parent; z: 90; visible: root.ddOpen; onClicked: root.ddOpen = false }
                Rectangle {
                    id: ddList
                    z: 100
                    visible: root.ddOpen
                    anchors { right: parent.right; rightMargin: 20; top: parent.top; topMargin: 16 + 22 + 6 }
                    width: 250
                    height: ddCol.implicitHeight + 12
                    radius: 10
                    color: Qt.rgba(0.05, 0.05, 0.07, 0.97)
                    border.width: 1
                    border.color: root.pal.lineFocus
                    Column {
                        id: ddCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                        spacing: 2
                        Repeater {
                            model: root.providers
                            delegate: Rectangle {
                                id: dRow
                                required property var modelData
                                readonly property bool cur: modelData.id === root.provider
                                width: ddCol.width
                                height: 26
                                radius: 7
                                color: cur ? root.pal.chosenFill : (dHov.hovered ? root.pal.fillHover : "transparent")
                                Rectangle {
                                    id: dDot
                                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                    width: 6; height: 6; radius: 3
                                    color: root.ready[dRow.modelData.id] ? root.pal.good : Qt.alpha(root.pal.muted, 0.5)
                                }
                                Text {
                                    anchors { left: dDot.right; leftMargin: 9; right: dNote.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                    text: dRow.modelData.name
                                    elide: Text.ElideRight
                                    color: dRow.cur ? root.pal.chosenText : ((dRow.modelData.id === "luna" && !root.luna.installed) ? Qt.alpha(root.pal.muted, 0.85) : root.pal.text)
                                    font.family: root.mono
                                    font.pixelSize: 11
                                    font.weight: dRow.cur ? Font.DemiBold : Font.Normal
                                }
                                Text {
                                    id: dNote
                                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                    text: dRow.cur ? "in use" : (dRow.modelData.id === "luna" && !root.luna.installed ? "not installed" : (root.ready[dRow.modelData.id] ? "" : "needs setup"))
                                    color: Qt.alpha(root.pal.muted, 0.9)
                                    font.family: root.mono
                                    font.pixelSize: 10
                                }
                                HoverHandler { id: dHov }
                                TapHandler { onTapped: { root.ddOpen = false; root.setProvider(dRow.modelData.id) } }
                            }
                        }
                    }
                }

                // ---------- title line ----------
                Item {
                    id: head
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 16 }
                    height: 22
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 14
                        QcBtn { pal: root.pal; text: root.pinned ? "pinned" : "pin"; hot: root.pinned; onClicked: root.setPinned(!root.pinned) }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.busy
                        text: "❯ chat"
                        color: root.pal.accent
                        font.family: root.mono
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: root.busy
                        text: root.phase + " · Esc stops"
                        color: root.pal.accent
                        font.family: root.mono
                        font.pixelSize: 11
                    }
                    // setup for the provider in use (host, model, key)
                    QcBtn {
                        id: setupBtn
                        pal: root.pal
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        text: "setup"
                        hot: root.panelOpen
                        onClicked: { root.ddOpen = false; root.panelOpen = !root.panelOpen; if (root.panelOpen) root.refresh() }
                    }
                    // the provider in use; a click drops the list of every provider (Luna included)
                    Rectangle {
                        anchors { right: setupBtn.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        height: 22
                        width: Math.min(190, pillText.implicitWidth + 40)
                        radius: 8
                        color: root.ddOpen ? root.pal.chosenFill : (pillHov.hovered ? root.pal.fillHover : root.pal.fill)
                        border.width: 1
                        border.color: root.ddOpen ? root.pal.lineFocus : root.pal.lineSoft
                        Text {
                            id: pillText
                            anchors { left: parent.left; leftMargin: 10; right: caret.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                            elide: Text.ElideRight
                            text: root.curLabel
                            color: root.pal.accent
                            font.family: root.mono
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                        }
                        Text {
                            id: caret
                            anchors { right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                            text: root.ddOpen ? "▴" : "▾"
                            color: root.pal.accent
                            font.family: root.mono
                            font.pixelSize: 10
                        }
                        HoverHandler { id: pillHov }
                        TapHandler { onTapped: { root.panelOpen = false; root.ddOpen = !root.ddOpen; if (root.ddOpen) root.refresh() } }
                    }
                }
                Rectangle { id: sep1; anchors { left: parent.left; right: parent.right; top: head.bottom; leftMargin: 20; rightMargin: 20; topMargin: 10 } height: 1; color: root.pal.lineSoft }

                // ---------- the provider list ----------
                Item {
                    id: panel
                    anchors { left: parent.left; right: parent.right; top: sep1.bottom; leftMargin: 20; rightMargin: 20 }
                    height: root.panelOpen ? pc.implicitHeight + 20 : 0
                    clip: true
                    visible: height > 0.5
                    Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

                    Column {
                        id: pc
                        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 10 }
                        spacing: 10

                        // Luna
                        Column {
                            width: parent.width
                            spacing: 8
                            visible: root.provider === "luna"
                            Text {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: !root.luna.installed ? "Luna is not installed. Run ./install.sh --luna, or pick another provider."
                                    : root.luna.blocked !== "" ? root.luna.blocked
                                    : "Luna answers here and keeps the chat in her own window too. Her tools, memory and models are in her settings."
                                color: root.luna.installed && root.luna.blocked === "" ? root.pal.muted : root.pal.warn
                                font.family: root.mono
                                font.pixelSize: 11
                            }
                            Row {
                                spacing: 16
                                QcBtn { pal: root.pal; text: "open Luna window"; onClicked: { root.panelOpen = false; root.openLunaRequested() } }
                                QcBtn { pal: root.pal; text: "new session"; onClicked: { root.clearChat(); root.panelOpen = false } }
                                QcBtn { pal: root.pal; text: chosen === "auto" ? "automatic: on" : "make automatic"; hot: chosen === "auto"
                                         onClicked: { root.chosen = "auto"; root.save({ provider: "auto" }); root.refresh() } }
                            }
                        }

                        // Ollama
                        Column {
                            width: parent.width
                            spacing: 8
                            visible: root.provider === "ollama"
                            RowLayout {
                                width: parent.width
                                spacing: 8
                                Text { text: "host"; color: root.pal.muted; font.family: root.mono; font.pixelSize: 11; Layout.preferredWidth: 38 }
                                QcField {
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    text: root.ollamaHost
                                    placeholder: "http://127.0.0.1:11434"
                                    onCommitted: v => { if (v !== "" && v !== root.ollamaHost) { root.ollamaHost = v; root.save({ ollamaHost: v }); root.refresh() } }
                                    onEscaped: root.panelOpen = false
                                }
                            }
                            Text {
                                visible: !root.ollamaUp
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: "Ollama is not answering at " + root.ollamaHost + ". Start it: systemctl --user start ollama"
                                color: root.pal.warn
                                font.family: root.mono
                                font.pixelSize: 11
                            }
                            Flow {
                                width: parent.width
                                spacing: 6
                                visible: root.ollamaModels.length > 0
                                Repeater {
                                    model: root.ollamaModels
                                    delegate: QcChip {
                                        required property string modelData
                                        pal: root.pal
                                        label: modelData
                                        current: modelData === root.models.ollama
                                        onClicked: root.setModel("ollama", modelData)
                                    }
                                }
                            }
                        }

                        // hosted providers and a custom endpoint
                        Column {
                            id: hosted
                            width: parent.width
                            spacing: 8
                            readonly property bool on: root.provider !== "luna" && root.provider !== "ollama"
                            visible: on
                            RowLayout {
                                width: parent.width
                                spacing: 8
                                visible: root.provider === "custom"
                                Text { text: "endpoint"; color: root.pal.muted; font.family: root.mono; font.pixelSize: 11; Layout.preferredWidth: 52 }
                                QcField {
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    text: root.customEndpoint
                                    placeholder: "https://host/v1/chat/completions"
                                    onCommitted: v => { if (v !== root.customEndpoint) { root.customEndpoint = v; root.save({ customEndpoint: v }); root.refresh() } }
                                    onEscaped: root.panelOpen = false
                                }
                            }
                            Flow {
                                width: parent.width
                                spacing: 6
                                visible: hosted.on && root.curInfo.presets.length > 0
                                Repeater {
                                    model: root.curInfo.presets
                                    delegate: QcChip {
                                        required property string modelData
                                        pal: root.pal
                                        label: modelData
                                        current: modelData === root.models[root.provider]
                                        onClicked: root.setModel(root.provider, modelData)
                                    }
                                }
                            }
                            RowLayout {
                                width: parent.width
                                spacing: 8
                                visible: hosted.on
                                Text { text: "model"; color: root.pal.muted; font.family: root.mono; font.pixelSize: 11; Layout.preferredWidth: hosted.on && root.provider === "custom" ? 52 : 38 }
                                QcField {
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    text: root.models[root.provider] || ""
                                    placeholder: "model name"
                                    onCommitted: v => { if (v !== (root.models[root.provider] || "")) root.setModel(root.provider, v) }
                                    onEscaped: root.panelOpen = false
                                }
                            }
                            RowLayout {
                                width: parent.width
                                spacing: 8
                                visible: hosted.on
                                Text { text: "key"; color: root.pal.muted; font.family: root.mono; font.pixelSize: 11; Layout.preferredWidth: hosted.on && root.provider === "custom" ? 52 : 38 }
                                QcField {
                                    id: keyField
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    secret: true
                                    placeholder: root.keySet[root.provider] ? "saved: paste a new key to replace it" : "paste your API key and press Enter"
                                    onCommitted: v => { if (v !== "") { root.setKey(root.provider, v); text = "" } }
                                    onEscaped: root.panelOpen = false
                                }
                                QcBtn {
                                    pal: root.pal
                                    visible: root.keySet[root.provider] === true
                                    text: "remove"
                                    onClicked: root.setKey(root.provider, "")
                                }
                            }
                        }
                    }
                }
                Rectangle { id: sepP; anchors { left: parent.left; right: parent.right; top: panel.bottom; leftMargin: 20; rightMargin: 20 } height: 1; color: root.pal.lineSoft; visible: panel.visible }

                // ---------- the conversation ----------
                Item {
                    id: body
                    anchors { left: parent.left; right: parent.right; top: sepP.bottom; bottom: sep2.top; leftMargin: 20; rightMargin: 20; topMargin: 12; bottomMargin: 10 }

                    // nothing asked yet
                    Column {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        spacing: 4
                        visible: mm.count === 0
                        Text {
                            width: parent.width
                            text: "ask anything"
                            color: "#f3f4f6"
                            font.family: root.mono; font.pixelSize: 13; font.weight: Font.Medium
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: "answered by " + root.curLabel + (root.chosen === "auto" && root.provider === "luna" ? "  (automatic: Luna is installed)" : "")
                            color: Qt.lighter(root.pal.muted, 1.35)
                            font.family: root.mono; font.pixelSize: 11
                        }
                        Text {
                            topPadding: 6
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: "Tab next provider  ·  Ctrl+P dropdown  ·  /help"
                            color: Qt.alpha(root.pal.muted, 0.9)
                            font.family: root.mono; font.pixelSize: 10
                        }
                    }

                    ListView {
                        id: view
                        anchors.fill: parent
                        clip: true
                        model: mm
                        spacing: 0
                        visible: mm.count > 0
                        boundsBehavior: Flickable.StopAtBounds
                        TapHandler { onTapped: root.takeFocus() }
                        delegate: Item {
                            id: row
                            required property int index
                            required property string role
                            required property string text
                            required property string tools
                            required property string meta
                            required property bool live
                            required property bool bad
                            width: view.width
                            height: rc.implicitHeight + (role === "you" && index > 0 ? 12 : 4)

                            Rectangle {      // a hairline before each new question
                                visible: row.role === "you" && row.index > 0
                                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 2 }
                                height: 1
                                color: root.pal.lineSoft
                            }
                            Column {
                                id: rc
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                spacing: 3

                                // your question, like a command in the console
                                Text {
                                    visible: row.role === "you"
                                    width: parent.width
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    textFormat: Text.PlainText
                                    topPadding: 4
                                    text: "❯ " + row.text
                                    color: root.pal.accent
                                    font.family: root.mono; font.pixelSize: 12; font.weight: Font.DemiBold
                                }
                                // what Luna ran
                                Text {
                                    visible: row.role === "ai" && row.tools !== ""
                                    width: parent.width
                                    leftPadding: 14
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    textFormat: Text.PlainText
                                    text: row.tools
                                    color: Qt.alpha(root.pal.muted, 0.9)
                                    font.family: root.mono; font.pixelSize: 10
                                }
                                // the answer (plain text you can select and copy)
                                SelText {
                                    visible: row.role !== "you" && (row.text !== "" || !row.live)
                                    width: parent.width
                                    leftPadding: 14
                                    text: row.text === "" ? " " : row.text
                                    color: row.bad ? root.pal.bad : (row.role === "sys" ? Qt.lighter(root.pal.muted, 1.35) : "#d7dae0")
                                    font.family: root.mono
                                    font.pixelSize: row.role === "sys" ? 11 : 12
                                    wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                                }
                                // under an answer: who wrote it, and copy
                                Row {
                                    visible: row.role === "ai" && !row.live && row.text !== ""
                                    leftPadding: 14
                                    spacing: 12
                                    Text {
                                        text: row.meta
                                        visible: row.meta !== ""
                                        color: root.pal.muted
                                        font.family: root.mono; font.pixelSize: 10
                                    }
                                    QcBtn {
                                        id: cp
                                        pal: root.pal
                                        font.pixelSize: 10
                                        text: "copy"
                                        onClicked: { Quickshell.execDetached(["wl-copy", row.text]); text = "copied" }
                                    }
                                }
                                Item { width: 1; height: 2 }
                            }
                        }
                    }
                }

                // ---------- input line ----------
                Rectangle { id: sep2; anchors { left: parent.left; right: parent.right; bottom: inputRow.top; leftMargin: 20; rightMargin: 20; bottomMargin: 8 } height: 1; color: root.pal.lineSoft }
                Item {
                    id: inputRow
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 16 }
                    height: 22
                    TapHandler { onTapped: root.takeFocus() }
                    Text {
                        id: prompt
                        anchors.verticalCenter: parent.verticalCenter
                        text: "❯"
                        color: root.pal.accent
                        font.family: root.mono; font.pixelSize: 13; font.weight: Font.DemiBold
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.70)
                    }
                    TextInput {
                        id: input
                        anchors { left: prompt.right; leftMargin: 8; right: act.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        color: "#ffffff"
                        selectionColor: Qt.alpha(root.pal.accent, 0.45)
                        font.family: root.mono; font.pixelSize: 13; font.weight: Font.Medium
                        clip: true
                        TapHandler { onTapped: root.takeFocus() }
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Escape) {
                                if (root.busy) root.stopChat()
                                else if (root.ddOpen) root.ddOpen = false
                                else if (root.panelOpen) root.panelOpen = false
                                else root.close()
                                e.accepted = true
                            } else if (e.key === Qt.Key_Tab) { root.cycleProvider(); e.accepted = true }
                            else if (e.key === Qt.Key_P && (e.modifiers & Qt.ControlModifier)) { root.panelOpen = false; root.ddOpen = !root.ddOpen; if (root.ddOpen) root.refresh(); e.accepted = true }
                            else if (e.key === Qt.Key_L && (e.modifiers & Qt.ControlModifier)) { root.clearChat(); e.accepted = true }
                            else if (e.key === Qt.Key_U && (e.modifiers & Qt.ControlModifier)) { text = ""; e.accepted = true }
                            else if (e.key === Qt.Key_C && (e.modifiers & Qt.ControlModifier) && root.busy && input.selectedText === "") { root.stopChat(); e.accepted = true }
                            else if (e.key === Qt.Key_Up && root.asked.length) {
                                root.askIdx = root.askIdx < 0 ? root.asked.length - 1 : Math.max(0, root.askIdx - 1)
                                text = root.asked[root.askIdx]; cursorPosition = text.length; e.accepted = true
                            } else if (e.key === Qt.Key_Down && root.askIdx >= 0) {
                                root.askIdx++
                                text = root.askIdx >= root.asked.length ? "" : root.asked[root.askIdx]
                                if (root.askIdx >= root.asked.length) root.askIdx = -1
                                cursorPosition = text.length; e.accepted = true
                            }
                        }
                        onAccepted: { var l = text; text = ""; root.send(l) }
                    }
                    Text {
                        anchors { left: input.left; verticalCenter: parent.verticalCenter }
                        visible: input.text === "" && !root.busy
                        text: "ask " + root.curInfo.name.toLowerCase()
                        color: Qt.alpha(root.pal.muted, 0.8)
                        font.family: root.mono; font.pixelSize: 13
                    }
                    QcBtn {
                        id: act
                        pal: root.pal
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        text: root.busy ? "stop" : "send"
                        hot: root.busy || input.text !== ""
                        onClicked: { if (root.busy) root.stopChat(); else { var l = input.text; input.text = ""; root.send(l) } }
                    }
                }
            }
        }
    }
}
