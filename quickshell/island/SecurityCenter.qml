import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "SecAsk.js" as SecAsk

// Security center.   >security in the launcher (also >firewall, >antivirus, the IPC call `security`).
// Two modules, each optional on its own (install.sh --firewall ai, --antivirus): the firewall (ai-firewall) and the antivirus
// (ai-antivirus). A module that is not installed is greyed out and the other keeps working.
//   Overview    both modules at a glance, their main action, and the newest events of both
//   Firewall    status, traffic, bans and detections from /run/ai-firewall/status.json (no root needed)
//   Antivirus   `ai-antivirus status --json`, the unacknowledged alerts, and on-demand scans (`ai-antivirus scan --json`)
//   Exceptions  programs and folders the antivirus leaves alone (`ai-antivirus exceptions --json`); AI coding tools by default.
//               Changes run as root through pkexec (the polkit password window), or in the console without a polkit agent.
//   Ask         questions to either module's local model (`ai-firewall ask --json`, `ai-antivirus ask --json`). The firewall can
//               run live tests (`/test`, or when the model asks for one); their results land in the conversation.
//               Only security questions and /test reach them (SecAsk.js); small talk and other questions get a fixed reply.
// Anything that needs root opens in the pop-out console (consoleRequested). Nothing runs while the window is closed.
Scope {
    id: root
    property var pal
    property bool open: false
    readonly property bool asWindow: open && pal.deskWin        // an ordinary window (Settings > Halcyon windows): Super+Q and opening another centre leave it alone (shell.qml)
    property string tab: "overview"          // overview | firewall | antivirus | exceptions | ask
    signal consoleRequested(string cmd)
    signal terminalRequested(string cmd)     // full-screen programs (the firewall dashboard) need a real terminal window, not the console
    signal focusRequested(string what)

    property string fwBin: "/usr/local/bin/ai-firewall"     // install.sh puts it here, the Arch package in /usr/bin (found on open)
    property string avBin: "/usr/bin/ai-antivirus"

    // ---- which modules are installed (looked up each time the window opens)
    property bool hasFw: false
    property bool hasAv: false
    property bool hasClam: false             // clamscan is installed: the ClamAV page (test it, scan with it)
    property bool detected: false
    Process {
        id: detectProc
        command: ["sh", "-c", "for p in /usr/local/bin/ai-firewall /usr/bin/ai-firewall; do [ -x \"$p\" ] && { echo \"fw $p\"; break; }; done; p=$(command -v ai-antivirus) && echo \"av $p\"; command -v clamscan >/dev/null 2>&1 && echo clam; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = text.match(/^fw (\S+)$/m)
                if (m) root.fwBin = m[1]
                root.hasFw = m !== null
                var a = text.match(/^av (\S+)$/m)
                if (a) root.avBin = a[1]
                root.hasAv = a !== null
                root.hasClam = /^clam$/m.test(text)
                root.detected = true
                if (root.tab === "firewall" && !root.hasFw || (root.tab === "antivirus" || root.tab === "exceptions") && !root.hasAv
                    || root.tab === "clamav" && !root.hasClam) root.tab = "overview"
                if (root.tab === "overview" && !root.hasFw && !root.hasAv && root.hasClam) root.tab = "clamav"   // ClamAV alone: its page
                if (root.askTarget === "firewall" && !root.hasFw) root.askTarget = "antivirus"
                if (root.askTarget === "antivirus" && !root.hasAv) root.askTarget = "firewall"
                root.refresh()
            }
        }
    }

    // ---- firewall: the status file the daemon rewrites every 3 s
    property var fw: null
    property var fwRate: ({ passed: 0, dropped: 0 })
    property var fwPrev: null
    property var fwHist: []                   // the last 60 rates (about 3 minutes), for the traffic graph
    readonly property bool fwAlive: fw !== null && (Date.now() / 1000 - (fw.updated_unix || 0)) < 30
    readonly property bool fwOk: fwAlive && fw.mode === "enforce"
    readonly property string fwState: !hasFw ? "Not installed" : (fw === null ? "Stopped" : (!fwAlive ? "Not responding" : (fw.mode === "enforce" ? "Protecting" : "Monitoring")))
    readonly property color fwColor: !hasFw ? pal.muted : (fw === null || !fwAlive ? pal.bad : (fw.mode === "enforce" ? pal.good : pal.warn))
    readonly property string posture: fw && fw.posture ? fw.posture : ""
    readonly property int bansCount: fw ? (fw.bans || []).length : 0
    Process {
        id: fwProc
        command: ["cat", "/run/ai-firewall/status.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                var o = null
                try { o = JSON.parse(text) } catch (e) { o = null }
                if (o && root.fwPrev && o.updated_unix > root.fwPrev.updated_unix) {
                    var dt = Math.max(1, o.updated_unix - root.fwPrev.updated_unix)
                    var drop = function (s) { return (s.dropped_policy || 0) + (s.dropped_blocklist || 0) + (s.dropped_feed || 0) }
                    root.fwRate = { passed: Math.max(0, Math.round(((o.passed || 0) - (root.fwPrev.passed || 0)) / dt)),
                                    dropped: Math.max(0, Math.round((drop(o) - drop(root.fwPrev)) / dt)) }
                    var h = root.fwHist.slice(-59); h.push(root.fwRate); root.fwHist = h
                }
                if (o) root.fwPrev = o
                root.fw = o
            }
        }
        onExited: code => { if (code !== 0) root.fw = null }
    }

    // ---- antivirus: ai-antivirus status + the alerts not acknowledged yet
    property var av: null
    property var avAlerts: []
    property string avErr: ""                // what `ai-antivirus status` printed on stderr (shown on the lock banner)
    readonly property bool avRunning: av !== null && av.services && av.services.engined === "active" && av.services.sensord === "active"
    // false until the user can read the database (group ai-antivirus, from the next login after install): alert figures are unknown then
    readonly property bool avKnown: av !== null && av.db_readable !== false
    readonly property int avUnacked: av && av.unacked !== null && av.unacked !== undefined ? av.unacked : avAlerts.length
    readonly property string avState: !hasAv ? "Not installed" : (av === null ? "…" : (!avRunning ? "Stopped" : (av.sensor_degraded === true ? "Degraded" : "Watching")))
    readonly property color avColor: !hasAv ? pal.muted : (!avRunning ? pal.bad : (av.sensor_degraded === true ? pal.warn : pal.good))

    // ---- who may read the database
    // Reading the alerts, the 24 h figures and the action log needs group ai-antivirus. A group added with `usermod` only reaches programs
    // started AFTER the login that follows it, and that login does not always reach this shell (a session kept alive by lingering or by
    // the login manager). So the cause is looked up instead of guessed (permProc), and the one case that can be fixed on the spot is:
    //   nogroup    this install has no group ai-antivirus           -> only "Unlock with password" (a root snapshot)
    //   notmember  the group exists, you are not in it              -> "Add me to the group", then it works at once (see stale)
    //   stale      you are in the group, this session does not know -> the data is read through `sg ai-antivirus`: no logout needed
    //   ok         in the group and the session knows it            -> a permission problem on the files: the error is shown
    property string avPerm: ""               // "" (not checked yet) | ok | nogroup | notmember | stale
    property bool hasSg: false               // sg (shadow-utils) is there
    readonly property bool avViaSg: avPerm === "stale" && hasSg
    // `sg` runs one command with the group and asks for no password when you are listed as a member in /etc/group
    function avCmd(args) {
        if (!avViaSg) return ["ai-antivirus"].concat(args)
        return ["timeout", "8", "sg", "ai-antivirus", "-c", ["ai-antivirus"].concat(args).map(shq).join(" ")]
    }
    readonly property string permScript: [
        "g=ai-antivirus; u=$(id -un)",
        "if getent group $g >/dev/null 2>&1; then echo group=yes; else echo group=no; fi",
        "case \",$(getent group $g | cut -d: -f4),\" in *,$u,*) echo member=yes ;; *) echo member=no ;; esac",
        "case \" $(id -Gn) \" in *\" $g \"*) echo session=yes ;; *) echo session=no ;; esac",
        "if command -v sg >/dev/null 2>&1; then echo sg=yes; else echo sg=no; fi"
    ].join("\n")
    Process {
        id: permProc
        command: ["sh", "-c", root.permScript]
        stdout: StdioCollector {
            onStreamFinished: {
                var k = {}, lines = text.split("\n")
                for (var i = 0; i < lines.length; i++) { var m = lines[i].match(/^(\w+)=(\w+)$/); if (m) k[m[1]] = m[2] }
                var was = root.avViaSg
                root.hasSg = k.sg === "yes"
                root.avPerm = k.group !== "yes" ? "nogroup" : (k.member !== "yes" ? "notmember" : (k.session !== "yes" ? "stale" : "ok"))
                if (root.avViaSg !== was) avSoon.restart()      // the commands changed: read again now, not at the next tick
            }
        }
    }
    Timer { id: avSoon; interval: 900; onTriggered: root.avRefreshData() }

    // ---- a one-off root snapshot ("Unlock with password"): status, alerts and the action log, read once with pkexec. It is not polled
    // (the password is asked only when you ask), and it ends by itself as soon as the live read works.
    property bool avSnap: false
    property var avSnapStatus: null
    readonly property string snapScript: "b=\"$1\"; echo @@status; \"$b\" status --json; echo @@alerts; \"$b\" alerts --unacked --json -n 40; echo @@actions; \"$b\" actions --json -n 100"
    // the figures only root could count are kept from the snapshot; services and the rest stay live
    function mergeSnap(d) {
        var s = avSnapStatus
        d = d || {}
        if (s) ["alerts_24h", "unacked", "pending_actions"].forEach(function (k) { if (s[k] !== undefined) d[k] = s[k] })
        d.db_readable = true
        return d
    }
    function avGotStatus(text) {
        var d = null
        try { d = JSON.parse(text) } catch (e) { d = null }
        if (d !== null && d.db_readable !== false) { avSnap = false; avSnapStatus = null }   // the live read works now: it takes over
        else if (d !== null && avSnap) d = mergeSnap(d)
        av = d
    }
    function parseAlerts(text) {
        var out = [], lines = String(text).split("\n")
        for (var i = lines.length - 1; i >= 0; i--) {
            if (lines[i].trim() === "") continue
            try { var o = JSON.parse(lines[i]); if (o && typeof o === "object") out.push(o) } catch (e) {}
        }
        return out
    }
    function parseSnap(text) {
        var parts = {}, cur = "", lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var m = lines[i].match(/^@@(\w+)$/)
            if (m) { cur = m[1]; parts[cur] = ""; continue }
            if (cur !== "") parts[cur] += lines[i] + "\n"
        }
        var st = null
        try { st = JSON.parse(parts.status || "") } catch (e) { st = null }
        return { status: st, alerts: parseAlerts(parts.alerts || ""), actions: parseActs(parts.actions || "") }
    }
    function avSnapDrop(ids) {                // after an acknowledge in snapshot mode: take them off the list we hold
        var keep = ids === "all" ? [] : avAlerts.filter(function (a) { return ids.indexOf(a.id) < 0 })
        var left = avSnapStatus && typeof avSnapStatus.unacked === "number" ? Math.max(0, avSnapStatus.unacked - (avAlerts.length - keep.length)) : keep.length
        avAlerts = keep
        if (avSnapStatus) avSnapStatus.unacked = left
        if (av) { var d = Object.assign({}, av); d.unacked = left; av = d }
    }

    Process {
        id: avProc
        command: root.avCmd(["status", "--json"])
        stdout: StdioCollector { onStreamFinished: root.avGotStatus(text) }
        stderr: StdioCollector { onStreamFinished: root.avErr = text.trim().replace(/^error: /i, "").split("\n")[0] }
    }
    Process {
        id: avAlertsProc
        command: root.avCmd(["alerts", "--unacked", "--json", "-n", "40"])
        stdout: StdioCollector { onStreamFinished: { if (!root.avSnap) root.avAlerts = root.parseAlerts(text) } }
    }
    Process {
        id: avAckProc
        property var ackIds: []
        stdout: StdioCollector { onStreamFinished: if (text.trim() !== "") root.flash(text.trim(), false) }
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.flash(text.trim().replace(/^error: /, ""), true) }
        onExited: code => {
            if (root.avSnap) {                   // it ran with pkexec: the password window hid this one
                Qt.callLater(function () { root.show("antivirus") })
                if (code === 0) root.avSnapDrop(avAckProc.ackIds)
            }
            root.refresh()
        }
    }
    // ---- what the responder did, would do, or holds back for you: quarantine a file, freeze / isolate a program, block an address.
    // The notifications ("Would quarantine", "N more notifications were held back. See: ai-antivirus actions") point here.
    //   pending   waits for your OK          -> Approve / Reject (sudo, in the console)
    //   dry_run   held back: alert-only mode recorded what it WOULD do; nothing was touched
    //   executed  done                       -> Undo (thaw, restore the quarantined file, lift the block), except kill
    property var avActions: []
    readonly property var avHeld: avActions.filter(function (a) { return a.action !== "notify" })
    readonly property int avPending: avActions.filter(function (a) { return a.status === "pending" }).length
    // the reason the action log could not be read as your user (stderr of `actions`), shown on the lock banner
    property string avActErr: ""
    // the page has something it cannot read: the status says so, the status itself failed, or the action log refused
    readonly property bool avLocked: hasAv && !avSnap && ((av !== null && av.db_readable === false) || (av === null && avErr !== "") || (avActErr !== "" && avActions.length === 0))
    // `actions --json` prints one JSON object per line like `alerts --json`; a JSON array (or {actions: [...]}) is read too
    function parseActs(text) {
        var out = [], t = String(text).trim()
        if (t === "") return out
        var whole = null
        try { whole = JSON.parse(t) } catch (e) { whole = null }
        if (whole !== null) {
            if (Array.isArray(whole)) out = whole
            else if (whole && Array.isArray(whole.actions)) out = whole.actions
            else if (whole && typeof whole === "object") out = [whole]
        } else {
            var lines = t.split("\n")
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].trim() === "") continue
                try { var o = JSON.parse(lines[i]); if (o && typeof o === "object") out.push(o) } catch (e) {}
            }
        }
        out.sort(function (a, b) { return (a.status === "pending" ? 0 : 1) - (b.status === "pending" ? 0 : 1) || (b.ts_ns || 0) - (a.ts_ns || 0) })
        return out
    }
    Process {
        id: avActProc
        command: root.avCmd(["actions", "--json", "-n", "60"])
        stdout: StdioCollector { onStreamFinished: { if (!root.avSnap) root.avActions = root.parseActs(text) } }
        stderr: StdioCollector { onStreamFinished: { if (!root.avSnap) root.avActErr = text.trim().replace(/^error: /, "").split("\n")[0] } }
    }
    // "Unlock with password": one pkexec run that reads status, alerts and the action log as root.
    // Three things used to go wrong here and look like "nothing happens":
    //   1. the result was read in onExited, but the output collectors can finish AFTER the exit: the text was still empty and the
    //      unlock fell back to the console as if it had failed. The result is now handled only when the exit AND both streams are in.
    //   2. no polkit agent was running (nothing shows a password window): scripts/polkit-agent.sh starts one first.
    //   3. every failure silently opened the console. Now the reason is shown on the lock bar, with the console as a button.
    property string avUnlockErr: ""           // why the last unlock did not work (shown on the lock bar); "" = fine
    property string avUnlockStep: ""          // "" | agent | password: what the unlock is waiting for
    property string agentFor: "unlock"        // who asked for the agent check: unlock (the lists) | exc (an exception change)
    property int avRootCode: -1
    property string avRootOutT: ""
    property string avRootErrT: ""
    property bool avRootExited: false
    property bool avRootOutDone: false
    property bool avRootErrDone: false
    readonly property string avSudoCmd: "sudo " + shq(avBin) + " alerts --unacked -n 40 && sudo " + shq(avBin) + " actions -n 100"
    function avRootFinish() {
        if (!avRootExited || !avRootOutDone || !avRootErrDone) return
        avRootExited = false                                // handle one run once
        avUnlockStep = ""
        show("antivirus")
        var code = avRootCode, errLine = avRootErrT.trim().replace(/^error: /i, "").split("\n")[0]
        var snap = null
        if (code === 0) snap = parseSnap(avRootOutT)
        if (snap && snap.status) {
            avUnlockErr = ""
            avSnapStatus = snap.status
            avSnap = true
            avAlerts = snap.alerts
            avActions = snap.actions
            avActErr = ""; avErr = ""
            av = mergeSnap(av ? Object.assign({}, av) : Object.assign({}, snap.status))
            return
        }
        if (code === 126) avUnlockErr = "The password window was closed without a password."
        else if (code === 127 || /not authorized|authentication agent|authorization/i.test(errLine))
            avUnlockErr = (errLine !== "" ? errLine : "pkexec was refused") + (/agent/i.test(errLine) ? " (no password window is running: Retry starts one)" : " (wrong password, or this user may not run it as root)")
        else if (code === 0) {
            var o = avRootOutT.trim().split("\n")[0]
            avUnlockErr = "Unlocked, but the status could not be read" + (o !== "" ? ": " + o.slice(0, 140) : (errLine !== "" ? ": " + errLine : " (it printed nothing)"))
        }
        else avUnlockErr = (errLine !== "" ? errLine : "ai-antivirus stopped with exit code " + code) + (errLine !== "" ? " (exit " + code + ")" : "")
        flash(avUnlockErr, true)
    }
    Process {
        id: avRootProc
        stdout: StdioCollector { onStreamFinished: { root.avRootOutT = text; root.avRootOutDone = true; root.avRootFinish() } }
        stderr: StdioCollector { onStreamFinished: { root.avRootErrT = text; root.avRootErrDone = true; root.avRootFinish() } }
        onExited: code => { root.avRootCode = code; root.avRootExited = true; root.avRootFinish() }
    }
    // step 1: a polkit agent must be running or pkexec has nowhere to ask
    Process {
        id: agentProc
        command: ["sh", Quickshell.env("HOME") + "/.config/Halcyon/scripts/polkit-agent.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                var r = text.trim(), forExc = root.agentFor === "exc"
                if (r === "nopkexec" || r.indexOf("none") === 0 || r === "") {
                    root.avUnlockStep = ""
                    var why = r === "nopkexec" ? "pkexec (the polkit package) is not installed." : "No password window (polkit agent) is installed or allowed here (Settings > Startup > Password prompt helper)."
                    if (forExc) {
                        root.flash(why + " Opening the console: it asks for your password there.", true)
                        root.consoleRequested("sudo " + root.shq(root.avBin) + " exceptions " + excEdit.args.map(root.shq).join(" "))
                    } else {
                        root.avUnlockErr = why + " Use the console button: it asks for your password there."
                        root.flash(root.avUnlockErr, true)
                    }
                    return
                }
                root.avUnlockStep = "password"
                root.hide()                              // the password window would sit under this one
                if (forExc) {
                    root.excOutT = ""; root.excErrT = ""; root.excCode = -1
                    root.excExited = false; root.excOutDone = false; root.excErrDone = false
                    excEdit.command = ["pkexec", root.avBin, "exceptions"].concat(excEdit.args)
                    excEdit.running = true
                    return
                }
                root.avRootOutT = ""; root.avRootErrT = ""; root.avRootCode = -1
                root.avRootExited = false; root.avRootOutDone = false; root.avRootErrDone = false
                avRootProc.command = ["pkexec", "/bin/sh", "-c", root.snapScript, "sh", root.avBin]
                avRootProc.running = true
            }
        }
    }
    function avUnlock() {
        if (avRootProc.running || agentProc.running || !hasAv) return
        avUnlockErr = ""
        avUnlockStep = "agent"; agentFor = "unlock"
        agentProc.running = true
    }
    // adds this user to the group: from then on `sg` reads the database at once; the console shows the command, you type the password there
    readonly property string avJoinCmd: "getent group ai-antivirus >/dev/null && sudo usermod -aG ai-antivirus \"$USER\" && echo \"done: open the Security center again, it loads now (no logout needed)\" || echo \"this system has no group ai-antivirus: use Unlock with password\""
    readonly property string avDiagCmd: "echo '--- you'; id; echo; echo '--- group'; getent group ai-antivirus || echo 'no group ai-antivirus'; echo; echo '--- files'; ls -ld /var/lib/ai-antivirus /var/log/ai-antivirus /run/ai-antivirus /etc/ai-antivirus 2>&1; echo; echo '--- status'; ai-antivirus status --json 2>&1 | head -c 700; echo; echo '--- actions'; ai-antivirus actions -n 3 2>&1 | head -5"
    function actVerb(a) {
        var v = { quarantine: ["Quarantine", "Quarantined"], freeze: ["Freeze", "Frozen"], isolate: ["Isolate", "Isolated"], block: ["Block", "Blocked"],
                  kill: ["Stop", "Stopped"], thaw: ["Thaw", "Thawed"] }[a.action] || [a.action, a.action]
        var what = a.target && a.target.kind === "file" ? " file" : (a.target && a.target.kind === "ip" ? " address" : (a.target && a.target.kind === "process" ? " program" : ""))
        if (a.status === "executed") return v[1] + what
        if (a.status === "pending") return v[0] + what + "?"
        if (a.status === "dry_run") return "Held back: would " + v[0].toLowerCase() + what
        if (a.status === "undone") return v[0] + what + " (undone)"
        if (a.status === "rejected") return v[0] + what + " (rejected)"
        if (a.status === "failed") return v[0] + what + " failed"
        return v[0] + what + " (" + a.status + ")"
    }
    function actTarget(t) {
        if (!t) return ""
        if (t.kind === "file") return String(t.path || "").replace(/^\/home\/[^/]+\//, "~/")
        if (t.kind === "process") return (t.exe ? String(t.exe).replace(/^\/home\/[^/]+\//, "~/") : "") + (t.pid ? "  (pid " + t.pid + ")" : "")
        if (t.kind === "ip") return String(t.addr || "")
        return ""
    }
    function actTone(a) {
        return a.status === "pending" ? pal.warn : (a.status === "executed" ? pal.bad : (a.status === "failed" ? pal.bad : (a.status === "dry_run" ? pal.accent : pal.muted)))
    }
    function actRun(verb, id) { consoleRequested("sudo " + shq(avBin) + " " + verb + " " + Number(id)) }
    function ack(ids) {
        if (avAckProc.running) return
        var args = ids === "all" ? ["ack", "--all"] : ["ack"].concat(ids.map(String))
        avAckProc.ackIds = ids
        avAckProc.command = avSnap ? ["pkexec", avBin].concat(args) : avCmd(args)
        if (avSnap) hide()                               // the snapshot is root's: the acknowledge needs the password window too
        avAckProc.running = true
    }

    // ---- on-demand scan, inside the window: one JSON line per file with findings, then a summary
    property var scanFound: []
    property var scanSum: null
    property string scanWhat: ""
    readonly property bool scanning: scanProc.running
    function scan(dir) {
        if (scanning || !hasAv) return
        scanFound = []; scanSum = null; scanWhat = dir
        scanProc.command = ["sh", "-c", "cd \"$HOME\" && exec ai-antivirus scan --json \"$1\"", "scan", dir]
        scanProc.running = true
    }
    Process {
        id: scanProc
        stdout: SplitParser {
            onRead: line => {
                var o = null
                try { o = JSON.parse(line) } catch (e) { return }
                if (o.summary) root.scanSum = o
                else { var c = root.scanFound.slice(); c.push(o); root.scanFound = c }
            }
        }
        onExited: if (root.scanSum === null) root.scanSum = { files: 0, found: root.scanFound.length, seconds: 0, failed: true }
    }

    // ---- ClamAV: `halcyon-ai.py clamav test|scan`. The fixes are commands from a fixed list (the local model, when it is on, only
    // orders them and sums up); each one opens in the console, so you see it and type your password before anything changes.
    readonly property string aiScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/halcyon-ai.py"
    property var clam: null                  // the last result: { kind: test|scan, headline, summary, checks, found, fixes, good, ai }
    property string clamErr: ""
    property string clamWhat: ""
    readonly property bool clamBusy: clamProc.running
    readonly property string clamState: clamBusy ? (clamWhat === "test" ? "Testing…" : clamWhat === "scan" ? "Scanning…" : "Working…")
        : (clam === null ? (clamErr !== "" ? "Failed" : "Not tested yet") : (clam.kind === "exceptions" ? "Exceptions" : clam.good ? (clam.kind === "test" ? "Works" : "Clean") : (clam.kind === "test" ? "Needs attention" : "Found something")))
    readonly property color clamColor: clamBusy || clam === null ? (clamErr !== "" ? pal.bad : pal.muted) : (clam.kind === "exceptions" ? pal.muted : clam.good ? pal.good : pal.bad)
    function clamRun(what, dir) {
        if (clamBusy || !hasClam) return
        clamWhat = what; clamErr = ""; clam = null
        clamProc.command = ["python3", aiScript, "clamav", what].concat(dir ? [dir] : []).concat(["--json"])
        clamProc.running = true
    }
    function clamForget(n) { clamRun("forget", String(n)) }      // answers with the updated list
    // a fix that is a command (not an instruction such as the NixOS one) can be opened in the console
    function runnable(cmd) { return /^(sudo |clamscan |mkdir |xdg-open )/.test(String(cmd || "")) }
    Process {
        id: clamProc
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (!d) { root.clamErr = "No answer from halcyon-ai.py (is python3 there?)"; return }
                if (!d.ok) { root.clamErr = d.error || "It did not work."; return }
                root.clam = d
            }
        }
    }

    // ---- exceptions: programs and folders the antivirus leaves alone
    property var exc: null
    readonly property var excList: exc && exc.exceptions ? exc.exceptions : []
    property string excKind: "program"       // the kind the add row adds
    Process {
        id: excProc
        command: [root.avBin, "exceptions", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.exc = JSON.parse(text) } catch (e) { root.exc = null } } }
    }
    function shq(a) { return "'" + String(a).replace(/'/g, "'\\''") + "'" }
    // args: ["add", kind, match, "--name", name] | ["remove", match] | ["reset"]
    function excChange(args) {
        if (excEdit.running || agentProc.running || avRootProc.running || !hasAv) return
        excEdit.args = args
        avUnlockStep = "agent"; agentFor = "exc"
        agentProc.running = true             // a polkit agent has to be running first, or pkexec has nowhere to ask
    }
    function excAdd(kind, match, name) {
        match = String(match).trim(); name = String(name).trim()
        if (match === "") return
        if (kind === "folder" && match.charAt(0) !== "/" && match.indexOf("~/") !== 0) match = "~/" + match
        excChange(name !== "" ? ["add", kind, match, "--name", name] : ["add", kind, match])
    }
    // an exception change runs with pkexec; like the unlock above, its result is handled only when the exit AND both output streams are in
    // (the old code read the collectors in onExited, which can run before they finish: the message was lost)
    property int excCode: -1
    property string excOutT: ""
    property string excErrT: ""
    property bool excExited: false
    property bool excOutDone: false
    property bool excErrDone: false
    function excFinish() {
        if (!excExited || !excOutDone || !excErrDone) return
        excExited = false
        avUnlockStep = ""
        var code = excCode, err = excErrT.trim()
        // pkexec itself refused (no agent / not found): the same command with sudo in the console
        if (code === 127 && (err === "" || /authentication agent|not found|No such file/i.test(err))) {
            consoleRequested("sudo " + shq(avBin) + " exceptions " + excEdit.args.map(shq).join(" "))
            return
        }
        show("exceptions")
        var line = err.replace(/^error: /i, "").split("\n")[0]
        if (code === 0) flash(excOutT.trim().split("\n")[0], false)
        else if (code === 126) flash("The password window was closed without a password.", true)
        else flash(line !== "" ? line : "The change did not work (exit " + code + ")", true)
        if (!excProc.running) excProc.running = true
    }
    Process {
        id: excEdit
        property var args: []
        stdout: StdioCollector { onStreamFinished: { root.excOutT = text; root.excOutDone = true; root.excFinish() } }
        stderr: StdioCollector { onStreamFinished: { root.excErrT = text; root.excErrDone = true; root.excFinish() } }
        onExited: code => { root.excCode = code; root.excExited = true; root.excFinish() }
    }

    function refresh() {
        if (!open) return
        if (hasAv && !excProc.running) excProc.running = true
        if (hasFw && !fwProc.running) fwProc.running = true
        avTick()
    }
    // the antivirus: what is blocking it (while it is blocked, or read through sg), then the data
    function avTick() {
        if (!hasAv) return
        if (!permProc.running && (avPerm === "" || avLocked || avViaSg)) permProc.running = true
        avRefreshData()
    }
    function avRefreshData() {
        if (!hasAv) return
        if (!avProc.running) avProc.running = true
        if (!avSnap && !avAlertsProc.running) avAlertsProc.running = true
        if (!avSnap && !avActProc.running) avActProc.running = true
    }
    Timer { interval: 2000; repeat: true; running: root.open && root.hasFw; onTriggered: if (!fwProc.running) fwProc.running = true }
    Timer { interval: 6000; repeat: true; running: root.open && root.hasAv; onTriggered: root.avTick() }

    // ---- both at once: the overview's headline and its feed
    readonly property int down: (hasFw && !fwAlive ? 1 : 0) + (hasAv && av !== null && !avRunning ? 1 : 0)
    readonly property string overall: !detected ? "" : (!hasFw && !hasAv ? "Not installed" : (down > 0 ? "Needs attention" : (avLocked ? "Alerts are locked" : (avPending > 0 ? "Waiting for your OK" : (avUnacked > 0 ? "Review alerts" : "Protected")))))
    readonly property color overallColor: !hasFw && !hasAv ? pal.muted : (down > 0 ? pal.bad : (avUnacked > 0 || avPending > 0 || avLocked ? pal.warn : pal.good))
    readonly property var feed: {
        var out = []
        if (fw) (fw.recent || []).forEach(function (d) { out.push({ at: d.at_unix, who: "firewall", title: d.reason + "  " + d.ip, sub: d.ports, tone: d.enforced ? "bad" : "warn" }) })
        avAlerts.forEach(function (a) { out.push({ at: a.ts_ns / 1e9, who: "antivirus", title: a.title, sub: a.detail && a.detail.exe ? a.detail.exe : a.rule_id, tone: a.severity }) })
        avHeld.forEach(function (a) { out.push({ at: a.ts_ns / 1e9, who: "antivirus", title: root.actVerb(a), sub: root.actTarget(a.target) || (a.rule_id || ""), tone: a.status === "pending" ? "medium" : (a.status === "executed" ? "high" : "low") }) })
        out.sort(function (a, b) { return b.at - a.at })
        return out.slice(0, 8)
    }

    // ---- ask: one conversation, aimed at either module
    property string askTarget: "firewall"     // firewall | antivirus
    property var msgs: []                     // { role: "you" | "ai" | "test", text, reports, actions, live, bad, who }
    property string model: ""
    readonly property bool asking: askProc.running
    readonly property var tests: ["all", "health", "ports", "detector", "traffic", "services"]
    function pushMsg(m) { var c = msgs.slice(); c.push(m); msgs = c }
    function patchLast(f) {
        var c = msgs.slice()
        for (var i = c.length - 1; i >= 0; i--) {
            if (c[i].role === "ai" && c[i].live) { var m = Object.assign({}, c[i]); f(m); c[i] = m; msgs = c; return true }
        }
        return false
    }
    function ask(q) {
        q = String(q || "").trim()
        if (q === "" || asking) return
        var target = askTarget
        if (q.indexOf("/test") === 0) target = "firewall"
        if (target === "firewall" && !hasFw) return
        if (target === "antivirus" && !hasAv) return
        pushMsg({ role: "you", text: q, who: target })
        var r = SecAsk.route(q, target)
        if (!r.send) {                         // not a security question: answered here, neither tool is started
            pushMsg({ role: "ai", text: r.reply, live: false, actions: [], who: target })
            Qt.callLater(function () { root.focusRequested("ask") })
            return
        }
        askProc.target = target
        askProc.command = target === "firewall" ? [fwBin, "ask", "--json", q] : ["ai-antivirus", "ask", "--json", q]
        askProc.running = true
        Qt.callLater(function () { root.focusRequested("ask") })
    }
    function runTest(name) { tab = "ask"; ask("/test" + (name && name !== "all" ? " " + name : "")) }
    function act(a) {
        if (a.test) { runTest(a.args[1] || "all"); return }
        // changes to the firewall need root: shown in the console with the exact command
        consoleRequested("sudo " + fwBin + " " + a.args.join(" "))
    }
    Process {
        id: askProc
        property string target: "firewall"
        stdout: SplitParser {
            onRead: line => {
                var o = null
                try { o = JSON.parse(line) } catch (e) { return }
                if (o.type === "model") root.model = o.name
                else if (o.type === "chunk") {
                    if (!root.patchLast(function (m) { m.text += o.text }))
                        root.pushMsg({ role: "ai", text: o.text, live: true, actions: [], who: askProc.target })
                }
                else if (o.type === "tests") {
                    root.patchLast(function (m) { m.live = false })
                    root.pushMsg({ role: "test", reports: o.reports || [], who: askProc.target })
                }
                else if (o.type === "done") {
                    var text = String(o.text || "").trim(), acts = o.actions || []
                    if (!root.patchLast(function (m) { m.text = text !== "" ? text : m.text; m.actions = acts; m.live = false }) && (text !== "" || acts.length > 0))
                        root.pushMsg({ role: "ai", text: text, actions: acts, live: false, who: askProc.target })
                }
                else if (o.type === "error") {
                    root.patchLast(function (m) { m.live = false })
                    root.pushMsg({ role: "ai", text: o.error, bad: true, live: false, actions: [], who: askProc.target })
                }
            }
        }
        onExited: { root.patchLast(function (m) { m.live = false }); root.refresh() }
    }

    // ---- small things
    property string note: ""
    property bool noteBad: false
    function flash(t, bad) { note = t; noteBad = bad === true; noteT.restart() }
    Timer { id: noteT; interval: 5000; onTriggered: root.note = "" }
    function count(n) {
        n = Number(n || 0)
        if (n >= 1e7) return Math.round(n / 1e6) + "M"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
        if (n >= 1e4) return Math.round(n / 1e3) + "k"
        return String(Math.round(n))
    }
    function dur(s) {
        s = Number(s || 0)
        if (s <= 0) return "∞"
        if (s < 120) return s + "s"
        if (s < 7200) return Math.round(s / 60) + "m"
        return Math.floor(s / 3600) + "h" + String(Math.floor(s % 3600 / 60)).padStart(2, "0")
    }
    function ago(unix) { return dur(Math.max(1, Math.round(Date.now() / 1000 - unix))) }
    function sevColor(s) {
        return s === "critical" || s === "bad" ? pal.bad : (s === "high" ? Qt.lighter(pal.bad, 1.15) : (s === "medium" || s === "warn" ? pal.warn : pal.muted))
    }
    function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1) }

    function show(t) {
        if (t === "overview" || t === "firewall" || t === "antivirus" || t === "exceptions" || t === "ask" || t === "clamav") tab = t
        open = true
        detectProc.running = true
        Qt.callLater(function () { root.focusRequested(root.tab === "ask" ? "ask" : "panel") })
    }
    function hide() { open = false }
    function toggle() { if (open) hide(); else show("overview") }
    function setTab(t) {
        tab = t
        refresh()
        Qt.callLater(function () { root.focusRequested(t === "ask" ? "ask" : "panel") })
    }
    property bool linger: false
    onOpenChanged: if (!open) { linger = true; lingerT.restart() } else refresh()
    Timer { id: lingerT; interval: (root.pal ? root.pal.dMed : 300) + 80; onTriggered: root.linger = false }

    // ---------------------------------------------------------------- pieces
    component Label: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
        font.weight: Font.DemiBold
        font.letterSpacing: root.pal.calm ? 0.2 : 0.9
        font.capitalization: root.pal.calm ? Font.MixedCase : Font.AllUppercase
    }
    component Glyph: Text {
        property int code: 0
        text: String.fromCodePoint(code)
        font.family: root.pal.font
        font.pixelSize: 16
        color: root.pal.muted
    }
    component Small: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap + 1
        elide: Text.ElideRight
    }
    // a quiet button: icon + label, filled on hover
    component Btn: Rectangle {
        id: b
        property string label: ""
        property int glyph: 0
        property bool primary: false
        property bool disabled: false
        signal clicked()
        implicitWidth: bRow.implicitWidth + 26
        implicitHeight: 34
        radius: height / 2
        opacity: disabled ? 0.4 : 1
        color: primary ? (bMa.containsMouse && !disabled ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent)
                       : (bMa.containsMouse && !disabled ? root.pal.fillHover : root.pal.fill)
        scale: bMa.pressed && !disabled ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Row {
            id: bRow
            anchors.centerIn: parent
            spacing: 7
            Glyph { visible: b.glyph !== 0; code: b.glyph; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: 15; color: b.primary ? root.pal.bg : root.pal.text }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: b.label
                color: b.primary ? root.pal.bg : root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody - 1
                font.weight: b.primary ? Font.DemiBold : Font.Medium
            }
        }
        MouseArea { id: bMa; anchors.fill: parent; hoverEnabled: true; cursorShape: b.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!b.disabled) b.clicked() }
    }
    component Dot: Rectangle { width: 8; height: 8; radius: 4 }
    // the three soft dots while something works
    component Working: Row {
        id: wk
        spacing: 5
        Repeater {
            model: 3
            delegate: Rectangle {
                required property int index
                width: 6; height: 6; radius: 3
                color: root.pal.accent
                opacity: 0.25 + 0.75 * Math.max(0, Math.sin((wkT.t - index * 0.18) * Math.PI * 2))
            }
        }
        Item { id: wkT; property real t: 0; NumberAnimation on t { from: 0; to: 1; duration: 1300; loops: Animation.Infinite; running: wk.visible && root.open } }
    }
    // one figure in a strip: a big number over a small label
    component Stat: Item {
        id: st
        property string label: ""
        property string value: ""
        property string sub: ""
        property color tone: root.pal.text
        property bool divider: true
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredWidth: 1
        clip: true
        Rectangle { visible: st.divider; width: 1; anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 14; bottomMargin: 14 } color: root.pal.lineSoft }
        Column {
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 20; rightMargin: 12 }
            spacing: 3
            Row {
                spacing: 7
                Text { id: stV; text: st.value; color: st.tone; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 7; font.weight: Font.DemiBold }
                Text { anchors.baseline: stV.baseline; text: st.sub; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
            }
            Label { text: st.label; width: parent.width; elide: Text.ElideRight }
        }
    }
    // a soft surface that holds a row of Stats
    component Strip: Rectangle {
        default property alias stats: stRow.data
        Layout.fillWidth: true
        implicitHeight: 78
        radius: root.pal.rLg
        color: root.pal.fill
        RowLayout { id: stRow; anchors.fill: parent; spacing: 0 }
    }
    // a titled section without a frame: a small label, an optional count, then its content
    component Section: Item {
        id: sec
        property string title: ""
        property string extra: ""
        property string action: ""          // a small text button at the right of the title
        signal acted()
        default property alias body: secBody.data
        RowLayout {
            id: secHead
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 4; rightMargin: 4 }
            spacing: 10
            Label { text: sec.title; Layout.fillWidth: true }
            Text { text: sec.extra; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
            Text {
                visible: sec.action !== ""
                text: sec.action
                color: secMa.containsMouse ? root.pal.accent : root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
                font.weight: Font.DemiBold
                MouseArea { id: secMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sec.acted() }
            }
        }
        Item { id: secBody; anchors { left: parent.left; right: parent.right; top: secHead.bottom; bottom: parent.bottom; topMargin: 8 } }
    }
    // a list row: a coloured mark, a title and a sub line, and a button that shows on hover
    component ListRow: Rectangle {
        id: lr
        property string title: ""
        property string sub: ""
        property string lead: ""
        property color mark: root.pal.muted
        property bool mono: false
        property int actGlyph: 0
        property color actTone: root.pal.muted
        property int act2Glyph: 0            // a second button left of the first (e.g. Reject next to Approve)
        property color act2Tone: root.pal.muted
        property bool actAlways: false       // show the buttons all the time, not only on hover
        property string chip: ""             // a small tinted label at the right (a severity, a status)
        property color chipTone: root.pal.muted
        signal act()
        signal act2()
        height: 48
        radius: root.pal.rSm
        color: lrMa.containsMouse ? root.pal.fill : "transparent"
        MouseArea { id: lrMa; anchors.fill: parent; hoverEnabled: true }
        Rectangle { id: lrMark; x: 8; width: 3; height: 26; radius: 2; anchors.verticalCenter: parent.verticalCenter; color: lr.mark }
        Text { id: lrLead; visible: lr.lead !== ""; anchors { left: lrMark.right; leftMargin: 10; verticalCenter: parent.verticalCenter } width: 40; text: lr.lead; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
        Column {
            anchors { left: lr.lead !== "" ? lrLead.right : lrMark.right; leftMargin: lr.lead !== "" ? 4 : 12; right: lr.chip !== "" ? lrChip.left : lrAct2.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            spacing: 1
            Text { width: parent.width; elide: Text.ElideRight; text: lr.title; color: root.pal.text; font.family: lr.mono ? root.pal.mono : root.pal.uiFont; font.pixelSize: root.pal.tBody - 1 }
            Small { width: parent.width; text: lr.sub; visible: text !== ""; font.pixelSize: root.pal.tCap }
        }
        Rectangle {
            id: lrChip
            visible: lr.chip !== ""
            anchors { right: lrAct2.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            width: lrChipT.implicitWidth + 16; height: 20; radius: 10
            color: Qt.alpha(lr.chipTone, 0.16)
            Text { id: lrChipT; anchors.centerIn: parent; text: lr.chip; color: lr.chipTone; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.weight: Font.DemiBold }
        }
        RowIcon {
            id: lrAct
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            visible: lr.actGlyph !== 0 && (lr.actAlways || lrMa.containsMouse)
            width: lr.actGlyph !== 0 ? 28 : 0
            glyph: lr.actGlyph
            tone: lr.actTone
            onClicked: lr.act()
        }
        RowIcon {
            id: lrAct2
            anchors { right: lrAct.left; rightMargin: lr.act2Glyph !== 0 ? 4 : 0; verticalCenter: parent.verticalCenter }
            visible: lr.act2Glyph !== 0 && (lr.actAlways || lrMa.containsMouse)
            width: lr.act2Glyph !== 0 ? 28 : 0
            glyph: lr.act2Glyph
            tone: lr.act2Tone
            onClicked: lr.act2()
        }
    }
    // a centred quiet note for an empty list
    component Empty: Column {
        property int glyph: 0xF0565
        property string text: ""
        property color tone: root.pal.good
        anchors.centerIn: parent
        spacing: 8
        Glyph { anchors.horizontalCenter: parent.horizontalCenter; code: parent.glyph; font.pixelSize: 28; color: Qt.alpha(parent.tone, 0.7) }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.text; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1 }
    }
    // a sidebar row
    component NavRow: Rectangle {
        id: nv
        property string key: ""
        property string label: ""
        property int glyph: 0
        property color tone: "transparent"
        property bool available: true
        property int badge: 0
        readonly property bool on: root.tab === key
        Layout.fillWidth: true
        implicitHeight: 44
        radius: root.pal.rMd
        opacity: available ? 1 : 0.4
        color: on ? Qt.alpha(root.pal.accent, 0.14) : (nvMa.containsMouse && available ? root.pal.fill : "transparent")
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Glyph { id: nvG; x: 14; anchors.verticalCenter: parent.verticalCenter; code: nv.glyph; font.pixelSize: 18; color: nv.on ? root.pal.accent : root.pal.muted }
        Text { anchors { left: nvG.right; leftMargin: 12; verticalCenter: parent.verticalCenter } text: nv.label; color: nv.on ? root.pal.text : Qt.alpha(root.pal.text, 0.85); font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: nv.on ? Font.DemiBold : Font.Medium }
        Rectangle {
            visible: nv.badge > 0
            anchors { right: nvDot.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            width: Math.max(20, nvB.implicitWidth + 12); height: 20; radius: 10
            color: Qt.alpha(root.pal.warn, 0.18)
            Text { id: nvB; anchors.centerIn: parent; text: nv.badge; color: root.pal.warn; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.DemiBold }
        }
        Dot { id: nvDot; anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter } color: nv.tone; width: 7; height: 7; radius: 4 }
        MouseArea { id: nvMa; anchors.fill: parent; hoverEnabled: true; enabled: nv.available; cursorShape: Qt.PointingHandCursor; onClicked: root.setTab(nv.key) }
    }
    // a small round icon button
    component RowIcon: Rectangle {
        id: ri
        property int glyph: 0
        property color tone: root.pal.muted
        signal clicked()
        width: 28; height: 28; radius: 14
        color: riMa.containsMouse ? Qt.alpha(ri.tone, 0.18) : "transparent"
        Glyph { anchors.centerIn: parent; code: ri.glyph; font.pixelSize: 15; color: ri.tone }
        MouseArea { id: riMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ri.clicked() }
    }
    // the header of a page: a tinted icon, the state, one detail line, then its buttons
    component PageHead: RowLayout {
        id: ph
        property int glyph: 0
        property string status: ""
        property string detail: ""
        property color tone: root.pal.text
        default property alias buttons: phBtns.data
        Layout.fillWidth: true
        spacing: 14
        Rectangle {
            width: 44; height: 44; radius: 14
            color: Qt.alpha(ph.tone, 0.15)
            Glyph { anchors.centerIn: parent; code: ph.glyph; font.pixelSize: 22; color: ph.tone }
        }
        Column {
            Layout.fillWidth: true
            spacing: 2
            Text { text: ph.status; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 5; font.weight: Font.DemiBold }
            Small { text: ph.detail; visible: text !== ""; width: parent.width }
        }
        Row { id: phBtns; spacing: 8 }
    }
    // traffic: passed (accent) and dropped (bad) per second, newest on the right
    component Spark: Canvas {
        id: sp
        property var hist: []
        onHistChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var h = sp.hist, n = h.length
            if (n < 2) return
            var max = 1
            for (var i = 0; i < n; i++) max = Math.max(max, h[i].passed, h[i].dropped)
            var step = width / 59, x0 = width - (n - 1) * step
            var line = function (key, col, fill) {
                ctx.beginPath()
                for (var j = 0; j < n; j++) {
                    var x = x0 + j * step, y = height - 2 - (height - 6) * h[j][key] / max
                    if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                }
                ctx.strokeStyle = col; ctx.lineWidth = 1.6; ctx.stroke()
                if (fill) { ctx.lineTo(width, height); ctx.lineTo(x0, height); ctx.closePath(); ctx.fillStyle = Qt.alpha(col, 0.12); ctx.fill() }
            }
            line("passed", root.pal.accent, true)
            line("dropped", root.pal.bad, false)
        }
    }
    // a module on the overview: its state, three figures and its main action; the card opens its page
    component ModuleCard: Rectangle {
        id: mc
        property string key: ""
        property string name: ""
        property int glyph: 0
        property string status: ""
        property color tone: root.pal.muted
        property bool available: true
        property var figures: []            // [[value, label, color], ...]
        default property alias actions: mcAct.data
        Layout.fillWidth: true
        Layout.preferredHeight: 196
        radius: root.pal.rLg
        color: mcMa.containsMouse && available ? root.pal.fillHover : root.pal.fill
        opacity: available ? 1 : 0.45
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        MouseArea { id: mcMa; anchors.fill: parent; hoverEnabled: true; enabled: mc.available; cursorShape: Qt.PointingHandCursor; onClicked: root.setTab(mc.key) }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 14
            RowLayout {
                spacing: 12
                Rectangle {
                    width: 38; height: 38; radius: 12
                    color: Qt.alpha(mc.tone, 0.15)
                    Glyph { anchors.centerIn: parent; code: mc.glyph; font.pixelSize: 19; color: mc.tone }
                }
                Column {
                    Layout.fillWidth: true
                    Text { text: mc.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold }
                    Row {
                        spacing: 6
                        Dot { anchors.verticalCenter: parent.verticalCenter; color: mc.tone; width: 6; height: 6; radius: 3 }
                        Small { text: mc.status }
                    }
                }
                Glyph { code: 0xF0142; font.pixelSize: 18; opacity: mcMa.containsMouse ? 1 : 0.5 }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    model: mc.available ? mc.figures : []
                    delegate: Column {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 1
                        Text { text: modelData[0]; color: modelData[2] || root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 3; font.weight: Font.DemiBold }
                        Small { text: modelData[1]; font.pixelSize: root.pal.tCap }
                    }
                }
            }
            Item { Layout.fillHeight: true }
            Row { id: mcAct; spacing: 8; visible: mc.available }
        }
    }

    // ================================================================ the window
    LazyLoader {
        active: root.open || root.linger
        Host {
            id: win
            desktop: root.pal.deskWin
            title: "Security"
            deskWidth: 1100
            deskHeight: 720
            namespace: "island-security"
            keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            onCloseRequested: root.hide()

            MouseArea { anchors.fill: parent; enabled: !win.desktop; onClicked: root.hide() }

            Item {
                id: qp
                anchors.fill: parent
                focus: true
                property bool ready: false
                readonly property real target: (ready && root.open) ? 1 : 0
                property real reveal: 0
                onTargetChanged: reveal = target
                Behavior on reveal { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                Component.onCompleted: { ready = true; Qt.callLater(function () { if (root.tab === "ask") askIn.forceActiveFocus(); else qp.forceActiveFocus() }) }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true; return }
                    // 1-5 switch pages
                    var pages = ["overview", "firewall", "antivirus", "exceptions", "ask", "clamav"], i = e.key - Qt.Key_1
                    if (i >= 0 && i < pages.length) { root.setTab(pages[i]); e.accepted = true }
                }
                Connections {
                    target: root
                    function onFocusRequested(what) { if (what === "ask") askIn.forceActiveFocus(); else qp.forceActiveFocus() }
                }

                Rectangle { visible: !win.desktop; anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * qp.reveal) }

                Glass {
                    id: panel
                    pal: root.pal
                    width: win.desktop ? qp.width : Math.min(1100, qp.width - 80)
                    height: win.desktop ? qp.height : Math.min(720, qp.height - 80)
                    radius: win.desktop ? 0 : root.pal.rXl
                    opacityBody: 0.97
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                    anchors.centerIn: parent
                    opacity: win.desktop ? 1 : qp.reveal
                    scale: win.desktop ? 1 : 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== the pages
                        Item {
                            Layout.preferredWidth: 224
                            Layout.fillHeight: true
                            Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right; topMargin: 24; bottomMargin: 24 } width: 1; color: root.pal.lineSoft }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                anchors.rightMargin: 17
                                spacing: 4

                                Row {
                                    Layout.topMargin: 6
                                    Layout.bottomMargin: 20
                                    Layout.leftMargin: 8
                                    spacing: 10
                                    Glyph { anchors.verticalCenter: parent.verticalCenter; code: 0xF0565; font.pixelSize: 20; color: root.pal.accent }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Security"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 2; font.weight: Font.DemiBold }
                                }
                                NavRow { key: "overview"; label: "Overview"; glyph: 0xF0570; tone: root.overallColor }
                                NavRow { key: "firewall"; label: "Firewall"; glyph: 0xF1A11; tone: root.fwColor; available: root.hasFw || !root.detected }
                                NavRow { key: "antivirus"; label: "Antivirus"; glyph: 0xF13B6; tone: root.avColor; badge: root.avUnacked + root.avPending; available: root.hasAv || !root.detected }
                                NavRow { key: "exceptions"; label: "Exceptions"; glyph: 0xF0780; available: root.hasAv || !root.detected }
                                NavRow { key: "ask"; label: "Ask"; glyph: 0xF0B79; available: root.hasFw || root.hasAv || !root.detected }
                                NavRow { key: "clamav"; label: "ClamAV"; glyph: 0xF0668; tone: root.clam !== null ? root.clamColor : "transparent"; available: root.hasClam || !root.detected }
                                Item { Layout.fillHeight: true }
                                Text {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 8
                                    visible: root.note !== ""
                                    text: root.note
                                    wrapMode: Text.Wrap
                                    color: root.noteBad ? root.pal.bad : root.pal.good
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap + 1
                                }
                                // the system posture sysmode set (ai-firewall posture)
                                Rectangle {
                                    visible: root.posture !== ""
                                    Layout.leftMargin: 4
                                    implicitWidth: poRow.implicitWidth + 24
                                    implicitHeight: 30
                                    radius: 15
                                    color: root.pal.fill
                                    readonly property color tone: root.posture === "lockdown" ? root.pal.bad : (root.posture === "stealth" ? root.pal.accent2 : (root.posture === "relaxed" ? root.pal.warn : root.pal.good))
                                    Row {
                                        id: poRow
                                        anchors.centerIn: parent
                                        spacing: 7
                                        Glyph { anchors.verticalCenter: parent.verticalCenter; code: 0xF033E; font.pixelSize: 14; color: parent.parent.tone }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.cap(root.posture); color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.Medium }
                                    }
                                }
                            }
                        }

                        // ======================== the page
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            // ---- nothing installed
                            Empty {
                                visible: root.detected && !root.hasFw && !root.hasAv && !root.hasClam
                                glyph: 0xF099E
                                tone: root.pal.muted
                                text: "Not installed"
                            }

                            // ---- overview
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 22
                                visible: root.tab === "overview" && (root.hasFw || root.hasAv)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 18
                                    Rectangle {
                                        width: 64; height: 64; radius: 22
                                        color: Qt.alpha(root.overallColor, 0.15)
                                        Glyph { anchors.centerIn: parent; code: 0xF0565; font.pixelSize: 32; color: root.overallColor }
                                    }
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 3
                                        Text { text: root.overall; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 10; font.weight: Font.DemiBold }
                                        Small {
                                            width: parent.width
                                            text: [root.hasFw ? root.bansCount + (root.bansCount === 1 ? " ban" : " bans") : "",
                                                   root.hasAv ? (!root.avKnown ? "alerts unreadable" : (root.avUnacked > 0 ? root.avUnacked + " to review" : "no open alerts")) : "",
                                                   root.hasFw && root.fwAlive ? root.fwRate.passed + " pkt/s" : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 14
                                    ModuleCard {
                                        key: "firewall"; name: "Firewall"; glyph: 0xF1A11
                                        status: root.fwState + (root.posture !== "" && root.posture !== "secure" ? "  ·  " + root.posture : "")
                                        tone: root.fwColor; available: root.hasFw
                                        figures: [[root.count(root.fw ? root.fw.passed : 0), "passed", root.pal.text],
                                                  [root.count(root.fw ? (root.fw.dropped_policy || 0) + (root.fw.dropped_blocklist || 0) + (root.fw.dropped_feed || 0) : 0), "dropped", root.pal.warn],
                                                  [String(root.bansCount), "banned", root.bansCount > 0 ? root.pal.bad : root.pal.text]]
                                        Btn { label: "Test"; glyph: 0xF0668; onClicked: root.runTest("all") }
                                    }
                                    ModuleCard {
                                        key: "antivirus"; name: "Antivirus"; glyph: 0xF13B6
                                        status: root.avState + (root.av && root.av.mode ? "  ·  " + root.av.mode : "")
                                        tone: root.avColor; available: root.hasAv
                                        readonly property var a: root.av && root.av.alerts_24h ? root.av.alerts_24h : null
                                        figures: [[a ? String((a.critical || 0) + (a.high || 0)) : "-", "high · 24h", a && (a.critical || a.high) ? root.pal.bad : root.pal.text],
                                                  [a ? String(a.medium || 0) : "-", "medium · 24h", a && a.medium ? root.pal.warn : root.pal.text],
                                                  [root.avKnown ? String(root.avUnacked) : "-", "to review", root.avUnacked > 0 ? root.pal.warn : root.pal.text]]
                                        Btn { label: root.scanning ? "Scanning…" : "Scan Downloads"; glyph: 0xF1276; disabled: root.scanning; onClicked: { root.setTab("antivirus"); root.scan("Downloads") } }
                                    }
                                }

                                Section {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    title: "Recent"
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.feed
                                        delegate: ListRow {
                                            required property var modelData
                                            width: ListView.view.width
                                            lead: root.ago(modelData.at)
                                            title: modelData.title
                                            sub: (modelData.who === "firewall" ? "Firewall" : "Antivirus") + "  ·  " + modelData.sub
                                            mark: root.sevColor(modelData.tone)
                                        }
                                    }
                                    Empty { visible: root.feed.length === 0; text: "Quiet" }
                                }
                            }

                            // ---- firewall
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 20
                                visible: root.tab === "firewall" && root.hasFw

                                PageHead {
                                    glyph: 0xF1A11
                                    status: root.fwState
                                    tone: root.fwColor
                                    detail: root.fw === null ? "" : [root.fw.interface || "no uplink", (root.fw.xdp_mode || "-") + " XDP",
                                        "up " + root.dur(Math.max(1, (root.fw.updated_unix || 0) - (root.fw.started_unix || 0))),
                                        "open tcp " + ((root.fw.allow_tcp || []).join(" ") || "none")].join("  ·  ")
                                    Btn { label: "Test"; glyph: 0xF0668; onClicked: root.runTest("all") }
                                    Btn { label: "Doctor"; glyph: 0xF04D9; onClicked: root.consoleRequested("sudo " + root.fwBin + " doctor --fix") }
                                    Btn { label: "Dashboard"; glyph: 0xF0A07; primary: true; onClicked: root.terminalRequested("sudo " + root.shq(root.fwBin) + " top") }
                                }

                                Strip {
                                    Stat { divider: false; label: "Passed"; value: root.count(root.fw ? root.fw.passed : 0); sub: root.fwRate.passed + "/s"; tone: root.pal.good }
                                    Stat { label: "Closed ports"; value: root.count(root.fw ? root.fw.dropped_policy : 0); tone: root.pal.warn }
                                    Stat { label: "From banned"; value: root.count(root.fw ? root.fw.dropped_blocklist : 0); sub: root.bansCount + " banned"; tone: root.pal.bad }
                                    Stat { label: "Blocklists"; value: root.count(root.fw ? root.fw.dropped_feed : 0); sub: root.count(root.fw ? root.fw.feed_networks : 0) + " nets"; tone: root.pal.accent2 }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: root.fwHist.length > 1
                                    RowLayout {
                                        Layout.leftMargin: 4
                                        spacing: 14
                                        Label { text: "Traffic"; Layout.fillWidth: true }
                                        Row { spacing: 5; Dot { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; color: root.pal.accent } Small { text: root.fwRate.passed + "/s in" } }
                                        Row { spacing: 5; Dot { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; color: root.pal.bad } Small { text: root.fwRate.dropped + "/s dropped" } }
                                    }
                                    Spark { Layout.fillWidth: true; implicitHeight: 46; hist: root.fwHist }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 24
                                    Section {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        title: "Bans"
                                        extra: root.fw ? String(root.bansCount) : ""
                                        ListView {
                                            anchors.fill: parent
                                            clip: true
                                            spacing: 2
                                            boundsBehavior: Flickable.StopAtBounds
                                            model: root.fw ? (root.fw.bans || []) : []
                                            delegate: ListRow {
                                                required property var modelData
                                                width: ListView.view.width
                                                mono: true
                                                title: modelData.ip
                                                sub: root.dur(modelData.remaining_secs) + "  ·  " + modelData.reason
                                                mark: modelData.source === "auto" ? root.pal.bad : (modelData.source === "config" ? root.pal.muted : root.pal.warn)
                                                actGlyph: modelData.source !== "config" ? 0xF0156 : 0
                                                actTone: root.pal.bad
                                                onAct: root.consoleRequested("sudo " + root.fwBin + " unban " + modelData.ip)
                                            }
                                        }
                                        Empty { visible: root.bansCount === 0; text: "No bans" }
                                    }
                                    Section {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        title: "Detections"
                                        ListView {
                                            anchors.fill: parent
                                            clip: true
                                            spacing: 2
                                            boundsBehavior: Flickable.StopAtBounds
                                            model: root.fw ? (root.fw.recent || []).slice().sort(function (a, b) { return b.at_unix - a.at_unix }) : []
                                            delegate: ListRow {
                                                required property var modelData
                                                width: ListView.view.width
                                                lead: root.ago(modelData.at_unix)
                                                title: modelData.reason + "  " + modelData.ip + (modelData.enforced ? "" : "  (monitor)")
                                                sub: modelData.ports + "  ·  score " + Number(modelData.score).toFixed(1)
                                                mark: modelData.enforced ? root.pal.bad : root.pal.warn
                                            }
                                        }
                                        Empty { visible: !root.fw || (root.fw.recent || []).length === 0; text: "Nothing detected" }
                                    }
                                }
                            }

                            // ---- antivirus
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 16
                                visible: root.tab === "antivirus" && root.hasAv

                                PageHead {
                                    glyph: 0xF13B6
                                    status: root.avState
                                    tone: root.avColor
                                    detail: root.av === null ? "" : [root.av.mode || "-", "v" + root.av.version,
                                        root.av.last_event_unix ? "last event " + root.ago(root.av.last_event_unix) + " ago" : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                    Btn { label: "Log"; glyph: 0xF018D; onClicked: root.consoleRequested("ai-antivirus tail -f") }
                                    Btn {
                                        readonly property bool aiOn: !!(root.av && root.av.services && root.av.services.analyzer === "active")
                                        label: aiOn ? "AI review: on" : "Turn on AI review"
                                        glyph: 0xF0B79
                                        onClicked: root.consoleRequested("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/antivirus-ai.sh " + (aiOn ? "off" : "on"))
                                    }
                                    Btn { label: "Scan home"; glyph: 0xF02DC; disabled: root.scanning; onClicked: root.scan(".") }
                                    Btn { label: "Scan Downloads"; glyph: 0xF1276; primary: true; disabled: root.scanning; onClicked: root.scan("Downloads") }
                                }

                                // ---- locked: say why, and offer the way out that fits. Replaces the dead "Unreadable" lists.
                                // snapshot: unlocked once with the password; it does not update by itself.
                                Rectangle {
                                    id: lockBar
                                    Layout.fillWidth: true
                                    visible: root.avLocked || root.avSnap
                                    implicitHeight: lbCol.implicitHeight + 32
                                    radius: root.pal.rLg
                                    readonly property color tone: root.avSnap ? root.pal.accent : root.pal.warn
                                    readonly property string why: root.avSnap
                                        ? "Read once with your password, so it does not update by itself. This build keeps its database readable by its own user only (0600) on purpose, so Reload when you want fresh alerts."
                                        : root.avPerm === "" ? "Checking what is blocking it…"
                                        : root.avPerm === "nogroup" ? "This install has no ai-antivirus group, so only root can read the alerts. Unlock once with your password, or run Diagnose to see who owns the files."
                                        : root.avPerm === "notmember" ? "This build keeps its alert database readable only by its own user (0600), on purpose, so being in the ai-antivirus group gives no access. Unlock once with your password to see a snapshot."
                                        : root.avPerm === "stale" ? (root.hasSg ? "This build keeps its alert database readable only by its own user (0600), so the group gives no access. Unlock once with your password to see a snapshot."
                                                                              : "This build keeps its alert database readable only by its own user (0600), so the group gives no access. Unlock once with your password to see a snapshot.")
                                        : "The alert database is readable only by its own user (0600) by design. Unlock once with your password to see a snapshot, or run Diagnose to see the file permissions."
                                    color: Qt.alpha(tone, 0.09)
                                    border.width: 1
                                    border.color: Qt.alpha(tone, 0.25)
                                    ColumnLayout {
                                        id: lbCol
                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                                        spacing: 12
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 14
                                            Rectangle {
                                                Layout.alignment: Qt.AlignTop
                                                width: 40; height: 40; radius: 13
                                                color: Qt.alpha(lockBar.tone, 0.16)
                                                Glyph { anchors.centerIn: parent; code: root.avSnap ? 0xF033F : 0xF033E; font.pixelSize: 20; color: lockBar.tone }
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 4
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: root.avSnap ? "Showing a one-time snapshot" : "Alerts and history are locked for your user"
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody + 1
                                                    font.weight: Font.DemiBold
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: lockBar.why
                                                    wrapMode: Text.Wrap
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody - 1
                                                    lineHeight: 1.15
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: root.avUnlockErr !== ""
                                                    text: "Unlock failed: " + root.avUnlockErr
                                                    wrapMode: Text.Wrap
                                                    color: root.pal.bad
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody - 1
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: !root.avSnap && (root.avActErr !== "" || root.avErr !== "")
                                                    text: root.avActErr !== "" ? root.avActErr : root.avErr
                                                    wrapMode: Text.Wrap
                                                    color: Qt.alpha(root.pal.text, 0.7)
                                                    font.family: root.pal.mono
                                                    font.pixelSize: root.pal.tCap
                                                }
                                            }
                                        }
                                        Flow {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 54
                                            spacing: 8
                                            Btn {
                                                visible: false
                                                primary: true
                                                label: root.avSnap ? "Fix for good" : "Add me to the group"
                                                glyph: 0xF0004
                                                onClicked: root.consoleRequested(root.avJoinCmd)
                                            }
                                            Btn {
                                                primary: true
                                                label: root.avUnlockStep === "agent" ? "Starting the password window…" : (root.avUnlockStep === "password" ? "Waiting for the password…" : (root.avSnap ? "Reload (password)" : "Unlock once with password"))
                                                glyph: 0xF0306
                                                disabled: root.avUnlockStep !== ""
                                                onClicked: root.avUnlock()
                                            }
                                            Btn {
                                                visible: root.avUnlockErr !== ""
                                                label: "Do it in the console (sudo)"
                                                glyph: 0xF018D
                                                onClicked: root.consoleRequested(root.avSudoCmd)
                                            }
                                            Btn { label: "Retry"; glyph: 0xF0450; onClicked: root.avTick() }
                                            Btn { label: "Diagnose"; glyph: 0xF018D; onClicked: root.consoleRequested(root.avDiagCmd) }
                                        }
                                    }
                                }

                                Strip {
                                    id: avStrip
                                    readonly property var a: root.av && root.av.alerts_24h ? root.av.alerts_24h : null
                                    Stat { divider: false; label: "Critical · 24h"; value: avStrip.a ? String(avStrip.a.critical) : "–"; sub: avStrip.a ? "" : (root.avLocked ? "locked" : ""); tone: avStrip.a && avStrip.a.critical > 0 ? root.pal.bad : (avStrip.a ? root.pal.text : root.pal.muted) }
                                    Stat { label: "High · 24h"; value: avStrip.a ? String(avStrip.a.high) : "–"; tone: avStrip.a && avStrip.a.high > 0 ? Qt.lighter(root.pal.bad, 1.15) : (avStrip.a ? root.pal.text : root.pal.muted) }
                                    Stat { label: "Medium · 24h"; value: avStrip.a ? String(avStrip.a.medium) : "–"; tone: avStrip.a && avStrip.a.medium > 0 ? root.pal.warn : (avStrip.a ? root.pal.text : root.pal.muted) }
                                    Stat { label: "To review"; value: root.avKnown ? String(root.avUnacked) : "–"; sub: root.avPending > 0 ? root.avPending + " waiting for your OK" : (root.av && root.av.pending_actions ? root.av.pending_actions + " pending" : ""); tone: root.avKnown ? (root.avUnacked > 0 ? root.pal.warn : root.pal.text) : root.pal.muted }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Repeater {
                                        model: root.av && root.av.services ? Object.keys(root.av.services) : []
                                        delegate: Rectangle {
                                            id: svc
                                            required property string modelData
                                            readonly property string st: root.av && root.av.services ? root.av.services[modelData] : ""
                                            readonly property color tone: st === "active" ? root.pal.good : (st === "failed" ? root.pal.bad : root.pal.muted)
                                            implicitWidth: svcRow.implicitWidth + 20
                                            implicitHeight: 26
                                            radius: height / 2
                                            color: root.pal.fill
                                            Row {
                                                id: svcRow
                                                anchors.centerIn: parent
                                                spacing: 7
                                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: svc.tone }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: svc.modelData; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
                                            }
                                        }
                                    }
                                    Rectangle {
                                        visible: root.av !== null && root.av.breaker_open === true
                                        implicitWidth: brRow.implicitWidth + 20
                                        implicitHeight: 26
                                        radius: height / 2
                                        color: root.pal.fill
                                        Row {
                                            id: brRow
                                            anchors.centerIn: parent
                                            spacing: 7
                                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: root.pal.warn }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "breaker open"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
                                        }
                                    }
                                }

                                // the scan, while it runs and after
                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: root.scanning || root.scanSum !== null
                                    implicitHeight: scCol.implicitHeight + 28
                                    radius: root.pal.rLg
                                    readonly property color tone: root.scanning ? root.pal.accent : (root.scanSum && root.scanSum.failed ? root.pal.bad : (root.scanFound.length > 0 ? root.pal.bad : root.pal.good))
                                    color: Qt.alpha(tone, 0.07)
                                    Column {
                                        id: scCol
                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; leftMargin: 18 }
                                        spacing: 8
                                        RowLayout {
                                            width: parent.width
                                            spacing: 10
                                            Working { visible: root.scanning }
                                            Glyph { visible: !root.scanning; code: root.scanFound.length > 0 || (root.scanSum !== null && root.scanSum.failed) ? 0xF0026 : 0xF05E0; color: parent.parent.parent.tone }
                                            Text {
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody - 1
                                                font.weight: Font.Medium
                                                text: root.scanning ? "Scanning ~/" + (root.scanWhat === "." ? "" : root.scanWhat)
                                                    : (root.scanSum === null ? "" : root.scanSum.failed ? "Scan failed"
                                                    : (root.scanFound.length > 0 ? root.scanFound.length + " found" : "Clean") + "  ·  " + root.count(root.scanSum.files) + " files in " + root.scanSum.seconds + " s")
                                            }
                                            RowIcon { visible: !root.scanning; glyph: 0xF0156; onClicked: { root.scanSum = null; root.scanFound = [] } }
                                        }
                                        Repeater {
                                            model: root.scanFound.slice(0, 5)
                                            delegate: Row {
                                                required property var modelData
                                                spacing: 10
                                                Text { id: fPath; text: modelData.path.charAt(0) === "/" ? modelData.path.replace(/^\/home\/[^/]+\//, "~/") : "~/" + modelData.path; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap + 1; width: Math.min(implicitWidth, scCol.width * 0.55); elide: Text.ElideMiddle }
                                                Small { text: (modelData.findings || []).map(function (f) { return f.detail || f.kind }).join(", "); color: root.pal.bad; width: scCol.width - fPath.width - 10 }
                                            }
                                        }
                                    }
                                }

                                // what the antivirus held back, quarantined, froze or isolated (the notifications point here). Always on this page, so a
                                // quarantined file can be found and restored from here (the ↶ button: `ai-antivirus undo <id>`, in the console with sudo)
                                Section {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: root.avHeld.length === 0 ? 62 : 34 + 50 * Math.min(4, root.avHeld.length)
                                    title: "Held back, quarantined and isolated"
                                    extra: root.avPending > 0 ? root.avPending + " waiting for your OK" : (root.avHeld.length > 0 ? String(root.avHeld.length) : "")
                                    action: root.avSnap ? "Reload (password)" : (root.avLocked ? "Unlock with password" : "Full list")
                                    onActed: { if (root.avSnap || root.avLocked) root.avUnlock(); else root.consoleRequested("ai-antivirus actions -n 100") }
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.avHeld
                                        delegate: ListRow {
                                            required property var modelData
                                            readonly property bool waiting: modelData.status === "pending"
                                            readonly property bool undoable: modelData.status === "executed" && modelData.action !== "kill"
                                            width: ListView.view.width
                                            title: root.actVerb(modelData)
                                            sub: [root.actTarget(modelData.target), modelData.rule_id || "", root.ago(modelData.ts_ns / 1e9) + " ago",
                                                  undoable ? "↶ undo" + (modelData.action === "quarantine" ? " restores the file" : "") : "",
                                                  modelData.error ? "error: " + modelData.error : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                            mark: root.actTone(modelData)
                                            chip: waiting ? "Needs OK" : (modelData.status === "dry_run" ? "Alert-only" : (modelData.status === "executed" ? "Done" : root.cap(modelData.status)))
                                            chipTone: root.actTone(modelData)
                                            actAlways: waiting || undoable
                                            // pending: Approve (✓) and Reject (✕); done: Undo (restore the file, thaw, lift the block). Each opens the console (sudo).
                                            actGlyph: waiting ? 0xF012C : (undoable ? 0xF054C : 0)
                                            actTone: waiting ? root.pal.good : root.pal.accent
                                            act2Glyph: waiting ? 0xF0156 : 0
                                            act2Tone: root.pal.bad
                                            onAct: root.actRun(waiting ? "approve" : "undo", modelData.id)
                                            onAct2: root.actRun("reject", modelData.id)
                                        }
                                    }
                                    // an empty list that takes one line, not a page (a plain Row: no inline component of its own)
                                    Row {
                                        visible: root.avHeld.length === 0
                                        anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                                        spacing: 10
                                        Glyph { anchors.verticalCenter: parent.verticalCenter; code: root.avLocked ? 0xF033E : 0xF0565; font.pixelSize: 18; color: Qt.alpha(root.avLocked ? root.pal.warn : root.pal.good, 0.8) }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.avLocked ? "Locked: unlock it above to see what was held back" : "Nothing held back"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1 }
                                    }
                                }

                                Section {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    title: "Alerts"
                                    extra: root.avAlerts.length > 0 ? String(root.avAlerts.length) : ""
                                    action: root.avAlerts.length > 1 ? "Acknowledge all" : ""
                                    onActed: root.ack("all")
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.avAlerts
                                        delegate: ListRow {
                                            required property var modelData
                                            width: ListView.view.width
                                            title: modelData.title
                                            sub: [modelData.rule_id || "", root.ago(modelData.ts_ns / 1e9) + " ago",
                                                  modelData.detail && modelData.detail.exe ? modelData.detail.exe : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                            mark: root.sevColor(modelData.severity)
                                            chip: root.cap(modelData.severity)
                                            chipTone: root.sevColor(modelData.severity)
                                            actGlyph: 0xF012C
                                            actTone: root.pal.good
                                            onAct: root.ack([modelData.id])
                                        }
                                    }
                                    Empty {
                                        visible: root.avAlerts.length === 0
                                        text: root.avKnown ? "All clear" : (root.avLocked ? "Locked: unlock it above to see the alerts" : "Unreadable")
                                        tone: root.avKnown ? root.pal.good : root.pal.warn
                                        glyph: root.avKnown ? 0xF0565 : 0xF033E
                                    }
                                }
                            }

                            // ---- ClamAV: test it, scan with it, and the fixes
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 18
                                visible: root.tab === "clamav" && root.hasClam

                                PageHead {
                                    glyph: 0xF0668
                                    status: root.clamState
                                    tone: root.clamColor
                                    detail: root.clamErr !== "" ? root.clamErr
                                        : (root.clam === null ? "Checks the signatures, the updater and that ClamAV detects a harmless test file"
                                        : root.clam.headline)
                                    Btn { label: "Test ClamAV"; glyph: 0xF0668; disabled: root.clamBusy; onClicked: root.clamRun("test", "") }
                                    Btn { label: "Exceptions"; glyph: 0xF0780; disabled: root.clamBusy; onClicked: root.clamRun("exceptions", "") }
                                    Btn { label: "Scan Downloads"; glyph: 0xF1276; primary: true; disabled: root.clamBusy; onClicked: root.clamRun("scan", "Downloads") }
                                }

                                Working { visible: root.clamBusy }

                                // the model's short summary, marked as such (the headline above is from fixed rules)
                                Small {
                                    Layout.fillWidth: true
                                    visible: !root.clamBusy && root.clam !== null && root.clam.ai === true && (root.clam.summary || "") !== ""
                                    text: "AI: " + (root.clam ? root.clam.summary : "")
                                    wrapMode: Text.Wrap
                                }

                                // test: one row per check
                                Column {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: !root.clamBusy && root.clam !== null && root.clam.kind === "test"
                                    Repeater {
                                        model: root.clam && root.clam.checks ? root.clam.checks : []
                                        delegate: Row {
                                            required property var modelData
                                            spacing: 9
                                            Dot { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 4; color: modelData.ok ? root.pal.good : root.pal.bad }
                                            Text { text: modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1 }
                                            Small { anchors.verticalCenter: parent.verticalCenter; text: modelData.detail }
                                        }
                                    }
                                }

                                // scan: what was found
                                Column {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    visible: !root.clamBusy && root.clam !== null && root.clam.kind === "scan" && (root.clam.found || []).length > 0
                                    Repeater {
                                        model: root.clam && root.clam.found ? root.clam.found.slice(0, 8) : []
                                        delegate: Row {
                                            required property var modelData
                                            spacing: 10
                                            Text { id: cfP; text: modelData.file.replace(/^\/home\/[^/]+\//, "~/"); color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap + 1; width: Math.min(implicitWidth, 460); elide: Text.ElideMiddle }
                                            Small { text: modelData.signature; color: root.pal.bad }
                                            Small { visible: (modelData.note || "") !== ""; text: modelData.status.replace("_", " ") + ": " + modelData.note }
                                        }
                                    }
                                }

                                // scan: what the model judged a false positive (hash-pinned exceptions, removable on the Exceptions button)
                                Small {
                                    Layout.fillWidth: true
                                    visible: !root.clamBusy && root.clam !== null && root.clam.kind === "scan" && (root.clam.excepted || []).length > 0
                                    wrapMode: Text.Wrap
                                    text: (root.clam && root.clam.excepted ? root.clam.excepted.map(function (e) { return e.file.replace(/^\/home\/[^/]+\//, "~/") + (e.note ? " (" + e.note + ")" : "") }).slice(0, 6).join("  ·  ") : "")
                                }

                                // exceptions: one row each, with a way to forget it
                                Section {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: !root.clamBusy && root.clam !== null && root.clam.kind === "exceptions"
                                    title: "ClamAV exceptions"
                                    extra: root.clam && root.clam.exceptions ? String(root.clam.exceptions.length) : ""
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.clam && root.clam.exceptions ? root.clam.exceptions : []
                                        delegate: ListRow {
                                            required property var modelData
                                            required property int index
                                            width: ListView.view.width
                                            title: modelData.path.replace(/^\/home\/[^/]+\//, "~/") + "  ·  " + modelData.signature
                                            sub: modelData.by + " " + (modelData.added || "") + (modelData.reason ? "  ·  " + modelData.reason : "")
                                            mark: root.pal.muted
                                            actGlyph: 0xF0156
                                            actTone: root.pal.accent
                                            onAct: root.clamForget(index + 1)
                                        }
                                    }
                                    Empty { visible: !root.clam || !root.clam.exceptions || root.clam.exceptions.length === 0; text: "No exceptions"; tone: root.pal.muted; glyph: 0xF0780 }
                                }

                                Section {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.clam === null || root.clam.kind !== "exceptions"
                                    title: "Fixes"
                                    extra: root.clam && root.clam.fixes ? String(root.clam.fixes.length) : ""
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.clam && root.clam.fixes ? root.clam.fixes : []
                                        delegate: ListRow {
                                            required property var modelData
                                            width: ListView.view.width
                                            title: modelData.title + "  ·  " + modelData.cmd
                                            sub: modelData.why
                                            mark: root.pal.warn
                                            actGlyph: root.runnable(modelData.cmd) ? 0xF018D : 0
                                            actTone: root.pal.accent
                                            onAct: root.consoleRequested(modelData.cmd)
                                        }
                                    }
                                    Empty {
                                        visible: !root.clamBusy && (root.clam === null || (root.clam.fixes || []).length === 0)
                                        text: root.clam === null ? "Run a test or a scan" : "Nothing to fix"
                                        tone: root.clam === null ? root.pal.muted : root.pal.good
                                        glyph: root.clam === null ? 0xF0668 : 0xF0565
                                    }
                                }
                            }

                            // ---- exceptions
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 18
                                visible: root.tab === "exceptions" && root.hasAv

                                PageHead {
                                    glyph: 0xF0780
                                    status: root.exc === null ? "Exceptions" : root.excList.length + (root.excList.length === 1 ? " exception" : " exceptions")
                                    tone: root.pal.accent
                                    detail: root.exc === null ? "" : (root.exc.from_file ? root.exc.file : "Defaults")
                                    Btn { label: "Defaults"; glyph: 0xF0450; disabled: root.exc === null || !root.exc.from_file; onClicked: root.excChange(["reset"]) }
                                }

                                // add: kind, match, label
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Rectangle {
                                        implicitWidth: ekRow.implicitWidth + 8
                                        implicitHeight: 40
                                        radius: 20
                                        color: root.pal.fill
                                        Row {
                                            id: ekRow
                                            anchors.centerIn: parent
                                            spacing: 2
                                            Repeater {
                                                model: [{ k: "program", l: "Program", g: 0xF018D }, { k: "folder", l: "Folder", g: 0xF024B }]
                                                delegate: Rectangle {
                                                    id: ek
                                                    required property var modelData
                                                    readonly property bool on: root.excKind === modelData.k
                                                    width: ekIn.implicitWidth + 24
                                                    height: 32
                                                    radius: 16
                                                    color: on ? Qt.alpha(root.pal.accent, 0.2) : (ekMa.containsMouse ? root.pal.fill : "transparent")
                                                    Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                                    Row {
                                                        id: ekIn
                                                        anchors.centerIn: parent
                                                        spacing: 7
                                                        Glyph { anchors.verticalCenter: parent.verticalCenter; code: ek.modelData.g; font.pixelSize: 14; color: ek.on ? root.pal.accent : root.pal.muted }
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: ek.modelData.l; color: ek.on ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: ek.on ? Font.DemiBold : Font.Medium }
                                                    }
                                                    MouseArea { id: ekMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.excKind = ek.modelData.k }
                                                }
                                            }
                                        }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        implicitHeight: 40
                                        radius: 20
                                        color: root.pal.fill
                                        border.width: 1
                                        border.color: exMatch.activeFocus ? root.pal.lineFocus : "transparent"
                                        TextInput {
                                            id: exMatch
                                            anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                            color: root.pal.text
                                            selectionColor: Qt.alpha(root.pal.accent, 0.35)
                                            font.family: root.pal.mono
                                            font.pixelSize: root.pal.tBody - 1
                                            clip: true
                                            maximumLength: 256
                                            Text { visible: parent.text === "" && !parent.activeFocus; text: root.excKind === "folder" ? "~/folder" : "name or /path"; color: root.pal.muted; font: parent.font }
                                            Keys.onReturnPressed: exAdd.go()
                                            Keys.onEnterPressed: exAdd.go()
                                            Keys.onTabPressed: exName.forceActiveFocus()
                                            Keys.onEscapePressed: root.hide()
                                        }
                                    }
                                    Rectangle {
                                        Layout.preferredWidth: 180
                                        implicitHeight: 40
                                        radius: 20
                                        color: root.pal.fill
                                        border.width: 1
                                        border.color: exName.activeFocus ? root.pal.lineFocus : "transparent"
                                        TextInput {
                                            id: exName
                                            anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                            color: root.pal.text
                                            selectionColor: Qt.alpha(root.pal.accent, 0.35)
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody - 1
                                            clip: true
                                            maximumLength: 80
                                            Text { visible: parent.text === "" && !parent.activeFocus; text: "Label"; color: root.pal.muted; font: parent.font }
                                            Keys.onReturnPressed: exAdd.go()
                                            Keys.onEnterPressed: exAdd.go()
                                            Keys.onBacktabPressed: exMatch.forceActiveFocus()
                                            Keys.onEscapePressed: root.hide()
                                        }
                                    }
                                    Btn {
                                        id: exAdd
                                        label: "Add"
                                        glyph: 0xF0415
                                        primary: true
                                        disabled: exMatch.text.trim() === "" || excEdit.running
                                        function go() { if (disabled) return; root.excAdd(root.excKind, exMatch.text, exName.text); exMatch.text = ""; exName.text = "" }
                                        onClicked: go()
                                    }
                                }

                                Section {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    title: "Left alone"
                                    extra: root.excList.length > 0 ? String(root.excList.length) : ""
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.excList
                                        delegate: ListRow {
                                            required property var modelData
                                            width: ListView.view.width
                                            title: modelData.name !== "" ? modelData.name : modelData.match
                                            sub: [modelData.kind === "folder" ? "Folder" : "Program", modelData.match, modelData["default"] ? "default" : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                            mark: modelData.kind === "folder" ? root.pal.accent2 : root.pal.accent
                                            actGlyph: 0xF0156
                                            actTone: root.pal.bad
                                            onAct: root.excChange(["remove", modelData.match])
                                        }
                                    }
                                    Empty { visible: root.exc !== null && root.excList.length === 0; text: "None"; tone: root.pal.muted; glyph: 0xF0780 }
                                }
                            }

                            // ---- ask
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 14
                                visible: root.tab === "ask" && (root.hasFw || root.hasAv)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    // which module answers: a two-way switch
                                    Rectangle {
                                        implicitWidth: tgRow.implicitWidth + 8
                                        implicitHeight: 36
                                        radius: 18
                                        color: root.pal.fill
                                        Row {
                                            id: tgRow
                                            anchors.centerIn: parent
                                            spacing: 2
                                            Repeater {
                                                model: [{ k: "firewall", l: "Firewall", g: 0xF1A11, ok: root.hasFw }, { k: "antivirus", l: "Antivirus", g: 0xF13B6, ok: root.hasAv }]
                                                delegate: Rectangle {
                                                    id: tg
                                                    required property var modelData
                                                    readonly property bool on: root.askTarget === modelData.k
                                                    visible: modelData.ok
                                                    width: tgIn.implicitWidth + 26
                                                    height: 28
                                                    radius: 14
                                                    color: on ? Qt.alpha(root.pal.accent, 0.2) : (tgMa.containsMouse ? root.pal.fill : "transparent")
                                                    Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                                    Row {
                                                        id: tgIn
                                                        anchors.centerIn: parent
                                                        spacing: 7
                                                        Glyph { anchors.verticalCenter: parent.verticalCenter; code: tg.modelData.g; font.pixelSize: 14; color: tg.on ? root.pal.accent : root.pal.muted }
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: tg.modelData.l; color: tg.on ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: tg.on ? Font.DemiBold : Font.Medium }
                                                    }
                                                    MouseArea { id: tgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.askTarget = tg.modelData.k }
                                                }
                                            }
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Small { visible: root.model !== ""; text: root.model; Layout.maximumWidth: 260 }
                                }

                                ListView {
                                    id: chat
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 16
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.msgs.length    // a number, not the array: every streamed chunk replaces root.msgs, and an array model would rebuild every bubble (the twitching)
                                    onCountChanged: Qt.callLater(function () { chat.positionViewAtEnd() })
                                    onContentHeightChanged: if (root.asking) chat.positionViewAtEnd()
                                    footer: Item {
                                        width: chat.width
                                        height: root.asking ? 30 : 0
                                        Working { visible: root.asking; anchors.verticalCenter: parent.verticalCenter; x: 2 }
                                    }
                                    delegate: Item {
                                        id: mItem
                                        required property int index
                                        readonly property var modelData: root.msgs[index] || ({})
                                        width: chat.width
                                        height: mCol.implicitHeight

                                        Column {
                                            id: mCol
                                            width: parent.width
                                            spacing: 8

                                            // you: a bubble on the right
                                            Rectangle {
                                                visible: mItem.modelData.role === "you"
                                                anchors.right: parent.right
                                                width: Math.min(youT.implicitWidth + 28, parent.width * 0.8)
                                                height: youT.implicitHeight + 16
                                                radius: 16
                                                color: Qt.alpha(root.pal.accent, 0.16)
                                                SelText {
                                                    id: youT
                                                    anchors { fill: parent; leftMargin: 14; rightMargin: 14; topMargin: 8; bottomMargin: 8 }
                                                    wrapMode: TextEdit.Wrap
                                                    text: mItem.modelData.text || ""
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                }
                                            }

                                            // the answer
                                            SelText {
                                                visible: mItem.modelData.role === "ai" && (mItem.modelData.text || "") !== ""
                                                width: parent.width
                                                wrapMode: TextEdit.Wrap
                                                textFormat: TextEdit.PlainText
                                                text: (mItem.modelData.text || "") + (mItem.modelData.live ? " ▍" : "")
                                                color: mItem.modelData.bad ? root.pal.bad : root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                            }

                                            // suggested actions: one click each (root ones open in the console)
                                            Flow {
                                                visible: mItem.modelData.role === "ai" && (mItem.modelData.actions || []).length > 0
                                                width: parent.width
                                                spacing: 6
                                                Repeater {
                                                    model: mItem.modelData.actions || []
                                                    delegate: Btn {
                                                        required property var modelData
                                                        label: modelData.describe
                                                        glyph: modelData.test ? 0xF0668 : 0xF040C
                                                        onClicked: root.act(modelData)
                                                    }
                                                }
                                            }

                                            // live test results
                                            Repeater {
                                                model: mItem.modelData.role === "test" ? (mItem.modelData.reports || []) : []
                                                delegate: Rectangle {
                                                    id: rep
                                                    required property var modelData
                                                    width: mCol.width
                                                    height: repCol.implicitHeight + 24
                                                    radius: root.pal.rMd
                                                    color: Qt.alpha(rep.modelData.ok ? root.pal.good : root.pal.bad, 0.07)
                                                    Column {
                                                        id: repCol
                                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 14 }
                                                        spacing: 6
                                                        Row {
                                                            spacing: 8
                                                            Glyph { anchors.verticalCenter: parent.verticalCenter; code: rep.modelData.ok ? 0xF05E0 : 0xF0026; color: rep.modelData.ok ? root.pal.good : root.pal.bad }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; text: rep.modelData.test; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold }
                                                            Small { anchors.verticalCenter: parent.verticalCenter; text: rep.modelData.summary }
                                                        }
                                                        GridLayout {
                                                            width: parent.width
                                                            columns: 2
                                                            columnSpacing: 16
                                                            rowSpacing: 3
                                                            Repeater {
                                                                model: rep.modelData.stats || []
                                                                delegate: Small {
                                                                    required property var modelData
                                                                    required property int index
                                                                    Layout.row: index
                                                                    Layout.column: 0
                                                                    leftPadding: 24
                                                                    text: modelData[0]
                                                                }
                                                            }
                                                            Repeater {
                                                                model: rep.modelData.stats || []
                                                                delegate: Text {
                                                                    required property var modelData
                                                                    required property int index
                                                                    Layout.row: index
                                                                    Layout.column: 1
                                                                    Layout.fillWidth: true
                                                                    elide: Text.ElideRight
                                                                    text: modelData[1]
                                                                    color: root.pal.text
                                                                    font.family: root.pal.mono
                                                                    font.pixelSize: root.pal.tCap + 1
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // live tests: the firewall only
                                Flow {
                                    Layout.fillWidth: true
                                    visible: root.askTarget === "firewall" && root.hasFw
                                    spacing: 6
                                    Repeater {
                                        model: root.tests
                                        delegate: Rectangle {
                                            id: tc
                                            required property string modelData
                                            implicitWidth: tcRow.implicitWidth + 22
                                            implicitHeight: 28
                                            radius: 14
                                            opacity: root.asking ? 0.4 : 1
                                            color: tcMa.containsMouse && !root.asking ? Qt.alpha(root.pal.accent, 0.16) : root.pal.fill
                                            Row {
                                                id: tcRow
                                                anchors.centerIn: parent
                                                spacing: 6
                                                Glyph { anchors.verticalCenter: parent.verticalCenter; code: 0xF0668; font.pixelSize: 12; color: tcMa.containsMouse ? root.pal.accent : root.pal.muted }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: tc.modelData; color: tcMa.containsMouse ? root.pal.accent : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1 }
                                            }
                                            MouseArea { id: tcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (!root.asking) root.runTest(tc.modelData) }
                                        }
                                    }
                                }

                                // the question
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 50
                                    radius: 25
                                    color: root.pal.fill
                                    border.width: 1
                                    border.color: askIn.activeFocus ? root.pal.lineFocus : "transparent"
                                    Behavior on border.color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                    Glyph { id: askG; x: 18; anchors.verticalCenter: parent.verticalCenter; code: root.askTarget === "firewall" ? 0xF1A11 : 0xF13B6; color: root.pal.accent }
                                    TextInput {
                                        id: askIn
                                        anchors { left: askG.right; leftMargin: 12; right: send.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                        color: root.pal.text
                                        selectionColor: Qt.alpha(root.pal.accent, 0.35)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        clip: true
                                        enabled: !root.asking
                                        Keys.onReturnPressed: { root.ask(text); text = "" }
                                        Keys.onEnterPressed: { root.ask(text); text = "" }
                                        Keys.onEscapePressed: root.hide()
                                    }
                                    Rectangle {
                                        id: send
                                        anchors { right: parent.right; rightMargin: 7; verticalCenter: parent.verticalCenter }
                                        width: 36; height: 36; radius: 18
                                        readonly property bool ready: askIn.text.trim() !== "" && !root.asking
                                        color: ready ? root.pal.accent : "transparent"
                                        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                                        Glyph { anchors.centerIn: parent; code: 0xF048A; font.pixelSize: 16; color: send.ready ? root.pal.bg : root.pal.muted }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ask(askIn.text); askIn.text = "" } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
