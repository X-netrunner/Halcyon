import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "focusClock" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: fc
    width: parent ? parent.width : 0
    readonly property bool tracked: root.tl.focusTracked === true
    readonly property int st: Number(root.tl.focusStreak || 0)
    readonly property int best: Math.max(st, Number(root.tl.focusBest || 0))
    readonly property int goal: Number(root.tl.focusGoal || 25)
    readonly property int todayMin: Number(root.tl.focusToday || 0)
    function plural(n) { return n + (n === 1 ? " day" : " days") }
    DayTimeline {
        Layout.fillWidth: true
        pal: root.pal
        heading: "Focus streak"
        plain: true
        since: fc.tracked ? fc.st : -1
        next: !fc.tracked ? -1 : (fc.best > fc.st ? fc.best - fc.st : (fc.st > 0 ? 0 : -1))
        span: Math.max(7, fc.best)
        neverText: "No focus sessions yet"
        todayText: fc.st > 0 ? "Day " + fc.st : "Today"
        lastText: !fc.tracked ? "" : (fc.st === 0 ? "No streak right now" : "Streak: " + fc.plural(fc.st))
        nextText: !fc.tracked ? "Start a Focus session to begin"
            : fc.best > fc.st ? "Best: " + fc.plural(fc.best) + "  \u00b7  " + (fc.best - fc.st) + " to go"
            : fc.st > 0 ? "This is your best" : "Reach " + fc.goal + " min in one day"
        status: !fc.tracked ? "" : (fc.st > 0 && fc.st >= fc.best ? "Your best" : (fc.st > 0 ? "On a streak" : "No streak"))
        detail: "A day counts from " + fc.goal + " minutes of focus (Widget builder > Focus timer & streak > Minutes that count as a focus day)."
            + (fc.tracked ? "  Today: " + fc.todayMin + " min." : "")
            + (fc.tracked && fc.st > 0 && fc.todayMin < fc.goal ? "  Focus " + (fc.goal - fc.todayMin) + " more min today to keep the streak going." : "")
    }
}
