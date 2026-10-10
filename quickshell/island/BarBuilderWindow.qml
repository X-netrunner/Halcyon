import QtQuick
import QtQuick.Layouts
import "BarLayout.js" as BL

// The bar builder window (Settings > Bar style > Bar builder > "Open the bar builder"). Same kind of window as the Wallpaper
// Gallery: a dimmed overlay with one card on it.
// The top of the card is the bar itself, in three places (left, middle, right); under it is the shelf of widgets that are not
// on the bar. Drag a widget onto a place to put it there (a light line shows where it will land), drag it along to reorder it,
// drop it on the shelf to take it off. Right click or × on a widget also takes it off. Every drop is saved and shown at once.
Item {
    id: root

    property var pal
    property bool open: false
    property var layout: null                  // opt.barLayout (anything: it is cleaned up here)
    signal edited(var layout)
    signal closed()

    readonly property var cur: BL.normalize(layout)
    readonly property var zoneInfo: [
        { k: "left", t: "Left", d: "from the left edge" },
        { k: "center", t: "Middle", d: "always centred" },
        { k: "right", t: "Right", d: "to the right edge" }
    ]
    readonly property var spare: {
        var out = []
        for (var i = 0; i < BL.catalog.length; i++) if (!BL.placed(cur, BL.catalog[i].id)) out.push(BL.catalog[i].id)
        return out
    }

    // ---------------------------------------------------------------- dragging (pointer driven, so the drop line is ours)
    property string dragId: ""                 // the widget being carried ("" = none)
    property string dragFrom: ""               // left | center | right | tray
    property int dragFromIdx: -1
    property real dragX: 0                     // the pointer, in this window's coordinates
    property real dragY: 0
    property string hoverZone: ""              // the place under the pointer: left | center | right | tray | ""
    property int insIdx: 0                     // where it would land in that place
    property real insX: 0                      // the drop line, in the coordinates of that place's chips
    property real insY: 0
    property real insH: 30
    property string hint: ""

    function boxFor(k) { return k === "left" ? wLeft : (k === "center" ? wCenter : (k === "right" ? wRight : wTray)) }
    function inside(item, x, y) {
        var p = item.mapFromItem(root, x, y)
        return p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= item.height
    }
    function chipsOf(box) {
        var out = [], ch = box.flow.children
        for (var i = 0; i < ch.length; i++) if (ch[i].wid !== undefined) out.push(ch[i])
        return out
    }
    function aim(zk, x, y) {
        var box = boxFor(zk)
        var kids = chipsOf(box)
        if (kids.length === 0) { insIdx = 0; insX = 0; insY = 0; insH = 30; return }
        var p = box.flow.mapFromItem(root, x, y)
        var best = kids[0], bd = 1e12
        for (var i = 0; i < kids.length; i++) {
            var dx = p.x - (kids[i].x + kids[i].width / 2)
            var dy = (p.y - (kids[i].y + kids[i].height / 2)) * 3          // the row counts more than the column
            var d = dx * dx + dy * dy
            if (d < bd) { bd = d; best = kids[i] }
        }
        var before = p.x < best.x + best.width / 2
        insIdx = best.idx + (before ? 0 : 1)
        insX = before ? best.x - 4 : best.x + best.width + 2
        insY = best.y
        insH = best.height
    }
    function beginDrag(id, zone, idx, x, y) {
        dragId = id; dragFrom = zone; dragFromIdx = idx
        hint = BL.nameOf(id) + ": " + BL.hintOf(id)
        moveDrag(x, y)
    }
    function moveDrag(x, y) {
        dragX = x; dragY = y
        var z = inside(wLeft, x, y) ? "left" : inside(wCenter, x, y) ? "center" : inside(wRight, x, y) ? "right" : inside(wTray, x, y) ? "tray" : ""
        hoverZone = z
        if (z !== "" && z !== "tray") aim(z, x, y)
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
        edited(BL.place(cur, id, z, idx))
    }

    // ---------------------------------------------------------------- the window
    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutCubic } }
    onOpenChanged: { if (open) Qt.callLater(function () { root.forceActiveFocus() }); else endDrag() }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })

    Keys.onPressed: function (e) {
        if (e.key === Qt.Key_Escape) {
            if (root.dragId !== "") root.cancelDrag(); else root.closed()
            e.accepted = true
        }
    }

    // backdrop
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.72)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }

    // a widget: a pill, the same look as the nodes of the tree
    component WChip: Rectangle {
        id: ch
        property string wid: ""
        property string zone: "tray"
        property int idx: 0
        readonly property bool carried: root.dragId === wid
        readonly property bool hot: cma.containsMouse && root.dragId === ""
        readonly property bool placed: zone !== "tray"

        implicitWidth: lbl.implicitWidth + (placed ? 50 : 34)
        implicitHeight: 30
        width: implicitWidth
        height: implicitHeight
        radius: height / 2
        opacity: carried ? 0.28 : 1
        color: hot ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, placed ? 0.95 : 0.6)
        border.width: 1
        border.color: Qt.alpha(root.pal.accent, hot ? 0.7 : (placed ? 0.3 : 0.16))
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on opacity { NumberAnimation { duration: root.pal.dFast } }

        Rectangle {
            x: 11
            anchors.verticalCenter: parent.verticalCenter
            width: 6; height: 6; radius: 3
            color: ch.placed ? root.pal.accent : root.pal.muted
            opacity: ch.placed ? 0.9 : 0.6
        }
        Text {
            id: lbl
            x: 24
            anchors.verticalCenter: parent.verticalCenter
            text: BL.shortOf(ch.wid)
            color: ch.placed ? root.pal.text : Qt.alpha(root.pal.text, 0.78)
            font.family: root.pal.uiFont
            font.pixelSize: 12
            font.weight: Font.Medium
        }

        MouseArea {
            id: cma
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: root.dragId !== "" ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property real sx: 0
            property real sy: 0
            onPressed: m => { var p = mapToItem(root, m.x, m.y); sx = p.x; sy = p.y }
            onPositionChanged: m => {
                if (!pressed || !(pressedButtons & Qt.LeftButton)) return
                var p = mapToItem(root, m.x, m.y)
                if (root.dragId === "") {
                    if (Math.abs(p.x - sx) + Math.abs(p.y - sy) > 6) root.beginDrag(ch.wid, ch.zone, ch.idx, p.x, p.y)
                } else if (root.dragId === ch.wid) root.moveDrag(p.x, p.y)
            }
            onReleased: m => { if (root.dragId === ch.wid) root.dropDrag() }
            onCanceled: root.cancelDrag()
            onClicked: m => { if (m.button === Qt.RightButton && ch.placed) root.edited(BL.remove(root.cur, ch.wid)) }
            onEntered: if (root.dragId === "") root.hint = BL.nameOf(ch.wid) + ": " + BL.hintOf(ch.wid)
            onExited: if (root.dragId === "") root.hint = ""
        }

        // × takes it off the bar
        Rectangle {
            visible: ch.placed
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            width: 20; height: 20; radius: 10
            color: xma.containsMouse ? Qt.alpha(root.pal.accent, 0.28) : "transparent"
            Text {
                anchors.centerIn: parent
                text: "×"
                color: root.pal.text
                opacity: xma.containsMouse ? 1 : (ch.hot ? 0.6 : 0.3)
                font.family: root.pal.uiFont
                font.pixelSize: 14
            }
            MouseArea {
                id: xma
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.edited(BL.remove(root.cur, ch.wid))
            }
        }
    }

    // a place: the left / middle / right of the bar, or the shelf
    component ZoneBox: Rectangle {
        id: zb
        property string zk: "left"
        property string title: ""
        property string sub: ""
        property var items: []
        property string empty: ""
        property alias flow: zflow
        readonly property bool tray: zk === "tray"
        readonly property bool hot: root.dragId !== "" && root.hoverZone === zk && !(tray && root.dragFrom === "tray")

        radius: 18
        color: hot ? Qt.alpha(root.pal.accent, 0.12) : Qt.alpha(tray ? root.pal.bg : root.pal.surface, tray ? 0.4 : 0.55)
        border.width: hot ? 1.5 : 1
        border.color: hot ? Qt.alpha(root.pal.accent, 0.9) : Qt.alpha(root.pal.accent, tray ? 0.14 : 0.24)
        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }

        Column {
            x: 14; y: 12
            width: parent.width - 28
            spacing: 10
            RowLayout {
                width: parent.width
                spacing: 8
                Text {
                    Layout.alignment: Qt.AlignBaseline
                    text: zb.title
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.alignment: Qt.AlignBaseline
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: zb.sub
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: 10
                }
            }
            Item {
                width: parent.width
                height: Math.max(zflow.height, 30)
                Flow {
                    id: zflow
                    width: parent.width
                    spacing: 6
                    move: Transition { NumberAnimation { properties: "x,y"; duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                    add: Transition { NumberAnimation { property: "scale"; from: 0.85; to: 1; duration: root.pal.dMed; easing.type: Easing.OutBack } }
                    Repeater {
                        model: zb.items
                        delegate: WChip {
                            required property string modelData
                            required property int index
                            wid: modelData
                            zone: zb.zk
                            idx: index
                        }
                    }
                }
                Text {
                    visible: zb.items.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: zb.empty
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: 11
                    font.italic: true
                }
                // where the widget would land
                Rectangle {
                    visible: root.dragId !== "" && root.hoverZone === zb.zk && !zb.tray
                    x: root.insX; y: root.insY
                    width: 3; height: root.insH; radius: 1.5
                    color: root.pal.accent
                }
            }
        }
    }

    // the card
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 900)
        height: Math.min(parent.height - 80, 580)
        radius: root.pal.rXl
        color: Qt.alpha(root.pal.surface, root.pal.glassSolid)
        border.width: 1
        border.color: root.pal.line
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutQuint } }

        MouseArea { anchors.fill: parent }          // a click on the card must not close the window

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 14

            // ---- header
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text {
                        text: "Bar builder"
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "Drag a widget onto the bar, along it to reorder, or onto the shelf to take it off"
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 11
                    }
                }
                Item { Layout.fillWidth: true }
                ActionChip { pal: root.pal; label: "Reset layout"; doneLabel: "Reset"; onClicked: root.edited(BL.defaults()) }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            // ---- the bar
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 200
                radius: 24
                color: Qt.alpha(root.pal.bg, 0.55)
                border.width: 1
                border.color: Qt.alpha(root.pal.accent, 0.25)
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 10
                    ZoneBox { id: wLeft; Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true; zk: "left"; title: "Left"; sub: root.zoneInfo[0].d; items: root.cur.left; empty: "Drop widgets here" }
                    ZoneBox { id: wCenter; Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true; zk: "center"; title: "Middle"; sub: root.zoneInfo[1].d; items: root.cur.center; empty: "Drop widgets here" }
                    ZoneBox { id: wRight; Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true; zk: "right"; title: "Right"; sub: root.zoneInfo[2].d; items: root.cur.right; empty: "Drop widgets here" }
                }
            }

            // ---- the shelf
            ZoneBox {
                id: wTray
                Layout.fillWidth: true
                Layout.fillHeight: true
                zk: "tray"
                title: "Not on the bar"
                sub: root.dragId !== "" && root.dragFrom !== "tray" ? "drop here to take it off" : "drag one up to the bar"
                items: root.spare
                empty: "Everything is on the bar"
            }

            // ---- what the widget under the pointer does
            Text {
                Layout.fillWidth: true
                text: root.hint !== "" ? root.hint : "Right click a widget on the bar to take it off. Colours, spacing, Wi-Fi look and Bluetooth mode come from the options in Settings."
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
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
        Rectangle {
            anchors.fill: parent
            anchors.margins: -6
            radius: parent.radius + 6
            color: root.pal.accent
            opacity: 0.1
            z: -1
        }
        Rectangle { x: 11; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: root.pal.accent }
        Text {
            id: ghostT
            x: 24
            anchors.verticalCenter: parent.verticalCenter
            text: root.dragId !== "" ? BL.shortOf(root.dragId) : ""
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: 12
            font.weight: Font.Medium
        }
    }
}
