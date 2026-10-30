import QtQuick

// The Performance tab of the rail dashboard. It only picks the LOOK (Settings > Bar > Performance tab look) and gives it the same inputs
// and signals as before; the looks are separate files and only the one in use is loaded, so the others cost nothing:
//   sky    PerfSky.qml     a constellation of five stars, the last minute as star trails, the battery as Halcyon's star (the default)
//   orbit  PerfOrbit.qml   four rings round one centre (CPU, memory, GPU, storage), the battery as a ring of its own
//   pulse  PerfPulse.qml   five lanes like a heart monitor with a glowing wave each, the battery as a tank of light
//   tiles  PerfTiles.qml   a bento of tiles: a half-circle gauge, memory blocks, a dot ring, a donut, two network waves, a cell stack
//   forecast PerfForecast.qml the machine in one short sentence, a temperature, five tiles with one bar each
//   classic PerfClassic.qml  the rings, spec rows and disk bars the island page always had (the default of island and notch)
//   radar  PerfRadar.qml    a pentagon radar (CPU, memory, GPU, storage, network) with the last minute's average as a dashed ghost
//   cockpit PerfCockpit.qml  a big CPU dial with a temperature arc, four small rings, a row of indicator lamps
//   recorder PerfRecorder.qml the last five minutes on one graph with the power / sysmode changes marked, scrub it with the pointer
//   editorial PerfEditorial.qml one huge number (the busiest part), a quiet table beside it, no Canvas
//   stars  PerfStars.qml    six live four-point stars (the splash's sparkle), brighter with more load, dimmer with less
//   sea    PerfSea.qml     a calm sea: a sun (light theme) or a moon and stars (dark theme) that is also the battery, waves, a buoy per part
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
    property string look: "sky"              // sky | orbit | pulse | tiles | sea | forecast | radar | cockpit | recorder | editorial | stars | classic ('auto' is resolved by shell.qml, never here)
    signal toggleWifi()
    signal toggleBt()
    signal setProfile(string p)
    signal setAuto()

    implicitWidth: 704
    implicitHeight: 316

    Loader {
        anchors.fill: parent
        sourceComponent: ({ orbit: cOrbit, pulse: cPulse, tiles: cTiles, sea: cSea, forecast: cForecast, classic: cClassic, radar: cRadar, cockpit: cCockpit, recorder: cRecorder, editorial: cEditorial, stars: cStars })[perfTab.look] || cSky
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
    Component {
        id: cClassic
        PerfClassic {
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
            onToggleWifi: perfTab.toggleWifi()
            onToggleBt: perfTab.toggleBt()
            onSetProfile: p => perfTab.setProfile(p)
            onSetAuto: perfTab.setAuto()
        }
    }
    Component { id: cOrbit; PerfOrbit { src: perfTab } }
    Component { id: cPulse; PerfPulse { src: perfTab } }
    Component { id: cTiles; PerfTiles { src: perfTab } }
    Component { id: cSea; PerfSea { src: perfTab } }
    Component { id: cRadar; PerfRadar { src: perfTab } }
    Component { id: cCockpit; PerfCockpit { src: perfTab } }
    Component { id: cRecorder; PerfRecorder { src: perfTab } }
    Component { id: cEditorial; PerfEditorial { src: perfTab } }
    Component { id: cStars; PerfStars { src: perfTab } }
    Component { id: cForecast; PerfForecast { src: perfTab } }
}
