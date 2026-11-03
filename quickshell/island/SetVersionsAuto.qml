import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "versionsAuto": the optional daily look at GitHub for the Version Center (a systemd user timer, off by default).
// It only reads which versions are newest and remembers what is behind; it never installs anything. `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: va
    width: parent ? parent.width : 0
    spacing: 10
    property bool isOn: false
    property bool busy: false
    property string msg: ""
    property bool bad: false
    property int behind: 0
    readonly property string helper: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-versions.py"

    function parse(t) { try { return JSON.parse(t) } catch (e) { return null } }
    function reload() { if (!stat.running) { stat.command = ["python3", helper, "autocheck", "status"]; stat.running = true } }
    function set(on) {
        if (busy) return
        busy = true; msg = ""; bad = false
        sw.command = ["python3", helper, "autocheck", on ? "on" : "off"]
        sw.running = true
    }
    Component.onCompleted: reload()
    Process {
        id: stat
        stdout: StdioCollector {
            onStreamFinished: {
                var o = va.parse(text)
                if (!o) return
                va.isOn = !!o.enabled
                var n = 0
                if (o.available && o.available.behind) for (var k in o.available.behind) n++
                va.behind = n
            }
        }
    }
    Process {
        id: sw
        stdout: StdioCollector {
            onStreamFinished: {
                var o = va.parse(text)
                va.busy = false
                if (o && o.ok) { va.isOn = !!o.enabled; va.msg = va.isOn ? "On: it looks once a day." : "Off." }
                else { va.bad = true; va.msg = (o && o.error) ? o.error : "The timer could not be changed." }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text { text: "Look for new versions once a day"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
            Text {
                Layout.fillWidth: true
                text: "A systemd user timer asks GitHub at most once a day which versions of Halcyon, LUNA, ai-antivirus and ai-firewall are newest, and shows a dot on the Version Center when something is behind. It never installs anything. Off by default; nothing runs in the background while it is off."
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; lineHeight: 1.3; wrapMode: Text.WordWrap
            }
        }
        Toggle {
            Layout.alignment: Qt.AlignTop
            pal: root.pal
            on: va.isOn
            busy: va.busy
            onToggled: va.set(!va.isOn)
        }
    }
    Text {
        Layout.fillWidth: true
        visible: va.isOn && va.behind > 0
        text: va.behind + (va.behind === 1 ? " component is behind main." : " components are behind main.") + " Open the Version Center to see which."
        color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap
    }
    Text {
        Layout.fillWidth: true
        visible: va.msg !== ""
        text: va.msg
        color: va.bad ? root.pal.bad : root.pal.good
        font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap
    }
}
