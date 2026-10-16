import QtQuick
import QtQuick.Layouts
import "NotifLayout.js" as NL

// The notification box builder window (Settings > Panels & notifications > Notification box builder > "Open ..."). A dimmed overlay
// with one card on it.
//   Left:   the real notification box (NotifSurface.qml, the same one the screen uses) filled with sample notifications. Everything
//           you change on the right shows here at once; buttons and the ✕ on the sample notifications work, nothing real is touched.
//   Right:  the look of the list, the parts of the box (on / off, up / down), the constellations and stars, spacing and shape,
//           and where the box sits on the screen (with a small picture of the screen).
// Every change is saved and shown on the real box at once.
Item {
    id: root
    property var pal
    property bool open: false
    property var layout: null                  // opt.notifLayout (anything: it is cleaned up here)
    property string look: "stack"              // opt.notifStyle
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    property bool stars: true                  // Settings > Constellations: the constellations in the notification centre
    signal edited(var layout)
    signal lookChosen(string look)
    signal closed()

    readonly property var cur: NL.normalize(layout)
    // the same test the box uses: a band with no constellation to draw is left out
    readonly property bool skyEmpty: !(sysmode === "lockdown" || sysmode === "stealth" || (profileStars && starData !== null && starData !== undefined))

    // ---------------------------------------------------------------- sample notifications
    property real now: Date.now()
    property real t0: Date.now()
    property var removed: ({})
    property bool sampleDnd: false
    function mk(id, app, title, body, urg, agoS, acts) {
        return { id: id, appName: app, summary: title, body: body, appIcon: "", image: "", urgency: urg, desktopEntry: "", actions: acts,
                 transient: false, ago: agoS, dismiss: function () {}, expire: function () {} }
    }
    readonly property var sampleAll: [
        mk(1, "notify-send", "Hello", "This is a test notification on Halcyon", 1, 5, []),
        mk(2, "Discord", "Aarav", "did you push the fix for the lock screen?", 1, 120, [{ identifier: "reply", text: "Reply", invoke: function () {} }]),
        mk(3, "Discord", "Dev server", "Nex, the build is green", 1, 540, []),
        mk(4, "Halcyon", "Gaming mode", "On. Helpers are stopped until you turn it off.", 1, 840, []),
        mk(5, "Pacman", "12 updates available", "linux, mesa, quickshell and 9 more", 1, 3600, []),
        mk(6, "Battery", "Battery low", "9% left. Plug in to keep working.", 2, 7200, [])
    ]
    readonly property var shown: sampleAll.filter(function (n) { return !removed[n.id] })
    readonly property var arrivedMap: {
        var m = {}
        for (var i = 0; i < sampleAll.length; i++) m[sampleAll[i].id] = t0 - sampleAll[i].ago * 1000
        return m
    }
    QtObject {
        id: sample
        property var history: root.shown
        property var arrived: root.arrivedMap
        property string avatar: ""
        property bool usePfp: false
        property bool dnd: root.sampleDnd
    }
    Timer { interval: 30000; running: root.open; repeat: true; onTriggered: root.now = Date.now() }

    // ---------------------------------------------------------------- the window
    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
    onOpenChanged: { if (open) { t0 = Date.now(); now = t0; removed = ({}); Qt.callLater(function () { root.forceActiveFocus() }) } }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })
    Keys.onPressed: function (e) { if (e.key === Qt.Key_Escape) { root.closed(); e.accepted = true } }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.45)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }


    Glass {
        id: card
        pal: root.pal
        anchors.centerIn: parent
        width: Math.min(parent.width - 120, 1120)
        height: Math.min(parent.height - 80, 800)
        radius: root.pal.rXl
        opacityBody: root.pal.solid ? 1 : 0.78
        border.color: Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 32
            spacing: 18

            // ---- header
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Rectangle { Layout.alignment: Qt.AlignVCenter; width: 8; height: 8; radius: 4; color: root.pal.accent }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text { text: "Notification box builder"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
                    Text { text: "The box on the left is the real one. Change anything on the right."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                }
                Item { Layout.fillWidth: true }
                ActionChip { pal: root.pal; label: "Restore sample"; doneLabel: "Restored"; onClicked: { root.removed = ({}); root.sampleDnd = false } }
                ActionChip { pal: root.pal; label: "Reset the box"; doneLabel: "Reset"; onClicked: root.edited(NL.defaults()) }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 24

                // ---- the live box
                Rectangle {
                    id: stage
                    Layout.fillHeight: true
                    Layout.preferredWidth: Math.max(440, root.cur.width + 56)
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.55)
                    border.width: 1
                    border.color: root.pal.lineTint
                    clip: true
                    NbCap { pal: root.pal; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 14; text: "LIVE PREVIEW" }

                    NotifSurface {
                        id: pv
                        pal: root.pal
                        layout: root.layout
                        src: sample
                        look: root.look
                        active: root.open
                        now: root.now
                        maxH: 640
                        stars: root.stars
                        sysmode: root.sysmode
                        starData: root.starData
                        profileStars: root.profileStars
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 20
                        transformOrigin: Item.Top
                        scale: Math.min(1, (stage.height - 48) / Math.max(1, height))
                        onDndRequested: on => root.sampleDnd = on
                        onClearRequested: { var m = {}; for (var i = 0; i < root.sampleAll.length; i++) m[root.sampleAll[i].id] = true; root.removed = m }
                        onDismissRequested: n => { var m = Object.assign({}, root.removed); m[n.id] = true; root.removed = m }
                    }
                }

                // ---- the controls
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
                        width: ctl.width - 12
                        spacing: 12

                        // look
                        NbCap { pal: root.pal; text: "LOOK OF THE LIST" }
                        Row {
                            spacing: 8
                            Chip { pal: root.pal; implicitHeight: 30; label: "Stack"; on: root.look === "stack"; onClicked: root.lookChosen("stack") }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Timeline"; on: root.look === "timeline"; onClicked: root.lookChosen("timeline") }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Grouped by app"; on: root.look === "grouped"; onClicked: root.lookChosen("grouped") }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // parts
                        NbCap { pal: root.pal; text: "PARTS OF THE BOX, TOP TO BOTTOM" }
                        // one row per part; a row sits at its place in the order and slides there when the arrows move it
                        Item {
                            id: partsBox
                            Layout.fillWidth: true
                            Layout.preferredHeight: 3 * 30 + 2 * 8
                            property bool ready: false
                            Component.onCompleted: Qt.callLater(function () { partsBox.ready = true })
                            Repeater {
                                model: NL.ids
                                delegate: RowLayout {
                                    id: br
                                    required property string modelData
                                    function posOf() { for (var i = 0; i < root.cur.blocks.length; i++) if (root.cur.blocks[i].id === modelData) return i; return 0 }
                                    readonly property int pos: posOf()
                                    readonly property var blk: root.cur.blocks[pos]
                                    x: 0
                                    y: pos * 38
                                    width: partsBox.width
                                    height: 30
                                    spacing: 8
                                    Behavior on y { enabled: partsBox.ready; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                                    Text {
                                        Layout.fillWidth: true
                                        text: NL.names[br.modelData] + (br.modelData === "sky" && br.blk.on && root.skyEmpty ? "  (no constellation to draw, so no space)" : "")
                                        color: br.blk.on ? root.pal.text : root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        font.weight: Font.Medium
                                    }
                                    Chip { pal: root.pal; implicitHeight: 28; label: br.blk.on ? "Shown" : "Hidden"; on: br.blk.on; onClicked: root.edited(NL.toggleBlock(root.cur, br.modelData)) }
                                    Chip { pal: root.pal; implicitHeight: 28; label: "▲"; opacity: br.pos > 0 ? 1 : 0.35; onClicked: if (br.pos > 0) root.edited(NL.moveBlock(root.cur, br.modelData, -1)) }
                                    Chip { pal: root.pal; implicitHeight: 28; label: "▼"; opacity: br.pos < root.cur.blocks.length - 1 ? 1 : 0.35; onClicked: if (br.pos < root.cur.blocks.length - 1) root.edited(NL.moveBlock(root.cur, br.modelData, 1)) }
                                }
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // constellations
                        NbCap { pal: root.pal; text: "CONSTELLATIONS AND STARS" }
                        Text {
                            visible: !root.stars
                            Layout.fillWidth: true
                            text: "The constellations are switched off for the notification centre (Settings > Constellations), so none of this shows on the screen."
                            color: root.pal.warn
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            wrapMode: Text.WordWrap
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 8
                            Chip { pal: root.pal; implicitHeight: 30; label: "Behind the whole box"; on: root.cur.behind; onClicked: root.edited(NL.edit(root.cur, "behind", !root.cur.behind)) }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Stars in popups"; on: root.cur.toastStars; onClicked: root.edited(NL.edit(root.cur, "toastStars", !root.cur.toastStars)) }
                        }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Band height"; from: 0; to: 260; value: root.cur.skyH; zeroText: "Auto"; onPicked: v => root.edited(NL.edit(root.cur, "skyH", v)) }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Drifting dots (behind)"; from: 0; to: 24; value: root.cur.dots; unit: ""; zeroText: "None"; onPicked: v => root.edited(NL.edit(root.cur, "dots", v)) }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Flying stars"; from: 0; to: 20; value: root.cur.fly; unit: ""; zeroText: "None"; onPicked: v => root.edited(NL.edit(root.cur, "fly", v)) }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // spacing and shape
                        NbCap { pal: root.pal; text: "SPACING AND SHAPE" }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Padding"; from: 8; to: 36; value: root.cur.pad; onPicked: v => root.edited(NL.edit(root.cur, "pad", v)) }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Between parts"; from: 4; to: 28; value: root.cur.gap; onPicked: v => root.edited(NL.edit(root.cur, "gap", v)) }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Between notifications"; from: 2; to: 24; value: root.cur.rowGap; onPicked: v => root.edited(NL.edit(root.cur, "rowGap", v)) }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Corner roundness"; from: 8; to: 40; value: root.cur.radius; onPicked: v => root.edited(NL.edit(root.cur, "radius", v)) }
                        NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Width"; from: 320; to: 560; value: root.cur.width; onPicked: v => root.edited(NL.edit(root.cur, "width", v)) }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // place on the screen
                        NbCap { pal: root.pal; text: "WHERE IT SITS ON THE SCREEN" }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 16
                            // a small picture of the screen: the box on its chosen corner / edge with its activation trigger
                            Rectangle {
                                id: scr
                                Layout.preferredWidth: 176
                                Layout.preferredHeight: 99
                                radius: 6
                                color: Qt.alpha(root.pal.bg, 0.7)
                                border.width: 1
                                border.color: root.pal.line
                                readonly property real sc: width / 1920
                                readonly property real bh: Math.min(height - 8, pv.height * sc)
                                readonly property bool atLeft: root.cur.corner === "tl" || root.cur.corner === "bl"
                                readonly property bool atBot: root.cur.corner === "bl" || root.cur.corner === "br" || root.cur.vpos === "bottom"

                                // activation area trigger hint in preview
                                Rectangle {
                                    id: miniTrigger
                                    readonly property bool isCorner: root.cur.spot === "corner"
                                    width: isCorner ? 6 : 2
                                    height: isCorner ? 6 : (root.cur.vpos === "middle" ? 36 : 28)
                                    radius: isCorner ? 3 : 1
                                    x: scr.atLeft ? 1 : scr.width - width - 1
                                    y: isCorner
                                        ? (scr.atBot ? scr.height - height - 1 : 1)
                                        : (root.cur.vpos === "middle" ? (scr.height - height) / 2 : (scr.atBot ? scr.height - height - 4 : 4))
                                    color: root.pal.accent
                                    z: 2
                                    Behavior on x { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                                    Behavior on y { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                                }

                                Rectangle {
                                    id: mini
                                    width: Math.max(8, root.cur.width * scr.sc)
                                    height: scr.bh
                                    radius: Math.max(2, root.cur.radius * scr.sc)
                                    x: scr.atLeft ? 4 : scr.width - width - 4
                                    y: root.cur.vpos === "middle" ? (scr.height - height) / 2
                                       : scr.atBot ? scr.height - height - Math.max(4, (root.pal.boxTop + root.cur.offY) * scr.sc)
                                       : Math.max(4, (root.pal.boxTop + root.cur.offY) * scr.sc)
                                    color: Qt.alpha(root.pal.accent, 0.35)
                                    border.width: 1
                                    border.color: root.pal.accent
                                    Behavior on x { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                                    Behavior on y { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    text: "Corner placement"
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    text: "Assign notifications to any corner in Desktop builder (Settings > Appearance > Desktop builder)."
                                    color: root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: 10
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: "Activation trigger area"
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                    font.weight: Font.DemiBold
                                }
                                Row {
                                    spacing: 6
                                    Chip { pal: root.pal; implicitHeight: 28; label: "Screen edge strip"; on: root.cur.spot !== "corner"; onClicked: root.edited(NL.edit(root.cur, "spot", "edge")) }
                                    Chip { pal: root.pal; implicitHeight: 28; label: "Corner trigger"; on: root.cur.spot === "corner"; onClicked: root.edited(NL.edit(root.cur, "spot", "corner")) }
                                }
                                Row {
                                    spacing: 6
                                    visible: root.cur.spot !== "corner"
                                    Chip { pal: root.pal; implicitHeight: 26; label: "Top"; on: root.cur.vpos === "top"; onClicked: root.edited(NL.edit(root.cur, "vpos", "top")) }
                                    Chip { pal: root.pal; implicitHeight: 26; label: "Middle"; on: root.cur.vpos === "middle"; onClicked: root.edited(NL.edit(root.cur, "vpos", "middle")) }
                                    Chip { pal: root.pal; implicitHeight: 26; label: "Bottom"; on: root.cur.vpos === "bottom"; onClicked: root.edited(NL.edit(root.cur, "vpos", "bottom")) }
                                }
                            }
                        }
                        NbSlider { visible: root.cur.vpos !== "middle"; Layout.fillWidth: true; pal: root.pal; label: "Distance from edge"; from: -120; to: 300; value: root.cur.offY; zeroText: "Default"; onPicked: v => root.edited(NL.edit(root.cur, "offY", v)) }
                        Row {
                            visible: root.cur.vpos !== "middle"
                            spacing: 8
                            Chip { pal: root.pal; implicitHeight: 30; label: "Line up with the popups"; onClicked: root.edited(NL.edit(root.cur, "offY", 16 - root.pal.boxTop)) }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Default distance"; on: root.cur.offY === 0; onClicked: root.edited(NL.edit(root.cur, "offY", 0)) }
                        }
                        Item { Layout.preferredHeight: 4 }
                    }
                }
            }
        }

        // a few stars flying over everything on the card (Settings > Look > Moving stars)
        BarStars { z: 20; anchors.fill: parent; anchors.margins: 14; pal: root.pal; count: 8; loopMs: 140000; sizeScale: 1.4; active: root.open; visible: root.open && root.movingStars }
    }
    property bool movingStars: true
}
