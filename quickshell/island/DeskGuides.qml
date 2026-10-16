import QtQuick
import "WidgetData.js" as WD

// What the desktop editor draws over the screen to line things up, like a design tool:
//   grid        thin lines every `gridSize` px, starting at the margins (every 5th line a little stronger)
//   centre      the screen's middle lines; they light up when the picked widget is centred
//   thirds      the rule-of-thirds lines
//   safe area   the margin box widgets are kept inside
//   measure     for the picked widget: the gap (px) to the screen edge or the next widget on each side, its size and its place,
//               and a cross through its own middle when that is level with the screen's middle
// Nothing here takes the mouse. `target` is the picked WidgetHost (its x / y / vw / vh are live while it is dragged).
Item {
    id: g
    property var pal
    property bool showGrid: true
    property int gridSize: 40
    property bool showCenter: true
    property bool showThirds: false
    property bool showSafe: true
    property bool showMeasure: true
    property bool measureOnly: false      // the layer above the widgets draws only the measuring; the one below draws the grid, centre, thirds, safe area
    property real margin: 24
    property real topInset: 24
    property real bottomInset: 24
    property var target: null            // WidgetHost or null
    property var collect: null           // function(uid) -> [{ x, y, w, h }]
    enabled: false

    readonly property color cLine: Qt.alpha(pal ? pal.text : "white", 0.10)
    readonly property color cLineStrong: Qt.alpha(pal ? pal.text : "white", 0.20)
    readonly property color cEdge: pal ? pal.accent : "#9aa9d4"
    readonly property color cGap: pal ? pal.accent2 : "#c2add8"
    readonly property color cMid: "#ff5c8a"

    readonly property var rect: target ? ({ x: target.x, y: target.y, w: target.vw, h: target.vh }) : null
    readonly property var others: { var r = rect; return (target && collect) ? collect(target.uid) : [] }
    readonly property var meas: rect ? WD.measure(rect, others, { w: width, h: height }) : null
    readonly property bool midX: rect ? Math.abs(rect.x + rect.w / 2 - width / 2) < 1.5 : false
    readonly property bool midY: rect ? Math.abs(rect.y + rect.h / 2 - height / 2) < 1.5 : false

    // ---- grid
    Repeater {
        model: (g.showGrid && !g.measureOnly) ? WD.gridLines(g.margin, g.width - g.margin, g.gridSize) : []
        delegate: Rectangle {
            required property int index
            required property int modelData
            x: modelData; y: g.topInset; width: 1; height: Math.max(0, g.height - g.topInset - g.bottomInset)
            color: index % 5 === 0 ? g.cLineStrong : g.cLine
        }
    }
    Repeater {
        model: (g.showGrid && !g.measureOnly) ? WD.gridLines(g.topInset, g.height - g.bottomInset, g.gridSize) : []
        delegate: Rectangle {
            required property int index
            required property int modelData
            y: modelData; x: g.margin; height: 1; width: Math.max(0, g.width - 2 * g.margin)
            color: index % 5 === 0 ? g.cLineStrong : g.cLine
        }
    }

    // ---- safe area
    Rectangle {
        visible: g.showSafe && !g.measureOnly
        x: g.margin; y: g.topInset
        width: Math.max(0, g.width - 2 * g.margin); height: Math.max(0, g.height - g.topInset - g.bottomInset)
        color: "transparent"; border.width: 1; border.color: Qt.alpha(g.cEdge, 0.28)
    }

    // ---- thirds
    Repeater {
        model: (g.showThirds && !g.measureOnly) ? [1, 2] : []
        delegate: Item {
            required property int modelData
            Rectangle { x: g.width * parent.modelData / 3; y: 0; width: 1; height: g.height; color: Qt.alpha(g.cGap, 0.35) }
            Rectangle { y: g.height * parent.modelData / 3; x: 0; height: 1; width: g.width; color: Qt.alpha(g.cGap, 0.35) }
        }
    }

    // ---- centre
    Rectangle { visible: g.showCenter && !g.measureOnly; x: g.width / 2 - 0.5; y: 0; width: 1; height: g.height; color: g.midX ? g.cMid : Qt.alpha(g.cMid, 0.30); opacity: g.midX ? 1 : 0.8 }
    Rectangle { visible: g.showCenter && !g.measureOnly; y: g.height / 2 - 0.5; x: 0; height: 1; width: g.width; color: g.midY ? g.cMid : Qt.alpha(g.cMid, 0.30); opacity: g.midY ? 1 : 0.8 }
    Rectangle {
        visible: g.showCenter && !g.measureOnly
        x: g.width / 2 - 5; y: g.height / 2 - 5; width: 10; height: 10; radius: 5
        color: "transparent"; border.width: 1; border.color: Qt.alpha(g.cMid, 0.8)
    }

    // ---- the picked widget's own middle, when it is level with the screen's middle
    Rectangle { visible: g.showMeasure && g.rect !== null && g.midX; x: g.width / 2 - 0.5; y: g.rect ? g.rect.y : 0; width: 1; height: g.rect ? g.rect.h : 0; color: g.cMid }
    Rectangle { visible: g.showMeasure && g.rect !== null && g.midY; y: g.height / 2 - 0.5; x: g.rect ? g.rect.x : 0; height: 1; width: g.rect ? g.rect.w : 0; color: g.cMid }

    // ---- gaps to the screen edge / next widget on each side (a widget that touches nothing says how far the screen edge is)
    Item {
        visible: g.showMeasure && g.meas !== null
        anchors.fill: parent
        DgGap { pal: g.pal; horiz: true;  a: g.meas ? g.meas.left.from : 0;  b: g.rect ? g.rect.x : 0;              at: g.meas ? g.meas.left.at : 0;  d: g.meas ? g.meas.left.d : 0;  tone: g.meas && g.meas.left.kind === "widget" ? g.cGap : g.cEdge }
        DgGap { pal: g.pal; horiz: true;  a: g.rect ? g.rect.x + g.rect.w : 0; b: g.meas ? g.meas.right.from + g.meas.right.d : 0; at: g.meas ? g.meas.right.at : 0; d: g.meas ? g.meas.right.d : 0; tone: g.meas && g.meas.right.kind === "widget" ? g.cGap : g.cEdge }
        DgGap { pal: g.pal; horiz: false; a: g.meas ? g.meas.top.from : 0;   b: g.rect ? g.rect.y : 0;              at: g.meas ? g.meas.top.at : 0;   d: g.meas ? g.meas.top.d : 0;   tone: g.meas && g.meas.top.kind === "widget" ? g.cGap : g.cEdge }
        DgGap { pal: g.pal; horiz: false; a: g.rect ? g.rect.y + g.rect.h : 0; b: g.meas ? g.meas.bottom.from + g.meas.bottom.d : 0; at: g.meas ? g.meas.bottom.at : 0; d: g.meas ? g.meas.bottom.d : 0; tone: g.meas && g.meas.bottom.kind === "widget" ? g.cGap : g.cEdge }

        // size and place, under the widget (above it when it sits at the bottom)
        DgTag {
            pal: g.pal
            visible: g.rect !== null
            x: g.rect ? Math.max(2, Math.min(g.width - width - 2, g.rect.x + g.rect.w / 2 - width / 2)) : 0
            y: g.rect ? (g.rect.y + g.rect.h + 30 + height < g.height ? g.rect.y + g.rect.h + 28 : g.rect.y - height - 30) : 0
            text: g.rect ? Math.round(g.rect.w) + " × " + Math.round(g.rect.h) + "   at " + Math.round(g.rect.x) + ", " + Math.round(g.rect.y) : ""
            tone: "#f2f3f7"
        }
    }
}
