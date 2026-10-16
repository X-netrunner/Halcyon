import QtQuick
import "WidgetData.js" as WD

// All the desktop widgets, drawn over the wallpaper (Wallpaper.qml) and, with `editing`, over the screen while you place them
// (DesktopEditor.qml). The layout is opt.deskWidgets; this only draws it and reports what you changed (commit).
//   layout    the clean layout          uids   the widget ids in drawing order (the Repeater only rebuilds when this list changes,
//                                                so a slider in the Widget builder never restarts the widgets)
Item {
    id: root
    property var pal
    property var env
    property var opt: ({})
    property bool editing: false
    property string selected: ""
    property bool shown: true
    property real topInset: 24
    property real bottomInset: 24
    property real margin: 24

    signal commit(var data)               // the layout changed (moved, resized, removed)
    signal selectedRequested(string uid)
    signal openRequested(string uid)

    readonly property var layout: WD.normalize(opt ? opt.deskWidgets : null)
    property var uids: []
    function syncUids() {
        var u = []
        for (var i = 0; i < layout.items.length; i++) u.push(layout.items[i].uid)
        if (u.join("|") !== uids.join("|")) uids = u
    }
    onLayoutChanged: syncUids()
    Component.onCompleted: syncUids()

    property real guideX: -1
    property real guideY: -1

    Repeater {
        model: root.uids
        delegate: WidgetHost {
            required property string modelData
            pal: root.pal
            env: root.env
            item: WD.find(root.layout, modelData)
            editing: root.editing
            selected: root.editing && root.selected === modelData
            shown: root.shown
            screenW: root.width
            screenH: root.height
            margin: root.margin
            topInset: root.topInset
            bottomInset: root.bottomInset
            z: selected ? 1000 : 1
            onPicked: uid => root.selectedRequested(uid)
            onDragMoved: (gx, gy) => { root.guideX = gx; root.guideY = gy }
            onDropped: (uid, px, py) => root.commit(WD.setPos(root.layout, uid, px, py))
            onRescaled: (uid, s) => root.commit(WD.setScale(root.layout, uid, s))
            onRemoveRequested: uid => root.commit(WD.remove(root.layout, uid))
            onOpenRequested: uid => root.openRequested(uid)
        }
    }

    // snap guides while dragging
    Rectangle { visible: root.editing && root.guideX >= 0; x: root.guideX - 0.5; y: 0; width: 1; height: root.height; color: root.pal ? root.pal.accent : "white"; opacity: 0.8; z: 2000 }
    Rectangle { visible: root.editing && root.guideY >= 0; y: root.guideY - 0.5; x: 0; height: 1; width: root.width; color: root.pal ? root.pal.accent : "white"; opacity: 0.8; z: 2000 }
}
