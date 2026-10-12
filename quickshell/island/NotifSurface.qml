import QtQuick
import "NotifLayout.js" as NL

// The notification box itself: the glass, the constellation behind it, the flying stars and the blocks (NotifBox.qml), sized by the
// builder's layout. The real panel (Notifs.qml) and the preview in the notification box builder both use this.
Glass {
    id: surf
    property var layout: null
    property var src
    property string look: "stack"
    property bool active: false
    property real now: Date.now()
    property real maxH: 700
    property bool stars: true
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    signal dndRequested(bool on)
    signal clearRequested()
    signal dismissRequested(var n)

    readonly property var cfg: NL.normalize(layout)
    width: cfg.width
    height: box.implicitHeight + 2 * cfg.pad
    radius: cfg.radius
    opacityBody: pal.glassSolid - 0.06

    // the constellation behind the whole box, faint
    Backdrop {
        anchors.fill: parent
        anchors.margins: 2
        visible: surf.cfg.behind && surf.stars && surf.visible
        pal: surf.pal
        mode: surf.sysmode
        avatarStars: surf.starData
        profileStars: surf.profileStars
        dots: 0
        artStrength: 0.32
        artFit: 0.95
    }
    // the small stars that drift across the bar and the other boxes
    BarStars {
        anchors.fill: parent
        anchors.margins: 6
        pal: surf.pal
        count: surf.cfg.fly
        loopMs: 140000
        sizeScale: 1.3
        active: surf.visible && surf.stars
        visible: surf.visible && surf.stars && surf.cfg.fly > 0
    }

    NotifBox {
        id: box
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: surf.cfg.pad }
        pal: surf.pal
        src: surf.src
        layout: surf.layout
        look: surf.look
        active: surf.active
        now: surf.now
        maxH: surf.maxH
        stars: surf.stars
        sysmode: surf.sysmode
        starData: surf.starData
        profileStars: surf.profileStars
        onDndRequested: on => surf.dndRequested(on)
        onClearRequested: surf.clearRequested()
        onDismissRequested: n => surf.dismissRequested(n)
    }
}
