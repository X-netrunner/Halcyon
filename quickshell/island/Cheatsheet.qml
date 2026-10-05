import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "Binds.js" as Binds

// Every shortcut, gesture and command as a tree (same look as the SUPER+TAB tree): the root splits into branches
// (Apps, Windows, ...), each branch has its leaves, a leaf is a keycap row.
//   Type to search.   Click a shortcut to change it: pick the modifiers, press the key, Save.
//   "Your shortcuts" holds the ones you added (key combination -> command).   Esc closes (or cancels an edit).
// Open: SUPER+ALT+/, `>cheatsheet` in the launcher, Settings > Shortcuts.
// Changes are saved by shell.qml (binds.json + binds.lua) and applied with a Hyprland reload.
Scope {
    id: root
    property var pal
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool open: false

    // owned by shell.qml
    property var keyMap: ({})          // id -> keys you chose ("none" = switched off)
    property var customs: []           // [{ label, keys, cmd }]
    signal rebind(string id, string keys)                                // keys "" = back to the default
    signal customSaved(int index, string label, string keys, string cmd) // index -1 = new
    signal customRemoved(int index)

    function show() { open = true }
    function hide() { open = false }
    function toggle() { open = !open }

    // ---------------------------------------------------------------- editing state (one leaf at a time)
    property string editId: ""         // "" none | a bind id | "custom:<n>" | "custom:new"
    property var editMods: ({})
    property string editKey: ""
    property string editLabel: ""
    property string editCmd: ""
    property string editError: ""
    property bool capturing: false

    function startEdit(rec) {
        var p = Binds.parse(rec.keys === "none" ? rec.def : rec.keys)
        // text first, id last: the text boxes fill themselves from these when the editor appears
        editLabel = rec.custom >= 0 ? rec.label : ""
        editCmd = rec.custom >= 0 ? rec.cmd : ""
        editMods = rec.id === "custom:new" ? ({ SUPER: true }) : p.mods
        editKey = rec.id === "custom:new" ? "" : p.key
        editError = ""
        capturing = false
        editId = rec.id
    }
    function cancelEdit() { editId = ""; capturing = false; editError = ""; search.forceActiveFocus() }
    function toggleMod(m) {
        var o = {}
        for (var k in editMods) o[k] = editMods[k]
        if (o[m]) delete o[m]; else o[m] = true
        editMods = o
        editError = ""
    }
    function saveEdit() {
        if (editKey === "") { editError = "Press the key first"; return }
        var hasMod = false
        for (var k in editMods) if (editMods[k]) hasMod = true
        if (!hasMod && !Binds.mayBeAlone(editKey)) { editError = "Add a modifier (Super, Ctrl, Alt or Shift), or that key would stop working everywhere"; return }
        var keys = Binds.build(editMods, editKey)
        var clash = Binds.conflict(keys, editId, keyMap, customs)
        if (clash !== "") { editError = "Already used by: " + clash; return }
        if (editId.indexOf("custom:") === 0) {
            if (editCmd.trim() === "") { editError = "Type the command to run"; return }
            var idx = editId === "custom:new" ? -1 : parseInt(editId.substring(7))
            customSaved(idx, editLabel.trim() !== "" ? editLabel.trim() : editCmd.trim(), keys, editCmd.trim())
        } else {
            // same as the default -> just forget the override
            var def = ""
            for (var g = 0; g < Binds.groups.length; g++)
                for (var i = 0; i < Binds.groups[g].items.length; i++)
                    if (Binds.groups[g].items[i].id === editId) def = Binds.groups[g].items[i].keys
            rebind(editId, Binds.norm(keys) === Binds.norm(def) ? "" : keys)
        }
        cancelEdit()
    }

    // ---------------------------------------------------------------- the tree data (rebuilt when the search or a shortcut changes)
    property string query: ""
    readonly property int colCount: card.width >= 1180 ? 3 : (card.width >= 780 ? 2 : 1)

    function visibleGroups() {
        var q = query.toLowerCase().trim()
        var out = []
        for (var g = 0; g < Binds.groups.length; g++) {
            var grp = Binds.groups[g]
            var items = []
            for (var i = 0; i < grp.items.length; i++) {
                var it = grp.items[i]
                var keys = Binds.effectiveKeys(it, keyMap)
                var hay = (it.label + " " + keys + " " + Binds.parts(keys).join(" ") + " " + grp.title).toLowerCase()
                if (q !== "" && hay.indexOf(q) < 0) continue
                items.push({ id: it.id || "", label: it.label, kind: it.kind || "bind", keys: keys, def: it.keys,
                             editable: !!it.id, custom: -1, cmd: "", changed: !!it.id && keyMap[it.id] !== undefined })
            }
            if (items.length > 0) out.push({ id: grp.id, title: grp.title, items: items, custom: false })
        }
        var cit = []
        for (var c = 0; c < customs.length; c++) {
            var cu = customs[c]
            var chay = (cu.label + " " + cu.cmd + " " + cu.keys + " " + Binds.parts(cu.keys).join(" ")).toLowerCase()
            if (q !== "" && chay.indexOf(q) < 0) continue
            cit.push({ id: "custom:" + c, label: cu.label, kind: "bind", keys: cu.keys, def: cu.keys, editable: true, custom: c, cmd: cu.cmd, changed: false })
        }
        if (q === "" || cit.length > 0) out.push({ id: "custom", title: "Your shortcuts", items: cit, custom: true })
        return out
    }
    readonly property var groupsNow: { var a = query; var b = keyMap; var c = customs; return visibleGroups() }
    readonly property var columns: {
        var n = colCount, cols = [], hs = []
        for (var i = 0; i < n; i++) { cols.push([]); hs.push(0) }
        for (var g = 0; g < groupsNow.length; g++) {
            var best = 0
            for (var j = 1; j < n; j++) if (hs[j] < hs[best]) best = j
            cols[best].push(groupsNow[g])
            hs[best] += groupsNow[g].items.length + 2 + (groupsNow[g].custom ? 1 : 0)
        }
        return cols
    }
    readonly property int shownCount: { var n = 0; for (var g = 0; g < groupsNow.length; g++) n += groupsNow[g].items.length; return n }

    onOpenChanged: {
        if (open) { search.text = ""; query = ""; editId = ""; capturing = false; focusT.restart() }
    }
    Timer { id: focusT; interval: 60; onTriggered: search.forceActiveFocus() }

    // ---------------------------------------------------------------- small pieces
    // a keycap: one key of a shortcut
    component Cap: Rectangle {
        id: cap
        property var pal
        property string label: ""
        property color tint: cap.pal.accent
        property bool dim: false
        implicitWidth: Math.max(22, capText.implicitWidth + 14)
        implicitHeight: 22
        radius: 6
        color: Qt.alpha(tint, dim ? 0.06 : 0.14)
        border.width: 1
        border.color: Qt.alpha(tint, dim ? 0.18 : 0.38)
        Text {
            id: capText
            anchors.centerIn: parent
            text: cap.label
            color: cap.dim ? cap.pal.muted : cap.pal.text
            font.family: cap.pal.uiFont
            font.pixelSize: 11
            font.weight: Font.Medium
        }
    }

    // single-line text box
    component Field: Rectangle {
        id: fld
        property var pal
        property alias text: inp.text
        property string placeholder: ""
        signal accepted()
        signal escaped()
        implicitHeight: 30
        radius: 10
        color: Qt.alpha(fld.pal.bg, 0.55)
        border.width: 1
        border.color: inp.activeFocus ? fld.pal.lineFocus : fld.pal.line
        Text {
            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
            visible: inp.text === "" && !inp.activeFocus
            text: fld.placeholder
            color: fld.pal.muted; font.family: fld.pal.uiFont; font.pixelSize: fld.pal.tBody
        }
        TextInput {
            id: inp
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: fld.pal.text
            selectionColor: Qt.alpha(fld.pal.accent, 0.4)
            selectedTextColor: fld.pal.text
            font.family: fld.pal.uiFont; font.pixelSize: fld.pal.tBody
            clip: true
            onAccepted: fld.accepted()
            Keys.onEscapePressed: fld.escaped()
        }
    }

    PanelWindow {
        id: win
        visible: root.open || fade.opacity > 0.01
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "island-keys"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Item {
            id: fade
            anchors.fill: parent
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
            focus: root.open
            Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { if (root.editId !== "") root.cancelEdit(); else root.hide(); e.accepted = true } }

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
                border.color: Qt.alpha(root.pal.accent, 0.35)
                scale: root.open ? 1 : 0.96
                Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                MouseArea { anchors.fill: parent }   // swallow clicks

                Backdrop { anchors.fill: parent; anchors.margins: 12; pal: root.pal; mode: root.sysmode; avatarStars: root.starData; profileStars: root.profileStars; dots: 14; artStrength: 0.6; artFit: 0.85 }

                // ---------------- header: title, search, close
                RowLayout {
                    id: head
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 26 }
                    spacing: 14
                    Text { text: String.fromCodePoint(0xF030C); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                    Text { text: "Shortcuts"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
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
                            text: String.fromCodePoint(0xF0349) + "  search shortcuts"
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
                            onTextChanged: root.query = text
                            Keys.onEscapePressed: { if (root.editId !== "") root.cancelEdit(); else root.hide() }
                        }
                    }
                    Text {
                        text: root.shownCount + " shown  ·  click one to change it"
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
                        readonly property real gap: 28
                        readonly property real colW: (width - (root.colCount - 1) * gap) / root.colCount
                        readonly property real barY: 72
                        readonly property real colsY: 98
                        property real colsH: 0
                        height: colsY + colsH + 8

                        // lowest hanging point of every column, to size the whole tree
                        function measure() {
                            var h = 0
                            for (var i = 0; i < colRep.count; i++) {
                                var c = colRep.itemAt(i)
                                if (c) h = Math.max(h, c.height)
                            }
                            colsH = h
                        }

                        // time for the pulses that run down the branches
                        property real tt: 0
                        NumberAnimation on tt { from: 0; to: 1; duration: 3600; loops: Animation.Infinite; running: root.open && root.pal.motion > 0.3 }

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
                                Text { text: String.fromCodePoint(0xF030C); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 17; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: "Halcyon"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: Binds.countAll(root.customs) + " things you can do"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; anchors.verticalCenter: parent.verticalCenter }
                            }
                        }

                        // ---- branches from the root to every column: one stem, one bar, one drop per column
                        Rectangle { x: tree.width / 2; y: rootNode.height; width: 1; height: tree.barY - rootNode.height; color: Qt.alpha(root.pal.accent, 0.45) }
                        Rectangle {
                            readonly property real firstX: 10
                            readonly property real lastX: (root.colCount - 1) * (tree.colW + tree.gap) + 10
                            x: Math.min(firstX, tree.width / 2)
                            y: tree.barY
                            width: Math.max(1, Math.max(lastX, tree.width / 2) - x)
                            height: 1
                            color: Qt.alpha(root.pal.accent, 0.45)
                        }
                        Repeater {
                            model: root.colCount
                            delegate: Item {
                                required property int index
                                readonly property real cx: index * (tree.colW + tree.gap) + 10
                                Rectangle { x: parent.cx; y: tree.barY; width: 1; height: tree.colsY - tree.barY; color: Qt.alpha(root.pal.accent, 0.45) }
                                Rectangle { x: parent.cx - 3; y: tree.barY - 3; width: 7; height: 7; radius: 3.5; color: root.pal.accent; opacity: 0.8 }
                                // pulse travelling down the drop
                                Rectangle {
                                    visible: root.pal.motion > 0.3
                                    x: parent.cx - 2
                                    y: tree.barY + (tree.colsY - tree.barY) * ((tree.tt + index * 0.23) % 1)
                                    width: 5; height: 5; radius: 2.5
                                    color: root.pal.accent
                                    opacity: Math.sin(((tree.tt + index * 0.23) % 1) * Math.PI) * 0.9
                                }
                            }
                        }

                        // ---- the columns of branches
                        Repeater {
                            id: colRep
                            model: root.columns
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
                                        height: grpHead.height + leaves.height + 16

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
                                            height: 34
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
                                                text: grp.modelData.title.toUpperCase()
                                                color: root.pal.accent
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 11
                                                font.weight: Font.DemiBold
                                                font.letterSpacing: 1.4
                                            }
                                        }

                                        // leaves
                                        Column {
                                            id: leaves
                                            y: grpHead.height
                                            width: parent.width
                                            spacing: 0

                                            Repeater {
                                                id: leafRep
                                                model: grp.modelData.items
                                                delegate: Item {
                                                    id: leaf
                                                    required property var modelData
                                                    required property int index
                                                    readonly property bool lastLeaf: leaf.index === grp.modelData.items.length - 1 && !grp.modelData.custom
                                                    readonly property bool editing: root.editId === leaf.modelData.id && leaf.modelData.id !== ""
                                                    readonly property bool isCustom: leaf.modelData.custom >= 0
                                                    readonly property bool isBind: leaf.modelData.kind === "bind"
                                                    readonly property bool off: leaf.modelData.keys === "none"
                                                    width: leaves.width
                                                    height: 32 + (leaf.editing ? editor.height + 8 : 0)

                                                    // sub-trunk + elbow
                                                    Rectangle { x: 34; y: 0; width: 1; height: leaf.lastLeaf ? 16 : leaf.height; color: Qt.alpha(root.pal.accent, 0.28) }
                                                    Rectangle { x: 34; y: 16; width: 16; height: 1; color: Qt.alpha(root.pal.accent, 0.28) }
                                                    Rectangle {
                                                        x: 50; y: 16 - 3; width: 6; height: 6; radius: 3
                                                        color: leaf.modelData.changed || leaf.isCustom ? root.pal.accent2 : Qt.alpha(root.pal.accent, 0.6)
                                                    }

                                                    // row: label on the left, keycaps on the right
                                                    Rectangle {
                                                        id: rowBg
                                                        x: 62; y: 1
                                                        width: leaf.width - 62
                                                        height: 30
                                                        radius: 9
                                                        color: leaf.editing ? Qt.alpha(root.pal.accent, 0.12) : (ma.containsMouse && leaf.modelData.editable ? Qt.alpha(root.pal.surfaceHi, 0.8) : "transparent")
                                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }

                                                        Row {
                                                            id: keyRow
                                                            anchors.right: parent.right
                                                            anchors.rightMargin: 8
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            spacing: 4
                                                            Repeater {
                                                                model: leaf.off ? ["off"] : (leaf.isBind ? Binds.parts(leaf.modelData.keys) : [leaf.modelData.keys])
                                                                delegate: Cap {
                                                                    required property string modelData
                                                                    pal: root.pal
                                                                    label: modelData
                                                                    dim: leaf.off || !leaf.isBind
                                                                    tint: leaf.modelData.kind === "cli" ? root.pal.accent2 : root.pal.accent
                                                                }
                                                            }
                                                        }
                                                        RowLayout {
                                                            anchors.left: parent.left; anchors.leftMargin: 8
                                                            anchors.right: keyRow.left; anchors.rightMargin: 12
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            spacing: 8
                                                            Text {
                                                                Layout.fillWidth: !leaf.isCustom
                                                                text: leaf.modelData.label
                                                                elide: Text.ElideRight
                                                                color: leaf.off ? root.pal.muted : root.pal.text
                                                                font.family: root.pal.uiFont
                                                                font.pixelSize: root.pal.tBody
                                                            }
                                                            Text {
                                                                visible: leaf.isCustom
                                                                Layout.fillWidth: true
                                                                text: leaf.modelData.cmd
                                                                elide: Text.ElideRight
                                                                color: root.pal.muted
                                                                font.family: root.pal.mono
                                                                font.pixelSize: 10
                                                            }
                                                        }
                                                        MouseArea {
                                                            id: ma
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            enabled: leaf.modelData.editable
                                                            cursorShape: leaf.modelData.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                            onClicked: { if (leaf.editing) root.cancelEdit(); else root.startEdit(leaf.modelData) }
                                                        }
                                                    }

                                                    // ---- inline editor
                                                    Rectangle {
                                                        id: editor
                                                        visible: leaf.editing
                                                        x: 62; y: 36
                                                        width: leaf.width - 62
                                                        height: edCol.implicitHeight + 24
                                                        radius: 12
                                                        color: Qt.alpha(root.pal.surface, 0.95)
                                                        border.width: 1
                                                        border.color: Qt.alpha(root.pal.accent, 0.35)

                                                        ColumnLayout {
                                                            id: edCol
                                                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                                            spacing: 8

                                                            Field {
                                                                pal: root.pal
                                                                visible: leaf.isCustom
                                                                Layout.fillWidth: true
                                                                placeholder: "Name (optional), e.g. Screen recorder"
                                                                onVisibleChanged: if (visible) text = root.editLabel
                                                                onTextChanged: root.editLabel = text
                                                                onEscaped: root.cancelEdit()
                                                            }
                                                            Field {
                                                                pal: root.pal
                                                                visible: leaf.isCustom
                                                                Layout.fillWidth: true
                                                                placeholder: "Command to run, e.g. firefox --private-window"
                                                                onVisibleChanged: if (visible) text = root.editCmd
                                                                onTextChanged: root.editCmd = text
                                                                onAccepted: root.saveEdit()
                                                                onEscaped: root.cancelEdit()
                                                            }

                                                            // modifiers + the key
                                                            Flow {
                                                                Layout.fillWidth: true
                                                                spacing: 6
                                                                Repeater {
                                                                    model: [ { m: "SUPER", t: "Super" }, { m: "CTRL", t: "Ctrl" }, { m: "ALT", t: "Alt" }, { m: "SHIFT", t: "Shift" } ]
                                                                    delegate: Chip {
                                                                        required property var modelData
                                                                        pal: root.pal
                                                                        implicitHeight: 30
                                                                        label: modelData.t
                                                                        on: !!root.editMods[modelData.m]
                                                                        onClicked: root.toggleMod(modelData.m)
                                                                    }
                                                                }
                                                                Text { text: "+"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 15; height: 30; verticalAlignment: Text.AlignVCenter }
                                                                // press-a-key box: click, then press the key
                                                                Rectangle {
                                                                    id: capBox
                                                                    width: 170; height: 30; radius: 15
                                                                    color: root.capturing ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.surfaceHi, 0.9)
                                                                    border.width: 1
                                                                    border.color: root.capturing ? root.pal.accent : root.pal.line
                                                                    focus: root.capturing
                                                                    Text {
                                                                        anchors.centerIn: parent
                                                                        text: root.capturing ? "press a key…" : (root.editKey !== "" ? Binds.parts(root.editKey).join("") : "click, then press a key")
                                                                        color: root.capturing || root.editKey === "" ? root.pal.muted : root.pal.text
                                                                        font.family: root.pal.uiFont
                                                                        font.pixelSize: root.pal.tBody
                                                                        font.weight: root.editKey !== "" && !root.capturing ? Font.DemiBold : Font.Normal
                                                                    }
                                                                    MouseArea {
                                                                        anchors.fill: parent
                                                                        onClicked: { root.capturing = true; root.editError = ""; capBox.forceActiveFocus() }
                                                                    }
                                                                    Keys.onPressed: e => {
                                                                        if (!root.capturing) return
                                                                        if (e.key === Qt.Key_Escape) { root.capturing = false; e.accepted = true; return }
                                                                        if (Binds.isModifierKey(e.key)) { e.accepted = true; return }
                                                                        var name = Binds.qtKey(e.key)
                                                                        e.accepted = true
                                                                        if (name === "") { root.editError = "That key can not be used"; return }
                                                                        root.editKey = name
                                                                        // modifiers held while pressing it are taken over too
                                                                        var held = Binds.qtMods(e.modifiers)
                                                                        var any = false
                                                                        for (var k in held) any = true
                                                                        if (any) root.editMods = held
                                                                        root.capturing = false
                                                                        root.editError = ""
                                                                    }
                                                                }
                                                            }

                                                            Text {
                                                                visible: root.editError !== ""
                                                                Layout.fillWidth: true
                                                                text: root.editError
                                                                wrapMode: Text.WordWrap
                                                                color: root.pal.bad
                                                                font.family: root.pal.uiFont
                                                                font.pixelSize: root.pal.tCap
                                                            }
                                                            Text {
                                                                Layout.fillWidth: true
                                                                visible: root.editError === ""
                                                                text: "Will be: " + (root.editKey !== "" ? Binds.parts(Binds.build(root.editMods, root.editKey)).join(" + ") : "…") + (leaf.isCustom || root.editId === "custom:new" ? "" : "     (default: " + Binds.parts(leaf.modelData.def).join(" + ") + ")")
                                                                color: root.pal.muted
                                                                font.family: root.pal.uiFont
                                                                font.pixelSize: root.pal.tCap
                                                            }

                                                            Flow {
                                                                Layout.fillWidth: true
                                                                spacing: 6
                                                                Chip { pal: root.pal; implicitHeight: 30; label: "Save"; on: true; onClicked: root.saveEdit() }
                                                                Chip {
                                                                    visible: !leaf.isCustom && root.editId !== "custom:new"
                                                                    pal: root.pal; implicitHeight: 30; label: "Default"
                                                                    onClicked: { root.rebind(root.editId, ""); root.cancelEdit() }
                                                                }
                                                                Chip {
                                                                    visible: !leaf.isCustom && root.editId !== "custom:new"
                                                                    pal: root.pal; implicitHeight: 30; label: "Turn off"
                                                                    onClicked: { root.rebind(root.editId, "none"); root.cancelEdit() }
                                                                }
                                                                Chip {
                                                                    visible: leaf.isCustom
                                                                    pal: root.pal; implicitHeight: 30; label: "Delete"
                                                                    onClicked: { var i = leaf.modelData.custom; root.cancelEdit(); root.customRemoved(i) }
                                                                }
                                                                Chip { pal: root.pal; implicitHeight: 30; label: "Cancel"; onClicked: root.cancelEdit() }
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            // "+ add a shortcut" (only in "Your shortcuts")
                                            Item {
                                                id: addLeaf
                                                visible: grp.modelData.custom
                                                width: leaves.width
                                                height: grp.modelData.custom ? (addEditing ? 32 + addEditor.height + 8 : 32) : 0
                                                readonly property bool addEditing: root.editId === "custom:new"
                                                Rectangle { x: 34; y: 0; width: 1; height: 16; color: Qt.alpha(root.pal.accent, 0.28) }
                                                Rectangle { x: 34; y: 16; width: 16; height: 1; color: Qt.alpha(root.pal.accent, 0.28) }
                                                Rectangle { x: 50; y: 13; width: 6; height: 6; radius: 3; color: "transparent"; border.width: 1; border.color: root.pal.accent }
                                                Rectangle {
                                                    x: 62; y: 1; width: leaves.width - 62; height: 30; radius: 9
                                                    color: addMa.containsMouse || addLeaf.addEditing ? Qt.alpha(root.pal.surfaceHi, 0.8) : "transparent"
                                                    Text {
                                                        anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                                        text: "+  Add a shortcut"
                                                        color: root.pal.accent
                                                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
                                                    }
                                                    MouseArea {
                                                        id: addMa
                                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: { if (addLeaf.addEditing) root.cancelEdit(); else root.startEdit({ id: "custom:new", label: "", keys: "", def: "", cmd: "", custom: -1 }) }
                                                    }
                                                }
                                                // the editor for a new shortcut reuses the same look as the leaf editor
                                                Rectangle {
                                                    id: addEditor
                                                    visible: addLeaf.addEditing
                                                    x: 62; y: 36
                                                    width: leaves.width - 62
                                                    height: newCol.implicitHeight + 24
                                                    radius: 12
                                                    color: Qt.alpha(root.pal.surface, 0.95)
                                                    border.width: 1
                                                    border.color: Qt.alpha(root.pal.accent, 0.35)
                                                    ColumnLayout {
                                                        id: newCol
                                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                                        spacing: 8
                                                        Field {
                                                            pal: root.pal
                                                            Layout.fillWidth: true
                                                            placeholder: "Name (optional), e.g. Screen recorder"
                                                            onVisibleChanged: if (visible) text = root.editLabel
                                                            onTextChanged: root.editLabel = text
                                                            onEscaped: root.cancelEdit()
                                                        }
                                                        Field {
                                                            pal: root.pal
                                                            Layout.fillWidth: true
                                                            placeholder: "Command to run, e.g. firefox --private-window"
                                                            onVisibleChanged: if (visible) text = root.editCmd
                                                            onTextChanged: root.editCmd = text
                                                            onAccepted: root.saveEdit()
                                                            onEscaped: root.cancelEdit()
                                                        }
                                                        Flow {
                                                            Layout.fillWidth: true
                                                            spacing: 6
                                                            Repeater {
                                                                model: [ { m: "SUPER", t: "Super" }, { m: "CTRL", t: "Ctrl" }, { m: "ALT", t: "Alt" }, { m: "SHIFT", t: "Shift" } ]
                                                                delegate: Chip {
                                                                    required property var modelData
                                                                    pal: root.pal; implicitHeight: 30
                                                                    label: modelData.t
                                                                    on: !!root.editMods[modelData.m]
                                                                    onClicked: root.toggleMod(modelData.m)
                                                                }
                                                            }
                                                            Text { text: "+"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 15; height: 30; verticalAlignment: Text.AlignVCenter }
                                                            Rectangle {
                                                                id: capBox2
                                                                width: 170; height: 30; radius: 15
                                                                color: root.capturing ? Qt.alpha(root.pal.accent, 0.2) : Qt.alpha(root.pal.surfaceHi, 0.9)
                                                                border.width: 1
                                                                border.color: root.capturing ? root.pal.accent : root.pal.line
                                                                focus: root.capturing
                                                                Text {
                                                                    anchors.centerIn: parent
                                                                    text: root.capturing ? "press a key…" : (root.editKey !== "" ? Binds.parts(root.editKey).join("") : "click, then press a key")
                                                                    color: root.capturing || root.editKey === "" ? root.pal.muted : root.pal.text
                                                                    font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                                                                    font.weight: root.editKey !== "" && !root.capturing ? Font.DemiBold : Font.Normal
                                                                }
                                                                MouseArea { anchors.fill: parent; onClicked: { root.capturing = true; root.editError = ""; capBox2.forceActiveFocus() } }
                                                                Keys.onPressed: e => {
                                                                    if (!root.capturing) return
                                                                    if (e.key === Qt.Key_Escape) { root.capturing = false; e.accepted = true; return }
                                                                    if (Binds.isModifierKey(e.key)) { e.accepted = true; return }
                                                                    var name = Binds.qtKey(e.key)
                                                                    e.accepted = true
                                                                    if (name === "") { root.editError = "That key can not be used"; return }
                                                                    root.editKey = name
                                                                    var held = Binds.qtMods(e.modifiers)
                                                                    var any = false
                                                                    for (var k in held) any = true
                                                                    if (any) root.editMods = held
                                                                    root.capturing = false
                                                                    root.editError = ""
                                                                }
                                                            }
                                                        }
                                                        Text {
                                                            Layout.fillWidth: true
                                                            text: root.editError !== "" ? root.editError : "Will be: " + (root.editKey !== "" ? Binds.parts(Binds.build(root.editMods, root.editKey)).join(" + ") : "…")
                                                            wrapMode: Text.WordWrap
                                                            color: root.editError !== "" ? root.pal.bad : root.pal.muted
                                                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                                                        }
                                                        Flow {
                                                            Layout.fillWidth: true
                                                            spacing: 6
                                                            Chip { pal: root.pal; implicitHeight: 30; label: "Save"; on: true; onClicked: root.saveEdit() }
                                                            Chip { pal: root.pal; implicitHeight: 30; label: "Cancel"; onClicked: root.cancelEdit() }
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
