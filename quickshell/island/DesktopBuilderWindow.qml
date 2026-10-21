import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import "DeskSpots.js" as DS
import "WidgetData.js" as WD

// The desktop builder window (Settings > Appearance > Desktop builder > "Open ..."). A dimmed overlay with one card on it.
//   Left:   a picture of the screen (it takes most of the card): the wallpaper (or the plain background), its blur, the moving
//           stars and the four corners with the box that opens from each: click a box, then the corner you want it in.
//           (The widgets are not in the picture: "Place them on the desktop" puts them right on the real screen.)
//   Right:  wallpaper on / off + blur + background, the moving stars, the corner of each box, the notification trigger.
// The switch in the header picks WHICH screen you build: the desktop, or the lock screen (its background, blur and tint, its constellations
// and splash, the built-in and your own widgets, and the same "Open the widget builder" / "Place them" buttons, aimed at the lock screen).
// Every change is saved and applied to the real desktop at once (it emits changed(key, value); Settings writes "opt:<key>").
Item {
    id: root
    property var pal
    property bool open: false
    property var opt: ({})
    property string wallpaperPath: ""
    property bool globalClick: false     // Settings > Edge boxes: what a box with no own choice does (see DS.trig)
    property string target: "desktop"    // "desktop" or "lock" (Settings dbTarget)
    readonly property bool lockT: target === "lock"
    signal changed(string key, var value)
    signal closed()
    signal targetPicked(string t)
    signal openWidgets(string which)     // the Widget builder (how each widget looks); which = "desktop" or "lock"
    signal editDesktop(string which)     // place the widgets right on that screen

    readonly property bool wallOn: !opt || opt.deskWall !== false
    readonly property real blurAmt: Math.max(0, Math.min(1, (opt && opt.deskBlur !== undefined ? Number(opt.deskBlur) : 0) / 100))
    readonly property string bgKind: (opt && opt.deskBg) || "theme"
    readonly property bool starsOn: !!opt && opt.deskStars === true
    readonly property var spots: DS.normalize(opt ? opt.boxSpots : null)
    readonly property var wlayout: WD.normalize(opt ? opt.deskWidgets : null)
    readonly property string barStyle: (opt && opt.barStyle) || "island"
    readonly property string widgetMode: (opt && opt.deskNotes) || "off"       // off | notes | both
    property string pick: ""                       // the box that was clicked and is waiting for a corner
    // ---- the lock screen (Lock.qml; the defaults are shell.qml's)
    readonly property bool lockWall: !!opt && opt.lockBg === "wallpaper"
    readonly property real lockBlurAmt: Math.max(0, Math.min(1, num("lockBlur", 40) / 64))
    readonly property real lockTint: Math.max(0, Math.min(0.95, num("lockTint", 0.55)))
    readonly property var lockLayout: WD.normalizeFor(opt ? opt.lockDeskWidgets : null, "lock")
    readonly property bool lockOwnOn: WD.isOn(opt, "lock")
    readonly property bool starsMaster: !opt || opt.stars !== false
    readonly property bool splashMaster: !opt || opt.splash !== false
    function flag(k, d) { return opt && opt[k] !== undefined ? opt[k] === true : d }
    readonly property var lockResetValues: ({ lockBg: "solid", lockBlur: 40, lockTint: 0.55, lockWidgets: false, lockSwitch: false,
                                              lockDeskWidgetsOn: true, starsLock: true, splashLock: true, splashUnlock: true })

    function num(k, d) { return opt && opt[k] !== undefined ? Number(opt[k]) : d }
    function put(k, v) { root.changed(k, v) }
    // Sliders send a value for every pixel of a drag, and every value rewrites the shared options (and re-blurs the real
    // wallpaper). putLive passes the first one at once, then at most one every 70 ms, always ending on the last value.
    property var pending: ({})
    function putLive(k, v) {
        if (liveT.running) { var p = pending; p[k] = v; pending = p; return }
        root.changed(k, v)
        liveT.start()
    }
    Timer {
        id: liveT
        interval: 70
        onTriggered: {
            var p = root.pending
            root.pending = ({})
            var any = false
            for (var k in p) { root.changed(k, p[k]); any = true }
            if (any) liveT.start()
        }
    }
    function flushLive() {
        var p = root.pending
        root.pending = ({})
        for (var k in p) root.changed(k, p[k])
    }
    function moveBox(id, corner) { root.put("boxSpots", DS.move(opt ? opt.boxSpots : null, id, corner)); root.pick = "" }
    function resetAll() {
        liveT.stop(); root.pending = ({})
        for (var k in DS.resetValues) put(k, DS.resetValues[k])
        put("boxSpots", DS.clone(DS.defaults))
        put("boxTrig", ({}))
        root.pick = ""
    }
    function resetLock() {
        liveT.stop(); root.pending = ({})
        for (var k in lockResetValues) put(k, lockResetValues[k])
    }

    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
    onOpenChanged: { if (open) { pick = ""; Qt.callLater(function () { root.forceActiveFocus() }) } else flushLive() }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })
    Keys.onPressed: function (e) { if (e.key === Qt.Key_Escape) { if (root.pick !== "") root.pick = ""; else root.closed(); e.accepted = true } }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.45)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }

    Glass {
        id: card
        pal: root.pal
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 1560)
        height: Math.min(parent.height - 40, 900)
        radius: root.pal.rXl
        opacityBody: root.pal.solid ? 1 : 0.78
        border.color: Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 14

            // ---- header
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Rectangle { Layout.alignment: Qt.AlignVCenter; width: 8; height: 8; radius: 4; color: root.pal.accent }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text { text: root.lockT ? "Lock screen builder" : "Desktop builder"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
                    Text { text: root.lockT ? "The picture on the left is your lock screen: its background, and outlines where the clock and the password box sit. Everything else is on the right."
                                            : "The picture on the left is your screen: click a box, then the corner it should open from. Everything else is on the right."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                }
                Item { Layout.fillWidth: true }
                SegSwitch {
                    Layout.alignment: Qt.AlignVCenter
                    pal: root.pal
                    options: [{ k: "desktop", t: "Desktop" }, { k: "lock", t: "Lock screen" }]
                    current: root.target
                    onPicked: k => { root.pick = ""; root.flushLive(); root.targetPicked(k) }
                }
                ActionChip { pal: root.pal; label: root.lockT ? "Reset the lock screen" : "Reset the desktop"; doneLabel: "Reset"; onClicked: root.lockT ? root.resetLock() : root.resetAll() }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 24

                // ================================================ the picture of the screen
                Rectangle {
                    id: stage
                    Layout.fillHeight: true
                    Layout.preferredWidth: Math.max(470, Math.round((card.width - 56 - 24) * 0.64))
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.55)
                    border.width: 1
                    border.color: root.pal.lineTint
                    clip: true
                    NbCap { pal: root.pal; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 14; text: "LIVE PREVIEW" }

                    // the screen, at the real aspect ratio
                    Item {
                        id: scr
                        readonly property real ratio: Math.max(0.5, root.width) / Math.max(0.5, root.height)
                        width: Math.max(40, Math.min(stage.width - 32, (stage.height - 96) * ratio))
                        height: width / ratio
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 16
                        readonly property real k: width / Math.max(1, root.width)      // preview scale

                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            clip: true
                            color: "#000000"
                            border.width: 1
                            border.color: root.pal.lineTint

                            // plain background (wallpaper off)
                            Rectangle {
                                anchors.fill: parent
                                color: root.bgKind === "black" ? "#000000" : root.pal.bg
                                gradient: root.bgKind === "gradient" ? pvGrad : null
                                Gradient {
                                    id: pvGrad
                                    GradientStop { position: 0.0; color: root.pal.bg }
                                    GradientStop { position: 1.0; color: Qt.tint(root.pal.bg, Qt.alpha(root.pal.accent, 0.30)) }
                                }
                            }
                            // the wallpaper, small (decoded at preview size, not the real one), blurred like the real thing
                            Image {
                                id: pvImg
                                anchors.fill: parent
                                anchors.margins: -Math.round(root.blurAmt * 56 * scr.k)
                                visible: root.wallOn && source.toString() !== ""
                                source: (root.open && root.wallOn && root.wallpaperPath !== "") ? "file://" + encodeURI(root.wallpaperPath).replace(/#/g, "%23").replace(/\?/g, "%3F") : ""
                                sourceSize: Qt.size(640, 400)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                layer.enabled: root.blurAmt > 0.001
                                layer.effect: MultiEffect { blurEnabled: true; blurMax: 64; blur: root.blurAmt; autoPaddingEnabled: false }
                            }
                            DesktopStars {
                                anchors.fill: parent
                                pal: root.pal
                                opt: root.opt
                                previewScale: Math.max(0.35, scr.k * 1.6)
                                visible: root.open && !root.lockT
                            }

                            // ---- the lock screen: the theme colour, or the wallpaper blurred under the tint sheet (Lock.qml), and its furniture
                            Item {
                                anchors.fill: parent
                                visible: root.lockT
                                Rectangle { anchors.fill: parent; color: root.pal.bg }
                                Image {
                                    anchors.fill: parent
                                    anchors.margins: -Math.round(root.lockBlurAmt * 56 * scr.k)
                                    visible: root.lockWall && source.toString() !== ""
                                    source: (root.open && root.lockT && root.lockWall && root.wallpaperPath !== "") ? "file://" + encodeURI(root.wallpaperPath).replace(/#/g, "%23").replace(/\?/g, "%3F") : ""
                                    sourceSize: Qt.size(640, 400)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: false
                                    layer.enabled: root.lockBlurAmt > 0.001
                                    layer.effect: MultiEffect { blurEnabled: true; blurMax: 64; blur: root.lockBlurAmt; autoPaddingEnabled: false }
                                }
                                Rectangle { anchors.fill: parent; visible: root.lockWall; color: root.pal.bg; opacity: root.lockTint }
                                // the same places DesktopEditor.qml outlines (Lock.qml: the clock at 16 % of the height, the password box from 52 %)
                                Rectangle {
                                    x: (parent.width - width) / 2; y: parent.height * 0.16
                                    width: 360 * scr.k; height: 170 * scr.k; radius: 16 * scr.k
                                    color: "transparent"; border.width: 1; border.color: Qt.alpha(root.pal.text, 0.35)
                                    Text { anchors.centerIn: parent; text: Qt.formatTime(new Date(), "hh:mm"); color: Qt.alpha(root.pal.text, 0.75); font.family: root.pal.uiFont; font.pixelSize: Math.max(10, 64 * scr.k); font.weight: Font.Light }
                                }
                                Rectangle {
                                    x: (parent.width - width) / 2; y: parent.height * 0.52
                                    width: 340 * scr.k; height: 210 * scr.k; radius: 16 * scr.k
                                    color: "transparent"; border.width: 1; border.color: Qt.alpha(root.pal.text, 0.35)
                                    Text { anchors.centerIn: parent; text: "password"; color: Qt.alpha(root.pal.text, 0.5); font.family: root.pal.uiFont; font.pixelSize: Math.max(8, 13 * scr.k) }
                                }
                                // your own lock screen widgets, as boxes about where they sit (linked ones by their own place; the exact
                                // spot and size: "Place them on the lock screen")
                                Repeater {
                                    model: root.lockOwnOn ? root.lockLayout.items.filter(function (it) { return it.off !== true }) : []
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property var t: WD.typeOf(modelData.type)
                                        readonly property real rw: (t ? t.size[0] : 160) * modelData.scale
                                        readonly property real rh: (t ? t.size[1] : 60) * modelData.scale
                                        x: WD.posX(modelData, root.width, rw, 24) * scr.k
                                        y: WD.posY(modelData, root.height, rh, 24, 24) * scr.k
                                        width: Math.max(6, rw * scr.k); height: Math.max(6, rh * scr.k)
                                        radius: 4
                                        color: Qt.alpha(root.pal.accent, 0.18); border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.6)
                                        Text { anchors.centerIn: parent; width: parent.width - 4; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: WD.nameOf(modelData.type); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: Math.max(7, 11 * scr.k) }
                                    }
                                }
                            }

                            // ---- the four corners
                            Repeater {
                                model: root.lockT ? [] : ["tl", "tr", "bl", "br"]
                                delegate: Item {
                                    id: slot
                                    required property string modelData
                                    readonly property string c: modelData
                                    readonly property string boxId: DS.boxAt(root.opt ? root.opt.boxSpots : null, c)
                                    readonly property bool atRight: c.charAt(1) === "r"
                                    readonly property bool atBottom: c.charAt(0) === "b"
                                    readonly property bool picked: boxId !== "" && boxId === root.pick
                                    readonly property bool target: root.pick !== "" && boxId !== root.pick
                                    z: 4
                                    width: Math.min(scr.width * 0.30, 190)
                                    height: Math.min(scr.height * 0.20, 76)
                                    x: atRight ? scr.width - width - 8 : 8
                                    y: atBottom ? scr.height - height - 8 : 8

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 10
                                        color: slot.picked ? Qt.alpha(root.pal.accent, 0.35) : (slot.target && ma.containsMouse ? Qt.alpha(root.pal.accent, 0.25) : Qt.alpha(root.pal.bg, 0.72))
                                        border.width: slot.picked || slot.target ? 2 : 1
                                        border.color: slot.picked ? root.pal.accent : (slot.target ? Qt.alpha(root.pal.accent, 0.7) : root.pal.lineTint)
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        Column {
                                            anchors.centerIn: parent
                                            spacing: 2
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: DS.names[slot.boxId] || ""
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 12
                                                font.weight: Font.DemiBold
                                            }
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: slot.picked ? "pick a corner" : (slot.target ? "move here" : (slot.boxId === "notif" ? ((root.opt && root.opt.notifSpot === "corner" ? "corner trigger" : "edge trigger") + " · " + DS.cornerNames[slot.c]) : DS.cornerNames[slot.c]) + (DS.trig(root.opt, slot.boxId, root.globalClick) ? " · click" : " · hover"))
                                                color: slot.picked ? root.pal.accent : root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 10
                                            }
                                        }
                                        MouseArea {
                                            id: ma
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (root.pick === "") root.pick = slot.boxId
                                                else if (root.pick === slot.boxId) root.pick = ""
                                                else root.moveBox(root.pick, slot.c)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.top: scr.bottom
                        anchors.topMargin: 12
                        anchors.leftMargin: 20; anchors.rightMargin: 20
                        text: root.lockT ? "Your lock screen widgets are drawn as boxes where they sit. \"Place them on the lock screen\" (right) moves and resizes the real ones. The boxes of the desktop (notifications, utilities ...) do not open on a locked screen."
                              : (root.pick !== "" ? ("Now click the corner for " + DS.names[root.pick] + ". Esc cancels.") : "Click a box, then click the corner you want it to open from. A box dropped on a taken corner swaps places with it.")
                        color: root.pick !== "" && !root.lockT ? root.pal.accent : root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 11
                        lineHeight: 1.25
                        wrapMode: Text.WordWrap
                    }
                }

                // ================================================ the controls
                Flickable {
                    id: ctl
                    Layout.minimumWidth: 340
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

                        // ================ the desktop
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !root.lockT
                            spacing: 12

                            // ---- wallpaper
                            NbCap { pal: root.pal; text: "WALLPAPER" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Show the wallpaper"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.wallOn; onToggled: root.put("deskWall", !root.wallOn) }
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: !root.wallOn
                                text: "No picture is loaded while this is off (it also frees the memory it used). The colours of the island, terminals and apps still follow the last wallpaper."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            NbSlider {
                                Layout.fillWidth: true
                                visible: root.wallOn
                                pal: root.pal; label: "Blur"; from: 0; to: 100; unit: " %"; zeroText: "Off"
                                value: Math.round(root.num("deskBlur", 0))
                                onPicked: v => root.putLive("deskBlur", v)
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: root.wallOn && root.blurAmt > 0
                                text: "A blurred wallpaper is drawn through a GPU effect; it only works again when the picture changes, but on a weak GPU keep it low."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            ChipRow {
                                Layout.fillWidth: true
                                visible: !root.wallOn
                                pal: root.pal; label: "Background"
                                options: [["theme", "Theme colour"], ["black", "Black"], ["gradient", "Gradient"]]
                                current: root.bgKind
                                onPicked: id => root.put("deskBg", id)
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- stars
                            NbCap { pal: root.pal; text: "MOVING STARS" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Moving stars on the desktop"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.starsOn; onToggled: root.put("deskStars", !root.starsOn) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "They float above the wallpaper, or above the plain background when the wallpaper is off. They stand still (and cost nothing) in Gaming mode."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: root.starsOn
                                spacing: 10
                                NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Amount"; from: 10; to: 250; unit: ""; value: Math.round(root.num("deskStarCount", 70)); onPicked: v => root.putLive("deskStarCount", v) }
                                NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Speed"; from: 10; to: 400; unit: " %"; value: Math.round(root.num("deskStarSpeed", 1) * 100); onPicked: v => root.putLive("deskStarSpeed", v / 100) }
                                NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Size"; from: 50; to: 300; unit: " %"; value: Math.round(root.num("deskStarSize", 1) * 100); onPicked: v => root.putLive("deskStarSize", v / 100) }
                                ChipRow {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Direction"
                                    options: [["right", "Right"], ["left", "Left"], ["up", "Up"], ["down", "Down"], ["diag", "Diagonal"]]
                                    current: (root.opt && root.opt.deskStarDir) || "right"
                                    onPicked: id => root.put("deskStarDir", id)
                                }
                                ChipRow {
                                    Layout.fillWidth: true
                                    pal: root.pal; label: "Colour"
                                    options: [["mix", "Mixed"], ["accent", "Accent"], ["white", "White"]]
                                    current: (root.opt && root.opt.deskStarTone) || "mix"
                                    onPicked: id => root.put("deskStarTone", id)
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Text { Layout.fillWidth: true; text: "Twinkle"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    Toggle { pal: root.pal; on: !(root.opt && root.opt.deskStarTwinkle === false); onToggled: root.put("deskStarTwinkle", (root.opt && root.opt.deskStarTwinkle === false)) }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Text { Layout.fillWidth: true; text: "Now and then a shooting star"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    Toggle { pal: root.pal; on: !!root.opt && root.opt.deskStarShoot === true; onToggled: root.put("deskStarShoot", !(root.opt && root.opt.deskStarShoot === true)) }
                                }
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- the top bar and the widgets
                            NbCap { pal: root.pal; text: "TOP BAR" }
                            ChipRow {
                                Layout.fillWidth: true
                                pal: root.pal; label: "Bar"
                                options: [["island", "Island"], ["notch", "Notch"], ["custom", "Custom"], ["off", "Off"]]
                                current: root.barStyle
                                onPicked: id => root.put("barStyle", id)
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.barStyle === "off" ? "No bar. The launcher (Super tap), the media and performance pages and every box still open from the top edge, so put the clock, workspaces and stats on the desktop as widgets." : "Switch the bar off once your desktop widgets do its job."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            NbCap { pal: root.pal; text: "WIDGETS  ·  " + root.wlayout.items.length }
                            Text {
                                Layout.fillWidth: true
                                text: "\"Place them on the desktop\" lets you drag the real widgets right on the screen (the wheel resizes them). The Widget builder changes how each one looks and links widgets together, for example the visualizer to the song title."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                ActionChip { pal: root.pal; label: "Open the widget builder"; on: true; onClicked: root.openWidgets("desktop") }
                                ActionChip { pal: root.pal; label: "Place them on the desktop"; onClicked: root.editDesktop("desktop") }
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- where the boxes open
                            NbCap { pal: root.pal; text: "ACTIVATION ZONES  ·  WHERE THE BOXES OPEN" }
                            Text {
                                Layout.fillWidth: true
                                text: "Each of the four boxes (Notifications, Utilities, Background apps, Console) opens from the corner you pick. Moving a box onto an occupied corner swaps them."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            Repeater {
                                model: DS.order
                                delegate: ChipRow {
                                    id: boxRow
                                    required property string modelData
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    label: DS.names[modelData]
                                    labelWidth: 104; fit: true
                                    options: DS.corners.map(function (c) { return [c, DS.cornerNames[c]] })
                                    current: root.spots[modelData]
                                    onPicked: id => root.moveBox(boxRow.modelData, id)
                                }
                            }
                            // ---- how each box opens: its own hover / click, or like the rest (Settings > Edge boxes)
                            NbCap { pal: root.pal; text: "OPENS ON" }
                            Text {
                                Layout.fillWidth: true
                                text: "Hover opens a box when the pointer reaches its corner and closes it when the pointer leaves. Click needs a click on the corner (a small dot shows where) and keeps the box open until you click elsewhere. \"Like the rest\" follows Settings > Edge boxes (now: " + (root.globalClick ? "click" : "hover") + ")."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            Repeater {
                                model: DS.order
                                delegate: ChipRow {
                                    id: trigRow
                                    required property string modelData
                                    readonly property var own: root.opt && root.opt.boxTrig ? root.opt.boxTrig[modelData] : undefined
                                    Layout.fillWidth: true
                                    pal: root.pal
                                    label: DS.names[modelData]
                                    labelWidth: 104; fit: true
                                    options: [["default", "Like the rest"], ["hover", "Hover"], ["click", "Click"]]
                                    current: own === "hover" || own === "click" ? own : "default"
                                    onPicked: id => root.put("boxTrig", DS.setTrig(root.opt, trigRow.modelData, id))
                                }
                            }
                            ChipRow {
                                Layout.fillWidth: true
                                pal: root.pal; label: "Notif trigger"
                                options: [["edge", "Screen edge strip"], ["corner", "Corner trigger"]]
                                current: (root.opt && root.opt.notifSpot === "corner") ? "corner" : "edge"
                                onPicked: id => root.put("notifSpot", id)
                            }
                        }

                        // ================ the lock screen (Lock.qml): the same kind of choices as the desktop, for the locked screen
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.lockT
                            spacing: 12

                            // ---- background
                            NbCap { pal: root.pal; text: "BACKGROUND" }
                            ChipRow {
                                Layout.fillWidth: true
                                pal: root.pal; label: "Background"
                                options: [["solid", "Theme colour"], ["wallpaper", "Blurred wallpaper"]]
                                current: root.lockWall ? "wallpaper" : "solid"
                                onPicked: id => root.put("lockBg", id)
                            }
                            NbSlider {
                                Layout.fillWidth: true
                                visible: root.lockWall
                                pal: root.pal; label: "Blur"; from: 4; to: 64; unit: ""
                                value: Math.round(root.num("lockBlur", 40))
                                onPicked: v => root.putLive("lockBlur", v)
                            }
                            NbSlider {
                                Layout.fillWidth: true
                                visible: root.lockWall
                                pal: root.pal; label: "Tint"; from: 0; to: 95; unit: " %"
                                value: Math.round(root.lockTint * 100)
                                onPicked: v => root.putLive("lockTint", v / 100)
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.lockWall ? "Your current wallpaper, blurred, behind the clock and the password box. Tint is how much of the theme colour covers it (0 % = the wallpaper as it is). It is only loaded while the screen is locked." : "The plain colour of your theme."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- constellations and splash
                            NbCap { pal: root.pal; text: "STARS AND SPLASH" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Constellations on the lock screen"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.flag("starsLock", true); onToggled: root.put("starsLock", !root.flag("starsLock", true)) }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Splash on the lock screen (when it is your login)"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.flag("splashLock", true); onToggled: root.put("splashLock", !root.flag("splashLock", true)) }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Splash when you unlock"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.flag("splashUnlock", true); onToggled: root.put("splashUnlock", !root.flag("splashUnlock", true)) }
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: !root.starsMaster || !root.splashMaster
                                text: (!root.starsMaster ? "The constellations need their master switch (Settings > Appearance > Constellations). " : "")
                                      + (!root.splashMaster ? "The splash needs the Splash animation switch (Settings > Power & lock)." : "")
                                color: root.pal.warn; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- widgets: the built-in row and your own
                            NbCap { pal: root.pal; text: "WIDGETS  ·  " + root.lockLayout.items.length }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Your own widgets on the lock screen"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.lockOwnOn; onToggled: root.put("lockDeskWidgetsOn", !root.lockOwnOn) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Built and placed the same way as the desktop ones: \"Place them on the lock screen\" lets you drag them right on the screen (the wheel resizes them), the Widget builder changes how each one looks. Every desktop widget is offered there; nothing on them can be clicked or run while it is locked (the music buttons stay), and the ones that show private things are marked."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                ActionChip { pal: root.pal; label: "Open the widget builder"; on: true; onClicked: root.openWidgets("lock") }
                                ActionChip { pal: root.pal; label: "Place them on the lock screen"; onClicked: root.editDesktop("lock") }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Built-in row: battery, Wi-Fi, notification count, media card"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; wrapMode: Text.WordWrap }
                                Toggle { pal: root.pal; on: root.flag("lockWidgets", false); onToggled: root.put("lockWidgets", !root.flag("lockWidgets", false)) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "The notification count is only the number, never what they say."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            NbCap { pal: root.pal; text: "OTHER USERS" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Switch user button"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.flag("lockSwitch", false); onToggled: root.put("lockSwitch", !root.flag("lockSwitch", false)) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Jump to another user who is logged in, or open a login screen for someone else. This screen stays locked while you are away."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }
        }
    }
}
