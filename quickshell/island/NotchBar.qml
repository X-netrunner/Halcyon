import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// Bar style "Notch" (Settings > Bar style): a bar that hangs from the very top edge of the screen.
// Its top corners flare outwards into the screen edge (inverted corners), its bottom corners are rounded.
//   left: workspaces (the focused one is a long pill, the others small dots)   middle: time   right: Wi-Fi bars + battery
// What is shown is chosen in Settings > Bar style (opt.notch*). The "island" style (the floating pill) is untouched:
// shell.qml only loads this file while opt.barStyle === "notch".
//
// The performance / media pages and the launcher are still drawn by the island in shell.qml; in this style they drop down
// just below this bar (the bar stays where it is).
PanelWindow {
    id: win

    // ---- fed by shell.qml
    property var pal
    property var stats: ({})
    property var net: ({})
    property var cava: []
    property bool playing: false
    property string activeSpecial: ""
    property bool caffeine: false
    property int bgCount: 0
    property var opt: ({})
    property string barPadding: "normal"      // low | normal | high (Settings > Bar > Bar size and padding)
    property bool autoHide: false
    property bool clock24: false
    property bool showStats: false            // Settings > Bar > "When you hover the bar" = Live stats
    property bool pageOpen: false             // the performance / media page or the launcher is open (bar is not clickable behind it)
    property int gaps: 8                      // Hyprland's gaps (see exclusiveZone)

    signal workspaceClicked(int wsId)
    signal workspaceScrolled(int dir)         // +1 wheel up, -1 wheel down
    signal specialClicked(string name)
    signal statusClicked()
    signal bgClicked()
    signal pageStep(int dir)                  // wheel / drag on the bar: -1 = media, +1 = performance (shell.qml go())
    signal hoverEdited(bool on)               // the pointer is on the bar / left it (shell.qml opens perf / media after a moment)

    // ---- what is shown (all remembered in settings.json under "opt")
    readonly property bool showWs: opt.notchWs !== false
    readonly property int wsMin: Math.max(1, Math.min(10, Number(opt.notchWsMin || 5)))     // workspaces always shown (1..N)
    readonly property bool showSpecials: opt.notchSpecials !== false
    readonly property bool showViz: opt.notchViz !== false
    readonly property bool showTime: opt.notchTime !== false
    readonly property bool showDate: opt.notchDate === true
    // accent: "theme" (default) = the island's own wallpaper accent; "vivid" pushes it towards a clearer, saturated colour;
    // "accent2" = the second wallpaper colour
    readonly property color ac: {
        var m = opt.notchAccent || "theme"
        if (m === "theme") return pal.accent
        if (m === "accent2") return pal.accent2
        var c = pal.accent
        return Qt.hsla(pal.hueOf(c, 0.5), Math.min(1, Math.max(0.6, c.hslSaturation * 1.7)), pal.light ? 0.40 : 0.58, 1)
    }
    readonly property bool showSeconds: opt.clockSeconds === true
    readonly property bool showWifi: opt.notchWifi !== false
    // Bluetooth: off | connected (only while a device is connected) | on (whenever Bluetooth is on)
    readonly property string btMode: opt.notchBtMode || "connected"
    readonly property bool btShown: net.bt === "on" && (btMode === "on" || (btMode === "connected" && (net.btdev || "") !== ""))
    readonly property string wifiLook: opt.notchWifiStyle || "bars"      // bars | symbol | dots
    readonly property bool centerClock: opt.notchCenter === true         // true: the clock is dead centre (empty space on the shorter side)
    readonly property int groupGap: Math.round(barH * 0.7)               // space between workspaces, clock and status icons
    readonly property bool showBat: opt.notchBat !== false
    readonly property bool showBatPct: opt.notchBatPct === true
    readonly property bool showCaffeine: opt.notchCaffeine !== false
    readonly property bool showBg: opt.notchBg !== false && opt.bgWhere !== "corner"

    // ---- size (Bar size and padding)
    readonly property var sizeSet: ({ low: { h: 26, gap: 3 }, normal: { h: 32, gap: 8 }, high: { h: 40, gap: 12 } })[barPadding] || ({ h: 32, gap: 8 })
    readonly property int barH: sizeSet.h
    readonly property real earR: Math.round(barH * 0.42)       // radius of the flare into the screen edge
    readonly property real cornR: Math.round(barH * 0.42)      // radius of the bottom corners
    readonly property int padX: Math.round(barH * 0.62)        // space between the edge of the bar and its content
    readonly property int textPx: Math.round(barH * 0.44)               // the time
    // workspace capsules: the current one is as tall as the time, the others 15 % smaller. Wi-Fi / battery / Bluetooth use that smaller size.
    readonly property int curH: Math.round(textPx * 1.3)
    readonly property int curW: Math.round(curH * 0.55)
    readonly property int offH: Math.round(curH * 0.85)
    readonly property int offW: Math.round(curW * 0.8)
    readonly property int icoH: offH
    readonly property int iconPx: icoH

    readonly property real bodyWidth: notch.bw        // the straight part of the bar (shell.qml grows the pages out of it)
    readonly property bool shown: !autoHide || peek || hov.hovered
    property bool peek: false
    Timer { id: peekT; interval: 700; onTriggered: win.peek = false }

    anchors { top: true; left: true; right: true }
    implicitHeight: barH + 34                       // room for the soft shadow under the bar
    // windows start below the bar; Hyprland adds its outer gap on top of this zone, so that is taken off again
    exclusiveZone: autoHide ? 0 : Math.max(0, barH + sizeSet.gap - gaps * 2)
    color: "transparent"

    WlrLayershell.namespace: "island-notch"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // while a page / the launcher is open the drop-down belongs to the island: keep this window out of the way of the mouse
    mask: Region { regions: [ Region { item: strip }, Region { item: win.pageOpen ? null : notch } ] }

    // thin hot strip along the top edge that brings back an auto-hidden bar
    Item {
        id: strip
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: 420
        height: 5
        HoverHandler { onHoveredChanged: { if (hovered) { peekT.stop(); win.peek = true } else peekT.restart() } }
    }

    // ------------------------------------------------------------------ the bar
    Item {
        id: notch

        // width of the three groups: the left and right one get the same width so the clock sits exactly in the middle
        // The bar is only as wide as what it shows: groups that are empty take no room and no gap, so nothing hangs in the air.
        // (Settings > Bar style > "Keep the clock centred" gives both sides the same width instead.)
        readonly property real sideW: Math.max(leftGroup.width, rightGroup.width)
        readonly property int parts: (leftGroup.width > 0 ? 1 : 0) + (midGroup.width > 0 ? 1 : 0) + (rightGroup.width > 0 ? 1 : 0)
        readonly property real flowW: leftGroup.width + midGroup.width + rightGroup.width + Math.max(0, parts - 1) * win.groupGap
        readonly property real bodyW: win.centerClock ? (sideW * 2 + midGroup.width + win.groupGap * 2 + win.padX * 2) : (flowW + win.padX * 2)
        width: bodyW + win.earR * 2
        height: win.barH
        anchors.horizontalCenter: parent.horizontalCenter
        y: win.shown ? 0 : -(win.barH + 30)
        Behavior on y { NumberAnimation { duration: win.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
        opacity: win.pageOpen ? 0.0 : 1.0
        Behavior on opacity { NumberAnimation { duration: win.pal.dMed } }

        SystemClock { id: clock; precision: win.showSeconds ? SystemClock.Seconds : SystemClock.Minutes }
        readonly property string timeStr: Qt.formatDateTime(clock.date, (win.clock24 ? "HH:mm" : "hh:mm") + (win.showSeconds ? ":ss" : "") + (win.clock24 ? "" : " AP"))
        readonly property string dateStr: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")

        readonly property real r: win.earR
        readonly property real cr: win.cornR
        readonly property real bw: width - 2 * r          // the straight part between the two flares
        readonly property real bh: height

        HoverHandler {
            id: hov
            onHoveredChanged: {
                win.hoverEdited(hovered)
                if (hovered) { peekT.stop() } else peekT.restart()
            }
        }

        // soft halo under the bar: hollow, so the glass is not darkened from behind (rules.lua blurs only what is more opaque)
        Item {
            id: haloBody
            x: notch.r
            width: notch.bw
            y: -60
            height: notch.bh + 60
            visible: win.shown
            HaloShadow {
                anchors.fill: parent
                radius: notch.cr
                spread: 20
                peak: 0.16
            }
        }

        // ---- the outline: flare, straight side, rounded corner, bottom, rounded corner, straight side, flare
        readonly property color fillCol: Qt.alpha(win.pal.bg, Math.min(0.97, win.pal.glassBar + 0.26))
        Shape {
            id: body
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            antialiasing: true

            ShapePath {
                fillColor: notch.fillCol
                strokeColor: "transparent"
                strokeWidth: 0
                startX: 0; startY: 0
                PathArc { x: notch.r; y: notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                PathLine { x: notch.r; y: notch.bh - notch.cr }
                PathArc { x: notch.r + notch.cr; y: notch.bh; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                PathLine { x: notch.r + notch.bw - notch.cr; y: notch.bh }
                PathArc { x: notch.r + notch.bw; y: notch.bh - notch.cr; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                PathLine { x: notch.r + notch.bw; y: notch.r }
                PathArc { x: notch.width; y: 0; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                PathLine { x: 0; y: 0 }
            }
            // faint top sheen, like the other glass surfaces
            ShapePath {
                strokeColor: "transparent"
                strokeWidth: 0
                fillGradient: LinearGradient {
                    x1: 0; y1: 0; x2: 0; y2: notch.bh
                    GradientStop { position: 0.0; color: Qt.alpha(win.pal.text, 0.05) }
                    GradientStop { position: 0.55; color: Qt.alpha(win.pal.text, 0.0) }
                }
                startX: 0; startY: 0
                PathArc { x: notch.r; y: notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                PathLine { x: notch.r; y: notch.bh - notch.cr }
                PathArc { x: notch.r + notch.cr; y: notch.bh; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                PathLine { x: notch.r + notch.bw - notch.cr; y: notch.bh }
                PathArc { x: notch.r + notch.bw; y: notch.bh - notch.cr; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                PathLine { x: notch.r + notch.bw; y: notch.r }
                PathArc { x: notch.width; y: 0; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                PathLine { x: 0; y: 0 }
            }
            // hairline: the same outline, open at the top (nothing is drawn along the screen edge)
            ShapePath {
                fillColor: "transparent"
                strokeColor: win.pal.line
                strokeWidth: 1
                startX: 0; startY: 0
                PathArc { x: notch.r; y: notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
                PathLine { x: notch.r; y: notch.bh - notch.cr }
                PathArc { x: notch.r + notch.cr; y: notch.bh; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                PathLine { x: notch.r + notch.bw - notch.cr; y: notch.bh }
                PathArc { x: notch.r + notch.bw; y: notch.bh - notch.cr; radiusX: notch.cr; radiusY: notch.cr; direction: PathArc.Counterclockwise }
                PathLine { x: notch.r + notch.bw; y: notch.r }
                PathArc { x: notch.width; y: 0; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Clockwise }
            }
        }

        // scroll / two-finger swipe on the bar = change page (the wheel over the workspaces walks through workspaces instead)
        property real wheelAcc: 0
        Timer { id: wheelCool; interval: 450 }
        Timer { id: wheelReset; interval: 300; onTriggered: notch.wheelAcc = 0 }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: e => {
                if (wheelCool.running) return
                var d = Math.abs(e.angleDelta.x) > Math.abs(e.angleDelta.y) ? e.angleDelta.x : e.angleDelta.y
                if (d === 0) return
                notch.wheelAcc += d
                wheelReset.restart()
                if (Math.abs(notch.wheelAcc) < 90) return
                win.pageStep(notch.wheelAcc > 0 ? -1 : 1)
                notch.wheelAcc = 0
                wheelCool.start()
            }
        }
        // hold + drag sideways: left = performance, right = media (like the island)
        property real dragX: 0
        DragHandler {
            id: dragH
            target: null
            xAxis.enabled: true
            yAxis.enabled: false
            onTranslationChanged: if (active) notch.dragX = translation.x
            onActiveChanged: {
                if (active) return
                var dx = notch.dragX
                notch.dragX = 0
                if (dx < -50) win.pageStep(1)
                else if (dx > 50) win.pageStep(-1)
            }
        }

        // ------------------------------------------------------------ content
        // left: workspaces. Vertical capsules (rounded top and bottom, straight sides):
        //   current = the size of the time, vivid wallpaper colour;  with windows = 15 % smaller, faded colour;  empty = 15 % smaller, dim
        Row {
            id: leftGroup
            anchors.left: parent.left
            anchors.leftMargin: notch.r + win.padX
            y: 0
            height: notch.bh
            spacing: Math.max(4, Math.round(win.barH * 0.17))

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function (e) {
                    if (e.angleDelta.y !== 0) win.workspaceScrolled(e.angleDelta.y > 0 ? 1 : -1)
                }
            }

            Repeater {
                model: win.showWs ? win.wsCount : 0
                delegate: Item {
                    id: wsItem
                    required property int index
                    readonly property int wsId: index + 1
                    readonly property var ws: win.findWs(wsId)
                    readonly property bool cur: ws !== null && ws.focused
                    readonly property bool occ: ws !== null && win.wsWindows(ws) > 0
                    width: cur ? win.curW : win.offW
                    height: notch.bh
                    Behavior on width { NumberAnimation { duration: Math.round(win.pal.dMed * 1.1); easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: wsItem.cur ? win.curH : win.offH
                        radius: width / 2
                        color: wsItem.cur ? win.ac
                             : wsItem.occ ? Qt.alpha(win.ac, wsMa.containsMouse ? 0.55 : 0.36)
                             : Qt.alpha(win.pal.text, wsMa.containsMouse ? 0.28 : 0.14)
                        Behavior on height { NumberAnimation { duration: Math.round(win.pal.dMed * 1.1); easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
                        Behavior on color { ColorAnimation { duration: win.pal.dMed } }
                    }
                    MouseArea {
                        id: wsMa
                        anchors.fill: parent
                        anchors.leftMargin: -3
                        anchors.rightMargin: -3
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.workspaceClicked(wsItem.wsId)
                    }
                }
            }

            Repeater {
                model: win.showSpecials ? win.specials : []
                delegate: Item {
                    id: spItem
                    required property var modelData
                    readonly property bool lit: win.activeSpecial === modelData.name
                    visible: lit || win.hasSpecial(modelData.name)
                    width: visible ? win.icoH + 4 : 0
                    height: notch.bh
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(spItem.modelData.glyph)
                        color: spItem.lit ? win.ac : Qt.alpha(win.pal.text, spMa.containsMouse ? 0.8 : 0.5)
                        font.family: win.pal.font
                        font.pixelSize: win.icoH
                        Behavior on color { ColorAnimation { duration: win.pal.dFast } }
                    }
                    MouseArea {
                        id: spMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.specialClicked(spItem.modelData.name)
                    }
                }
            }
        }

        // middle: music bars, time, date, (live stats while hovering). Every child is as tall as the bar.
        Row {
            id: midGroup
            x: win.centerClock ? Math.round((notch.width - width) / 2) : (notch.r + win.padX + (leftGroup.width > 0 ? leftGroup.width + win.groupGap : 0))
            y: 0
            height: notch.bh
            spacing: Math.round(win.barH * 0.3)

            Visualizer {
                visible: win.showViz && win.opt.viz !== "off" && win.playing
                y: Math.round((notch.bh - height) / 2)
                pal: win.pal
                values: win.cava
                active: win.showViz && win.playing
            }
            Text {
                id: timeText
                visible: win.showTime
                height: notch.bh
                verticalAlignment: Text.AlignVCenter
                text: notch.timeStr
                color: win.pal.text
                font.family: win.pal.uiFont
                font.pixelSize: win.textPx
                font.weight: Font.DemiBold
            }
            Text {
                visible: win.showDate
                height: notch.bh
                verticalAlignment: Text.AlignVCenter
                text: notch.dateStr
                color: win.showTime ? win.pal.muted : win.pal.text
                font.family: win.pal.uiFont
                font.pixelSize: win.showTime ? Math.max(10, win.textPx - 2) : win.textPx
                font.weight: win.showTime ? Font.Normal : Font.DemiBold
            }
            // live stats: slide out while the pointer is on the bar (Settings > Bar > When you hover the bar)
            Item {
                height: notch.bh
                implicitWidth: win.showStats ? statsRow.implicitWidth : 0
                width: implicitWidth
                clip: true
                opacity: win.showStats ? 1 : 0
                Behavior on implicitWidth { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
                Behavior on opacity { NumberAnimation { duration: win.pal.dMed } }
                Row {
                    id: statsRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Repeater {
                        model: [
                            { k: "CPU", v: Math.round(win.stats.cpu || 0) + "%", frac: (win.stats.cpu || 0) / 100 },
                            { k: "RAM", v: (win.stats.memGb || "0.0") + "G", frac: (win.stats.mem || 0) / 100 },
                            { k: "TEMP", v: Math.round(win.stats.temp || 0) + "°", frac: (win.stats.temp || 0) / 100 }
                        ]
                        delegate: Row {
                            required property var modelData
                            spacing: 4
                            Text { text: modelData.k; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: win.pal.tCap; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: modelData.v; color: modelData.frac > 0.9 ? win.pal.bad : (modelData.frac > 0.75 ? win.pal.warn : win.pal.text); font.family: win.pal.uiFont; font.pixelSize: win.pal.tBody; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
            }
        }

        // clicking the status icons opens the performance page (under the row, so the background-apps count keeps its own click)
        MouseArea {
            anchors.fill: rightGroup
            anchors.margins: -6
            cursorShape: Qt.PointingHandCursor
            onClicked: win.statusClicked()
        }

        // right: background apps, caffeine, Wi-Fi, Bluetooth, battery (click = performance page).
        // All icons are rounded and smooth, as tall as an empty workspace capsule, and take the wallpaper colour.
        Row {
            id: rightGroup
            anchors.right: parent.right
            anchors.rightMargin: notch.r + win.padX
            y: 0
            height: notch.bh
            spacing: Math.round(win.barH * 0.3)

            // apps alive in the background (Settings > Bar > Background apps count: Bar)
            Item {
                visible: win.showBg && win.bgCount > 0
                width: visible ? bgRow.width : 0
                height: notch.bh
                Row {
                    id: bgRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Text { text: String.fromCodePoint(0xF003B); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: win.bgCount; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: Math.max(10, win.textPx - 2); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: win.bgClicked() }
            }

            // the screen will not sleep or lock
            Item {
                visible: win.showCaffeine && win.caffeine
                width: visible ? cafText.implicitWidth : 0
                height: notch.bh
                Text { id: cafText; anchors.centerIn: parent; text: String.fromCodePoint(0xF0176); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH }
            }

            // Wi-Fi: bars, the classic symbol or dots (Settings > Bar style > Wi-Fi look)
            Item {
                visible: win.showWifi
                width: visible ? wifiIcon.width : 0
                height: notch.bh
                WifiIcon {
                    id: wifiIcon
                    anchors.centerIn: parent
                    pal: win.pal
                    net: win.net
                    look: win.wifiLook
                    tint: win.ac
                    offTint: Qt.alpha(win.ac, 0.3)
                    size: win.icoH
                }
            }

            // Bluetooth: see Settings > Bar style > Bluetooth (off / only when connected / whenever it is on)
            Item {
                visible: win.btShown
                width: visible ? btText.implicitWidth : 0
                height: notch.bh
                Text {
                    id: btText
                    anchors.centerIn: parent
                    text: String.fromCodePoint(0xF00AF)
                    color: (win.net.btdev || "") !== "" ? win.ac : Qt.alpha(win.ac, 0.45)
                    font.family: win.pal.font
                    font.pixelSize: win.icoH
                }
            }

            // battery: a smooth pill with a pill-shaped fill (green while charging, red when low)
            Item {
                id: bat
                visible: win.showBat && win.stats.hasBat === true
                readonly property int bh: Math.round(win.icoH * 0.8)
                readonly property int bw: Math.round(win.icoH * 1.75)
                width: visible ? bw + (win.showBatPct ? pctText.implicitWidth + 5 : 0) : 0
                height: notch.bh
                Rectangle {
                    id: batBody
                    y: Math.round((notch.bh - bat.bh) / 2)
                    width: bat.bw
                    height: bat.bh
                    radius: height / 2
                    antialiasing: true
                    color: "transparent"
                    border.width: 1.5
                    border.color: Qt.alpha(win.ac, 0.85)
                    Rectangle {
                        x: 2.5; y: 2.5
                        height: parent.height - 5
                        width: Math.max(height, (parent.width - 5) * Math.max(0, Math.min(100, win.stats.bat || 0)) / 100)
                        radius: height / 2
                        antialiasing: true
                        color: win.stats.charging ? win.pal.good : ((win.stats.bat || 0) <= 20 ? win.pal.bad : win.ac)
                        Behavior on width { NumberAnimation { duration: win.pal.dMed } }
                    }
                }
                Text {
                    id: pctText
                    visible: win.showBatPct
                    x: bat.bw + 5
                    height: notch.bh
                    verticalAlignment: Text.AlignVCenter
                    text: (win.stats.bat || 0) + "%"
                    color: win.pal.text
                    font.family: win.pal.uiFont
                    font.pixelSize: Math.max(10, win.textPx - 2)
                    font.weight: Font.Medium
                }
            }

        }
    }

    // ------------------------------------------------------------------ data helpers (same lists as Home.qml)

    readonly property var specials: [
        { name: "special", glyph: 0xF04CE },          // SUPER+S  scratch
        { name: "music", glyph: 0xF075A },            // SUPER+M  music
        { name: "sysmon", glyph: 0xF04C5 },           // CTRL+SHIFT+ESC  performance
        { name: "communication", glyph: 0xF0361 },    // SUPER+D  discord
        { name: "todo", glyph: 0xF05E0 }              // SUPER+R  todoist
    ]
    // workspaces 1..N are always drawn (N = Settings > Bar style > workspaces always shown, or the highest one in use)
    readonly property int wsCount: {
        var l = Hyprland.workspaces.values, m = wsMin
        for (var i = 0; i < l.length; i++) if (l[i].id > m) m = l[i].id
        return Math.min(10, m)
    }
    function findWs(id) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].id === id) return l[i]
        return null
    }
    function wsWindows(w) {
        try { return w.toplevels.values.length } catch (e) { return 0 }
    }
    function hasSpecial(n) {
        var l = Hyprland.workspaces.values
        for (var i = 0; i < l.length; i++) if (l[i].name === "special:" + n) return true
        return false
    }
}
