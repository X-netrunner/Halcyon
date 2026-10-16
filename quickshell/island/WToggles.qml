import QtQuick
import "WidgetData.js" as WD

// "Quick toggles" (Wi-Fi, Bluetooth, Do not disturb, Caffeine, Gaming, Num Lock, theme, night light, lock, power) and
// "App shortcuts" (your own buttons that start an app or a command). One file: both are a set of buttons.
//   toggles: row | grid | icons        shortcuts: row | grid | list
WBase {
    id: root

    readonly property bool isShort: kind === "shortcuts"
    readonly property var nt: env ? env.net : ({})

    // every toggle: its icon, its name, and whether it is lit (undefined = a plain button)
    readonly property var all: ({
        wifi:     { n: "Wi-Fi", i: 0xF05A9, on: nt && nt.wifi !== undefined && nt.wifi !== "off" },
        bt:       { n: "Bluetooth", i: 0xF00AF, on: nt && nt.bt !== undefined && nt.bt !== "off" },
        dnd:      { n: "Do not disturb", i: 0xF009B, on: env ? env.dnd === true : false },
        caffeine: { n: "Caffeine", i: 0xF0176, on: env ? env.caffeine === true : false },
        gaming:   { n: "Gaming", i: 0xF0297, on: env ? env.gaming === true : false },
        numlock:  { n: "Num Lock", i: 0xF0313, on: env ? env.numLock === true : false },
        theme:    { n: "Theme", i: 0xF0335, on: env ? env.theme === "light" : false },
        night:    { n: "Night light", i: 0xF0594, on: undefined },
        lock:     { n: "Lock", i: 0xF033E, on: undefined },
        power:    { n: "Power", i: 0xF0425, on: undefined }
    })
    readonly property var items: {
        var out = []
        if (isShort) {
            var s = WD.parseShortcuts(opt("items", ""))
            for (var j = 0; j < s.length; j++) out.push({ id: "run", n: s[j].name, i: 0xF003B, on: undefined, cmd: s[j].cmd })
            return out
        }
        var sel = opt("show", [])
        for (var i = 0; i < sel.length; i++) {
            var a = all[sel[i]]
            if (a) out.push({ id: sel[i], n: a.n, i: a.i, on: a.on, cmd: "" })
        }
        return out
    }
    readonly property bool iconsOnly: !isShort && style === "icons"
    readonly property int cols: style === "grid" ? 3 : (style === "list" ? 1 : Math.max(1, items.length))

    function press(it) {
        if (!env) return
        if (it.id === "run") env.deskRun(it.cmd)
        else env.deskAct(it.id)
    }

    implicitWidth: grid.implicitWidth
    implicitHeight: Math.max(grid.implicitHeight, 30)
    Text {
        visible: root.items.length === 0
        anchors.centerIn: parent
        text: root.isShort ? "Add buttons in the Widget builder" : "Pick buttons in the Widget builder"
        color: root.dim; font.family: root.face; font.pixelSize: root.sz(12)
    }
    Grid {
        id: grid
        columns: root.cols
        spacing: root.sz(8)
        Repeater {
            model: root.items
            delegate: Rectangle {
                id: btn
                required property var modelData
                readonly property bool lit: modelData.on === true
                width: root.iconsOnly ? root.sz(44) : (root.style === "list" ? root.sz(190) : (root.style === "grid" ? root.sz(92) : lab.implicitWidth + root.sz(46)))
                height: root.iconsOnly ? root.sz(44) : (root.style === "grid" ? root.sz(64) : root.sz(38))
                radius: root.iconsOnly ? width / 2 : (root.style === "grid" ? root.sz(16) : height / 2)
                color: lit ? Qt.alpha(root.accent, 0.24) : (bm.containsMouse ? Qt.alpha(root.fg, 0.14) : Qt.alpha(root.fg, 0.07))
                border.width: 1
                border.color: lit ? Qt.alpha(root.accent, 0.8) : Qt.alpha(root.fg, 0.10)
                scale: bm.pressed ? 0.95 : 1
                Behavior on color { ColorAnimation { duration: 140 } }
                Behavior on scale { NumberAnimation { duration: 120 } }

                Item {
                    anchors.centerIn: parent
                    width: content.width; height: content.height
                    Grid {
                        id: content
                        columns: root.style === "grid" ? 1 : 2
                        spacing: root.style === "grid" ? root.sz(4) : root.sz(8)
                        horizontalItemAlignment: Grid.AlignHCenter
                        verticalItemAlignment: Grid.AlignVCenter
                        WIco { b: root; text: root.glyph(btn.modelData.i); color: btn.lit ? root.accent : root.fg; font.pixelSize: root.sz(root.style === "grid" ? 20 : 17) }
                        WLbl { id: lab; b: root; visible: !root.iconsOnly; text: btn.modelData.n; elide: Text.ElideRight; width: Math.min(implicitWidth, root.style === "grid" ? root.sz(84) : root.sz(150))
                               color: btn.lit ? root.fg : root.dim; font.pixelSize: root.sz(root.style === "grid" ? 11 : 13); font.weight: Font.Medium }
                    }
                }
                MouseArea {
                    id: bm
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !root.editing
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.press(btn.modelData)
                }
            }
        }
    }
}
