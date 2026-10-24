import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "WidgetData.js" as WD

// Place your widgets right on the desktop (halcyon desktop-edit, or "Place them on the desktop" in the builders).
// The screen dims a little and every widget gets a handle: drag = move (it snaps to the middle and the edges), the dot in the corner
// or the mouse wheel = resize, a click picks it, "Style and look" opens it in the Widget builder, ✕ takes it away. "Add" puts a new one on.
// Esc or Done leaves. Everything is saved as you go.
// The switch in the toolbar picks WHICH screen you place them on: the desktop, or the lock screen (its own list of widgets, opt.lockDeskWidgets). On the
// lock screen the clock and the password box are drawn as outlines, so you leave room for them; every widget is offered (the private ones are marked).
// The "view bar" above the toolbar draws helpers like a design tool: a grid (size 20 / 40 / 80 / 120 px, optionally snapping to it), the
// screen's centre lines (they light up when the picked widget is centred), rule-of-thirds lines, the safe area, and the measuring: the gap
// in px to the screen edge or the next widget on every side of the picked widget, plus its size and place. Your choices are remembered.
PanelWindow {
    id: win
    property var pal
    property var env
    property var opt: ({})
    property bool open: false
    property real topInset: 24
    property string target: "desktop"          // "desktop" or "lock": which list you are placing (shell.qml deskEditTarget)
    readonly property bool lockT: target === "lock"
    signal commit(var data)
    signal done()
    signal targetPicked(string t)
    signal optToggled(string key, var value)       // a helper switch (grid, centre ...) changed: shell.qml saves it
    signal openWidget(string uid)

    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "island-desktopedit"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: win.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    property bool adding: false
    property string sel: ""
    readonly property var layout: WD.normalizeFor(opt ? opt[WD.keyOf(target)] : null, target)
    // the helpers (saved as opt.deskGrid ...); the defaults show the grid, the centre and the measuring
    function flag(k, d) { return opt && opt[k] !== undefined ? opt[k] === true : d }
    readonly property bool gridOn: flag("deskGrid", true)
    readonly property int gridPx: opt && opt.deskGridSize ? Number(opt.deskGridSize) : 40
    readonly property bool snapOn: flag("deskGridSnap", false)
    readonly property bool centreOn: flag("deskCenter", true)
    readonly property bool thirdsOn: flag("deskThirds", false)
    readonly property bool safeOn: flag("deskSafe", true)
    readonly property bool measureOn: flag("deskMeasure", true)
    // the how-to card: hidden unless you ask for it (the ? in the toolbar, or H); it sits in the bottom-right corner, out of the way
    property bool helpOpen: false

    Item {
        id: fade
        anchors.fill: parent
        opacity: win.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.InOutSine } }
        focus: win.open
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Escape) { if (win.helpOpen) win.helpOpen = false; else if (win.adding) win.adding = false; else win.done(); e.accepted = true }
            else if (e.key === Qt.Key_H || e.key === Qt.Key_F1 || e.key === Qt.Key_Question) { win.helpOpen = !win.helpOpen; e.accepted = true }
            else if (win.sel !== "" && e.key >= Qt.Key_Left && e.key <= Qt.Key_Down) {
                // arrow keys move the picked widget 1 px (Shift: 10 px)
                var st = (e.modifiers & Qt.ShiftModifier) ? 10 : 1
                dw.nudge(win.sel, e.key === Qt.Key_Left ? -st : (e.key === Qt.Key_Right ? st : 0), e.key === Qt.Key_Up ? -st : (e.key === Qt.Key_Down ? st : 0))
                e.accepted = true
            }
        }

        // (on the lock screen the real desktop widgets are hidden and the dim is heavier: you are placing widgets on a different screen)
        Rectangle { anchors.fill: parent; color: Qt.alpha(win.pal.bg, win.lockT ? 0.9 : 0.38) }
        MouseArea { anchors.fill: parent; onClicked: { win.sel = ""; win.adding = false } }

        // the lock screen's own furniture (Lock.qml: the clock and date at 16 % of the height, your picture and the password box from 52 %)
        Item {
            visible: win.lockT
            anchors.fill: parent
            Rectangle {
                x: (parent.width - width) / 2; y: parent.height * 0.16
                width: 360; height: 170; radius: 16
                color: "transparent"; border.width: 1; border.color: Qt.alpha(win.pal.text, 0.25)
                Text { anchors.centerIn: parent; text: "clock and date"; color: Qt.alpha(win.pal.text, 0.4); font.family: win.pal.uiFont; font.pixelSize: 12 }
            }
            Rectangle {
                x: (parent.width - width) / 2; y: parent.height * 0.52
                width: 340; height: 210; radius: 16
                color: "transparent"; border.width: 1; border.color: Qt.alpha(win.pal.text, 0.25)
                Text { anchors.centerIn: parent; text: "your picture and the password box"; color: Qt.alpha(win.pal.text, 0.4); font.family: win.pal.uiFont; font.pixelSize: 12 }
            }
        }

        DeskWidgets {
            id: dw
            anchors.fill: parent
            pal: win.pal
            env: win.env
            opt: win.opt
            target: win.target
            editing: true
            selected: win.sel
            topInset: win.topInset
            showGrid: win.gridOn; gridSize: win.gridPx; snapGrid: win.snapOn
            showCenter: win.centreOn; showThirds: win.thirdsOn; showSafe: win.safeOn; showMeasure: win.measureOn
            onSelectedRequested: uid => { win.sel = uid; win.adding = false }
            onCommit: d => win.commit(d)
            onOpenRequested: uid => win.openWidget(uid)
        }

        // the "add" shelf
        Glass {
            visible: win.adding
            pal: win.pal
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: viewBar.top; anchors.bottomMargin: 12
            width: Math.min(parent.width - 80, 760)
            height: Math.min(parent.height * 0.5, shelf.implicitHeight + 36)
            radius: win.pal.rXl
            opacityBody: win.pal.glassSolid - 0.02
            border.color: Qt.alpha(win.pal.accent, 0.35)
            MouseArea { anchors.fill: parent }
            Flickable {
                anchors.fill: parent; anchors.margins: 18
                contentWidth: width; contentHeight: shelf.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: shelf
                    width: parent.width
                    spacing: 12
                    Text {
                        visible: win.lockT
                        width: shelf.width
                        wrapMode: Text.WordWrap
                        text: "Every widget works here too, but nothing on them can be clicked or run while the screen is locked. Marked private (anyone at your locked computer can read them): " + WD.lockPrivateNames() + "."
                        color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: 10
                    }
                    Repeater {
                        model: WD.cats
                        delegate: Column {
                            id: shelfCat
                            required property var modelData
                            readonly property var kinds: WD.catalog.filter(function (t) { return t.cat === modelData[0] })
                            visible: kinds.length > 0
                            width: shelf.width
                            spacing: 6
                            NbCap { pal: win.pal; text: win.pal.cap(modelData[1]) }
                            Flow {
                                width: parent.width
                                spacing: 8
                                Repeater {
                                    model: shelfCat.kinds
                                    delegate: Chip {
                                        required property var modelData
                                        pal: win.pal; implicitHeight: 32
                                        glyph: String.fromCodePoint(modelData.icon); label: modelData.name + (win.lockT && WD.lockPrivateOf(modelData.id) !== "" ? "  · private" : "")
                                        onClicked: { var uid = WD.nextUid(win.layout.items); win.commit(WD.add(win.layout, modelData.id)); win.sel = uid; win.adding = false }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // the view bar: grid, centre, thirds, safe area, measuring
        Glass {
            id: viewBar
            pal: win.pal
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: bar.top; anchors.bottomMargin: 10
            width: Math.min(parent.width - 40, vb.implicitWidth + 28)
            height: 48
            radius: 24
            opacityBody: win.pal.glassSolid - 0.02
            border.color: Qt.alpha(win.pal.accent, 0.25)
            MouseArea { anchors.fill: parent }
            RowLayout {
                id: vb
                anchors.centerIn: parent
                spacing: 8
                Text { text: "View"; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: 11; font.letterSpacing: 1.5; Layout.rightMargin: 2 }
                Chip { pal: win.pal; implicitHeight: 30; label: "Grid"; on: win.gridOn; onClicked: win.optToggled("deskGrid", !win.gridOn) }
                Repeater {
                    model: win.gridOn ? WD.gridSizes : []
                    delegate: Chip {
                        required property var modelData
                        pal: win.pal; implicitHeight: 30; padX: 11; label: modelData[1]; on: win.gridPx === modelData[0]
                        onClicked: win.optToggled("deskGridSize", modelData[0])
                    }
                }
                Chip { visible: win.gridOn; pal: win.pal; implicitHeight: 30; label: "Snap to grid"; on: win.snapOn; onClicked: win.optToggled("deskGridSnap", !win.snapOn) }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: win.pal.lineSoft }
                Chip { pal: win.pal; implicitHeight: 30; label: "Centre"; on: win.centreOn; onClicked: win.optToggled("deskCenter", !win.centreOn) }
                Chip { pal: win.pal; implicitHeight: 30; label: "Thirds"; on: win.thirdsOn; onClicked: win.optToggled("deskThirds", !win.thirdsOn) }
                Chip { pal: win.pal; implicitHeight: 30; label: "Safe area"; on: win.safeOn; onClicked: win.optToggled("deskSafe", !win.safeOn) }
                Chip { pal: win.pal; implicitHeight: 30; label: "Measure"; on: win.measureOn; onClicked: win.optToggled("deskMeasure", !win.measureOn) }
            }
        }

        // the how-to card: a small popup in the bottom-right corner, only while you want it (? in the toolbar, H, or its own ✕)
        Glass {
            id: helpCard
            pal: win.pal
            visible: opacity > 0.01
            opacity: win.helpOpen ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: win.pal.dFast } }
            anchors.right: parent.right; anchors.rightMargin: 24
            anchors.bottom: parent.bottom; anchors.bottomMargin: 34
            width: 300
            height: helpCol.implicitHeight + 28
            radius: win.pal.rLg
            opacityBody: win.pal.glassSolid - 0.02
            border.color: Qt.alpha(win.pal.accent, 0.35)
            MouseArea { anchors.fill: parent }
            Column {
                id: helpCol
                x: 16; y: 14
                width: parent.width - 32
                spacing: 7
                Item {
                    width: parent.width; height: 20
                    Text { text: "How to place widgets"; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: 13; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        text: "✕"; color: hx.containsMouse ? win.pal.text : win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: 13
                        MouseArea { id: hx; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.helpOpen = false }
                    }
                }
                Repeater {
                    model: [
                        "Drag a widget to move it. It snaps to the others, the middle and the edges (hold Alt or Ctrl to move freely).",
                        "Arrow keys nudge it 1 px (Shift: 10 px).",
                        "The corner dot or the mouse wheel changes its size.",
                        "Linked widgets move and resize together: drag any of them. Set links in the Widget builder > Link.",
                        "Switch off hides a widget without deleting it.",
                        "H or ? shows / hides this card, Esc leaves."
                    ].concat(win.lockT ? ["Lock screen: the outlines are the clock and the password box, keep widgets off them. Widgets there only show things, nothing on them can be clicked while it is locked (the music buttons stay)."] : [])
                    delegate: Text {
                        required property string modelData
                        width: helpCol.width
                        text: "·  " + modelData
                        wrapMode: Text.WordWrap
                        color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: 11
                    }
                }
            }
        }

        // the toolbar
        Glass {
            id: bar
            pal: win.pal
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom; anchors.bottomMargin: 34
            width: tb.implicitWidth + 36
            height: 62
            radius: 31
            opacityBody: win.pal.glassSolid - 0.02
            border.color: Qt.alpha(win.pal.accent, 0.35)
            MouseArea { anchors.fill: parent }
            RowLayout {
                id: tb
                anchors.centerIn: parent
                spacing: 12
                Text { Layout.alignment: Qt.AlignVCenter; text: win.lockT ? "Place your lock screen widgets" : "Place your widgets"; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: 13; font.weight: Font.DemiBold }
                SegSwitch {
                    Layout.alignment: Qt.AlignVCenter
                    pal: win.pal
                    options: [{ k: "desktop", t: "Desktop" }, { k: "lock", t: "Lock screen" }]
                    current: win.target
                    onPicked: k => { win.sel = ""; win.adding = false; win.targetPicked(k) }
                }
                Rectangle {                                   // the ? that opens / closes the how-to card
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 26; Layout.preferredHeight: 26; radius: 13
                    color: win.helpOpen ? Qt.alpha(win.pal.accent, 0.22) : (hq.containsMouse ? Qt.alpha(win.pal.surfaceHi, 0.9) : Qt.alpha(win.pal.surface, 0.8))
                    border.width: 1; border.color: win.helpOpen ? win.pal.accent : win.pal.lineSoft
                    Text { anchors.centerIn: parent; text: "?"; color: win.helpOpen ? win.pal.accent : win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: 13; font.weight: Font.Bold }
                    MouseArea { id: hq; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.helpOpen = !win.helpOpen }
                }
                ActionChip { pal: win.pal; label: win.adding ? "Close" : "Add a widget"; primary: !win.adding; onClicked: win.adding = !win.adding }
                ActionChip { pal: win.pal; label: "Widget builder"; onClicked: win.openWidget(win.sel) }
                ActionChip { pal: win.pal; label: "Done"; primary: true; onClicked: win.done() }
            }
        }
    }
}
