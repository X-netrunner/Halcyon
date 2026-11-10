import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "DeskSpots.js" as DS

// Settings custom leaf "desktopBuilder" (moved out of Settings.qml). `root` is the Settings scope.
DesktopBuilder {
    property var root                  // the Settings scope (it hands itself in)
    pal: root.pal
    opt: root.opt
    onOpenRequested: t => root.openDesktopBuilder(t)
    onResetRequested: {
        for (var k in DS.resetValues) root.setting("opt:" + k, DS.resetValues[k])      // the same list the builder window resets
        root.setting("opt:boxSpots", null)
        root.setting("opt:boxZone", null)
    }
}
