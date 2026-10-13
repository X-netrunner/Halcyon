import QtQuick

// The two small controls on an event row: "Task" flags the event as a task (it is then nagged and can start Focus mode, when
// those are switched on in Settings > Calendar) and the round check marks a task as done. Done is stored on this computer only.
Row {
    id: m
    property var pal
    property var cal                 // the Calendar scope
    property var ev                  // the event
    readonly property bool task: cal.isTask(ev)
    readonly property bool done: cal.isDone(ev)
    spacing: 6
    layoutDirection: Qt.RightToLeft

    Rectangle {
        id: chk
        visible: m.task
        width: 26; height: 26; radius: 13
        color: m.done ? m.pal.accent : (ca.containsMouse ? Qt.alpha(m.pal.surfaceHi, 0.95) : "transparent")
        border.width: 1.5; border.color: m.done ? m.pal.accent : Qt.alpha(m.pal.text, 0.45)
        Behavior on color { ColorAnimation { duration: m.pal.dFast } }
        Text {
            anchors.centerIn: parent; text: "✓"; visible: m.done || ca.containsMouse
            color: m.done ? m.pal.bg : Qt.alpha(m.pal.text, 0.6)
            font.family: m.pal.uiFont; font.pixelSize: 14; font.weight: Font.Bold
        }
        MouseArea { id: ca; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: m.cal.setDone(m.ev, !m.done) }
    }
    Rectangle {
        visible: !m.cal.tasksAll
        height: 26; width: tl.implicitWidth + 18; radius: 13
        color: m.task ? Qt.alpha(m.pal.accent, 0.20) : (ta.containsMouse ? Qt.alpha(m.pal.surfaceHi, 0.95) : "transparent")
        border.width: 1; border.color: m.task ? m.pal.accent : m.pal.line
        Behavior on color { ColorAnimation { duration: m.pal.dFast } }
        Text {
            id: tl; anchors.centerIn: parent; text: "Task"
            color: m.task ? m.pal.accent : m.pal.muted
            font.family: m.pal.uiFont; font.pixelSize: m.pal.tCap
        }
        MouseArea { id: ta; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: m.cal.setTask(m.ev, !m.task) }
    }
}
