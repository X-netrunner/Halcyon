import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Settings > Security > "Counter-scan attackers" (custom leaf, only listed while the sysmode is stealth).
// The switch is `sysmode counterscan on|off`, which saves COUNTER_SCAN in /etc/recon-deceiver.conf: once it is on it stays on,
// across reboots and mode switches, until you turn it off here (or with `sudo sysmode counterscan off`). It is root, so every
// change asks for the sudo password: it goes to `sudo -k -S` once and is never stored or logged.
// `root` is the Settings scope (it hands itself in), so pal / sysmode / the Toggle and Chip look come from there.
ColumnLayout {
    id: cs
    property var root
    width: parent ? parent.width : 0
    spacing: 12

    readonly property bool inStealth: root.sysmode === "stealth" || root.sysmode === "hacking"
    property bool isOn: false          // what /etc/recon-deceiver.conf says right now
    property string wanted: ""         // "on" | "off" while the password row is open
    property string msg: ""
    property bool bad: false
    property bool busy: false

    function ask(what) { if (busy || !inStealth && what === "on") return; wanted = what; msg = ""; bad = false; Qt.callLater(function () { pwIn.forceActiveFocus() }) }
    function go() {
        if (pwIn.text === "" || run.running || wanted === "") return
        busy = true; msg = ""; bad = false
        run.pw = pwIn.text
        pwIn.text = ""
        run.running = true
    }
    Component.onCompleted: if (!stateProc.running) stateProc.running = true

    Process {            // reads the saved switch (the file is world-readable, no root needed)
        id: stateProc
        command: ["sh", "-c", "grep -qiE '^COUNTER_SCAN=(on|1|yes|true)[[:space:]]*$' /etc/recon-deceiver.conf 2>/dev/null && echo on || echo off"]
        stdout: StdioCollector { onStreamFinished: cs.isOn = String(text).trim() === "on" }
    }
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
        command: ["sudo", "-k", "-S", "-p", "", "/usr/local/bin/sysmode", "counterscan", cs.wanted === "off" ? "off" : "on", "--yes"]
        stdout: StdioCollector { onStreamFinished: { run.soT = text; run.soDone = true; run.finishCheck() } }
        stderr: StdioCollector { onStreamFinished: { run.seT = text; run.seDone = true; run.finishCheck() } }
        onRunningChanged: { if (running) { soT = ""; seT = ""; soDone = false; seDone = false; exitedOnce = false } if (running && pw !== "") { write(pw + "\n"); pw = "" } }
        onExited: (c, st) => { code = c; exitedOnce = true; finishCheck() }
    }
    QtObject {           // runs once the process has ended and its output is complete (run.finishCheck)
        id: fin
        function trigger() {
            cs.busy = false
            var err = String(run.seT || "").trim()
            if (run.code === 0) {
                cs.wanted = ""
                cs.msg = String(run.soT || "").trim().split("\n").pop()
                cs.bad = false
            } else if (err.indexOf("incorrect password") >= 0 || err.indexOf("no password was provided") >= 0 || err.indexOf("Sorry, try again") >= 0 || err.indexOf("a password is required") >= 0) {
                cs.msg = "That password is not right. Try again."
                cs.bad = true
                Qt.callLater(function () { pwIn.forceActiveFocus() })
            } else {
                cs.msg = err.split("\n").pop() || ("It did not work (code " + run.code + ").")
                cs.bad = true
            }
            if (!stateProc.running) stateProc.running = true
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text { text: "Counter-scan attackers (nmap)"; color: cs.root.pal.text; font.family: cs.root.pal.uiFont; font.pixelSize: cs.root.pal.tBody; font.weight: Font.Medium }
            Text {
                Layout.fillWidth: true
                text: "Stealth mode only. When someone probes the decoys, nmap scans the address they came from (OS and open ports) and the result goes to the attacker-scans log. "
                    + "That address is often a hacked machine, a proxy or a VPN exit, and scanning other people's systems without permission is illegal in many places. "
                    + "Your gateway, DNS servers, this machine and the allow list are never scanned. Once you turn it on it stays on, through reboots and mode changes, until you turn it off here."
                color: cs.root.pal.muted; font.family: cs.root.pal.uiFont; font.pixelSize: 11; lineHeight: 1.3; wrapMode: Text.WordWrap
            }
        }
        Toggle {
            Layout.alignment: Qt.AlignTop
            pal: cs.root.pal
            on: cs.isOn
            busy: cs.busy
            onToggled: cs.ask(cs.isOn ? "off" : "on")
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        visible: cs.wanted !== ""
        Rectangle {
            Layout.fillWidth: true
            height: 36; radius: 18
            color: Qt.alpha(cs.root.pal.surface, 0.8)
            border.width: root.pal.zen && !pwIn.activeFocus ? 0 : 1
            border.color: pwIn.activeFocus ? Qt.alpha(cs.root.pal.accent, 0.5) : cs.root.pal.lineSoft
            TextInput {
                id: pwIn
                anchors.fill: parent
                anchors.leftMargin: 16; anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                passwordCharacter: "\u2022"
                color: cs.root.pal.text
                font.family: cs.root.pal.uiFont; font.pixelSize: cs.root.pal.tBody
                clip: true
                enabled: !cs.busy
                onAccepted: cs.go()
                Text {
                    visible: !parent.text && !parent.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: cs.wanted === "off" ? "your sudo password, to switch it off" : "your sudo password, to switch it on"
                    color: cs.root.pal.muted; font.family: cs.root.pal.uiFont; font.pixelSize: cs.root.pal.tBody
                }
            }
        }
        Chip { pal: cs.root.pal; maxLabel: 1000; label: cs.busy ? "Working…" : (cs.wanted === "off" ? "Turn off" : "Turn on"); on: true; onClicked: cs.go() }
        Chip { pal: cs.root.pal; maxLabel: 1000; label: "Cancel"; onClicked: { cs.wanted = ""; pwIn.text = ""; cs.msg = "" } }
    }
    Text {
        Layout.fillWidth: true
        visible: cs.msg !== ""
        text: cs.msg
        color: cs.bad ? cs.root.pal.bad : cs.root.pal.good
        font.family: cs.root.pal.uiFont; font.pixelSize: 11; wrapMode: Text.WordWrap
    }
}
