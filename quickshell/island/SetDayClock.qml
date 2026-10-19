import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "dayClock" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: dc
    width: parent ? parent.width : 0
    spacing: 22
    readonly property bool safetyInstalled: root.startup.has && root.startup.has.safety === true
    readonly property int bSince: Number(root.remind.backupSince !== undefined ? root.remind.backupSince : -1)
    readonly property int bNext: Number(root.remind.backupNext !== undefined ? root.remind.backupNext : -1)
    readonly property int bSpan: Math.max(1, Number(root.remind.backupSpan || 7))
    readonly property int sSince: Number(root.remind.safetySince !== undefined ? root.remind.safetySince : -1)
    readonly property int sNext: Number(root.remind.safetyNext !== undefined ? root.remind.safetyNext : -1)
    readonly property string sKind: String(root.remind.safetyNextKind || "none")
    readonly property int sSpan: sKind === "auto" ? Math.max(1, Number(root.remind.auto.days || 30))
        : (root.remind.SAFETY_EVERY === "custom" ? Number(root.remind.SAFETY_DAYS || 14) : Number(root.remind.SAFETY_EVERY || 30))
    function plural(n) { return n + (n === 1 ? " day" : " days") }
    readonly property int uSince: Number(root.tl.updSince !== undefined ? root.tl.updSince : -1)
    readonly property int hSince: Number(root.tl.halSince !== undefined ? root.tl.halSince : -1)
    readonly property string halcyonNote: hSince < 0 ? "" : "  Halcyon itself was last installed or updated " + String(root.tl.halAgo || "") + "."

    DayTimeline {
        Layout.fillWidth: true
        pal: root.pal
        heading: "Backup"
        since: dc.bSince
        next: dc.bNext
        span: dc.bSpan
        status: root.remind.BACKUP_REMIND ? (dc.bNext === 0 ? "Due now" : "Reminder on") : "No reminder"
        detail: root.remind.BACKUP_REMIND
            ? "Last backup made here: " + root.remind.backupAgo + ".  Next reminder: " + (dc.bNext === 0 ? "today." : "in " + dc.plural(dc.bNext) + ".")
            : "Last backup made here: " + root.remind.backupAgo + ".  Switch on \"Remind me to back up\" above to get a countdown."
    }
    DayTimeline {
        Layout.fillWidth: true
        opacity: dc.safetyInstalled ? 1 : 0.45
        pal: root.pal
        heading: "Safety check"
        since: dc.sSince
        next: dc.sNext
        span: dc.sSpan
        active: !!root.remind.safetyRunning
        status: !dc.safetyInstalled ? "Not installed"
            : root.remind.safetyRunning ? "Scanning now"
            : dc.sKind === "auto" ? "Automatic"
            : dc.sKind === "reminder" ? "Reminder on"
            : "Not scheduled"
        detail: !dc.safetyInstalled ? "Install it with ./install.sh --safety-check."
            : "Last scan: " + root.remind.safetyAgo + "."
              + (dc.sKind === "auto" ? (dc.sNext === 0 ? "  Next: due now, it starts at the next look (every 6 hours, on AC power)." : "  Next: in " + dc.plural(dc.sNext) + ".")
                 : dc.sKind === "reminder" ? "  Next reminder: " + (dc.sNext === 0 ? "today." : "in " + dc.plural(dc.sNext) + ".")
                 : "  Switch on the automatic scan below to get a countdown.")
    }
    // the system update: when pacman last really replaced a package (scripts/timeline.py reads /var/log/pacman.log). Nothing is
    // scheduled and nothing is run from here; it only shows the date, and turns amber after 60 days.
    DayTimeline {
        Layout.fillWidth: true
        pal: root.pal
        heading: "System update"
        plain: true
        warnAfter: 60
        since: dc.uSince
        span: dc.uSince > 90 ? 365 : dc.uSince > 30 ? 90 : 30
        neverText: "No update on record"
        lastText: dc.uSince < 0 ? "" : "Updated: " + String(root.tl.updAgo || "")
        nextText: "You start updates yourself"
        status: dc.uSince < 0 ? "Unknown" : (dc.uSince > 60 ? "Long ago" : "")
        detail: dc.uSince < 0
            ? "There is no readable pacman log here, so no date can be shown (this needs Arch's /var/log/pacman.log)." + dc.halcyonNote
            : "Last package upgrade: " + String(root.tl.updAt || "") + ", read from /var/log/pacman.log." + dc.halcyonNote
    }
}
