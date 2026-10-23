import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "NotifLayout.js" as NL

// What is inside the notification box: the blocks of the builder's layout (constellation band, title + buttons, the list), in the
// order and with the spacing the layout says. Used by the real panel (NotifSurface.qml inside Notifs.qml) and by the preview in the
// notification box builder, so what you see there is what you get.
Item {
    id: box
    property var pal
    property var src                       // history, arrived, avatar, usePfp, dnd  (the Notifs scope, or the builder's sample)
    property var layout: null              // opt.notifLayout (cleaned up by NL.normalize)
    property string look: "stack"          // stack | timeline | grouped
    property bool active: false            // on screen: the empty-state animations run, the "5m" labels stay fresh
    property real now: Date.now()
    property real maxH: 700                // room the whole box may use, for the height of the list
    property bool stars: true              // constellations in this box (Settings > Constellations)
    property string sysmode: ""
    property var starData: null
    property bool profileStars: true
    signal dndRequested(bool on)
    signal clearRequested()
    signal dismissRequested(var n)

    readonly property var cfg: NL.normalize(layout)
    readonly property var history: src ? src.history : []
    readonly property bool dnd: src ? src.dnd : false
    // the band only takes room while there is a constellation to draw in it (the mode's art or your profile picture); with
    // nothing to draw it would be an empty gap, so it is left out. The drifting dots are not in the band: they sit behind the
    // whole box (NotifSurface.qml) and take no room.
    readonly property bool hasArt: sysmode === "lockdown" || sysmode === "stealth" || (profileStars && starData !== null && starData !== undefined)
    readonly property bool skyEmpty: !hasArt
    readonly property var order: {
        var out = [], b = cfg.blocks
        for (var i = 0; i < b.length; i++) if (b[i].on && (b[i].id !== "sky" || (stars && !skyEmpty))) out.push(b[i].id)
        return out
    }
    readonly property real skyHeight: cfg.skyH > 0 ? cfg.skyH : Math.max(90, Math.min(150, maxH * 0.2))
    readonly property real skyUsed: order.indexOf("sky") >= 0 ? skyHeight : 0
    readonly property real listMax: Math.max(150, Math.min(470, maxH - skyUsed - 190))

    // The parts are not in a column layout: each one sits at a y worked out from the order, so when the order changes (the arrows in
    // the builder) or a part appears or goes, the parts slide into their new places instead of jumping.
    property bool ready: false              // no sliding while the box is first built
    Component.onCompleted: Qt.callLater(function () { box.ready = true })
    function shown(id) { return order.indexOf(id) >= 0 }
    function blockH(id) {
        var l = id === "sky" ? skyLd : (id === "header" ? headerLd : listLd)
        return l.item ? l.item.implicitHeight : 0
    }
    function yOf(id) {
        var y = 0, b = cfg.blocks
        for (var i = 0; i < b.length; i++) {
            if (b[i].id === id) return y
            if (shown(b[i].id)) y += blockH(b[i].id) + cfg.gap
        }
        return y
    }
    function total() {
        var h = 0, n = 0, b = cfg.blocks
        for (var i = 0; i < b.length; i++) if (shown(b[i].id)) { h += blockH(b[i].id); n++ }
        return h + Math.max(0, n - 1) * cfg.gap
    }
    implicitHeight: total()

    NotifBlock { id: skyLd; host: box; bid: "sky"; sourceComponent: skyC }
    NotifBlock { id: headerLd; host: box; bid: "header"; sourceComponent: headerC }
    NotifBlock { id: listLd; host: box; bid: "list"; sourceComponent: listC }

    // ---------------------------------------------------------------- the constellation band
    Component {
        id: skyC
        Item {
            width: parent ? parent.width : 0
            implicitHeight: box.skyHeight
            Backdrop {
                anchors.fill: parent
                visible: box.stars
                pal: box.pal
                mode: box.sysmode
                avatarStars: box.starData
                profileStars: box.profileStars
                dots: 0
                artStrength: 1
                artFit: 0.9
            }
        }
    }

    // ---------------------------------------------------------------- title, count, buttons
    Component {
        id: headerC
        ColumnLayout {
            width: parent ? parent.width : 0
            spacing: Math.max(6, box.cfg.gap - 2)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                BoxTitle {
                    pal: box.pal
                    title: "Notifications"
                    sub: box.history.length === 0 ? "You are all caught up"
                        : box.history.length + (box.history.length === 1 ? " notification" : " notifications") + (box.dnd ? "  ·  muted" : "")
                }
                Chip {
                    Layout.preferredHeight: 30
                    pal: box.pal
                    glyph: String.fromCodePoint(0xF009B)
                    label: "DND"
                    on: box.dnd
                    onClicked: box.dndRequested(!box.dnd)
                }
                Chip {
                    Layout.preferredHeight: 30
                    visible: box.history.length > 0
                    pal: box.pal
                    label: "Clear"
                    onClicked: box.clearRequested()
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: box.pal.lineSoft }
        }
    }

    // ---------------------------------------------------------------- the notifications (or the "all caught up" picture)
    Component {
        id: listC
        ColumnLayout {
            width: parent ? parent.width : 0
            spacing: 0
            NotifList {
                id: list
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, box.listMax)
                visible: box.history.length > 0
                pal: box.pal
                notifs: box.src
                look: box.look
                rowGap: box.cfg.rowGap
                now: box.now
                onDismissRequested: n => box.dismissRequested(n)
            }

            // empty: a tree-style node (same look as the SUPER+TAB nodes) with a short branch and a label
            Item {
                visible: box.history.length === 0
                Layout.fillWidth: true
                Layout.preferredHeight: 190
                Layout.topMargin: 6

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 0
                    width: 2
                    height: 52
                    radius: 1
                    color: Qt.alpha(box.pal.accent, 0.28)
                    Rectangle {
                        width: 4; height: 4; radius: 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: box.pal.accent
                        SequentialAnimation on y {
                            running: box.active && box.history.length === 0
                            loops: Animation.Infinite
                            NumberAnimation { from: 0; to: 48; duration: 1800; easing.type: Easing.InOutSine }
                            PauseAnimation { duration: 500 }
                        }
                    }
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 52
                    width: 76; height: 76; radius: 28
                    color: Qt.alpha(box.pal.surface, 0.97)
                    border.width: 1.5
                    border.color: Qt.alpha(box.dnd ? box.pal.muted : box.pal.accent, 0.7)
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width + 14; height: width; radius: 34
                        color: "transparent"
                        border.width: 1
                        border.color: Qt.alpha(box.pal.accent, 0.5)
                        SequentialAnimation on opacity {
                            running: box.active && box.history.length === 0
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.5; duration: 2200; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 0.08; duration: 2200; easing.type: Easing.InOutSine }
                        }
                    }
                    Shape {
                        anchors.centerIn: parent
                        width: 40; height: 40
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: box.pal.accent
                            strokeWidth: 2.6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            PathSvg { path: box.dnd ? "M26,6 C14,7 7,16 9,26 C11,35 22,39 31,33 C21,32 17,22 21,14 C22,11 24,8 26,6 Z" : "M9,21 L17,29 L32,12" }
                        }
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 140
                    text: box.dnd ? "Do not disturb" : "All caught up"
                    color: box.pal.text
                    font.family: box.pal.uiFont
                    font.pixelSize: box.pal.tTitle
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 163
                    text: box.dnd ? "popups are muted, new ones are still kept" : "nothing new"
                    color: box.pal.muted
                    font.family: box.pal.uiFont
                    font.pixelSize: box.pal.tCap
                }
            }
        }
    }
}
