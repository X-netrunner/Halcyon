import QtQuick

// "Battery time": how long the battery lasts at the current use (or how long until it is full), with the charge and the power
// draw. Everything comes from the stats feed the bar already reads (hx stats: bat, batEst, batW, charging, ac, hasBat), so this
// widget starts no process and reads no file of its own. The estimate is hx's: the drain rate smoothed over the last readings,
// so it settles a few seconds after a change instead of jumping with every spike.
WBase {
    id: root

    readonly property var st: env ? env.stats : ({})
    readonly property bool hasBat: !!st && st.hasBat === true
    readonly property bool charging: !!st && st.charging === true
    readonly property bool plugged: !!st && st.ac === true
    readonly property int pct: st && st.bat !== undefined ? Math.round(Number(st.bat)) : 0
    readonly property real watts: st && st.batW !== undefined ? Number(st.batW) : 0
    readonly property string est: st && st.batEst ? String(st.batEst) : ""
    // the time on its own ("2h 09m"), whatever hx appended ("to full")
    readonly property string timeText: est.replace(/\s*to full\s*$/, "")
    readonly property bool full: plugged && !charging && pct >= 95

    // the big line and the small line under it
    readonly property string headline: {
        if (!hasBat) return "No battery"
        if (timeText !== "") return timeText
        if (full) return "Full"
        if (plugged && !charging) return "Plugged in"
        return "…"
    }
    readonly property string caption: {
        if (!hasBat) return "on mains power"
        if (charging) return timeText !== "" ? "until full" : "charging"
        if (timeText !== "") return "left"
        if (full || (plugged && !charging)) return "not charging"
        return "working it out"
    }
    readonly property bool showW: opt("watts", true) === true && watts > 0.05
    readonly property bool showPct: opt("pct", true) === true
    readonly property string extra: (showPct && hasBat ? pct + "%" : "") + (showPct && hasBat && showW ? "  ·  " : "") + (showW ? watts.toFixed(1) + " W" + (charging ? " in" : "") : "")

    // the charge colour: amber / red when low and not charging (the same rule as the Battery widget)
    readonly property color lit: !pal ? accent : (!charging && hasBat && pct < 15 ? pal.bad : (!charging && hasBat && pct < 30 ? pal.warn : accent))
    readonly property int icon: !hasBat ? 0xF06A5 : (charging ? 0xF0084 : (pct >= 90 ? 0xF0079 : (pct >= 60 ? 0xF0080 : (pct >= 30 ? 0xF007D : 0xF007A))))

    hidden: !hasBat && opt("hideNoBat", true) === true
    implicitWidth: body.item ? body.item.implicitWidth : 160
    implicitHeight: body.item ? body.item.implicitHeight : 50
    Loader {
        id: body
        sourceComponent: root.style === "line" ? lineC : (root.style === "ring" ? ringC : (root.style === "bar" ? barC : (root.style === "minimal" ? minC : cardC)))
    }

    // card: a small heading, the time big, the charge and watts under it
    Component {
        id: cardC
        Column {
            spacing: root.sz(1)
            WLbl { b: root; text: root.charging ? "CHARGING" : "BATTERY"; color: root.lit; font.pixelSize: root.sz(11); font.letterSpacing: 2; font.weight: Font.DemiBold }
            Row {
                spacing: root.sz(8)
                WLbl { b: root; text: root.headline; font.pixelSize: root.sz(34); font.weight: Font.Light }
                WLbl { b: root; text: root.caption; color: root.dim; font.pixelSize: root.sz(13); anchors.baseline: parent.children[0].baseline }
            }
            WLbl { b: root; visible: text !== ""; text: root.extra; color: root.dim; font.pixelSize: root.sz(12) }
        }
    }
    // one line: icon, "2h 09m left", the charge and watts
    Component {
        id: lineC
        Row {
            spacing: root.sz(8)
            WIco { b: root; text: root.glyph(root.icon); color: root.lit; font.pixelSize: root.sz(18); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.headline + (root.caption !== "" ? " " + root.caption : ""); font.pixelSize: root.sz(16); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; visible: text !== ""; text: root.extra; color: root.dim; font.pixelSize: root.sz(13); anchors.verticalCenter: parent.verticalCenter }
        }
    }
    // ring: the charge as a ring, the time beside it
    Component {
        id: ringC
        Row {
            spacing: root.sz(12)
            Item {
                width: root.sz(64); height: width
                anchors.verticalCenter: parent.verticalCenter
                Canvas {
                    anchors.fill: parent
                    canvasSize: Qt.size(width * root.rs, height * root.rs)
                    property real frac: root.clamp01(root.pct / 100)
                    property color c1: root.lit
                    property color c2: root.track
                    onFracChanged: requestPaint()
                    onC1Changed: requestPaint()
                    onC2Changed: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d"), s = root.rs, r = width * s / 2, lw = root.sz(6) * s
                        ctx.reset()
                        ctx.lineWidth = lw; ctx.lineCap = "round"
                        ctx.strokeStyle = c2; ctx.beginPath(); ctx.arc(r, r, r - lw, 0, 6.2832); ctx.stroke()
                        if (frac > 0) { ctx.strokeStyle = c1; ctx.beginPath(); ctx.arc(r, r, r - lw, -1.5708, -1.5708 + 6.2832 * frac); ctx.stroke() }
                    }
                }
                WLbl { b: root; anchors.centerIn: parent; text: root.hasBat ? root.pct + "%" : "AC"; font.pixelSize: root.sz(14); font.weight: Font.DemiBold }
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                WLbl { b: root; text: root.headline; font.pixelSize: root.sz(24); font.weight: Font.Light }
                WLbl { b: root; text: root.caption + (root.showW ? "  ·  " + root.watts.toFixed(1) + " W" : ""); color: root.dim; font.pixelSize: root.sz(12) }
            }
        }
    }
    // bar: the time and the charge over a bar that empties
    Component {
        id: barC
        Column {
            spacing: root.sz(5)
            width: Math.max(root.sz(200), top.implicitWidth)
            Row {
                id: top
                spacing: root.sz(8)
                WLbl { b: root; text: root.headline; font.pixelSize: root.sz(20); font.weight: Font.Medium }
                WLbl { b: root; text: root.caption; color: root.dim; font.pixelSize: root.sz(12); anchors.baseline: parent.children[0].baseline }
            }
            Rectangle {
                width: parent.width; height: root.sz(6); radius: height / 2; color: root.track
                Rectangle { width: Math.max(parent.height, parent.width * root.clamp01(root.pct / 100)); height: parent.height; radius: height / 2; color: root.lit }
            }
            WLbl { b: root; visible: text !== ""; text: root.extra; color: root.dim; font.pixelSize: root.sz(11) }
        }
    }
    // minimal: just the time
    Component {
        id: minC
        WLbl { b: root; text: root.headline; font.pixelSize: root.sz(22); font.weight: Font.Medium }
    }
}
