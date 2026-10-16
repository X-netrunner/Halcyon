import QtQuick
import QtQuick.Shapes

// "System usage": several meters in one widget. You pick which ones (CPU, memory, temperature, disk, GPU, network) and the layout:
//   bars | rings | list | compact
WBase {
    id: root

    function rate(b) {
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB/s"
        if (b >= 1024) return Math.round(b / 1024) + " KB/s"
        return Math.round(b) + " B/s"
    }
    readonly property var st: env ? env.stats : ({})
    readonly property var rows: {
        var sel = opt("show", ["cpu", "ram", "temp", "net"]), s = st || ({}), out = []
        for (var i = 0; i < sel.length; i++) {
            var id = sel[i]
            if (id === "cpu") out.push({ id: id, n: "CPU", v: (s.cpu || 0) / 100, t: Math.round(s.cpu || 0) + "%", hi: 0.85 })
            else if (id === "ram") out.push({ id: id, n: "RAM", v: (s.mem || 0) / 100, t: (s.memGb || "0.0") + "G", hi: 0.9 })
            else if (id === "temp") out.push({ id: id, n: "TEMP", v: Math.min(1, (s.temp || 0) / 100), t: Math.round(s.temp || 0) + "°", hi: 0.75 })
            else if (id === "gpu") {
                var g = env && env.gpu ? env.gpu : ({})
                out.push({ id: id, n: "GPU", v: (g.gpu || 0) / 100, t: (g.state === "none" || g.state === undefined) ? "n/a" : Math.round(g.gpu || 0) + "%", hi: 0.9 })
            } else if (id === "disk") {
                var ds = env && env.disks && env.disks.disks ? env.disks.disks : []
                var d0 = ds.length ? ds[0] : null
                var dv = d0 ? d0.used / Math.max(1, d0.size) : 0
                out.push({ id: id, n: "DISK", v: dv, t: d0 ? Math.round(dv * 100) + "%" : "n/a", hi: 0.9 })
            } else if (id === "net") out.push({ id: id, n: "NET", v: -1, t: "↓ " + rate(s.down || 0) + "   ↑ " + rate(s.up || 0), hi: 2 })
        }
        return out
    }
    readonly property real wide: opt("width", 260)
    function lit(r) { return r.v < 0 ? accent : level(r.v, r.hi, r.hi + 0.08) }

    implicitWidth: body.item ? body.item.implicitWidth : 200
    implicitHeight: body.item ? body.item.implicitHeight : 80
    Loader {
        id: body
        sourceComponent: root.style === "rings" ? ringsC : (root.style === "list" ? listC : (root.style === "compact" ? compactC : barsC))
    }

    Component {
        id: barsC
        Column {
            spacing: root.sz(10)
            Repeater {
                model: root.rows
                delegate: Row {
                    required property var modelData
                    spacing: root.sz(10)
                    WLbl { b: root; width: root.sz(40); text: modelData.n; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 1; anchors.verticalCenter: parent.verticalCenter }
                    Rectangle {
                        visible: modelData.v >= 0
                        width: root.wide - root.sz(40) - root.sz(56) - root.sz(20); height: root.sz(7); radius: height / 2; color: root.track
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle { width: Math.max(parent.height, parent.width * Math.max(0, modelData.v)); height: parent.height; radius: height / 2; color: root.lit(modelData)
                            Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } } }
                    }
                    WLbl { b: root; width: modelData.v >= 0 ? root.sz(56) : root.wide - root.sz(50); horizontalAlignment: modelData.v >= 0 ? Text.AlignRight : Text.AlignLeft
                           text: modelData.t; font.pixelSize: root.sz(13); font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
    }
    Component {
        id: ringsC
        Column {
            spacing: root.sz(10)
            Row {
                spacing: root.sz(14)
                Repeater {
                    model: root.rows.filter(function (r) { return r.v >= 0 })
                    delegate: Item {
                        required property var modelData
                        width: root.sz(60); height: root.sz(76)
                        Item {
                            id: rr
                            width: root.sz(60); height: width
                            Shape {
                                anchors.fill: parent
                                layer.enabled: true
                                layer.samples: 4
                                ShapePath { strokeColor: root.track; strokeWidth: root.sz(5); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                    PathAngleArc { centerX: rr.width / 2; centerY: rr.height / 2; radiusX: rr.width / 2 - root.sz(4); radiusY: rr.height / 2 - root.sz(4); startAngle: -90; sweepAngle: 359.9 } }
                                ShapePath { strokeColor: root.lit(modelData); strokeWidth: root.sz(5); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                    PathAngleArc { centerX: rr.width / 2; centerY: rr.height / 2; radiusX: rr.width / 2 - root.sz(4); radiusY: rr.height / 2 - root.sz(4); startAngle: -90; sweepAngle: 359.9 * Math.max(0.01, modelData.v) } }
                            }
                            WLbl { b: root; anchors.centerIn: parent; text: modelData.t; font.pixelSize: root.sz(13); font.weight: Font.DemiBold }
                        }
                        WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; y: rr.height + root.sz(3); text: modelData.n; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 1 }
                    }
                }
            }
            Repeater {
                model: root.rows.filter(function (r) { return r.v < 0 })
                delegate: WLbl { required property var modelData; b: root; text: modelData.t; color: root.dim; font.pixelSize: root.sz(12) }
            }
        }
    }
    Component {
        id: listC
        Column {
            spacing: root.sz(5)
            Repeater {
                model: root.rows
                delegate: Row {
                    required property var modelData
                    spacing: root.sz(12)
                    WLbl { b: root; width: root.sz(46); text: modelData.n; color: root.dim; font.pixelSize: root.sz(12); font.letterSpacing: 1 }
                    WLbl { b: root; text: modelData.t; color: root.lit(modelData); font.pixelSize: root.sz(15); font.weight: Font.Medium; font.family: root.pal ? root.pal.mono : "monospace" }
                }
            }
        }
    }
    Component {
        id: compactC
        Row {
            spacing: root.sz(14)
            Repeater {
                model: root.rows
                delegate: Row {
                    required property var modelData
                    spacing: root.sz(5)
                    WLbl { b: root; text: modelData.n; color: root.dim; font.pixelSize: root.sz(11); font.letterSpacing: 1; anchors.baseline: cv.baseline }
                    WLbl { id: cv; b: root; text: modelData.t; color: root.lit(modelData); font.pixelSize: root.sz(15); font.weight: Font.DemiBold }
                }
            }
        }
    }
}
