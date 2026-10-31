import QtQuick
import Quickshell
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
    // the live wallpaper replaces the picture on the desktop, so the preview shows it too (the sky itself, or a video's still)
    readonly property bool liveOn: !!opt && opt.deskLive === "on"
    readonly property string livePick: (opt && opt.deskLivePick) || "sky"
    readonly property string liveStill: liveOn && livePick !== "sky" ? Quickshell.env("HOME") + "/.cache/island/live-thumbs/" + Qt.md5(livePick) + ".jpg" : ""
    readonly property real blurAmt: Math.max(0, Math.min(1, (opt && opt.deskBlur !== undefined ? Number(opt.deskBlur) : 0) / 100))
    readonly property string bgKind: (opt && opt.deskBg) || "theme"
    // Dim the wallpaper so the widgets read (the same setting as Settings > Widget builder: opt.widgetDim / widgetDimAmt)
    readonly property string dimMode: (opt && opt.widgetDim) || "wall"
    readonly property real dimAmt: Math.max(0.1, Math.min(0.8, opt && opt.widgetDimAmt !== undefined ? Number(opt.widgetDimAmt) : 0.35))
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
        put("boxZone", ({}))
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
        border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 14

            // ---- header (WinHeader: the same in every window)
            WinHeader {
                pal: root.pal
                title: root.lockT ? "Lock screen builder" : "Desktop builder"
                onClosed: root.closed()
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
                    border.width: root.pal.calm ? 0 : 1
                    border.color: root.pal.lineTint
                    clip: true
                    // the screen, at the real aspect ratio (as big as it can be with the dock below it)
                    Item {
                        id: scr
                        readonly property real ratio: Math.max(0.5, root.width) / Math.max(0.5, root.height)
                        width: Math.max(40, Math.min(stage.width - 32, (stage.height - dock.implicitHeight - 96) * ratio))
                        height: width / ratio
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 16
                        readonly property real k: width / Math.max(1, root.width)      // preview scale

                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            clip: true
                            color: "#000000"
                            border.width: root.pal.calm ? 0 : 1
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
                                visible: root.wallOn && source.toString() !== "" && !(root.liveOn && root.livePick === "sky")
                                source: (root.open && root.wallOn && (root.liveStill || root.wallpaperPath) !== "") ? "file://" + encodeURI(root.liveStill || root.wallpaperPath).replace(/#/g, "%23").replace(/\?/g, "%3F") : ""
                                sourceSize: Qt.size(640, 400)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                layer.enabled: root.blurAmt > 0.001
                                layer.effect: MultiEffect { blurEnabled: true; blurMax: 64; blur: root.blurAmt; autoPaddingEnabled: false }
                            }
                            Loader {
                                anchors.fill: parent
                                active: root.open && !root.lockT && root.liveOn && root.livePick === "sky"
                                sourceComponent: LiveSky { pal: root.pal; showWord: !root.opt || root.opt.deskLiveWord !== false }
                            }
                            // Dim the wallpaper (whole picture), as the desktop draws it (Wallpaper.qml)
                            Rectangle {
                                anchors.fill: parent
                                visible: root.wallOn && !root.lockT && root.dimMode === "wall"
                                color: "black"
                                opacity: root.dimAmt
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
                                    // a box with a tag opens from the tag, not from this corner
                                    readonly property string cornerLabel: (boxId !== "" && DS.zoneOf(root.opt, boxId)) ? "opens at its tag" : DS.cornerNames[c]
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
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
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
                                                text: slot.picked ? "pick a corner" : (slot.target ? "move here" : (slot.boxId === "notif" ? ((root.opt && root.opt.notifSpot === "corner" ? "corner trigger" : "edge trigger") + " · " + slot.cornerLabel) : slot.cornerLabel) + (DS.trig(root.opt, slot.boxId, root.globalClick) ? " · click" : " · hover"))
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

                            // ---- wake spots: drag a tag to any place on any edge; that is where the box wakes (hover / click). A tag on its
                            // own corner = the default.
                            Repeater {
                                model: root.lockT ? [] : DS.order
                                delegate: Rectangle {
                                    id: tag
                                    required property string modelData
                                    readonly property var zone: DS.zoneOf(root.opt, modelData)
                                    readonly property string corner: (root.spots && root.spots[modelData]) || "tr"
                                    property bool dragging: false
                                    property string dEdge: ""
                                    property real dPos: 0
                                    readonly property string edge: dragging ? dEdge : (zone ? zone.edge : (corner.charAt(0) === "t" ? "top" : "bottom"))
                                    readonly property real pos: dragging ? dPos : (zone ? zone.pos : (corner.charAt(1) === "l" ? 0 : 1))
                                    readonly property bool horiz: edge === "top" || edge === "bottom"
                                    z: 8
                                    // the box as it will come out: flush with the tag's edge, at the tag's place along it (the same rule the real box uses,
                                    // DS.along). Shown while the tag is dragged and for every box that has a tag.
                                    Rectangle {
                                        parent: scr
                                        z: 5
                                        visible: tag.zone !== null || tag.dragging
                                        readonly property real gw: Math.min(scr.width * 0.27, 170)
                                        readonly property real gh: Math.min(scr.height * 0.36, 118)
                                        width: gw; height: gh; radius: 8
                                        x: tag.edge === "left" ? 2 : tag.edge === "right" ? scr.width - gw - 2 : DS.along(tag.pos, scr.width, gw, 6)
                                        y: tag.edge === "top" ? 2 : tag.edge === "bottom" ? scr.height - gh - 2 : DS.along(tag.pos, scr.height, gh, 6)
                                        color: Qt.alpha(root.pal.accent, tag.dragging ? 0.20 : 0.12)
                                        border.width: 1; border.color: Qt.alpha(root.pal.accent, tag.dragging ? 0.8 : 0.45)
                                        Text {
                                            anchors.centerIn: parent
                                            text: DS.names[tag.modelData]
                                            color: root.pal.text
                                            opacity: 0.8
                                            font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold
                                        }
                                    }
                                    width: 52; height: 18; radius: 9
                                    color: dragging ? root.pal.accent : Qt.alpha(root.pal.accent, zone ? 0.85 : 0.5)
                                    border.width: 1; border.color: Qt.alpha(root.pal.bg, 0.6)
                                    x: edge === "left" ? 2 : edge === "right" ? scr.width - width - 2 : Math.round(pos * (scr.width - width))
                                    y: edge === "top" ? 2 : edge === "bottom" ? scr.height - height - 2 : Math.round(pos * (scr.height - height))
                                    Text { anchors.centerIn: parent; text: DS.shortNames[tag.modelData]; color: root.pal.bg; font.family: root.pal.uiFont; font.pixelSize: 10; font.weight: Font.DemiBold }
                                    function follow(mx, my) {
                                        var q = tagMa.mapToItem(scr, mx, my)
                                        var d = { left: q.x, right: scr.width - q.x, top: q.y, bottom: scr.height - q.y }
                                        var best = "top"
                                        for (var e in d) if (d[e] < d[best]) best = e
                                        dEdge = best
                                        var f = (best === "top" || best === "bottom") ? q.x / scr.width : q.y / scr.height
                                        dPos = Math.max(0, Math.min(1, f))
                                    }
                                    MouseArea {
                                        id: tagMa
                                        anchors.fill: parent
                                        cursorShape: Qt.SizeAllCursor
                                        onPressed: m => { tag.dragging = true; tag.follow(m.x, m.y) }
                                        onPositionChanged: m => { if (pressed) tag.follow(m.x, m.y) }
                                        onReleased: {
                                            var e = tag.dEdge, f = tag.dPos, c = tag.corner
                                            tag.dragging = false
                                            var cl = c.charAt(1) === "l", ct = c.charAt(0) === "t"
                                            var home = ((e === (ct ? "top" : "bottom")) && (cl ? f < 0.05 : f > 0.95))
                                                    || ((e === (cl ? "left" : "right")) && (ct ? f < 0.05 : f > 0.95))
                                            root.put("boxZone", home ? DS.setZone(root.opt, tag.modelData, "", 0) : DS.setZone(root.opt, tag.modelData, e, f))
                                        }
                                        onDoubleClicked: root.put("boxZone", DS.setZone(root.opt, tag.modelData, "", 0))
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
                        // the new style says only what to do next while you are moving a box
                        text: root.pal.zen && root.pal.hideHints && root.pick === "" ? "" : root.lockT ? "Your lock screen widgets are drawn as boxes where they sit. \"Place them on the lock screen\" (right) moves and resizes the real ones. The boxes of the desktop (notifications, utilities ...) do not open on a locked screen."
                              : (root.pick !== "" ? ("Now click the corner for " + DS.names[root.pick] + ". Esc cancels.") : "Click a box, then click the corner you want it to open from (a box dropped on a taken corner swaps places). Or drag a small tag along any edge: that box wakes there and opens from there (the faint box shows where). Double-click a tag to put the box back in its corner.")
                        color: root.pick !== "" && !root.lockT ? root.pal.accent : root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 11
                        lineHeight: 1.25
                        wrapMode: Text.WordWrap
                    }

                    // ---- under the picture: which screen you are building, its main switches, and what to do next
                    Column {
                        id: dock
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 16 }
                        spacing: 14
                        Row {
                            width: parent.width
                            spacing: 8
                            Text { text: root.pal.cap("LIVE PREVIEW"); color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.calm ? 12 : 10; font.letterSpacing: root.pal.calm ? 0.1 : 0.8 }
                            Text { text: Math.round(root.width) + " \u00d7 " + Math.round(root.height); color: Qt.alpha(root.pal.muted, 0.75); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                        }
                        // Desktop | Lock screen as two cards
                        Row {
                            width: parent.width
                            spacing: 10
                            Repeater {
                                model: [{ k: "desktop", t: "Desktop", g: 0xF0379, d: "Wallpaper, stars, widgets and where the boxes open" },
                                        { k: "lock", t: "Lock screen", g: 0xF033E, d: "Background, its own widgets, stars and the splash" }]
                                delegate: Rectangle {
                                    id: tc
                                    required property var modelData
                                    readonly property bool on: root.target === modelData.k
                                    width: (dock.width - 10) / 2
                                    height: 62
                                    radius: root.pal.rMd
                                    color: on ? Qt.alpha(root.pal.accent, 0.15) : (tcMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                    border.width: root.pal.calm ? 0 : 1
                                    border.color: on ? Qt.alpha(root.pal.accent, 0.45) : root.pal.lineSoft
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                    Text {
                                        id: tcG
                                        x: 16; anchors.verticalCenter: parent.verticalCenter
                                        text: String.fromCodePoint(tc.modelData.g)
                                        color: tc.on ? root.pal.accent : root.pal.muted
                                        font.family: root.pal.font; font.pixelSize: 22
                                    }
                                    Column {
                                        anchors { left: tcG.right; leftMargin: 14; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                        spacing: 2
                                        Text { text: tc.modelData.t; color: tc.on ? root.pal.accent : root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                                        Text { visible: !(root.pal.zen && root.pal.hideHints); width: parent.width; elide: Text.ElideRight; text: tc.modelData.d; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                    }
                                    MouseArea { id: tcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (!tc.on) { root.pick = ""; root.flushLive(); root.targetPicked(tc.modelData.k) } }
                                }
                            }
                        }
                        // the switches you reach for most, for the screen picked above (the rest is on the right)
                        Flow {
                            width: parent.width
                            spacing: 8
                            Repeater {
                                model: root.lockT
                                    ? [{ t: "Wallpaper behind it", on: root.lockWall, k: "lockBg", v: root.lockWall ? "solid" : "wallpaper" },
                                       { t: "Its own widgets", on: root.lockOwnOn, k: "lockDeskWidgetsOn", v: !root.lockOwnOn },
                                       { t: "Stars", on: root.flag("starsLock", true), k: "starsLock", v: !root.flag("starsLock", true) },
                                       { t: "Unlock splash", on: root.flag("splashUnlock", true), k: "splashUnlock", v: !root.flag("splashUnlock", true) }]
                                    : [{ t: "Wallpaper", on: root.wallOn, k: "deskWall", v: !root.wallOn },
                                       { t: "Moving stars", on: root.starsOn, k: "deskStars", v: !root.starsOn },
                                       { t: "Widgets", on: root.flag("deskWidgetsOn", true), k: "deskWidgetsOn", v: !root.flag("deskWidgetsOn", true) },
                                       { t: "Top bar", on: root.barStyle !== "off", k: "barStyle", v: root.barStyle === "off" ? "island" : "off" }]
                                delegate: Chip {
                                    required property var modelData
                                    pal: root.pal
                                    implicitHeight: 32
                                    glyph: String.fromCodePoint(modelData.on ? 0xF012C : 0xF0156)
                                    label: modelData.t
                                    on: modelData.on
                                    onClicked: root.put(modelData.k, modelData.v)
                                }
                            }
                        }
                        Flow {
                            width: parent.width
                            spacing: 8
                            ActionChip { pal: root.pal; implicitHeight: 32; label: "Open the widget builder"; on: true; onClicked: root.openWidgets(root.lockT ? "lock" : "desktop") }
                            ActionChip { pal: root.pal; implicitHeight: 32; label: root.lockT ? "Place them on the lock screen" : "Place them on the desktop"; onClicked: root.editDesktop(root.lockT ? "lock" : "desktop") }
                            ActionChip { pal: root.pal; implicitHeight: 32; label: root.lockT ? "Reset the lock screen" : "Reset the desktop"; doneLabel: "Reset"; onClicked: root.lockT ? root.resetLock() : root.resetAll() }
                        }
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
                            NbCap { pal: root.pal; text: root.pal.cap("WALLPAPER") }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Show the wallpaper"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.wallOn; onToggled: root.put("deskWall", !root.wallOn) }
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: !(root.pal.zen && root.pal.hideHints) && (!root.wallOn)
                                text: "Off frees its memory. Colours still follow the last wallpaper."
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
                                visible: !(root.pal.zen && root.pal.hideHints) && (root.wallOn && root.blurAmt > 0)
                                text: "Uses the GPU only when the picture changes. Keep it low on a weak GPU."
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                            ChipRow {
                                Layout.fillWidth: true
                                visible: root.wallOn
                                pal: root.pal; label: "Dim it"
                                options: [["off", "No"], ["wall", "Whole picture"], ["auto", "Behind widgets"]]
                                current: root.dimMode === "widgets" ? "auto" : root.dimMode
                                onPicked: id => root.put("widgetDim", id)
                            }
                            NbSlider {
                                Layout.fillWidth: true
                                visible: root.wallOn && root.dimMode !== "off"
                                pal: root.pal; label: "How dark"; from: 10; to: 80; unit: " %"
                                value: Math.round(root.dimAmt * 100)
                                onPicked: v => root.putLive("widgetDimAmt", v / 100)
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: !(root.pal.zen && root.pal.hideHints) && (root.wallOn)
                                text: root.dimMode === "off" ? "Widgets choose their colours from the picture as it is." : "Keeps the widgets readable on light or busy wallpapers; their text colour follows the dim."
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
                            NbCap { pal: root.pal; text: root.pal.cap("MOVING STARS") }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Moving stars on the desktop"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.starsOn; onToggled: root.put("deskStars", !root.starsOn) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "They stand still in Gaming mode."
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
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
                            NbCap { pal: root.pal; text: root.pal.cap("TOP BAR") }
                            ChipRow {
                                Layout.fillWidth: true
                                pal: root.pal; label: "Bar"
                                options: [["island", "Island"], ["notch", "Notch"], ["rail", "Rail"], ["custom", "Custom"], ["off", "Off"]]
                                current: root.barStyle
                                onPicked: id => root.put("barStyle", id)
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.barStyle === "off" ? "No bar. The launcher (Super tap), the media and performance pages and every box still open from the top edge, so put the clock, workspaces and stats on the desktop as widgets." : "Switch the bar off once your desktop widgets do its job."
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            NbCap { pal: root.pal; text: root.pal.cap("WIDGETS  ·  " + root.wlayout.items.length) }
                            Text {
                                Layout.fillWidth: true
                                text: "\"Place them on the desktop\" lets you drag the real widgets right on the screen (the wheel resizes them). The Widget builder changes how each one looks and links widgets together, for example the visualizer to the song title."
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
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
                            NbCap { pal: root.pal; text: root.pal.cap("ACTIVATION ZONES  ·  WHERE THE BOXES OPEN") }
                            Text {
                                Layout.fillWidth: true
                                text: "Pick the corner each box opens from. Taking a used corner swaps the two. A box you gave a tag (drag it along an edge in the picture) wakes and opens from its tag instead."
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
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
                            ChipRow {
                                Layout.fillWidth: true
                                pal: root.pal; label: "Boxes come out of"
                                options: [["corner", "The corner (top / bottom and side)"], ["side", "The side only"]]
                                current: (root.opt && root.opt.boxOut === "side") ? "side" : "corner"
                                onPicked: id => root.put("boxOut", id)
                            }
                            Hint {
                                pal: root.pal
                                Layout.fillWidth: true
                                visible: !root.pal.zen || !root.pal.hideHints
                                text: "Needs the screen border (Bar builder). The corner: a box is attached to both borders of its corner and slides out of the corner. The side only: it is attached to the side border."
                                color: root.pal.muted; fontFamily: root.pal.uiFont; pixelSize: 10
                            }
                            // ---- how each box opens: its own hover / click, or like the rest (Settings > Edge boxes)
                            NbCap { pal: root.pal; text: root.pal.cap("OPENS ON") }
                            Hint {
                                pal: root.pal
                                Layout.fillWidth: true
                                text: "Hover: opens at the corner, closes when you leave. Click: a click on the corner, stays until you click elsewhere. \"Like the rest\" is now " + (root.globalClick ? "click" : "hover") + "."
                                color: root.pal.muted; fontFamily: root.pal.uiFont; pixelSize: 10
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
                                pal: root.pal; label: "Console shows"
                                options: [["terminal", "Terminal"], ["chat", "AI Chatbox only"]]
                                current: (root.opt && (root.opt.consoleMode === "chat" || root.opt.consoleMode === "luna" || root.opt.consoleLuna === true)) ? "chat" : "terminal"
                                onPicked: id => {
                                    root.put("consoleMode", id)
                                    root.put("consoleLuna", false)
                                }
                            }
                            Hint {
                                pal: root.pal
                                Layout.fillWidth: true
                                text: "AI Chatbox only: the console corner and key open the AI chatbox and never the terminal. Pick Luna, Ollama or any API from the dropdown at its top right."
                                color: root.pal.muted; fontFamily: root.pal.uiFont; pixelSize: 10
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
                            NbCap { pal: root.pal; text: root.pal.cap("BACKGROUND") }
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
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- constellations and splash
                            NbCap { pal: root.pal; text: root.pal.cap("STARS AND SPLASH") }
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
                                      + (!root.splashMaster ? "The splash needs the Splash animation switch (Settings > Lock screen)." : "")
                                color: root.pal.warn; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            // ---- widgets: the built-in row and your own
                            NbCap { pal: root.pal; text: root.pal.cap("WIDGETS  ·  " + root.lockLayout.items.length) }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Your own widgets on the lock screen"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.lockOwnOn; onToggled: root.put("lockDeskWidgetsOn", !root.lockOwnOn) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Built and placed the same way as the desktop ones: \"Place them on the lock screen\" lets you drag them right on the screen (the wheel resizes them), the Widget builder changes how each one looks. Every desktop widget is offered there; nothing on them can be clicked or run while it is locked (the music buttons stay), and the ones that show private things are marked."
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
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
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                            NbCap { pal: root.pal; text: root.pal.cap("OTHER USERS") }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Switch user button"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.flag("lockSwitch", false); onToggled: root.put("lockSwitch", !root.flag("lockSwitch", false)) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Switch to another user. This session stays locked."
                                visible: !(root.pal.zen && root.pal.hideHints)      // an explanation: the new style leaves it to ask >
                                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }
        }
    }
}
