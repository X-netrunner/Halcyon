import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "barBuilder" (moved out of Settings.qml). `root` is the Settings scope.
BarBuilder {
    property var root                  // the Settings scope (it hands itself in)
    pal: root.pal
    layout: root.get("opt:barLayout")
    barStyle: root.get("opt:barStyle") || "island"
    onOpenRequested: root.builderOpen = true
    onEdited: l => root.setting("opt:barLayout", l)
}
