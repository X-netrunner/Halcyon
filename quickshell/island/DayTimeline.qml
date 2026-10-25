import QtQuick
import QtQuick.Layouts

// A timeline for "how long since the last time" and "how long until the next one" (Settings > Backup and Security).
//   last  o==========@----|----|----|----o  due
//                    today
// The rail is the whole interval. The filled part is the time that has passed, the marker is today, the ring on the right is
// the day it is due. One tick per day for short intervals, quarter marks for long ones. Everything is driven by three numbers:
//   since  whole days since the last time (-1 = never)      next  whole days until it is due (0 = due now, -1 = nothing planned)
//   span   the interval in days (used when `next` is not known, so the rail still has a length)
// Plain mode (plain: true) is for things that have no due date (last wallpaper change, last system update, the Focus streak):
// nothing is ever "late" (amber only after warnAfter days, if you set it), the end ring is a goal, not a deadline, and the
// words on the rail can be replaced (lastText, nextText, todayText, neverText). Without `plain` it looks and works as before.
Item {
    id: root
    property var pal
    property string heading: ""
    property string status: ""            // the pill on the right: "Reminder", "Automatic", "Scanning now" ...
    property string detail: ""            // a muted line under the rail
    property int since: -1
    property int next: -1
    property int span: 30
    property bool active: false           // something is running right now (the marker pulses, green)
    property bool plain: false            // no due date: never "late", the end ring is a goal (see the note above)
    property int warnAfter: 0             // plain mode: turn amber once `since` is more than this many days (0 = never)
    property string lastText: ""          // replaces "Last: 3 days ago"
    property string nextText: ""          // replaces "Due in 4 days" / "Nothing scheduled"
    property string todayText: ""         // replaces the marker label ("Today  ·  day 3")
    property string neverText: "Never run"

    readonly property bool never: since < 0
    readonly property bool scheduled: next >= 0
    readonly property bool due: scheduled && next === 0
    readonly property real total: (since >= 0 && scheduled) ? Math.max(1, since + next) : Math.max(1, span)
    readonly property real frac: never ? 0 : (due ? 1 : Math.min(1, since / total))
    readonly property bool reached: plain && scheduled && next === 0        // plain mode: the end ring is reached (a goal met)
    readonly property bool late: plain ? (warnAfter > 0 && !never && since > warnAfter) : (due || (!scheduled && !never && since > span))
    readonly property color tone: active ? pal.good : ((plain ? late : (late || (scheduled && frac > 0.85))) ? pal.warn : pal.accent)
    readonly property int ticks: total <= 14 ? Math.round(total) : 4

    function days(n) { return n + (n === 1 ? " day" : " days") }

    property real shown: frac
    Behavior on shown { enabled: root.visible; NumberAnimation { duration: 700; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

    implicitHeight: col.implicitHeight
    implicitWidth: 360

    ColumnLayout {
        id: col
        width: parent.width
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: root.heading
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
                font.weight: Font.Medium
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                implicitWidth: pill.implicitWidth + 18
                implicitHeight: 22
                radius: 11
                color: Qt.alpha(root.tone, 0.14)
                border.width: 1
                border.color: Qt.alpha(root.tone, 0.45)
                visible: root.status !== ""
                Text {
                    id: pill
                    anchors.centerIn: parent
                    text: root.status
                    color: root.tone
                    font.family: root.pal.uiFont
                    font.pixelSize: 10
                    font.weight: Font.Medium
                    font.letterSpacing: 0.4
                }
            }
        }

        // ---- the rail
        Item {
            id: track
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            readonly property real x0: 9
            readonly property real railW: Math.max(10, width - 18)
            readonly property real cy: 30

            // marker label ("Today"), kept inside the track
            Text {
                id: todayLbl
                visible: !root.never
                text: root.todayText !== "" ? root.todayText : (root.since === 0 ? "Today" : "Today  \u00b7  day " + root.since)
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: 9
                font.letterSpacing: 0.5
                y: 0
                x: Math.max(0, Math.min(track.width - width, track.x0 + track.railW * root.shown - width / 2))
            }

            Rectangle {      // the whole interval
                x: track.x0; y: track.cy - 2
                width: track.railW; height: 4; radius: 2
                color: root.pal.surface
            }
            Rectangle {      // the part that has passed
                x: track.x0; y: track.cy - 2
                width: Math.max(0, track.railW * root.shown); height: 4; radius: 2
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.alpha(root.tone, 0.55) }
                    GradientStop { position: 1.0; color: root.tone }
                }
            }
            Repeater {       // day marks
                model: Math.max(0, root.ticks - 1)
                delegate: Rectangle {
                    required property int index
                    readonly property real at: (index + 1) / root.ticks
                    x: track.x0 + track.railW * at - 0.5
                    y: track.cy - 5
                    width: 1; height: 10
                    color: at <= root.shown ? Qt.alpha(root.tone, 0.55) : Qt.alpha(root.pal.text, 0.16)
                }
            }

            Rectangle {      // the last time: filled when it happened, an empty ring when it never did
                x: track.x0 - width / 2; y: track.cy - height / 2
                width: 11; height: 11; radius: 6
                color: root.never ? "transparent" : root.tone
                border.width: 2
                border.color: root.never ? root.pal.muted : root.tone
            }
            Rectangle {      // the day it is due
                x: track.x0 + track.railW - width / 2; y: track.cy - height / 2
                width: 15; height: 15; radius: 8
                color: root.reached ? root.tone : (root.due && !root.plain ? root.pal.warn : root.pal.bg)
                border.width: 2
                border.color: root.reached ? root.tone : (root.scheduled ? (root.due ? root.pal.warn : Qt.alpha(root.pal.text, 0.5)) : Qt.alpha(root.pal.text, 0.2))
                Rectangle {
                    anchors.centerIn: parent
                    width: 5; height: 5; radius: 3
                    visible: root.scheduled && !root.due && !root.reached
                    color: Qt.alpha(root.pal.text, 0.5)
                }
            }

            Item {           // today
                id: today
                visible: !root.never
                x: track.x0 + track.railW * root.shown - 10
                y: track.cy - 10
                width: 20; height: 20
                Rectangle {
                    id: halo
                    anchors.centerIn: parent
                    width: 20; height: 20; radius: 10
                    color: Qt.alpha(root.tone, 0.28)
                    SequentialAnimation on scale {
                        running: root.visible && (root.active || (root.due && !root.plain)) && root.pal.motion > 0.3
                        loops: Animation.Infinite
                        NumberAnimation { to: 1.45; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 10; height: 10; radius: 5
                    color: root.pal.text
                    border.width: 2
                    border.color: root.tone
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: root.lastText !== "" ? root.lastText : (root.never ? root.neverText : (root.since === 0 ? "Last: today" : "Last: " + root.days(root.since) + " ago"))
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
            Item { Layout.fillWidth: true }
            Text {
                text: root.nextText !== "" ? root.nextText : (root.scheduled ? (root.due ? "Due now" : "Due in " + root.days(root.next)) : "Nothing scheduled")
                color: (root.due && !root.plain) ? root.pal.warn : root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
                font.weight: (root.due && !root.plain) ? Font.Medium : Font.Normal
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.detail !== ""
            text: root.detail
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 11
            lineHeight: 1.3
            wrapMode: Text.WordWrap
        }
    }
}
