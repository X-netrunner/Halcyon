import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "BarLayout.js" as BL

// The bar builder window (Settings > Bar style > Bar builder > "Open the bar builder"). A dimmed overlay with one card on it.
//
//   The bar: the real bar, drawn the way it looks on the screen (same widgets, same sizes, same spacing, same Notch / Island / Rail shape),
//            with the three places (left, middle, right) built in. It is always drawn lying flat: on a Left / Right bar the three places run
//            from the top of the screen to the bottom (Left = top, Right = bottom) and the widgets stand upright there, as on the screen. Drag a widget along the bar to reorder it, onto another place
//            to move it, onto the shelf to take it off. A light line shows where it will land; a dashed line marks the exact
//            centre of the screen. Click a widget to give it its own padding.
//   Above:   the bar's shape (Notch, Island or Rail), the edge it sits on and the padding numbers: type a number, or use - / +, or leave "auto".
//   Under:   the sizes of the left, middle and right, how a drop would change them, and a suggestion that evens the sides out.
//   Shelf:   the widgets that are not on the bar.
// Every change is saved and shown on the real bar at once.
Item {
    id: root

    property var pal
    property bool open: false
    property var layout: null                  // opt.barLayout (anything: it is cleaned up here)
    property string barPadding: "normal"       // low | normal | high : the real bar height
    property bool spacious: false              // Settings > Bar style > Spacing (what "auto" spacing comes to)
    property string wifiLook: "bars"
    property string btMode: "connected"
    property bool showBatPct: false
    property string sysmode: ""                // for the constellation behind the card (same as the tree and Settings)
    property var starData: null
    property bool profileStars: true
    property bool movingStars: true      // the few stars flying over the card (Settings > Look > Moving stars); the constellations are not drawn here
    signal edited(var layout)
    // Border around the screen (ScreenFrame.qml): the on / off switch, thickness and inner corner radius live here now
    property bool frameOn: false
    property int frameW: 12
    property int frameR: 22
    signal frameEdited(string key, var value)
    signal closed()

    readonly property var cur: BL.normalize(layout)
    readonly property var spare: {
        var out = []
        for (var i = 0; i < BL.catalog.length; i++) if (!BL.placed(cur, BL.catalog[i].id)) out.push(BL.catalog[i].id)
        return out
    }

    // ---------------------------------------------------------------- the bar's numbers (the same formulas as CustomBar.qml)
    readonly property int barH: ({ low: 26, normal: 32, high: 40 })[barPadding] || 32
    readonly property var sp: BL.resolve(cur, barH, spacious)
    readonly property bool isl: cur.shape === "island"
    readonly property bool rail: cur.shape === "rail"
    // a Left / Right bar: the preview is drawn upright, on that edge of a small screen, its three places stacked Top / Middle / Bottom
    readonly property bool vert: BL.isVert(cur.side)
    readonly property string longWord: vert ? "longer" : "wider"
    // what the left and right place are called on this bar (Left / Right, or Top / Bottom on a Left / Right bar)
    readonly property string nameL: BL.zoneTitle(cur, "left")
    readonly property string nameR: BL.zoneTitle(cur, "right")
    readonly property real earR: (isl || rail) ? 0 : Math.round(barH * 0.42)
    readonly property real cornR: isl ? barH / 2 : Math.round(barH * 0.42)
    readonly property int textPx: Math.round(barH * 0.44)
    readonly property int curH: Math.round(textPx * 1.3)
    readonly property int curW: Math.round(curH * 0.55)
    readonly property int offH: Math.round(curH * 0.85)
    readonly property int offW: Math.round(curW * 0.8)
    readonly property int icoH: offH
    readonly property int comboSize: Math.round(barH * 0.78)
    readonly property int gapL: sp.gap
    readonly property int gapC: cur.gap !== null ? cur.gap : sp.autoMidGap
    readonly property int gapR: cur.gap !== null ? cur.gap : sp.autoRightGap
    readonly property int minZone: 76                         // an empty place is shown this wide so there is something to drop on
    readonly property int minZoneV: 120                       // ... and on an upright bar this wide (it has to hold "Middle · drop here")
    readonly property int minZoneH: 56                        // ... and this tall
    // the picture is drawn bigger or smaller to fit the card; every number you read or type is in real screen pixels
    readonly property real zoom: Math.max(0.6, Math.min(1.7, (stage.width - 48) / Math.max(1, barBody.width)))
    // the upright bar is drawn to fit the height of the stage
    readonly property real zoomV: Math.max(0.5, Math.min(1.4, (stage.height - 44) / Math.max(1, vBody.height)))

    readonly property var fakeNet: ({ wifi: "on", ssid: "Home", signal: 80, bt: "on", btdev: "Buds", btn: 1, eth: false })
    readonly property var fakeStats: ({ hasBat: true, bat: 72, charging: false, cpu: 12, memGb: "6.1", mem: 38, temp: 54 })
    readonly property string nowTime: Qt.formatDateTime(new Date(), "hh:mm AP")
    readonly property string nowDate: Qt.formatDateTime(new Date(), "ddd") + "  " + Qt.formatDateTime(new Date(), "d MMM")

    // ---------------------------------------------------------------- sizes and the symmetry help
    function widthOf(id) {
        if (vert) return barH                  // upright: a widget's length along the bar is its height (the padding is added by BL.zoneWidth)
        var ch = meas.children
        for (var i = 0; i < ch.length; i++) if (ch[i].wid === id) return ch[i].width
        return 40
    }
    readonly property real wLeft: BL.zoneWidth(cur, cur.left, widthOf, gapL)
    readonly property real wMid: BL.zoneWidth(cur, cur.center, widthOf, gapC)
    readonly property real wRight: BL.zoneWidth(cur, cur.right, widthOf, gapR)
    readonly property real diffLR: wLeft - wRight
    readonly property var tip: BL.bestMove(cur, widthOf, gapL, gapR, 6)

    function px(v) { return Math.round(v) + " px" }
    // what the sizes would be if the widget in the hand were dropped here
    function dropText() {
        if (hoverZone === "tray") return dragFrom === "tray" ? "" : "Drop to take " + BL.nameOf(dragId) + " off the bar"
        if (hoverZone === "") return "Let go outside the bar and nothing changes"
        var idx = insIdx
        if (dragFrom === hoverZone && dragFromIdx < idx) idx -= 1
        var o = BL.place(cur, dragId, hoverZone, idx)
        var l = BL.zoneWidth(o, o.left, widthOf, gapL), r = BL.zoneWidth(o, o.right, widthOf, gapR)
        var d = Math.round(Math.abs(l - r))
        return "Drop here:  " + nameL + " " + px(l) + "  ·  " + nameR + " " + px(r) + "  ·  " + (d <= 6 ? "✓ the sides match" : d + " px apart")
    }

    // ---------------------------------------------------------------- dragging (pointer driven, so the drop line is ours)
    property string dragId: ""                 // the widget being carried (\"\" = none)
    property string dragFrom: ""               // left | center | right | tray
    property int dragFromIdx: -1
    property real dragX: 0                     // the pointer, in this window's coordinates
    property real dragY: 0
    property string hoverZone: ""              // the place under the pointer: left | center | right | tray | ""
    property int insIdx: 0                     // where it would land in that place
    property real insX: 0                      // the drop line, in the bar's own pixels
    property string hint: ""
    property string selId: ""                  // the widget picked for padding
    readonly property string sel: BL.placed(cur, selId) ? selId : ""

    function zoneItem(k) { if (vert) return k === "left" ? zoneT : (k === "center" ? zoneM : zoneB); return k === "left" ? zoneL : (k === "center" ? zoneC : zoneR) }
    function rowOf(k) { if (vert) return k === "left" ? colT : (k === "center" ? colM : colB); return k === "left" ? rowL : (k === "center" ? rowC : rowR) }
    function gapFor(k) { return k === "left" ? gapL : (k === "center" ? gapC : gapR) }
    function slotsOf(k) {
        var out = [], ch = rowOf(k).children
        for (var i = 0; i < ch.length; i++) if (ch[i].wid !== undefined && ch[i].visible) out.push(ch[i])
        return out
    }
    function inside(item, x, y) {
        var p = item.mapFromItem(root, x, y)
        return p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= item.height
    }
    function aim(zk, px, py) {
        var kids = slotsOf(zk), zi = zoneItem(zk), row = rowOf(zk), g = gapFor(zk)
        if (kids.length === 0) { insIdx = 0; insX = zi.x + zi.width / 2 - 1; return }
        var best = kids[0], bd = 1e12
        for (var i = 0; i < kids.length; i++) {
            var d = Math.abs(px - (zi.x + row.x + kids[i].x + kids[i].width / 2))
            if (d < bd) { bd = d; best = kids[i] }
        }
        var cx = zi.x + row.x + best.x + best.width / 2
        var before = px < cx
        insIdx = best.idx + (before ? 0 : 1)
        insX = zi.x + row.x + (before ? best.x - g / 2 : best.x + best.width + g / 2) - 1
    }
    // the same as aim() for an upright bar: the pointer's height decides where in the column it would land; insX is then the drop line's y
    function aimV(zk, py) {
        var kids = slotsOf(zk), zi = zoneItem(zk), col = rowOf(zk), g = gapFor(zk)
        if (kids.length === 0) { insIdx = 0; insX = zi.y + zi.height / 2 - 1; return }
        var best = kids[0], bd = 1e12
        for (var i = 0; i < kids.length; i++) {
            var d = Math.abs(py - (zi.y + col.y + kids[i].y + kids[i].height / 2))
            if (d < bd) { bd = d; best = kids[i] }
        }
        var cy = zi.y + col.y + best.y + best.height / 2
        var before = py < cy
        insIdx = best.idx + (before ? 0 : 1)
        insX = zi.y + col.y + (before ? best.y - g / 2 : best.y + best.height + g / 2) - 1
    }
    function beginDrag(id, zone, idx, x, y) {
        dragId = id; dragFrom = zone; dragFromIdx = idx
        hint = BL.nameOf(id) + ": " + BL.hintOf(id)
        moveDrag(x, y)
    }
    function moveDrag(x, y) {
        dragX = x; dragY = y
        if (vert) {
            var q = vBody.mapFromItem(root, x, y)
            var zv = ""
            if (q.x >= -34 && q.x <= vBody.width + 34 && q.y >= -16 && q.y <= vBody.height + 16)
                zv = q.y < zoneM.y - 6 ? "left" : (q.y > zoneM.y + zoneM.height + 6 ? "right" : "center")
            else if (inside(wTray, x, y)) zv = "tray"
            hoverZone = zv
            if (zv !== "" && zv !== "tray") aimV(zv, q.y)
            return
        }
        var p = barBody.mapFromItem(root, x, y)
        var z = ""
        if (p.x >= -16 && p.x <= barBody.width + 16 && p.y >= -34 && p.y <= barBody.height + 34)
            z = p.x < zoneC.x - 6 ? "left" : (p.x > zoneC.x + zoneC.width + 6 ? "right" : "center")
        else if (inside(wTray, x, y)) z = "tray"
        hoverZone = z
        if (z !== "" && z !== "tray") aim(z, p.x, p.y)
    }
    function endDrag() { dragId = ""; dragFrom = ""; dragFromIdx = -1; hoverZone = ""; hint = "" }
    function cancelDrag() { endDrag() }
    function dropDrag() {
        var id = dragId, z = hoverZone, idx = insIdx, from = dragFrom, fi = dragFromIdx
        endDrag()
        if (id === "" || z === "") return                       // let go outside: nothing changes
        if (z === "tray") { if (from !== "tray") edited(BL.remove(cur, id)); return }
        if (from === z && fi < idx) idx -= 1                    // it leaves its old spot first
        if (from === z && fi === idx) return
        selId = id
        edited(BL.place(cur, id, z, idx))
    }

    // ---------------------------------------------------------------- the window
    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
    onOpenChanged: { if (open) Qt.callLater(function () { root.forceActiveFocus() }); else { endDrag(); selId = "" } }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })

    Keys.onPressed: function (e) {
        if (e.key === Qt.Key_Escape) {
            if (root.dragId !== "") root.cancelDrag(); else if (root.sel !== "") root.selId = ""; else root.closed()
            e.accepted = true
        }
    }

    // backdrop
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.45)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }

    // ---------------------------------------------------------------- widgets drawn the way the bar draws them (with sample data)
    // The same components the real bar uses; the numbers (time, battery, Wi-Fi ...) are samples, and the widgets that only show
    // sometimes (Caffeine, Focus, Bg apps ...) are shown here all the time so they can be placed.
    Component { id: mWorkspaces
        Row {
            height: root.barH
            spacing: root.gapL
            Repeater {
                model: 5
                delegate: Item {
                    required property int index
                    width: index === 0 ? root.curW : root.offW
                    height: root.barH
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: index === 0 ? root.curH : root.offH
                        radius: width / 2
                        color: index === 0 ? root.pal.accent : (index < 3 ? Qt.alpha(root.pal.accent, 0.36) : Qt.alpha(root.pal.text, 0.14))
                    }
                }
            }
        }
    }
    Component { id: mSpecials
        Row {
            height: root.barH
            spacing: root.gapL
            Repeater {
                model: [0xF04CE, 0xF075A, 0xF04C5]
                delegate: Item {
                    required property int index
                    required property var modelData
                    width: root.icoH + 4
                    height: root.barH
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(parent.modelData)
                        color: parent.index === 0 ? root.pal.accent : Qt.alpha(root.pal.text, 0.5)
                        font.family: root.pal.font
                        font.pixelSize: root.icoH
                    }
                }
            }
        }
    }
    Component { id: mMusic
        Item {
            height: root.barH
            implicitWidth: viz.implicitWidth
            Visualizer { id: viz; y: Math.round((root.barH - height) / 2); pal: root.pal; values: [30, 55, 80, 45, 65, 35]; active: true }
        }
    }
    Component { id: mClock
        Text {
            height: root.barH
            verticalAlignment: Text.AlignVCenter
            text: root.nowTime
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.textPx
            font.weight: Font.DemiBold
        }
    }
    Component { id: mDate
        Text {
            height: root.barH
            verticalAlignment: Text.AlignVCenter
            text: root.nowDate
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: Math.max(10, root.textPx - 2)
        }
    }
    Component { id: mStats
        Row {
            height: root.barH
            spacing: 12
            Repeater {
                model: [ { k: "CPU", v: "12%" }, { k: "RAM", v: "6.1G" }, { k: "TEMP", v: "54°" } ]
                delegate: Row {
                    required property var modelData
                    spacing: 4
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    Text { text: modelData.k; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: modelData.v; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
    }
    Component { id: mStatus
        Item {
            height: root.barH
            implicitWidth: ring.width
            StatusRing {
                id: ring
                anchors.verticalCenter: parent.verticalCenter
                pal: root.pal
                net: root.fakeNet
                stats: root.fakeStats
                tint: root.pal.accent
                size: root.comboSize
                showWifi: true
                showBat: true
                btMode: root.btMode
                showPct: root.showBatPct
                textColor: root.pal.text
                textFont: root.pal.uiFont
                textPx: Math.max(10, root.textPx - 2)
            }
        }
    }
    Component { id: mWifi
        Item {
            height: root.barH
            implicitWidth: wf.width
            WifiIcon { id: wf; anchors.centerIn: parent; pal: root.pal; net: root.fakeNet; look: root.wifiLook; tint: root.pal.accent; offTint: Qt.alpha(root.pal.accent, 0.3); size: root.icoH }
        }
    }
    Component { id: mBluetooth
        Item {
            height: root.barH
            implicitWidth: btT.implicitWidth
            Text { id: btT; anchors.centerIn: parent; text: String.fromCodePoint(0xF00AF); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: root.icoH }
        }
    }
    Component { id: mBattery
        Item {
            id: bat
            height: root.barH
            readonly property int bh: Math.round(root.icoH * 0.8)
            readonly property int bw: Math.round(root.icoH * 1.75)
            implicitWidth: bw + (root.showBatPct ? pctT.implicitWidth + 5 : 0)
            Rectangle {
                y: Math.round((root.barH - bat.bh) / 2)
                width: bat.bw
                height: bat.bh
                radius: height / 2
                antialiasing: true
                color: "transparent"
                border.width: 1.5
                border.color: Qt.alpha(root.pal.accent, 0.85)
                Rectangle {
                    x: 2.5; y: 2.5
                    height: parent.height - 5
                    width: Math.max(height, (parent.width - 5) * 0.72)
                    radius: height / 2
                    antialiasing: true
                    color: root.pal.accent
                }
            }
            Text {
                id: pctT
                visible: root.showBatPct
                x: bat.bw + 5
                height: root.barH
                verticalAlignment: Text.AlignVCenter
                text: "72%"
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: Math.max(10, root.textPx - 2)
                font.weight: Font.Medium
            }
        }
    }
    Component { id: mCaffeine
        Item {
            height: root.barH
            implicitWidth: cafT.implicitWidth
            Text { id: cafT; anchors.centerIn: parent; text: String.fromCodePoint(0xF0176); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: root.icoH }
        }
    }
    Component { id: mNumLock
        Item {
            height: root.barH
            implicitWidth: nlKey.width
            Rectangle {
                id: nlKey
                anchors.verticalCenter: parent.verticalCenter
                width: nlText.implicitWidth + 12
                height: Math.round(root.textPx * 1.35)
                radius: height / 2
                color: root.pal.accent
                Text { id: nlText; anchors.centerIn: parent; text: "123"; color: root.pal.bg; font.family: root.pal.uiFont; font.pixelSize: Math.max(9, root.textPx - 4); font.weight: Font.DemiBold }
            }
        }
    }
    Component { id: mFocus
        Item {
            height: root.barH
            implicitWidth: focusRow.implicitWidth
            Row {
                id: focusRow
                anchors.centerIn: parent
                spacing: 5
                Text { text: String.fromCodePoint(0xF051B); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: root.icoH; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "24:10"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: Math.max(10, root.textPx - 2); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
            }
        }
    }
    Component { id: mBgApps
        Item {
            height: root.barH
            implicitWidth: bgRow.width
            Row {
                id: bgRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Text { text: String.fromCodePoint(0xF003B); color: root.pal.accent; font.family: root.pal.font; font.pixelSize: root.icoH; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "3"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: Math.max(10, root.textPx - 2); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            }
        }
    }
    function mockFor(id) {
        switch (id) {
        case "workspaces": return mWorkspaces
        case "specials": return mSpecials
        case "music": return mMusic
        case "clock": return mClock
        case "date": return mDate
        case "stats": return mStats
        case "status": return mStatus
        case "wifi": return mWifi
        case "bluetooth": return mBluetooth
        case "battery": return mBattery
        case "caffeine": return mCaffeine
        case "numlock": return mNumLock
        case "focus": return mFocus
        case "bgapps": return mBgApps
        }
        return null
    }

    // every widget once, out of sight: their widths are what the sizes and the suggestions are worked out from
    Row {
        id: meas
        visible: false
        Repeater { model: BL.catalog; delegate: BbMock { bb: root; required property var modelData; wid: modelData.id } }
    }





    // ---------------------------------------------------------------- the card
    Glass {
        id: card
        pal: root.pal
        anchors.centerIn: parent
        width: Math.min(parent.width - 120, 1040)
        // as tall as what is in it (it used to be a fixed 780 px with half-empty panels)
        height: Math.min(parent.height - 80, bbCol.implicitHeight + 72)
        radius: root.pal.rXl
        opacityBody: root.pal.solid ? 1 : 0.78
        border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

        // a click on the card must not close the window; it takes the typing focus off a number box
        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }


        ColumnLayout {
            id: bbCol
            anchors.fill: parent
            anchors.margins: 36
            spacing: 20

            // ---- header (WinHeader: the same in every window)
            WinHeader {
                pal: root.pal
                title: "Bar builder"
                leading: [ ActionChip { pal: root.pal; label: "Reset layout"; doneLabel: "Reset"; onClicked: root.edited(BL.defaults()) } ]
                onClosed: root.closed()
            }

            // ---- the bar, as it looks on the screen
            Rectangle {
                id: stage
                Layout.fillWidth: true
                Layout.preferredHeight: root.vert ? 300 : Math.round(root.barH * root.zoom) + (root.isl ? 72 : 60)
                radius: root.pal.rLg
                color: Qt.alpha(root.pal.bg, 0.55)
                border.width: root.pal.calm ? 0 : 1
                border.color: root.pal.lineTint
                clip: true

                // the top edge of the screen
                Rectangle { visible: !root.isl && !root.vert; anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 2; color: Qt.alpha(root.pal.accent, 0.35) }
                Text {
                    anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 14
                    font.letterSpacing: root.pal.zen ? 0 : 0.8
                    text: (root.pal.zen ? "Preview  ×" : "PREVIEW  ×") + (root.vert ? root.zoomV : root.zoom).toFixed(1) + (root.vert ? "  ·  " + root.cur.side + " edge" : "")
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                }

                Item {
                    id: zoomBox
                    visible: !root.vert
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: root.isl ? 20 : 4
                    width: barBody.width * root.zoom
                    height: barBody.height * root.zoom

                    Item {
                        id: barBody
                        transformOrigin: Item.TopLeft
                        scale: root.zoom
                        readonly property real sideW: Math.max(root.minZone, rowL.width, rowR.width)
                        readonly property real midW: Math.max(root.minZone, rowC.width)
                        width: sideW * 2 + midW + root.sp.clear * 2 + root.sp.edge * 2 + root.earR * 2
                        height: root.barH

                        // the body: flared corners hanging from the edge (Notch), a rounded pill (Island) or a strip along the edge (Rail)
                        Rectangle {
                            visible: root.isl || root.rail
                            anchors.fill: parent
                            radius: root.cornR
                            color: root.pal.box(Qt.alpha(root.pal.surface, 0.9))
                            border.width: root.pal.calm ? 0 : 1
                            border.color: root.pal.line
                        }
                        Shape {
                            visible: !root.isl && !root.rail
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            antialiasing: true
                            ShapePath {
                                fillColor: Qt.alpha(root.pal.surface, 0.9)
                                strokeColor: root.pal.line
                                strokeWidth: 1
                                startX: 0; startY: 0
                                PathArc { x: root.earR; y: root.earR; radiusX: root.earR; radiusY: root.earR; direction: PathArc.Clockwise }
                                PathLine { x: root.earR; y: barBody.height - root.cornR }
                                PathArc { x: root.earR + root.cornR; y: barBody.height; radiusX: root.cornR; radiusY: root.cornR; direction: PathArc.Counterclockwise }
                                PathLine { x: barBody.width - root.earR - root.cornR; y: barBody.height }
                                PathArc { x: barBody.width - root.earR; y: barBody.height - root.cornR; radiusX: root.cornR; radiusY: root.cornR; direction: PathArc.Counterclockwise }
                                PathLine { x: barBody.width - root.earR; y: root.earR }
                                PathArc { x: barBody.width; y: 0; radiusX: root.earR; radiusY: root.earR; direction: PathArc.Clockwise }
                                PathLine { x: 0; y: 0 }
                            }
                        }

                        // left: grows from the left end
                        Item {
                            id: zoneL
                            x: root.earR + root.sp.edge
                            width: Math.max(root.minZone, rowL.width)
                            height: barBody.height
                            Rectangle { visible: root.dragId !== "" && root.hoverZone === "left"; anchors.fill: parent; anchors.margins: -3; radius: 9; color: Qt.alpha(root.pal.accent, 0.12); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6) }
                            BbEmptyZone { bb: root; visible: root.cur.left.length === 0; title: root.nameL }
                            Row {
                                id: rowL
                                height: parent.height
                                spacing: root.gapL
                                Repeater {
                                    model: root.cur.left
                                    delegate: BbPlaced { bb: root; required property string modelData; required property int index; wid: modelData; zone: "left"; idx: index }
                                }
                            }
                        }
                        // middle: always centred on the screen
                        Item {
                            id: zoneC
                            x: Math.round(barBody.width / 2 - width / 2)
                            width: Math.max(root.minZone, rowC.width)
                            height: barBody.height
                            Rectangle { visible: root.dragId !== "" && root.hoverZone === "center"; anchors.fill: parent; anchors.margins: -3; radius: 9; color: Qt.alpha(root.pal.accent, 0.12); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6) }
                            BbEmptyZone { bb: root; visible: root.cur.center.length === 0; title: BL.zoneTitle(root.cur, "center") }
                            Row {
                                id: rowC
                                anchors.horizontalCenter: parent.horizontalCenter
                                height: parent.height
                                spacing: root.gapC
                                Repeater {
                                    model: root.cur.center
                                    delegate: BbPlaced { bb: root; required property string modelData; required property int index; wid: modelData; zone: "center"; idx: index }
                                }
                            }
                        }
                        // right: grows from the right end
                        Item {
                            id: zoneR
                            x: barBody.width - root.earR - root.sp.edge - width
                            width: Math.max(root.minZone, rowR.width)
                            height: barBody.height
                            Rectangle { visible: root.dragId !== "" && root.hoverZone === "right"; anchors.fill: parent; anchors.margins: -3; radius: 9; color: Qt.alpha(root.pal.accent, 0.12); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6) }
                            BbEmptyZone { bb: root; visible: root.cur.right.length === 0; title: root.nameR }
                            Row {
                                id: rowR
                                anchors.right: parent.right
                                height: parent.height
                                spacing: root.gapR
                                Repeater {
                                    model: root.cur.right
                                    delegate: BbPlaced { bb: root; required property string modelData; required property int index; wid: modelData; zone: "right"; idx: index }
                                }
                            }
                        }

                        // where the widget would land
                        Rectangle {
                            visible: root.dragId !== "" && root.hoverZone !== "" && root.hoverZone !== "tray"
                            x: root.insX; y: root.barH * 0.12
                            width: 2; height: root.barH * 0.76; radius: 1
                            color: root.pal.accent
                            z: 10
                        }
                    }
                }


                // ---- an upright bar (Left / Right): a small screen with the bar on its edge. Every widget is drawn as always (its icon, then its
                // text to the right), the three places are stacked Top / Middle / Bottom, and the drop line is horizontal.
                Item {
                    id: vStage
                    visible: root.vert
                    anchors.fill: parent

                    Rectangle {
                        id: vScreen
                        anchors.centerIn: parent
                        height: parent.height - 24
                        width: Math.min(parent.width - 40, Math.round(height * 1.7))
                        radius: 10
                        color: Qt.alpha(root.pal.surface, 0.18)
                        border.width: 1
                        border.color: Qt.alpha(root.pal.accent, 0.22)
                    }
                    // the edge the bar sits on
                    Rectangle {
                        width: 2; height: vScreen.height
                        x: root.cur.side === "left" ? vScreen.x : vScreen.x + vScreen.width - 2
                        y: vScreen.y
                        color: Qt.alpha(root.pal.accent, 0.35)
                    }

                    Item {
                        id: vZoom
                        x: root.cur.side === "left" ? vScreen.x + 8 : vScreen.x + vScreen.width - width - 8
                        y: vScreen.y + Math.round((vScreen.height - height) / 2)
                        width: vBody.width * root.zoomV
                        height: vBody.height * root.zoomV

                        Item {
                            id: vBody
                            transformOrigin: Item.TopLeft
                            scale: root.zoomV
                            readonly property real colW: Math.max(root.minZoneV, colT.width, colM.width, colB.width)     // as wide as the widest widget
                            readonly property real sideH: Math.max(root.minZoneH, colT.height, colB.height)
                            readonly property real midH: Math.max(root.minZoneH, colM.height)
                            width: colW + 12
                            height: sideH * 2 + midH + root.sp.clear * 2 + root.sp.edge * 2

                            Rectangle {
                                anchors.fill: parent
                                radius: root.isl ? Math.min(root.cornR, 20) : Math.min(root.cornR, 14)
                                color: root.pal.box(Qt.alpha(root.pal.surface, 0.9))
                                border.width: root.pal.calm ? 0 : 1
                                border.color: root.pal.line
                            }

                            // top: grows down from the top end
                            Item {
                                id: zoneT
                                x: 6; y: root.sp.edge
                                width: vBody.colW
                                height: Math.max(root.minZoneH, colT.height)
                                Rectangle { visible: root.dragId !== "" && root.hoverZone === "left"; anchors.fill: parent; anchors.margins: -3; radius: 9; color: Qt.alpha(root.pal.accent, 0.12); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6) }
                                BbEmptyZone { bb: root; visible: root.cur.left.length === 0; title: root.nameL }
                                Column {
                                    id: colT
                                    spacing: root.gapL
                                    Repeater {
                                        model: root.cur.left
                                        delegate: BbPlaced { bb: root; required property string modelData; required property int index; wid: modelData; zone: "left"; idx: index }
                                    }
                                }
                            }
                            // middle: always centred on the screen's height
                            Item {
                                id: zoneM
                                x: 6
                                y: Math.round(vBody.height / 2 - height / 2)
                                width: vBody.colW
                                height: Math.max(root.minZoneH, colM.height)
                                Rectangle { visible: root.dragId !== "" && root.hoverZone === "center"; anchors.fill: parent; anchors.margins: -3; radius: 9; color: Qt.alpha(root.pal.accent, 0.12); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6) }
                                BbEmptyZone { bb: root; visible: root.cur.center.length === 0; title: BL.zoneTitle(root.cur, "center") }
                                Column {
                                    id: colM
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: root.gapC
                                    Repeater {
                                        model: root.cur.center
                                        delegate: BbPlaced { bb: root; required property string modelData; required property int index; wid: modelData; zone: "center"; idx: index }
                                    }
                                }
                            }
                            // bottom: grows up from the bottom end
                            Item {
                                id: zoneB
                                x: 6
                                y: vBody.height - root.sp.edge - height
                                width: vBody.colW
                                height: Math.max(root.minZoneH, colB.height)
                                Rectangle { visible: root.dragId !== "" && root.hoverZone === "right"; anchors.fill: parent; anchors.margins: -3; radius: 9; color: Qt.alpha(root.pal.accent, 0.12); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6) }
                                BbEmptyZone { bb: root; visible: root.cur.right.length === 0; title: root.nameR }
                                Column {
                                    id: colB
                                    anchors.bottom: parent.bottom
                                    spacing: root.gapR
                                    Repeater {
                                        model: root.cur.right
                                        delegate: BbPlaced { bb: root; required property string modelData; required property int index; wid: modelData; zone: "right"; idx: index }
                                    }
                                }
                            }

                            // where the widget would land (a line across the column)
                            Rectangle {
                                visible: root.vert && root.dragId !== "" && root.hoverZone !== "" && root.hoverZone !== "tray"
                                x: 6; y: root.insX
                                width: vBody.colW; height: 2; radius: 1
                                color: root.pal.accent
                                z: 10
                            }
                        }
                    }

                    // what each place is called, written on the screen side of the bar (to its right on a Left bar)
                    Text {
                        text: root.nameL
                        x: root.cur.side === "left" ? vZoom.x + vZoom.width + 12 : vZoom.x - 12 - width
                        y: vZoom.y + (zoneT.y + 6) * root.zoomV
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                    }
                    Text {
                        text: BL.zoneTitle(root.cur, "center")
                        x: root.cur.side === "left" ? vZoom.x + vZoom.width + 12 : vZoom.x - 12 - width
                        y: vZoom.y + (zoneM.y + zoneM.height / 2) * root.zoomV - height / 2
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                    }
                    Text {
                        text: root.nameR
                        x: root.cur.side === "left" ? vZoom.x + vZoom.width + 12 : vZoom.x - 12 - width
                        y: vZoom.y + (zoneB.y + zoneB.height - 6) * root.zoomV - height
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10
                    }
                    // the exact middle of the screen's height, while a widget is carried
                    Rectangle {
                        visible: root.dragId !== ""
                        x: vScreen.x; y: vScreen.y + Math.round(vScreen.height / 2) - 0.5
                        width: vScreen.width; height: 1
                        color: Qt.alpha(root.pal.accent, 0.4)
                    }
                }

                // the exact centre of the screen
                Rectangle {
                    visible: root.dragId !== "" && !root.vert
                    x: Math.round(stage.width / 2) - 0.5
                    y: 0
                    width: 1; height: stage.height
                    color: Qt.alpha(root.pal.accent, 0.4)
                }
                Text {
                    visible: root.dragId !== "" && !root.vert
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    text: "centre of the screen"
                    color: Qt.alpha(root.pal.accent, 0.85)
                    font.family: root.pal.uiFont; font.pixelSize: 10
                }
            }

            // ---- two quiet panels: how the bar is styled, and how balanced it is
            RowLayout {
                Layout.fillWidth: true
                spacing: 20

                // style: the shape and the three spacing numbers, one under the other
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    implicitHeight: styleCol.implicitHeight + 40
                    radius: root.pal.rMd
                    color: root.pal.box(Qt.alpha(root.pal.surface, 0.35))
                    border.width: root.pal.calm ? 0 : 1
                    border.color: root.pal.line
                    Column {
                        id: styleCol
                        x: 22; y: 20
                        width: parent.width - 44
                        spacing: 14
                        Text { text: root.pal.cap("STYLE"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.calm ? 12 : 10; font.letterSpacing: root.pal.calm ? 0.2 : 0.8 }
                        Row {
                            spacing: 10
                            Text { width: 96; anchors.verticalCenter: parent.verticalCenter; text: "Shape"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Notch"; on: root.cur.shape === "notch"; onClicked: root.edited(BL.setShape(root.cur, "notch")) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Island"; on: root.isl; onClicked: root.edited(BL.setShape(root.cur, "island")) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Rail"; on: root.rail; onClicked: root.edited(BL.setShape(root.cur, "rail")) }
                        }
                        Flow {
                            width: parent.width
                            spacing: 10
                            Text { width: 96; height: 28; verticalAlignment: Text.AlignVCenter; text: "Side"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Top"; on: root.cur.side === "top"; onClicked: root.edited(BL.setSide(root.cur, "top")) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Bottom"; on: root.cur.side === "bottom"; onClicked: root.edited(BL.setSide(root.cur, "bottom")) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Left"; on: root.cur.side === "left"; onClicked: root.edited(BL.setSide(root.cur, "left")) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Right"; on: root.cur.side === "right"; onClicked: root.edited(BL.setSide(root.cur, "right")) }
                        }
                        Row {
                            visible: root.rail
                            spacing: 10
                            Text { width: 96; anchors.verticalCenter: parent.verticalCenter; text: "Capsules"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Off"; on: !root.cur.caps; onClicked: root.edited(BL.setCaps(root.cur, false)) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "On"; on: root.cur.caps; onClicked: root.edited(BL.setCaps(root.cur, true)) }
                        }
                        Row {
                            spacing: 10
                            Text { width: 96; anchors.verticalCenter: parent.verticalCenter; text: "Special workspaces"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; elide: Text.ElideRight }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Beside"; on: root.cur.spMode !== "over"; onClicked: root.edited(BL.setSpMode(root.cur, "bar")) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Over workspaces"; on: root.cur.spMode === "over"; onClicked: root.edited(BL.setSpMode(root.cur, "over")) }
                        }
                        BbNumBox { bb: root; labelW: 96; label: "Edge"; value: root.cur.edge; shown: root.sp.edge; maxV: BL.padMax.edge; onCommit: v => root.edited(BL.setNum(root.cur, "edge", v)) }
                        BbNumBox { bb: root; labelW: 96; label: "Gap"; value: root.cur.gap; shown: root.sp.gap; maxV: BL.padMax.gap; onCommit: v => root.edited(BL.setNum(root.cur, "gap", v)) }
                        BbNumBox { bb: root; labelW: 96; label: "Centre gap"; value: root.cur.clear; shown: root.sp.clear; maxV: BL.padMax.clear; onCommit: v => root.edited(BL.setNum(root.cur, "clear", v)) }
                        Row {
                            spacing: 10
                            Text { width: 96; anchors.verticalCenter: parent.verticalCenter; text: "Screen border"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Off"; on: !root.frameOn; onClicked: root.frameEdited("opt:frame", false) }
                            Chip { pal: root.pal; implicitHeight: 28; label: "On"; on: root.frameOn; onClicked: root.frameEdited("opt:frame", true) }
                        }
                        BbNumBox { visible: root.frameOn; bb: root; labelW: 96; label: "Thickness"; value: root.frameW; shown: root.frameW; maxV: 28; onCommit: v => root.frameEdited("opt:frameW", v === null ? 12 : Math.max(4, v)) }
                        BbNumBox { visible: root.frameOn; bb: root; labelW: 96; label: "Inner corners"; value: root.frameR; shown: root.frameR; maxV: 40; onCommit: v => root.frameEdited("opt:frameR", v === null ? 22 : v) }
                    }
                }

                // balance: the sizes, what would even them out, and the padding of the picked widget
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    implicitHeight: balCol.implicitHeight + 40
                    radius: root.pal.rMd
                    color: root.pal.box(Qt.alpha(root.pal.surface, 0.35))
                    border.width: root.pal.calm ? 0 : 1
                    border.color: root.pal.line
                    Column {
                        id: balCol
                        x: 22; y: 20
                        width: parent.width - 44
                        spacing: 12
                        Text { text: root.pal.cap("BALANCE"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.calm ? 12 : 10; font.letterSpacing: root.pal.calm ? 0.2 : 0.8 }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.dragId !== "" ? root.dropText()
                                  : root.nameL + " " + root.px(root.wLeft) + "   ·   Middle " + root.px(root.wMid) + "   ·   " + root.nameR + " " + root.px(root.wRight)
                            color: root.dragId !== "" ? root.pal.accent : root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            font.weight: Font.DemiBold
                        }
                        Text {
                            visible: root.dragId === ""
                            width: parent.width
                            wrapMode: Text.WordWrap
                            lineHeight: 1.1
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            text: Math.abs(root.diffLR) <= 6
                                  ? "✓ " + root.nameL + " and " + root.nameR.toLowerCase() + " match. The middle stays centred."
                                  : (root.tip !== null
                                     ? (root.diffLR > 0 ? root.nameL : root.nameR) + " is " + Math.round(Math.abs(root.diffLR)) + " px " + root.longWord + ". Moving " + BL.nameOf(root.tip.id) + " to " + (root.tip.to === "left" ? root.nameL : root.nameR) + " brings them to " + Math.round(root.tip.after) + " px apart."
                                     : (root.diffLR > 0 ? root.nameL : root.nameR) + " is " + Math.round(Math.abs(root.diffLR)) + " px " + root.longWord + ". Try the spacing numbers, or move a widget by hand.")
                        }
                        Chip {
                            visible: root.dragId === "" && root.tip !== null
                            pal: root.pal
                            implicitHeight: 28
                            label: "Move " + (root.tip !== null ? BL.shortOf(root.tip.id) : "")
                            on: true
                            onClicked: root.edited(root.tip.layout)
                        }
                        Rectangle { width: parent.width; height: 1; color: root.pal.lineSoft }
                        // the picked widget
                        Hint {
                            pal: root.pal
                            visible: root.sel === ""
                            width: parent.width
                            text: "Click a widget on the bar to give it its own padding."
                            color: root.pal.muted
                            fontFamily: root.pal.uiFont
                            pixelSize: root.pal.tCap
                        }
                        Flow {
                            visible: root.sel !== ""
                            width: parent.width
                            spacing: 12
                            Text { height: 28; verticalAlignment: Text.AlignVCenter; text: root.sel !== "" ? BL.nameOf(root.sel) : ""; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                            BbNumBox {
                                bb: root
                                label: "Padding"
                                value: root.sel !== "" ? BL.padOf(root.cur, root.sel) : 0
                                shown: 0
                                autoWord: "none"
                                maxV: BL.widgetPadMax
                                onCommit: v => root.edited(BL.setPad(root.cur, root.sel, v === null ? 0 : v))
                            }
                            Chip { pal: root.pal; implicitHeight: 28; label: "Take off"; onClicked: root.edited(BL.remove(root.cur, root.sel)) }
                        }
                    }
                }
            }

            // ---- the shelf
            Rectangle {
                id: wTray
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 104
                radius: root.pal.rLg
                readonly property bool hot: root.dragId !== "" && root.hoverZone === "tray" && root.dragFrom !== "tray"
                color: hot ? Qt.alpha(root.pal.accent, 0.12) : Qt.alpha(root.pal.surface, 0.4)
                border.width: hot ? 1.5 : 1
                border.color: hot ? Qt.alpha(root.pal.accent, 0.9) : root.pal.line
                Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Behavior on border.color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Column {
                    x: 22; y: 18
                    width: parent.width - 44
                    spacing: 14
                    Row {
                        spacing: 10
                        Text { text: "Not on the bar"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                        Text { visible: !(root.pal.zen && root.pal.hideHints) || (root.dragId !== "" && root.dragFrom !== "tray"); text: root.dragId !== "" && root.dragFrom !== "tray" ? "drop here to take it off" : "drag one up to the bar"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Flow {
                        width: parent.width
                        spacing: 10
                        Repeater {
                            model: root.spare
                            delegate: BbChip { bb: root; required property string modelData; required property int index; wid: modelData; idx: index }
                        }
                    }
                    Text {
                        visible: root.spare.length === 0
                        text: "Everything is on the bar"
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.italic: true
                    }
                }
            }

            // ---- what the widget under the pointer does
            Text {
                Layout.fillWidth: true
                // the new style: only what the widget under the pointer does, nothing at rest
                text: root.hint !== "" ? root.hint : (root.pal.zen && root.pal.hideHints ? "" : "Right-click a widget to take it off. The middle always stays centred.")
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
                wrapMode: Text.Wrap
            }
        }

        // a few stars flying over everything on the card (Settings > Look > Moving stars)
        BarStars { z: 20; anchors.fill: parent; anchors.margins: 14; pal: root.pal; count: 10; loopMs: 140000; sizeScale: 1.4; active: root.open; visible: root.open && root.movingStars }
    }

    // the widget in the hand
    Rectangle {
        visible: root.dragId !== ""
        z: 100
        width: ghostT.implicitWidth + 34
        height: 30
        radius: 15
        x: root.dragX - width / 2
        y: root.dragY - height / 2
        scale: 1.07
        color: Qt.alpha(root.pal.surfaceHi, 0.98)
        border.width: 1.5
        border.color: root.pal.accent
        Rectangle { anchors.fill: parent; anchors.margins: -6; radius: parent.radius + 6; color: root.pal.accent; opacity: 0.1; z: -1 }
        Rectangle { x: 11; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: root.pal.accent }
        Text {
            id: ghostT
            x: 24
            anchors.verticalCenter: parent.verticalCenter
            text: root.dragId !== "" ? BL.shortOf(root.dragId) : ""
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody
            font.weight: Font.Medium
        }
    }
}
