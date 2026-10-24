import QtQuick
import Quickshell
import Quickshell.Wayland

// The guided tour (first start) and the "what's new" tour (after an update).
// The screen is dimmed except for a rounded hole around the part being explained; the hole lets the pointer through, so the
// highlighted thing can be touched. A card next to the hole says what it does. Esc skips, Right / Enter / Space next, Left back.
// To keep it light:
//   - the welcome card offers a Quick tour (the steps marked "quick" in features.json) or everything
//   - a card shows one line big (typed in), the rest under "More"
//   - "try" steps are small challenges: do the thing yourself (shell.qml watches for it and calls challengeDone()), a star burst,
//     +1 star; "Show me" opens it for you instead (showMe())
//   - the progress is a constellation that fills in, Hal (a little sparkle) bobs beside the card and cheers, and the last card
//     says how many stars you found
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
    signal showMe()                       // a challenge step: open it for me instead (shell.qml)

    // ---- the game: challenges done (by step id) and stars collected
    property var doneIds: ({})
    property int stars: 0
    property int burst: 0                  // goes up once per reward: the star burst and Hal's spin follow it
    readonly property int challenges: steps.filter(function (f) { return !!f.try }).length
    readonly property bool waiting: !!step && !!step.try && doneIds[step.id] !== true
    function isDone(id) { return doneIds[id] === true }
    function challengeDone() {
        if (!step || !step.try || doneIds[step.id] === true) return
        var d = {}                         // a new object: assigning the same one again would not tell the bindings
        for (var k in doneIds) d[k] = doneIds[k]
        d[step.id] = true
        doneIds = d
        stars++
        burst++
    }
    // the welcome card's "Quick tour": only the steps marked quick (the first and last always stay)
    readonly property int quickCount: steps.filter(function (f, i) { return f.quick === true || i === 0 || i === steps.length - 1 }).length
    function quickOnly() {
        var n = steps.length
        steps = steps.filter(function (f, i) { return f.quick === true || i === 0 || i === n - 1 })
        go(1)
    }
    // what a card says: one line big, the rest under "More" (short bodies are shown whole)
    function leadOf(f) {
        var b = f ? (f.body || "") : ""
        if (b.length <= 170) return b
        var m = b.match(/^.{20,200}?[.!?](\s|$)/)
        return m ? m[0].trim() : b
    }
    function restOf(f) {
        var b = f ? (f.body || "") : "", l = leadOf(f)
        return b.length > l.length ? b.substring(l.length).trim() : ""
    }
    readonly property string rank: {
        var c = Math.max(1, challenges), r = stars / c
        return stars === 0 ? "Stargazer in training" : (r < 0.5 ? "Stargazer" : (r < 1 ? "Constellation keeper" : "Halcyon master"))
    }

    function start(newMode, newSteps) {
        if (!newSteps || newSteps.length === 0) return
        mode = newMode
        steps = newSteps
        index = 0
        doneIds = ({}); stars = 0
        open = true
        stepShown(steps[0])
    }
    function go(i) {
        if (!open || i < 0 || i >= steps.length) return
        index = i
        if (i === steps.length - 1 && i > 0) burst++        // the last card: a burst and a spin to finish on
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

            // ---- where the hole is ----
            // t* = where the target IS (set at once, never animated: the card and the input mask follow these, so they move once
            //      per step instead of being re-aimed on every frame of the hole's glide).
            // h* = what is drawn. A new step glides there (glide = true); once it has settled the hole simply sits on the target
            //      every frame, so it stays glued to a bar that grows, shrinks or slides (the old 30 Hz poll + 70 ms animation
            //      restarted five animations over and over and trailed behind the bar).
            property real tx: width / 2
            property real ty: height / 2
            property real tw: 0
            property real th: 0
            property real tr: 0
            readonly property bool hasTarget: tw > 1 && th > 1
            property real hx: width / 2
            property real hy: height / 2
            property real hw: 0
            property real hh: 0
            property real hr: 0
            readonly property bool hasHole: hw > 1 && hh > 1
            property bool glide: true
            // the bar (and its pages) changes size all the time: read it on every frame. The other targets are still after the
            // first moments, so they are read a few times a second.
            readonly property bool moving: !!(root.step && ["bar", "perf", "media"].indexOf(root.step.target || "") >= 0)
            Behavior on hx { enabled: win.glide; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
            Behavior on hy { enabled: win.glide; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
            Behavior on hw { enabled: win.glide; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
            Behavior on hh { enabled: win.glide; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
            Behavior on hr { enabled: win.glide; NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }

            function refreshHole() {
                var r = (root.step && root.step.target && root.rectFn) ? root.rectFn(root.step.target, width, height) : null
                var nx, ny, nw, nh, nr
                if (r && r.w > 4 && r.h > 4) {
                    var pad = 7
                    nx = r.x - pad; ny = r.y - pad; nw = r.w + pad * 2; nh = r.h + pad * 2
                    nr = Math.min((r.r !== undefined ? r.r : root.pal.rLg) + pad, nw / 2, nh / 2)
                } else {
                    nx = width / 2; ny = height / 2; nw = 0; nh = 0; nr = 0
                }
                // ignore sub-pixel noise: it would only re-aim the card and rebuild the input mask for nothing
                if (Math.abs(nx - tx) < 0.2 && Math.abs(ny - ty) < 0.2 && Math.abs(nw - tw) < 0.2 && Math.abs(nh - th) < 0.2 && Math.abs(nr - tr) < 0.2) return
                tx = nx; ty = ny; tw = nw; th = nh; tr = nr
                hx = nx; hy = ny; hw = nw; hh = nh; hr = nr
            }
            Connections { target: root; function onIndexChanged() { win.glide = true; settleT.restart(); win.refreshHole() } }
            Timer { id: settleT; interval: root.pal.dSlow + 120; onTriggered: win.glide = false }
            Component.onCompleted: { refreshHole(); settleT.restart() }
            FrameAnimation { running: root.open && win.moving; onTriggered: win.refreshHole() }
            Timer { interval: 50; repeat: true; running: root.open && !win.moving; onTriggered: win.refreshHole() }

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

                // light around the hole: a thin accent line and two fading halos, all following the hole.
                // The pulse is the opacity of the inner group (one cheap node value per frame); the colours never change.
                Item {
                    id: light
                    opacity: win.hasHole ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: root.pal.dMed } }
                    property real pulse: 1
                    SequentialAnimation on pulse {
                        running: root.open && win.hasHole && root.pal.motion > 0.3
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.55; duration: 1300; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1300; easing.type: Easing.InOutSine }
                    }
                    Item {
                        opacity: root.pal.motion > 0.3 ? light.pulse : 1
                        Repeater {
                            model: 3
                            delegate: Rectangle {
                                required property int index
                                readonly property real grow: 2 + index * 5
                                x: win.hx - grow; y: win.hy - grow
                                width: win.hw + grow * 2; height: win.hh + grow * 2
                                radius: win.hr + grow
                                color: "transparent"
                                border.width: index === 0 ? 1.5 : 5
                                border.color: Qt.alpha(root.pal.accent, index === 0 ? 0.9 : 0.16 / index)
                            }
                        }
                    }
                }

                // invisible: only gives the input mask the hole's shape (the target, so the mask is rebuilt once per step, not on every frame of the glide)
                Item { id: holeProbe; x: win.tx; y: win.ty; width: win.tw; height: win.th }

                // ---------------- the card ----------------
                Glass {
                    id: card
                    pal: root.pal
                    width: 392
                    height: col.implicitHeight + 40
                    radius: root.pal.rLg
                    opacityBody: root.pal.glassSolid - 0.02
                    border.color: root.waiting ? Qt.alpha(root.pal.accent, 0.4 + 0.4 * light.pulse) : Qt.alpha(root.pal.accent, 0.40)

                    // beside the hole: below, above, right, left; no hole = the middle of the screen
                    readonly property real gap: 22
                    readonly property var spot: {
                        var sw = scene.width, sh = scene.height, m = 24
                        if (root.view) return { x: (sw - width) / 2, y: sh - height - 36 }
                        if (!win.hasTarget) return { x: (sw - width) / 2, y: (sh - height) / 2 }
                        var cx = Math.max(m, Math.min(sw - width - m, win.tx + win.tw / 2 - width / 2))
                        var cy = Math.max(m, Math.min(sh - height - m, win.ty + win.th / 2 - height / 2))
                        if (win.ty + win.th + gap + height < sh - m) return { x: cx, y: win.ty + win.th + gap }
                        if (win.ty - gap - height > m) return { x: cx, y: win.ty - gap - height }
                        if (win.tx + win.tw + gap + width < sw - m) return { x: win.tx + win.tw + gap, y: cy }
                        if (win.tx - gap - width > m) return { x: win.tx - gap - width, y: cy }
                        return { x: (sw - width) / 2, y: (sh - height) / 2 }
                    }
                    x: spot.x
                    y: spot.y
                    Behavior on x { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.OutCubic } }
                    Behavior on height { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.OutCubic } }
                    MouseArea { anchors.fill: parent }       // clicks on the card do nothing

                    // a new step: the card gives a small hop and the big line is typed in
                    property real hop: 0
                    SequentialAnimation on hop {
                        id: hopAnim
                        running: false
                        NumberAnimation { to: 1; duration: 90; easing.type: Easing.OutQuad }
                        NumberAnimation { to: 0; duration: 380; easing.type: Easing.OutBack }
                    }
                    transform: Translate { y: -6 * card.hop }
                    property int typed: 0
                    NumberAnimation on typed { id: typeAnim; running: false; from: 0; duration: 520 }
                    property bool more: false
                    Connections {
                        target: root
                        function onIndexChanged() {
                            card.more = false
                            hopAnim.restart()
                            var n = root.leadOf(root.step).length
                            if (root.pal.motion > 0.3) { typeAnim.to = n; typeAnim.duration = Math.min(900, 12 * n); typeAnim.restart() } else card.typed = n
                        }
                        function onStepsChanged() { card.typed = root.leadOf(root.step).length }
                    }
                    Component.onCompleted: typed = root.leadOf(root.step).length

                    // ---- Hal, the little sparkle beside the card: bobs, blinks, and spins when you earn a star
                    Item {
                        id: hal
                        width: 54; height: 54
                        x: -26; y: -30
                        z: 5
                        property real bob: 0
                        NumberAnimation on bob { running: root.open && root.pal.motion > 0.3; from: 0; to: 2 * Math.PI; duration: 2400; loops: Animation.Infinite }
                        property real spin: 0
                        NumberAnimation on spin { id: halSpin; running: false; from: 0; to: 360; duration: 700; easing.type: Easing.OutBack }
                        Connections { target: root; function onBurstChanged() { halSpin.restart(); burstAnim.restart() } }
                        transform: Translate { y: 3 * Math.sin(hal.bob) }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 46; height: 46; radius: 23
                            color: Qt.alpha(root.pal.accent, 0.16)
                            border.width: 1; border.color: Qt.alpha(root.pal.accent, 0.55)
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "✦"
                            rotation: hal.spin + 8 * Math.sin(hal.bob * 0.5)
                            scale: 1 + 0.25 * Math.sin(hal.spin / 360 * Math.PI)
                            color: root.pal.accent
                            font.pixelSize: 28
                        }
                        // what Hal says: a cheer after a star, a nudge while a challenge waits
                        Rectangle {
                            id: speech
                            readonly property var cheers: ["Nice!", "You're a natural.", "Ooh, shiny.", "Star get!", "Look at you go.", "Smooth."]
                            readonly property string say: root.waiting ? "Your turn!" : (root.step && root.step.try && root.isDone(root.step.id) ? cheers[(root.stars + root.index) % cheers.length] : "")
                            visible: say !== ""
                            x: hal.width - 4; y: -10
                            width: sayText.implicitWidth + 18; height: 24; radius: 12
                            color: root.pal.accent
                            Text { id: sayText; anchors.centerIn: parent; text: speech.say; color: root.pal.bg; font.family: root.pal.uiFont; font.pixelSize: 11; font.weight: Font.DemiBold }
                        }
                    }

                    // ---- the star burst (once per reward)
                    Item {
                        id: burstBox
                        x: hal.x + hal.width / 2; y: hal.y + hal.height / 2
                        z: 6
                        property real t: 1
                        NumberAnimation on t { id: burstAnim; running: false; from: 0; to: 1; duration: 900; easing.type: Easing.OutCubic }
                        Repeater {
                            model: 16
                            delegate: Text {
                                required property int index
                                readonly property real ang: index / 16 * 2 * Math.PI + (index % 2) * 0.2
                                readonly property real dist: (60 + (index % 3) * 34) * burstBox.t
                                visible: burstBox.t < 1
                                x: Math.cos(ang) * dist - width / 2
                                y: Math.sin(ang) * dist - height / 2 + 30 * burstBox.t * burstBox.t
                                opacity: 1 - burstBox.t
                                text: index % 3 === 0 ? "✦" : "·"
                                color: index % 2 ? root.pal.accent : root.pal.accent2
                                font.pixelSize: index % 3 === 0 ? 18 : 30
                            }
                        }
                    }

                    Column {
                        id: col
                        x: 20; y: 20
                        width: parent.width - 40
                        spacing: 10

                        // badge, stars collected, step counter
                        Item {
                            width: parent.width; height: 20
                            Row {
                                x: 30
                                spacing: 8
                                Rectangle {
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
                                    visible: root.challenges > 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "✦ " + root.stars + " / " + root.challenges
                                    color: root.stars > 0 ? root.pal.accent : root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                    font.weight: Font.DemiBold
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
                            text: root.last && root.challenges > 0 ? "You found " + root.stars + " of " + root.challenges + " stars" : (root.step ? root.step.title : "")
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tDisplay - 2
                            font.weight: Font.DemiBold
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            visible: root.last && root.challenges > 0
                            width: parent.width
                            text: root.rank + (root.stars < root.challenges ? ". Replay with >tour to catch the rest." : ". Every single one!")
                            color: root.pal.accent
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody + 1
                            font.weight: Font.Medium
                            wrapMode: Text.WordWrap
                        }
                        // the big line, typed in
                        Text {
                            width: parent.width
                            text: root.leadOf(root.step).substring(0, card.typed)
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody + 2
                            lineHeight: 1.25
                            wrapMode: Text.WordWrap
                        }
                        // the rest, only when asked for
                        Text {
                            visible: card.more && root.restOf(root.step) !== ""
                            width: parent.width
                            text: root.restOf(root.step)
                            color: Qt.alpha(root.pal.text, 0.75)
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                            lineHeight: 1.25
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            visible: root.restOf(root.step) !== ""
                            text: card.more ? "Less ▴" : "More ▾"
                            color: moreMa.containsMouse ? root.pal.text : root.pal.accent
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            MouseArea { id: moreMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.more = !card.more }
                        }

                        // ---- the challenge
                        Rectangle {
                            visible: !!(root.step && root.step.try)
                            width: parent.width
                            height: chCol.implicitHeight + 20
                            radius: root.pal.rMd
                            color: root.waiting ? Qt.alpha(root.pal.accent, 0.10 + 0.06 * light.pulse) : Qt.alpha(root.pal.good, 0.14)
                            border.width: 1
                            border.color: root.waiting ? Qt.alpha(root.pal.accent, 0.6) : Qt.alpha(root.pal.good, 0.6)
                            Column {
                                id: chCol
                                x: 12; y: 10
                                width: parent.width - 24
                                spacing: 8
                                Text {
                                    width: parent.width
                                    text: root.waiting ? (root.pal.zen ? "Your turn  ·  " : "YOUR TURN  ·  ") + (root.step && root.step.try ? root.step.try.say : "")
                                                       : "✦  +1 star. That's exactly it."
                                    color: root.waiting ? root.pal.text : root.pal.good
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody
                                    font.weight: Font.DemiBold
                                    wrapMode: Text.WordWrap
                                }
                                // key caps
                                Row {
                                    visible: root.waiting && !!(root.step && root.step.keys && root.step.keys.length > 0)
                                    spacing: 6
                                    Repeater {
                                        model: root.step && root.step.keys ? root.step.keys : []
                                        delegate: keyCap
                                    }
                                }
                                Text {
                                    visible: root.waiting
                                    text: "Show me instead"
                                    color: showMa.containsMouse ? root.pal.text : root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                    font.underline: showMa.containsMouse
                                    MouseArea { id: showMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.showMe() }
                                }
                            }
                        }

                        // key caps of a step without a challenge
                        Row {
                            visible: !!(root.step && !root.step.try && root.step.keys && root.step.keys.length > 0)
                            spacing: 6
                            Repeater {
                                model: root.step && !root.step.try && root.step.keys ? root.step.keys : []
                                delegate: keyCap
                            }
                        }

                        // progress: a constellation that fills in (a star per step, joined up to where you are)
                        Item {
                            id: prog
                            width: parent.width
                            height: 18
                            readonly property real stepW: root.steps.length > 1 ? (width - 8) / (root.steps.length - 1) : 0
                            function px(i) { return 4 + i * stepW }
                            function py(i) { return 9 + (i % 2 ? -4 : 4) * (i % 3 === 0 ? 0.4 : 1) }
                            Repeater {
                                model: Math.max(0, root.steps.length - 1)
                                delegate: Rectangle {
                                    required property int index
                                    readonly property real dx: prog.px(index + 1) - prog.px(index)
                                    readonly property real dy: prog.py(index + 1) - prog.py(index)
                                    x: prog.px(index); y: prog.py(index)
                                    width: Math.sqrt(dx * dx + dy * dy); height: 1
                                    transformOrigin: Item.Left
                                    rotation: Math.atan2(dy, dx) * 180 / Math.PI
                                    color: index < root.index ? Qt.alpha(root.pal.accent, 0.7) : Qt.alpha(root.pal.text, 0.12)
                                    Behavior on color { ColorAnimation { duration: root.pal.dMed } }
                                }
                            }
                            Repeater {
                                model: root.steps.length
                                delegate: Rectangle {
                                    required property int index
                                    readonly property bool isCur: index === root.index
                                    readonly property bool won: root.isDone(root.steps[index] ? root.steps[index].id : "")
                                    width: isCur ? 8 : (won ? 6 : 4); height: width; radius: width / 2
                                    x: prog.px(index) - width / 2; y: prog.py(index) - height / 2
                                    color: won ? root.pal.good : (index <= root.index ? root.pal.accent : Qt.alpha(root.pal.text, 0.25))
                                    scale: isCur ? 0.85 + 0.3 * light.pulse : 1
                                    Behavior on width { NumberAnimation { duration: root.pal.dMed } }
                                }
                            }
                        }

                        // buttons (the welcome card: a quick tour or everything)
                        Item {
                            id: btns
                            width: parent.width; height: 34
                            readonly property bool chooser: root.index === 0 && root.mode === "welcome" && root.quickCount < root.steps.length
                            Text {
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
                                    visible: root.index > 0 || btns.chooser
                                    height: 32; radius: 16; width: backText.implicitWidth + 28
                                    color: backMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.95) : Qt.alpha(root.pal.surface, 0.9)
                                    border.width: root.pal.calm ? 0 : 1; border.color: root.pal.line
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Text { id: backText; anchors.centerIn: parent; text: btns.chooser ? "Everything (" + root.steps.length + ")" : "Back"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                    MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; onClicked: btns.chooser ? root.next() : root.back() }
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
                                        text: btns.chooser ? "Quick tour (" + root.quickCount + ")" : (root.last ? "Done" : (root.waiting ? "Skip it" : (root.index === 0 ? "Start" : "Next")))
                                        color: root.pal.bg
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        font.weight: Font.DemiBold
                                    }
                                    MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true; onClicked: btns.chooser ? root.quickOnly() : root.next() }
                                }
                            }
                        }
                    }
                }

                Component {
                    id: keyCap
                    Row {
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
                            color: root.pal.box(Qt.alpha(root.pal.surface, 0.95))
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
        }
    }
}
