import QtQuick
import Quickshell
import Quickshell.Io

// "Daily brief": your day in a few lines (scripts/halcyon-ai.py brief): what is overdue and due today, the open tasks and the Focus
// streak. The local AI words it when it is on; otherwise it is written plainly from the same facts. The script keeps the answer for
// the day (it asks again after 3 hours, or when your notes change), so reading it every 10 minutes costs a python start, not a model run.
// A click asks again now (--refresh).
//   card | line
WBase {
    id: root

    readonly property bool showFacts: opt("facts", true) === true
    readonly property real wide: opt("width", 300)
    property var d: ({})
    property bool fresh: false               // the next read is a click: ask the model again
    readonly property var tasks: d.tasks || ({})
    readonly property var foc: d.focus || ({})
    readonly property string facts: {
        var p = []
        if (tasks.overdue && tasks.overdue.length) p.push(tasks.overdue.length + " overdue")
        if (tasks.today && tasks.today.length) p.push(tasks.today.length + " due today")
        if (tasks.open) p.push(tasks.open + (tasks.open === 1 ? " open task" : " open tasks"))
        if (foc.tracked) p.push(foc.streak > 0 ? foc.streak + " day streak" : "no streak")
        return p.join("  ·  ")
    }

    function read(force) {
        if (briefProc.running) return
        briefProc.command = ["python3", Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-ai.py", "brief", "--json"].concat(force ? ["--refresh"] : [])
        briefProc.running = true
    }
    Timer { interval: 600000; repeat: true; running: root.live; triggeredOnStart: true; onTriggered: root.read(false) }
    Process {
        id: briefProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { var x = JSON.parse(text); if (x && x.ok) root.d = x } catch (e) { /* keep what is shown */ }
            }
        }
    }

    implicitWidth: root.style === "line" ? lineRow.implicitWidth : wide - 28
    implicitHeight: root.style === "line" ? lineRow.implicitHeight : col.implicitHeight

    // card: the greeting, the brief, the facts
    Column {
        id: col
        visible: root.style !== "line"
        width: parent.width
        spacing: root.sz(8)
        Row {
            spacing: root.sz(8)
            WIco { b: root; text: root.glyph(0xF0674); color: root.accent; font.pixelSize: root.sz(14); anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; text: root.d.greeting || "Your day"; font.pixelSize: root.sz(13); font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; visible: briefProc.running; text: "…"; color: root.dim; font.pixelSize: root.sz(12); anchors.verticalCenter: parent.verticalCenter }
        }
        WLbl {
            b: root
            width: col.width
            text: root.d.text || (briefProc.running ? "Putting your day together…" : "Nothing to show yet.")
            wrapMode: Text.Wrap
            font.pixelSize: root.sz(13)
            lineHeight: 1.25
        }
        WLbl { b: root; visible: root.showFacts && root.facts !== ""; width: col.width; text: root.facts; color: root.dim; font.pixelSize: root.sz(11); elide: Text.ElideRight }
    }
    // one line: the brief only
    Row {
        id: lineRow
        visible: root.style === "line"
        spacing: root.sz(8)
        WIco { b: root; text: root.glyph(0xF0674); color: root.accent; font.pixelSize: root.sz(15); anchors.verticalCenter: parent.verticalCenter }
        WLbl {
            b: root
            width: Math.min(implicitWidth, root.wide)
            text: root.d.text || "…"
            elide: Text.ElideRight
            font.pixelSize: root.sz(13)
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: !root.editing && !!root.env
        cursorShape: Qt.PointingHandCursor
        onClicked: root.read(true)
    }
}
