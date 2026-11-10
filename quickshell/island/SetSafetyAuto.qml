import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings custom leaf "safetyAuto" (moved out of Settings.qml). `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: sa
    width: parent ? parent.width : 0
    spacing: 12
    readonly property bool installed: root.startup.has && root.startup.has.safety === true
    readonly property bool isOn: !!(root.remind.auto && root.remind.auto.on)
    property string every: isOn ? String(root.remind.auto.every) : "30"      // the schedule picked here
    property int days: isOn && root.remind.auto.days > 0 ? root.remind.auto.days : 14   // used when every = custom
    property string wanted: ""         // "on" (turn on / apply) | "off", while the password row is open
    property string msg: ""
    property bool bad: false
    property bool busy: false
    opacity: installed ? 1 : 0.45
    function effDays() { return every === "custom" ? days : Number(every) }
    function ask(what) { if (!installed || busy) return; wanted = what; msg = ""; bad = false; Qt.callLater(function () { pwIn.forceActiveFocus() }) }
    function go() {
        if (pwIn.text === "" || run.running || wanted === "") return
        busy = true; msg = ""; bad = false
        run.pw = pwIn.text
        pwIn.text = ""
        run.running = true
    }
    onEveryChanged: if (isOn && effDays() > 0 && effDays() !== root.remind.auto.days) ask("on")
    Process {
        id: run
        property string pw: ""
        property int code: 0
        // the result is handled when the exit AND both output streams are in (a fixed wait after the exit can be too short)
        property string soT: ""
        property string seT: ""
        property bool soDone: false
        property bool seDone: false
        property bool exitedOnce: false
        function finishCheck() { if (exitedOnce && soDone && seDone) { exitedOnce = false; fin.trigger() } }
        stdinEnabled: true
        command: ["sudo", "-k", "-S", "-p", "", "bash", root.autoScript].concat(sa.wanted === "off" ? ["off"] : ["on", String(sa.effDays()), Quickshell.env("USER")])
        stdout: StdioCollector { onStreamFinished: { run.soT = text; run.soDone = true; run.finishCheck() } }
        stderr: StdioCollector { onStreamFinished: { run.seT = text; run.seDone = true; run.finishCheck() } }
        onRunningChanged: { if (running) { soT = ""; seT = ""; soDone = false; seDone = false; exitedOnce = false } if (running && pw !== "") { write(pw + "\n"); pw = "" } }
        onExited: (c, st) => { code = c; exitedOnce = true; finishCheck() }
    }
    QtObject {           // runs once the process has ended and its output is complete (run.finishCheck)
        id: fin
        function trigger() {
            sa.busy = false
            var err = String(run.seT || "").trim()
            if (run.code === 0) {
                sa.wanted = ""
                sa.msg = String(run.soT || "").trim().split("\n").pop()
                sa.bad = false
            } else if (err.indexOf("incorrect password") >= 0 || err.indexOf("no password was provided") >= 0 || err.indexOf("Sorry, try again") >= 0 || err.indexOf("a password is required") >= 0) {
                sa.msg = "That password is not right. Try again."
                sa.bad = true
                Qt.callLater(function () { pwIn.forceActiveFocus() })
            } else {
                sa.msg = err.split("\n").pop() || ("It did not work (code " + run.code + ").")
                sa.bad = true
            }
            root.remindRefresh()
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text { text: "Run the safety check automatically"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
            Text {
                Layout.fillWidth: true
                text: !sa.installed ? "Not installed, so this is switched off. Add it with ./install.sh --safety-check, then open Settings again."
                    : "It runs by itself in the background (as root) at the chosen interval: malware and rootkit scans, firewall, audit and file integrity, plus a backup when your backup disk is plugged in. It never updates the system, asks nothing, formats nothing, and waits for AC power. Because it is root, switching it on, changing how often and switching it off all ask for your sudo password."
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11; lineHeight: 1.3; wrapMode: Text.WordWrap
            }
        }
        Toggle {
            Layout.alignment: Qt.AlignTop
            pal: root.pal
            on: sa.isOn
            busy: sa.busy
            onToggled: sa.ask(sa.isOn ? "off" : "on")
        }
    }
    Flow {
        Layout.fillWidth: true
        spacing: 10
        Text { text: "Every"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; height: 30; verticalAlignment: Text.AlignVCenter }
        Repeater {
            model: [{ v: "1", t: "Day" }, { v: "7", t: "Week" }, { v: "30", t: "Month" }, { v: "90", t: "3 months" }, { v: "custom", t: "Custom" }]
            delegate: SChip {
                required property var modelData
                pal: root.pal
                label: modelData.t
                on: sa.every === modelData.v
                onClicked: { if (!sa.installed) return; sa.every = modelData.v; if (!sa.isOn) sa.ask("on") }
            }
        }
    }
    Slider {
        Layout.fillWidth: true
        visible: sa.every === "custom"
        pal: root.pal
        glyph: String.fromCodePoint(0xF0E17)
        value: (sa.days - 1) / 364
        readout: sa.days + " days"
        onMoved: v => { sa.days = Math.round(1 + v * 364); if (sa.isOn && sa.days !== root.remind.auto.days) sa.ask("on") }
    }
    RowLayout {
        id: pwRow
        Layout.fillWidth: true
        spacing: 10
        visible: sa.wanted !== ""
        Rectangle {
            id: pwBox
            Layout.fillWidth: true
            height: 36; radius: 18
            color: root.pal.zen ? root.pal.field : root.pal.box(Qt.alpha(root.pal.surface, 0.8))
            border.width: root.pal.zen && !pwIn.activeFocus ? 0 : 1
            border.color: pwIn.activeFocus ? Qt.alpha(root.pal.accent, 0.5) : root.pal.lineSoft
            TextInput {
                id: pwIn
                anchors.fill: parent
                anchors.leftMargin: 16; anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                passwordCharacter: "\u2022"
                color: root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                clip: true
                enabled: !sa.busy
                onAccepted: sa.go()
                Text {
                    visible: !parent.text && !parent.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: sa.wanted === "off" ? "your sudo password, to switch it off" : "your sudo password, to switch it on" + (sa.isOn ? " with this schedule" : "")
                    color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
            }
        }
        SChip { pal: root.pal; label: sa.busy ? "Working…" : (sa.wanted === "off" ? "Turn off" : (sa.isOn ? "Apply" : "Turn on")); primary: true; onClicked: sa.go() }
        SChip { pal: root.pal; label: "Cancel"; onClicked: { sa.wanted = ""; pwIn.text = ""; sa.msg = ""; sa.every = sa.isOn ? String(root.remind.auto.every) : "30" } }
    }
    Text {
        Layout.fillWidth: true
        visible: sa.msg !== ""
        text: sa.msg
        color: sa.bad ? root.pal.bad : root.pal.good
        font.family: root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap
    }
    component SChip: Chip { maxLabel: 1000 }
}
