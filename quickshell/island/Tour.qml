import QtQuick
import Quickshell
import Quickshell.Wayland

// The guided tour (first start) and the "what's new" tour (after an update).
// The screen is dimmed except for a rounded hole around the part being explained; the hole lets the pointer through, so the
// highlighted thing can be touched. A card next to the hole says what it does. Esc skips, Right / Enter / Space next, Left back.
//
// shell.qml owns the data (Tour.js) and the demos: it passes `steps` and `rectFn`, reacts to `stepShown`, and stores the result
// when `finished` fires. Nothing here touches the rest of the island.
Scope {
    id: root
    property var pal
    property bool open: false
    property string mode: "welcome"       // welcome | new
    property var steps: []
    property int index: 0
    // (targetName, screenW, screenH) -> { x, y, w, h } in screen pixels, or null for "no hole, centred card"
    property var rectFn: null
    readonly property var step: (index >= 0 && index < steps.length) ? steps[index] : null
    readonly property bool last: index >= steps.length - 1
    // a demo that fills the screen with its own window (shortcuts, commands, tree, settings): no dimming, the card goes to the bottom
    readonly property bool view: !!step && ["cheat", "cmds", "tree", "settings", "calendar"].indexOf(step.demo || "") >= 0
    property bool cycling: false

    signal stepShown(var step)
    signal finished(bool completed)       // completed = reached the end; false = skipped with Esc

    function start(newMode, newSteps) {
        if (!newSteps || newSteps.length === 0) return
        mode = newMode
        steps = newSteps
        index = 0
        open = true
        stepShown(steps[0])
    }
    function go(i) {
        if (!open || i < 0 || i >= steps.length) return
        index = i
        stepShown(steps[i])
    }
    function next() { if (last) end(true); else go(index + 1) }
    function back() { go(index - 1) }
    // other windows (they open on the Overlay layer too) cover this one when they appear; closing and re-opening it puts it back on top
    function raise() { if (!open) return; cycling = true; raiseT.restart() }
    Timer { id: raiseT; interval: 50; onTriggered: root.cycling = false }
    function end(completed) {
        if (!open) return
        open = false
        finished(completed)
    }

    LazyLoader {
        active: root.open && !root.cycling
        PanelWindow {
            id: win
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "island-tour"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // everything takes the pointer except the hole: the highlighted part can be used
            // (a full-screen demo behind the tour stays usable: then only the card takes the pointer)
            mask: Region {
                item: root.view ? card : scene
                regions: [ Region { item: holeProbe; intersection: Intersection.Subtract } ]
            }

            // ---- where the hole is (animated), refreshed while the target moves / animates ----
            property real hx: width / 2
            property real hy: height / 2
            property real hw: 0
            property real hh: 0
            property real hr: 0
            readonly property bool hasHole: hw > 1 && hh > 1
            // a new step glides to its place; after that the hole only has to follow the target a little behind, and the bar
            // changes size all the time (pages, hover, the clock), so it is read about 30 times a second
            property int holeDur: root.pal.dSlow
            Behavior on hx { NumberAnimation { duration: win.holeDur; easing.type: Easing.OutCubic } }
            Behavior on hy { NumberAnimation { duration: win.holeDur; easing.type: Easing.OutCubic } }
            Behavior on hw { NumberAnimation { duration: win.holeDur; easing.type: Easing.OutCubic } }
            Behavior on hh { NumberAnimation { duration: win.holeDur; easing.type: Easing.OutCubic } }
            Behavior on hr { NumberAnimation { duration: win.holeDur; easing.type: Easing.OutCubic } }

            function refreshHole() {
                var r = (root.step && root.step.target && root.rectFn) ? root.rectFn(root.step.target, width, height) : null
                if (r && r.w > 4 && r.h > 4) {
                    var pad = 7
                    hx = r.x - pad; hy = r.y - pad; hw = r.w + pad * 2; hh = r.h + pad * 2
                    hr = Math.min((r.r !== undefined ? r.r : root.pal.rLg) + pad, hw / 2, hh / 2)
                } else {
                    hx = width / 2; hy = height / 2; hw = 0; hh = 0; hr = 0
                }
            }
            Connections { target: root; function onIndexChanged() { win.holeDur = root.pal.dSlow; settleT.restart() } }
            Timer { id: settleT; interval: 700; onTriggered: win.holeDur = 70 }
            Component.onCompleted: { refreshHole(); settleT.restart() }
            Timer { interval: 33; repeat: true; running: root.open; onTriggered: win.refreshHole() }

            Item {
                id: scene
                anchors.fill: parent
                opacity: root.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
                focus: root.open
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { root.end(false); e.accepted = true }
                    else if (e.key === Qt.Key_Right || e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { root.next(); e.accepted = true }
                    else if (e.key === Qt.Key_Left || e.key === Qt.Key_Backspace) { root.back(); e.accepted = true }
                }

                // the dark screen with a rounded hole: a huge rectangle whose border is the dim colour (its inner edge is the hole)
                Rectangle {
                    id: dim
                    readonly property real bw: Math.max(scene.width, scene.height) + 40
                    x: win.hx - bw
                    y: win.hy - bw
                    width: win.hw + bw * 2
                    height: win.hh + bw * 2
                    radius: win.hr + bw
                    color: "transparent"
                    antialiasing: true
                    border.width: bw
                    border.color: root.view ? "transparent" : Qt.alpha(Qt.darker(root.pal.bg, 1.7), 0.74)
                    Behavior on border.color { ColorAnimation { duration: root.pal.dSlow } }
                }

                // light around the hole: a thin accent line and a few fading halos, all following the hole
                Item {
                    id: light
                    opacity: win.hasHole ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }
                    property real pulse: 1
                    SequentialAnimation on pulse {
                        running: root.open && win.hasHole
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.55; duration: 1300; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1300; easing.type: Easing.InOutSine }
                    }
                    Repeater {
                        model: 4
                        delegate: Rectangle {
                            required property int index
                            readonly property real grow: 2 + index * 5
                            x: win.hx - grow; y: win.hy - grow
                            width: win.hw + grow * 2; height: win.hh + grow * 2
                            radius: win.hr + grow
                            color: "transparent"
                            border.width: index === 0 ? 1.5 : 5
                            border.color: Qt.alpha(root.pal.accent, (index === 0 ? 0.9 : 0.16 / index) * light.pulse)
                        }
                    }
                }

                // invisible: only gives the input mask the hole's shape
                Item { id: holeProbe; x: win.hx; y: win.hy; width: win.hw; height: win.hh }

                // ---------------- the card ----------------
                Glass {
                    id: card
                    pal: root.pal
                    width: 372
                    height: col.implicitHeight + 40
                    radius: root.pal.rLg
                    opacityBody: root.pal.glassSolid - 0.02
                    border.color: Qt.alpha(root.pal.accent, 0.40)

                    // beside the hole: below, above, right, left; no hole = the middle of the screen
                    readonly property real gap: 22
                    readonly property var spot: {
                        var sw = scene.width, sh = scene.height, m = 24
                        if (root.view) return { x: (sw - width) / 2, y: sh - height - 36 }
                        if (!win.hasHole) return { x: (sw - width) / 2, y: (sh - height) / 2 }
                        var cx = Math.max(m, Math.min(sw - width - m, win.hx + win.hw / 2 - width / 2))
                        var cy = Math.max(m, Math.min(sh - height - m, win.hy + win.hh / 2 - height / 2))
                        if (win.hy + win.hh + gap + height < sh - m) return { x: cx, y: win.hy + win.hh + gap }
                        if (win.hy - gap - height > m) return { x: cx, y: win.hy - gap - height }
                        if (win.hx + win.hw + gap + width < sw - m) return { x: win.hx + win.hw + gap, y: cy }
                        if (win.hx - gap - width > m) return { x: win.hx - gap - width, y: cy }
                        return { x: (sw - width) / 2, y: (sh - height) / 2 }
                    }
                    x: spot.x
                    y: spot.y
                    Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    Behavior on y { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    MouseArea { anchors.fill: parent }       // clicks on the card do nothing

                    Column {
                        id: col
                        x: 20; y: 20
                        width: parent.width - 40
                        spacing: 10

                        // badge + step counter
                        Item {
                            width: parent.width; height: 20
                            Rectangle {
                                id: badge
                                height: 20; radius: 10
                                width: badgeText.implicitWidth + 18
                                color: Qt.alpha(root.pal.accent, 0.18)
                                border.width: 1
                                border.color: Qt.alpha(root.pal.accent, 0.5)
                                Text {
                                    id: badgeText
                                    anchors.centerIn: parent
                                    text: root.mode === "new" ? "WHAT'S NEW" : "TOUR"
                                    color: root.pal.accent
                                    font.family: root.pal.uiFont
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                    font.letterSpacing: 1.2
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: (root.index + 1) + " / " + root.steps.length
                                color: root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                            }
                        }

                        Text {
                            width: parent.width
                            text: root.step ? root.step.title : ""
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tDisplay - 2
                            font.weight: Font.DemiBold
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            width: parent.width
                            text: root.step ? root.step.body : ""
                            color: Qt.alpha(root.pal.text, 0.82)
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            lineHeight: 1.25
                            wrapMode: Text.WordWrap
                        }

                        // key caps
                        Row {
                            visible: !!(root.step && root.step.keys && root.step.keys.length > 0)
                            spacing: 6
                            Repeater {
                                model: root.step && root.step.keys ? root.step.keys : []
                                delegate: Row {
                                    required property var modelData
                                    required property int index
                                    spacing: 6
                                    Text {
                                        visible: index > 0
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "+"
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tCap
                                    }
                                    Rectangle {
                                        height: 26; radius: 7
                                        width: capText.implicitWidth + 18
                                        color: Qt.alpha(root.pal.surface, 0.95)
                                        border.width: 1
                                        border.color: Qt.alpha(root.pal.text, 0.18)
                                        Rectangle {          // the lower edge of the key
                                            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                            anchors.leftMargin: 5; anchors.rightMargin: 5
                                            height: 2; radius: 1
                                            color: Qt.alpha(root.pal.text, 0.12)
                                        }
                                        Text {
                                            id: capText
                                            anchors.centerIn: parent
                                            anchors.verticalCenterOffset: -1
                                            text: modelData
                                            color: root.pal.text
                                            font.family: root.pal.mono
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                        }
                                    }
                                }
                            }
                        }

                        // progress capsules
                        Row {
                            spacing: 4
                            height: 6
                            Repeater {
                                model: root.steps.length
                                delegate: Rectangle {
                                    required property int index
                                    height: 4; radius: 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: index === root.index ? 18 : 4
                                    color: index <= root.index ? root.pal.accent : Qt.alpha(root.pal.text, 0.18)
                                    Behavior on width { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                }
                            }
                        }

                        // buttons
                        Item {
                            width: parent.width; height: 34
                            Text {
                                id: skipBtn
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.last ? "" : "Skip  ·  Esc"
                                color: skipMa.containsMouse ? root.pal.text : root.pal.muted
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tCap
                                Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                MouseArea { id: skipMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; onClicked: root.end(false) }
                            }
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                Rectangle {
                                    visible: root.index > 0
                                    height: 32; radius: 16; width: 64
                                    color: backMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, 0.9)
                                    border.width: 1; border.color: root.pal.line
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Text { anchors.centerIn: parent; text: "Back"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.back() }
                                }
                                Rectangle {
                                    height: 32; radius: 16
                                    width: Math.max(84, nextText.implicitWidth + 32)
                                    scale: nextMa.pressed ? 0.96 : 1
                                    color: nextMa.containsMouse ? Qt.alpha(root.pal.accent, 0.95) : Qt.alpha(root.pal.accent, 0.85)
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Behavior on scale { NumberAnimation { duration: root.pal.dFast } }
                                    Text {
                                        id: nextText
                                        anchors.centerIn: parent
                                        text: root.last ? "Done" : (root.index === 0 ? "Start" : "Next")
                                        color: root.pal.bg
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        font.weight: Font.DemiBold
                                    }
                                    MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.next() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
