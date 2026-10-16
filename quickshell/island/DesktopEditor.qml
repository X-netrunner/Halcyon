import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "WidgetData.js" as WD

// Place your widgets right on the desktop (halcyon desktop-edit, or "Place them on the desktop" in the builders).
// The screen dims a little and every widget gets a handle: drag = move (it snaps to the middle and the edges), the dot in the corner
// or the mouse wheel = resize, a click picks it, "Style and look" opens it in the Widget builder, ✕ takes it away. "Add" puts a new one on.
// Esc or Done leaves. Everything is saved as you go.
PanelWindow {
    id: win
    property var pal
    property var env
    property var opt: ({})
    property bool open: false
    property real topInset: 24
    signal commit(var data)
    signal done()
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
    readonly property var layout: WD.normalize(opt ? opt.deskWidgets : null)

    Item {
        id: fade
        anchors.fill: parent
        opacity: win.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: win.pal.dMed; easing.type: Easing.InOutSine } }
        focus: win.open
        Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { if (win.adding) win.adding = false; else win.done(); e.accepted = true } }

        Rectangle { anchors.fill: parent; color: Qt.alpha(win.pal.bg, 0.38) }
        MouseArea { anchors.fill: parent; onClicked: { win.sel = ""; win.adding = false } }

        DeskWidgets {
            anchors.fill: parent
            pal: win.pal
            env: win.env
            opt: win.opt
            editing: true
            selected: win.sel
            topInset: win.topInset
            onSelectedRequested: uid => { win.sel = uid; win.adding = false }
            onCommit: d => win.commit(d)
            onOpenRequested: uid => win.openWidget(uid)
        }

        // the "add" shelf
        Glass {
            visible: win.adding
            pal: win.pal
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: bar.top; anchors.bottomMargin: 12
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
                    Repeater {
                        model: WD.cats
                        delegate: Column {
                            required property var modelData
                            width: shelf.width
                            spacing: 6
                            NbCap { pal: win.pal; text: modelData[1].toUpperCase() }
                            Flow {
                                width: parent.width
                                spacing: 8
                                Repeater {
                                    model: WD.catalog.filter(function (t) { return t.cat === modelData[0] })
                                    delegate: Chip {
                                        required property var modelData
                                        pal: win.pal; implicitHeight: 32
                                        glyph: String.fromCodePoint(modelData.icon); label: modelData.name
                                        onClicked: { var uid = WD.nextUid(win.layout.items); win.commit(WD.add(win.layout, modelData.id)); win.sel = uid; win.adding = false }
                                    }
                                }
                            }
                        }
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
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 1
                    Text { text: "Place your widgets"; color: win.pal.text; font.family: win.pal.uiFont; font.pixelSize: 13; font.weight: Font.DemiBold }
                    Text { text: "Drag to move  ·  corner dot or wheel to resize  ·  double-click = style"; color: win.pal.muted; font.family: win.pal.uiFont; font.pixelSize: 10 }
                }
                ActionChip { pal: win.pal; label: win.adding ? "Close" : "Add a widget"; on: !win.adding; onClicked: win.adding = !win.adding }
                ActionChip { pal: win.pal; label: "Widget builder"; onClicked: win.openWidget(win.sel) }
                ActionChip { pal: win.pal; label: "Done"; on: true; onClicked: win.done() }
            }
        }
    }
}
