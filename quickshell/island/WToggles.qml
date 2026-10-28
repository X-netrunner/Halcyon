import QtQuick
import "WidgetData.js" as WD

// "Quick toggles" (Wi-Fi, Bluetooth, Do not disturb, Caffeine, Gaming, Num Lock, theme, night light, lock, power) and
// "App shortcuts" (your own buttons that start an app or a command). One file: both are a set of buttons.
//   toggles: row | grid | icons | list | outline | glyphs        shortcuts: row | grid | list | outline | glyphs
WBase {
    id: root

    readonly property bool isShort: kind === "shortcuts"
    readonly property var nt: env ? env.net : ({})

    // every toggle: its name and icon (fixed)...
    readonly property var all: ({
        wifi:     { n: "Wi-Fi", i: 0xF05A9 },
        bt:       { n: "Bluetooth", i: 0xF00AF },
        dnd:      { n: "Do not disturb", i: 0xF009B },
        caffeine: { n: "Caffeine", i: 0xF0176 },
        gaming:   { n: "Gaming", i: 0xF0297 },
        numlock:  { n: "Num Lock", i: 0xF0313 },
        theme:    { n: "Theme", i: 0xF0335 },
        night:    { n: "Night light", i: 0xF0594 },
        lock:     { n: "Lock", i: 0xF033E },
        power:    { n: "Power", i: 0xF0425 }
    })
    // ...and whether it is lit right now (the plain buttons - night light, lock, power, your shortcuts - are never lit). Every button
    // asks for its own state; the list of buttons below no longer depends on these feeds, so it is not rebuilt (every button destroyed
    // and made again, hover and press lost) each time the Wi-Fi / Bluetooth reading or a switch changes.
    function isOn(id) {
        switch (id) {
        case "wifi": return !!nt && nt.wifi !== undefined && nt.wifi !== "off"
        case "bt": return !!nt && nt.bt !== undefined && nt.bt !== "off"
        case "dnd": return env ? env.dnd === true : false
        case "caffeine": return env ? env.caffeine === true : false
        case "gaming": return env ? env.gaming === true : false
        case "numlock": return env ? env.numLock === true : false
        case "theme": return env ? env.theme === "light" : false
        }
        return false
    }
    readonly property var items: {
        var out = []
        if (isShort) {
            var s = WD.parseShortcuts(opt("items", ""))
            for (var j = 0; j < s.length; j++) out.push({ id: "run", n: s[j].name, i: 0xF003B, cmd: s[j].cmd })
            return out
        }
        var sel = opt("show", [])
        for (var i = 0; i < sel.length; i++) {
            var a = all[sel[i]]
            if (a) out.push({ id: sel[i], n: a.n, i: a.i, cmd: "" })
        }
        return out
    }
    readonly property bool iconsOnly: !isShort && (style === "icons" || style === "glyphs")
    readonly property bool outlined: style === "outline"      // no fill, just a line round each button
    readonly property bool bare: style === "glyphs"           // no box at all: the icon (and name) alone, a dot under the lit one
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
                readonly property bool lit: root.isOn(modelData.id)
                width: root.iconsOnly ? root.sz(44) : (root.style === "list" ? root.sz(190) : (root.style === "grid" ? root.sz(92) : lab.width + root.sz(46)))
                height: root.iconsOnly ? root.sz(44) : (root.style === "grid" ? root.sz(64) : root.sz(38))
                radius: root.iconsOnly ? width / 2 : (root.style === "grid" ? root.sz(16) : height / 2)
                color: root.bare ? "transparent"
                     : (root.outlined ? (lit ? Qt.alpha(root.accent, 0.14) : (bm.containsMouse ? Qt.alpha(root.fg, 0.08) : "transparent"))
                     : (lit ? Qt.alpha(root.accent, 0.24) : (bm.containsMouse ? Qt.alpha(root.fg, 0.14) : Qt.alpha(root.fg, 0.07))))
                border.width: root.bare ? 0 : (root.outlined ? 1.5 : 1)
                border.color: lit ? Qt.alpha(root.accent, 0.8) : Qt.alpha(root.fg, root.outlined ? 0.38 : 0.10)
                scale: bm.pressed ? 0.95 : 1
                Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }

                // glyphs: the lit one has a small dot under it
                Rectangle {
                    visible: root.bare && btn.lit
                    anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: root.sz(2)
                    width: root.sz(5); height: width; radius: width / 2
                    color: root.accent
                }
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
