import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Every command of the top-left console as a tree, same look as the SUPER+/ shortcuts tree: the root splits into
// branches (Sysmode, Hotspot, Halcyon windows, Console), each branch has its commands.
//   Type to search.   Click a command to put it in the console (it is not run: press Enter there).   Esc closes.
// Open: SUPER+ALT+/, or: quickshell ipc -p ~/.config/Halcyon/quickshell/island call island cmdlist
// Only exists when sysmode is set up (/usr/local/bin/sysmode): without it the key is not bound (hyprland/keybinds.lua),
// the shortcut is hidden in the shortcuts tree, and the IPC call does nothing.
Scope {
    id: root
    property var pal
    property bool stars: true             // constellations in this box (Settings > Constellations)
    property int flyCount: 0              // moving stars drifting in this box (0 = none): set by shell.qml from Resource use
    property int flyLoop: 150000          // ms for one slow pass of them
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool open: false
    property bool consoleOpen: false
    property bool available: false        // sysmode is installed
    property string query: ""

    readonly property string sysmodeBin: "/usr/local/bin/sysmode"

    // a command was clicked: shell.qml closes this tree and puts the text in the console
    signal use(string text)

    function check() { probe.running = false; probe.running = true }
    function show() { if (available) { query = ""; open = true } }
    function hide() { open = false }
    function toggle() { if (open) hide(); else show() }

    Process {
        id: probe
        command: ["test", "-x", root.sysmodeBin]
        onExited: (code, status) => { root.available = (code === 0); if (!root.available) root.open = false }
    }
    Component.onCompleted: check()

    // ---------------------------------------------------------------- the commands
    // put = what goes into the console when you click it; sudo = the console asks for your password
    readonly property var groups: [
        { title: "Sysmode  (sm = sysmode)", items: [
            { cmd: "secure", put: "sysmode secure", sudo: true, desc: "daily hardening: firewall, no forwarding, compilers for root only" },
            { cmd: "stealth", put: "sysmode stealth", sudo: true, desc: "decoy lab: honeypot, IDS, random hostname and MACs" },
            { cmd: "relaxed", put: "sysmode relaxed", sudo: true, desc: "training lab: forwarding on, restrictions lifted (old name: cyber)" },
            { cmd: "lockdown", put: "sysmode lockdown", sudo: true, desc: "fortress: SSH off, kernel locks, a reboot to leave it" },
            { cmd: "status", put: "sysmode status", sudo: false, desc: "the active profile and the key kernel numbers" },
            { cmd: "verify", put: "sysmode verify", sudo: false, desc: "audit the profile against the live system (check does the same)" },
            { cmd: "logs", put: "sysmode logs", sudo: false, desc: "banned IPs and recent honeypot / IDS alerts" },
            { cmd: "dossier [ip]", put: "sysmode dossier ", sudo: false, desc: "everything known about one attacker" },
            { cmd: "doctor", put: "sysmode doctor", sudo: false, desc: "missing packages, with install hints" }
        ] },
        { title: "Hotspot", items: [
            { cmd: "hotspot-on", put: "hotspot-on", sudo: false, desc: "start the lab Wi-Fi hotspot (BlackHatLab)" },
            { cmd: "hotspot-off", put: "hotspot-off", sudo: false, desc: "stop it and go back to normal Wi-Fi" }
        ] },
        { title: "Halcyon windows", items: [
            { cmd: "halcyon launcher", put: "halcyon launcher", sudo: false, desc: "app menu and commands" },
            { cmd: "halcyon settings", put: "halcyon settings", sudo: false, desc: "Settings" },
            { cmd: "bar-builder", put: "bar-builder", sudo: false, desc: "bar builder" },
            { cmd: "desktop-builder", put: "desktop-builder", sudo: false, desc: "desktop builder: widget places & box activation zones" },
            { cmd: "widget-builder", put: "widget-builder", sudo: false, desc: "widget builder: layout & look of each desktop widget" },
            { cmd: "desktop-edit", put: "desktop-edit", sudo: false, desc: "drag your widgets around right on the desktop" },
            { cmd: "halcyon bar", put: "halcyon bar", sudo: false, desc: "top bar on / off (toggle)" },
            { cmd: "notification-builder", put: "notification-builder", sudo: false, desc: "notification box builder" },
            { cmd: "wallpaper-gallery", put: "wallpaper-gallery", sudo: false, desc: "wallpaper gallery" },
            { cmd: "startup-view", put: "startup-view", sudo: false, desc: "startup and processes" },
            { cmd: "halcyon notifications", put: "halcyon notifications", sudo: false, desc: "notification centre" },
            { cmd: "halcyon clear-notifications", put: "halcyon clear-notifications", sudo: false, desc: "remove all notifications" },
            { cmd: "halcyon cheatsheet", put: "halcyon cheatsheet", sudo: false, desc: "shortcuts tree" },
            { cmd: "halcyon power-menu", put: "halcyon power-menu", sudo: false, desc: "power menu" },
            { cmd: "halcyon overview", put: "halcyon overview", sudo: false, desc: "workspace tree" },
            { cmd: "halcyon dnd", put: "halcyon dnd", sudo: false, desc: "do not disturb (toggle)" },
            { cmd: "halcyon gaming-mode", put: "halcyon gaming-mode", sudo: false, desc: "gaming mode (toggle)" },
            { cmd: "halcyon caffeine", put: "halcyon caffeine", sudo: false, desc: "keep the screen awake (toggle)" },
            { cmd: "halcyon theme", put: "halcyon theme", sudo: false, desc: "light / dark theme (toggle)" },
            { cmd: "halcyon lock", put: "halcyon lock", sudo: false, desc: "lock the screen" },
            { cmd: "halcyon reload", put: "halcyon reload", sudo: false, desc: "reload the island and Hyprland" }
        ] },
        { title: "In this console", items: [
            { cmd: "ai <question>", put: "ai ", sudo: false, desc: "local AI assistant" },
            { cmd: "advisor", put: "advisor", sudo: false, desc: "system analysis and performance advisor" },
            { cmd: "notes <text>", put: "notes ", sudo: false, desc: "quick notes (Super + N)" },
            { cmd: "help", put: "help", sudo: false, desc: "the short help" },
            { cmd: "cd [folder]", put: "cd ", sudo: false, desc: "change folder (remembered)" },
            { cmd: "clear", put: "clear", sudo: false, desc: "clear the output (Ctrl+L too)" },
            { cmd: "exit", put: "exit", sudo: false, desc: "close the console (Esc too)" },
            { cmd: "sudo ...", put: "sudo ", sudo: true, desc: "asks for your password right in the console" },
            { cmd: "vim / htop / ssh ...", put: "", sudo: false, desc: "need a real terminal, so they open in one" },
            { cmd: "Tab", put: "", sudo: false, desc: "completes; Right arrow takes the grey suggestion; Up / Down = history" }
        ] }
    ]

    readonly property var groupsNow: {
        var q = query.toLowerCase().trim()
        var out = []
        for (var g = 0; g < groups.length; g++) {
            var grp = groups[g], items = []
            for (var i = 0; i < grp.items.length; i++) {
                var it = grp.items[i]
                if (q !== "" && (it.cmd + " " + it.desc + " " + grp.title).toLowerCase().indexOf(q) < 0) continue
                items.push(it)
            }
            if (items.length > 0) out.push({ title: grp.title, items: items })
        }
        return out
    }
    readonly property int shownCount: { var n = 0; for (var g = 0; g < groupsNow.length; g++) n += groupsNow[g].items.length; return n }
    readonly property int totalCount: { var n = 0; for (var g = 0; g < groups.length; g++) n += groups[g].items.length; return n }

    LazyLoader {
        active: root.open
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-cmds"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: (root.open && !root.consoleOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: fade
                anchors.fill: parent
                opacity: root.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                focus: root.open
                Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true } }

                Rectangle { anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.55) }
                MouseArea { anchors.fill: parent; onClicked: root.hide() }

                Glass {
                    id: card
                    pal: root.pal
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 80, 1360)
                    height: parent.height - 80
                    radius: root.pal.rXl
                    opacityBody: root.pal.glassSolid - 0.02
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)
                    scale: root.open ? 1 : 0.96
                    Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    MouseArea { anchors.fill: parent }   // swallow clicks

                    Backdrop { visible: root.open && root.stars; anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; avatarStars: root.starData; profileStars: root.profileStars; dots: 14; artStrength: 0.6; artFit: 0.85 }
                    BarStars { anchors.fill: parent; anchors.margins: 12; pal: root.pal; count: root.flyCount; loopMs: root.flyLoop; sizeScale: 1.3; active: root.open; visible: root.open && root.flyCount > 0 }

                    // ---------------- header: title, search, close
                    RowLayout {
                        id: head
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 26 }
                        spacing: 14
                        Text { text: String.fromCodePoint(0xF0489); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                        BoxTitle { pal: root.pal; size: 20; overlay: true; title: "Console commands" }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 420
                            implicitHeight: 34
                            radius: 17
                            color: Qt.alpha(root.pal.bg, 0.55)
                            border.width: 1
                            border.color: search.activeFocus ? root.pal.lineFocus : root.pal.line
                            Text {
                                anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                visible: search.text === ""
                                text: String.fromCodePoint(0xF0349) + "  search commands"
                                color: root.pal.muted; font.family: root.pal.font; font.pixelSize: root.pal.tBody
                            }
                            TextInput {
                                id: search
                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                                verticalAlignment: TextInput.AlignVCenter
                                color: root.pal.text
                                selectionColor: Qt.alpha(root.pal.accent, 0.4)
                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                clip: true
                                Component.onCompleted: forceActiveFocus()
                                onTextChanged: root.query = text
                                Timer { running: root.open; interval: 80; onTriggered: search.forceActiveFocus() }
                                Keys.onEscapePressed: root.hide()
                            }
                        }
                        Text {
                            text: root.shownCount + " shown  ·  click one to put it in the console"
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                        }
                        Item { Layout.fillWidth: true }
                        RoundBtn { pal: root.pal; glyph: "✕"; size: 32; onClicked: root.hide() }
                    }

                    // ---------------- the tree
                    Flickable {
                        id: scroll
                        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 26; topMargin: 18 }
                        contentWidth: width
                        contentHeight: tree.height + 12
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Item {
                            id: tree
                            width: scroll.width
                            readonly property int colCount: card.width >= 1100 ? 2 : 1
                            readonly property real gap: 44
                            readonly property real colW: (width - (colCount - 1) * gap) / colCount
                            readonly property real barY: 72
                            readonly property real colsY: 98
                            property real colsH: 0
                            height: colsY + colsH + 8

                            // the groups spread over the columns, always into the shortest one
                            readonly property var columns: {
                                var n = colCount, cols = [], hs = []
                                for (var i = 0; i < n; i++) { cols.push([]); hs.push(0) }
                                for (var g = 0; g < root.groupsNow.length; g++) {
                                    var best = 0
                                    for (var j = 1; j < n; j++) if (hs[j] < hs[best]) best = j
                                    cols[best].push(root.groupsNow[g])
                                    hs[best] += root.groupsNow[g].items.length * 1.7 + 2
                                }
                                return cols
                            }
                            readonly property int usedCols: {
                                var n = 0
                                for (var i = 0; i < columns.length; i++) if (columns[i].length > 0) n = i + 1
                                return n
                            }

                            function measure() {
                                var h = 0
                                for (var i = 0; i < colRep.count; i++) {
                                    var c = colRep.itemAt(i)
                                    if (c) h = Math.max(h, c.height)
                                }
                                colsH = h
                            }

                            // ---- root node
                            Rectangle {
                                id: rootNode
                                width: rootRow.implicitWidth + 36
                                height: 42
                                radius: 21
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: 0
                                color: Qt.alpha(root.pal.accent, 0.16)
                                border.width: 1
                                border.color: Qt.alpha(root.pal.accent, 0.55)
                                Row {
                                    id: rootRow
                                    anchors.centerIn: parent
                                    spacing: 10
                                    Text { text: String.fromCodePoint(0xF0489); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 17; anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: "Console"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: root.totalCount + " commands"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; anchors.verticalCenter: parent.verticalCenter }
                                }
                            }

                            // ---- branches from the root to every column: one stem, one bar, one drop per column
                            Rectangle { visible: tree.usedCols > 0; x: tree.width / 2; y: rootNode.height; width: 1; height: tree.barY - rootNode.height; color: Qt.alpha(root.pal.accent, 0.45) }
                            Rectangle {
                                visible: tree.usedCols > 0
                                readonly property real firstX: 10
                                readonly property real lastX: (Math.max(1, tree.usedCols) - 1) * (tree.colW + tree.gap) + 10
                                x: Math.min(firstX, tree.width / 2)
                                y: tree.barY
                                width: Math.max(1, Math.max(lastX, tree.width / 2) - x)
                                height: 1
                                color: Qt.alpha(root.pal.accent, 0.45)
                            }
                            Repeater {
                                model: tree.usedCols
                                delegate: Item {
                                    required property int index
                                    readonly property real cx: index * (tree.colW + tree.gap) + 10
                                    Rectangle { x: parent.cx; y: tree.barY; width: 1; height: tree.colsY - tree.barY; color: Qt.alpha(root.pal.accent, 0.45) }
                                    Rectangle { x: parent.cx - 3; y: tree.barY - 3; width: 7; height: 7; radius: 3.5; color: root.pal.accent; opacity: 0.8 }
                                }
                            }

                            // ---- the columns of branches
                            Repeater {
                                id: colRep
                                model: tree.columns
                                delegate: Column {
                                    id: col
                                    required property var modelData
                                    required property int index
                                    x: index * (tree.colW + tree.gap)
                                    y: tree.colsY
                                    width: tree.colW
                                    spacing: 0
                                    onHeightChanged: tree.measure()
                                    Component.onCompleted: tree.measure()

                                    Repeater {
                                        model: col.modelData
                                        delegate: Item {
                                            id: grp
                                            required property var modelData
                                            required property int index
                                            readonly property bool lastGroup: grp.index === col.modelData.length - 1
                                            width: col.width
                                            height: grpHead.height + leaves.height + 34

                                            // the column's trunk: runs down through every group
                                            Rectangle {
                                                x: 10; y: 0; width: 1
                                                height: grp.lastGroup ? grpHead.height / 2 : grp.height
                                                color: Qt.alpha(root.pal.accent, 0.45)
                                            }

                                            // group node + title
                                            Item {
                                                id: grpHead
                                                width: parent.width
                                                height: 44
                                                Rectangle {
                                                    x: 3; anchors.verticalCenter: parent.verticalCenter
                                                    width: 15; height: 15; radius: 7.5
                                                    color: Qt.alpha(root.pal.accent, 0.25)
                                                    border.width: 1.5
                                                    border.color: root.pal.accent
                                                    Rectangle { anchors.centerIn: parent; width: 5; height: 5; radius: 2.5; color: root.pal.accent }
                                                }
                                                Text {
                                                    x: 28; anchors.verticalCenter: parent.verticalCenter
                                                    text: (root.pal.calm ? grp.modelData.title : grp.modelData.title.toUpperCase())
                                                    color: root.pal.accent
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: 12
                                                    font.weight: Font.DemiBold
                                                    font.letterSpacing: root.pal.calm ? 0.2 : (1.6)
                                                }
                                            }

                                            // leaves
                                            Column {
                                                id: leaves
                                                y: grpHead.height
                                                width: parent.width
                                                spacing: 0

                                                Repeater {
                                                    model: grp.modelData.items
                                                    delegate: Item {
                                                        id: leaf
                                                        required property var modelData
                                                        required property int index
                                                        readonly property bool lastLeaf: leaf.index === grp.modelData.items.length - 1
                                                        readonly property bool clickable: leaf.modelData.put !== ""
                                                        width: leaves.width
                                                        height: 54

                                                        // sub-trunk + elbow
                                                        Rectangle { x: 34; y: 0; width: 1; height: leaf.lastLeaf ? leaf.height / 2 : leaf.height; color: Qt.alpha(root.pal.accent, 0.28) }
                                                        Rectangle { x: 34; y: leaf.height / 2; width: 16; height: 1; color: Qt.alpha(root.pal.accent, 0.28) }
                                                        Rectangle { x: 50; y: leaf.height / 2 - 3; width: 6; height: 6; radius: 3; color: Qt.alpha(root.pal.accent, 0.6) }

                                                        Rectangle {
                                                            id: rowBg
                                                            x: 62; y: 3
                                                            width: leaf.width - 62
                                                            height: leaf.height - 6
                                                            radius: 12
                                                            color: ma.containsMouse && leaf.clickable ? Qt.alpha(root.pal.surfaceHi, 0.8) : "transparent"
                                                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }

                                                            RowLayout {
                                                                anchors.fill: parent
                                                                anchors.leftMargin: 12
                                                                anchors.rightMargin: 14
                                                                spacing: 18
                                                                // the command, as a mono keycap
                                                                Rectangle {
                                                                    Layout.preferredWidth: 220
                                                                    Layout.maximumWidth: 220
                                                                    Layout.alignment: Qt.AlignVCenter
                                                                    implicitHeight: 28
                                                                    radius: 8
                                                                    color: Qt.alpha(root.pal.accent2, 0.14)
                                                                    border.width: 1
                                                                    border.color: Qt.alpha(root.pal.accent2, 0.38)
                                                                    Text {
                                                                        id: cmdText
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        anchors.left: parent.left; anchors.right: parent.right
                                                                        anchors.leftMargin: 12; anchors.rightMargin: 12
                                                                        text: leaf.modelData.cmd
                                                                        elide: Text.ElideRight
                                                                        color: root.pal.text
                                                                        font.family: root.pal.mono
                                                                        font.pixelSize: 12
                                                                    }
                                                                }
                                                                Text {
                                                                    Layout.fillWidth: true
                                                                    Layout.alignment: Qt.AlignVCenter
                                                                    text: leaf.modelData.desc
                                                                    wrapMode: Text.WordWrap
                                                                    lineHeight: 1.15
                                                                    color: root.pal.muted
                                                                    font.family: root.pal.uiFont
                                                                    font.pixelSize: root.pal.tBody
                                                                }
                                                                // asks for the password in the console
                                                                Text {
                                                                    visible: leaf.modelData.sudo
                                                                    text: "sudo"
                                                                    color: root.pal.warn
                                                                    font.family: root.pal.mono
                                                                    font.pixelSize: 10
                                                                }
                                                            }
                                                            MouseArea {
                                                                id: ma
                                                                anchors.fill: parent
                                                                hoverEnabled: true
                                                                cursorShape: leaf.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                                onClicked: if (leaf.clickable) root.use(leaf.modelData.put)
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
                }
            }
        }
    }
}
