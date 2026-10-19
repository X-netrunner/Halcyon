import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "notifBuilder" (moved out of Settings.qml). `root` is the Settings scope.
NotifBuilder {
    property var root                  // the Settings scope (it hands itself in)
    pal: root.pal
    layout: root.get("opt:notifLayout")
    onOpenRequested: root.nbOpen = true
    onResetRequested: root.setting("opt:notifLayout", null)
}
