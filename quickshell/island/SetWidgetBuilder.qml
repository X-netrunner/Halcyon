import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "widgetBuilder" (moved out of Settings.qml). `root` is the Settings scope.
WidgetBuilder {
    property var root                  // the Settings scope (it hands itself in)
    pal: root.pal
    opt: root.opt
    onOpenRequested: root.openWidgetBuilder("")
    onPlaceRequested: root.editOnDesktop()
    onClearRequested: root.setting("opt:deskWidgets", null)
}
