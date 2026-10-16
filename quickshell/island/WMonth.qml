import QtQuick

// "Month calendar": the month with today lit, or just this week as a strip.   grid | week
WBase {
    id: root

    property date now: new Date()
    Timer { running: root.live; repeat: true; interval: 60000; onTriggered: root.now = new Date() }

    readonly property bool monday: opt("mon", "mon") === "mon"
    readonly property bool wk: opt("weeks", false) === true
    readonly property var names: monday ? ["M", "T", "W", "T", "F", "S", "S"] : ["S", "M", "T", "W", "T", "F", "S"]

    function isoWeek(d) {
        var t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
        var dn = t.getUTCDay() || 7
        t.setUTCDate(t.getUTCDate() + 4 - dn)
        var y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1))
        return Math.ceil((((t - y0) / 86400000) + 1) / 7)
    }
    // the cells: 42 for the grid (6 weeks), 7 for the strip. { d: day number, cur: this month, today, wk: week number of the row }
    readonly property var cells: {
        var n = now, out = []
        var first = new Date(n.getFullYear(), n.getMonth(), 1)
        var off = (first.getDay() - (monday ? 1 : 0) + 7) % 7
        var start = new Date(first); start.setDate(1 - off)
        if (style === "week") {
            var back = (n.getDay() - (monday ? 1 : 0) + 7) % 7
            start = new Date(n.getFullYear(), n.getMonth(), n.getDate() - back)
        }
        var count = style === "week" ? 7 : 42
        for (var i = 0; i < count; i++) {
            var d = new Date(start); d.setDate(start.getDate() + i)
            out.push({ d: d.getDate(), cur: d.getMonth() === n.getMonth(), today: d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate(), wk: isoWeek(d) })
        }
        return out
    }
    readonly property real cw: sz(style === "week" ? 36 : 32)

    implicitWidth: (wk && style === "grid" ? cw : 0) + cw * 7
    implicitHeight: head.height + sz(8) + (style === "week" ? cw + sz(18) : cw * 6 + cw)

    Column {
        spacing: root.sz(8)
        Row {
            id: head
            spacing: root.sz(8)
            WLbl { b: root; text: Qt.formatDate(root.now, "MMMM"); font.pixelSize: root.sz(16); font.weight: Font.DemiBold }
            WLbl { b: root; text: Qt.formatDate(root.now, "yyyy"); color: root.dim; font.pixelSize: root.sz(16) }
        }
        Row {
            visible: root.style === "grid"
            Item { visible: root.wk; width: root.wk ? root.cw : 0; height: 1 }
            Repeater { model: root.names; delegate: WLbl { required property string modelData; b: root; width: root.cw; horizontalAlignment: Text.AlignHCenter; text: modelData; color: root.dim; font.pixelSize: root.sz(11); font.weight: Font.Medium } }
        }
        Grid {
            columns: root.wk && root.style === "grid" ? 8 : 7
            Repeater {
                model: root.style === "grid" && root.wk ? 48 : root.cells.length
                delegate: Item {
                    required property int index
                    // with week numbers every 8th cell is the week number of its row
                    readonly property bool isWk: root.wk && root.style === "grid" && index % 8 === 0
                    readonly property var c: isWk ? undefined : root.cells[(root.wk && root.style === "grid") ? Math.floor(index / 8) * 7 + (index % 8) - 1 : index]
                    readonly property var rowc: root.cells[Math.floor(index / 8) * 7]
                    width: root.cw; height: root.cw
                    Rectangle {
                        visible: !parent.isWk && parent.c !== undefined && parent.c.today
                        anchors.centerIn: parent
                        width: root.cw - root.sz(4); height: width; radius: width / 2
                        color: root.accent
                    }
                    WLbl {
                        b: root
                        anchors.centerIn: parent
                        text: parent.isWk ? (parent.rowc ? parent.rowc.wk : "") : (parent.c ? parent.c.d : "")
                        color: parent.isWk ? Qt.alpha(root.dim, 0.7) : ((parent.c && parent.c.today) ? (root.pal ? root.pal.bg : "black") : ((parent.c && parent.c.cur) ? root.fg : Qt.alpha(root.dim, 0.5)))
                        font.pixelSize: root.sz(parent.isWk ? 10 : 13)
                        font.weight: (parent.c && parent.c.today) ? Font.Bold : Font.Normal
                    }
                }
            }
        }
    }
}
