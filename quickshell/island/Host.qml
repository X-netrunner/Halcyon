import QtQuick
import Quickshell
import Quickshell.Wayland

// The window a centre (Luna, Study, Games ...) draws itself in. One of two things, by Settings > Workspaces & windows > Windows:
//   overlay  a full-screen layer-shell surface above everything (the default; the centre draws its own dimmed backdrop)
//   desktop  an ordinary window: it sits on the workspace next to your other apps and follows the tiling (or floating) rules
// The centre puts its content inside and does not care which one it got. Content is parented to whichever window is showing,
// so a change of mode only needs the window to be opened again.
//   desktop     true = the ordinary window       title     the window's title in desktop mode (rules and the taskbar see it)
//   namespace / layer / keyboardFocus   what the old PanelWindow lines said (overlay only)
//   closeRequested()   the compositor closed the desktop window (the centre should run its own hide())
Scope {
    id: h
    property bool desktop: false
    property string namespace: ""
    property string title: ""
    property var layer: WlrLayer.Overlay
    property var keyboardFocus: WlrKeyboardFocus.None
    property color color: "transparent"
    property int deskWidth: 1100
    property int deskHeight: 740
    signal closeRequested()
    default property alias content: stage.data

    Item {
        id: stage
        parent: h.desktop ? fw.contentItem : pw.contentItem
        anchors.fill: parent
    }

    PanelWindow {
        id: pw
        visible: !h.desktop
        anchors { top: true; bottom: true; left: true; right: true }
        color: h.color
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: h.namespace
        WlrLayershell.layer: h.layer
        WlrLayershell.keyboardFocus: h.desktop ? WlrKeyboardFocus.None : h.keyboardFocus
    }

    FloatingWindow {
        id: fw
        visible: h.desktop
        title: h.title
        color: h.color
        implicitWidth: h.deskWidth
        implicitHeight: h.deskHeight
        onVisibleChanged: if (!visible && h.desktop) h.closeRequested()
    }
}
