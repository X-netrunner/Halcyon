import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import "DeskSpots.js" as DS

// The desktop builder window (Settings > Appearance > Desktop builder > "Open ..."). A dimmed overlay with one card on it.
//   Left:   a small picture of the screen: the wallpaper (or the plain background), its blur, the moving stars, and the four
//           corners with the box that opens from each. Click a box, then click the corner you want it in.
//   Right:  wallpaper on / off + blur + background, the moving stars, the corner of each box, the notification trigger.
// Every change is saved and applied to the real desktop at once (it emits changed(key, value); Settings writes "opt:<key>").
Item {
    id: root
    property var pal
    property bool open: false
    property var opt: ({})
    property string wallpaperPath: ""
    signal changed(string key, var value)
    signal closed()

    readonly property bool wallOn: !opt || opt.deskWall !== false
    readonly property real blurAmt: Math.max(0, Math.min(1, (opt && opt.deskBlur !== undefined ? Number(opt.deskBlur) : 0) / 100))
    readonly property string bgKind: (opt && opt.deskBg) || "theme"
    readonly property bool starsOn: opt && opt.deskStars === true
    readonly property var spots: DS.normalize(opt ? opt.boxSpots : null)
    property string pick: ""                       // the box that was clicked and is waiting for a corner

    function num(k, d) { return opt && opt[k] !== undefined ? Number(opt[k]) : d }
    function put(k, v) { root.changed(k, v) }
    function moveBox(id, corner) { root.put("boxSpots", DS.move(opt ? opt.boxSpots : null, id, corner)); root.pick = "" }
    function resetAll() {
        put("deskWall", true); put("deskBlur", 0); put("deskBg", "theme")
        put("deskStars", false); put("deskStarCount", 70); put("deskStarSpeed", 1); put("deskStarSize", 1)
        put("deskStarDir", "right"); put("deskStarTone", "mix"); put("deskStarTwinkle", true); put("deskStarShoot", false)
        put("boxSpots", DS.defaults); put("notifSpot", "edge")
        root.pick = ""
    }

    opacity: open ? 1 : 0
    visible: opacity > 0.01
    focus: open
    Behavior on opacity { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.InOutSine } }
    onOpenChanged: { if (open) { pick = ""; Qt.callLater(function () { root.forceActiveFocus() }) } }
    Component.onCompleted: if (open) Qt.callLater(function () { root.forceActiveFocus() })
    Keys.onPressed: function (e) { if (e.key === Qt.Key_Escape) { if (root.pick !== "") root.pick = ""; else root.closed(); e.accepted = true } }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.pal.bg, 0.45)
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }

    Glass {
        id: card
        pal: root.pal
        anchors.centerIn: parent
        width: Math.min(parent.width - 120, 1100)
        height: Math.min(parent.height - 80, 720)
        radius: root.pal.rXl
        opacityBody: root.pal.solid ? 1 : 0.78
        border.color: Qt.alpha(root.pal.accent, 0.35)
        scale: root.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
        MouseArea { anchors.fill: parent; onPressed: m => { root.forceActiveFocus(); m.accepted = true } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 32
            spacing: 18

            // ---- header
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Rectangle { Layout.alignment: Qt.AlignVCenter; width: 8; height: 8; radius: 4; color: root.pal.accent }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text { text: "Desktop builder"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: 20; font.weight: Font.DemiBold }
                    Text { text: "The picture on the left is your screen. Change anything on the right."; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                }
                Item { Layout.fillWidth: true }
                ActionChip { pal: root.pal; label: "Reset the desktop"; doneLabel: "Reset"; onClicked: root.resetAll() }
                ActionChip { pal: root.pal; label: "Done"; on: true; onClicked: root.closed() }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 24

                // ================================================ the picture of the screen
                Rectangle {
                    id: stage
                    Layout.fillHeight: true
                    Layout.preferredWidth: 470
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.bg, 0.55)
                    border.width: 1
                    border.color: root.pal.lineTint
                    clip: true
                    NbCap { pal: root.pal; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 14; text: "LIVE PREVIEW" }

                    // the screen, at the real aspect ratio
                    Item {
                        id: scr
                        readonly property real ratio: Math.max(0.5, root.width) / Math.max(0.5, root.height)
                        width: stage.width - 40
                        height: Math.min(stage.height - 90, width / ratio)
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 22
                        readonly property real k: width / Math.max(1, root.width)      // preview scale

                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            clip: true
                            color: "#000000"
                            border.width: 1
                            border.color: root.pal.lineTint

                            // plain background (wallpaper off)
                            Rectangle {
                                anchors.fill: parent
                                color: root.bgKind === "black" ? "#000000" : root.pal.bg
                                gradient: root.bgKind === "gradient" ? pvGrad : null
                                Gradient {
                                    id: pvGrad
                                    GradientStop { position: 0.0; color: root.pal.bg }
                                    GradientStop { position: 1.0; color: Qt.tint(root.pal.bg, Qt.alpha(root.pal.accent, 0.30)) }
                                }
                            }
                            // the wallpaper, small (decoded at preview size, not the real one), blurred like the real thing
                            Image {
                                id: pvImg
                                anchors.fill: parent
                                anchors.margins: -Math.round(root.blurAmt * 56 * scr.k)
                                visible: root.wallOn && source.toString() !== ""
                                source: (root.open && root.wallOn && root.wallpaperPath !== "") ? "file://" + root.wallpaperPath : ""
                                sourceSize: Qt.size(640, 400)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                layer.enabled: root.blurAmt > 0.001
                                layer.effect: MultiEffect { blurEnabled: true; blurMax: 64; blur: root.blurAmt; autoPaddingEnabled: false }
                            }
                            DesktopStars {
                                anchors.fill: parent
                                pal: root.pal
                                opt: root.opt
                                previewScale: Math.max(0.35, scr.k * 1.6)
                                visible: root.open
                            }

                            // ---- the four corners
                            Repeater {
                                model: [
                                    { c: "tl", fixed: false },
                                    { c: "tr", fixed: true },
                                    { c: "bl", fixed: false },
                                    { c: "br", fixed: false }
                                ]
                                delegate: Item {
                                    id: slot
                                    required property var modelData
                                    readonly property string c: modelData.c
                                    readonly property string boxId: modelData.fixed ? "notif" : DS.boxAt(root.opt ? root.opt.boxSpots : null, c)
                                    readonly property bool atRight: c.charAt(1) === "r"
                                    readonly property bool atBottom: c.charAt(0) === "b"
                                    readonly property bool picked: boxId !== "" && boxId === root.pick
                                    readonly property bool target: root.pick !== "" && !modelData.fixed && boxId !== root.pick
                                    width: Math.min(scr.width * 0.38, 150)
                                    height: Math.min(scr.height * 0.24, 62)
                                    x: atRight ? scr.width - width - 8 : 8
                                    y: atBottom ? scr.height - height - 8 : 8

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 10
                                        color: slot.picked ? Qt.alpha(root.pal.accent, 0.35) : (slot.target && ma.containsMouse ? Qt.alpha(root.pal.accent, 0.25) : Qt.alpha(root.pal.bg, 0.72))
                                        border.width: slot.picked || slot.target ? 2 : 1
                                        border.color: slot.picked ? root.pal.accent : (slot.target ? Qt.alpha(root.pal.accent, 0.7) : root.pal.lineTint)
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                        Column {
                                            anchors.centerIn: parent
                                            spacing: 2
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: slot.boxId === "notif" ? "Notifications" : (DS.names[slot.boxId] || "")
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 12
                                                font.weight: Font.DemiBold
                                            }
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: slot.boxId === "notif" ? (root.opt && root.opt.notifSpot === "corner" ? "corner trigger" : "edge trigger") + " · fixed" : (slot.picked ? "pick a corner" : (slot.target ? "move here" : DS.cornerNames[slot.c]))
                                                color: slot.picked ? root.pal.accent : root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: 10
                                            }
                                        }
                                        MouseArea {
                                            id: ma
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            enabled: !slot.modelData.fixed
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (root.pick === "") root.pick = slot.boxId
                                                else if (root.pick === slot.boxId) root.pick = ""
                                                else root.moveBox(root.pick, slot.c)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.top: scr.bottom
                        anchors.topMargin: 12
                        anchors.leftMargin: 20; anchors.rightMargin: 20
                        text: root.pick !== "" ? ("Now click the corner for " + DS.names[root.pick] + ". Esc cancels.") : "Click a box, then click the corner you want it to open from. A box dropped on a taken corner swaps places with it."
                        color: root.pick !== "" ? root.pal.accent : root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: 10
                        lineHeight: 1.25
                        wrapMode: Text.WordWrap
                    }
                }

                // ================================================ the controls
                Flickable {
                    id: ctl
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: cc.implicitHeight + 8
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: cc
                        width: ctl.width - 12
                        spacing: 12

                        // ---- wallpaper
                        NbCap { pal: root.pal; text: "WALLPAPER" }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "Show the wallpaper"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Toggle { pal: root.pal; on: root.wallOn; onToggled: root.put("deskWall", !root.wallOn) }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: !root.wallOn
                            text: "No picture is loaded while this is off (it also frees the memory it used). The colours of the island, terminals and apps still follow the last wallpaper."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }
                        NbSlider {
                            Layout.fillWidth: true
                            visible: root.wallOn
                            pal: root.pal; label: "Blur"; from: 0; to: 100; unit: " %"; zeroText: "Off"
                            value: Math.round(root.num("deskBlur", 0))
                            onPicked: v => root.put("deskBlur", v)
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.wallOn && root.blurAmt > 0
                            text: "A blurred wallpaper is drawn through a GPU effect; it only works again when the picture changes, but on a weak GPU keep it low."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: !root.wallOn
                            spacing: 8
                            Text { text: "Background"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 128 }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Theme colour"; on: root.bgKind === "theme"; onClicked: root.put("deskBg", "theme") }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Black"; on: root.bgKind === "black"; onClicked: root.put("deskBg", "black") }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Gradient"; on: root.bgKind === "gradient"; onClicked: root.put("deskBg", "gradient") }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- stars
                        NbCap { pal: root.pal; text: "MOVING STARS" }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.fillWidth: true; text: "Moving stars on the desktop"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                            Toggle { pal: root.pal; on: root.starsOn; onToggled: root.put("deskStars", !root.starsOn) }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "They float above the wallpaper, or above the plain background when the wallpaper is off. They stand still (and cost nothing) in Gaming mode."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.starsOn
                            spacing: 10
                            NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Amount"; from: 10; to: 250; unit: ""; value: Math.round(root.num("deskStarCount", 70)); onPicked: v => root.put("deskStarCount", v) }
                            NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Speed"; from: 10; to: 400; unit: " %"; value: Math.round(root.num("deskStarSpeed", 1) * 100); onPicked: v => root.put("deskStarSpeed", v / 100) }
                            NbSlider { Layout.fillWidth: true; pal: root.pal; label: "Size"; from: 50; to: 300; unit: " %"; value: Math.round(root.num("deskStarSize", 1) * 100); onPicked: v => root.put("deskStarSize", v / 100) }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: "Direction"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 128 }
                                Repeater {
                                    model: [["right", "Right"], ["left", "Left"], ["up", "Up"], ["down", "Down"], ["diag", "Diagonal"]]
                                    delegate: Chip { required property var modelData; pal: root.pal; implicitHeight: 30; label: modelData[1]; on: ((root.opt && root.opt.deskStarDir) || "right") === modelData[0]; onClicked: root.put("deskStarDir", modelData[0]) }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: "Colour"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 128 }
                                Repeater {
                                    model: [["mix", "Mixed"], ["accent", "Accent"], ["white", "White"]]
                                    delegate: Chip { required property var modelData; pal: root.pal; implicitHeight: 30; label: modelData[1]; on: ((root.opt && root.opt.deskStarTone) || "mix") === modelData[0]; onClicked: root.put("deskStarTone", modelData[0]) }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Twinkle"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: !(root.opt && root.opt.deskStarTwinkle === false); onToggled: root.put("deskStarTwinkle", (root.opt && root.opt.deskStarTwinkle === false)) }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text { Layout.fillWidth: true; text: "Now and then a shooting star"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                Toggle { pal: root.pal; on: root.opt && root.opt.deskStarShoot === true; onToggled: root.put("deskStarShoot", !(root.opt && root.opt.deskStarShoot === true)) }
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: root.pal.lineSoft }

                        // ---- where the boxes open
                        NbCap { pal: root.pal; text: "WHERE THE BOXES OPEN" }
                        Text {
                            Layout.fillWidth: true
                            text: "Each box opens from the corner you pick (hover it or click it, as set in Edge boxes). The top-right corner stays with the notifications."
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 10; lineHeight: 1.25; wrapMode: Text.WordWrap
                        }
                        Repeater {
                            model: DS.order
                            delegate: RowLayout {
                                id: boxRow
                                required property string modelData
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: DS.names[boxRow.modelData]; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 128; elide: Text.ElideRight }
                                Repeater {
                                    model: DS.corners
                                    delegate: Chip {
                                        required property string modelData
                                        pal: root.pal; implicitHeight: 30
                                        label: DS.cornerNames[modelData]
                                        on: root.spots[boxRow.modelData] === modelData
                                        onClicked: root.moveBox(boxRow.modelData, modelData)
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text { text: "Notifications"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; Layout.preferredWidth: 128 }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Right edge"; on: !(root.opt && root.opt.notifSpot === "corner"); onClicked: root.put("notifSpot", "edge") }
                            Chip { pal: root.pal; implicitHeight: 30; label: "Top-right corner"; on: root.opt && root.opt.notifSpot === "corner"; onClicked: root.put("notifSpot", "corner") }
                        }
                    }
                }
            }
        }
    }
}
