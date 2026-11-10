import QtQuick

// The dashboard of a rail bar (Caelestia's dashboard: Wrapper / Content / Tabs): ONE box with a strip of three tabs on top, Media,
// Calendar and Performance, and the page of the chosen tab under it. Calendar is the middle tab and the one it opens on: it is in the
// spotlight (a soft pill glides behind it, full colour) and the other two are faded back; click one and it takes the spotlight.
// Switching slides the pages sideways and the box glides to the new page's height (Caelestia does the same with a Flickable); the wheel
// over the strip and the Left / Right keys step through the tabs. RailPages.qml hangs it from the top edge of the screen, centred.
//
// STYLES (Settings > Bar > Dashboard style, opt.dashStyle): `style` picks what this box is. "tabs" is everything above (plus, under the Calendar page, the
// stat strip DashStrip.qml when `showStats`); "bento" (DashBento.qml) is one grid of cards with no tabs; "command" (DashCommand.qml) is a search bar, five
// switches and a short list. The box's size follows the style (implicitWidth / implicitHeight), RailPages.qml and Glass only read those two.
//
// Left out on purpose: Caelestia's weather and its user / uptime card. Halcyon's weather lives in a desktop widget that is not fed to this
// window; showing it here would have meant inventing data.
Item {
    id: root
    property var pal
    property var player: null
    property var cava: []
    property var stats: ({})
    property var gpu: ({ gpu: 0, state: "none" })
    property var specs: ({})
    property var disks: ({ disks: [] })
    property var net: ({})
    property string profile: "balanced"
    property string profileLabel: "Balanced"
    property bool autoPower: false
    property string autoNote: ""
    property string sysmode: ""
    property var cal: null                   // the Calendar scope (Calendar.qml): the month, the events
    property string perfLook: "sky"          // the Performance tab's look: sky | orbit | pulse | tiles | sea | forecast | radar | cockpit | recorder | editorial | stars | classic (shell.qml resolves 'auto') (Settings > Bar; PerfTab.qml)
    property int tab: 1                      // 0 = Media, 1 = Calendar (the default), 2 = Performance
    property bool open: false                // the box is shown: the tabs only read / sample while it is
    property string style: "tabs"            // tabs | bento | command (opt.dashStyle)
    property bool showStats: true            // the stat strip under the Calendar page of the Tabs style (opt.dashStrip)
    property bool wifiOn: false
    property bool btOn: false
    property bool dndOn: false
    property bool caffeineOn: false
    property bool airplaneOn: false
    property bool muteOn: false
    property bool gamingOn: false
    property bool dimOn: false
    readonly property bool tabsOn: style === "tabs"

    signal tabPicked(int index)
    signal openCalendar()
    signal openMusic(string tab)
    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()
    signal openLauncher()
    signal runCmd(string id)
    signal launch(string id)

    readonly property int pad: 16
    readonly property int paneW: 704
    readonly property int stripH: 48
    // the height of the page that is shown: the box glides from one page's height to the other's
    property real viewH: tab === 0 ? music.implicitHeight : (tab === 1 ? calTab.implicitHeight : perf.implicitHeight)
    Behavior on viewH { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

    // the stat strip under the Calendar page: its room opens and closes with the tab
    property real statSpace: (tabsOn && showStats && tab === 1) ? 64 : 0
    Behavior on statSpace { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
    readonly property real tabsH: pad + stripH + 8 + 1 + 12 + viewH + statSpace + pad
    implicitWidth: tabsOn ? paneW + pad * 2 : (alt.item ? alt.item.implicitWidth : paneW + pad * 2)
    implicitHeight: tabsOn ? tabsH : (alt.item ? alt.item.implicitHeight : tabsH)

    function step(d) { if (!tabsOn) return; var t = Math.max(0, Math.min(2, root.tab + d)); if (t !== root.tab) root.tabPicked(t) }

    // ---- the tab strip
    Item {
        id: strip
        visible: root.tabsOn
        x: root.pad; y: root.pad
        width: root.paneW
        height: root.stripH + 8
        // the spotlight: one soft pill behind the current tab, gliding to the next one
        Rectangle {
            id: spot
            readonly property Item t: root.tab === 0 ? tabMedia : (root.tab === 1 ? tabCal : tabPerf)
            x: t.x + 8
            y: 2
            width: t.width - 16
            height: root.stripH - 6
            radius: root.pal.rMd
            color: Qt.alpha(root.pal.accent, 0.13)
            border.width: 1
            border.color: Qt.alpha(root.pal.accent, 0.30)
            Behavior on x { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        }
        Row {
            id: tabs
            width: parent.width
            height: root.stripH
            DashTab {
                id: tabMedia
                width: tabs.width / 3; height: root.stripH
                pal: root.pal
                glyph: String.fromCodePoint(0xF075A)
                label: "Media"
                current: root.tab === 0
                onClicked: root.tabPicked(0)
            }
            DashTab {
                id: tabCal
                width: tabs.width / 3; height: root.stripH
                pal: root.pal
                glyph: String.fromCodePoint(0xF00ED)
                label: "Calendar"
                current: root.tab === 1
                onClicked: root.tabPicked(1)
            }
            DashTab {
                id: tabPerf
                width: tabs.width / 3; height: root.stripH
                pal: root.pal
                glyph: String.fromCodePoint(0xF04C5)
                label: "Performance"
                current: root.tab === 2
                onClicked: root.tabPicked(2)
            }
        }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: e => { if (e.angleDelta.y < 0) root.step(1); else if (e.angleDelta.y > 0) root.step(-1) }
        }
    }
    Rectangle {
        visible: root.tabsOn
        x: root.pad; y: root.pad + root.stripH + 8
        width: root.paneW; height: 1
        color: root.pal.line
    }

    // ---- the pages: side by side, the strip slides them
    Item {
        id: view
        visible: root.tabsOn
        x: root.pad
        y: root.pad + root.stripH + 8 + 1 + 12
        width: root.paneW
        height: root.viewH
        clip: true

        Row {
            id: panes
            x: -root.tab * root.paneW
            Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

            MusicTab {
                id: music
                width: root.paneW
                height: root.viewH
                pal: root.pal
                player: root.player
                cava: root.cava
                active: root.tabsOn && root.open && root.tab === 0
                opacity: root.tab === 0 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                onOpenMusic: t => root.openMusic(t)
            }
            CalTab {
                id: calTab
                width: root.paneW
                height: root.viewH
                pal: root.pal
                cal: root.cal
                active: root.tabsOn && root.open && root.tab === 1
                opacity: root.tab === 1 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                onOpenFull: root.openCalendar()
            }
            PerfTab {
                id: perf
                width: root.paneW
                height: root.viewH
                pal: root.pal
                stats: root.stats
                gpu: root.gpu
                specs: root.specs
                disks: root.disks
                net: root.net
                profile: root.profile
                profileLabel: root.profileLabel
                autoPower: root.autoPower
                autoNote: root.autoNote
                sysmode: root.sysmode
                look: root.perfLook
                active: root.tabsOn && root.open && root.tab === 2
                opacity: root.tab === 2 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                onToggleWifi: root.toggleWifi()
                onToggleBt: root.toggleBt()
                onSetProfile: p => root.setProfile(p)
                onSetAuto: root.setAuto()
            }
        }
    }
    // ---- Tabs style: the stat strip under the Calendar page
    DashStrip {
        id: statStrip
        pal: root.pal
        player: root.player
        stats: root.stats
        gpu: root.gpu
        x: root.pad
        y: root.pad + root.stripH + 8 + 1 + 12 + root.viewH + 8
        width: root.paneW
        height: 56
        opacity: (root.tabsOn && root.showStats && root.tab === 1) ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
    }

    // ---- the other two styles
    Component {
        id: bentoC
        DashBento {
            pal: root.pal
            player: root.player
            stats: root.stats
            cal: root.cal
            wifiOn: root.wifiOn; btOn: root.btOn; dndOn: root.dndOn; caffeineOn: root.caffeineOn
            open: root.open
            onOpenCalendar: root.openCalendar()
            onToggleWifi: root.toggleWifi()
            onToggleBt: root.toggleBt()
            onRunCmd: id => root.runCmd(id)
        }
    }
    Component {
        id: commandC
        DashCommand {
            pal: root.pal
            player: root.player
            cal: root.cal
            wifiOn: root.wifiOn; btOn: root.btOn; dndOn: root.dndOn; caffeineOn: root.caffeineOn
            airplaneOn: root.airplaneOn; muteOn: root.muteOn; gamingOn: root.gamingOn; dimOn: root.dimOn
            open: root.open
            onOpenLauncher: root.openLauncher()
            onOpenCalendar: root.openCalendar()
            onToggleWifi: root.toggleWifi()
            onToggleBt: root.toggleBt()
            onRunCmd: id => root.runCmd(id)
            onLaunch: id => root.launch(id)
        }
    }
    // keyboard for the Command style (RailPages.qml: Up / Down / Enter); harmless in the other styles
    function cmdMove(d) { if (style === "command" && alt.item && alt.item.move) alt.item.move(d) }
    function cmdEnter() { return style === "command" && alt.item && alt.item.enter ? alt.item.enter() : false }
    Loader {
        id: alt
        anchors.fill: parent
        active: !root.tabsOn
        sourceComponent: root.style === "command" ? commandC : bentoC
    }
}
