import QtQuick
import QtQuick.Shapes
import "StarData.js" as Stars

// Constellation art, drawn in the wallpaper accent colour: stars with soft halos joined by hairlines.
//   lockdown  a shield          stealth  a coiled dragon          (both hand-placed, see StarData.js)
//   avatar    your profile picture turned into a constellation (`hx stars <image>`), via `custom`
// Vector only, so it is crisp at any size and free while hidden. Sits behind content; `strength` scales it.
Item {
    id: root
    property var pal
    property string mode: ""            // lockdown | stealth | avatar | "" (nothing)
    property var custom: null           // { w, h, stars:[[x,y,size]], edges:[[a,b]], dust:[[x,y,size]] } for mode "avatar"
    property real strength: 1.0
    property real fit: 0.9
    property real tilt: 0

    readonly property var art: mode === "lockdown" ? Stars.shield : (mode === "stealth" ? Stars.dragon : (mode === "avatar" ? custom : null))
    visible: art !== null && art !== undefined && strength > 0
    opacity: strength

    readonly property color tone: pal.accent
    readonly property real dw: art ? art.w : 100
    readonly property real dh: art ? art.h : 100

    // edges as one path: "M x,y L x,y M ..."
    readonly property string edgePath: {
        if (!art) return ""
        var p = "", s = art.stars, e = art.edges
        for (var i = 0; i < e.length; i++) {
            var a = s[e[i][0]], b = s[e[i][1]]
            if (a && b) p += "M" + a[0] + "," + a[1] + " L" + b[0] + "," + b[1] + " "
        }
        return p
    }

    // sizes are in screen pixels whatever the art is scaled to (the avatar grid is only 96 units wide)
    readonly property real u: 1 / Math.max(0.05, stage.scale)

    // shared slow twinkle phase
    property real ph: 0
    NumberAnimation on ph { from: 0; to: 6.2832; duration: 7000; loops: Animation.Infinite; running: root.visible }

    Item {
        id: stage
        width: root.dw
        height: root.dh
        anchors.centerIn: parent
        rotation: root.tilt
        scale: Math.min(root.width / root.dw, root.height / root.dh) * root.fit

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: Qt.alpha(root.tone, 0.07)
                strokeWidth: 4 * root.u
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathSvg { path: root.edgePath }
            }
            ShapePath {
                strokeColor: Qt.alpha(root.tone, 0.34)
                strokeWidth: 1.0 * root.u
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathSvg { path: root.edgePath }
            }
        }

        // faint background dust
        Repeater {
            model: root.art && root.art.dust ? root.art.dust : []
            delegate: Rectangle {
                required property var modelData
                required property int index
                x: modelData[0] - 0.8 * root.u; y: modelData[1] - 0.8 * root.u
                width: 1.6 * root.u; height: width; radius: width / 2
                color: root.tone
                opacity: 0.18 + 0.14 * Math.sin(root.ph * 1.0 + index * 1.7)
            }
        }

        // the stars: halo + core, each twinkling on its own phase
        Repeater {
            model: root.art ? root.art.stars : []
            delegate: Item {
                required property var modelData
                required property int index
                readonly property real r: modelData[2] || 1.5
                x: modelData[0]; y: modelData[1]
                opacity: 0.72 + 0.28 * Math.sin(root.ph + index * 0.9)
                Rectangle {
                    anchors.centerIn: parent
                    width: r * 9 * root.u; height: width; radius: width / 2
                    color: Qt.alpha(root.tone, 0.07)
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: r * 4.2 * root.u; height: width; radius: width / 2
                    color: Qt.alpha(root.tone, 0.18)
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: r * 2 * root.u; height: width; radius: width / 2
                    color: Qt.lighter(root.tone, 1.5)
                }
            }
        }
    }
}
