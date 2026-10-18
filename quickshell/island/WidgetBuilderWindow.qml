import QtQuick
import QtQuick.Layouts
import "WidgetData.js" as WD

// The widget builder window (Settings > Appearance > Widget builder, or `widget-builder`). It is about ONE widget at a time:
//   Left:    your widgets (click one to work on it) and "Add a widget" with every kind there is.
//   Middle:  the picked widget, life size, exactly as it will look on the desktop.
//   Right:   its layout (style), its options, its size, its look (box, colours, font, text size), saved styles of your own,
//            and a quick place on the screen. Where everything sits overall is the Desktop builder's job.
// Every change is saved and shows on the real desktop at once (changed("deskWidgets", layout) / changed("deskStyles", list)).
Item {
    id: root
    property var pal
    property var env
    property bool open: false
    property var opt: ({})
    signal changed(string key, var value)
    signal closed()
    signal editOnDesktop()

    // the newest layout a slider made that the 70 ms timer has not sent yet: every edit starts from it, so a click right after a slider
    // does not start from the old layout (and then get overwritten when the timer sends the slider's value)
    property var livePending: null
    readonly property var layout: WD.normalize(livePending !== null ? livePending : (opt ? opt.deskWidgets : null))
    readonly property var saved: (opt && opt.deskStyles && opt.deskStyles.length !== undefined) ? opt.deskStyles : []
    property string sel: ""
    property string pick: ""              // asked to open on this widget (from the desktop editor)
    onPickChanged: if (pick !== "" && WD.find(layout, pick) !== null) { sel = pick; adding = false }
    property bool adding: false
    property string newName: ""
    readonly property var cur: WD.find(layout, sel)
    readonly property var curLook: WD.look(cur ? cur.look : null)
    readonly property var curType: cur ? WD.typeOf(cur.type) : null

    function select(uid) { sel = uid; adding = false }

    // links: this widget follows another one (same width, same size, a fixed gap; see WidgetData.js)
    readonly property string curLinkTo: cur && cur.link ? cur.link : ""
    readonly property string curLinkSide: cur ? WD.sideOf(cur.linkSide) : "below"
    readonly property int curLinkGap: cur && cur.linkGap !== undefined ? cur.linkGap : 14
    // several widgets may follow the same one: on one side they stand in a line, and this one can be moved along it
    readonly property var curSiblings: cur && cur.link ? WD.siblings(layout, cur.link, WD.sideOf(cur.linkSide)) : []
    readonly property int curSlot: cur ? curSiblings.indexOf(cur.uid) : 0
    readonly property var slotOptions: {
        var o = []
        for (var i = 0; i < curSiblings.length; i++) o.push([i, i === 0 ? "1st" : (i === 1 ? "2nd" : (i === 2 ? "3rd" : (i + 1) + "th"))])
        return o
    }
    // "Nothing" and every other widget it may follow (named by its kind; "2nd" etc. when there are several of one kind)
    readonly property var linkOptions: {
        var o = [["", "Nothing"]], cnt = {}, seen = {}
        for (var i = 0; i < layout.items.length; i++) cnt[layout.items[i].type] = (cnt[layout.items[i].type] || 0) + 1
        for (var j = 0; j < layout.items.length; j++) {
            var it = layout.items[j]
            seen[it.type] = (seen[it.type] || 0) + 1
            if (it.uid === sel || !WD.canLink(layout, sel, it.uid)) continue
            o.push([it.uid, WD.nameOf(it.type) + (cnt[it.type] > 1 ? " " + seen[it.type] : "")])
        }
        return o
    }
    // the "?" markers: one shared bubble on the card (so the scrolling column can not cut the text off)
    property var tipItem: null
    property string tipText: ""
    property real tipCx: 0
    property real tipTop: 0
    property real tipBottom: 0
    function setTip(item, on) {
        if (!on) { if (tipItem === item) tipItem = null; return }
        var a = card.mapFromItem(item, item.width / 2, 0), b = card.mapFromItem(item, 0, item.height)
        tipText = item.tip; tipCx = a.x; tipTop = a.y; tipBottom = b.y
        tipItem = item
    }
    onSelChanged: tipItem = null
    function setLinkTo(to) { edit(WD.setLink(layout, sel, to, curLinkSide, curLinkGap), false) }
    function setLinkSlot(n) { edit(WD.setLinkSlot(layout, sel, n), false) }
    function setLinkV(side, gap, live) { edit(WD.setLink(layout, sel, curLinkTo, side, gap), live === true) }
    // the picked one disappeared (or nothing is picked yet): pick the first
    onLayoutChanged: if (WD.find(layout, sel) === null) sel = layout.items.length ? layout.items[0].uid : ""
    Component.onCompleted: if (sel === "" && layout.items.length) sel = layout.items[0].uid

    // sliders send a value for every pixel: pass the first at once, then at most one every 70 ms, ending on the last
    property var pending: ({})
    function send(k, v) { if (k === "deskWidgets") livePending = null; root.changed(k, v) }
    function put(k, v) {
        if (k === "deskWidgets") { var p0 = pending; delete p0.deskWidgets; pending = p0 }      // this newer layout replaces a waiting one
        send(k, v)
    }
    function putLive(k, v) {
        if (liveT.running) { var p = pending; p[k] = v; pending = p; if (k === "deskWidgets") livePending = v; return }
        send(k, v)
        liveT.start()
    }
    Timer {
        id: liveT
        interval: 70
        onTriggered: {
            var p = root.pending
            root.pending = ({})
            var any = false
            for (var k in p) { root.send(k, p[k]); any = true }
            if (any) liveT.start()
        }
    }
    function flushLive() { var p = root.pending; root.pending = ({}); for (var k in p) root.send(k, p[k]) }

    function edit(l, live) { if (live) putLive("deskWidgets", l); else put("deskWidgets", l) }
    function setStyle(s) { edit(WD.setStyle(layout, sel, s), false) }
    function setOptV(k, v, live) { edit(WD.setOpt(layout, sel, k, v), live === true) }
    function setLookV(k, v, live) { edit(WD.setLook(layout, sel, k, v), live === true) }
    function toggleIn(k, id) {
        var a = (cur && cur.opts && cur.opts[k] !== undefined ? cur.opts[k] : WD.optDefault(cur.type, k)) || []
        var i = a.indexOf(id), b = a.slice()
        if (i >= 0) b.splice(i, 1); else b.push(id)
        setOptV(k, b, false)
    }
    function addWidget(type) {
        var uid = WD.nextUid(layout.items)
        edit(WD.add(layout, type), false)
        sel = uid; adding = false
    }
    function applyStyleLook(l) { edit(WD.applyLook(layout, sel, l), false) }
    function saveStyle() {
        var n = newName.trim()
        if (n === "" || !cur) return
        var out = []
        for (var i = 0; i < saved.length; i++) if (saved[i].name !== n) out.push(saved[i])
        out.push({ name: n, look: WD.look(cur.look) })
        put("deskStyles", out)
        newName = ""
    }
    function dropStyle(n) {
        var out = []
        for (var i = 0; i < saved.length; i++) if (saved[i].name !== n) out.push(saved[i])
        put("deskStyles", out)
    }

    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
    onOpenChanged: { if (open) Qt.callLater(function () { root.forceActiveFocus() }); else flushLive() }
    Keys.onPressed: function (e) { if (e.key === Qt.Key_Escape) { if (root.adding) root.adding = false; else root.closed(); e.accepted = true } }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.5)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }

    Glass {
        id: card
        pal: root.pal
        anchors.centerIn: parent
        width: Math.min(parent.width - 100, 1280)
        height: Math.min(parent.height - 70, 800)
        radius: root.pal.rXl
        opacityBody: root.pal.solid ? 1 : 0.8
        border.color: Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 30
            spacing: 18

            // ---- header
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Rectangle { Layout.alignment: Qt.AlignVCenter; width: 8; height: 8; radius: 4; color: root.pal.accent }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text { text: "Widget builder"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
                    Text { text: "One widget at a time: pick it on the left, shape it on the right. Where they all sit is the Desktop builder's job."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                }
                Item { Layout.fillWidth: true }
                ActionChip { pal: root.pal; label: "Place them on the desktop"; onClicked: root.editOnDesktop() }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 22

                // ================================================= left: the list
                Rectangle {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 250
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.45)
                    border.width: 1; border.color: root.pal.lineTint

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10
                        NbCap { pal: root.pal; text: "YOUR WIDGETS  ·  " + root.layout.items.length }
                        Flickable {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            contentWidth: width
                            contentHeight: lst.implicitHeight + 4
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            Column {
                                id: lst
                                width: parent.width
                                spacing: 6
                                Text {
                                    visible: root.layout.items.length === 0
                                    width: parent.width
                                    text: "Nothing on the desktop yet. Add a widget below."
                                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; wrapMode: Text.WordWrap
                                }
                                Repeater {
                                    model: WD.listRows(root.layout)
                                    delegate: Item {
                                        id: rowD
                                        required property var modelData
                                        readonly property var itm: modelData.it
                                        readonly property bool grouped: modelData.g >= 0
                                        readonly property color grpCol: grouped ? WD.groupColor(modelData.g) : "transparent"
                                        readonly property bool on: itm.uid === root.sel && !root.adding
                                        readonly property real hdr: (grouped && modelData.pos === "first") ? 20 : 0
                                        width: lst.width; height: hdr + 44
                                        opacity: itm.off === true ? 0.55 : 1
                                        // linked widgets: a small header for the first one, and a coloured bracket down the side of the whole group
                                        Row {
                                            visible: rowD.hdr > 0
                                            height: 18; spacing: 6
                                            Text { text: String.fromCodePoint(0xF0337); color: rowD.grpCol; font.family: root.pal.font; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                                            Text { text: rowD.modelData.label + "  ·  " + rowD.modelData.n + " linked"; color: rowD.grpCol; font.family: root.pal.uiFont; font.pixelSize: 10; font.letterSpacing: 1; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                        }
                                        Rectangle {
                                            visible: rowD.grouped
                                            x: 3; y: rowD.hdr > 0 ? 20 : 0; width: 3; radius: 1.5
                                            height: rowD.height - y + (rowD.modelData.pos === "last" ? 0 : 6)
                                            color: Qt.alpha(rowD.grpCol, 0.9)
                                        }
                                        Rectangle {
                                            x: rowD.grouped ? 14 : 0; y: rowD.hdr
                                            width: rowD.width - x; height: 44; radius: 14
                                            color: rowD.on ? Qt.alpha(root.pal.accent, 0.18) : (lm.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.8) : Qt.alpha(root.pal.surface, 0.5))
                                            border.width: 1; border.color: rowD.on ? Qt.alpha(root.pal.accent, 0.5) : (rowD.grouped ? Qt.alpha(rowD.grpCol, 0.35) : root.pal.lineSoft)
                                            Row {
                                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10
                                                spacing: 10
                                                Text { text: String.fromCodePoint(WD.iconOf(rowD.itm.type)); color: rowD.on ? root.pal.accent : root.pal.muted; font.family: root.pal.font; font.pixelSize: 18; anchors.verticalCenter: parent.verticalCenter }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: parent.width - 40
                                                    Text { width: parent.width; text: WD.nameOf(rowD.itm.type); elide: Text.ElideRight; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                    Text { width: parent.width; text: (rowD.modelData.rel !== "" ? rowD.modelData.rel : WD.spotName(rowD.itm)) + (rowD.itm.off === true ? "  ·  switched off" : ""); elide: Text.ElideRight; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10 }
                                                }
                                            }
                                            MouseArea { id: lm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.select(rowD.itm.uid) }
                                        }
                                    }
                                }
                            }
                        }
                        // The column is only ~222 px wide: "Add a widget" + Copy + Remove on one line squeezed the first
                        // button to ~46 px and its label spilled out. So: Add on its own line, Copy / Remove share the next.
                        ActionChip { Layout.fillWidth: true; pal: root.pal; label: root.adding ? "Back" : "Add a widget"; on: !root.adding; onClicked: root.adding = !root.adding }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            ActionChip { Layout.fillWidth: true; Layout.preferredWidth: 1; pal: root.pal; label: "Copy"; disabled: root.cur === null; onClicked: root.edit(WD.duplicate(root.layout, root.sel), false) }
                            ActionChip { Layout.fillWidth: true; Layout.preferredWidth: 1; pal: root.pal; label: "Remove"; disabled: root.cur === null; onClicked: root.edit(WD.remove(root.layout, root.sel), false) }
                        }
                        // the master switch: every desktop widget off / on at once (they stay in your layout)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "All desktop widgets"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; elide: Text.ElideRight }
                            Toggle { pal: root.pal; on: !root.opt || root.opt.deskWidgetsOn !== false; onToggled: root.put("deskWidgetsOn", !(!root.opt || root.opt.deskWidgetsOn !== false)) }
                        }
                    }
                }

                // ================================================= middle: the widget, life size, or the catalog
                Rectangle {
                    id: stage
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: 420
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.55)
                    border.width: 1; border.color: root.pal.lineTint
                    clip: true
                    NbCap { pal: root.pal; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 14; text: root.adding ? "ADD A WIDGET" : "LIVE PREVIEW  ·  LIFE SIZE" }

                    // a soft backdrop so light and dark widgets both show
                    Rectangle {
                        anchors.fill: parent; anchors.margins: 1; radius: root.pal.rLg
                        visible: !root.adding
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.alpha(root.pal.accent, 0.10) }
                            GradientStop { position: 1; color: Qt.alpha(root.pal.accent2, 0.06) }
                        }
                    }
                    Item {
                        visible: !root.adding && root.cur !== null
                        anchors.centerIn: parent
                        width: pv.vw; height: pv.vh
                        WidgetHost {
                            id: pv
                            pal: root.pal
                            env: root.env
                            item: root.cur
                            preview: true
                            shown: root.open
                        }
                    }
                    Text {
                        visible: !root.adding && root.cur === null
                        anchors.centerIn: parent
                        text: "Add a widget to start"
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle
                    }
                    Text {
                        visible: !root.adding && root.cur !== null
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top; anchors.topMargin: 16
                        width: parent.width - 40
                        horizontalAlignment: Text.AlignHCenter
                        text: root.curType ? root.curType.hint : ""
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; wrapMode: Text.WordWrap
                    }

                    // the catalog
                    Flickable {
                        visible: root.adding
                        anchors.fill: parent; anchors.margins: 18; anchors.bottomMargin: 38
                        contentWidth: width
                        contentHeight: cat.implicitHeight + 8
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        Column {
                            id: cat
                            width: parent.width
                            spacing: 14
                            Repeater {
                                model: WD.cats
                                delegate: Column {
                                    required property var modelData
                                    width: cat.width
                                    spacing: 8
                                    NbCap { pal: root.pal; text: modelData[1].toUpperCase() }
                                    Flow {
                                        width: parent.width
                                        spacing: 8
                                        Repeater {
                                            model: WD.catalog.filter(function (t) { return t.cat === modelData[0] })
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: 150; height: 64; radius: 14
                                                color: am.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, 0.6)
                                                border.width: 1; border.color: am.containsMouse ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
                                                Column {
                                                    anchors.fill: parent; anchors.margins: 10
                                                    spacing: 4
                                                    Row {
                                                        spacing: 8
                                                        Text { text: String.fromCodePoint(modelData.icon); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 17 }
                                                        Text { text: modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium; elide: Text.ElideRight; width: 106 }
                                                    }
                                                    Text { width: parent.width; text: modelData.hint; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 9; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                                                }
                                                MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.addWidget(modelData.id) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ================================================= right: the controls
                Flickable {
                    id: ctl
                    Layout.fillHeight: true
                    Layout.preferredWidth: 470
                    contentWidth: width
                    contentHeight: cc.implicitHeight + 8
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    visible: root.cur !== null

                    ColumnLayout {
                        id: cc
                        width: ctl.width - 12
                        spacing: 12

                        // ---- show / hide this one (switched off: not drawn, nothing runs for it, it stays here to switch on again)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "Show this widget on the desktop"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium; elide: Text.ElideRight }
                            Toggle { pal: root.pal; on: root.cur !== null && root.cur.off !== true; onToggled: root.edit(WD.setOff(root.layout, root.sel, root.cur !== null && root.cur.off !== true), false) }
                        }

                        // ---- layout
                        NbCap { pal: root.pal; text: "LAYOUT" }
                        ChipRow {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Style"; labelWidth: 90
                            options: root.curType ? root.curType.styles : []
                            current: root.cur ? WD.styleOf(root.cur) : ""
                            onPicked: id => root.setStyle(id)
                        }

                        // ---- options of this kind of widget
                        NbCap { visible: root.curType !== null && root.curType.opts.length > 0; pal: root.pal; text: "OPTIONS" }
                        Repeater {
                            model: root.curType ? root.curType.opts : []
                            delegate: Loader {
                                id: ol
                                required property var modelData
                                Layout.fillWidth: true
                                readonly property var o: modelData
                                readonly property var val: (root.cur && root.cur.opts && root.cur.opts[o.k] !== undefined) ? root.cur.opts[o.k] : o.def
            Component {
                id: oToggle
                RowLayout {
                    spacing: 10
                    Text { Layout.fillWidth: true; text: ol.o.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                    Toggle { pal: root.pal; on: ol.val === true; onToggled: root.setOptV(ol.o.k, !(ol.val === true), false) }
                }
            }
            Component {
                id: oChips
                ChipRow {
                    pal: root.pal; label: ol.o.label; labelWidth: 90
                    options: ol.o.options
                    current: ol.val
                    onPicked: id => root.setOptV(ol.o.k, id, false)
                }
            }
            Component {
                id: oSlider
                NbSlider {
                    pal: root.pal; label: ol.o.label; from: ol.o.min; to: ol.o.max; unit: ol.o.unit
                    value: Math.round(Number(ol.val))
                    onPicked: v => root.setOptV(ol.o.k, v, true)
                }
            }
            Component {
                id: oMulti
                Column {
                    spacing: 6
                    Text { text: ol.o.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                    Flow {
                        width: parent.width
                        spacing: 8
                        Repeater {
                            model: ol.o.options
                            delegate: Chip {
                                required property var modelData
                                pal: root.pal; implicitHeight: 30; label: modelData[1]
                                on: (ol.val || []).indexOf(modelData[0]) >= 0
                                onClicked: root.toggleIn(ol.o.k, modelData[0])
                            }
                        }
                    }
                }
            }
            Component {
                id: oText
                Column {
                    spacing: 6
                    Text { text: ol.o.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                    WbText {
                        width: parent.width
                        pal: root.pal; text: String(ol.val); hintText: ol.o.hintText || ""
                        onCommitted: t => root.setOptV(ol.o.k, t, false)
                    }
                }
            }
                                sourceComponent: o.kind === "toggle" ? oToggle : (o.kind === "chips" ? oChips : (o.kind === "slider" ? oSlider : (o.kind === "multi" ? oMulti : oText)))
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- size and place
                        NbCap { pal: root.pal; text: "SIZE AND PLACE" }
                        NbSlider {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Size"; from: 50; to: 250; unit: " %"
                            value: Math.round((root.cur ? root.cur.scale : 1) * 100)
                            onPicked: v => root.edit(WD.setScale(root.layout, root.sel, v / 100), true)
                        }
                        ChipRow {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Put it at"; labelWidth: 90
                            options: WD.spots.map(function (s) { return [s[0], s[1]] })
                            current: ""
                            onPicked: id => root.edit(WD.placeAt(root.layout, root.sel, id), false)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "For an exact spot, use \"Place them on the desktop\": drag it there, the wheel resizes it."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- link: follow another widget
                        Row {
                            spacing: 6
                            NbCap { pal: root.pal; text: "LINK"; anchors.verticalCenter: parent.verticalCenter }
                            HelpTip {
                                id: qLink
                                pal: root.pal
                                onHoveredChanged: root.setTip(qLink, hovered)
                                anchors.verticalCenter: parent.verticalCenter
                                tip: "Link makes this widget follow another one, for example uptime next to the workspaces. It takes the other widget's size and keeps a fixed gap from it. When one of them gets wider (\"9h\" turning into \"1d 11h\") the linked one is pushed along instead of being covered. Drag or resize either one on the desktop and both move together. Two or more widgets can follow the same one: on the same side of it they line up one after the other."
                            }
                        }
                        ChipRow {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Follow"; labelWidth: 90
                            options: root.linkOptions
                            current: root.curLinkTo
                            onPicked: id => root.setLinkTo(id)
                        }
                        ChipRow {
                            Layout.fillWidth: true
                            visible: root.curLinkTo !== ""
                            pal: root.pal; label: "Sits"; labelWidth: 90
                            HelpTip {
                                id: qSide
                                pal: root.pal
                                onHoveredChanged: root.setTip(qSide, hovered)
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: 8
                                tip: "Which side of the widget it follows this one stays on. Below it / Above it: stacked, same left edge, and both become as wide as the wider of the two. Right of it / Left of it: side by side and centred on each other; each keeps its own width, so one that grows pushes the other along. Gap is the space between them."
                            }
                            options: [["below", "Below it"], ["above", "Above it"], ["right", "Right of it"], ["left", "Left of it"]]
                            current: root.curLinkSide
                            onPicked: id => root.setLinkV(id, root.curLinkGap, false)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            visible: root.curLinkTo !== ""
                            pal: root.pal; label: "Gap"; from: 0; to: 80; unit: " px"
                            value: root.curLinkGap
                            onPicked: v => root.setLinkV(root.curLinkSide, v, true)
                        }
                        // another widget follows the same one on the same side: they stand in a line, this says who comes first
                        ChipRow {
                            Layout.fillWidth: true
                            visible: root.curLinkTo !== "" && root.curSiblings.length > 1
                            pal: root.pal; label: "Place in line"; labelWidth: 90
                            options: root.slotOptions
                            current: root.curSlot
                            onPicked: id => root.setLinkSlot(id)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.curLinkTo === "" ? "Link a widget to another one, for example uptime to the workspaces. Put it above / below (stacked, same width) or right / left (side by side, each its own width) and it keeps the gap you set, even when the other one grows. Move or resize one on the desktop and the other goes with it."
                                                        : "Linked: this widget takes the size of the one it follows and moves with it (stacked ones also share its width). On the desktop, drag or resize the one it follows (the Size slider above no longer applies here)."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- the look
                        NbCap { pal: root.pal; text: "LOOK" }
                        ChipRow {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Box"; labelWidth: 90
                            options: WD.surfaces
                            current: root.curLook.surface
                            onPicked: id => root.setLookV("surface", id)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            visible: root.curLook.surface !== "clear"
                            pal: root.pal; label: "Box opacity"; from: 0; to: 100; unit: " %"
                            value: Math.round(root.curLook.op * 100)
                            onPicked: v => root.setLookV("op", v / 100, true)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            visible: root.curLook.surface !== "clear" && root.curLook.surface !== "pill"
                            pal: root.pal; label: "Corners"; from: 0; to: 60; unit: " px"; zeroText: "Auto"
                            value: root.curLook.radius < 0 ? 0 : root.curLook.radius
                            onPicked: v => root.setLookV("radius", v === 0 ? -1 : v, true)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Inner space"; from: 0; to: 48; unit: " px"; zeroText: "Auto"
                            value: root.curLook.pad < 0 ? 0 : root.curLook.pad
                            onPicked: v => root.setLookV("pad", v === 0 ? -1 : v, true)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Text size"; from: 60; to: 180; unit: " %"
                            value: Math.round(root.curLook.fs * 100)
                            onPicked: v => root.setLookV("fs", v / 100, true)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Colour depth"; from: 0; to: 100; unit: " %"; zeroText: "Plain"
                            value: Math.round(root.curLook.depth * 100)
                            onPicked: v => root.setLookV("depth", v / 100, true)
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Readability"; from: 0; to: 100; unit: " %"; zeroText: "Off"
                            value: Math.round(root.curLook.contrast * 100)
                            onPicked: v => root.setLookV("contrast", v / 100, true)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Colour depth tints the box, bars and quiet text with the wallpaper accent. Readability brightens the colours and outlines each letter; \"No box\" never gets a backing."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                        ChipRow {
                            Layout.fillWidth: true
                            pal: root.pal; label: "Font"; labelWidth: 90
                            options: [["ui", "Clean"], ["serif", "Serif"], ["mono", "Code"]]
                            current: root.curLook.font
                            onPicked: id => root.setLookV("font", id)
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "Match wallpaper accent"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; elide: Text.ElideRight }
                            Toggle { pal: root.pal; on: root.curLook.match; onToggled: root.setLookV("match", !root.curLook.match) }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            ActionChip { Layout.fillWidth: true; Layout.preferredWidth: 1; pal: root.pal; label: "Match on all"; onClicked: root.edit(WD.setLookAll(root.layout, "match", true), false) }
                            ActionChip { Layout.fillWidth: true; Layout.preferredWidth: 1; pal: root.pal; label: "Off on all"; onClicked: root.edit(WD.setLookAll(root.layout, "match", false), false) }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.curLook.match ? "On: the lit colour, the text and the box tint all follow the wallpaper accent and change with the wallpaper. The colour pickers are hidden while this is on."
                                                     : "Turn on to make the colours of this widget follow the wallpaper accent (text, bars and box). \"Match on all\" does it for every widget at once."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }
                        ChipRow {
                            Layout.fillWidth: true
                            visible: !root.curLook.match
                            pal: root.pal; label: "Lit colour"; labelWidth: 90
                            options: WD.tones
                            current: root.curLook.tone
                            onPicked: id => root.setLookV("tone", id)
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.curLook.tone === "custom" && !root.curLook.match
                            spacing: 8
                            Item { Layout.preferredWidth: 90; height: 1 }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: WD.swatches
                                    delegate: Rectangle {
                                        required property string modelData
                                        width: 26; height: 26; radius: 13; color: modelData
                                        border.width: root.curLook.color.toLowerCase() === modelData ? 3 : 1
                                        border.color: root.curLook.color.toLowerCase() === modelData ? root.pal.text : root.pal.line
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setLookV("color", parent.modelData) }
                                    }
                                }
                                WbText {
                                    pal: root.pal; width: 110; height: 28; radius: 14
                                    text: root.curLook.color; hintText: "#rrggbb"
                                    onCommitted: t => { if (/^#[0-9a-fA-F]{6}$/.test(t)) root.setLookV("color", t.toLowerCase()) }
                                }
                            }
                        }
                        ChipRow {
                            Layout.fillWidth: true
                            visible: !root.curLook.match
                            pal: root.pal; label: "Text colour"; labelWidth: 90
                            options: [["theme", "Theme"], ["light", "White"], ["dark", "Dark"], ["custom", "My colour"]]
                            current: root.curLook.textTone
                            onPicked: id => root.setLookV("textTone", id)
                        }
                        WbText {
                            Layout.fillWidth: true
                            visible: root.curLook.textTone === "custom" && !root.curLook.match
                            pal: root.pal; text: root.curLook.textColor; hintText: "#rrggbb"
                            onCommitted: t => { if (/^#[0-9a-fA-F]{6}$/.test(t)) root.setLookV("textColor", t.toLowerCase()) }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "Hairline edge"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Toggle { pal: root.pal; on: root.curLook.border; onToggled: root.setLookV("border", !root.curLook.border) }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "Soft shadow"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Toggle { pal: root.pal; on: root.curLook.shadow; onToggled: root.setLookV("shadow", !root.curLook.shadow) }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- styles: ready-made and your own
                        NbCap { pal: root.pal; text: "STYLES" }
                        Text {
                            Layout.fillWidth: true
                            text: "Pick one to give this widget that look (box, colours, font, text size). Make your own above, then save it here to reuse on any widget."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {
                                model: WD.presets
                                delegate: Chip { required property var modelData; pal: root.pal; implicitHeight: 30; label: modelData.name; onClicked: root.applyStyleLook(modelData.look) }
                            }
                        }
                        NbCap { visible: root.saved.length > 0; pal: root.pal; text: "YOURS" }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {
                                model: root.saved
                                delegate: Row {
                                    required property var modelData
                                    spacing: 4
                                    Chip { pal: root.pal; implicitHeight: 30; label: modelData.name; on: true; onClicked: root.applyStyleLook(modelData.look) }
                                    Rectangle {
                                        width: 30; height: 30; radius: 15; color: dm.containsMouse ? Qt.alpha(root.pal.bad, 0.3) : Qt.alpha(root.pal.surface, 0.8); border.width: 1; border.color: root.pal.lineSoft
                                        Text { anchors.centerIn: parent; text: "✕"; color: root.pal.text; font.pixelSize: 11 }
                                        MouseArea { id: dm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.dropStyle(parent.parent.modelData.name) }
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            WbText { Layout.fillWidth: true; pal: root.pal; text: root.newName; hintText: "Name for this look"; onCommitted: t => root.newName = t }
                            ActionChip { pal: root.pal; label: "Save this look"; doneLabel: "Saved"; disabled: root.newName.trim() === ""; onClicked: root.saveStyle() }
                        }
                        Item { Layout.fillWidth: true; height: 8 }
                    }
                }
                Item { visible: root.cur === null; Layout.preferredWidth: 470; Layout.fillHeight: true }
            }
        }

        // the one bubble every "?" shows
        Rectangle {
            z: 40
            visible: root.tipItem !== null
            width: Math.min(320, card.width - 40)
            height: tipBody.implicitHeight + 22
            radius: root.pal.rMd
            color: Qt.alpha(root.pal.bg, 0.98)
            border.width: 1
            border.color: Qt.alpha(root.pal.accent, 0.5)
            x: Math.max(12, Math.min(card.width - width - 12, root.tipCx - width / 2))
            y: root.tipBottom + 10 + height > card.height - 8 ? root.tipTop - height - 10 : root.tipBottom + 10
            Text {
                id: tipBody
                x: 12; y: 11
                width: parent.width - 24
                text: root.tipText
                wrapMode: Text.WordWrap
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap + 1
                lineHeight: 1.15
            }
        }
    }
}
