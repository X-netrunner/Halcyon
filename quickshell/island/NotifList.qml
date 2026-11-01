import QtQuick
import QtQuick.Layouts
import Quickshell

// The list inside the notification centre (the right-edge panel and the bar's drop-down page).
// Settings > Panels & notifications > Notification style picks the look:
//   stack     one card per notification (NotifRow)
//   timeline  a rail with a dot per notification, under Just now / Earlier today / Yesterday / Older (NotifLine)
//   grouped   one card per app with its notifications inside (NotifGroup)
ListView {
    id: list
    property var pal
    property var notifs                     // the Notifs scope: history, arrived, avatar, usePfp
    property string look: "stack"
    property int rowGap: 10                 // space between notifications (Stack and Grouped looks)
    property real now: Date.now()
    signal dismissRequested(var n)

    readonly property var arrivedMap: notifs ? notifs.arrived : ({})
    // flat list of entries; each has a `key` so a refresh keeps the delegates that are still there
    readonly property var entries: { var t = now; return build(notifs ? notifs.history : [], look) }

    function build(h, mode) {
        var out = [], i
        if (mode === "grouped") {
            var order = [], by = {}
            for (i = 0; i < h.length; i++) {
                var a = h[i].appName || "Other"
                if (!by[a]) { by[a] = []; order.push(a) }
                by[a].push(h[i])
            }
            for (var g = 0; g < order.length; g++) {
                var ids = by[order[g]].map(function (n) { return n.id }).join(",")
                out.push({ key: "g:" + order[g] + ":" + ids, kind: "group", app: order[g], items: by[order[g]] })
            }
        } else if (mode === "timeline") {
            var nowMs = Date.now(), d0 = new Date()
            d0.setHours(0, 0, 0, 0)
            var labels = ["Just now", "Earlier today", "Yesterday", "Older"], last = -1
            for (i = 0; i < h.length; i++) {
                var t = arrivedMap[h[i].id] || nowMs
                var b = (nowMs - t) < 600000 ? 0 : t >= d0.getTime() ? 1 : t >= d0.getTime() - 86400000 ? 2 : 3
                if (b < last) b = last                     // newest first: a bucket never goes back up the list
                if (b !== last) { out.push({ key: "h:" + b, kind: "head", label: labels[b] }); last = b }
                out.push({ key: "r:" + h[i].id, kind: "line", n: h[i] })
            }
        } else {
            for (i = 0; i < h.length; i++) out.push({ key: "r:" + h[i].id, kind: "row", n: h[i] })
        }
        return out
    }

    clip: true
    spacing: look === "timeline" ? 0 : rowGap
    boundsBehavior: Flickable.StopAtBounds
    model: ScriptModel { values: list.entries; objectProp: "key" }

    delegate: Item {
        id: cell
        required property var modelData
        readonly property string kind: modelData.kind
        width: list.width
        height: (rowLd.item ? rowLd.item.height : 0) + (lineLd.item ? lineLd.item.height : 0)
              + (groupLd.item ? groupLd.item.height : 0) + (headLd.item ? headLd.item.height : 0)

        // Smooth re-flow WITHOUT ListView's add / displaced transitions. Those leave the rows below stuck at the wrong y (the cards
        // overlap) whenever a card changes height while its transition is still running, which is exactly what happens when a
        // notification is updated just after it arrives (e.g. the AI explanation being appended). A Behavior on y always ends at
        // whatever y the list last assigned, so it can never end up in the wrong place. `live` keeps a new cell from gliding in
        // from y = 0 on its first placement.
        property bool live: false
        Behavior on y {
            enabled: cell.live && list.pal.motion > 0.05
            NumberAnimation { duration: list.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: list.pal.curveDecel }
        }

        // the entrance happens on the content, not on the cell, so the cell's own geometry stays entirely in the list's hands
        property real enter: list.pal.motion > 0.05 ? 0 : 1
        Component.onCompleted: { Qt.callLater(function () { cell.live = true }); if (list.pal.motion > 0.05) enterAnim.start() }
        NumberAnimation { id: enterAnim; target: cell; property: "enter"; to: 1; duration: list.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: list.pal.curveDecel }
        readonly property real contentX: (1 - enter) * 30

        Loader {
            id: rowLd
            opacity: cell.enter
            x: cell.contentX
            active: cell.kind === "row"
            width: cell.width
            sourceComponent: Component {
                NotifRow {
                    notif: cell.modelData.n
                    pal: list.pal
                    avatar: list.notifs.avatar
                    usePfp: list.notifs.usePfp
                    arrived: list.arrivedMap[cell.modelData.n.id] || 0
                    now: list.now
                    onDismissRequested: list.dismissRequested(cell.modelData.n)
                }
            }
        }
        Loader {
            id: lineLd
            opacity: cell.enter
            x: cell.contentX
            active: cell.kind === "line"
            width: cell.width
            sourceComponent: Component {
                NotifLine {
                    notif: cell.modelData.n
                    pal: list.pal
                    arrived: list.arrivedMap[cell.modelData.n.id] || 0
                    now: list.now
                    onDismissRequested: list.dismissRequested(cell.modelData.n)
                }
            }
        }
        Loader {
            id: groupLd
            opacity: cell.enter
            x: cell.contentX
            active: cell.kind === "group"
            width: cell.width
            sourceComponent: Component {
                NotifGroup {
                    pal: list.pal
                    app: cell.modelData.app
                    items: cell.modelData.items
                    arrivedMap: list.arrivedMap
                    now: list.now
                    onDismissItem: n => list.dismissRequested(n)
                    onDismissAll: { var all = cell.modelData.items.slice(); for (var i = 0; i < all.length; i++) list.dismissRequested(all[i]) }
                }
            }
        }
        Loader {
            id: headLd
            opacity: cell.enter
            x: cell.contentX
            active: cell.kind === "head"
            width: cell.width
            sourceComponent: Component {
                Item {
                    height: 30
                    Text {
                        x: 62; y: 8
                        text: cell.modelData.label
                        color: list.pal.muted
                        font.family: list.pal.uiFont
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.letterSpacing: list.pal.calm ? 0.2 : (0.9)
                        font.capitalization: list.pal.calm ? Font.MixedCase : Font.AllUppercase
                    }
                }
            }
        }
    }

    // Only the removal is a ListView transition (the row fades and slides out while the ones below glide up through their Behavior on y).
    // No `add` / `displaced` here: see the note in the delegate.
    remove: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; to: 0; duration: list.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: list.pal.curveFx }
            NumberAnimation { property: "x"; to: 30; duration: list.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: list.pal.curveAccel }
        }
    }
}
