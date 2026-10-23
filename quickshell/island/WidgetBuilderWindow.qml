import QtQuick
import QtQuick.Effects
import Quickshell.Widgets
import QtQuick.Layouts
import "WidgetData.js" as WD

// The widget builder window (Settings > Appearance > Widget builder, or `widget-builder`). It is about ONE widget at a time:
//   Left:    your widgets (click one to work on it) and "Add a widget" with every kind there is.
//   Middle:  the picked widget, life size, exactly as it will look on the desktop.
//   Right:   its layout (style), its options, its size, its look (box, colours, font, text size), saved styles of your own,
//            and a quick place on the screen. Where everything sits overall is the Desktop builder's job.
// Every change is saved and shows on the real desktop at once (changed("deskWidgets", layout) / changed("deskStyles", list)).
// The switch in the header picks WHICH screen's widgets you shape: the desktop's (opt.deskWidgets) or the lock screen's (opt.lockDeskWidgets, only the
// types WidgetData.js allows there). The saved looks (deskStyles) are shared by both.
Item {
    id: root
    property var pal
    property var env
    property bool open: false
    property var opt: ({})
    property string wallpaper: ""              // the wallpaper on screen: the preview shows the widget over it (dimmed like the desktop)
    // behind the preview: wall (the wallpaper as the desktop shows it) | soft (blurred and darker, so the widget reads) | plain
    readonly property string pvBack: (opt && opt.wbPreviewBack) || "soft"
    signal changed(string key, var value)
    signal closed()
    signal editOnDesktop(string which)         // which = "desktop" or "lock": the screen to place the widgets on
    signal targetPicked(string t)
    property string target: "desktop"          // "desktop" or "lock" (Settings wbTarget)
    readonly property bool lockT: target === "lock"
    readonly property string lkey: WD.keyOf(target)          // the settings key of this screen's list

    // the newest layout a slider made that the 70 ms timer has not sent yet: every edit starts from it, so a click right after a slider
    // does not start from the old layout (and then get overwritten when the timer sends the slider's value)
    property var livePending: null
    readonly property var layout: WD.normalizeFor(livePending !== null ? livePending : (opt ? opt[lkey] : null), target)
    readonly property var saved: (opt && opt.deskStyles && opt.deskStyles.length !== undefined) ? opt.deskStyles : []
    property string sel: ""
    property string tab: "content"        // the right column's tab: content | place | look | styles
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
    // the other screen's list: send what a slider had waiting (it still carries its own key), then start on that list's first widget
    onTargetChanged: { flushLive(); livePending = null; adding = false; sel = layout.items.length ? layout.items[0].uid : "" }
    Component.onCompleted: if (sel === "" && layout.items.length) sel = layout.items[0].uid

    // sliders send a value for every pixel: pass the first at once, then at most one every 70 ms, ending on the last
    property var pending: ({})
    function send(k, v) { if (k === root.lkey) livePending = null; root.changed(k, v) }
    function put(k, v) {
        if (k === root.lkey) { var p0 = pending; delete p0[root.lkey]; pending = p0 }      // this newer layout replaces a waiting one
        send(k, v)
    }
    function putLive(k, v) {
        if (liveT.running) { var p = pending; p[k] = v; pending = p; if (k === root.lkey) livePending = v; return }
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

    function edit(l, live) { if (live) putLive(root.lkey, l); else put(root.lkey, l) }
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
        border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)
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
                BoxTitle {
                    Layout.alignment: Qt.AlignVCenter
                    pal: root.pal
                    size: 20
                    subIsHint: true
                    title: "Widget builder"
                    sub: root.lockT ? "Your lock screen's widgets. Nothing on them can be clicked while it is locked." : "Pick a widget on the left, shape it on the right."
                }
                SegSwitch {
                    Layout.alignment: Qt.AlignVCenter
                    pal: root.pal
                    options: [{ k: "desktop", t: "Desktop" }, { k: "lock", t: "Lock screen" }]
                    current: root.target
                    onPicked: k => root.targetPicked(k)
                }
                ActionChip { pal: root.pal; label: root.lockT ? "Place them on the lock screen" : "Place them on the desktop"; onClicked: root.editOnDesktop(root.target) }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 22

                // ================================================= left: the list
                Rectangle {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 260
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.35)
                    border.width: root.pal.calm ? 0 : 1; border.color: root.pal.lineTint

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10
                        Text { text: "Your widgets  ·  " + root.layout.items.length; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 12; font.weight: Font.Medium }
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
                                    text: root.lockT ? "Nothing on the lock screen yet. Add a widget below." : "Nothing on the desktop yet. Add a widget below."
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
                                        width: lst.width; height: hdr + 48
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
                                            width: rowD.width - x; height: 44; radius: 12
                                            color: rowD.on ? Qt.alpha(root.pal.accent, 0.18) : (lm.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.8) : Qt.alpha(root.pal.surface, 0.5))
                                            border.width: root.pal.calm ? 0 : 1; border.color: rowD.on ? Qt.alpha(root.pal.accent, 0.5) : (rowD.grouped ? Qt.alpha(rowD.grpCol, 0.35) : root.pal.lineSoft)
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
                            Text { Layout.fillWidth: true; text: root.lockT ? "All lock screen widgets" : "All desktop widgets"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; elide: Text.ElideRight }
                            Toggle { pal: root.pal; on: WD.isOn(root.opt, root.target); onToggled: root.put(WD.onKeyOf(root.target), !WD.isOn(root.opt, root.target)) }
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
                    border.width: root.pal.calm ? 0 : 1; border.color: root.pal.lineTint
                    clip: true
                    Rectangle {
                        z: 5
                        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 14
                        width: capT.implicitWidth + 20; height: 24; radius: 12
                        color: Qt.alpha(root.pal.bg, 0.7)
                        Text { id: capT; anchors.centerIn: parent; text: root.adding ? "Add a widget" : "Live preview · life size"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11 }
                    }

                    // the backdrop: your wallpaper, dimmed the way the desktop dims it (Settings > Widget builder > Dim the wallpaper),
                    // so the preview shows the widget as it really sits; a soft accent wash when there is no picture
                    Rectangle {
                        anchors.fill: parent; anchors.margins: 1; radius: root.pal.rLg
                        visible: !root.adding
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.alpha(root.pal.accent, 0.10) }
                            GradientStop { position: 1; color: Qt.alpha(root.pal.accent2, 0.06) }
                        }
                    }
                    // (rounded like the box it sits in; Softened blurs and darkens it so the widget stands out, and the
                    //  colours you are matching still show through; Plain leaves the picture out)
                    ClippingRectangle {
                        anchors.fill: parent; anchors.margins: 1
                        radius: Math.max(0, stage.radius - 1)
                        color: "transparent"
                        visible: !root.adding && root.wallpaper !== "" && !root.lockT && wallPv.status === Image.Ready && root.pvBack !== "plain"
                        Image {
                            id: wallPv
                            anchors.fill: parent
                            layer.enabled: root.pvBack === "soft"
                            layer.effect: MultiEffect { blurEnabled: true; blurMax: 48; blur: 0.75; saturation: -0.15; autoPaddingEnabled: false }
                            source: root.wallpaper !== "" && root.open ? "file://" + encodeURI(root.wallpaper).replace(/#/g, "%23").replace(/\?/g, "%3F") : ""
                            sourceSize: Qt.size(Math.max(1, Math.round(width)), Math.max(1, Math.round(height)))
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                        }
                        Rectangle {
                            anchors.fill: parent
                            color: "black"
                            readonly property string mode: (root.opt && root.opt.widgetDim) || "wall"
                            opacity: (mode === "off" ? 0.08 : Math.max(0.1, Math.min(0.8, root.opt && root.opt.widgetDimAmt !== undefined ? Number(root.opt.widgetDimAmt) : 0.35)))
                                     + (root.pvBack === "soft" ? 0.22 : 0)
                        }
                    }
                    // what is behind the preview
                    Row {
                        z: 6
                        visible: !root.adding && root.wallpaper !== "" && !root.lockT
                        anchors { top: parent.top; right: parent.right; margins: 12 }
                        spacing: 2
                        Rectangle {
                            width: pbRow.implicitWidth + 8; height: 30; radius: 15
                            color: Qt.alpha(root.pal.bg, 0.72)
                            Row {
                                id: pbRow
                                anchors.centerIn: parent
                                spacing: 2
                                Repeater {
                                    model: [["wall", "Wallpaper"], ["soft", "Softened"], ["plain", "Plain"]]
                                    delegate: Rectangle {
                                        id: pbB
                                        required property var modelData
                                        readonly property bool on: root.pvBack === modelData[0]
                                        width: pbT.implicitWidth + 20; height: 24; radius: 12
                                        color: on ? Qt.alpha(root.pal.accent, 0.22) : (pbMa.containsMouse ? Qt.alpha(root.pal.text, 0.08) : "transparent")
                                        Text { id: pbT; anchors.centerIn: parent; text: pbB.modelData[1]; color: pbB.on ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; font.weight: pbB.on ? Font.DemiBold : Font.Normal }
                                        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.changed("wbPreviewBack", pbB.modelData[0]) }
                                    }
                                }
                            }
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
                            // a linked widget is previewed in its group's colours (the group's area is not known here: the whole picture is)
                            leadLook: root.cur && root.curLook.groupColours && WD.linkRoot(root.layout, root.sel) !== root.sel ? (WD.find(root.layout, WD.linkRoot(root.layout, root.sel)) || {}).look || {} : null
                            groupHosts: leadLook !== null ? [pv, pv] : []
                            preview: true
                            inert: root.lockT
                            lockLum: (root.lockT && root.env && root.env.lockBackLum !== undefined) ? root.env.lockBackLum : -1
                            shown: root.open
                        }
                    }
                    Text {
                        visible: !root.adding && root.cur === null
                        anchors.centerIn: parent
                        text: "Add a widget to start"
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle
                    }
                    // (the kind's hint now sits under "Layout" in the Content tab)

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
                            Text {
                                visible: root.lockT
                                width: cat.width
                                wrapMode: Text.WordWrap
                                text: "Every widget works here too, but nothing on them can be clicked or run while the screen is locked. Marked private (anyone at your locked computer can read them): " + WD.lockPrivateNames() + "."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                            }
                            Repeater {
                                model: WD.cats
                                delegate: Column {
                                    id: catGroup
                                    required property var modelData
                                    readonly property var kinds: WD.catalog.filter(function (t) { return t.cat === modelData[0] })
                                    visible: kinds.length > 0
                                    width: cat.width
                                    spacing: 8
                                    NbCap { pal: root.pal; text: modelData[1].toUpperCase() }
                                    Flow {
                                        width: parent.width
                                        spacing: 8
                                        Repeater {
                                            model: catGroup.kinds
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
                                                    Text {
                                                        width: parent.width
                                                        readonly property string priv: root.lockT ? WD.lockPrivateOf(modelData.id) : ""
                                                        text: priv !== "" ? "Private: " + priv : modelData.hint
                                                        color: priv !== "" ? root.pal.warn : root.pal.muted
                                                        font.family: root.pal.uiFont; font.pixelSize: 9; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                                                    }
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

                // ================================================= right: the controls, in four calm tabs
                ColumnLayout {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 480
                    Layout.maximumWidth: 480
                    visible: root.cur !== null
                    spacing: 14

                    // the widget's name and its show / hide switch, then the tabs
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { text: root.cur ? String.fromCodePoint(WD.iconOf(root.cur.type)) : ""; color: root.pal.accent; font.family: root.pal.font; font.pixelSize: 22 }
                        Column {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: root.cur ? WD.nameOf(root.cur.type) : ""; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 16; font.weight: Font.DemiBold }
                            Text { text: root.cur && root.cur.off === true ? "Switched off: not drawn, nothing runs for it" : (root.lockT ? "Shown on the lock screen" : "Shown on the desktop"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11 }
                        }
                        Toggle { pal: root.pal; on: root.cur !== null && root.cur.off !== true; onToggled: root.edit(WD.setOff(root.layout, root.sel, root.cur !== null && root.cur.off !== true), false) }
                    }
                    SegSwitch {
                        Layout.fillWidth: true
                        pal: root.pal
                        options: [{ k: "content", t: "Content" }, { k: "place", t: "Place" }, { k: "look", t: "Look" }, { k: "styles", t: "Styles" }]
                        current: root.tab
                        onPicked: k => { root.tab = k; ctl.contentY = 0 }
                    }

                    Flickable {
                        id: ctl
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: cc.implicitHeight + 8
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        ColumnLayout {
                            id: cc
                            width: ctl.width - 10
                            spacing: 14

                            // ======================= Content: what it shows
                            WbSection {
                                visible: root.tab === "content"
                                pal: root.pal; title: "Layout"; sub: root.curType ? root.curType.hint : ""
                                ChipRow {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Style"; labelWidth: 84
                                    options: root.curType ? root.curType.styles : []
                                    current: root.cur ? WD.styleOf(root.cur) : ""
                                    onPicked: id => root.setStyle(id)
                                }
                            }
                            WbSection {
                                visible: root.tab === "content" && root.curType !== null && root.curType.opts.length > 0
                                pal: root.pal; title: "What it shows"
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
                                                spacing: 14
                                                Text { Layout.fillWidth: true; text: ol.o.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; wrapMode: Text.WordWrap; lineHeight: 1.15 }
                                                Toggle { Layout.alignment: Qt.AlignVCenter; pal: root.pal; on: ol.val === true; onToggled: root.setOptV(ol.o.k, !(ol.val === true), false) }
                                            }
                                        }
                                        Component {
                                            id: oChips
                                            ChipRow {
                                                pal: root.pal; label: ol.o.label; labelWidth: 84
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
                                                spacing: 8
                                                Text { width: parent.width; text: ol.o.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; wrapMode: Text.WordWrap }
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
                                                spacing: 8
                                                Text { width: parent.width; text: ol.o.label; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; wrapMode: Text.WordWrap }
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
                            }

                            // ======================= Place: size, spot, link
                            WbSection {
                                visible: root.tab === "place"
                                pal: root.pal; title: "Size and spot"
                                sub: root.curLinkTo !== "" ? "Linked: it moves and sizes with the widget it follows. Drag that one on the desktop." : "Pick a spot on the little screen, or use \"" + (root.lockT ? "Place them on the lock screen" : "Place them on the desktop") + "\" for an exact one."
                                NbSlider {
                                    Layout.fillWidth: true
                                    enabled: root.curLinkTo === ""
                                    opacity: enabled ? 1 : 0.45
                                    pal: root.pal; label: "Size"; from: 50; to: 250; unit: " %"
                                    value: Math.round((root.cur ? root.cur.scale : 1) * 100)
                                    onPicked: v => root.edit(WD.setScale(root.layout, root.sel, v / 100), true)
                                }
                                // the nine spots as a small screen (16:10)
                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: root.curLinkTo === ""
                                    width: 240; height: 150; radius: 14
                                    color: Qt.alpha(root.pal.bg, 0.5)
                                    border.width: root.pal.calm ? 0 : 1; border.color: root.pal.lineSoft
                                    Grid {
                                        anchors.fill: parent; anchors.margins: 10
                                        columns: 3; spacing: 6
                                        Repeater {
                                            model: WD.spots
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: (240 - 20 - 12) / 3; height: (150 - 20 - 12) / 3; radius: 9
                                                color: spm.containsMouse ? Qt.alpha(root.pal.accent, 0.25) : Qt.alpha(root.pal.surface, 0.55)
                                                border.width: 1; border.color: spm.containsMouse ? Qt.alpha(root.pal.accent, 0.6) : "transparent"
                                                Behavior on color { ColorAnimation { duration: 120 } }
                                                Rectangle { anchors.centerIn: parent; width: 14; height: 6; radius: 3; color: spm.containsMouse ? root.pal.accent : Qt.alpha(root.pal.muted, 0.6) }
                                                MouseArea { id: spm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.edit(WD.placeAt(root.layout, root.sel, parent.modelData[0]), false) }
                                                HoverHandler { onHoveredChanged: if (hovered) spotTip.text = parent.modelData[1] }
                                            }
                                        }
                                    }
                                }
                                Text { id: spotTip; Layout.alignment: Qt.AlignHCenter; visible: root.curLinkTo === ""; text: "Click a spot"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11 }
                            }
                            WbSection {
                                visible: root.tab === "place"
                                pal: root.pal; title: "Link"
                                sub: root.curLinkTo === "" ? "Make it follow another widget, e.g. uptime next to the workspaces: same size, a fixed gap, and it is pushed along when the other one grows."
                                                           : "It takes the size of the widget it follows and moves with it."
                                ChipRow {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Follow"; labelWidth: 84
                                    options: root.linkOptions
                                    current: root.curLinkTo
                                    onPicked: id => root.setLinkTo(id)
                                }
                                ChipRow {
                                    Layout.fillWidth: true
                                    visible: root.curLinkTo !== ""
                                    pal: root.pal; label: "Sits"; labelWidth: 84
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
                                ChipRow {
                                    Layout.fillWidth: true
                                    visible: root.curLinkTo !== "" && root.curSiblings.length > 1
                                    pal: root.pal; label: "In line"; labelWidth: 84
                                    options: root.slotOptions
                                    current: root.curSlot
                                    onPicked: id => root.setLinkSlot(id)
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: root.curLinkTo !== ""
                                    spacing: 14
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text { width: parent.width; text: "Same colours as its group"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        Text { width: parent.width; text: "Takes the colours of the first widget of the group and reads the wallpaper behind the whole group, so linked widgets never split into different colours."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.15 }
                                    }
                                    Toggle { pal: root.pal; on: root.curLook.groupColours; onToggled: root.setLookV("groupColours", !root.curLook.groupColours) }
                                }
                            }

                            // ======================= Look: box, text, colour, finish
                            WbSection {
                                visible: root.tab === "look"
                                pal: root.pal; title: "Box"
                                ChipRow {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Kind"; labelWidth: 84
                                    options: WD.surfaces
                                    current: root.curLook.surface
                                    onPicked: id => root.setLookV("surface", id)
                                }
                                NbSlider {
                                    Layout.fillWidth: true
                                    visible: root.curLook.surface !== "clear"
                                    pal: root.pal; label: "Opacity"; from: 0; to: 100; unit: " %"
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
                            }
                            WbSection {
                                visible: root.tab === "look"
                                pal: root.pal; title: "Text"
                                ChipRow {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Font"; labelWidth: 84
                                    options: [["ui", "Clean"], ["serif", "Serif"], ["mono", "Code"]]
                                    current: root.curLook.font
                                    onPicked: id => root.setLookV("font", id)
                                }
                                NbSlider {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Size"; from: 60; to: 180; unit: " %"
                                    value: Math.round(root.curLook.fs * 100)
                                    onPicked: v => root.setLookV("fs", v / 100, true)
                                }
                                NbSlider {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Readability"; from: 0; to: 100; unit: " %"; zeroText: "Off"
                                    value: Math.round(root.curLook.contrast * 100)
                                    onPicked: v => root.setLookV("contrast", v / 100, true)
                                }
                            }
                            WbSection {
                                visible: root.tab === "look"
                                pal: root.pal; title: "Colour"
                                sub: root.curLinkTo !== "" && root.curLook.groupColours ? "This widget uses its group's colours (Place > Link). Switch that off to colour it on its own." : ""
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 14
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text { width: parent.width; text: "Follow the wallpaper accent"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        Text { width: parent.width; text: "Text, bars and box change with every wallpaper."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap }
                                    }
                                    Toggle { pal: root.pal; on: root.curLook.match; onToggled: root.setLookV("match", !root.curLook.match) }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    ActionChip { Layout.fillWidth: true; Layout.preferredWidth: 1; pal: root.pal; label: "Follow on all"; onClicked: root.edit(WD.setLookAll(root.layout, "match", true), false) }
                                    ActionChip { Layout.fillWidth: true; Layout.preferredWidth: 1; pal: root.pal; label: "Off on all"; onClicked: root.edit(WD.setLookAll(root.layout, "match", false), false) }
                                }
                                ChipRow {
                                    Layout.fillWidth: true
                                    visible: !root.curLook.match
                                    pal: root.pal; label: "Lit colour"; labelWidth: 84
                                    options: WD.tones
                                    current: root.curLook.tone
                                    onPicked: id => root.setLookV("tone", id)
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    visible: root.curLook.tone === "custom" && !root.curLook.match
                                    spacing: 8
                                    Repeater {
                                        model: (root.pal.swatches || []).slice(0, 8).map(function (c) { return String(c).toLowerCase() }).concat(WD.swatches)
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
                                ChipRow {
                                    Layout.fillWidth: true
                                    visible: !root.curLook.match
                                    pal: root.pal; label: "Text colour"; labelWidth: 84
                                    options: [["theme", "Theme"], ["auto", "Auto"], ["accent", "Accent"], ["second", "Second"], ["split", "Split"], ["light", "White"], ["dark", "Dark"], ["custom", "My colour"]]
                                    current: root.curLook.textTone
                                    onPicked: id => root.setLookV("textTone", id)
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    visible: root.curLook.textTone === "custom" && !root.curLook.match
                                    spacing: 8
                                    Repeater {
                                        model: (root.pal.swatches || []).slice(0, 8).map(function (c) { return String(c).toLowerCase() }).concat(WD.swatches)
                                        delegate: Rectangle {
                                            required property string modelData
                                            width: 26; height: 26; radius: 13; color: modelData
                                            border.width: root.curLook.textColor.toLowerCase() === modelData ? 3 : 1
                                            border.color: root.curLook.textColor.toLowerCase() === modelData ? root.pal.text : root.pal.line
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setLookV("textColor", parent.modelData) }
                                        }
                                    }
                                    WbText {
                                        pal: root.pal; width: 110; height: 28; radius: 14
                                        text: root.curLook.textColor; hintText: "#rrggbb"
                                        onCommitted: t => { if (/^#[0-9a-fA-F]{6}$/.test(t)) root.setLookV("textColor", t.toLowerCase()) }
                                    }
                                }
                                NbSlider {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Colour depth"; from: 0; to: 100; unit: " %"; zeroText: "Plain"
                                    value: Math.round(root.curLook.depth * 100)
                                    onPicked: v => root.setLookV("depth", v / 100, true)
                                }
                            }
                            WbSection {
                                visible: root.tab === "look"
                                pal: root.pal; title: "Finish"
                                Repeater {
                                    model: [["halo", "Soft dark halo behind the words"], ["border", "Hairline edge"], ["shadow", "Soft shadow"]]
                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 14
                                        Text { Layout.fillWidth: true; text: modelData[1]; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                        Toggle { pal: root.pal; on: root.curLook[modelData[0]] !== false; onToggled: root.setLookV(modelData[0], root.curLook[modelData[0]] === false) }
                                    }
                                }
                            }

                            // ======================= Styles: ready-made and your own
                            WbSection {
                                visible: root.tab === "styles"
                                pal: root.pal; title: "Ready-made"; sub: "One click puts that look on this widget."
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Repeater {
                                        model: WD.presets
                                        delegate: Chip { required property var modelData; pal: root.pal; implicitHeight: 32; label: modelData.name; onClicked: root.applyStyleLook(modelData.look) }
                                    }
                                }
                            }
                            WbSection {
                                visible: root.tab === "styles"
                                pal: root.pal; title: "Yours"; sub: root.saved.length === 0 ? "Shape a look you like, name it and save it to reuse on other widgets." : ""
                                Flow {
                                    Layout.fillWidth: true
                                    visible: root.saved.length > 0
                                    spacing: 8
                                    Repeater {
                                        model: root.saved
                                        delegate: Row {
                                            required property var modelData
                                            spacing: 4
                                            Chip { pal: root.pal; implicitHeight: 32; label: modelData.name; on: true; onClicked: root.applyStyleLook(modelData.look) }
                                            Rectangle {
                                                width: 32; height: 32; radius: 16; color: dm.containsMouse ? Qt.alpha(root.pal.bad, 0.3) : Qt.alpha(root.pal.surface, 0.8); border.width: root.pal.calm ? 0 : 1; border.color: root.pal.lineSoft
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
                            }
                            Item { Layout.fillWidth: true; height: 6 }
                        }
                    }
                }
                Item { visible: root.cur === null; Layout.preferredWidth: 480; Layout.fillHeight: true }
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
