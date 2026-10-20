import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Screenshot panel.   Super + Ctrl + S, >screenshot in the launcher, `halcyon screenshot`, or the IPC call `screenshot`.
// A small panel on the side of the screen, in the look of the new-note panel: pick what to capture (Region, Window or Full screen)
// and what happens to it (Copy, Save, or Both). The panel leaves first so it is not in the picture, then
// scripts/halcyon-shot.py does the capture. R / W / F pick the target, C / S / B the action, Esc closes.
//
// It sits NEXT TO the existing shortcuts: Super + Shift + S (scripts/screenshot-area.sh), Print and Super + Shift + Print are not
// touched. It starts no process of its own; the script runs once per capture and exits.
Scope {
    id: root
    property var pal
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property var opt: ({})                  // the island's settings: the stars follow the Desktop builder's direction, speed and colour
    property string spot: "tl"
    property bool open: false

    property string action: "both"                // copy | save | both | text: what the panel opens with (remembered by the script)
    property var has: ({ grim: true, slurp: true, "wl-copy": true, wayfreeze: true, hyprctl: true, tesseract: true })
    property string dir: ""

    readonly property bool panelRight: spot.charAt(1) !== "r"
    readonly property bool panelBottom: spot.charAt(0) === "b"
    readonly property string script: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-shot.py"

    function show() { open = true; confProc.running = true }
    function hide() { open = false }
    function close() { hide() }
    function toggle() { if (open) hide(); else show() }

    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() }
    Timer { id: lingerT; interval: 340; onTriggered: root.linger = false }

    Process {
        id: confProc
        command: ["python3", root.script, "conf"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text)
                    if (d.action === "copy" || d.action === "save" || d.action === "both" || d.action === "text") root.action = d.action
                    if (d.has) root.has = d.has
                    root.dir = d.dir || ""
                } catch (e) { /* keeps what it had */ }
            }
        }
    }

    function setAction(a) {
        if (a === action) return
        action = a
        Quickshell.execDetached(["python3", root.script, "set", "action", a])      // remembered for the next time
    }

    // what each target needs; a missing tool greys it out instead of failing after the click
    function canDo(mode) {
        if (!has.grim) return false
        if (mode !== "full" && !has.slurp) return false
        if (action !== "save" && !has["wl-copy"]) return false
        if (action === "text" && !has.tesseract) return false
        return true
    }
    readonly property string missingText: {
        var m = []
        if (!has.grim) m.push("grim")
        if (!has.slurp) m.push("slurp")
        if (!has["wl-copy"]) m.push("wl-clipboard")
        if (action === "text" && !has.tesseract) m.push("tesseract (and tesseract-data-eng)")
        return m.length ? "Missing: " + m.join(", ") : ""
    }

    // the panel leaves, then (after its slide-out) the capture starts: the panel must not be in the picture
    property string pendingMode: ""
    function capture(mode) {
        if (!canDo(mode)) return
        pendingMode = mode
        open = false
        shotT.restart()
    }
    Timer {
        id: shotT
        interval: 420
        onTriggered: {
            var m = root.pendingMode
            root.pendingMode = ""
            if (m !== "") Quickshell.execDetached(["python3", root.script, m, root.action])
        }
    }

    readonly property var targets: [
        { k: "region", t: "Region", d: "Drag a rectangle", key: "R" },
        { k: "window", t: "Window", d: "Click a window", key: "W" },
        { k: "full", t: "Full screen", d: "The screen you are on", key: "F" }
    ]

    LazyLoader {
        active: root.open || root.linger
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-shot"
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
                Component.onCompleted: { ready = true; Qt.callLater(function () { keys.forceActiveFocus() }) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: 520
                    height: col.implicitHeight + 40
                    radius: root.pal.rXl
                    opacityBody: root.pal.solid ? 1 : 0.90
                    border.color: Qt.alpha(root.pal.accent, 0.40)
                    opacity: qp.reveal
                    x: root.panelRight ? qp.width - width - 22 + (1 - qp.reveal) * width * 0.4
                                       : 22 - (1 - qp.reveal) * width * 0.4
                    y: root.panelBottom ? qp.height - height - root.pal.boxEdge : root.pal.boxTop
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    NoteStars {
                        anchors.fill: parent
                        anchors.margins: 1
                        pal: root.pal
                        opt: root.opt
                        running: root.stars && root.open
                        count: 30
                    }

                    // keys only; nothing here takes text
                    Item {
                        id: keys
                        anchors.fill: parent
                        focus: true
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true }
                            else if (e.key === Qt.Key_R) { root.capture("region"); e.accepted = true }
                            else if (e.key === Qt.Key_W) { root.capture("window"); e.accepted = true }
                            else if (e.key === Qt.Key_F) { root.capture("full"); e.accepted = true }
                            else if (e.key === Qt.Key_C) { root.setAction("copy"); e.accepted = true }
                            else if (e.key === Qt.Key_S) { root.setAction("save"); e.accepted = true }
                            else if (e.key === Qt.Key_B) { root.setAction("both"); e.accepted = true }
                            else if (e.key === Qt.Key_T) { root.setAction("text"); e.accepted = true }
                        }
                    }

                    ColumnLayout {
                        id: col
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
                        spacing: 14

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Rectangle { width: 8; height: 8; radius: 4; color: root.pal.accent }
                            Text {
                                text: "Screenshot"
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tTitle
                                font.weight: Font.DemiBold
                            }
                            Item { Layout.fillWidth: true }
                            RoundBtn {
                                pal: root.pal
                                size: 28
                                glyph: String.fromCodePoint(0xF0156)
                                onClicked: root.hide()
                            }
                        }

                        // what to capture
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Repeater {
                                model: root.targets
                                delegate: Rectangle {
                                    id: card
                                    required property var modelData
                                    readonly property bool ok: root.canDo(modelData.k)
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    Layout.preferredHeight: 92
                                    radius: root.pal.rMd
                                    opacity: ok ? 1 : 0.4
                                    color: cma.containsMouse && ok ? Qt.alpha(root.pal.accent, 0.16) : Qt.alpha(root.pal.surface, 0.7)
                                    border.width: 1
                                    border.color: cma.containsMouse && ok ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
                                    scale: cma.pressed && ok ? 0.97 : 1
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
                                    Behavior on scale { NumberAnimation { duration: root.pal.dFast } }

                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 6
                                        // a little picture of the target, drawn from rectangles (no icon font needed)
                                        Item {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 38; height: 28
                                            Rectangle {              // region: a frame with a smaller selection inside
                                                visible: card.modelData.k === "region"
                                                anchors.fill: parent
                                                radius: 4
                                                color: "transparent"
                                                border.width: 1
                                                border.color: Qt.alpha(root.pal.muted, 0.6)
                                                Rectangle {
                                                    x: 7; y: 5; width: 20; height: 16
                                                    radius: 2
                                                    color: Qt.alpha(root.pal.accent, 0.22)
                                                    border.width: 2
                                                    border.color: root.pal.accent
                                                }
                                            }
                                            Rectangle {              // window: a frame with a title bar
                                                visible: card.modelData.k === "window"
                                                anchors.fill: parent
                                                anchors.margins: 3
                                                radius: 4
                                                color: Qt.alpha(root.pal.accent, 0.12)
                                                border.width: 2
                                                border.color: root.pal.accent
                                                Rectangle {
                                                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 2 }
                                                    height: 5
                                                    radius: 2
                                                    color: root.pal.accent
                                                }
                                            }
                                            Rectangle {              // full screen: the whole frame filled
                                                visible: card.modelData.k === "full"
                                                anchors.fill: parent
                                                radius: 4
                                                color: Qt.alpha(root.pal.accent, 0.28)
                                                border.width: 2
                                                border.color: root.pal.accent
                                            }
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: card.modelData.t
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                            font.weight: Font.Medium
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: card.modelData.d
                                            color: root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: 10
                                        }
                                    }
                                    Text {
                                        anchors { right: parent.right; top: parent.top; margins: 8 }
                                        text: card.modelData.key
                                        color: Qt.alpha(root.pal.muted, 0.7)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: 10
                                    }
                                    MouseArea {
                                        id: cma
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: card.ok
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.capture(card.modelData.k)
                                    }
                                }
                            }
                        }

                        // what happens to it
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text {
                                text: "Then"
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody
                            }
                            SegSwitch {
                                pal: root.pal
                                current: root.action
                                options: [{ k: "copy", t: "Copy" }, { k: "save", t: "Save" }, { k: "both", t: "Both" }, { k: "text", t: "Text" }]
                                onPicked: k => root.setAction(k)
                            }
                            Item { Layout.fillWidth: true }
                        }

                        Text {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: root.missingText !== "" ? root.missingText + " (install it and this lights up)"
                                : (root.action === "copy" ? "Goes on the clipboard only. No file is made."
                                : (root.action === "text" ? "Reads the words in the picture and copies the text. No picture is kept."
                                : (root.action === "save" ? "Saved to " + root.dir.replace(Quickshell.env("HOME"), "~") + ". The clipboard is not touched."
                                : "Saved to " + root.dir.replace(Quickshell.env("HOME"), "~") + " and copied.")))
                            color: root.missingText !== "" ? root.pal.warn : Qt.alpha(root.pal.muted, 0.9)
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                        }

                        Text {
                            text: "R  W  F  pick   \u00b7   C  S  B  T  copy / save / both / text   \u00b7   Esc closes   \u00b7   Super + Shift + S still drags a region at once"
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: Qt.alpha(root.pal.muted, 0.85)
                            font.family: root.pal.uiFont
                            font.pixelSize: 10
                        }
                    }
                }
            }
        }
    }
}
