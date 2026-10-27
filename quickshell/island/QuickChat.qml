import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

// Top pop-out AI Chatbox for Halcyon.
// Operates as its own self-contained assistant surface without opening Luna's management menu.
// Supports:
//   - Custom API Keys (OpenAI, OpenRouter, DeepSeek, Groq, Gemini, Custom OpenAI-compatible endpoints)
//   - Local Ollama models (with auto-discovery)
//   - Luna engine (via local stdio)
//
// Toggle via:
//   quickshell ipc -p ~/.config/Halcyon/quickshell/island call island quickchat
//   or click/hover the console corner when "AI Chatbox" is selected in Desktop builder.
Scope {
    id: root
    property var pal
    property bool stars: true
    property int flyCount: 0
    property int flyLoop: 150000
    property bool clickMode: false
    property bool autoHide: false
    property string spot: "tl"
    property bool fsActive: false

    readonly property bool atRight: spot.charAt(1) === "r"
    readonly property bool atBottom: spot.charAt(0) === "b"

    readonly property int boxW: 620
    readonly property int boxH: 620
    readonly property color txt: root.pal ? root.pal.text : "#dcdde8"
    readonly property color acc: root.pal ? root.pal.accent : "#7aa2f7"
    readonly property color mut: root.pal ? root.pal.muted : "#9496a8"

    signal openTerminalRequested()

    property bool open: false
    property bool focused: false
    property bool pinned: false
    property bool zoneHover: false
    property bool grabKeys: false
    property real reveal: 0
    readonly property bool shown: open || reveal > 0.01

    Behavior on reveal { NumberAnimation { duration: root.pal ? root.pal.dSlow : 240; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal ? root.pal.curve : [0.2, 0, 0, 1] } }
    onOpenChanged: reveal = open ? 1 : 0

    function takeFocus() { focused = true; grabKeys = true; input.forceActiveFocus() }
    function close() {
        open = false
        focused = false
        pinned = false
        grabKeys = false
        settingsOpen = false
    }
    function toggle() {
        if (open && focused) { close(); return }
        open = true
        pinned = true
        takeFocus()
    }

    // ---------- configuration state ----------
    property string backend: "ollama"       // "ollama" | "api" | "luna"
    property string ollamaModel: "qwen2.5:3b-instruct"
    property string ollamaHost: "http://127.0.0.1:11434"
    property string apiProvider: "openrouter"
    property string apiModel: "openai/gpt-4o-mini"
    property string apiEndpoint: "https://openrouter.ai/api/v1/chat/completions"
    property string apiKey: ""
    property string maskedKey: ""
    property bool settingsOpen: false
    property bool keyVisible: false
    property var discoveredOllama: []

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-aichat.py"

    // Load config on startup
    Process {
        id: cfgLoadProc
        command: ["python3", root.script, "get-config"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var c = JSON.parse(text)
                    if (c.backend) root.backend = c.backend
                    if (c.ollamaModel) root.ollamaModel = c.ollamaModel
                    if (c.ollamaHost) root.ollamaHost = c.ollamaHost
                    if (c.apiProvider) root.apiProvider = c.apiProvider
                    if (c.apiModel) root.apiModel = c.apiModel
                    if (c.apiEndpoint) root.apiEndpoint = c.apiEndpoint
                    if (c.apiKey) root.apiKey = c.apiKey
                    if (c.maskedKey) root.maskedKey = c.maskedKey
                } catch (e) {}
            }
        }
    }
    Component.onCompleted: cfgLoadProc.running = true

    // Load models
    Process {
        id: modelsProc
        command: ["python3", root.script, "list-models"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    if (d.ollama && d.ollama.length > 0) {
                        root.discoveredOllama = d.ollama
                        if (!root.ollamaModel || root.discoveredOllama.indexOf(root.ollamaModel) < 0)
                            root.ollamaModel = d.ollama[0]
                    }
                } catch (e) {}
            }
        }
    }
    function refreshModels() { if (!modelsProc.running) modelsProc.running = true }

    function saveConfig() {
        var payload = JSON.stringify({
            backend: root.backend,
            ollamaModel: root.ollamaModel,
            ollamaHost: root.ollamaHost,
            apiProvider: root.apiProvider,
            apiModel: root.apiModel,
            apiEndpoint: root.apiEndpoint,
            apiKey: root.apiKey
        })
        saveProc.command = ["python3", root.script, "set-config", payload]
        saveProc.running = true
        settingsOpen = false
    }
    Process { id: saveProc }

    // ---------- chat messages ----------
    ListModel {
        id: mm
        Component.onCompleted: {
            append({
                role: "ai",
                text: "Hello! I am your quick AI chatbox. You can talk to me directly, switch between Ollama, your own API key, or Luna via ⚙ Settings, or use slash commands like `/model` and `/backend`.",
                live: false,
                modelName: "assistant",
                bad: false
            })
        }
    }

    property bool busy: false
    property string streamText: ""

    function sendPrompt(q) {
        var t = q.trim()
        if (t === "") return
        input.text = ""

        // Handle slash commands
        if (t.charAt(0) === "/") {
            handleSlash(t)
            return
        }

        mm.append({ role: "you", text: t, live: false, modelName: "", bad: false })
        mm.append({ role: "ai", text: "", live: true, modelName: currentBadge(), bad: false })
        view.positionViewAtEnd()

        var hist = []
        var maxHistory = 10
        var start = Math.max(0, mm.count - 1 - maxHistory)
        for (var i = start; i < mm.count - 1; i++) {
            var item = mm.get(i)
            if (item.text && !item.bad) {
                hist.push({ role: item.role === "you" ? "user" : "assistant", content: item.text })
            }
        }

        var req = {
            backend: root.backend,
            prompt: t,
            history: hist,
            ollamaModel: root.ollamaModel,
            ollamaHost: root.ollamaHost,
            apiProvider: root.apiProvider,
            apiModel: root.apiModel,
            apiEndpoint: root.apiEndpoint,
            apiKey: root.apiKey
        }

        streamText = ""
        busy = true
        chatProc.command = ["python3", root.script, "stream"]
        chatProc.payload = JSON.stringify(req)
        chatProc.running = true
    }

    function handleSlash(cmd) {
        var parts = cmd.split(" ")
        var c = parts[0].toLowerCase()
        var arg = parts.slice(1).join(" ").trim()

        if (c === "/clear") {
            mm.clear()
            mm.append({ role: "ai", text: "Chat history cleared.", live: false, modelName: "system", bad: false })
        } else if (c === "/backend") {
            if (arg === "ollama" || arg === "api" || arg === "luna") {
                root.backend = arg
                saveConfig()
                mm.append({ role: "ai", text: "Switched backend to `" + arg + "`.", live: false, modelName: "system", bad: false })
            } else {
                mm.append({ role: "ai", text: "Usage: `/backend <ollama|api|luna>`", live: false, modelName: "system", bad: true })
            }
        } else if (c === "/model") {
            if (arg) {
                if (root.backend === "ollama") root.ollamaModel = arg
                else root.apiModel = arg
                saveConfig()
                mm.append({ role: "ai", text: "Model set to `" + arg + "`.", live: false, modelName: "system", bad: false })
            } else {
                var cur = root.backend === "ollama" ? root.ollamaModel : root.apiModel
                mm.append({ role: "ai", text: "Current model: `" + cur + "`. Usage: `/model <name>`", live: false, modelName: "system", bad: false })
            }
        } else if (c === "/key") {
            if (arg) {
                root.apiKey = arg
                saveConfig()
                mm.append({ role: "ai", text: "API Key updated successfully.", live: false, modelName: "system", bad: false })
            } else {
                mm.append({ role: "ai", text: "Usage: `/key <your_api_key>`", live: false, modelName: "system", bad: true })
            }
        } else if (c === "/help") {
            mm.append({
                role: "ai",
                text: "**Available Slash Commands:**\n- `/clear` : clear chat history\n- `/backend <ollama|api|luna>` : switch engine\n- `/model <name>` : change active model\n- `/key <api_key>` : update custom API key\n- `/help` : show this help",
                live: false, modelName: "system", bad: false
            })
        } else {
            mm.append({ role: "ai", text: "Unknown command `" + c + "`. Type `/help` for options.", live: false, modelName: "system", bad: true })
        }
        view.positionViewAtEnd()
    }

    function stopChat() {
        if (chatProc.running) chatProc.signal(15)
        busy = false
    }

    function currentBadge() {
        if (backend === "ollama") return "Ollama · " + (ollamaModel || "local")
        if (backend === "api") return (apiProvider.toUpperCase()) + " · " + (apiModel || "api")
        return "Luna"
    }

    Process {
        id: chatProc
        property string payload: ""
        onStarted: {
            write(payload)
            closeStdin()
        }
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                var idx = mm.count - 1
                if (idx < 0) return

                if (o.type === "delta") {
                    root.streamText += o.text
                    mm.setProperty(idx, "text", root.streamText)
                    view.positionViewAtEnd()
                } else if (o.type === "done") {
                    mm.setProperty(idx, "text", o.text || root.streamText)
                    mm.setProperty(idx, "live", false)
                    if (o.model) mm.setProperty(idx, "modelName", o.model)
                    root.busy = false
                    view.positionViewAtEnd()
                } else if (o.type === "error") {
                    mm.setProperty(idx, "text", o.error)
                    mm.setProperty(idx, "bad", true)
                    mm.setProperty(idx, "live", false)
                    root.busy = false
                    view.positionViewAtEnd()
                }
            }
        }
        onExited: {
            root.busy = false
            var idx = mm.count - 1
            if (idx >= 0 && mm.get(idx).live) {
                mm.setProperty(idx, "live", false)
                if (!mm.get(idx).text) mm.setProperty(idx, "text", "Generation stopped.")
            }
        }
    }

    // Hover triggers
    Timer { id: closeT; interval: 550; onTriggered: if (!root.pinned && !root.zoneHover && !root.busy) root.close() }
    function setHover(on) {
        if (on) { closeT.stop(); if (!clickMode) { open = true; takeFocus() } }
        else if (!clickMode && !pinned && !busy) closeT.restart()
    }
    function cornerTap() {
        if (open) close()
        else { open = true; takeFocus() }
    }

    // Layershell window
    PanelWindow {
        id: win
        anchors { top: !root.atBottom; bottom: root.atBottom; left: !root.atRight; right: root.atRight }
        implicitWidth: root.boxW + 60
        implicitHeight: root.boxH + 60
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "island-chat"
        WlrLayershell.layer: root.pinned ? WlrLayer.Overlay : WlrLayer.Top
        WlrLayershell.keyboardFocus: !root.focused ? WlrKeyboardFocus.None
                                   : ((root.grabKeys || root.zoneHover || input.text !== "") ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)

        mask: Region { item: zone }

        Item {
            id: zone
            anchors.top: root.atBottom ? undefined : parent.top
            anchors.bottom: root.atBottom ? parent.bottom : undefined
            anchors.left: root.atRight ? undefined : parent.left
            anchors.right: root.atRight ? parent.right : undefined
            width: root.shown ? root.boxW + 40 : (root.clickMode ? 28 : 14)
            height: root.shown ? root.boxH + 40 : (root.clickMode ? 28 : 14)

            HoverHandler { onHoveredChanged: { root.zoneHover = hovered; root.setHover(hovered) } }

            // Click corner indicator
            Rectangle {
                visible: root.clickMode && !root.shown
                x: root.atRight ? parent.width - 15 : 3; y: root.atBottom ? parent.height - 15 : 3
                width: 12; height: 12; radius: 6
                color: Qt.alpha(root.acc, 0.5)
            }
            Item {
                x: root.atRight ? parent.width - width : 0; y: root.atBottom ? parent.height - height : 0
                width: 24; height: 24
                TapHandler {
                    enabled: root.clickMode
                    onTapped: root.cornerTap()
                }
            }

            Glass {
                id: box
                pal: root.pal
                x: root.atRight ? 18 + (1 - root.reveal) * (root.boxW * 0.5) : 22 - (1 - root.reveal) * (root.boxW * 0.5)
                y: root.atBottom ? (zone.height - height + (1 - root.reveal) * 40) : (24 - (1 - root.reveal) * 40)
                width: root.boxW
                height: root.boxH
                radius: root.pal ? root.pal.rLg : 18
                opacityBody: 0.94
                opacity: Math.min(1, root.reveal * 1.6)
                visible: opacity > 0.01
                border.color: root.focused ? (root.pal ? root.pal.lineFocus : "#7aa2f7") : Qt.alpha(root.acc, 0.40)

                // Background tint
                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Qt.rgba(0.04, 0.05, 0.08, 0.65)
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.takeFocus()
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 10

                    // ---------- HEADER ----------
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        // Switch to Terminal
                        Rectangle {
                            width: 28; height: 26; radius: 6
                            color: termHov.hovered ? Qt.alpha(root.acc, 0.25) : Qt.alpha(root.txt, 0.08)
                            border.width: 1; border.color: Qt.alpha(root.txt, 0.15)
                            Text {
                                anchors.centerIn: parent
                                text: ">_"
                                color: root.pal ? root.txt : "#ffffff"
                                font.family: root.pal ? root.pal.mono : "monospace"
                                font.pixelSize: 11; font.bold: true
                            }
                            HoverHandler { id: termHov }
                            TapHandler { onTapped: root.openTerminalRequested() }
                        }

                        Text {
                            text: "AI CHAT"
                            color: root.pal ? root.txt : "#ffffff"
                            font.pixelSize: 13
                            font.bold: true
                            font.letterSpacing: 1.5
                        }

                        // Current backend badge
                        Rectangle {
                            Layout.fillWidth: true
                            height: 24; radius: 6
                            color: Qt.alpha(root.acc, 0.15)
                            border.width: 1; border.color: Qt.alpha(root.acc, 0.3)
                            Text {
                                anchors.centerIn: parent
                                width: parent.width - 12
                                text: root.currentBadge()
                                color: root.acc
                                font.pixelSize: 11
                                font.family: root.pal ? root.pal.mono : "monospace"
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        // Settings Button (gear)
                        Rectangle {
                            width: 28; height: 26; radius: 6
                            color: (root.settingsOpen || setHov.hovered) ? Qt.alpha(root.acc, 0.35) : Qt.alpha(root.txt, 0.08)
                            border.width: 1; border.color: Qt.alpha(root.txt, 0.15)
                            Text {
                                anchors.centerIn: parent
                                text: "⚙"
                                color: root.pal ? root.txt : "#ffffff"
                                font.pixelSize: 13
                            }
                            HoverHandler { id: setHov }
                            TapHandler {
                                onTapped: {
                                    root.settingsOpen = !root.settingsOpen
                                    if (root.settingsOpen) root.refreshModels()
                                }
                            }
                        }

                        // Clear Button
                        Rectangle {
                            width: 28; height: 26; radius: 6
                            color: clrHov.hovered ? Qt.alpha("#ff6b6b", 0.3) : Qt.alpha(root.txt, 0.08)
                            border.width: 1; border.color: Qt.alpha(root.txt, 0.15)
                            Text {
                                anchors.centerIn: parent
                                text: "🗑"
                                font.pixelSize: 12
                            }
                            HoverHandler { id: clrHov }
                            TapHandler {
                                onTapped: {
                                    mm.clear()
                                    mm.append({ role: "ai", text: "Chat history cleared.", live: false, modelName: "system", bad: false })
                                }
                            }
                        }

                        // Pin Button
                        Rectangle {
                            width: 28; height: 26; radius: 6
                            color: root.pinned ? Qt.alpha(root.acc, 0.4) : (pinHov.hovered ? Qt.alpha(root.txt, 0.15) : Qt.alpha(root.txt, 0.08))
                            border.width: 1; border.color: Qt.alpha(root.txt, 0.15)
                            Text {
                                anchors.centerIn: parent
                                text: "📌"
                                font.pixelSize: 11
                            }
                            HoverHandler { id: pinHov }
                            TapHandler { onTapped: root.pinned = !root.pinned }
                        }

                        // Close Button
                        Rectangle {
                            width: 28; height: 26; radius: 6
                            color: clsHov.hovered ? Qt.alpha("#ff6b6b", 0.4) : Qt.alpha(root.txt, 0.08)
                            border.width: 1; border.color: Qt.alpha(root.txt, 0.15)
                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                color: root.pal ? root.txt : "#ffffff"
                                font.pixelSize: 11
                            }
                            HoverHandler { id: clsHov }
                            TapHandler { onTapped: root.close() }
                        }
                    }

                    // ---------- SETTINGS DRAWER ----------
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.settingsOpen
                        implicitHeight: setCol.implicitHeight + 16
                        radius: 10
                        color: Qt.rgba(0.08, 0.10, 0.16, 0.95)
                        border.width: 1; border.color: Qt.alpha(root.acc, 0.4)

                        ColumnLayout {
                            id: setCol
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            Text {
                                text: "AI Chat Configuration"
                                color: root.acc
                                font.pixelSize: 12; font.bold: true
                            }

                            // Backend Choice
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Repeater {
                                    model: [["ollama", "Ollama (Local)"], ["api", "Custom API"], ["luna", "Luna Engine"]]
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        height: 26; radius: 5
                                        color: root.backend === modelData[0] ? Qt.alpha(root.acc, 0.35) : Qt.alpha(root.txt, 0.08)
                                        border.width: 1; border.color: root.backend === modelData[0] ? root.acc : Qt.alpha(root.txt, 0.15)
                                        Text {
                                            anchors.centerIn: parent
                                            text: parent.modelData[1]
                                            color: root.pal ? root.txt : "#ffffff"
                                            font.pixelSize: 11
                                            font.bold: root.backend === parent.modelData[0]
                                        }
                                        TapHandler { onTapped: root.backend = parent.modelData[0] }
                                    }
                                }
                            }

                            // Ollama Controls
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: root.backend === "ollama"
                                spacing: 4

                                Text {
                                    text: "Ollama Model:"
                                    color: Qt.alpha(root.txt, 0.7); font.pixelSize: 11
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 28; radius: 5
                                        color: Qt.rgba(0, 0, 0, 0.3)
                                        border.width: 1; border.color: Qt.alpha(root.txt, 0.2)
                                        TextInput {
                                            anchors.fill: parent; anchors.margins: 6
                                            text: root.ollamaModel
                                            color: root.pal ? root.txt : "#ffffff"
                                            font.family: root.pal ? root.pal.mono : "monospace"
                                            font.pixelSize: 11
                                            onTextChanged: root.ollamaModel = text
                                        }
                                    }
                                }
                            }

                            // API Controls
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: root.backend === "api"
                                spacing: 4

                                Text {
                                    text: "API Provider & Key:"
                                    color: Qt.alpha(root.txt, 0.7); font.pixelSize: 11
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    Repeater {
                                        model: [["openrouter", "OpenRouter"], ["openai", "OpenAI"], ["deepseek", "DeepSeek"], ["groq", "Groq"], ["gemini", "Gemini"]]
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            height: 22; radius: 4
                                            color: root.apiProvider === modelData[0] ? Qt.alpha(root.acc, 0.3) : Qt.alpha(root.txt, 0.05)
                                            border.width: 1; border.color: root.apiProvider === modelData[0] ? root.acc : Qt.alpha(root.txt, 0.1)
                                            Text {
                                                anchors.centerIn: parent
                                                text: parent.modelData[1]
                                                color: root.pal ? root.txt : "#ffffff"
                                                font.pixelSize: 10
                                            }
                                            TapHandler {
                                                onTapped: {
                                                    root.apiProvider = parent.modelData[0]
                                                    if (root.apiProvider === "openrouter") {
                                                        root.apiModel = "openai/gpt-4o-mini"
                                                        root.apiEndpoint = "https://openrouter.ai/api/v1/chat/completions"
                                                    } else if (root.apiProvider === "openai") {
                                                        root.apiModel = "gpt-4o-mini"
                                                        root.apiEndpoint = "https://api.openai.com/v1/chat/completions"
                                                    } else if (root.apiProvider === "deepseek") {
                                                        root.apiModel = "deepseek-chat"
                                                        root.apiEndpoint = "https://api.deepseek.com/chat/completions"
                                                    } else if (root.apiProvider === "groq") {
                                                        root.apiModel = "llama-3.3-70b-versatile"
                                                        root.apiEndpoint = "https://api.groq.com/openai/v1/chat/completions"
                                                    } else if (root.apiProvider === "gemini") {
                                                        root.apiModel = "gemini-1.5-flash"
                                                        root.apiEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 28; radius: 5
                                        color: Qt.rgba(0, 0, 0, 0.3)
                                        border.width: 1; border.color: Qt.alpha(root.txt, 0.2)
                                        TextInput {
                                            id: keyInput
                                            anchors.fill: parent; anchors.margins: 6
                                            echoMode: root.keyVisible ? TextInput.Normal : TextInput.Password
                                            text: root.apiKey
                                            color: root.pal ? root.txt : "#ffffff"
                                            font.pixelSize: 11
                                            onTextChanged: root.apiKey = text
                                        }
                                    }
                                    Rectangle {
                                        width: 28; height: 28; radius: 5
                                        color: Qt.alpha(root.txt, 0.1)
                                        Text {
                                            anchors.centerIn: parent
                                            text: root.keyVisible ? "👁" : "🔒"
                                            font.pixelSize: 11
                                        }
                                        TapHandler { onTapped: root.keyVisible = !root.keyVisible }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Text {
                                        text: "Model:"
                                        color: Qt.alpha(root.txt, 0.7); font.pixelSize: 11
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 26; radius: 4
                                        color: Qt.rgba(0, 0, 0, 0.3)
                                        border.width: 1; border.color: Qt.alpha(root.txt, 0.15)
                                        TextInput {
                                            anchors.fill: parent; anchors.margins: 5
                                            text: root.apiModel
                                            color: root.pal ? root.txt : "#ffffff"
                                            font.family: root.pal ? root.pal.mono : "monospace"
                                            font.pixelSize: 11
                                            onTextChanged: root.apiModel = text
                                        }
                                    }
                                }
                            }

                            // Luna Controls
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: root.backend === "luna"
                                spacing: 2
                                Text {
                                    text: "Uses Luna's local reasoning engine via stdio directly in this chatbox."
                                    color: Qt.alpha(root.txt, 0.7); font.pixelSize: 11
                                }
                            }

                            // Save button
                            RowLayout {
                                Layout.fillWidth: true
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 28; radius: 6
                                    color: saveHov.hovered ? Qt.alpha(root.acc, 0.4) : Qt.alpha(root.acc, 0.25)
                                    border.width: 1; border.color: root.acc
                                    Text {
                                        anchors.centerIn: parent
                                        text: "Save & Apply Settings"
                                        color: root.pal ? root.txt : "#ffffff"
                                        font.pixelSize: 11; font.bold: true
                                    }
                                    HoverHandler { id: saveHov }
                                    TapHandler { onTapped: root.saveConfig() }
                                }
                            }
                        }
                    }

                    // ---------- MESSAGES LIST ----------
                    ListView {
                        id: view
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 10
                        model: mm

                        delegate: Item {
                            id: dItem
                            required property var modelData
                            required property string role
                            required property string text
                            required property bool live
                            required property string modelName
                            required property bool bad
                            required property int index

                            readonly property bool isUser: role === "you"
                            width: view.width
                            implicitHeight: bubCol.implicitHeight

                            ColumnLayout {
                                id: bubCol
                                width: view.width
                                spacing: 3

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.alignment: isUser ? Qt.AlignRight : Qt.AlignLeft
                                    spacing: 6

                                    Item { Layout.fillWidth: true; visible: isUser }

                                    Rectangle {
                                        Layout.maximumWidth: view.width * 0.85
                                        implicitWidth: Math.min(view.width * 0.85, msgText.implicitWidth + 24)
                                        implicitHeight: msgText.implicitHeight + 16
                                        radius: 12
                                        color: isUser ? Qt.alpha(root.acc, 0.35)
                                                      : (bad ? Qt.alpha("#ff6b6b", 0.2) : Qt.rgba(0.12, 0.14, 0.20, 0.75))
                                        border.width: 1
                                        border.color: isUser ? root.acc : (bad ? "#ff6b6b" : Qt.alpha(root.txt, 0.12))

                                        Text {
                                            id: msgText
                                            anchors.fill: parent
                                            anchors.margins: 8
                                            text: dItem.text + (dItem.live ? " ▍" : "")
                                            color: bad ? "#ff8888" : (root.pal ? root.txt : "#ffffff")
                                            font.pixelSize: 12
                                            lineHeight: 1.3
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            textFormat: Text.PlainText
                                        }
                                    }

                                    Item { Layout.fillWidth: true; visible: !isUser }
                                }

                                // Copy button / model tag under assistant reply
                                RowLayout {
                                    visible: !isUser && !live && text !== ""
                                    spacing: 6
                                    Text {
                                        text: dItem.modelName
                                        color: Qt.alpha(root.txt, 0.4)
                                        font.pixelSize: 10
                                        font.family: root.pal ? root.pal.mono : "monospace"
                                    }
                                    Rectangle {
                                        width: 44; height: 16; radius: 4
                                        color: cpHov.hovered ? Qt.alpha(root.txt, 0.15) : Qt.alpha(root.txt, 0.05)
                                        Text {
                                            anchors.centerIn: parent
                                            text: "copy"
                                            color: Qt.alpha(root.txt, 0.6)
                                            font.pixelSize: 9
                                        }
                                        HoverHandler { id: cpHov }
                                        TapHandler {
                                            onTapped: Quickshell.execDetached(["wl-copy", dItem.text])
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---------- INPUT BAR ----------
                    Rectangle {
                        Layout.fillWidth: true
                        height: 40; radius: 10
                        color: Qt.rgba(0, 0, 0, 0.35)
                        border.width: 1
                        border.color: root.busy ? root.acc : Qt.alpha(root.txt, 0.2)

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 8

                            Text {
                                text: "✦"
                                color: root.acc
                                font.pixelSize: 13
                            }

                            TextInput {
                                id: input
                                Layout.fillWidth: true
                                color: root.pal ? root.txt : "#ffffff"
                                font.pixelSize: 12
                                selectionColor: root.acc
                                selectedTextColor: "#ffffff"
                                onAccepted: {
                                    if (!root.busy) root.sendPrompt(input.text)
                                }
                                Keys.onEscapePressed: root.close()

                                Text {
                                    anchors.fill: parent
                                    visible: input.text === "" && !input.activeFocus
                                    text: "Ask anything... (or /help for commands)"
                                    color: Qt.alpha(root.pal ? root.txt : "#ffffff", 0.35)
                                    font.pixelSize: 12
                                }
                            }

                            // Send or Stop button
                            Rectangle {
                                width: 28; height: 28; radius: 6
                                color: root.busy ? Qt.alpha("#ff6b6b", 0.3)
                                                 : (sendHov.hovered ? Qt.alpha(root.acc, 0.4) : Qt.alpha(root.acc, 0.2))
                                border.width: 1
                                border.color: root.busy ? "#ff6b6b" : root.acc

                                Text {
                                    anchors.centerIn: parent
                                    text: root.busy ? "⏹" : "➤"
                                    color: root.busy ? "#ff8888" : (root.pal ? root.txt : "#ffffff")
                                    font.pixelSize: 11
                                }
                                HoverHandler { id: sendHov }
                                TapHandler {
                                    onTapped: {
                                        if (root.busy) root.stopChat()
                                        else root.sendPrompt(input.text)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
