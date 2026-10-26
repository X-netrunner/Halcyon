import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Luna.   >luna in the launcher (also `island command luna`, the IPC call `luna`, `halcyon luna`).
// Your conversations with Luna, the local assistant (install.sh --luna), one saved session each. Open an old one and carry on where it
// stopped: Luna gets that conversation's own memory back. While she works you see what she is doing (the tools she runs) and, if you
// want, her reasoning. Everything goes through scripts/halcyon-luna.py (sessions in ~/.local/share/halcyon/luna) and her `--stdio` mode;
// nothing leaves the machine. Nothing runs while the window is closed (LazyLoader, no timers, no processes), except an answer that was
// still being written: it finishes and is there when you come back.
Scope {
    id: root
    property var pal
    property bool open: false
    signal focusRequested(string what)      // the window's own field takes the keyboard (ids inside the LazyLoader are not reachable)
    property bool consoleOpen: false        // kept for the same wiring as the other centers (shell.qml)

    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-luna.py"

    // ---- state
    property var sessions: []               // { id, title, updated, count, preview }
    property string cur: ""                 // the open session ("" = a new chat, made when you send the first message)
    property var msgs: []                   // { role: "you" | "luna", text, tools: [], model, secs, think, live, bad }
    property bool ok: true                  // Luna installed and the AI on
    property string problem: ""
    property string status: ""              // what she is doing right now
    property int secs: 0
    property string confirmDel: ""
    property string renaming: ""
    property string note: ""
    readonly property bool busy: chatProc.running || newProc.running
    Timer { interval: 1000; repeat: true; running: root.busy; onTriggered: root.secs++ }

    function show() {
        open = true
        note = ""
        check()
        reload(true)
    }
    function hide() { open = false; confirmDel = ""; renaming = "" }
    function toggle() { if (open) hide(); else show() }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }
    function flash(t) { note = t; noteT.restart() }
    Timer { id: noteT; interval: 5000; onTriggered: root.note = "" }
    function shortName(n) { n = String(n || ""); n = n.replace(/:latest$/, ""); var i = n.lastIndexOf("/"); return i >= 0 ? n.substring(i + 1) : n }
    function ago(ts) {
        var d = Math.max(0, Date.now() / 1000 - ts)
        if (d < 90) return "now"
        if (d < 5400) return Math.round(d / 60) + " min"
        if (d < 129600) return Math.round(d / 3600) + " h"
        return Math.round(d / 86400) + " d"
    }

    // the model's text -> rich text: **bold**, `code`, lists, headings (the same small subset the Study Center draws)
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function inline(l) {
        return l.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<i>$2</i>")
                .replace(/`([^`]+)`/g, "<span style=\"font-family:'" + pal.mono + "'\">$1</span>")
    }
    function fmt(t) {
        var lines = esc(t).split("\n"), out = [], list = ""
        function close() { if (list !== "") { out.push("</" + list + ">"); list = "" } }
        function opn(kind) { if (list !== kind) { close(); out.push("<" + kind + " style=\"margin-top:2px;margin-bottom:6px;margin-left:-14px\">"); list = kind } }
        var code = false
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]
            if (/^\s*```/.test(l)) { close(); code = !code; out.push(code ? "<pre style=\"font-family:'" + pal.mono + "'\">" : "</pre>"); continue }
            if (code) { out.push(l + "\n"); continue }
            var h = /^\s*#{1,4}\s+(.*)$/.exec(l), bu = /^\s*[-*•]\s+(.*)$/.exec(l), nu = /^\s*\d+[.)]\s+(.*)$/.exec(l)
            if (bu) { opn("ul"); out.push("<li>" + inline(bu[1]) + "</li>"); continue }
            if (nu) { opn("ol"); out.push("<li>" + inline(nu[1]) + "</li>"); continue }
            close()
            if (l.trim() === "") { out.push("<div style=\"font-size:6px\">&nbsp;</div>"); continue }
            if (h) out.push("<div style=\"margin-top:6px\"><b>" + inline(h[1]) + "</b></div>")
            else out.push("<div>" + inline(l) + "</div>")
        }
        if (code) out.push("</pre>")
        close()
        return out.join("")
    }

    // ---- is Luna there
    function check() { if (!statusProc.running) statusProc.running = true }
    Process {
        id: statusProc
        command: ["python3", root.script, "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var o = JSON.parse(text)
                    root.ok = o.ok === true
                    root.problem = o.installed === false ? "Luna is not installed. Run ./install.sh --luna, then open this again." : (o.blocked || "")
                } catch (e) { root.ok = false; root.problem = "No answer from halcyon-luna.py (is python3 there?)" }
            }
        }
    }

    // ---- the sessions
    function reload(openLast) {
        listProc.openLast = openLast === true
        if (!listProc.running) listProc.running = true
    }
    Process {
        id: listProc
        property bool openLast: false
        command: ["python3", root.script, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.sessions = JSON.parse(text).sessions || []
                    // opening the window carries on with the newest session, unless one is already open or being written
                    if (listProc.openLast && root.cur === "" && root.msgs.length === 0 && !root.busy && root.sessions.length > 0)
                        root.openSession(root.sessions[0].id)
                } catch (e) {}
            }
        }
    }
    function openSession(id) {
        if (busy || id === cur) return
        cur = id; msgs = []; confirmDel = ""; renaming = ""
        showProc.command = ["python3", script, "show", id, "--json"]
        showProc.running = true
        Qt.callLater(function () { root.focusRequested("ask") })
    }
    Process {
        id: showProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var t = JSON.parse(text).turns || [], m = []
                    for (var i = 0; i < t.length; i++)
                        m.push({ role: t[i].role, text: t[i].text || "", tools: t[i].tools || [], model: t[i].model || "", secs: t[i].secs || 0,
                                 think: t[i].thinking || "", live: false, bad: t[i].bad === true })
                    root.msgs = m
                } catch (e) {}
            }
        }
    }
    function newChat() { if (busy) return; cur = ""; msgs = []; confirmDel = ""; renaming = ""; Qt.callLater(function () { root.focusRequested("ask") }) }
    function removeSession(id) {
        confirmDel = ""
        Quickshell.execDetached(["python3", script, "delete", id])
        sessions = sessions.filter(function (s) { return s.id !== id })
        if (cur === id) { cur = ""; msgs = [] }
        relT.restart()
    }
    function renameSession(id, title) {
        renaming = ""
        title = String(title || "").trim()
        if (title === "") return
        Quickshell.execDetached(["python3", script, "rename", id, title])
        sessions = sessions.map(function (s) { if (s.id === id) { var c = {}; for (var k in s) c[k] = s[k]; c.title = title; return c } return s })
    }
    Timer { id: relT; interval: 400; onTriggered: root.reload(false) }

    // ---- a turn
    function send(q) {
        q = String(q || "").trim()
        if (q === "" || busy) return
        if (!ok) { flash(problem !== "" ? problem : "Luna is not available."); return }
        msgs = msgs.concat([{ role: "you", text: q }, { role: "luna", text: "", tools: [], model: "", secs: 0, think: "", live: true, bad: false }])
        status = "thinking"
        secs = 0
        if (cur === "") { newProc.question = q; newProc.running = true }
        else startChat(q)
    }
    function startChat(q) {
        chatProc.command = ["python3", script, "chat", cur, "--json", "--", q]
        chatProc.running = true
    }
    function stop() { if (chatProc.running) chatProc.signal(15) }
    Process {
        id: newProc
        property string question: ""
        command: ["python3", root.script, "new", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.cur = JSON.parse(text).id; root.startChat(newProc.question) }
                catch (e) { root.patchLast(function (c) { c.text = "Could not start a chat."; c.bad = true; c.live = false }) }
            }
        }
    }
    function patchLast(f) {
        var m = msgs.slice(), l = m.length - 1
        if (l < 0 || m[l].role !== "luna") return
        var c = {}
        for (var k in m[l]) c[k] = m[l][k]
        f(c)
        m[l] = c
        msgs = m
    }
    Process {
        id: chatProc
        stdout: SplitParser {
            onRead: d => {
                var o = null
                try { o = JSON.parse(d) } catch (e) { return }
                if (o.type === "activity") {
                    if (o.kind === "tool_start") {
                        root.status = "running " + o.name + (o.summary && o.summary !== o.name ? ": " + o.summary : "")
                        root.patchLast(function (c) { c.tools = c.tools.concat([{ name: o.name, summary: o.summary || "" }]) })
                    } else if (o.kind === "step") root.status = "thinking"
                } else if (o.type === "thinking") root.patchLast(function (c) { c.think += o.delta })
                else if (o.type === "reply") root.patchLast(function (c) { c.text = o.text; c.model = o.model || ""; c.secs = o.secs || 0; c.live = false })
                else if (o.type === "error") root.patchLast(function (c) { c.text = o.error; c.bad = true; c.live = false })
            }
        }
        onExited: {
            root.status = ""
            root.patchLast(function (c) { if (c.live) { c.live = false; if (c.text === "") { c.text = "Stopped."; c.bad = true } } })
            root.check()
            root.reload(false)
        }
    }
    function copy(t) { Quickshell.execDetached(["wl-copy", "--", t]); flash("Copied") }
    function saveNote(t) {
        Quickshell.execDetached(["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-notes.py", "add", t])
        flash("Saved as a note (Super + N)")
    }

    // ---------------------------------------------------------------- small pieces
    component LinkBtn: Rectangle {
        id: lb
        property string label: ""
        property string glyph: ""
        signal clicked()
        implicitWidth: lbRow.implicitWidth + 20
        implicitHeight: 30
        radius: 15
        color: lbMa.containsMouse ? Qt.alpha(root.pal.text, 0.07) : "transparent"
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Row {
            id: lbRow
            anchors.centerIn: parent
            spacing: 6
            Text { visible: lb.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: lb.glyph; color: lbMa.containsMouse ? root.pal.text : root.pal.muted; font.family: root.pal.font; font.pixelSize: 14 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: lb.label; color: lbMa.containsMouse ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
        }
        MouseArea { id: lbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: lb.clicked() }
    }
    component PrimaryBtn: Rectangle {
        id: pb
        property string label: ""
        property string glyph: ""
        signal clicked()
        implicitWidth: pbRow.implicitWidth + 30
        implicitHeight: 36
        radius: height / 2
        color: pbMa.containsMouse ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent
        scale: pbMa.pressed ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 8
            Text { visible: pb.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: pb.glyph; color: root.pal.bg; font.family: root.pal.font; font.pixelSize: 15 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: pb.label; color: root.pal.bg; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
        }
        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked() }
    }
    component Working: Row {
        id: wk
        property string text: ""
        spacing: 10
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            Repeater {
                model: 3
                delegate: Rectangle {
                    required property int index
                    width: 6; height: 6; radius: 3
                    color: root.pal.accent
                    opacity: 0.25 + 0.75 * Math.max(0, Math.sin((dots.t - index * 0.18) * Math.PI * 2))
                }
            }
        }
        Item {
            id: dots
            property real t: 0
            NumberAnimation on t { from: 0; to: 1; duration: 1300; loops: Animation.Infinite; running: wk.visible && root.open }
        }
        Text { anchors.verticalCenter: parent.verticalCenter; text: wk.text; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; elide: Text.ElideRight; width: Math.min(implicitWidth, 520) }
    }

    // ================================================================ the window
    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-luna"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            MouseArea { anchors.fill: parent; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { askIn.forceActiveFocus() }) }
                Keys.onEscapePressed: root.hide()
                Connections {
                    target: root
                    function onFocusRequested(what) { askIn.forceActiveFocus() }
                }

                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: Math.min(1100, qp.width - 80)
                    height: Math.min(740, qp.height - 80)
                    radius: root.pal.rXl
                    opacityBody: 0.97
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                    anchors.centerIn: parent
                    opacity: qp.reveal
                    scale: 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== the sessions
                        Item {
                            Layout.preferredWidth: 270
                            Layout.fillHeight: true
                            Item {
                                anchors.fill: parent
                                anchors.margins: 1
                                clip: true
                                Rectangle {
                                    width: parent.width + root.pal.rXl
                                    height: parent.height
                                    radius: root.pal.rXl
                                    color: root.pal.box(Qt.alpha(root.pal.surface, 0.35))
                                }
                            }
                            Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right; topMargin: 24; bottomMargin: 24 } width: 1; color: root.pal.lineSoft }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 20
                                anchors.rightMargin: 21
                                spacing: 14

                                Text {
                                    text: "Luna"
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tTitle + 2
                                    font.weight: Font.DemiBold
                                }
                                PrimaryBtn {
                                    Layout.fillWidth: true
                                    label: "New chat"
                                    glyph: String.fromCodePoint(0xF0415)
                                    onClicked: root.newChat()
                                }

                                ListView {
                                    id: slist
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 2
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.sessions
                                    delegate: Rectangle {
                                        id: srow
                                        required property var modelData
                                        readonly property bool active: modelData.id === root.cur
                                        readonly property bool editing: root.renaming === modelData.id
                                        width: slist.width
                                        height: 52
                                        radius: 14
                                        color: active ? Qt.alpha(root.pal.accent, 0.16) : (rowMa.containsMouse ? Qt.alpha(root.pal.text, 0.06) : "transparent")
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openSession(srow.modelData.id) }
                                        Column {
                                            anchors { left: parent.left; right: acts.left; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 6 }
                                            spacing: 3
                                            Text {
                                                visible: !srow.editing
                                                width: parent.width
                                                text: srow.modelData.title
                                                elide: Text.ElideRight
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                font.weight: srow.active ? Font.DemiBold : Font.Normal
                                            }
                                            TextInput {
                                                id: renIn
                                                visible: srow.editing
                                                width: parent.width
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                selectByMouse: true
                                                onVisibleChanged: if (visible) { text = srow.modelData.title; forceActiveFocus(); selectAll() }
                                                Keys.onReturnPressed: root.renameSession(srow.modelData.id, text)
                                                Keys.onEscapePressed: root.renaming = ""
                                            }
                                            Text {
                                                width: parent.width
                                                text: root.ago(srow.modelData.updated) + (srow.modelData.preview ? "  ·  " + srow.modelData.preview : "")
                                                elide: Text.ElideRight
                                                color: root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tCap
                                            }
                                        }
                                        Row {
                                            id: acts
                                            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 8 }
                                            spacing: 2
                                            visible: rowMa.containsMouse || actMa1.containsMouse || actMa2.containsMouse || root.confirmDel === srow.modelData.id
                                            Rectangle {
                                                width: 26; height: 26; radius: 13
                                                visible: root.confirmDel !== srow.modelData.id
                                                color: actMa1.containsMouse ? Qt.alpha(root.pal.text, 0.1) : "transparent"
                                                Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF03EB); color: root.pal.muted; font.family: root.pal.font; font.pixelSize: 13 }
                                                MouseArea { id: actMa1; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.renaming = srow.modelData.id }
                                            }
                                            Rectangle {
                                                width: root.confirmDel === srow.modelData.id ? 62 : 26; height: 26; radius: 13
                                                color: root.confirmDel === srow.modelData.id ? Qt.alpha(root.pal.bad, 0.2) : (actMa2.containsMouse ? Qt.alpha(root.pal.text, 0.1) : "transparent")
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.confirmDel === srow.modelData.id ? "Delete?" : String.fromCodePoint(0xF01B4)
                                                    color: root.confirmDel === srow.modelData.id ? root.pal.bad : root.pal.muted
                                                    font.family: root.confirmDel === srow.modelData.id ? root.pal.uiFont : root.pal.font
                                                    font.pixelSize: root.confirmDel === srow.modelData.id ? root.pal.tCap : 13
                                                }
                                                MouseArea {
                                                    id: actMa2
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: { if (root.confirmDel === srow.modelData.id) root.removeSession(srow.modelData.id); else root.confirmDel = srow.modelData.id }
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.sessions.length === 0
                                        text: "No chats yet"
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                    }
                                }
                            }
                        }

                        // ======================== the chat
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: root.cur === "" ? "New chat" : (function () { for (var i = 0; i < root.sessions.length; i++) if (root.sessions[i].id === root.cur) return root.sessions[i].title; return "Chat" })()
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tTitle
                                        font.weight: Font.DemiBold
                                    }
                                    Text {
                                        visible: root.note !== ""
                                        text: root.note
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap + 1
                                    }
                                    LinkBtn { label: "Close"; glyph: String.fromCodePoint(0xF0156); onClicked: root.hide() }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: !root.ok && root.problem !== ""
                                    implicitHeight: probT.implicitHeight + 24
                                    radius: 14
                                    color: Qt.alpha(root.pal.warn, 0.14)
                                    Text { id: probT; x: 16; y: 12; width: parent.width - 32; wrapMode: Text.Wrap; text: root.problem; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true

                                    Column {
                                        anchors.centerIn: parent
                                        visible: root.msgs.length === 0
                                        spacing: 8
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Ask Luna anything"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Chats are saved. Open one on the left to carry on."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    }

                                    ListView {
                                        id: chat
                                        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: askBar.top; bottomMargin: 14 }
                                        visible: root.msgs.length > 0
                                        clip: true
                                        spacing: 18
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.msgs
                                        onCountChanged: Qt.callLater(function () { chat.positionViewAtEnd() })
                                        onContentHeightChanged: if (root.busy) positionViewAtEnd()
                                        delegate: Item {
                                            id: mrow
                                            required property var modelData
                                            required property int index
                                            readonly property bool you: modelData.role === "you"
                                            property bool showThink: false
                                            property bool showTools: false
                                            width: chat.width
                                            height: you ? youBox.height : aiCol.height
                                            Rectangle {
                                                id: youBox
                                                visible: mrow.you
                                                anchors.right: parent.right
                                                width: Math.min(youT.implicitWidth + 32, parent.width * 0.75)
                                                height: youT.height + 20
                                                radius: 18
                                                color: Qt.alpha(root.pal.accent, 0.13)
                                                Text { id: youT; x: 16; y: 10; width: parent.width - 32; wrapMode: Text.Wrap; text: mrow.modelData.text; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; lineHeight: 1.3 }
                                            }
                                            Column {
                                                id: aiCol
                                                visible: !mrow.you
                                                width: Math.min(parent.width, 780)
                                                spacing: 10
                                                Working {
                                                    visible: mrow.modelData.live === true && mrow.modelData.text === ""
                                                    text: root.status + "  ·  " + root.secs + " s"
                                                }
                                                Row {
                                                    spacing: 14
                                                    visible: mrow.modelData.text !== ""
                                                    Rectangle { width: 2; height: aiT.height; radius: 1; color: mrow.modelData.bad ? Qt.alpha(root.pal.bad, 0.6) : Qt.alpha(root.pal.accent, 0.45) }
                                                    Text {
                                                        id: aiT
                                                        width: aiCol.width - 16
                                                        wrapMode: Text.Wrap
                                                        textFormat: Text.RichText
                                                        text: root.fmt(mrow.modelData.text)
                                                        color: mrow.modelData.bad ? root.pal.bad : root.pal.text
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tBody + 1
                                                        lineHeight: 1.35
                                                    }
                                                }
                                                Row {
                                                    leftPadding: 16
                                                    spacing: 4
                                                    visible: !mrow.modelData.live && !mrow.modelData.bad
                                                    Text {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        visible: (mrow.modelData.model || "") !== ""
                                                        text: root.shortName(mrow.modelData.model) + (mrow.modelData.secs ? "  ·  " + mrow.modelData.secs + " s" : "")
                                                        color: Qt.alpha(root.pal.muted, 0.8)
                                                        font.family: root.pal.uiFont
                                                        font.pixelSize: root.pal.tCap
                                                        rightPadding: 6
                                                    }
                                                    LinkBtn { visible: (mrow.modelData.tools || []).length > 0; label: (mrow.showTools ? "Hide " : "") + (mrow.modelData.tools || []).length + (((mrow.modelData.tools || []).length === 1) ? " tool used" : " tools used"); onClicked: mrow.showTools = !mrow.showTools }
                                                    LinkBtn { visible: (mrow.modelData.think || "") !== ""; label: mrow.showThink ? "Hide the reasoning" : "Show the reasoning"; onClicked: mrow.showThink = !mrow.showThink }
                                                    LinkBtn { label: "Copy"; glyph: String.fromCodePoint(0xF018F); onClicked: root.copy(mrow.modelData.text) }
                                                    LinkBtn { label: "Save as note"; glyph: String.fromCodePoint(0xF0F8C); onClicked: root.saveNote(mrow.modelData.text) }
                                                }
                                                Column {
                                                    visible: mrow.showTools
                                                    width: parent.width
                                                    leftPadding: 16
                                                    spacing: 3
                                                    Repeater {
                                                        model: mrow.modelData.tools || []
                                                        delegate: Text {
                                                            required property var modelData
                                                            width: aiCol.width - 20
                                                            elide: Text.ElideRight
                                                            text: modelData.name + (modelData.summary && modelData.summary !== modelData.name ? ": " + modelData.summary : "")
                                                            color: root.pal.muted
                                                            font.family: root.pal.mono
                                                            font.pixelSize: root.pal.tCap
                                                        }
                                                    }
                                                }
                                                Text {
                                                    visible: mrow.showThink
                                                    width: parent.width
                                                    leftPadding: 16
                                                    wrapMode: Text.Wrap
                                                    text: mrow.modelData.think || ""
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap + 1
                                                    lineHeight: 1.3
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: askBar
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                        height: Math.min(160, Math.max(50, askIn.contentHeight + 28))
                                        radius: 25
                                        color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.75))
                                        border.width: root.pal.zen && !askIn.activeFocus ? 0 : 1
                                        border.color: askIn.activeFocus ? root.pal.lineFocus : root.pal.line
                                        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                                        TextEdit {
                                            id: askIn
                                            anchors { left: parent.left; right: sendBtn.left; verticalCenter: parent.verticalCenter; leftMargin: 20; rightMargin: 10 }
                                            wrapMode: TextEdit.Wrap
                                            color: root.pal.text
                                            selectionColor: Qt.alpha(root.pal.accent, 0.4)
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody + 1
                                            Keys.onPressed: e => {
                                                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                                    if (!root.busy && text.trim() !== "") { root.send(text); text = "" }
                                                    e.accepted = true
                                                } else if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: askIn.text.length === 0
                                                text: "Message Luna…"
                                                color: root.pal.muted
                                                font: askIn.font
                                            }
                                        }
                                        RoundBtn {
                                            id: sendBtn
                                            anchors { right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                                            pal: root.pal
                                            size: 34
                                            primary: true
                                            glyph: String.fromCodePoint(root.busy ? 0xF04DB : 0xF005D)
                                            enabledBtn: root.busy || askIn.text.trim() !== ""
                                            onClicked: { if (root.busy) root.stop(); else if (askIn.text.trim() !== "") { root.send(askIn.text); askIn.text = "" } }
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
}
