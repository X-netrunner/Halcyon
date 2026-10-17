import QtQuick
import Quickshell
import Quickshell.Services.SystemTray

// The corner boxes, on the desktop as widgets.
//   "Utilities box" (utilbox): Wi-Fi, Bluetooth, Do not disturb, volume, brightness, power      list | tiles | slim
//   "Background apps box" (appsbox): the apps living in the system tray, a click opens one       list | icons | count
// Same feeds and actions as the corner boxes (Panel.qml, BgApps.qml), so they always agree with them.
WBase {
    id: root

    readonly property bool isApps: kind === "appsbox"
    readonly property real boxW: opt("width", 260)
    readonly property var nt: env ? env.net : ({})

    // ---------------------------------------------------------------- utilities
    readonly property var picks: opt("show", ["wifi", "bt", "volume", "brightness", "power"])
    readonly property var toggleDefs: ({
        wifi:  { n: "Wi-Fi", i: 0xF05A9, on: nt && nt.wifi !== undefined && nt.wifi !== "off", sub: nt && nt.ssid ? String(nt.ssid) : "" },
        bt:    { n: "Bluetooth", i: 0xF00AF, on: nt && nt.bt !== undefined && nt.bt !== "off", sub: nt && nt.btdev ? String(nt.btdev) : "" },
        dnd:   { n: "Do not disturb", i: 0xF009B, on: env ? env.dnd === true : false, sub: "" },
        power: { n: "Power", i: 0xF0425, on: undefined, sub: "" }
    })
    readonly property var toggles: {
        var out = []
        for (var i = 0; i < picks.length; i++) { var d = toggleDefs[picks[i]]; if (d) out.push({ id: picks[i], n: d.n, i: d.i, on: d.on, sub: d.sub }) }
        return out
    }
    readonly property bool showVol: picks.indexOf("volume") >= 0
    readonly property bool showBri: picks.indexOf("brightness") >= 0
    readonly property real volV: env ? Math.max(0, Math.min(1, (env.vol || 0) / 100)) : 0
    readonly property real briV: env ? Math.max(0, Math.min(1, (env.bright || 0) / 100)) : 0

    // ---------------------------------------------------------------- background apps
    readonly property var hiddenIds: ["nm-applet", "blueman", "blueman-applet", "network-manager-applet", "nm-tray"]
    readonly property var apps: {
        var res = []
        if (!isApps) return res
        var v = SystemTray.items.values
        for (var i = 0; i < v.length; i++) {
            var id = String(v[i].id || "").toLowerCase()
            if (hiddenIds.indexOf(id) < 0) res.push(v[i])
        }
        return res
    }
    function appName(it) {
        var t = String(it.tooltipTitle || it.title || "")
        return t !== "" ? t : String(it.id || "App")
    }
    hidden: isApps && opt("hideEmpty", false) === true && apps.length === 0

    implicitWidth: isApps ? (style === "count" ? cnt.implicitWidth : (style === "icons" ? Math.max(sz(60), icons.implicitWidth) : boxW)) : (style === "slim" ? slim.implicitWidth : boxW)
    implicitHeight: bodyLoader.implicitHeight
    Loader {
        id: bodyLoader
        width: root.implicitWidth
        sourceComponent: root.isApps ? (root.style === "count" ? countC : (root.style === "icons" ? iconsC : appListC))
                                      : (root.style === "tiles" ? tilesC : (root.style === "slim" ? slimC : listC))
    }
    // measured outside the loader so implicitWidth never depends on the loaded item
    Row { id: slim; visible: false; spacing: root.sz(8); Repeater { model: root.toggles; delegate: Item { width: root.sz(40); height: 1 } } Item { visible: root.showVol; width: root.sz(110); height: 1 } Item { visible: root.showBri; width: root.sz(110); height: 1 } }
    Row { id: icons; visible: false; spacing: root.sz(10); Repeater { model: root.apps; delegate: Item { width: root.sz(36); height: 1 } } }
    Text { id: cnt; visible: false; text: root.apps.length + (root.apps.length === 1 ? " app" : " apps") + " in the background"; font.pixelSize: root.sz(14); font.family: root.face }

    function press(id) {
        if (!env) return
        if (id === "power") env.deskAct("power")
        else env.deskAct(id)
    }

    // ---- utilities: list
    Component {
        id: listC
        Column {
            spacing: root.sz(8)
            Repeater { model: root.toggles; delegate: WbRow { b: root; required property var modelData; t: modelData } }
            WbLevel { b: root; visible: root.showVol; isVol: true; v: root.volV; glyphCp: (root.env && root.env.muted) ? 0xF0581 : 0xF057E }
            WbLevel { b: root; visible: root.showBri; isVol: false; v: root.briV; glyphCp: 0xF00DF }
        }
    }
    // ---- utilities: tiles
    Component {
        id: tilesC
        Column {
            spacing: root.sz(10)
            Grid {
                columns: 2; spacing: root.sz(8)
                Repeater {
                    model: root.toggles
                    delegate: Rectangle {
                        id: tile
                        required property var modelData
                        readonly property bool lit: modelData.on === true
                        width: (root.boxW - root.sz(8)) / 2; height: root.sz(70); radius: root.sz(18)
                        color: lit ? Qt.alpha(root.accent, 0.26) : Qt.alpha(root.fg, 0.07)
                        border.width: 1; border.color: lit ? Qt.alpha(root.accent, 0.8) : Qt.alpha(root.fg, 0.1)
                        Column {
                            anchors.centerIn: parent; spacing: root.sz(4)
                            WIco { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: root.glyph(tile.modelData.i); color: tile.lit ? root.accent : root.dim; font.pixelSize: root.sz(24) }
                            WLbl { b: root; anchors.horizontalCenter: parent.horizontalCenter; text: tile.modelData.n; font.pixelSize: root.sz(11.5) }
                        }
                        MouseArea { anchors.fill: parent; enabled: !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: root.press(tile.modelData.id) }
                    }
                }
            }
            WbLevel { b: root; visible: root.showVol; isVol: true; v: root.volV; glyphCp: (root.env && root.env.muted) ? 0xF0581 : 0xF057E }
            WbLevel { b: root; visible: root.showBri; isVol: false; v: root.briV; glyphCp: 0xF00DF }
        }
    }
    // ---- utilities: one slim bar
    Component {
        id: slimC
        Row {
            spacing: root.sz(8)
            Repeater {
                model: root.toggles
                delegate: Rectangle {
                    id: sb
                    required property var modelData
                    readonly property bool lit: modelData.on === true
                    width: root.sz(40); height: root.sz(40); radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: lit ? Qt.alpha(root.accent, 0.26) : Qt.alpha(root.fg, 0.08)
                    border.width: 1; border.color: lit ? Qt.alpha(root.accent, 0.8) : Qt.alpha(root.fg, 0.1)
                    WIco { b: root; anchors.centerIn: parent; text: root.glyph(sb.modelData.i); color: sb.lit ? root.accent : root.dim; font.pixelSize: root.sz(19) }
                    MouseArea { anchors.fill: parent; enabled: !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: root.press(sb.modelData.id) }
                }
            }
            WbLevel { b: root; visible: root.showVol; width: root.sz(110); anchors.verticalCenter: parent.verticalCenter; isVol: true; v: root.volV; glyphCp: (root.env && root.env.muted) ? 0xF0581 : 0xF057E }
            WbLevel { b: root; visible: root.showBri; width: root.sz(110); anchors.verticalCenter: parent.verticalCenter; isVol: false; v: root.briV; glyphCp: 0xF00DF }
        }
    }

    // ---- background apps: list
    Component {
        id: appListC
        Column {
            spacing: root.sz(8)
            WLbl { b: root; text: "BACKGROUND APPS"; color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 2.5 }
            WLbl { b: root; visible: root.apps.length === 0; text: "Nothing is running in the background"; color: root.dim; font.pixelSize: root.sz(12) }
            Repeater {
                model: root.apps
                delegate: Rectangle {
                    id: ar
                    required property var modelData
                    width: root.boxW; height: root.sz(40); radius: root.sz(12)
                    color: am.containsMouse ? Qt.alpha(root.fg, 0.12) : Qt.alpha(root.fg, 0.06)
                    border.width: 1; border.color: Qt.alpha(root.fg, 0.1)
                    Image {
                        x: root.sz(10); anchors.verticalCenter: parent.verticalCenter
                        width: root.sz(24); height: width
                        sourceSize.width: 48; sourceSize.height: 48
                        source: ar.modelData.icon
                        fillMode: Image.PreserveAspectFit; smooth: true
                    }
                    WLbl { b: root; x: root.sz(44); anchors.verticalCenter: parent.verticalCenter; width: parent.width - root.sz(56); text: root.appName(ar.modelData); font.pixelSize: root.sz(13); elide: Text.ElideRight }
                    MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; enabled: !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: ar.modelData.activate() }
                }
            }
        }
    }
    // ---- background apps: icons only
    Component {
        id: iconsC
        Row {
            spacing: root.sz(10)
            WLbl { b: root; visible: root.apps.length === 0; text: "No background apps"; color: root.dim; font.pixelSize: root.sz(12) }
            Repeater {
                model: root.apps
                delegate: Rectangle {
                    id: ic
                    required property var modelData
                    width: root.sz(36); height: width; radius: width / 2
                    color: Qt.alpha(root.fg, 0.08); border.width: 1; border.color: Qt.alpha(root.fg, 0.12)
                    Image { anchors.centerIn: parent; width: root.sz(22); height: width; sourceSize.width: 44; sourceSize.height: 44; source: ic.modelData.icon; fillMode: Image.PreserveAspectFit; smooth: true }
                    MouseArea { anchors.fill: parent; enabled: !root.editing; cursorShape: Qt.PointingHandCursor; onClicked: ic.modelData.activate() }
                }
            }
        }
    }
    // ---- background apps: just the number
    Component {
        id: countC
        Row {
            spacing: root.sz(8)
            WIco { b: root; text: root.glyph(0xF0570); font.pixelSize: root.sz(20); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.apps.length + (root.apps.length === 1 ? " app" : " apps") + " in the background"; font.pixelSize: root.sz(14); anchors.verticalCenter: parent.verticalCenter }
        }
    }
}
