import QtQuick

// The Performance tab of the rail dashboard. It only picks the LOOK (Settings > Bar > Performance tab look) and gives it the same inputs
// and signals as before; the looks are separate files and only the one in use is loaded, so the others cost nothing:
//   sky    PerfSky.qml     a constellation of five stars, the last minute as star trails, the battery as Halcyon's star (the default)
//   orbit  PerfOrbit.qml   four rings round one centre (CPU, memory, GPU, storage), the battery as a ring of its own
//   pulse  PerfPulse.qml   five lanes like a heart monitor with a glowing wave each, the battery as a tank of light
//   tiles  PerfTiles.qml   a bento of tiles: a half-circle gauge, memory blocks, a dot ring, a donut, two network waves, a cell stack
// The three newer looks share their data in PerfBase.qml (they get this item as `src`). This tab only reads: the four signals below are
// never emitted by any look.
Item {
    id: perfTab
    property var pal
    property var stats: ({})
    property var net: ({})
    property var gpu: ({ gpu: 0, state: "none" })
    property var specs: ({})
    property var disks: ({ disks: [] })
    property string profile: "balanced"
    property string profileLabel: "Balanced"
    property bool autoPower: false
    property string autoNote: ""
    property string sysmode: ""
    property bool active: false              // the tab is on screen
    property string look: "sky"              // sky | orbit | pulse | tiles
    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()

    implicitWidth: 704
    implicitHeight: 316

    Loader {
        anchors.fill: parent
        sourceComponent: perfTab.look === "orbit" ? cOrbit : (perfTab.look === "pulse" ? cPulse : (perfTab.look === "tiles" ? cTiles : cSky))
    }

    Component {
        id: cSky
        PerfSky {
            pal: perfTab.pal
            stats: perfTab.stats
            net: perfTab.net
            gpu: perfTab.gpu
            specs: perfTab.specs
            disks: perfTab.disks
            profile: perfTab.profile
            profileLabel: perfTab.profileLabel
            autoPower: perfTab.autoPower
            autoNote: perfTab.autoNote
            sysmode: perfTab.sysmode
            active: perfTab.active
        }
    }
    Component { id: cOrbit; PerfOrbit { src: perfTab } }
    Component { id: cPulse; PerfPulse { src: perfTab } }
    Component { id: cTiles; PerfTiles { src: perfTab } }
}
