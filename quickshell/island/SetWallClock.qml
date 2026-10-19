import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "wallClock" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: wc
    width: parent ? parent.width : 0
    readonly property int since: Number(root.tl.wallSince !== undefined ? root.tl.wallSince : -1)
    readonly property int every: Number(root.opt.wpEvery || 0)
    DayTimeline {
        Layout.fillWidth: true
        pal: root.pal
        heading: "Wallpaper"
        plain: true
        since: wc.since
        span: wc.since > 90 ? 365 : wc.since > 30 ? 90 : wc.since > 14 ? 30 : 14
        neverText: "No change on record yet"
        lastText: wc.since < 0 ? "" : "Changed: " + String(root.tl.wallAgo || "")
        nextText: wc.every > 0 ? "Changes by itself every " + wc.every + " min" : "Changes when you pick one"
        status: String(root.tl.wallSource || "") === "file" ? "Approximate" : ""
        detail: wc.since < 0
            ? "The date shows up after the next wallpaper change."
            : "Last change: " + String(root.tl.wallAt || "") + "."
              + (String(root.tl.wallSource || "") === "file" ? "  Taken from the date of the wallpaper file until the next change is recorded." : "")
    }
}
