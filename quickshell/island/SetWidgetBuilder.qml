import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "WidgetData.js" as WD

// Settings custom leaf "widgetBuilder" (moved out of Settings.qml). `root` is the Settings scope.
// The page has a Desktop / Lock screen switch; `t` below is the one it is on, and each button works on that screen's list of widgets.
WidgetBuilder {
    property var root                  // the Settings scope (it hands itself in)
    pal: root.pal
    opt: root.opt
    onOpenRequested: t => root.openWidgetBuilder("", t)
    onPlaceRequested: t => root.editOnDesktop(t)
    onClearRequested: t => root.setting("opt:" + WD.keyOf(t), null)
}
