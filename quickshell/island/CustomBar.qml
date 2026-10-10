import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "BarLayout.js" as BL

// Bar style "Custom" (Settings > Bar style > Style, then Settings > Bar style > Bar builder).
// The same hanging bar as the Notch (flared top corners, rounded bottom corners), but what is on it and where is up to you:
// opt.barLayout = { left: [...], center: [...], right: [...] } (BarLayout.js has the list of widgets, BarBuilder.qml edits it).
//   left / right: grow from the edges      middle: always centred on the screen (both sides get the same width so it stays centred)
// Same inputs and signals as NotchBar.qml, so shell.qml feeds it the same way.
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
    property string focusText: ""        // Focus mode running: the time left ("" = no session)
    property bool focusPaused: false
    property int bgCount: 0
    property var opt: ({})
    property string barPadding: "normal"      // low | normal | high (Settings > Bar > Bar size and padding)
    property bool autoHide: false
    property bool clickMode: false            // Settings > Edge boxes = Click: an auto-hidden bar comes back on a click on the top edge, not on a hover
    property bool clock24: false
    property bool showStats: false            // Settings > Bar > "When you hover the bar" = Live stats
    property bool pageOpen: false             // the performance / media page or the launcher is open (bar is not clickable behind it)
    property int gaps: 8                      // Hyprland's gaps (see exclusiveZone)

    signal workspaceClicked(int wsId)
    signal workspaceScrolled(int dir)         // +1 wheel up, -1 wheel down
    signal specialClicked(string name)
    signal statusClicked()
    signal pageDrop(int dir)                  // drag the bar down (+1) / up (-1): the utilities box and notifications (Settings > Bar style)
    signal clockToggled(string what)          // right click on the time = 12 / 24 hour, middle click = seconds (shell.qml flips the setting)
    signal bgClicked()
    signal pageStep(int dir)                  // wheel / drag on the bar: -1 = media, +1 = performance (shell.qml go())
    signal hoverEdited(bool on)               // the pointer is on the bar / left it (shell.qml opens perf / media after a moment)

    // ---- layout: what is on the bar, and where
    readonly property var lay: BL.normalize(opt.barLayout)
    readonly property color ac: {
        var m = opt.notchAccent || "theme"
        if (m === "theme") return pal.accent
        if (m === "accent2") return pal.accent2
        var c = pal.accent
        return Qt.hsla(pal.hueOf(c, 0.5), Math.min(1, Math.max(0.6, c.hslSaturation * 1.7)), pal.light ? 0.40 : 0.58, 1)
    }
    readonly property int wsMin: Math.max(1, Math.min(10, Number(opt.notchWsMin || 5)))
    readonly property bool showSeconds: opt.clockSeconds === true
    readonly property string btMode: opt.notchBtMode || "connected"
    readonly property bool btShown: net.bt === "on" && (btMode === "on" || (btMode === "connected" && (net.btdev || "") !== ""))
    readonly property string wifiLook: opt.notchWifiStyle || "bars"
    readonly property bool spacious: opt.notchSpacing === "spacious"
    readonly property int midGap: Math.round(barH * (spacious ? 0.7 : 0.3))
    readonly property int groupGap: Math.round(barH * (spacious ? 1.1 : 0.3))
    readonly property int itemGap: Math.max(4, Math.round(barH * (spacious ? 0.28 : 0.17)))
    readonly property int rightGap: Math.round(barH * (spacious ? 0.5 : 0.3))
    readonly property bool showBatPct: opt.notchBatPct === true
    readonly property bool dropOn: opt.dropDown === "stack" || opt.dropDown === "side"

    // ---- size (Bar size and padding): the same numbers as the Notch
    readonly property var sizeSet: ({ low: { h: 26, gap: 3 }, normal: { h: 32, gap: 8 }, high: { h: 40, gap: 12 } })[barPadding] || ({ h: 32, gap: 8 })
    readonly property int barH: sizeSet.h
    readonly property real earR: Math.round(barH * 0.42)
    readonly property real cornR: Math.round(barH * 0.42)
    readonly property int padX: Math.round(barH * (spacious ? 0.95 : 0.62))
    readonly property int textPx: Math.round(barH * 0.44)
    readonly property int curH: Math.round(textPx * 1.3)
    readonly property int curW: Math.round(curH * 0.55)
    readonly property int offH: Math.round(curH * 0.85)
    readonly property int offW: Math.round(curW * 0.8)
    readonly property int icoH: offH
    readonly property int comboSize: Math.round(barH * 0.78)

    readonly property real bodyWidth: notch.bw
    readonly property bool shown: !autoHide || peek || hov.hovered
    property bool peek: false
    Timer { id: peekT; interval: 700; onTriggered: win.peek = false }
    Timer { id: graceT; interval: 2500; onTriggered: if (!hov.hovered) win.peek = false }

    anchors { top: true; left: true; right: true }
    implicitHeight: barH + 34
    exclusiveZone: autoHide ? 0 : Math.max(0, barH + sizeSet.gap - gaps * 2)
    color: "transparent"

    WlrLayershell.namespace: "island-notch"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region { regions: [ Region { item: strip }, Region { item: win.pageOpen ? null : notch } ] }

    Item {
        id: strip
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: 420
        height: 5
        HoverHandler {
            enabled: !win.clickMode
            onHoveredChanged: { if (hovered) { peekT.stop(); win.peek = true } else peekT.restart() }
        }
        TapHandler {
            enabled: win.clickMode
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: { peekT.stop(); win.peek = true; graceT.restart() }
        }
    }

    // a click on any status widget: the drop-down, or the performance page
    function statusTap() { if (dropOn) pageDrop(1); else statusClicked() }

    // ------------------------------------------------------------------ the bar
    Item {
        id: notch

        readonly property real sideW: Math.max(leftRow.width, rightRow.width)
        readonly property real centerW: midRow.width
        readonly property real bodyW: sideW * 2 + centerW + (sideW > 0 ? (centerW > 0 ? win.groupGap * 2 : win.groupGap) : 0) + win.padX * 2
        width: bodyW + win.earR * 2
        height: win.barH
        anchors.horizontalCenter: parent.horizontalCenter
        y: win.shown ? 0 : -(win.barH + 30)
        Behavior on y { NumberAnimation { duration: win.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }
        opacity: win.pageOpen ? 0.0 : 1.0
        Behavior on opacity { NumberAnimation { duration: win.pal.dMed } }
        Behavior on width { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: win.pal.curve } }

        SystemClock { id: clock; precision: win.showSeconds ? SystemClock.Seconds : SystemClock.Minutes }
        readonly property string timeStr: Qt.formatDateTime(clock.date, (win.clock24 ? "HH:mm" : "hh:mm") + (win.showSeconds ? ":ss" : "") + (win.clock24 ? "" : " AP"))
        readonly property string dateStr: Qt.formatDateTime(clock.date, "ddd") + "  " + Qt.formatDateTime(clock.date, "d MMM")

        readonly property real r: win.earR
        readonly property real cr: win.cornR
        readonly property real bw: width - 2 * r
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
        property real dragY: 0
        DragHandler {
            id: dragH
            target: null
            xAxis.enabled: true
            yAxis.enabled: win.dropOn
            onTranslationChanged: if (active) { notch.dragX = translation.x; notch.dragY = translation.y }
            onActiveChanged: {
                if (active) return
                var dx = notch.dragX, dy = notch.dragY
                notch.dragX = 0; notch.dragY = 0
                if (win.dropOn && Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 40) win.pageDrop(dy > 0 ? 1 : -1)
                else if (dx < -50) win.pageStep(1)
                else if (dx > 50) win.pageStep(-1)
            }
        }

        // ------------------------------------------------------------ content
        // every widget is a component with an implicit width; the three rows below place them from the layout
        Component { id: cWorkspaces
            Row {
                id: wsRow
                height: notch.bh
                spacing: win.itemGap
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: function (e) { if (e.angleDelta.y !== 0) win.workspaceScrolled(e.angleDelta.y > 0 ? 1 : -1) }
                }
                Repeater {
                    model: win.wsCount
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
            }
        }

        Component { id: cSpecials
            Row {
                height: notch.bh
                spacing: win.itemGap
                Repeater {
                    model: win.specials
                    delegate: Item {
                        id: spItem
                        required property var modelData
                        readonly property bool lit: win.activeSpecial === modelData.name
                        readonly property bool show: lit || win.hasSpecial(modelData.name)
                        visible: show
                        width: show ? win.icoH + 4 : 0
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
        }

        Component { id: cMusic
            Item {
                height: notch.bh
                implicitWidth: win.opt.viz === "off" ? 0 : viz.implicitWidth
                Visualizer {
                    id: viz
                    y: Math.round((notch.bh - height) / 2)
                    pal: win.pal
                    values: win.cava
                    active: win.playing
                }
            }
        }

        Component { id: cClock
            Text {
                height: notch.bh
                verticalAlignment: Text.AlignVCenter
                text: notch.timeStr
                color: win.pal.text
                font.family: win.pal.uiFont
                font.pixelSize: win.textPx
                font.weight: Font.DemiBold
                TapHandler { acceptedButtons: Qt.LeftButton; onTapped: win.statusTap() }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: win.clockToggled("24h") }
                TapHandler { acceptedButtons: Qt.MiddleButton; onTapped: win.clockToggled("seconds") }
            }
        }

        Component { id: cDate
            Text {
                height: notch.bh
                verticalAlignment: Text.AlignVCenter
                text: notch.dateStr
                color: win.pal.muted
                font.family: win.pal.uiFont
                font.pixelSize: Math.max(10, win.textPx - 2)
            }
        }

        Component { id: cStats
            Row {
                height: notch.bh
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
                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                        Text { text: modelData.k; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: win.pal.tCap; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: modelData.v; color: modelData.frac > 0.9 ? win.pal.bad : (modelData.frac > 0.75 ? win.pal.warn : win.pal.text); font.family: win.pal.uiFont; font.pixelSize: win.pal.tBody; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cStatus
            Item {
                height: notch.bh
                implicitWidth: ring.any ? ring.width : 0
                StatusRing {
                    id: ring
                    anchors.verticalCenter: parent.verticalCenter
                    pal: win.pal
                    net: win.net
                    stats: win.stats
                    tint: win.ac
                    size: win.comboSize
                    showWifi: true
                    showBat: true
                    btMode: win.btMode
                    showPct: win.showBatPct
                    textColor: win.pal.text
                    textFont: win.pal.uiFont
                    textPx: Math.max(10, win.textPx - 2)
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cWifi
            Item {
                height: notch.bh
                implicitWidth: wf.width
                WifiIcon {
                    id: wf
                    anchors.centerIn: parent
                    pal: win.pal
                    net: win.net
                    look: win.wifiLook
                    tint: win.ac
                    offTint: Qt.alpha(win.ac, 0.3)
                    size: win.icoH
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cBluetooth
            Item {
                height: notch.bh
                implicitWidth: win.btShown ? btText.implicitWidth : 0
                clip: true
                Text {
                    id: btText
                    anchors.centerIn: parent
                    text: String.fromCodePoint(0xF00AF)
                    color: (win.net.btdev || "") !== "" ? win.ac : Qt.alpha(win.ac, 0.45)
                    font.family: win.pal.font
                    font.pixelSize: win.icoH
                }
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cBattery
            Item {
                id: bat
                height: notch.bh
                readonly property int bh: Math.round(win.icoH * 0.8)
                readonly property int bw: Math.round(win.icoH * 1.75)
                implicitWidth: win.stats.hasBat === true ? bw + (win.showBatPct ? pctText.implicitWidth + 5 : 0) : 0
                Rectangle {
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
                TapHandler { onTapped: win.statusTap() }
            }
        }

        Component { id: cCaffeine
            Item {
                height: notch.bh
                implicitWidth: win.caffeine ? cafText.implicitWidth : 0
                clip: true
                Text { id: cafText; anchors.centerIn: parent; text: String.fromCodePoint(0xF0176); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH }
            }
        }

        Component { id: cFocus
            Item {
                height: notch.bh
                implicitWidth: win.focusText !== "" ? focusRow.implicitWidth : 0
                clip: true
                opacity: win.focusPaused ? 0.55 : 1
                Row {
                    id: focusRow
                    anchors.centerIn: parent
                    spacing: 5
                    Text { text: String.fromCodePoint(0xF051B); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: win.focusText; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: Math.max(10, win.textPx - 2); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }

        Component { id: cBgApps
            Item {
                height: notch.bh
                implicitWidth: win.bgCount > 0 ? bgRow.width : 0
                clip: true
                Row {
                    id: bgRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Text { text: String.fromCodePoint(0xF003B); color: win.ac; font.family: win.pal.font; font.pixelSize: win.icoH; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: win.bgCount; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: Math.max(10, win.textPx - 2); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: win.bgClicked() }
            }
        }

        // widget id -> component
        function comp(id) {
            switch (id) {
            case "workspaces": return cWorkspaces
            case "specials": return cSpecials
            case "music": return cMusic
            case "clock": return cClock
            case "date": return cDate
            case "stats": return cStats
            case "status": return cStatus
            case "wifi": return cWifi
            case "bluetooth": return cBluetooth
            case "battery": return cBattery
            case "caffeine": return cCaffeine
            case "focus": return cFocus
            case "bgapps": return cBgApps
            }
            return null
        }

        Row {
            id: leftRow
            x: notch.r + win.padX
            y: 0
            height: notch.bh
            spacing: win.itemGap
            Repeater {
                model: win.lay.left
                delegate: Loader {
                    required property string modelData
                    height: notch.bh
                    sourceComponent: notch.comp(modelData)
                    // a widget with nothing to show (no battery, no music bars, no running Focus ...) takes no room and no gap
                    visible: status === Loader.Ready && item !== null && item.implicitWidth > 0
                }
            }
        }
        Row {
            id: midRow
            x: Math.round(notch.width / 2 - width / 2)
            y: 0
            height: notch.bh
            spacing: win.midGap
            Repeater {
                model: win.lay.center
                delegate: Loader {
                    required property string modelData
                    height: notch.bh
                    sourceComponent: notch.comp(modelData)
                    // a widget with nothing to show (no battery, no music bars, no running Focus ...) takes no room and no gap
                    visible: status === Loader.Ready && item !== null && item.implicitWidth > 0
                }
            }
        }
        Row {
            id: rightRow
            anchors.right: parent.right
            anchors.rightMargin: notch.r + win.padX
            y: 0
            height: notch.bh
            spacing: win.rightGap
            Repeater {
                model: win.lay.right
                delegate: Loader {
                    required property string modelData
                    height: notch.bh
                    sourceComponent: notch.comp(modelData)
                    // a widget with nothing to show (no battery, no music bars, no running Focus ...) takes no room and no gap
                    visible: status === Loader.Ready && item !== null && item.implicitWidth > 0
                }
            }
        }
    }

    // ------------------------------------------------------------------ data helpers (same lists as NotchBar.qml)
    readonly property var specials: [
        { name: "special", glyph: 0xF04CE },
        { name: "music", glyph: 0xF075A },
        { name: "sysmon", glyph: 0xF04C5 },
        { name: "communication", glyph: 0xF0361 },
        { name: "todo", glyph: 0xF05E0 }
    ]
    readonly property int specCount: {
        var n = 0
        for (var i = 0; i < specials.length; i++)
            if (activeSpecial === specials[i].name || hasSpecial(specials[i].name)) n++
        return n
    }
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
        for (var i = 0; i < l.length; i++) if (l[i].name === "special:" + n) return wsWindows(l[i]) > 0
        return false
    }
}
