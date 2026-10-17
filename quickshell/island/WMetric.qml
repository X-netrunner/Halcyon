import QtQuick
import QtQuick.Shapes

// One number from the machine, drawn six ways (the widget's style): ring | arc | bar | pill | number | history.
// cpu, ram, temp, gpu, disk, battery, volume, brightness all come through here; the type decides what is read.
// Volume and brightness answer the mouse wheel.
WBase {
    id: root

    // ---- the reading: v 0..1, text (what is shown), name, icon
    readonly property var st: env ? env.stats : ({})
    readonly property var m: {
        var s = st || ({}), v = 0, t = "", n = "", ic = 0xF061A, hi = 0.85, bad = 0.95, inv = false
        switch (kind) {
        case "cpu": v = (s.cpu || 0) / 100; t = Math.round(s.cpu || 0) + "%"; n = "CPU"; ic = 0xF061A; break
        case "ram":
            v = (s.mem || 0) / 100; n = "MEMORY"; ic = 0xF035B
            t = opt("gb", false) === true ? (s.memGb || "0.0") + "G" : Math.round(s.mem || 0) + "%"
            break
        case "temp": v = Math.min(1, (s.temp || 0) / 100); t = Math.round(s.temp || 0) + "°"; n = "TEMP"; ic = 0xF050F; hi = 0.75; bad = 0.88; break
        case "gpu": {
            var g = env && env.gpu ? env.gpu : ({})
            v = (g.gpu || 0) / 100; t = (g.state === "none" || g.state === undefined) ? "n/a" : Math.round(g.gpu || 0) + "%"; n = "GPU"; ic = 0xF0379
            break
        }
        case "disk": {
            var ds = env && env.disks && env.disks.disks ? env.disks.disks : []
            var d0 = ds.length ? ds[0] : null
            v = d0 ? d0.used / Math.max(1, d0.size) : 0
            t = d0 ? Math.round(v * 100) + "%" : "n/a"; n = d0 ? String(d0.mount).toUpperCase() : "DISK"; ic = 0xF02CA; hi = 0.85; bad = 0.95
            break
        }
        case "battery":
            v = (s.bat || 0) / 100; t = (s.hasBat ? Math.round(s.bat || 0) + "%" : "AC"); n = s.charging ? "CHARGING" : "BATTERY"; ic = 0xF0079
            inv = true
            break
        case "volume": v = env ? Math.max(0, Math.min(1, (env.vol || 0) / 100)) : 0; t = env && env.muted ? "mute" : Math.round(v * 100) + "%"; n = "VOLUME"; ic = (env && env.muted) ? 0xF0581 : 0xF057E; hi = 2; bad = 2; break
        case "brightness": v = env ? Math.max(0, Math.min(1, (env.bright || 0) / 100)) : 0; t = Math.round(v * 100) + "%"; n = "BRIGHTNESS"; ic = 0xF00DF; hi = 2; bad = 2; break
        }
        return { v: Math.max(0, Math.min(1, v)), t: t, n: n, ic: ic, hi: hi, bad: bad, inv: inv }
    }
    readonly property bool noBattery: kind === "battery" && st && st.hasBat === false
    hidden: noBattery && opt("hideNoBat", true) === true
    readonly property bool showName: opt("label", true) === true
    // the colour of the lit part: the look's accent, amber / red when it is too much (too little for the battery)
    readonly property color lit: {
        if (!pal) return accent
        if (m.inv) return (!(st && st.charging) && m.v < 0.15) ? pal.bad : ((!(st && st.charging) && m.v < 0.3) ? pal.warn : accent)
        return level(m.v, m.hi, m.bad)
    }
    property real shownV: m.v
    Behavior on shownV { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

    // history: the last 30 readings (only the types that move)
    property var hist: []
    onMChanged: {
        if (style !== "history" || !live) return          // nothing is recorded while it is off screen or in another style
        var a = hist.slice(-29)
        a.push(m.v)
        hist = a
    }

    // the wheel changes volume / brightness
    readonly property bool wheelable: kind === "volume" || kind === "brightness"
    MouseArea {
        id: wheelArea
        anchors.fill: parent
        enabled: root.wheelable && !root.editing
        acceptedButtons: root.kind === "volume" ? Qt.LeftButton : Qt.NoButton
        onClicked: if (root.env) root.env.deskAct("mute")
        // a fast wheel sent every notch from the SAME old reading (the real value arrives later), so five notches moved it by one:
        // the next notch builds on the value just asked for until the reading catches up
        property real asked: -1
        Timer { id: askedT; interval: 700; onTriggered: wheelArea.asked = -1 }
        onWheel: w => {
            if (!root.env) return
            var d = (w.angleDelta.y > 0 ? 0.05 : -0.05)
            var base = asked >= 0 ? asked : root.m.v
            asked = Math.max(root.kind === "volume" ? 0 : 0.01, Math.min(1, base + d))
            askedT.restart()
            if (root.kind === "volume") root.env.deskSetVol(asked)
            else root.env.deskSetBright(asked)
        }
    }

    implicitWidth: body.item ? body.item.implicitWidth : 100
    implicitHeight: body.item ? body.item.implicitHeight : 100
    Loader {
        id: body
        sourceComponent: {
            switch (root.style) {
            case "arc": return arcC
            case "bar": return barC
            case "pill": return pillC
            case "number": return numC
            case "history": return histC
            case "hairline": return hairC
            case "petals": return petalC
            default: return ringC
            }
        }
    }
    // ---- hairline: the name and the number on one line, a thread under them with a small light at its end
    Component {
        id: hairC
        Column {
            spacing: root.sz(6)
            Item {
                width: root.sz(200); height: root.sz(26)
                WLbl { b: root; visible: root.showName; text: root.m.n; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3; anchors.left: parent.left; anchors.baseline: val.baseline }
                WLbl { id: val; b: root; text: root.m.t; font.pixelSize: root.sz(24); font.weight: Font.ExtraLight; anchors.right: parent.right; anchors.bottom: parent.bottom }
            }
            Item {
                width: root.sz(200); height: root.sz(10)
                Rectangle { y: parent.height / 2; width: parent.width; height: 1; color: root.track }
                Rectangle { y: parent.height / 2 - 0.25; width: Math.max(1, parent.width * root.shownV); height: 1.5; color: root.lit }
                WGlow { x: parent.width * root.shownV - width / 2; y: parent.height / 2 - height / 2; width: root.sz(36); height: width; color: root.lit; strength: 0.28 }
                Rectangle { x: parent.width * root.shownV - width / 2; y: parent.height / 2 - height / 2; width: root.sz(6); height: width; radius: width / 2; color: root.lit }
            }
        }
    }
    // ---- petals: a flower whose petals light up one by one as the number grows
    Component {
        id: petalC
        Item {
            implicitWidth: root.sz(110); implicitHeight: root.sz(110) + (root.showName ? root.sz(18) : 0)
            WPetals {
                id: pf
                b: root
                width: root.sz(100); height: width
                anchors.horizontalCenter: parent.horizontalCenter
                count: 12; open: 1; lit: root.shownV; color: root.lit
                WLbl { b: root; anchors.centerIn: parent; text: root.m.t; font.pixelSize: root.sz(17); font.weight: Font.Light }
            }
            WLbl { b: root; visible: root.showName; anchors.horizontalCenter: parent.horizontalCenter; y: pf.height + root.sz(4); text: root.m.n; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 2.4 }
        }
    }

    // ---- ring
    Component {
        id: ringC
        Item {
            implicitWidth: root.sz(104); implicitHeight: root.sz(104) + (root.showName ? root.sz(18) : 0)
            Item {
                id: rg
                width: root.sz(104); height: width
                Shape {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 4
                    layer.textureSize: Qt.size(Math.ceil(width * root.rs), Math.ceil(height * root.rs))
                    ShapePath { strokeColor: root.track; strokeWidth: root.sz(8); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: rg.width / 2; centerY: rg.height / 2; radiusX: rg.width / 2 - root.sz(6); radiusY: rg.height / 2 - root.sz(6); startAngle: -90; sweepAngle: 359.9 } }
                    ShapePath { strokeColor: root.lit; strokeWidth: root.sz(8); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: rg.width / 2; centerY: rg.height / 2; radiusX: rg.width / 2 - root.sz(6); radiusY: rg.height / 2 - root.sz(6); startAngle: -90; sweepAngle: 359.9 * Math.max(0.004, root.shownV) } }
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 0
                    WIco { b: root; color: root.lit; anchors.horizontalCenter: parent.horizontalCenter; text: root.glyph(root.m.ic); font.pixelSize: root.sz(15) }
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.m.t; font.pixelSize: root.sz(20); font.weight: Font.DemiBold }
                }
            }
            WLbl { b: root; visible: root.showName; anchors.horizontalCenter: parent.horizontalCenter; y: rg.height + root.sz(4); text: root.m.n; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 1.2 }
        }
    }
    // ---- arc (a 270 degree gauge)
    Component {
        id: arcC
        Item {
            implicitWidth: root.sz(120); implicitHeight: root.sz(104)
            Item {
                id: ag
                width: root.sz(120); height: root.sz(120)
                Shape {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 4
                    layer.textureSize: Qt.size(Math.ceil(width * root.rs), Math.ceil(height * root.rs))
                    ShapePath { strokeColor: root.track; strokeWidth: root.sz(9); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: ag.width / 2; centerY: ag.height / 2; radiusX: ag.width / 2 - root.sz(8); radiusY: ag.height / 2 - root.sz(8); startAngle: 135; sweepAngle: 270 } }
                    ShapePath { strokeColor: root.lit; strokeWidth: root.sz(9); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: ag.width / 2; centerY: ag.height / 2; radiusX: ag.width / 2 - root.sz(8); radiusY: ag.height / 2 - root.sz(8); startAngle: 135; sweepAngle: 270 * Math.max(0.006, root.shownV) } }
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 0
                    WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.m.t; font.pixelSize: root.sz(24); font.weight: Font.DemiBold }
                    WLbl { b: root; visible: root.showName; anchors.horizontalCenter: parent.horizontalCenter; text: root.m.n; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 1.2 }
                }
            }
        }
    }
    // ---- bar
    Component {
        id: barC
        Column {
            spacing: root.sz(8)
            Row {
                width: root.sz(200)
                spacing: root.sz(8)
                WIco { b: root; color: root.lit; text: root.glyph(root.m.ic); font.pixelSize: root.sz(16); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; visible: root.showName; text: root.m.n; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 1.2; anchors.verticalCenter: parent.verticalCenter }
            }
            WLbl { b: root; text: root.m.t; font.pixelSize: root.sz(30); font.weight: Font.DemiBold }
            Rectangle {
                width: root.sz(200); height: root.sz(8); radius: height / 2; color: root.track
                Rectangle { width: Math.max(parent.height, parent.width * root.shownV); height: parent.height; radius: height / 2; color: root.lit }
            }
        }
    }
    // ---- pill (one slim line)
    Component {
        id: pillC
        Row {
            spacing: root.sz(10)
            WIco { b: root; color: root.lit; text: root.glyph(root.m.ic); font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; visible: root.showName; text: root.m.n; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 1.1; anchors.verticalCenter: parent.verticalCenter }
            Rectangle {
                width: root.sz(70); height: root.sz(5); radius: height / 2; color: root.track; anchors.verticalCenter: parent.verticalCenter
                Rectangle { width: Math.max(parent.height, parent.width * root.shownV); height: parent.height; radius: height / 2; color: root.lit }
            }
            WLbl { b: root; text: root.m.t; font.pixelSize: root.sz(15); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
        }
    }
    // ---- number
    Component {
        id: numC
        Column {
            spacing: 0
            Row {
                spacing: root.sz(8)
                WIco { b: root; color: root.lit; text: root.glyph(root.m.ic); font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; visible: root.showName; text: root.m.n; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 1.4; anchors.verticalCenter: parent.verticalCenter }
            }
            WLbl { b: root; text: root.m.t; font.pixelSize: root.sz(54); font.weight: Font.Light; color: root.lit }
        }
    }
    // ---- history (the last 30 readings as little bars)
    Component {
        id: histC
        Column {
            spacing: root.sz(6)
            Row {
                spacing: root.sz(8)
                WIco { b: root; color: root.lit; text: root.glyph(root.m.ic); font.pixelSize: root.sz(16); anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; visible: root.showName; text: root.m.n; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 1.2; anchors.verticalCenter: parent.verticalCenter }
                WLbl { b: root; text: root.m.t; font.pixelSize: root.sz(16); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            }
            Row {
                id: hrow
                spacing: root.sz(2)
                height: root.sz(46)
                Repeater {
                    model: 30
                    delegate: Item {
                        required property int index
                        readonly property real val: {
                            var a = root.hist, j = a.length - 30 + index
                            return j >= 0 && j < a.length ? a[j] : 0
                        }
                        width: root.sz(5); height: hrow.height
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Math.max(2, parent.height * val); radius: 1.5; color: val > 0 ? root.lit : root.track; opacity: val > 0 ? 0.4 + 0.6 * (index / 29) : 0.5 }
                    }
                }
            }
        }
    }
}
