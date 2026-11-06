import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
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
    property bool popped: false             // "Pop out": only this open window is an ordinary window; forgotten once it has closed (Settings > Windows is separate)
    readonly property bool deskMode: pal.deskWin || popped
    readonly property bool asWindow: open && deskMode        // an ordinary window (Settings > Halcyon windows or Pop out): Super+Q and opening another centre leave it alone (shell.qml)
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
    // ---- the rest of what the Firewall Center showed, now sub-pages of the Firewall page: Rules, Feeds, History, Doctor
    property string fwSub: "live"            // live | rules | feeds | history | doctor
    property var fwLog: []                   // what ai-firewall did (bans, lifts, profile switches, feed updates), newest first
    property var fwFindings: []              // the doctor's findings
    property bool fwDoctorRan: false
    function fwSubGo(k) {
        fwSub = k
        if (k === "history" && !fwHistProc.running) fwHistProc.running = true
        if (k === "doctor" && !fwDoctorRan && !fwDoctorProc.running) fwDoctorProc.running = true
    }
    // `sudo ai-firewall <args>` in the console. Only plain words reach the shell: everything here is built from the daemon's own status,
    // the doctor's fixed fix ids or validated input, but the console runs bash, so it is checked once more.
    function sudoThen(args) {
        args = String(args).trim()
        if (!/^[A-Za-z0-9 ._:\/-]+$/.test(args)) return
        consoleRequested("sudo " + fwBin + " " + args)
    }
    Process {
        id: fwHistProc
        command: [root.fwBin, "history", "--json", "-n", "200"]
        stdout: StdioCollector { onStreamFinished: { try { root.fwLog = JSON.parse(text).reverse() } catch (e) { root.fwLog = [] } } }
    }
    Process {
        id: fwDoctorProc
        command: [root.fwBin, "doctor", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { root.fwFindings = JSON.parse(text).findings || [] } catch (e) { root.fwFindings = [] } root.fwDoctorRan = true } }
    }
    Timer { interval: 5000; repeat: true; running: root.open && root.hasFw && root.tab === "firewall" && root.fwSub === "history"; triggeredOnStart: true; onTriggered: if (!fwHistProc.running) fwHistProc.running = true }
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
    property string avAlertsRaw: ""          // the last text the poll read: an unchanged answer leaves the list (and its scroll place) alone
    property string avActionsRaw: ""
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

    // the three reads the 6 s poll repeats (status, unacknowledged alerts, action log): cut off after 8 s. A read that hung (the engine
    // holding the database, a stuck sg) kept its Process "running" for ever, the poll skips a running one, and so the lists stopped
    // updating until the shell was restarted. sg already has its own timeout; the plain call had none.
    function avRead(args) {
        return avViaSg ? avCmd(args) : ["timeout", "8", "ai-antivirus"].concat(args)
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
        command: root.avRead(["status", "--json"])
        stdout: StdioCollector { onStreamFinished: root.avGotStatus(text) }
        stderr: StdioCollector { onStreamFinished: root.avErr = text.trim().replace(/^error: /i, "").split("\n")[0] }
    }
    Process {
        id: avAlertsProc
        command: root.avRead(["alerts", "--unacked", "--json", "-n", "40"])
        stdout: StdioCollector { onStreamFinished: { if (!root.avSnap && text !== root.avAlertsRaw) { root.avAlertsRaw = text; root.avAlerts = root.parseAlerts(text) } } }
    }
    Process {
        id: avAckProc
        property var ackIds: []
        stdout: StdioCollector { onStreamFinished: if (text.trim() !== "") root.flash(text.trim(), false) }
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.flash(text.trim().replace(/^error: /, ""), true) }
        onExited: code => {
            if (root.reviewAckState === 1) root.reviewAckState = code === 0 ? 2 : 3     // the AI's clearing, from Let AI decide
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
    // ---- the Antivirus page's lists: the same alert many times (one file in many places) is ONE row with a count, worst first;
    // a click opens the places. The held list is folded the same way. A filter by severity sits above.
    property string avView: "alerts"         // alerts | held
    property string avSev: "all"             // all | critical | high | medium
    property var avOpenKeys: ({})
    function toggleOpen(k) { var m = Object.assign({}, avOpenKeys); m[k] = !m[k]; avOpenKeys = m }
    function sevRank(s) { return s === "critical" ? 4 : (s === "high" ? 3 : (s === "medium" ? 2 : 1)) }
    function rawOf(a) { var d = a.detail || {}; return String(d.exe || d.path || d.file || "") }
    function whereOf(a) { var d = a.detail || {}; return String(d.exe || d.path || d.file || d.cmdline || d.target || d.dst || "").replace(/^\/home\/[^/]+\//, "~/") }
    readonly property var avSevN: {
        var n = { all: avAlerts.length, critical: 0, high: 0, medium: 0 }
        avAlerts.forEach(function (a) { if (n[a.severity] !== undefined) n[a.severity]++ })
        return n
    }
    readonly property string avSevEff: avSev === "all" || (avSevN[avSev] || 0) > 0 ? avSev : "all"    // a filter that emptied itself falls back to all
    function groupAlerts(list, sev) {
        var map = {}, order = []
        list.forEach(function (a) {
            if (sev !== "all" && a.severity !== sev) return
            var k = (a.rule_id || "") + "|" + (a.title || "")
            var g = map[k]
            if (!g) { g = map[k] = { key: k, title: a.title, rule_id: a.rule_id, severity: a.severity, count: 0, ts: 0, ids: [], where: [], raw: [] }; order.push(g) }
            g.count++; g.ids.push(a.id)
            var t = a.ts_ns / 1e9
            if (t > g.ts) g.ts = t
            if (sevRank(a.severity) > sevRank(g.severity)) g.severity = a.severity
            var w = whereOf(a)
            if (w !== "" && g.where.length < 12 && g.where.indexOf(w) < 0) g.where.push(w)
            var r = rawOf(a)
            if (r.charAt(0) === "/" && g.raw.length < 12 && g.raw.indexOf(r) < 0) g.raw.push(r)
        })
        order.sort(function (x, y) { return (sevRank(y.severity) - sevRank(x.severity)) || (y.ts - x.ts) })
        return order
    }
    function groupHeld(list) {
        var map = {}, order = []
        list.forEach(function (a) {
            var k = a.status === "pending" ? "p" + a.id : (a.action + "|" + a.status + "|" + (a.rule_id || ""))
            var g = map[k]
            if (!g) { g = map[k] = { key: k, a: a, count: 0, ts: 0, where: [], errs: [] }; order.push(g) }
            g.count++
            var t = a.ts_ns / 1e9
            if (t > g.ts) g.ts = t
            var w = actTarget(a.target)
            if (w !== "" && g.where.length < 12 && g.where.indexOf(w) < 0) g.where.push(w)
            if (a.error && g.errs.length < 1) g.errs.push(String(a.error))
        })
        order.sort(function (x, y) { return ((y.a.status === "pending" ? 1 : 0) - (x.a.status === "pending" ? 1 : 0)) || (y.ts - x.ts) })
        return order
    }
    readonly property var avGroups: groupAlerts(avAlerts, avSevEff)
    readonly property var avHeldGroups: groupHeld(avHeld)
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
        command: root.avRead(["actions", "--json", "-n", "60"])
        stdout: StdioCollector { onStreamFinished: { if (!root.avSnap && text !== root.avActionsRaw) { root.avActionsRaw = text; root.avActions = root.parseActs(text) } } }
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
    readonly property string avSudoCmd: "sudo /bin/sh -c " + shq(shq(avBin) + " alerts --unacked -n 40; " + shq(avBin) + " actions -n 100")   // one sudo, so one password prompt
    function avRootFinish() {
        if (!avRootExited || !avRootOutDone || !avRootErrDone) return
        avRootExited = false                                // handle one run once
        avUnlockStep = ""
        if (avCancelled) { avCancelled = false; return }    // the watchdog or Cancel stopped it: its message is already shown
        if (avPkHidden) show("antivirus")                   // only the pkexec route hides this window, and never bring it over the console
        avPkHidden = false
        var code = avRootCode, errLine = avRootErrT.trim().replace(/^error: /i, "").split("\n")[0]
        if (avRepairing) {
            avRepairing = false
            avPwAction = "unlock"
            if (code !== 0 && /incorrect password|try again|no password/i.test(avRootErrT)) {
                pwRefused()
                avUnlockErr = "That password did not work. Try again."
                avPwAction = "repair"
                avAskPw = true
                pwFocusRequested()
                return
            }
            if (code === 0) {
                pwAccepted()
                avUnlockErr = ""
                avActErr = ""; avErr = ""
                avSnap = false; avSnapStatus = null
                flash("History repaired. Unlock again to read the new alerts.", false)
                avTick()
            } else {
                avUnlockErr = "The repair did not finish" + (errLine !== "" ? ": " + errLine : " (exit " + code + ")")
                flash(avUnlockErr, true)
            }
            return
        }
        var snap = null
        if (code === 0) snap = parseSnap(avRootOutT)
        if (snap && snap.status) {
            pwAccepted()
            avUnlockErr = ""
            avAskPw = false
            avSnapAt = Date.now()
            avSnapStatus = snap.status
            avSnap = true
            avAlerts = snap.alerts
            avActions = snap.actions
            avActErr = ""; avErr = ""
            av = mergeSnap(av ? Object.assign({}, av) : Object.assign({}, snap.status))
            return
        }
        if (avUnlockVia === "sudo") { avSudoFail(code, avRootErrT); return }
        if (code === 126) avUnlockErr = "The password window was closed without a password."
        else if (/not authorized/i.test(errLine) && !/agent/i.test(errLine))
            avUnlockErr = "The system password window refused it (polkit: not authorized: this user is not an administrator there, or the password was wrong). Use \"Unlock once with password\": it asks here and uses sudo."
        else if (code === 127 || /authentication agent|authorization/i.test(errLine))
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
        stdinEnabled: true                                  // the sudo route: the password goes in on stdin, never on a command line (`ps` would show it)
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
                        root.admAsk({ steps: [["exceptions"].concat(excEdit.args)], title: "Exceptions", button: "Do it", ackIds: [], detail: "Changes the antivirus exceptions." })
                    } else {
                        root.avUnlockErr = why + " Use the console button: it asks for your password there."
                        root.flash(root.avUnlockErr, true)
                    }
                    return
                }
                root.avUnlockStep = "password"
                root.avPkHidden = true
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
    // ---- "Unlock once with password", asked in this window and run with sudo. The old way needed pkexec AND a polkit password window:
    // without administrator rights in polkit it answered "Not authorized", and while a password window was pending the button stayed
    // dead ("Waiting for the password...") with no way out. Now: the field is here, sudo is what the console already uses, a wrong
    // password says so and asks again, nothing waits longer than the watchdog, and Cancel always works.
    property bool avAskPw: false              // the password field is showing
    property string avPwAction: "unlock"      // unlock | repair: what the password will be used for
    property bool avRepairing: false          // a repair is running (the password was accepted)
    property bool avDetails: false            // the raw error (a path, an os error) is only shown when asked for
    // the history was written by a newer engine: no password can read it, the database has to be rebuilt (a copy is kept)
    readonly property bool avSchemaStuck: /schema version \d+ is newer than the supported version/.test(avUnlockErr + " " + avErr + " " + avActErr)
    readonly property string repairScript: Quickshell.env("HOME") + "/.config/Halcyon/scripts/antivirus-db-repair.sh"
    function avRepair() {
        if (!hasAv || avRootProc.running || agentProc.running) return
        avUnlockErr = ""
        avPwAction = "repair"
        if (pwKnown) { avSubmitPw(pwCache); return }
        avAskPw = true
        pwFocusRequested()
    }
    property string avUnlockVia: ""           // sudo | pkexec: how the last unlock ran
    property bool avPkHidden: false           // the pkexec route hid this window: bring it back when that ends (never over the console)
    property bool avCancelled: false          // a run was stopped on purpose: its exit is not an error
    property bool excCancelled: false
    property double avSnapAt: 0               // when the snapshot was read
    property int nowTick: 0
    signal pwFocusRequested()
    onConsoleRequested: avPkHidden = false
    Timer { interval: 15000; repeat: true; running: root.open && root.hasAv && root.tab === "antivirus"; onTriggered: root.nowTick++ }
    function avUnlock() {
        if (!hasAv || avRootProc.running || agentProc.running) return
        avUnlockErr = ""
        avPwAction = "unlock"
        if (pwKnown) { avSubmitPw(pwCache); return }
        avAskPw = true
        pwFocusRequested()
    }
    function avSubmitPw(pw) {
        if (pw === "" || avRootProc.running || agentProc.running || !hasAv) return
        avUnlockErr = ""
        pwTrying = pw
        avUnlockVia = "sudo"; avUnlockStep = "password"
        avRepairing = avPwAction === "repair"
        avRootOutT = ""; avRootErrT = ""; avRootCode = -1
        avRootExited = false; avRootOutDone = false; avRootErrDone = false
        // sh reads ONE line (the password) and gives sudo exactly that line: a wrong password fails once instead of retrying three times
        // (three wrong tries would lock the account for a few minutes), and timeout ends it if it ever hangs
        if (avRepairing) {
            // the repair stops and starts services, so it gets a longer leash than the quick snapshot read
            avRootProc.command = ["timeout", "-k", "3", "90", "sh", "-c",
                "IFS= read -r pw; printf '%s\\n' \"$pw\" | sudo -S -p '' -- /bin/bash \"$1\"", "sh", repairScript]
        } else {
            avRootProc.command = ["timeout", "-k", "3", "40", "sh", "-c",
                "IFS= read -r pw; printf '%s\\n' \"$pw\" | sudo -S -p '' -- /bin/sh -c \"$1\" sh \"$2\"", "sh", snapScript, avBin]
        }
        avRootProc.running = true
        avRootProc.write(pw + "\n")
        avAskPw = false
    }
    function avSudoFail(code, err) {
        var lines = String(err).split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l !== "" })
        var all = lines.join(" ")
        if (/incorrect password|try again|no password was provided|authentication failure/i.test(all)) { pwRefused(); avUnlockErr = "That password did not work. Try again."; avAskPw = true; pwFocusRequested() }
        else if (/not in the sudoers|not allowed to run sudo|may not run sudo|not allowed to execute/i.test(all))
            avUnlockErr = "This user is not allowed to use sudo, so a password cannot unlock it. As an administrator, add this user to the wheel group (usermod -aG wheel NAME) and log in again."
        else if (/sudo: (command )?not found|sudo: not installed/i.test(all)) avUnlockErr = "sudo is not installed. Try \"System password window\"."
        else if (/faillock|temporarily locked|account is locked/i.test(all)) avUnlockErr = "The account is locked for a few minutes after wrong passwords. Wait, then try again."
        else if (code === 124 || code === 137 || code === 143) avUnlockErr = "It took too long and was stopped. Try again."
        else avUnlockErr = (lines.length > 0 ? lines[0].replace(/^error: /i, "") : "ai-antivirus stopped with exit code " + code).slice(0, 180)
        flash(avUnlockErr, true)
    }
    // the system password window (pkexec + a polkit agent): kept as the second way
    function avUnlockPk() {
        if (avRootProc.running || agentProc.running || !hasAv) return
        avUnlockErr = ""; avAskPw = false
        avUnlockVia = "pkexec"
        avUnlockStep = "agent"; agentFor = "unlock"
        agentProc.running = true
    }
    function avCancelUnlock(msg) {
        if (agentProc.running) agentProc.running = false
        if (avRootProc.running) { avCancelled = true; avRootProc.running = false }
        if (excEdit.running) { excCancelled = true; excEdit.running = false }
        avUnlockStep = ""
        avAskPw = false
        if (msg) { avUnlockErr = msg; flash(msg, true) }
        if (avPkHidden) show("antivirus")
        avPkHidden = false
    }
    // nothing waits for ever: a password window that never appeared (or was lost behind another window) used to leave this stuck
    Timer {
        id: unlockWatch
        interval: 75000
        running: root.avUnlockStep !== ""
        onTriggered: root.avCancelUnlock("No answer after a minute, so it was cancelled. Try \"Unlock once with password\" again.")
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
    // ---- changes that need root (approve, reject, undo, allow): done HERE. A bar asks for the password, sudo runs `ai-antivirus ...`
    // and the answer shows in this window. The console is no longer opened. The password goes in on stdin, never on a command line.
    // The password is typed ONCE per login and kept in memory only (never written to disk, never on a command line): every later root
    // action here (approve, reject, undo, allow, unlock, repair) reuses it. It is dropped when it is refused (wrong or changed), with
    // "Forget password", or when the shell restarts (log out / reboot). sudo itself cannot remember it for us: these commands run
    // without a terminal, and sudo's own ticket is tied to a terminal, so each one used to start from zero.
    property bool pwRemember: true            // "Remember until I log out" (the switch next to the password field)
    property string pwCache: ""
    property string pwTrying: ""              // the password of the run in flight: it is only kept once sudo accepted it
    readonly property bool pwKnown: pwCache !== ""
    function pwForget() { pwCache = ""; pwTrying = "" }
    function pwAccepted() { if (pwRemember && pwTrying !== "") pwCache = pwTrying; pwTrying = "" }
    function pwRefused() { pwCache = ""; pwTrying = "" }
    property var admJob: null                 // { steps: [[args...], ...], title, detail, button, ackIds }
    property string admErr: ""
    property bool admCancelled: false
    property int admCode: -1
    property string admOutT: ""
    property string admErrT: ""
    property bool admExited: false
    property bool admOutDone: false
    property bool admErrDone: false
    readonly property bool admBusy: admProc.running
    signal admFocusRequested()
    function admAsk(job) {
        if (admBusy || (!hasAv && !(job && job.script))) return
        admErr = ""; admJob = job
        if (pwKnown) { admSubmit(pwCache); return }          // no password bar: the remembered one is used
        Qt.callLater(function () { root.admFocusRequested() })
    }
    // A root command done HERE, in the background: no console. With a remembered password it runs the moment you press the button;
    // otherwise the password bar asks once. `cmd` is a shell line without "sudo" (it runs as root); the first line it prints is shown.
    function rootRun(cmd, title, detail, button) {
        admAsk({ steps: [], script: cmd, title: title, button: button || "Do it", detail: detail || cmd, ackIds: [] })
    }
    // full access in one password: put this user into group ai-antivirus (alerts, acknowledging, the action log, the AI's clearing)
    function avGrantAccess() {
        admAsk({ steps: [], script: "usermod -aG ai-antivirus \"${SUDO_USER:-$USER}\" && echo \"Full access given.\"",
                 title: "Full access", button: "Give full access", ackIds: [], joinGroup: true,
                 detail: "Adds your user to the ai-antivirus group, so alerts, acknowledging them and the AI's clearing work without a password. No logout needed." })
    }
    // Full access is a choice: ON = this user is in group ai-antivirus (alerts, acknowledging and the AI's clearing need no password),
    // OFF = every root action asks for the password, and nothing is stored. The choice is also written to install-choices.env
    // (AV_FULL_ACCESS) so install.sh and update.sh keep it: they only add you to the group when it is not "no".
    readonly property bool avFullAccess: avPerm === "ok" || avPerm === "stale"
    function avSaveAccessChoice(on) {
        Quickshell.execDetached(["sh", "-c", "f=\"$HOME/.local/state/island/install-choices.env\"; mkdir -p \"$(dirname \"$f\")\"; [ -f \"$f\" ] || : > \"$f\"; grep -v '^AV_FULL_ACCESS=' \"$f\" > \"$f.new\" 2>/dev/null; printf 'AV_FULL_ACCESS=\"%s\"\\n' \"$1\" >> \"$f.new\"; mv \"$f.new\" \"$f\"", "sh", on ? "yes" : "no"])
    }
    function avSetFullAccess(on) {
        if (on === avFullAccess) return
        avSaveAccessChoice(on)
        if (on) { avGrantAccess(); return }
        admAsk({ steps: [], script: "gpasswd -d \"${SUDO_USER:-$USER}\" ai-antivirus >/dev/null && echo \"Full access is off: the password is asked again.\"",
                 title: "Turn full access off", button: "Turn it off", ackIds: [], leaveGroup: true,
                 detail: "Takes your user out of the ai-antivirus group. Alerts and actions then ask for your password. Fully in effect after your next login." })
    }
    function admCancel() {
        if (admProc.running) { admCancelled = true; admProc.running = false }
        if (admJob && admJob.reviewAck && reviewAckState === 1) reviewAckState = 3
        admJob = null; admErr = ""
    }
    function admSubmit(pw) {
        if (pw === "" || admBusy || admJob === null) return
        admErr = ""
        pwTrying = pw
        admOutT = ""; admErrT = ""; admCode = -1
        admExited = false; admOutDone = false; admErrDone = false
        // one sudo for every step of the job (one password); a wrong password fails once instead of retrying three times
        // a job with its own `script` runs it as root as it is (it gets the ai-antivirus binary as $1); the others run the binary
        var script = admJob.script ? admJob.script : admJob.steps.map(function (st) { return "\"$1\" " + st.map(shq).join(" ") }).join(" && ")
        admProc.command = ["timeout", "-k", "3", "40", "sh", "-c",
            "IFS= read -r pw; printf '%s\\n' \"$pw\" | sudo -S -p '' -- /bin/sh -c \"$1\" sh \"$2\"",
            "sh", script, avBin]
        admProc.running = true
        admProc.write(pw + "\n")
    }
    function admFinish() {
        if (!admExited || !admOutDone || !admErrDone) return
        admExited = false
        if (admCancelled) { admCancelled = false; return }
        var code = admCode, lines = admErrT.split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l !== "" }), all = lines.join(" ")
        if (code === 0) {
            pwAccepted()
            var job = admJob
            admJob = null; admErr = ""
            var first = admOutT.trim().split("\n")[0]
            flash(first !== "" ? first : job.title + ": done", false)
            if (job.joinGroup || job.leaveGroup) { avPerm = ""; permProc.running = true; avSoon.restart() }      // in the group now: the live read takes over at once
            if (job.ackIds && job.ackIds.length > 0 && !avSnap) ack(job.ackIds)
            else if (avSnap) {
                if (job.dropIds) { avSnapDrop(job.dropIds); if (job.reviewAck) reviewAckState = 2 }
                else flash((first !== "" ? first + " " : "") + "Done. Press Reload to see it.", false)
            }
            refresh()
            return
        }
        if (/incorrect password|try again|no password was provided|authentication failure/i.test(all)) { pwRefused(); admErr = "That password did not work. Try again." }
        else if (/not in the sudoers|not allowed to run sudo|may not run sudo/i.test(all)) admErr = "This user is not allowed to use sudo."
        else if (/sudo: (command )?not found/i.test(all)) admErr = "sudo is not installed."
        else if (/faillock|temporarily locked|account is locked/i.test(all)) admErr = "The account is locked for a few minutes after wrong passwords. Wait, then try again."
        else if (code === 124 || code === 137 || code === 143) admErr = "It took too long and was stopped. Try again."
        else admErr = (lines.length > 0 ? lines[0].replace(/^error: /i, "") : "ai-antivirus stopped with exit code " + code).slice(0, 200)
        Qt.callLater(function () { root.admFocusRequested() })
    }
    Process {
        id: admProc
        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: { root.admOutT = text; root.admOutDone = true; root.admFinish() } }
        stderr: StdioCollector { onStreamFinished: { root.admErrT = text; root.admErrDone = true; root.admFinish() } }
        onExited: code => { root.admCode = code; root.admExited = true; root.admFinish() }
    }
    function actRun(verb, id, a) {
        var what = a ? actVerb(a).replace(/\?$/, "") + (actTarget(a.target) !== "" ? ": " + actTarget(a.target) : "") : ""
        var text = { approve: ["Approve", "Carry it out", "The antivirus will do what it asked: " + what],
                     reject: ["Reject", "Leave it alone", "Nothing is quarantined, frozen or blocked. It stays as it is. " + what],
                     undo: ["Undo", "Undo it", "Put it back as it was. " + what] }[verb] || [verb, "Run", what]
        admAsk({ steps: [[verb, String(Number(id))]], title: text[0], button: text[1], detail: text[2], ackIds: [] })
    }
    // Allow: the antivirus stops reporting this program (an exception), and its alerts are acknowledged
    function allowAlerts(g) {
        if (!g.raw || g.raw.length === 0) { flash("This alert has no program path to allow.", true); return }
        var steps = g.raw.slice(0, 8).map(function (r) { return ["exceptions", "add", "program", r, "--name", "Allowed from Security center"] })
        admAsk({ steps: steps, title: "Allow " + g.title, button: "Allow it",
                 detail: "The antivirus will stop reporting " + (g.raw.length > 1 ? g.raw.length + " programs" : g.raw[0].replace(/^\/home\/[^/]+\//, "~/")) +
                         ". Remove it later on the Exceptions page. Malware found by hash or YARA is still reported.", ackIds: g.ids })
    }
    function ack(ids) {
        if (avAckProc.running) return
        var args = ids === "all" ? ["ack", "--all"] : ["ack"].concat(ids.map(String))
        // the snapshot is root's: the acknowledge needs root too. The console asks for the password (sudo), then Reload shows the result
        if (avSnap) {
            admAsk({ steps: [args], title: "Acknowledge", button: "Acknowledge", ackIds: [], dropIds: ids,
                     detail: ids === "all" ? "Marks every alert as seen." : "Marks " + ids.length + (ids.length === 1 ? " alert" : " alerts") + " as seen." })
            return
        }
        avAckProc.ackIds = ids
        avAckProc.command = avCmd(args)
        avAckProc.running = true
    }

    // ---- on-demand scan, inside the window: one JSON line per file with findings, then a summary
    property var scanFound: []
    property var scanSum: null
    property string scanWhat: ""
    property bool scanStarting: false         // set the moment a scan is asked for: Process.running can lag a tick behind `running = true`
    readonly property bool scanning: scanProc.running || scanStarting
    function scan(dir) {
        if (scanning || !hasAv) return false
        scanFound = []; scanSum = null; scanWhat = dir
        scanProc.command = ["sh", "-c", "cd \"$HOME\" && exec ai-antivirus scan --json \"$1\"", "scan", dir]
        scanStarting = true
        scanStartT.restart()
        scanProc.running = true
        return true
    }
    // safety net: if the process never shows up as running (it could not be launched), end the scan as failed instead of hanging
    Timer {
        id: scanStartT
        interval: 4000
        onTriggered: {
            if (!root.scanStarting) return
            root.scanStarting = false
            if (!scanProc.running) { root.scanSum = { files: 0, found: 0, seconds: 0, failed: true }; root.askScanDone() }
        }
    }
    Process {
        id: scanProc
        onRunningChanged: if (running) { root.scanStarting = false; scanStartT.stop() }
        stdout: SplitParser {
            onRead: line => {
                var o = null
                try { o = JSON.parse(line) } catch (e) { return }
                if (o.summary) root.scanSum = o
                else { var c = root.scanFound.slice(); c.push(o); root.scanFound = c }
            }
        }
        onExited: { root.scanStarting = false; scanStartT.stop(); if (root.scanSum === null) root.scanSum = { files: 0, found: root.scanFound.length, seconds: 0, failed: true }; root.askScanDone() }
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
    // Allow one finding (your decision): a hash-pinned exception, no password needed (it lives in your own state folder).
    // The first click asks "Sure?", the second does it. It is reported again if the file changes.
    property string clamConfirm: ""
    function clamAllow(file, sig) {
        var k = file + "|" + sig
        if (clamAllowProc.running) return
        if (clamConfirm !== k) { clamConfirm = k; clamConfirmT.restart(); return }
        clamConfirm = ""
        clamAllowProc.file = file; clamAllowProc.sig = sig
        clamAllowProc.command = ["python3", aiScript, "clamav", "allow", file, sig, "--json"]
        clamAllowProc.running = true
    }
    Timer { id: clamConfirmT; interval: 6000; onTriggered: root.clamConfirm = "" }
    Process {
        id: clamAllowProc
        property string file: ""
        property string sig: ""
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (!d || !d.ok) { root.flash(d && d.error ? d.error : "Could not allow it.", true); return }
                var c = Object.assign({}, root.clam)
                var f = clamAllowProc.file, s = clamAllowProc.sig
                c.found = (c.found || []).filter(function (x) { return !(x.file === f && x.signature === s) })
                c.excepted = (c.excepted || []).concat([{ file: f, signature: s, status: "excepted", note: "allowed by you" }])
                c.headline = c.found.length > 0 ? c.found.length + " found" : "Nothing left to review"
                c.good = c.found.length === 0
                root.clam = c
                root.flash(d.text || "Allowed.", false)
            }
        }
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
        if (admBusy || !hasAv) return
        var verb = args[0], what = args[0] === "add" ? "Allow " + args[2] : (args[0] === "remove" ? "Stop allowing " + args[1] : "Reset the exceptions to the defaults")
        var more = verb === "add" ? "The antivirus will stop reporting it." : (verb === "remove" ? "The antivirus will report it again." : "Your own exceptions are removed.")
        admAsk({ steps: [["exceptions"].concat(args)], title: what, button: verb === "add" ? "Allow it" : "Do it", detail: more, ackIds: [] })
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
        if (excCancelled) { excCancelled = false; return }
        var wasHidden = avPkHidden
        avPkHidden = false
        var code = excCode, err = excErrT.trim()
        // pkexec itself refused (no agent / not found): the same command with sudo in the console
        if (code === 127 && (err === "" || /authentication agent|not found|No such file/i.test(err))) {
            admAsk({ steps: [["exceptions"].concat(excEdit.args)], title: "Exceptions", button: "Do it", ackIds: [], detail: "Changes the antivirus exceptions." })
            return
        }
        if (wasHidden) show("exceptions")
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
    readonly property string overallTone: !hasFw && !hasAv ? "muted" : (down > 0 ? "bad" : (avUnacked > 0 || avPending > 0 || avLocked ? "warn" : "good"))
    // the pages as icons in the middle of the head. The firewall and the antivirus are always there: the one that is not installed is
    // greyed out and can not be opened (its hover says so), and what only works with it (Exceptions) goes grey with it. ClamAV is an
    // extra, so it only shows when it is installed.
    readonly property var navItems: {
        var noFw = detected && !hasFw, noAv = detected && !hasAv
        var a = [{ key: "overview", glyph: 0xF0570, label: "Overview", dot: avUnacked + avPending > 0, tone: overallColor }]
        a.push({ key: "firewall", glyph: 0xF1A11, label: noFw ? "Firewall · not installed" : "Firewall", dot: hasFw && !fwAlive, tone: pal.bad, disabled: noFw })
        a.push({ key: "antivirus", glyph: 0xF13B6, label: noAv ? "Antivirus · not installed" : "Antivirus", dot: avUnacked > 0 || avPending > 0, tone: pal.warn, disabled: noAv })
        a.push({ key: "exceptions", glyph: 0xF0780, label: noAv ? "Exceptions · needs the antivirus" : "Exceptions", disabled: noAv })
        a.push({ key: "ask", glyph: 0xF0B79, label: noFw && noAv ? "Ask · needs the firewall or the antivirus" : "Ask", disabled: noFw && noAv })
        if (hasClam || !detected) a.push({ key: "clamav", glyph: 0xF0668, label: "ClamAV", dot: clam !== null && !clam.good, tone: pal.bad })
        return a
    }
    // ---- the smart overview: one sentence about how things are, and at most three things that need you (each with ONE button)
    readonly property var ovTodo: {
        var t = []
        if (hasFw && !fwAlive) t.push({ key: "fw", tone: "bad", glyph: 0xF1A11, title: "Firewall is not responding", sub: "It is not running.", btn: "Open" })
        if (hasAv && av !== null && !avRunning) t.push({ key: "avdown", tone: "bad", glyph: 0xF13B6, title: "Antivirus is not running", sub: "Nothing is being watched.", btn: "Open" })
        if (avLocked) t.push({ key: "unlock", tone: "warn", glyph: 0xF033E, title: "Alerts are locked", sub: "Unlock to read them.", btn: "Unlock" })
        if (avPending > 0) t.push({ key: "held", tone: "warn", glyph: 0xF0026, title: avPending + (avPending === 1 ? " action waits" : " actions wait") + " for your OK", sub: "Approve or reject.", btn: "Review" })
        if (!avLocked && avUnacked > 0) t.push({ key: "alerts", tone: avAlerts.some(function (a) { return a.severity === "critical" || a.severity === "high" }) ? "bad" : "warn", glyph: 0xF0026, title: avUnacked + (avUnacked === 1 ? " alert" : " alerts") + " to review", sub: "Allow what you trust.", btn: "Review" })
        return t.slice(0, 3)
    }
    readonly property var ovTiles: [
        { key: "firewall", name: "Firewall", glyph: 0xF1A11, ok: hasFw, tone: fwColor,
          line: fwState + (posture !== "" && posture !== "secure" ? "  ·  " + posture : ""),
          figure: fw ? count((fw.dropped_policy || 0) + (fw.dropped_blocklist || 0) + (fw.dropped_feed || 0)) + " blocked" : "" },
        { key: "antivirus", name: "Antivirus", glyph: 0xF13B6, ok: hasAv, tone: avColor,
          line: avState + (av && av.mode ? "  ·  " + av.mode : ""),
          figure: !avKnown ? "locked" : (avUnacked > 0 ? avUnacked + " to review" : "all clear") }
    ]
    readonly property bool ovCalm: detected && ovTodo.length === 0
    readonly property string ovHead: !detected ? "" : (ovTodo.length === 0 ? "You're protected" : (ovTodo.length === 1 ? "One thing needs you" : ovTodo.length + " things need you"))
    readonly property string ovSub: {
        if (!detected) return ""
        if (ovTodo.length > 0) return ""
        return hasFw && hasAv ? "Firewall and antivirus are both running." : (hasAv ? "Antivirus is running." : "Firewall is running.")
    }
    function ovGo(key) {
        if (key === "fw") setTab("firewall")
        else if (key === "avdown") setTab("antivirus")
        else if (key === "unlock") { setTab("antivirus"); avUnlock() }
        else if (key === "held") { avView = "held"; setTab("antivirus") }
        else if (key === "alerts") { avView = "alerts"; setTab("antivirus") }
    }
    // ---- Let AI decide. Two parts, both shown in the card while they happen:
    //   1. the alert review: the local model reads every group of unacknowledged antivirus alerts (`halcyon-ai.py review`) and says
    //      safe / not sure / dangerous for each, with the reason, one row at a time. What it calls safe AND the fixed gates in
    //      halcyon-ai.py allow (behaviour rules only, low severity, or medium from Halcyon's own files; never high or critical, never a
    //      hash or YARA match) is acknowledged here at once, the same as pressing Acknowledge, no password needed. Everything else
    //      stays on the list and is shown to you. It never approves a held action (that needs sudo) and never adds an exception.
    //   2. the pick: of what still needs you, which to deal with first and why (`halcyon-ai.py decide`). Nothing is done until you
    //      approve; approving only takes you to that page (or starts the unlock), the same as pressing its row.
    // ---- the antivirus log: a card that pops out beside the window (like the AI's card), the live `ai-antivirus tail -f`
    property bool logOpen: false
    property bool logPaused: false
    // The newest 200 lines live in a ListModel and arrive in batches. Before, every line copied the whole 300-line array and
    // assigned it again, which made the list throw away and rebuild every row (each with a regex) for every single line: opening the
    // log, which first dumps the recent history, rebuilt it hundreds of times in a row. Now a line is only queued; one timer adds
    // everything that arrived in the last 200 ms in one go, the tone is worked out once per line, and nothing else is touched.
    readonly property int logMax: 200
    property var logBuf: []
    ListModel { id: logModel }
    Timer { id: logFlushT; interval: 200; onTriggered: root.logFlush() }
    function logPush(line) {
        if (logPaused) return
        var t = String(line)
        if (t.length > 400) t = t.slice(0, 400) + "…"
        logBuf.push({ t: t, c: logTone(t) })
        if (!logFlushT.running) logFlushT.start()
    }
    function logFlush() {
        var n = logBuf.length
        if (n === 0) return
        var b = n > logMax ? logBuf.slice(n - logMax) : logBuf
        logBuf = []
        logModel.append(b)
        var over = logModel.count - logMax
        if (over > 0) logModel.remove(0, over)
    }
    function logClear() { logFlushT.stop(); logBuf = []; logModel.clear() }
    function logToggle() {
        if (logOpen) { logOpen = false; return }
        if (decideOpen) decideClose()
        logOpen = true
    }
    function logTone(l) {      // "bad" | "warn" | "" (the delegate maps it to a colour)
        if (/malware|malicious|quarantin|ransom|trojan|critical|infected|killed|blocked|denied/i.test(l)) return "bad"
        if (/warn|alert|suspicious|held|pending|error|fail/i.test(l)) return "warn"
        return ""
    }
    onLogOpenChanged: { logClear(); if (logOpen) logPaused = false }
    Process {
        id: logProc
        // a stale session reads through sg (the group is not in this session yet); a tail has no time limit, unlike the 8 s reads
        command: root.avViaSg ? ["sg", "ai-antivirus", "-c", "ai-antivirus tail -f"] : ["ai-antivirus", "tail", "-f"]
        running: root.logOpen && root.open && root.hasAv
        stdout: SplitParser { onRead: line => root.logPush(line) }
        stderr: SplitParser { onRead: line => root.logPush("! " + line) }
    }
    property bool decideOpen: false
    property var decideRes: null
    property string decideErr: ""
    property var decideSteps: []
    property bool decideSkipped: false        // nothing was left to pick from after the review
    property int decideGen: 0                 // an answer that arrives after the card was closed or restarted is dropped
    property var reviewItems: []              // one per group of alerts, added as the model judges it
    property var reviewRes: null
    property string reviewErr: ""
    property string reviewNote: ""            // why no review ran (alerts locked, a snapshot)
    property string reviewStep: ""
    property int reviewAckState: 0            // 0 nothing to acknowledge | 1 acknowledging | 2 done | 3 did not work
    property int reviewTotal: 0               // groups handed to the review (the progress bar's end)
    property bool rvOpenCleared: true         // the "Judged safe" list is open
    readonly property bool reviewBusy: reviewProc.running
    readonly property bool decideBusy: decideProc.running
    readonly property bool cardBusy: reviewProc.running || decideProc.running
    readonly property bool rvShown: reviewBusy || reviewItems.length > 0 || reviewNote !== "" || reviewErr !== ""
    readonly property var rvNeeds: reviewItems.filter(function (i) { return i.status !== "clear" })
    readonly property var rvCleared: reviewItems.filter(function (i) { return i.status === "clear" })
    readonly property string rvSummary: {
        if (!reviewRes) return ""
        var c = reviewRes.clear_ids ? reviewRes.clear_ids.length : 0, n = reviewRes.needs || 0
        var s = c === 0 ? "Nothing was cleared. "
              : (reviewAckState === 3 ? "The AI judged " + c + (c === 1 ? " alert" : " alerts") + " safe but could not acknowledge " + (c === 1 ? "it" : "them") + ". "
                                      : "Cleared " + c + " safe " + (c === 1 ? "alert" : "alerts") + ". ")
        return s + (n === 0 ? "Nothing needs you." : (n === 1 ? "One group needs you." : n + " groups need you."))
    }
    readonly property int rvClearedN: rvCleared.reduce(function (n, i) { return n + (i.count || 1) }, 0)
    readonly property int rvNeedsN: rvNeeds.reduce(function (n, i) { return n + (i.count || 1) }, 0)
    // the card's colour: accent while it works, then green (all clear), amber (something to look at) or red (something may be dangerous)
    readonly property string cardState: cardBusy || (!rvShown && decideRes === null) ? "busy"
        : (rvNeeds.some(function (i) { return i.verdict === "suspicious" || i.severity === "critical" }) ? "bad"
        : (rvNeeds.length > 0 || (decideRes !== null && !rvShown) ? "warn" : "good"))
    readonly property color cardTone: cardState === "bad" ? pal.bad : (cardState === "warn" ? pal.warn : (cardState === "good" ? pal.good : pal.accent))
    function rvLabel(it) {
        if (it.status === "clear") return "Safe"
        if (it.verdict === "suspicious") return "Might be dangerous"
        if (it.severity === "high" || it.severity === "critical") return "Yours to decide"
        if (it.verdict === "safe") return "Looks safe, kept for you"
        return "Not sure"
    }
    function rvColor(it) {
        if (it.status === "clear") return pal.good
        return it.verdict === "suspicious" || it.severity === "critical" ? pal.bad : pal.warn
    }
    readonly property var decidePickItem: {
        if (!decideRes) return null
        for (var i = 0; i < ovTodo.length; i++) if (ovTodo[i].key === decideRes.pick) return ovTodo[i]
        return null
    }
    // the unacknowledged alerts as groups (the same alert in many places is one group), what the review is given; at most 40 alerts
    function reviewGroups() {
        var map = {}, order = []
        avAlerts.forEach(function (a) {
            var k = (a.rule_id || "") + "|" + (a.title || "")
            var g = map[k]
            if (!g) { g = map[k] = { key: k, title: a.title || "", rule_id: a.rule_id || "", severity: a.severity || "", count: 0, ids: [], where: [], raw: [], sample: "" }; order.push(g) }
            g.count++; g.ids.push(a.id)
            if (sevRank(a.severity) > sevRank(g.severity)) g.severity = a.severity
            var w = whereOf(a)
            if (w !== "" && g.where.length < 4 && g.where.indexOf(w) < 0) g.where.push(w)
            var r = rawOf(a)
            if (r.charAt(0) === "/" && g.raw.length < 4 && g.raw.indexOf(r) < 0) g.raw.push(r)
            if (g.sample === "") { try { g.sample = JSON.stringify(a.detail || {}).slice(0, 300) } catch (e) { g.sample = "" } }
        })
        return order
    }
    function decideStart() {
        if (cardBusy || (ovTodo.length === 0 && avAlerts.length === 0)) return
        decideGen++
        decideRes = null; decideErr = ""; decideSteps = []; decideSkipped = false; decideOpen = true
        reviewItems = []; reviewRes = null; reviewErr = ""; reviewNote = ""; reviewStep = ""; reviewAckState = 0; reviewTotal = 0
        if (hasAv && avLocked) reviewNote = "The alerts are locked, so the AI cannot read them yet. Unlock them first, then ask again."
        else if (hasAv && avAlerts.length > 0) {
            var rg = reviewGroups()
            reviewTotal = rg.length
            reviewProc.command = ["python3", aiScript, "review", "--json", "--items", JSON.stringify(rg)]
            reviewProc.running = true
            return
        }
        decideRun()
    }
    // part 2: what still needs you after the review (the alerts it cleared are taken off the list it is given)
    function decideRun() {
        var gone = reviewRes && reviewRes.clear_ids && reviewAckState !== 3 ? reviewRes.clear_ids.length : 0
        var left = Math.max(0, avUnacked - gone)
        var items = []
        ovTodo.forEach(function (t) {
            if (t.key === "alerts") {
                if (left === 0) return
                items.push({ key: t.key, tone: t.tone, title: left + (left === 1 ? " alert" : " alerts") + " to review", sub: t.sub })
            } else items.push({ key: t.key, tone: t.tone, title: t.title, sub: t.sub })
        })
        if (items.length === 0) { decideSkipped = true; return }
        decideProc.command = ["python3", aiScript, "decide", "--json", "--items", JSON.stringify(items)]
        decideProc.running = true
    }
    function decideClose() {
        decideGen++
        decideOpen = false
        if (reviewProc.running) reviewProc.running = false
        if (decideProc.running) decideProc.running = false
    }
    function decideApprove() {
        var k = decideRes ? decideRes.pick : ""
        decideClose()
        if (k !== "") ovGo(k)
    }
    function decideTitle(k) {
        for (var i = 0; i < ovTodo.length; i++) if (ovTodo[i].key === k) return ovTodo[i].title
        return k
    }
    // the alerts the model called safe and the gates allowed: acknowledged like a press on Acknowledge (avAckProc, no root)
    function reviewClear(ids) {
        if (avSnap) {            // the alerts were read as root: the acknowledge needs root too. One password, asked in the window
            if (admBusy || admJob !== null) { reviewAckState = 3; return }
            reviewAckState = 1
            admAsk({ steps: [["ack"].concat(ids.map(String))], title: "Acknowledge what the AI cleared", button: "Acknowledge",
                     detail: "The AI read " + ids.length + (ids.length === 1 ? " alert" : " alerts") + " and judged " + (ids.length === 1 ? "it" : "them") +
                             " safe. Acknowledging needs your password once, because the alerts were read with it.",
                     ackIds: [], dropIds: ids, reviewAck: true })
            show("antivirus")
            return
        }
        if (avAckProc.running) { reviewAckState = 3; return }
        reviewAckState = 1
        ack(ids)
    }
    Process {
        id: reviewProc
        property int gen: 0
        onRunningChanged: if (running) gen = root.decideGen
        stderr: SplitParser {
            onRead: d => {
                if (reviewProc.gen !== root.decideGen) return
                var line = String(d), m = line.match(/^STEP (.+)$/)
                if (m) { root.reviewStep = m[1]; return }
                m = line.match(/^ITEM (.+)$/)
                if (m) { try { root.reviewItems = root.reviewItems.concat([JSON.parse(m[1])]) } catch (e) {} }
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (reviewProc.gen !== root.decideGen || !root.decideOpen) return
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (!d) root.reviewErr = "No answer from halcyon-ai.py (is python3 there?)"
                else if (!d.ok) root.reviewErr = d.error || "The review did not work."
                else {
                    root.reviewRes = d
                    root.reviewItems = d.items || []
                    if (d.clear_ids && d.clear_ids.length > 0) root.reviewClear(d.clear_ids)
                }
                root.decideRun()
            }
        }
    }
    Process {
        id: decideProc
        property int gen: 0
        onRunningChanged: if (running) gen = root.decideGen
        stderr: SplitParser {
            onRead: d => {
                var m = String(d).match(/^STEP (.+)$/)
                if (m && decideProc.gen === root.decideGen) root.decideSteps = root.decideSteps.concat([m[1]])
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (decideProc.gen !== root.decideGen || !root.decideOpen) return
                var d = null
                try { d = JSON.parse(text) } catch (e) { d = null }
                if (!d) { root.decideErr = "No answer from halcyon-ai.py (is python3 there?)"; return }
                if (!d.ok) { root.decideErr = d.error || "It did not work."; return }
                root.decideRes = d
            }
        }
    }
    readonly property var feed: {
        var out = []
        if (fw) (fw.recent || []).forEach(function (d) { out.push({ at: d.at_unix, who: "firewall", title: d.reason + "  " + d.ip, sub: d.ports, tone: d.enforced ? "bad" : "warn" }) })
        avAlerts.forEach(function (a) { out.push({ at: a.ts_ns / 1e9, who: "antivirus", title: a.title, sub: a.detail && a.detail.exe ? a.detail.exe : a.rule_id, tone: a.severity }) })
        avHeld.forEach(function (a) { out.push({ at: a.ts_ns / 1e9, who: "antivirus", title: root.actVerb(a), sub: root.actTarget(a.target) || (a.rule_id || ""), tone: a.status === "pending" ? "medium" : (a.status === "executed" ? "high" : "low") }) })
        out.sort(function (a, b) { return b.at - a.at })
        return out.slice(0, 8)
    }

    // ---- ask: one conversation, aimed at either module
    property bool aiOn: true                  // the master AI switch (shell.qml sets it); off: Ask answers with a note and starts nothing
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
        // "scan my Downloads", "can you run a scan on ~/projects": it is DONE here, with the antivirus's own scanner (no model needed),
        // and the result is told in the chat. A question about scans still goes to the assistant.
        var sr = hasAv ? SecAsk.scanRequest(q) : null
        if (!sr && hasAv && askWantsFolder) {          // the answer to "Which folder should I scan?": "~/games", "my Downloads" ...
            var fr = SecAsk.scanRequest("scan " + q)
            if (fr && fr.path !== "") sr = fr
            else askWantsFolder = false
        }
        if (sr) {
            pushMsg({ role: "you", text: q, who: target })
            askScan(sr, target)
            Qt.callLater(function () { root.focusRequested("ask") })
            return
        }
        if (target === "firewall" && !hasFw) return
        if (target === "antivirus" && !hasAv) return
        pushMsg({ role: "you", text: q, who: target })
        var r = SecAsk.route(q, target)
        if (!r.send) {                         // not a security question: answered here, neither tool is started
            pushMsg({ role: "ai", text: r.reply, live: false, actions: [], who: target })
            Qt.callLater(function () { root.focusRequested("ask") })
            return
        }
        if (!aiOn && q.indexOf("/test") !== 0) {      // the master AI switch (Settings > AI > AI features): neither tool is asked anything
            pushMsg({ role: "ai", text: "AI features are switched off (Settings > AI > AI features). Turn them on to ask questions here. The tests under Overview still work.", bad: true, live: false, actions: [], who: target })
            Qt.callLater(function () { root.focusRequested("ask") })
            return
        }
        askProc.target = target
        askProc.command = target === "firewall" ? [fwBin, "ask", "--json", q] : ["ai-antivirus", "ask", "--json", q]
        askProc.running = true
        Qt.callLater(function () { root.focusRequested("ask") })
    }
    property bool askWantsFolder: false       // "Which folder should I scan?" was just asked: the next message may be only the folder
    property bool askScanPending: false       // a scan the Ask tab started: its result is told in the chat when it ends
    property string askScanLabel: ""
    function askScan(sr, target) {
        function say(text, bad) { root.pushMsg({ role: "ai", text: text, bad: bad === true, live: false, actions: [], who: target }) }
        if (sr.path === "") { askWantsFolder = true; say("Which folder should I scan? Say it with its name, for example \"scan my Downloads\" or \"scan ~/projects\"."); return }
        askWantsFolder = false
        if (scanning) { say("A scan of " + (scanWhat.charAt(0) === "/" ? scanWhat : "~/" + (scanWhat === "." ? "" : scanWhat)) + " is still running. Ask again when it is done.", true); return }
        var home = Quickshell.env("HOME")
        var p = sr.path
        var abs = p === "~" ? home : (p.indexOf("~/") === 0 ? home + p.slice(1) : p)
        var rel = abs === home ? "." : (abs.indexOf(home + "/") === 0 ? abs.slice(home.length + 1) : abs)
        askScanLabel = p
        askScanPending = true
        say("Scanning " + p + (sr.whole ? " (your home folder: system files are watched all the time by the sensor)" : "") + "…")
        if (!scan(rel)) { askScanPending = false; say("The scan did not start.", true) }
    }
    function askScanDone() {
        if (!askScanPending) return
        askScanPending = false
        var s = scanSum, n = scanFound.length, lab = askScanLabel, txt, bad = false
        function nice(pth) { return pth.charAt(0) === "/" ? pth.replace(/^\/home\/[^/]+\//, "~/") : "~/" + pth }
        if (!s || s.failed) { txt = "I could not scan " + lab + ". Does it exist, and may the antivirus read it?"; bad = true }
        else if (n === 0) txt = "Scanned " + count(s.files) + " files in " + lab + " in " + s.seconds + " s: nothing found."
        else {
            bad = true
            txt = "Scanned " + count(s.files) + " files in " + lab + " in " + s.seconds + " s and found " + n + (n === 1 ? " file" : " files") + " with findings:\n" +
                  scanFound.slice(0, 5).map(function (o) { return "• " + nice(o.path) + (o.findings && o.findings.length ? "  (" + o.findings.map(function (f) { return f.detail || f.kind }).join(", ") + ")" : "") }).join("\n") +
                  (n > 5 ? "\nand " + (n - 5) + " more" : "") + "\nThe same list is on the Antivirus page."
        }
        pushMsg({ role: "ai", text: txt, bad: bad, live: false, actions: [], who: askTarget })
    }
    function runTest(name) { tab = "ask"; ask("/test" + (name && name !== "all" ? " " + name : "")) }
    function act(a) {
        if (a.test) { runTest(a.args[1] || "all"); return }
        // changes to the firewall need root: shown in the console with the exact command
        rootRun(shq(fwBin) + " " + a.args.map(shq).join(" "), "Firewall", "ai-firewall " + a.args.join(" "), "Do it")
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
        if (tabOff(t)) t = "overview"
        if (t === "overview" || t === "firewall" || t === "antivirus" || t === "exceptions" || t === "ask" || t === "clamav") tab = t
        open = true
        detectProc.running = true
        Qt.callLater(function () { root.focusRequested(root.tab === "ask" ? "ask" : "panel") })
    }
    function hide() { if (admJob !== null) admCancel(); open = false }
    function toggle() { if (open) hide(); else show("overview") }
    function toggleTo(t) { if (open && tab === t) hide(); else show(t) }      // the same page's entry pressed again closes the window
    // ---- life: one slow clock (`beat`, 0..1 every 4.2 s) drives the shield's ripples and the status dots, and `pageIn` (0..1) fades a
    // page in when you open the window or switch pages. Both only run while the window is open, on the page that uses them, and
    // stand still when motion is off (Settings > Motion), so nothing here costs anything at rest.
    readonly property bool live: open && pal && pal.motion > 0.05
    property real beat: 0
    property real pageIn: 1
    function stag(i) { return Math.max(0, Math.min(1, pageIn * 1.7 - i * 0.22)) }      // 0..1 for the i-th block of a page (0 first)
    NumberAnimation { target: root; property: "beat"; from: 0; to: 1; duration: root.ovTodo.length === 0 ? 4200 : 2800; loops: Animation.Infinite; running: root.live && root.tab === "overview" }
    NumberAnimation { id: pageAnim; target: root; property: "pageIn"; from: 0; to: 1; duration: root.pal ? root.pal.dSlow : 600; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal ? root.pal.curveDecel : [0.05, 0.7, 0.1, 1, 1, 1] }
    function tabOff(t) {
        return detected && ((t === "firewall" && !hasFw) || ((t === "antivirus" || t === "exceptions") && !hasAv) || (t === "ask" && !hasFw && !hasAv) || (t === "clamav" && !hasClam))
    }
    function setTab(t) {
        if (tabOff(t)) return
        if (t !== tab) pageAnim.restart()
        tab = t
        refresh()
        Qt.callLater(function () { root.focusRequested(t === "ask" ? "ask" : "panel") })
    }
    property bool linger: false
    onDecideOpenChanged: if (decideOpen && logOpen) logOpen = false
    onOpenChanged: if (!open) { logOpen = false; decideClose(); linger = true; lingerT.restart() } else { refresh(); pageAnim.restart() }
    // closed for good: let go of what the pages held (alert lists, scan results, the ClamAV report, which rows were open) and free the JS heap.
    // A one-time password snapshot is kept: dropping it would ask for the password again.
    Timer {
        id: lingerT
        interval: (root.pal ? root.pal.dMed : 300) + 80
        onTriggered: {
            root.linger = false
            if (root.open) return
            root.popped = false
            if (!root.avSnap) { root.avAlerts = []; root.avActions = []; root.avAlertsRaw = ""; root.avActionsRaw = "" }
            root.scanFound = []; root.scanSum = null
            root.clam = null; root.exc = null
            root.fwLog = []; root.fwFindings = []; root.fwDoctorRan = false; root.fwSub = "live"
            root.decideRes = null; root.decideErr = ""; root.decideSteps = []; root.decideSkipped = false
            root.reviewItems = []; root.reviewRes = null; root.reviewErr = ""; root.reviewNote = ""; root.reviewStep = ""; root.reviewAckState = 0; root.reviewTotal = 0
            root.avOpenKeys = ({})
            gc()
        }
    }

    // ---------------------------------------------------------------- pieces
    component Label: Text {
        color: root.pal.muted
        font.family: root.pal.uiFont
        font.pixelSize: root.pal.tCap
        font.weight: Font.Medium
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
        radius: 10
        opacity: disabled ? 0.4 : 1
        color: primary ? (bMa.containsMouse && !disabled ? Qt.lighter(root.pal.accent, 1.08) : root.pal.accent)
                       : (bMa.containsMouse && !disabled ? root.pal.fillHover : root.pal.fill)
        scale: bMa.pressed && !disabled ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Behavior on scale { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Row {
            id: bRow
            anchors.centerIn: parent
            spacing: 8
            Glyph { visible: b.glyph !== 0; code: b.glyph; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: 15; color: b.primary ? root.pal.bg : root.pal.text }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: b.label
                color: b.primary ? root.pal.bg : root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody - 1
                font.weight: b.primary ? Font.Medium : Font.Medium
            }
        }
        MouseArea { id: bMa; anchors.fill: parent; hoverEnabled: true; cursorShape: b.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!b.disabled) b.clicked() }
    }
    component Dot: Rectangle { width: 8; height: 8; radius: 4 }
    // the AI card's pieces: a tinted pill (verdict, count) and a figure tile (alerts read / cleared / waiting)
    // the three soft dots while something works
    component Working: Row {
        id: wk
        spacing: 4
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
            spacing: 4
            Row {
                spacing: 8
                Text {
                    id: stV
                    text: st.value
                    color: st.tone
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tTitle + 7
                    font.weight: Font.Medium
                    transformOrigin: Item.Left
                    onTextChanged: if (root.live) stPop.restart()          // a changed figure gives a small pop
                    SequentialAnimation {
                        id: stPop
                        NumberAnimation { target: stV; property: "scale"; to: 1.14; duration: 110; easing.type: Easing.OutQuad }
                        NumberAnimation { target: stV; property: "scale"; to: 1; duration: 320; easing.type: Easing.OutBack }
                    }
                }
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
                font.weight: Font.Medium
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
        signal clicked()
        height: 48
        radius: root.pal.rSm
        color: lrMa.containsMouse ? root.pal.fill : "transparent"
        MouseArea { id: lrMa; anchors.fill: parent; hoverEnabled: true; onClicked: lr.clicked() }
        Rectangle {
            id: lrMark
            x: 8
            width: lrMa.containsMouse ? 4 : 3
            height: lrMa.containsMouse ? 30 : 26
            radius: 2
            anchors.verticalCenter: parent.verticalCenter
            color: lr.mark
            Behavior on height { NumberAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            Behavior on width { NumberAnimation { duration: root.pal.dFast } }
        }
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
            Text { id: lrChipT; anchors.centerIn: parent; text: lr.chip; color: lr.chipTone; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap - 1; font.weight: Font.Medium }
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
        opacity: available ? 1 : 0.6   // unslop: still readable when the tool is not installed
        color: on ? Qt.alpha(root.pal.accent, 0.14) : (nvMa.containsMouse && available ? root.pal.fill : "transparent")
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Glyph { id: nvG; x: 14; anchors.verticalCenter: parent.verticalCenter; code: nv.glyph; font.pixelSize: 18; color: nv.on ? root.pal.accent : root.pal.muted }
        Text { anchors { left: nvG.right; leftMargin: 12; verticalCenter: parent.verticalCenter } text: nv.label; color: nv.on ? root.pal.text : Qt.alpha(root.pal.text, 0.85); font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: nv.on ? Font.Medium : Font.Medium }
        Rectangle {
            visible: nv.badge > 0
            anchors { right: nvDot.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            width: Math.max(20, nvB.implicitWidth + 12); height: 20; radius: 10
            color: Qt.alpha(root.pal.warn, 0.18)
            Text { id: nvB; anchors.centerIn: parent; text: nv.badge; color: root.pal.warn; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
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
            Text { text: ph.status; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle + 5; font.weight: Font.Medium }
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
    // a module on the overview: its state, three figures and a live line or graph at the bottom; the card opens its page
    component ModuleCard: Rectangle {
        id: mc
        property string key: ""
        property string name: ""
        property int glyph: 0
        property string status: ""
        property color tone: root.pal.muted
        property bool available: true
        property var figures: []            // [[value, label, color], ...]
        property var hist: []               // a live graph along the bottom (the firewall's traffic); empty = a quiet "watching" line instead
        property bool watching: false       // the "watching" line is shown (the module is running)
        default property alias actions: mcAct.data
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.preferredHeight: 196
        radius: root.pal.rLg
        color: mcMa.containsMouse && available ? root.pal.fillHover : root.pal.fill
        border.width: 1
        border.color: Qt.alpha(mc.tone, mcMa.containsMouse && available ? 0.5 : 0)
        opacity: available ? 1 : 0.6
        scale: mcMa.containsMouse && available ? 1.012 : 1
        Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
        Behavior on border.color { ColorAnimation { duration: root.pal.dFast } }
        Behavior on scale { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
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
                    // a soft halo that breathes with the clock
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width; height: parent.height; radius: parent.radius
                        color: "transparent"
                        border.width: 1
                        border.color: mc.tone
                        visible: mc.available && root.live
                        scale: 1 + 0.22 * ((root.beat * 2) % 1)
                        opacity: 0.4 * (1 - ((root.beat * 2) % 1))
                    }
                }
                Column {
                    Layout.fillWidth: true
                    Text { text: mc.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.Medium }
                    Row {
                        spacing: 6
                        Dot { anchors.verticalCenter: parent.verticalCenter; color: mc.tone; width: 6; height: 6; radius: 3; opacity: mc.available && root.live ? 0.65 + 0.35 * Math.sin(root.beat * Math.PI * 2) : 1 }
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
                        Text {
                            id: fv
                            text: modelData[0]
                            color: modelData[2] || root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tTitle + 3
                            font.weight: Font.Medium
                            transformOrigin: Item.Left
                            onTextChanged: if (root.live) fvPop.restart()
                            SequentialAnimation {
                                id: fvPop
                                NumberAnimation { target: fv; property: "scale"; to: 1.16; duration: 110; easing.type: Easing.OutQuad }
                                NumberAnimation { target: fv; property: "scale"; to: 1; duration: 320; easing.type: Easing.OutBack }
                            }
                        }
                        Small { text: modelData[1]; font.pixelSize: root.pal.tCap }
                    }
                }
            }
            // the bottom of the card: the live graph, or (no graph) a quiet line with a glint that drifts along it while the module runs
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: mc.available
                Spark { anchors.fill: parent; anchors.topMargin: 2; hist: mc.hist; visible: mc.hist.length > 1 }
                Item {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6 }
                    height: 3
                    visible: mc.hist.length <= 1 && mc.watching
                    clip: true
                    Rectangle { anchors.fill: parent; radius: 2; color: Qt.alpha(mc.tone, 0.16) }
                    Rectangle {
                        width: parent.width * 0.22; height: parent.height; radius: 2
                        color: mc.tone
                        opacity: 0.85
                        x: (parent.width - width) * (0.5 - 0.5 * Math.cos(root.beat * Math.PI * 2))
                    }
                }
            }
            Row { id: mcAct; spacing: 8; visible: mc.available && children.length > 0 }
        }
    }

    // ================================================================ the window
    LazyLoader {
        active: root.open || root.linger
        Host {
            id: win
            desktop: root.deskMode
            title: "Security"
            deskWidth: 1140
            deskHeight: 780
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
                    if (e.key === Qt.Key_Escape) { if (root.logOpen) root.logOpen = false; else if (root.decideOpen) root.decideClose(); else root.hide(); e.accepted = true; return }
                    // 1-5 switch pages
                    var pages = ["overview", "firewall", "antivirus", "exceptions", "ask", "clamav"], i = e.key - Qt.Key_1
                    if (i >= 0 && i < pages.length) { root.setTab(pages[i]); e.accepted = true }
                }
                Connections {
                    target: root
                    function onFocusRequested(what) { if (what === "ask") askIn.forceActiveFocus(); else qp.forceActiveFocus() }
                }

                Rectangle { visible: !win.desktop; anchors.fill: parent; color: Qt.alpha(root.pal.bg, 0.5 * Math.max(0, Math.min(1, qp.reveal))) }

                Glass {
                    id: panel
                    pal: root.pal
                    // while the AI's card is out beside it, the window gives up a little width on a smaller screen so both fit (never below 820)
                    width: win.desktop ? qp.width : Math.min(1140, qp.width - 80, (root.decideOpen && decSide.beside) ? Math.max(820, qp.width - decSide.cardW - decSide.gap - 48) : 100000, (root.logOpen && logSide.beside) ? Math.max(820, qp.width - logSide.cardW - logSide.gap - 48) : 100000)
                    Behavior on width { enabled: !win.desktop; NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    height: win.desktop ? qp.height : Math.min(780, qp.height - 80)
                    radius: win.desktop ? 0 : root.pal.rXl
                    opacityBody: 0.97
                    border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: -decSide.shiftBy * decSide.prog - logSide.shiftBy * logSide.prog        // the window and the AI's / log card sit centred together
                    opacity: win.desktop ? 1 : qp.reveal
                    scale: win.desktop ? 1 : 0.97 + 0.03 * qp.reveal
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ======================== the head, in the middle
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 96

                            CalmHeader {
                                anchors.fill: parent
                                anchors.leftMargin: 28
                                anchors.rightMargin: 16
                                pal: root.pal
                                glyph: 0xF0565
                                title: "Security"
                                sub: !root.detected ? "checking…"
                                     : root.overall + (root.posture !== "" ? "  ·  " + root.cap(root.posture) : "")
                                subTone: root.overallTone

                                CalmIconBtn {
                                    pal: root.pal
                                    glyph: 0xF04D9
                                    tip: "Diagnose"
                                    onClicked: root.consoleRequested(root.avDiagCmd)
                                }
                                CalmIconBtn {
                                    pal: root.pal
                                    glyph: root.popped ? 0xF0141 : 0xF03CC
                                    active: root.popped
                                    tip: root.popped ? "Popped out" : "Pop out"
                                    onClicked: root.popped = !root.popped
                                }
                                CalmIconBtn {
                                    pal: root.pal
                                    glyph: 0xF0156
                                    tip: "Close"
                                    onClicked: root.hide()
                                }
                            }
                        }

                        // ======================== the pages, as icons in the middle
                        CalmNav {
                            Layout.alignment: Qt.AlignHCenter
                            pal: root.pal
                            items: root.navItems
                            current: root.tab
                            onPicked: key => root.setTab(key)
                        }

                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 28
                            Layout.rightMargin: 28
                            Layout.topMargin: 6
                            visible: root.note !== ""
                            horizontalAlignment: Text.AlignHCenter
                            text: root.note
                            color: root.noteBad ? root.pal.bad : root.pal.good
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tCap
                            elide: Text.ElideRight
                        }

                        // ======================== the page
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            // ---- asks for the password for an approve / reject / undo / allow, and does it here
                            Rectangle {
                                id: admBar
                                z: 100
                                visible: root.admJob !== null
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 20 }
                                implicitHeight: admCol.implicitHeight + 28
                                height: implicitHeight
                                radius: root.pal.rLg
                                color: Qt.rgba(root.pal.bg.r, root.pal.bg.g, root.pal.bg.b, 0.98)
                                border.width: 1
                                border.color: Qt.alpha(root.admErr !== "" ? root.pal.bad : root.pal.accent, 0.5)
                                MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }
                                Column {
                                    id: admCol
                                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; leftMargin: 20; rightMargin: 20 }
                                    spacing: 8
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: root.admJob ? root.admJob.title : ""
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody
                                        font.weight: Font.Medium
                                    }
                                    Text {
                                        width: parent.width
                                        visible: text !== ""
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 3
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                        text: root.admErr !== "" ? root.admErr : (root.admJob ? root.admJob.detail : "")
                                        color: root.admErr !== "" ? root.pal.bad : Qt.alpha(root.pal.text, 0.75)
                                        font.family: root.pal.uiFont
                                        font.pixelSize: root.pal.tBody - 1
                                    }
                                    Row {
                                        spacing: 8
                                        Rectangle {
                                            width: Math.min(300, admCol.width - 260)
                                            height: 40
                                            radius: 20
                                            color: root.pal.fill
                                            border.width: 1
                                            border.color: admPw.activeFocus ? root.pal.lineFocus : "transparent"
                                            TextInput {
                                                id: admPw
                                                anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                                echoMode: TextInput.Password
                                                passwordCharacter: "\u2022"
                                                enabled: !root.admBusy
                                                color: root.pal.text
                                                selectionColor: Qt.alpha(root.pal.accent, 0.35)
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody
                                                clip: true
                                                maximumLength: 256
                                                Text { visible: parent.text === "" && !parent.activeFocus; text: "Your password (for sudo)"; color: root.pal.muted; font: parent.font }
                                                function go() { var pw = text; text = ""; root.admSubmit(pw) }
                                                onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
                                                Keys.onReturnPressed: go()
                                                Keys.onEnterPressed: go()
                                                Keys.onEscapePressed: { text = ""; root.admCancel() }
                                                Connections { target: root; function onAdmFocusRequested() { admPw.text = ""; admPw.forceActiveFocus() } }
                                            }
                                        }
                                        Btn { label: root.admBusy ? "Working…" : (root.admJob ? root.admJob.button : ""); glyph: 0xF012C; primary: true; disabled: root.admBusy; onClicked: admPw.go() }
                                        Btn { label: "Cancel"; glyph: 0xF0156; onClicked: { admPw.text = ""; root.admCancel() } }
                                    }
                                    Row {
                                        spacing: 8
                                        Chip { pal: root.pal; implicitHeight: 30; label: "Remember until I log out"; glyph: String.fromCodePoint(root.pwRemember ? 0xF012C : 0xF0156); on: root.pwRemember; onClicked: root.pwRemember = !root.pwRemember }
                                    }
                                }
                            }

                            // ---- nothing installed
                            Empty {
                                visible: root.detected && !root.hasFw && !root.hasAv && !root.hasClam
                                glyph: 0xF099E
                                tone: root.pal.muted
                                text: "Not installed"
                            }

                            // ---- overview: how it is (one calm hero), what needs you, the two modules, the latest events
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 32
                                anchors.rightMargin: 32
                                anchors.topMargin: 12
                                anchors.bottomMargin: 24
                                spacing: 16
                                visible: root.tab === "overview" && (root.hasFw || root.hasAv)

                                // the hero: a shield in two soft rings, the verdict in a few words under it. The colour is the whole message
                                // (green: protected, amber: something waits for you, red: a module is down). Nothing here animates at rest.
                                Item {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 148
                                    opacity: root.stag(0)
                                    transform: Translate { y: (1 - root.stag(0)) * 14 }
                                    Item {
                                        id: hero
                                        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top }
                                        width: 88; height: 88
                                        // two ripples leave the shield in turn (calm when all is well, quicker when something waits)
                                        Repeater {
                                            model: root.live ? 2 : 0
                                            delegate: Rectangle {
                                                id: rp
                                                required property int index
                                                readonly property real t: (root.beat + index * 0.5) % 1
                                                anchors.centerIn: parent
                                                width: 88; height: 88; radius: 44
                                                color: "transparent"
                                                border.width: 1.5
                                                border.color: root.overallColor
                                                scale: 1 + 0.8 * t
                                                opacity: 0.34 * (1 - t) * (1 - t)
                                            }
                                        }
                                        Rectangle { anchors.centerIn: parent; width: 88; height: 88; radius: 44; color: Qt.alpha(root.overallColor, 0.07); border.width: 1; border.color: Qt.alpha(root.overallColor, 0.18) }
                                        // a small light that circles the outer ring
                                        Item {
                                            anchors.fill: parent
                                            visible: root.live
                                            NumberAnimation on rotation { from: 0; to: 360; duration: root.ovTodo.length === 0 ? 16000 : 7000; loops: Animation.Infinite; running: root.live && root.tab === "overview" }
                                            Rectangle { x: 41; y: -3; width: 6; height: 6; radius: 3; color: root.overallColor; opacity: 0.9 }
                                            Rectangle { x: 41; y: 85; width: 4; height: 4; radius: 2; color: root.overallColor; opacity: 0.35 }
                                        }
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 64; height: 64; radius: 32
                                            color: Qt.alpha(root.overallColor, 0.14)
                                            scale: root.live ? 1 + 0.045 * Math.sin(root.beat * Math.PI * 2) : 1
                                        }
                                        Glyph {
                                            anchors.centerIn: parent
                                            code: root.ovTodo.length === 0 ? 0xF0565 : 0xF0026
                                            font.pixelSize: 32
                                            color: root.overallColor
                                            scale: root.live ? 1 + 0.03 * Math.sin(root.beat * Math.PI * 2) : 1
                                        }
                                    }
                                    Column {
                                        anchors { horizontalCenter: parent.horizontalCenter; top: hero.bottom; topMargin: 12 }
                                        width: parent.width
                                        spacing: 4
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            text: root.ovHead
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tTitle + 4
                                            font.weight: Font.Medium
                                            font.letterSpacing: -0.2
                                            elide: Text.ElideRight
                                        }
                                        Small {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            visible: root.ovTodo.length === 0
                                            text: root.ovSub
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: root.ovTodo.length > 0
                                    opacity: root.stag(1)
                                    transform: Translate { y: (1 - root.stag(1)) * 14 }
                                    Repeater {
                                        model: root.ovTodo
                                        delegate: Rectangle {
                                            id: td
                                            required property var modelData
                                            readonly property color accentCol: modelData.tone === "bad" ? root.pal.bad : root.pal.warn
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 64
                                            radius: root.pal.rLg
                                            color: Qt.alpha(accentCol, tdMa.containsMouse ? 0.13 : 0.085)
                                            MouseArea {
                                                id: tdMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.ovGo(td.modelData.key)
                                            }
                                            Rectangle {
                                                id: tdIc
                                                x: 14
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 38
                                                height: 38
                                                radius: 13
                                                color: Qt.alpha(td.accentCol, 0.16)
                                                Glyph {
                                                    anchors.centerIn: parent
                                                    code: td.modelData.glyph
                                                    font.pixelSize: 19
                                                    color: td.accentCol
                                                }
                                            }
                                            Column {
                                                anchors.left: tdIc.right
                                                anchors.leftMargin: 14
                                                anchors.right: tdGo.left
                                                anchors.rightMargin: 12
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2
                                                Text {
                                                    width: parent.width
                                                    elide: Text.ElideRight
                                                    text: td.modelData.title
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                    font.weight: Font.Medium
                                                }
                                                Small {
                                                    width: parent.width
                                                    text: td.modelData.sub
                                                }
                                            }
                                            // the whole row is the action; this is the quiet affordance, not a second button
                                            Glyph {
                                                id: tdGo
                                                anchors.right: parent.right
                                                anchors.rightMargin: 16
                                                anchors.verticalCenter: parent.verticalCenter
                                                code: 0xF0142
                                                font.pixelSize: 15
                                                color: Qt.alpha(root.pal.text, tdMa.containsMouse ? 0.8 : 0.45)
                                            }
                                        }
                                    }
                                    Btn {
                                        Layout.alignment: Qt.AlignHCenter
                                        visible: root.aiOn
                                        glyph: 0xF0B79
                                        label: root.cardBusy ? "Thinking…" : "Let AI decide for this PC"
                                        disabled: root.cardBusy
                                        onClicked: root.decideStart()
                                    }
                                }

                                // the two modules: a name, how it is doing, three figures. The whole card opens its page.
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 14
                                    opacity: root.stag(2)
                                    transform: Translate { y: (1 - root.stag(2)) * 14 }
                                    ModuleCard {
                                        key: "firewall"; name: "Firewall"; glyph: 0xF1A11
                                        available: root.hasFw
                                        watching: root.hasFw && root.fwAlive
                                        hist: root.fwHist
                                        tone: root.fwColor
                                        status: root.hasFw ? root.fwState + (root.posture !== "" && root.posture !== "secure" ? "  ·  " + root.posture : "") : "Not installed"
                                        figures: root.fw ? [
                                            [root.count((root.fw.dropped_policy || 0) + (root.fw.dropped_blocklist || 0) + (root.fw.dropped_feed || 0)), "blocked", root.pal.warn],
                                            [String(root.bansCount), "banned", root.bansCount > 0 ? root.pal.bad : root.pal.text],
                                            [root.count(root.fw.passed || 0), "let through", root.pal.good]
                                        ] : []
                                    }
                                    ModuleCard {
                                        key: "antivirus"; name: "Antivirus"; glyph: 0xF13B6
                                        available: root.hasAv
                                        watching: root.avRunning
                                        tone: root.avColor
                                        status: root.hasAv ? root.avState + (root.av && root.av.mode ? "  ·  " + root.av.mode : "") : "Not installed"
                                        figures: root.hasAv ? [
                                            [root.avKnown ? String(root.avUnacked) : "–", "to review", root.avUnacked > 0 ? root.pal.warn : root.pal.text],
                                            [root.avKnown ? String(root.avPending) : "–", "waiting for OK", root.avPending > 0 ? root.pal.warn : root.pal.text],
                                            [root.avKnown ? String(root.avHeld.length) : "–", "held back", root.pal.text]
                                        ] : []
                                    }
                                }

                                // the latest events of both, on one soft surface
                                Rectangle {
                                    id: latBox
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 0
                                    Layout.preferredHeight: 0
                                    Layout.maximumHeight: 24 + 24 + Math.min(3, root.feed.length) * 50
                                    // as many rows as the window has room for: the box takes what is left and never runs out of the window
                                    readonly property int rows: Math.max(0, Math.min(3, Math.floor((height - 24 - 24 + 2) / 50)))
                                    visible: root.feed.length > 0 && rows > 0
                                    clip: true
                                    opacity: root.stag(3)
                                    transform: Translate { y: (1 - root.stag(3)) * 14 }
                                    radius: root.pal.rLg
                                    color: root.pal.fill
                                    ColumnLayout {
                                        id: latCol
                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                        spacing: 2
                                        Label { Layout.leftMargin: 8; Layout.bottomMargin: 2; text: "Latest" }
                                        Repeater {
                                            model: root.feed.slice(0, latBox.rows)
                                            delegate: ListRow {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                lead: root.ago(modelData.at)
                                                title: modelData.title
                                                sub: (modelData.who === "firewall" ? "Firewall" : "Antivirus") + "  ·  " + modelData.sub
                                                mark: root.sevColor(modelData.tone)
                                            }
                                        }
                                    }
                                }
                                Item { Layout.fillHeight: latBox.rows === 0; Layout.preferredHeight: 0 }
                            }

                            // ---- firewall
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 20
                                visible: root.tab === "firewall" && root.hasFw
                                opacity: root.pageIn
                                transform: Translate { y: (1 - root.pageIn) * 10 }

                                PageHead {
                                    glyph: 0xF1A11
                                    status: root.fwState
                                    tone: root.fwColor
                                    detail: root.fw === null ? "" : [root.fw.interface || "no uplink", (root.fw.xdp_mode || "-") + " XDP",
                                        "up " + root.dur(Math.max(1, (root.fw.updated_unix || 0) - (root.fw.started_unix || 0))),
                                        "open tcp " + ((root.fw.allow_tcp || []).join(" ") || "none")].join("  ·  ")
                                    CalmIconBtn { pal: root.pal; glyph: 0xF0668; tip: "Test the firewall"; onClicked: root.runTest("all") }
                                    CalmIconBtn { pal: root.pal; glyph: 0xF04D9; tip: "Doctor (check and fix)"; onClicked: root.consoleRequested("sudo " + root.fwBin + " doctor --fix") }
                                    CalmIconBtn { pal: root.pal; glyph: 0xF0A07; primary: true; tip: "Open the live dashboard"; onClicked: root.terminalRequested("sudo " + root.shq(root.fwBin) + " top") }
                                }

                                // the config file is broken: say so, the last config that worked is what applies
                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: root.fw !== null && !!root.fw.config_error
                                    implicitHeight: fwCfgErr.implicitHeight + 22
                                    radius: root.pal.rMd
                                    color: Qt.alpha(root.pal.bad, 0.12)
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 16; rightMargin: 10 }
                                        spacing: 12
                                        Text {
                                            id: fwCfgErr
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            text: "The config file has an error, so the last config that worked is in force.\n" + (root.fw && root.fw.config_error ? root.fw.config_error : "")
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tCap
                                        }
                                        Btn { label: "Edit config"; glyph: 0xF03EB; onClicked: root.terminalRequested("sudoedit /etc/ai-firewall/config.toml") }
                                    }
                                }

                                // Live | Rules | Feeds | History | Doctor: what the separate Firewall Center used to be
                                Row {
                                    spacing: 6
                                    Repeater {
                                        model: [{ k: "live", l: "Live" }, { k: "rules", l: "Rules" }, { k: "feeds", l: "Feeds" }, { k: "history", l: "History" }, { k: "doctor", l: "Doctor" }]
                                        delegate: Rectangle {
                                            id: fsb
                                            required property var modelData
                                            readonly property bool on: root.fwSub === modelData.k
                                            implicitWidth: fsbT.implicitWidth + 26
                                            implicitHeight: 30
                                            radius: 15
                                            color: on ? Qt.alpha(root.pal.accent, 0.16) : (fsbMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                            Text {
                                                id: fsbT
                                                anchors.centerIn: parent
                                                text: fsb.modelData.l + (fsb.modelData.k === "doctor" && root.fwFindings.some(function (f) { return f.severity === "warn" || f.severity === "fail" }) ? "  •" : "")
                                                color: fsb.on ? root.pal.accent : root.pal.muted
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody - 1
                                                font.weight: Font.Medium
                                            }
                                            MouseArea { id: fsbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.fwSubGo(fsb.modelData.k) }
                                        }
                                    }
                                }

                                Strip {
                                    visible: root.fwSub === "live"
                                    Stat { divider: false; label: "Passed"; value: root.count(root.fw ? root.fw.passed : 0); sub: root.fwRate.passed + "/s"; tone: root.pal.good }
                                    Stat { label: "Closed ports"; value: root.count(root.fw ? root.fw.dropped_policy : 0); tone: root.pal.warn }
                                    Stat { label: "From banned"; value: root.count(root.fw ? root.fw.dropped_blocklist : 0); sub: root.bansCount + " banned"; tone: root.pal.bad }
                                    Stat { label: "Blocklists"; value: root.count(root.fw ? root.fw.dropped_feed : 0); sub: root.count(root.fw ? root.fw.feed_networks : 0) + " nets"; tone: root.pal.accent2 }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: root.fwSub === "live" && root.fwHist.length > 1
                                    RowLayout {
                                        Layout.leftMargin: 4
                                        spacing: 14
                                        Label { text: "Traffic"; Layout.fillWidth: true }
                                        Row { spacing: 4; Dot { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; color: root.pal.accent } Small { text: root.fwRate.passed + "/s in" } }
                                        Row { spacing: 4; Dot { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; color: root.pal.bad } Small { text: root.fwRate.dropped + "/s dropped" } }
                                    }
                                    Spark { Layout.fillWidth: true; implicitHeight: 46; hist: root.fwHist }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 24
                                    visible: root.fwSub === "live"
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
                                                onAct: root.rootRun(root.shq(root.fwBin) + " unban " + root.shq(modelData.ip), "Unban " + modelData.ip, "Lets " + modelData.ip + " connect again.", "Unban")
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

                                // ---- Rules: the network profile, open ports, narrower rules; ports can be opened from here
                                Flickable {
                                    id: fwRulesFl
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.fwSub === "rules"
                                    clip: true
                                    contentWidth: width
                                    contentHeight: fwRulesCol.implicitHeight
                                    boundsBehavior: Flickable.StopAtBounds
                                    ColumnLayout {
                                        id: fwRulesCol
                                        width: fwRulesFl.width
                                        spacing: 10
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 12
                                            Small { Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: "Nothing gets in unless a port is open below; everything you start yourself can always go out. Changes to the config apply within 3 seconds." }
                                            Btn { label: "Edit config"; glyph: 0xF03EB; onClicked: root.terminalRequested("sudoedit /etc/ai-firewall/config.toml") }
                                        }
                                        FwCard {
                                            pal: root.pal
                                            title: "Network profile"
                                            value: root.fw ? (root.fw.profile || "default") + ((root.fw.profiles || []).length > 0 ? "   (profiles: " + root.fw.profiles.join(", ") + ")" : "   (no profiles set up)") : "–"
                                            note: "A profile can open different ports per network (home wifi vs public), picked by the connection's name."
                                        }
                                        FwCard { pal: root.pal; title: "Open to everyone · TCP"; mono: true; value: root.fw && (root.fw.allow_tcp || []).length ? root.fw.allow_tcp.join("  ") : "none" }
                                        FwCard {
                                            pal: root.pal
                                            title: "Open to everyone · UDP"
                                            mono: true
                                            value: root.fw && (root.fw.allow_udp || []).length ? root.fw.allow_udp.join("  ") : "none"
                                            note: root.fw && root.fw.udp_strict ? "Other UDP only gets in as a reply to something this machine sent." : "UDP to high ports is let in as replies (udp_strict is off)."
                                        }
                                        FwCard {
                                            pal: root.pal
                                            title: "Narrower rules"
                                            mono: root.fw !== null && (root.fw.rules || []).length > 0
                                            value: root.fw && (root.fw.rules || []).length ? root.fw.rules.join("\n") : "none (e.g. ssh only from your LAN, or a limit against password guessing)"
                                        }
                                        FwCard { pal: root.pal; title: "Ping"; value: root.fw && root.fw.ping === false ? "ignored" : "answered" }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Rectangle {
                                                Layout.fillWidth: true
                                                implicitHeight: 40
                                                radius: 20
                                                color: root.pal.fill
                                                border.width: fwPort.activeFocus ? 1 : 0
                                                border.color: root.pal.lineFocus
                                                TextInput {
                                                    id: fwPort
                                                    anchors { fill: parent; leftMargin: 20; rightMargin: 20 }
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                    selectByMouse: true
                                                    clip: true
                                                    function go() {
                                                        var m = text.trim().match(/^(tcp|udp)\s+(\d{1,5}(-\d{1,5})?)$/i)
                                                        if (m) { root.sudoThen("open " + m[1].toLowerCase() + " " + m[2]); text = "" }
                                                    }
                                                    onAccepted: go()
                                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: fwPort.text === ""; text: "tcp 22  or  udp 51820  or  tcp 1714-1764"; color: root.pal.muted; font: fwPort.font }
                                                }
                                            }
                                            Btn { label: "Open port"; onClicked: fwPort.go() }
                                        }
                                    }
                                }

                                // ---- Feeds: the lists of known-bad networks it loads
                                Flickable {
                                    id: fwFeedsFl
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.fwSub === "feeds"
                                    clip: true
                                    contentWidth: width
                                    contentHeight: fwFeedsCol.implicitHeight
                                    boundsBehavior: Flickable.StopAtBounds
                                    ColumnLayout {
                                        id: fwFeedsCol
                                        width: fwFeedsFl.width
                                        spacing: 8
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 12
                                            Small { Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: "Public lists of networks known for attacks, spam and hijacking. Everything from them is dropped before it reaches anything else. Private and LAN ranges are always taken out of the lists. Pick lists in the config ([feeds])." }
                                            Btn { label: "Refresh now"; glyph: 0xF0450; onClicked: root.sudoThen("feeds --refresh") }
                                        }
                                        Repeater {
                                            model: root.fw ? (root.fw.feeds || []) : []
                                            delegate: Rectangle {
                                                id: fdRow
                                                required property var modelData
                                                Layout.fillWidth: true
                                                implicitHeight: 56
                                                radius: root.pal.rMd
                                                color: root.pal.fill
                                                RowLayout {
                                                    anchors { fill: parent; leftMargin: 18; rightMargin: 18 }
                                                    spacing: 14
                                                    Column {
                                                        Layout.fillWidth: true
                                                        spacing: 2
                                                        Text { text: fdRow.modelData.name; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                        Text {
                                                            text: fdRow.modelData.updated_unix ? "updated " + root.ago(fdRow.modelData.updated_unix) + " ago" : "not downloaded yet"
                                                            color: fdRow.modelData.error ? root.pal.warn : root.pal.muted
                                                            font.family: root.pal.uiFont
                                                            font.pixelSize: root.pal.tCap
                                                        }
                                                    }
                                                    Text { text: root.count(fdRow.modelData.entries) + " networks"; color: root.pal.accent2; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody }
                                                }
                                            }
                                        }
                                        Small { visible: !root.fw || (root.fw.feeds || []).length === 0; text: "No lists turned on." }
                                    }
                                }

                                // ---- History: what the firewall did
                                ListView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.fwSub === "history"
                                    clip: true
                                    spacing: 4
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: root.fwSub === "history" ? root.fwLog : []
                                    delegate: RowLayout {
                                        id: fhRow
                                        required property var modelData
                                        width: ListView.view.width
                                        spacing: 12
                                        Text { text: root.ago(fhRow.modelData.at_unix) + " ago"; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 80 }
                                        Rectangle {
                                            implicitWidth: fhKind.implicitWidth + 16; implicitHeight: 20; radius: 10
                                            readonly property color kc: fhRow.modelData.kind === "ban" ? root.pal.bad : fhRow.modelData.kind === "profile" ? root.pal.accent : fhRow.modelData.kind === "feeds" ? root.pal.accent2 : root.pal.good
                                            color: Qt.alpha(kc, 0.15)
                                            Text { id: fhKind; anchors.centerIn: parent; text: fhRow.modelData.kind; color: parent.kc; font.family: root.pal.uiFont; font.pixelSize: 10 }
                                        }
                                        Text { text: fhRow.modelData.ip || ""; color: root.pal.text; font.family: root.pal.mono; font.pixelSize: root.pal.tCap; Layout.preferredWidth: 180; elide: Text.ElideRight }
                                        Text { text: fhRow.modelData.detail || ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; Layout.fillWidth: true; elide: Text.ElideRight }
                                    }
                                }
                                Small { visible: root.fwSub === "history" && root.fwLog.length === 0; text: "Nothing yet." }

                                // ---- Doctor: what is wrong with the setup, each with a fix button
                                Flickable {
                                    id: fwDocFl
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.fwSub === "doctor"
                                    clip: true
                                    contentWidth: width
                                    contentHeight: fwDocCol.implicitHeight
                                    boundsBehavior: Flickable.StopAtBounds
                                    ColumnLayout {
                                        id: fwDocCol
                                        width: fwDocFl.width
                                        spacing: 8
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Small { Layout.fillWidth: true; text: fwDoctorProc.running ? "Checking…" : "Checks the daemon, the interface, the config and your network setup." }
                                            Btn { label: "Check again"; glyph: 0xF0450; disabled: fwDoctorProc.running; onClicked: if (!fwDoctorProc.running) fwDoctorProc.running = true }
                                            Btn { label: "Full check (admin)"; glyph: 0xF04D9; onClicked: root.sudoThen("doctor --fix") }
                                        }
                                        Repeater {
                                            model: root.fwFindings.filter(function (f) { return f.severity === "warn" || f.severity === "fail" })
                                            delegate: Rectangle {
                                                id: fdf
                                                required property var modelData
                                                Layout.fillWidth: true
                                                implicitHeight: fdfCol.implicitHeight + 20
                                                radius: root.pal.rMd
                                                color: Qt.alpha(fdf.modelData.severity === "fail" ? root.pal.bad : root.pal.warn, 0.10)
                                                RowLayout {
                                                    anchors { fill: parent; leftMargin: 16; rightMargin: 10 }
                                                    spacing: 12
                                                    Column {
                                                        id: fdfCol
                                                        Layout.fillWidth: true
                                                        spacing: 2
                                                        Text { text: fdf.modelData.title; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium; width: parent.width; elide: Text.ElideRight }
                                                        Text { text: fdf.modelData.detail || ""; color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; width: parent.width; wrapMode: Text.WordWrap }
                                                    }
                                                    Btn { visible: !!fdf.modelData.fix; label: "Fix"; onClicked: root.sudoThen("fix " + fdf.modelData.fix) }
                                                }
                                            }
                                        }
                                        Text {
                                            visible: root.fwDoctorRan && root.fwFindings.filter(function (f) { return f.severity === "warn" || f.severity === "fail" }).length === 0
                                            text: "The doctor found nothing wrong" + (root.fwFindings.some(function (f) { return f.title === "Partial check" }) ? " (the admin check also looks at firewall rules and bans)." : ".")
                                            color: root.pal.good
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                        }
                                    }
                                }
                            }

                            // ---- antivirus
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 16
                                visible: root.tab === "antivirus" && root.hasAv
                                opacity: root.pageIn
                                transform: Translate { y: (1 - root.pageIn) * 10 }

                                PageHead {
                                    glyph: 0xF13B6
                                    status: root.avState
                                    tone: root.avColor
                                    detail: root.av === null ? "" : [root.av.mode || "-", "v" + root.av.version,
                                        root.av.last_event_unix ? "last event " + root.ago(root.av.last_event_unix) + " ago" : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                    CalmIconBtn { pal: root.pal; glyph: 0xF018D; primary: root.logOpen; tip: root.logOpen ? "Close the log" : "Open the log"; onClicked: root.logToggle() }
                                    CalmIconBtn {
                                        pal: root.pal
                                        readonly property bool aiOn: !!(root.av && root.av.services && root.av.services.analyzer === "active")
                                        glyph: 0xF0B79
                                        active: aiOn
                                        tip: aiOn ? "AI review is on" : "Turn on AI review"
                                        onClicked: root.consoleRequested("bash " + Quickshell.env("HOME") + "/.config/Halcyon/scripts/antivirus-ai.sh " + (aiOn ? "off" : "on"))
                                    }
                                    CalmIconBtn { pal: root.pal; glyph: 0xF02DC; tip: "Scan home"; enabledBtn: !root.scanning; onClicked: root.scan(".") }
                                    CalmIconBtn { pal: root.pal; glyph: 0xF1276; primary: true; tip: "Scan downloads"; enabledBtn: !root.scanning; onClicked: root.scan("Downloads") }
                                    CalmIconBtn { visible: root.avPerm !== "" && root.avPerm !== "nogroup"; pal: root.pal; glyph: root.avFullAccess ? 0xF033F : 0xF033E; primary: root.avFullAccess; tip: root.avFullAccess ? "Full access is on: no password for alerts (click to turn off)" : "Full access is off: asks for the password (click to turn on)"; onClicked: root.avSetFullAccess(!root.avFullAccess) }
                                    CalmIconBtn { visible: root.pwKnown; pal: root.pal; glyph: 0xF033E; tip: "Forget the remembered password"; onClicked: { root.pwForget(); root.flash("Password forgotten. It is asked again next time.", false) } }
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
                                        ? "Read once with your password · Reload for fresh alerts"
                                        : root.avPerm === "" ? "Checking permissions…"
                                        : root.avPerm === "nogroup" ? "Only root can read it on this install."
                                        : "The database is readable by its own user only."
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
                                                    text: root.avSnap ? "Snapshot" + (root.avSnapAt > 0 && root.nowTick >= 0 ? "  ·  read " + root.ago(root.avSnapAt / 1000) + " ago" : "") : "Alerts are locked"
                                                    color: root.pal.text
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody + 1
                                                    font.weight: Font.Medium
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: lockBar.why
                                                    visible: !root.avSnap                 // the title says it is a snapshot; the paragraph only while locked
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
                                                // the technical line (a path, an os error) stays folded away: the one sentence above is the reason
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: root.avDetails && !root.avSnap && (root.avActErr !== "" || root.avErr !== "")
                                                    text: root.avActErr !== "" ? root.avActErr : root.avErr
                                                    wrapMode: Text.Wrap
                                                    maximumLineCount: 3
                                                    elide: Text.ElideRight
                                                    color: Qt.alpha(root.pal.text, 0.6)
                                                    font.family: root.pal.mono
                                                    font.pixelSize: root.pal.tCap
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: !root.avDetails && !root.avSnap && (root.avActErr !== "" || root.avErr !== "")
                                                    horizontalAlignment: Text.AlignLeft
                                                    text: "Details"
                                                    color: Qt.alpha(root.pal.muted, 0.9)
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                    font.underline: detMa.containsMouse
                                                    MouseArea { id: detMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.avDetails = true }
                                                }
                                                // the one case a password can not solve: the history was written by a newer engine
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: root.avSchemaStuck
                                                    text: "The history was written by a newer ai-antivirus, so no password can read it. Repair keeps a copy and starts a fresh history."
                                                    wrapMode: Text.Wrap
                                                    maximumLineCount: 2
                                                    elide: Text.ElideRight
                                                    color: root.pal.muted
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tCap
                                                }
                                            }
                                        }
                                        // the password, asked here (sudo); used once to read the alerts, never stored or shown
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 56
                                            visible: root.avAskPw && root.avUnlockStep === ""
                                            spacing: 8
                                            Rectangle {
                                                Layout.fillWidth: true
                                                Layout.maximumWidth: 340
                                                implicitHeight: 40
                                                radius: 20
                                                color: root.pal.fill
                                                border.width: 1
                                                border.color: pwIn.activeFocus ? root.pal.lineFocus : "transparent"
                                                TextInput {
                                                    id: pwIn
                                                    anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                                    echoMode: TextInput.Password
                                                    passwordCharacter: "\u2022"
                                                    color: root.pal.text
                                                    selectionColor: Qt.alpha(root.pal.accent, 0.35)
                                                    font.family: root.pal.uiFont
                                                    font.pixelSize: root.pal.tBody
                                                    clip: true
                                                    maximumLength: 256
                                                    Text { visible: parent.text === "" && !parent.activeFocus; text: "Your password (for sudo)"; color: root.pal.muted; font: parent.font }
                                                    function go() { var pw = text; text = ""; root.avSubmitPw(pw) }
                                                    onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
                                                    Keys.onReturnPressed: go()
                                                    Keys.onEnterPressed: go()
                                                    Keys.onEscapePressed: { text = ""; root.avAskPw = false }
                                                    Connections { target: root; function onPwFocusRequested() { pwIn.forceActiveFocus(); pwIn.selectAll() } }
                                                }
                                            }
                                            Btn { label: "Unlock"; glyph: 0xF0306; primary: true; onClicked: pwIn.go() }
                                            Btn { label: "Cancel"; onClicked: { pwIn.text = ""; root.avAskPw = false } }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 50
                                            Layout.rightMargin: 4
                                            spacing: 6

                                            Btn {
                                                visible: !root.avAskPw && root.avUnlockStep === ""
                                                primary: true
                                                label: root.avSnap ? "Reload" : "Unlock"
                                                glyph: 0xF0306
                                                onClicked: root.avUnlock()
                                            }
                                            Btn {
                                                visible: !root.avAskPw && root.avUnlockStep === "" && root.avPerm === "notmember" && root.hasSg
                                                primary: true
                                                label: "Give full access"
                                                glyph: 0xF033F
                                                onClicked: root.avGrantAccess()
                                            }
                                            Btn {
                                                visible: !root.avAskPw && root.avUnlockStep === "" && root.avSchemaStuck
                                                label: "Repair history"
                                                glyph: 0xF04D9
                                                onClicked: root.avRepair()
                                            }
                                            Btn {
                                                visible: root.avUnlockStep !== ""
                                                label: "Cancel"
                                                glyph: 0xF0156
                                                onClicked: root.avCancelUnlock("Cancelled.")
                                            }
                                            Item { Layout.fillWidth: true }
                                            CalmIconBtn { pal: root.pal; glyph: 0xF018D; tip: "Do it in the console (sudo)"; onClicked: root.consoleRequested(root.avSudoCmd) }
                                            CalmIconBtn { pal: root.pal; glyph: 0xF0306; tip: "System password window"; visible: !root.avSnap; onClicked: root.avUnlockPk() }
                                            CalmIconBtn { pal: root.pal; glyph: 0xF0450; tip: "Retry"; onClicked: root.avTick() }
                                            CalmIconBtn { pal: root.pal; glyph: 0xF04D9; tip: "Diagnose"; onClicked: root.consoleRequested(root.avDiagCmd) }
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
                                                spacing: 8
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
                                            spacing: 8
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
                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; leftMargin: 20 }
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
                                                text: root.scanning ? "Scanning " + (root.scanWhat.charAt(0) === "/" ? root.scanWhat : "~/" + (root.scanWhat === "." ? "" : root.scanWhat))
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

                                // the lists: a switch between Alerts and Held back, then ONE list that takes all the room left
                                // (they used to share it: four fixed rows for "held back" and a sliver for the alerts)
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    // two soft tabs, not two solid buttons: the list below is the thing to look at
                                    Rectangle {
                                        implicitWidth: alRow.implicitWidth + 26
                                        implicitHeight: 32
                                        radius: 16
                                        color: root.avView === "alerts" ? Qt.alpha(root.pal.accent, 0.16) : (alMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                        Row {
                                            id: alRow
                                            anchors.centerIn: parent
                                            spacing: 7
                                            Glyph { anchors.verticalCenter: parent.verticalCenter; code: 0xF0026; font.pixelSize: 14; color: root.avView === "alerts" ? root.pal.accent : root.pal.muted }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Alerts"; color: root.avView === "alerts" ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.Medium }
                                            Text { visible: root.avAlerts.length > 0; anchors.verticalCenter: parent.verticalCenter; text: root.avAlerts.length; color: Qt.alpha(root.pal.text, 0.55); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                        }
                                        MouseArea { id: alMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.avView = "alerts" }
                                    }
                                    Rectangle {
                                        implicitWidth: hbRow.implicitWidth + 26
                                        implicitHeight: 32
                                        radius: 16
                                        color: root.avView === "held" ? Qt.alpha(root.pal.accent, 0.16) : (hbMa.containsMouse ? root.pal.fillHover : root.pal.fill)
                                        Row {
                                            id: hbRow
                                            anchors.centerIn: parent
                                            spacing: 7
                                            Glyph { anchors.verticalCenter: parent.verticalCenter; code: 0xF0780; font.pixelSize: 14; color: root.avView === "held" ? root.pal.accent : root.pal.muted }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Held back"; color: root.avView === "held" ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1; font.weight: Font.Medium }
                                            Text { visible: root.avPending + root.avHeld.length > 0; anchors.verticalCenter: parent.verticalCenter; text: root.avPending > 0 ? root.avPending + " need OK" : root.avHeld.length; color: Qt.alpha(root.pal.text, 0.55); font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap }
                                        }
                                        MouseArea { id: hbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.avView = "held" }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Repeater {
                                        model: root.avView === "alerts" ? ["all", "critical", "high", "medium"] : []
                                        delegate: Rectangle {
                                            id: sv
                                            required property string modelData
                                            readonly property bool on: root.avSevEff === modelData
                                            readonly property int n: root.avSevN[modelData] || 0
                                            visible: n > 0 || modelData === "all"
                                            implicitWidth: svT.implicitWidth + 22
                                            implicitHeight: 30
                                            radius: 15
                                            color: on ? Qt.alpha(modelData === "all" ? root.pal.accent : root.sevColor(modelData), 0.22) : root.pal.fill
                                            Text { id: svT; anchors.centerIn: parent; text: root.cap(sv.modelData) + "  " + sv.n; color: sv.on ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.avSev = sv.modelData }
                                        }
                                    }
                                    Btn { visible: root.avView === "alerts" && root.avAlerts.length > 1; label: "Acknowledge all"; glyph: 0xF012C; onClicked: root.ack("all") }
                                    Btn { visible: root.avView === "held" && root.avLocked; label: "Unlock"; glyph: 0xF0306; onClicked: root.avUnlock() }
                                    Btn { visible: root.avView === "held" && !root.avLocked && !root.avSnap; label: "Full list"; glyph: 0xF018D; onClicked: root.consoleRequested("ai-antivirus actions -n 100") }
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.avView === "alerts"
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.avGroups
                                        delegate: Item {
                                            id: ag
                                            required property var modelData
                                            readonly property bool open: root.avOpenKeys[modelData.key] === true
                                            width: ListView.view.width
                                            height: 48 + (open ? agWhere.implicitHeight + 14 : 0)
                                            ListRow {
                                                width: parent.width
                                                title: ag.modelData.title + (ag.modelData.count > 1 ? "   ×" + ag.modelData.count : "")
                                                sub: [ag.modelData.rule_id || "", (root.nowTick >= 0 ? root.ago(ag.modelData.ts) : "") + " ago",
                                                      ag.modelData.where.length > 0 ? ag.modelData.where[0] + (ag.modelData.where.length > 1 ? "  +" + (ag.modelData.where.length - 1) + " more" : "") : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                                mark: root.sevColor(ag.modelData.severity)
                                                chip: root.cap(ag.modelData.severity)
                                                chipTone: root.sevColor(ag.modelData.severity)
                                                actAlways: true
                                                actGlyph: 0xF012C
                                                actTone: root.pal.good
                                                act2Glyph: ag.modelData.raw.length > 0 ? 0xF0565 : 0      // shield-check: Allow
                                                act2Tone: root.pal.accent
                                                onClicked: root.toggleOpen(ag.modelData.key)
                                                onAct: root.ack(ag.modelData.ids)
                                                onAct2: root.allowAlerts(ag.modelData)
                                            }
                                            Text {
                                                id: agWhere
                                                visible: ag.open
                                                x: 24; y: 52
                                                width: parent.width - 60
                                                text: ag.modelData.where.length > 0 ? ag.modelData.where.join("\n") : "(no path in this alert)"
                                                wrapMode: Text.WrapAnywhere
                                                textFormat: Text.PlainText
                                                color: Qt.alpha(root.pal.text, 0.75)
                                                font.family: root.pal.mono
                                                font.pixelSize: root.pal.tCap
                                                lineHeight: 1.2
                                            }
                                        }
                                    }
                                    Empty {
                                        visible: root.avGroups.length === 0
                                        text: root.avKnown ? (root.avAlerts.length > 0 ? "Nothing at this level" : "All clear") : (root.avLocked ? "Locked: unlock it above to see the alerts" : "Unreadable")
                                        tone: root.avKnown ? root.pal.good : root.pal.warn
                                        glyph: root.avKnown ? 0xF0565 : 0xF033E
                                    }
                                }

                                // what the antivirus held back, quarantined, froze or isolated (the notifications point here). A file that can be
                                // restored has its undo button (`ai-antivirus undo <id>`, in the console with sudo); the same action on many files is one row.
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: root.avView === "held"
                                    ListView {
                                        anchors.fill: parent
                                        clip: true
                                        spacing: 2
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.avHeldGroups
                                        delegate: Item {
                                            id: hg
                                            required property var modelData
                                            readonly property var act: modelData.a
                                            readonly property bool open: root.avOpenKeys[modelData.key] === true
                                            readonly property bool waiting: act.status === "pending"
                                            readonly property bool undoable: modelData.count === 1 && act.status === "executed" && act.action !== "kill"
                                            width: ListView.view.width
                                            height: 48 + (open ? hgWhere.implicitHeight + 14 : 0)
                                            ListRow {
                                                width: parent.width
                                                title: root.actVerb(hg.act) + (hg.modelData.count > 1 ? "   ×" + hg.modelData.count : "")
                                                sub: [hg.modelData.where.length > 0 ? hg.modelData.where[0] + (hg.modelData.where.length > 1 ? "  +" + (hg.modelData.where.length - 1) + " more" : "") : "",
                                                      hg.act.rule_id || "", (root.nowTick >= 0 ? root.ago(hg.modelData.ts) : "") + " ago",
                                                      hg.undoable ? "↶ undo" + (hg.act.action === "quarantine" ? " restores the file" : "") : ""].filter(function (x) { return x !== "" }).join("  ·  ")
                                                mark: root.actTone(hg.act)
                                                chip: hg.waiting ? "Needs OK" : (hg.act.status === "dry_run" ? "Alert-only" : (hg.act.status === "executed" ? "Done" : root.cap(hg.act.status)))
                                                chipTone: root.actTone(hg.act)
                                                actAlways: hg.waiting || hg.undoable
                                                // pending: Approve (✓) and Reject (✕, leaves the file alone); done: Undo. Each asks for the password in this window.
                                                actGlyph: hg.waiting ? 0xF012C : (hg.undoable ? 0xF054C : 0)
                                                actTone: hg.waiting ? root.pal.good : root.pal.accent
                                                act2Glyph: hg.waiting ? 0xF0156 : 0
                                                act2Tone: root.pal.bad
                                                onClicked: root.toggleOpen(hg.modelData.key)
                                                onAct: root.actRun(hg.waiting ? "approve" : "undo", hg.act.id, hg.act)
                                                onAct2: root.actRun("reject", hg.act.id, hg.act)
                                            }
                                            Text {
                                                id: hgWhere
                                                visible: hg.open
                                                x: 24; y: 52
                                                width: parent.width - 60
                                                text: hg.modelData.where.join("\n") + (hg.modelData.errs.length > 0 ? "\n\n" + hg.modelData.errs[0] : "")
                                                wrapMode: Text.WrapAnywhere
                                                textFormat: Text.PlainText
                                                color: Qt.alpha(root.pal.text, 0.75)
                                                font.family: root.pal.mono
                                                font.pixelSize: root.pal.tCap
                                                lineHeight: 1.2
                                            }
                                        }
                                    }
                                    Empty {
                                        visible: root.avHeldGroups.length === 0
                                        text: root.avLocked ? "Locked: unlock it above to see what was held back" : "Nothing held back"
                                        tone: root.avLocked ? root.pal.warn : root.pal.good
                                        glyph: root.avLocked ? 0xF033E : 0xF0565
                                    }
                                }
                            }

                            // ---- ClamAV: test it, scan with it, and the fixes
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 28
                                spacing: 20
                                visible: root.tab === "clamav" && root.hasClam
                                opacity: root.pageIn
                                transform: Translate { y: (1 - root.pageIn) * 10 }

                                PageHead {
                                    glyph: 0xF0668
                                    status: root.clamState
                                    tone: root.clamColor
                                    detail: root.clamErr !== "" ? root.clamErr
                                        : (root.clam === null ? "Checks the signatures, the updater and that ClamAV detects a harmless test file"
                                        : root.clam.headline)
                                    CalmIconBtn { pal: root.pal; glyph: 0xF0668; tip: "Test ClamAV"; enabledBtn: !root.clamBusy; onClicked: root.clamRun("test", "") }
                                    CalmIconBtn { pal: root.pal; glyph: 0xF0780; tip: "Exceptions"; enabledBtn: !root.clamBusy; onClicked: root.clamRun("exceptions", "") }
                                    CalmIconBtn { pal: root.pal; glyph: 0xF1276; primary: true; tip: "Scan downloads"; enabledBtn: !root.clamBusy; onClicked: root.clamRun("scan", "Downloads") }
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
                                            spacing: 8
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
                                            Btn {
                                                readonly property string k: modelData.file + "|" + modelData.signature
                                                height: 26; implicitHeight: 26
                                                label: root.clamConfirm === k ? "Sure? Allow it" : "Allow"
                                                glyph: 0xF0565
                                                primary: root.clamConfirm === k
                                                disabled: clamAllowProc.running
                                                onClicked: root.clamAllow(modelData.file, modelData.signature)
                                            }
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
                                    // the heading only once there is something under it (before a test the empty state speaks alone)
                                    title: root.clam && root.clam.fixes && root.clam.fixes.length > 0 ? "Fixes" : ""
                                    extra: root.clam && root.clam.fixes && root.clam.fixes.length > 0 ? String(root.clam.fixes.length) : ""
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
                                            onAct: { if (/^sudo\s+[^-\s]/.test(modelData.cmd)) root.rootRun(modelData.cmd.replace(/^sudo\s+/, ""), modelData.title, modelData.cmd, "Run it"); else root.consoleRequested(modelData.cmd) }
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
                                spacing: 20
                                visible: root.tab === "exceptions" && root.hasAv
                                opacity: root.pageIn
                                transform: Translate { y: (1 - root.pageIn) * 10 }

                                PageHead {
                                    glyph: 0xF0780
                                    status: root.exc === null ? "Exceptions" : root.excList.length + (root.excList.length === 1 ? " exception" : " exceptions")
                                    tone: root.pal.accent
                                    detail: root.exc === null ? "" : (root.exc.from_file ? root.exc.file : "Defaults")
                                    CalmIconBtn { pal: root.pal; glyph: 0xF0450; tip: "Restore the defaults"; enabledBtn: root.exc !== null && root.exc.from_file; onClicked: root.excChange(["reset"]) }
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
                                                        spacing: 8
                                                        Glyph { anchors.verticalCenter: parent.verticalCenter; code: ek.modelData.g; font.pixelSize: 14; color: ek.on ? root.pal.accent : root.pal.muted }
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: ek.modelData.l; color: ek.on ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: ek.on ? Font.Medium : Font.Medium }
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
                                opacity: root.pageIn
                                transform: Translate { y: (1 - root.pageIn) * 10 }

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
                                                        spacing: 8
                                                        Glyph { anchors.verticalCenter: parent.verticalCenter; code: tg.modelData.g; font.pixelSize: 14; color: tg.on ? root.pal.accent : root.pal.muted }
                                                        Text { anchors.verticalCenter: parent.verticalCenter; text: tg.modelData.l; color: tg.on ? root.pal.text : root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: tg.on ? Font.Medium : Font.Medium }
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
                                                            Text { anchors.verticalCenter: parent.verticalCenter; text: rep.modelData.test; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium }
                                                            Small { anchors.verticalCenter: parent.verticalCenter; text: rep.modelData.summary }
                                                        }
                                                        GridLayout {
                                                            width: parent.width
                                                            columns: 2
                                                            columnSpacing: 16
                                                            rowSpacing: 4
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
                                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
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

                // ---- the AI's card (Let AI decide): pops out beside the window like the utilities box's side card and the pair stays
                // centred. With no room beside it (a pop-out window, a narrow screen) it lies over the window's right side instead.
                Item {
                    id: decSide
                    visible: false
                    width: 0; height: 0
                    readonly property real cardW: 344
                    readonly property real gap: 8
                    readonly property real room: Math.max(0, (qp.width - panel.width) / 2)
                    // the Security window is 1140 px wide: on a 1920 px screen 390 px are left on each side, which the old "card + 32"
                    // test (392) missed by 2 px, so the card lay over the window instead of beside it. Now "card + 16" (360).
                    // not from panel.width (that one shrinks while the card is out): the window's full size plus the card, or the smallest
                    // window (820) plus the card, whichever the screen can hold
                    readonly property bool beside: !win.desktop && qp.width >= 820 + cardW + gap + 48
                    // window + gap + card, centred as one block: the window sits half of (card + gap) left of the middle, whatever its width
                    readonly property real shiftBy: beside ? (cardW + gap) / 2 : 0
                    property real prog: (root.decideOpen && beside) ? 1 : 0
                    Behavior on prog { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                }
                ClippingRectangle {
                    id: decCard
                    z: 5
                    property real shown: root.decideOpen ? 1 : 0
                    Behavior on shown { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    visible: shown > 0.01
                    opacity: shown * qp.reveal
                    x: decSide.beside ? panel.x + panel.width + decSide.gap : panel.x + panel.width - width - 18
                    y: decSide.beside ? panel.y : panel.y + 96
                    width: decSide.cardW
                    height: decSide.beside ? panel.height : Math.max(240, panel.height - 96 - 18)
                    radius: root.pal.rLg
                    // solid, not glass: it has to stay readable over the dimmed desktop
                    color: Qt.alpha(root.pal.surface, 1)
                    border.width: root.pal.bw
                    border.color: root.pal.line
                    transform: Translate { x: (decSide.beside ? -1 : 1) * (1 - decCard.shown) * 36 }
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    // ---- the head: an accent wash fading into the card, the status icon, the title, and a thin progress line while it reads
                    Rectangle {
                        id: dHead
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 92
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.alpha(root.cardTone, 0.20) }
                            GradientStop { position: 1; color: Qt.alpha(root.cardTone, 0.0) }
                        }
                        Rectangle {
                            id: dIc
                            x: 20
                            anchors.verticalCenter: parent.verticalCenter
                            width: 46; height: 46; radius: 16
                            color: Qt.alpha(root.cardTone, 0.20)
                            border.width: 1
                            border.color: Qt.alpha(root.cardTone, 0.35)
                            Behavior on color { ColorAnimation { duration: root.pal.dMed } }
                            Glyph {
                                id: dGl
                                anchors.centerIn: parent
                                code: root.cardState === "busy" ? 0xF0B79 : (root.cardState === "good" ? 0xF05E0 : 0xF0026)
                                font.pixelSize: 23
                                color: root.cardTone
                                SequentialAnimation on opacity {
                                    running: root.cardState === "busy" && root.decideOpen
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                                    onRunningChanged: if (!running) dGl.opacity = 1
                                }
                            }
                        }
                        Column {
                            anchors { left: dIc.right; leftMargin: 14; right: dClose.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            spacing: 2
                            Text {
                                width: parent.width
                                text: root.rvShown ? "AI review" : "AI's pick for this PC"
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tTitle
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            Small {
                                width: parent.width
                                text: root.reviewBusy ? "Reading " + Math.min(root.reviewItems.length + 1, Math.max(1, root.reviewTotal)) + " of " + root.reviewTotal + " groups of alerts"
                                    : (root.decideBusy ? "Working out what to do first"
                                    : (root.decideRes ? (root.decideRes.by === "ai" ? "Your local model" : "Plain order, no model")
                                    : (root.decideErr !== "" || root.reviewErr !== "" ? "No answer"
                                    : (root.reviewRes ? (root.reviewRes.by === "ai" ? "Your local model" : "No model") : "Done"))))
                            }
                        }
                        Rectangle {
                            id: dClose
                            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                            width: 30; height: 30; radius: 15
                            color: dcMa.containsMouse ? root.pal.fillHover : "transparent"
                            Glyph { anchors.centerIn: parent; code: 0xF0156; font.pixelSize: 15; color: dcMa.containsMouse ? root.pal.text : root.pal.muted }
                            MouseArea { id: dcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.decideClose() }
                        }
                        Rectangle {
                            visible: root.reviewBusy && root.reviewTotal > 0
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20 }
                            height: 3; radius: 2
                            color: Qt.alpha(root.pal.text, 0.08)
                            Rectangle {
                                width: parent.width * Math.min(1, root.reviewItems.length / Math.max(1, root.reviewTotal))
                                height: parent.height; radius: 2
                                color: root.cardTone
                                Behavior on width { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                            }
                        }
                    }

                    // everything the AI does shows here while it happens: a row for each group of alerts the moment it is judged (what it is,
                    // safe or not, and why), then the pick. What it cleared, what it kept for you and what it could not read are all listed.
                    Flickable {
                        id: dFlick
                        anchors { left: parent.left; right: parent.right; top: dHead.bottom; bottom: dFoot.top; topMargin: 4 }
                        clip: true
                        contentWidth: width
                        contentHeight: dCol.implicitHeight + 28
                        boundsBehavior: Flickable.StopAtBounds
                        Column {
                            id: dCol
                            x: 20; y: 10
                            width: dFlick.width - 40
                            spacing: 10

                            // ---- three figures: read, cleared, waiting
                            Row {
                                visible: root.reviewItems.length > 0
                                width: parent.width
                                spacing: 8
                                RvTile { pal: root.pal; width: (dCol.width - 16) / 3; value: String(root.reviewItems.length); caption: "groups read"; tone: root.pal.text }
                                RvTile { pal: root.pal; width: (dCol.width - 16) / 3; value: String(root.rvClearedN); caption: "cleared"; tone: root.pal.good }
                                RvTile { pal: root.pal; width: (dCol.width - 16) / 3; value: String(root.rvNeedsN); caption: "need you"; tone: root.rvNeedsN > 0 ? root.cardTone : root.pal.muted }
                            }
                            Text {
                                visible: root.reviewRes !== null
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: root.rvSummary
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody - 1
                                lineHeight: 1.15
                            }
                            Row {
                                visible: root.reviewBusy
                                spacing: 10
                                Working { anchors.verticalCenter: parent.verticalCenter }
                                Small {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: dCol.width - 40
                                    text: root.reviewStep !== "" ? root.reviewStep : "Starting"
                                    color: root.pal.text
                                }
                            }
                            Text {
                                visible: root.reviewNote !== ""
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: root.reviewNote
                                color: root.pal.warn
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody - 1
                            }
                            Text {
                                visible: root.reviewErr !== ""
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: root.reviewErr
                                color: root.pal.bad
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody - 1
                            }
                            Small {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                elide: Text.ElideNone
                                visible: root.reviewRes !== null && root.reviewRes.ai_note !== ""
                                text: root.reviewRes ? root.reviewRes.ai_note : ""
                            }
                            Small {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                elide: Text.ElideNone
                                visible: root.avUnacked > root.avAlerts.length && root.reviewItems.length > 0
                                text: "It read the newest " + root.avAlerts.length + " of " + root.avUnacked + " alerts. Ask again for the rest."
                            }

                            // ---- what needs you: not sure, called dangerous, or not allowed to be cleared by the AI
                            Label { visible: root.rvNeeds.length > 0; text: "Needs you" }
                            Repeater {
                                model: root.rvNeeds
                                delegate: Rectangle {
                                    id: nr
                                    required property var modelData
                                    width: dCol.width
                                    height: nrCol.implicitHeight + 22
                                    radius: 14
                                    color: Qt.alpha(root.rvColor(nr.modelData), 0.08)
                                    transform: Translate { y: (1 - nr.opacity) * 8 }
                                    NumberAnimation on opacity { from: 0; to: 1; duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve }
                                    Rectangle { x: 0; y: 12; width: 3; height: parent.height - 24; radius: 2; color: root.rvColor(nr.modelData) }
                                    Column {
                                        id: nrCol
                                        anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                        spacing: 6
                                        Item {
                                            width: parent.width
                                            height: Math.max(nrT.implicitHeight, 20)
                                            Text {
                                                id: nrT
                                                anchors { left: parent.left; right: nrC.visible ? nrC.left : parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                                elide: Text.ElideRight
                                                text: nr.modelData.title
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody - 1
                                                font.weight: Font.Medium
                                            }
                                            RvPill { pal: root.pal; id: nrC; visible: nr.modelData.count > 1; text: "×" + nr.modelData.count; tone: root.pal.muted; anchors { right: parent.right; verticalCenter: parent.verticalCenter } }
                                        }
                                        Row {
                                            spacing: 8
                                            RvPill { pal: root.pal; text: root.rvLabel(nr.modelData); tone: root.rvColor(nr.modelData) }
                                            Small { anchors.verticalCenter: parent.verticalCenter; text: root.cap(nr.modelData.severity) + " severity" }
                                        }
                                        Small {
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            elide: Text.ElideNone
                                            visible: text !== ""
                                            text: nr.modelData.reason
                                        }
                                    }
                                }
                            }
                            Small {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                elide: Text.ElideNone
                                visible: root.rvShown && root.avPending > 0
                                text: root.avPending + (root.avPending === 1 ? " action waits" : " actions wait") + " for your OK. Those need your password, so the AI never approves them."
                            }

                            // ---- what it cleared by itself, and why (tap the title to fold it)
                            Item {
                                visible: root.rvCleared.length > 0
                                width: parent.width
                                height: 22
                                Label { anchors.verticalCenter: parent.verticalCenter; text: "Judged safe" }
                                Glyph {
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                    code: root.rvOpenCleared ? 0xF0140 : 0xF0142
                                    font.pixelSize: 16
                                    color: root.pal.muted
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.rvOpenCleared = !root.rvOpenCleared }
                            }
                            Repeater {
                                model: root.rvOpenCleared ? root.rvCleared : []
                                delegate: Rectangle {
                                    id: cr
                                    required property var modelData
                                    width: dCol.width
                                    height: crCol.implicitHeight + 20
                                    radius: 14
                                    color: Qt.alpha(root.pal.good, 0.07)
                                    transform: Translate { y: (1 - cr.opacity) * 8 }
                                    NumberAnimation on opacity { from: 0; to: 1; duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve }
                                    Glyph { id: crG; x: 12; y: 12; code: 0xF05E0; font.pixelSize: 17; color: root.pal.good }
                                    Column {
                                        id: crCol
                                        anchors { left: crG.right; leftMargin: 10; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                        spacing: 2
                                        Text {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: cr.modelData.title + (cr.modelData.count > 1 ? "   ×" + cr.modelData.count : "")
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody - 1
                                            font.weight: Font.Medium
                                        }
                                        Small {
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            elide: Text.ElideNone
                                            visible: text !== ""
                                            text: cr.modelData.reason
                                        }
                                    }
                                }
                            }
                            Small {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                elide: Text.ElideNone
                                visible: root.rvCleared.length > 0 && !root.reviewBusy
                                text: root.reviewAckState === 3 ? "They are still on the Antivirus page: the acknowledge did not go through."
                                                                : "Cleared means acknowledged, the same as pressing Acknowledge yourself. Each one is also logged in ~/.local/state/island/av-ai-review.jsonl."
                            }

                            // ---- the pick
                            Item { visible: root.rvShown && (root.decideBusy || root.decideRes !== null || root.decideErr !== "" || root.decideSkipped); width: 1; height: 2 }
                            Label { visible: root.rvShown && (root.decideBusy || root.decideRes !== null || root.decideErr !== "" || root.decideSkipped); text: "What to do first" }
                            Column {
                                visible: root.decideBusy
                                width: parent.width
                                spacing: 8
                                Working {}
                                Repeater {
                                    model: root.decideSteps.slice(-3)
                                    delegate: Small {
                                        required property string modelData
                                        required property int index
                                        width: dCol.width
                                        text: modelData
                                        color: root.pal.muted
                                    }
                                }
                            }
                            Text {
                                visible: root.decideSkipped
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: "Nothing else needs you."
                                color: root.pal.text
                                font.family: root.pal.uiFont
                                font.pixelSize: root.pal.tBody - 1
                            }
                            Column {
                                visible: root.decideErr !== ""
                                width: parent.width
                                spacing: 12
                                Text {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: root.decideErr
                                    color: root.pal.bad
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody - 1
                                }
                                Btn { label: "Try again"; onClicked: root.decideStart() }
                            }
                            Column {
                                visible: root.decideRes !== null
                                width: parent.width
                                spacing: 8
                                Rectangle {
                                    width: parent.width
                                    height: dwCol.implicitHeight + 24
                                    radius: 14
                                    color: Qt.alpha(root.pal.accent, 0.10)
                                    Column {
                                        id: dwCol
                                        anchors { left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                                        spacing: 6
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            text: root.decideRes ? root.decideRes.why : ""
                                            color: root.pal.text
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody - 1
                                            lineHeight: 1.15
                                        }
                                        Small {
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            elide: Text.ElideNone
                                            text: "Looked at: " + (root.decideRes && root.decideRes.facts_line !== "" ? root.decideRes.facts_line : "this computer")
                                        }
                                        Small {
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            elide: Text.ElideNone
                                            visible: root.decideRes !== null && root.decideRes.ai_note !== ""
                                            text: root.decideRes ? root.decideRes.ai_note : ""
                                        }
                                    }
                                }
                                Repeater {
                                    model: root.decideRes ? root.decideRes.order : []
                                    delegate: Rectangle {
                                        id: dr
                                        required property string modelData
                                        required property int index
                                        width: dCol.width
                                        height: drCol.implicitHeight + 18
                                        radius: 14
                                        color: Qt.alpha(index === 0 ? root.pal.accent : root.pal.text, index === 0 ? 0.12 : 0.05)
                                        Text {
                                            id: drN
                                            x: 14
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: String(dr.index + 1)
                                            color: dr.index === 0 ? root.pal.accent : root.pal.muted
                                            font.family: root.pal.uiFont
                                            font.pixelSize: root.pal.tBody
                                            font.weight: Font.Medium
                                        }
                                        Column {
                                            id: drCol
                                            anchors { left: drN.right; leftMargin: 12; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                            spacing: 1
                                            Text {
                                                width: parent.width
                                                elide: Text.ElideRight
                                                text: root.decideTitle(dr.modelData)
                                                color: root.pal.text
                                                font.family: root.pal.uiFont
                                                font.pixelSize: root.pal.tBody - 1
                                                font.weight: Font.Medium
                                            }
                                            Small {
                                                width: parent.width
                                                visible: text !== ""
                                                text: root.decideRes && root.decideRes.notes && root.decideRes.notes[dr.modelData] ? root.decideRes.notes[dr.modelData] : ""
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // your OK: nothing is acted on beyond what the review cleared, and nothing else happens before you press a button
                    Item {
                        id: dFoot
                        visible: !root.cardBusy
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 76
                        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20 } height: 1; color: root.pal.line; opacity: 0.6 }
                        Row {
                            anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter; verticalCenterOffset: 3 }
                            spacing: 10
                            Btn {
                                visible: root.decidePickItem !== null
                                primary: true
                                glyph: 0xF012C
                                label: root.decidePickItem ? "Approve and " + root.decidePickItem.btn.toLowerCase() : "Approve"
                                onClicked: root.decideApprove()
                            }
                            Btn {
                                visible: root.decidePickItem === null && root.rvNeeds.length > 0
                                primary: true
                                label: "Open the alerts"
                                onClicked: { root.decideClose(); root.ovGo("alerts") }
                            }
                            Btn { label: root.decidePickItem !== null ? "Not now" : "Done"; onClicked: root.decideClose() }
                        }
                    }
                }

                // ---- the antivirus log: pops out beside the window like the AI's card (the two never show together), or lies over its
                // right side when there is no room beside it. Live: it follows `ai-antivirus tail -f` while it is open.
                Item {
                    id: logSide
                    visible: false
                    width: 0; height: 0
                    readonly property real cardW: 420
                    readonly property real gap: 8
                    readonly property bool beside: !win.desktop && qp.width >= 820 + cardW + gap + 48
                    readonly property real shiftBy: beside ? (cardW + gap) / 2 : 0
                    property real prog: (root.logOpen && beside) ? 1 : 0
                    Behavior on prog { NumberAnimation { duration: root.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                }
                ClippingRectangle {
                    id: logCard
                    z: 5
                    property real shown: root.logOpen ? 1 : 0
                    Behavior on shown { NumberAnimation { duration: root.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }
                    visible: shown > 0.01
                    opacity: shown * qp.reveal
                    x: logSide.beside ? panel.x + panel.width + logSide.gap : panel.x + panel.width - width - 18
                    y: logSide.beside ? panel.y : panel.y + 96
                    width: logSide.cardW
                    height: logSide.beside ? panel.height : Math.max(240, panel.height - 96 - 18)
                    radius: root.pal.rLg
                    color: Qt.alpha(root.pal.surface, 1)
                    border.width: root.pal.bw
                    border.color: root.pal.line
                    transform: Translate { x: (logSide.beside ? -1 : 1) * (1 - logCard.shown) * 36 }
                    MouseArea { anchors.fill: parent; onPressed: m => { m.accepted = true } }

                    RowLayout {
                        id: logHead
                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 18; rightMargin: 12; topMargin: 14 }
                        height: 40
                        spacing: 8
                        Glyph { code: 0xF018D; font.pixelSize: 18; color: root.pal.accent }
                        Text {
                            Layout.fillWidth: true
                            text: "Antivirus log" + (root.logPaused ? "  ·  paused" : "")
                            color: root.pal.text
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody + 1
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                        CalmIconBtn { pal: root.pal; glyph: root.logPaused ? 0xF040A : 0xF03E4; tip: root.logPaused ? "Resume" : "Pause"; onClicked: root.logPaused = !root.logPaused }
                        CalmIconBtn { pal: root.pal; glyph: 0xF01B4; tip: "Clear"; onClicked: root.logClear() }
                        CalmIconBtn { pal: root.pal; glyph: 0xF0156; tip: "Close the log"; onClicked: root.logOpen = false }
                    }
                    Rectangle { anchors { left: parent.left; right: parent.right; top: logHead.bottom; topMargin: 8; leftMargin: 18; rightMargin: 18 } height: 1; color: root.pal.line; opacity: 0.6 }
                    ListView {
                        id: logList
                        anchors { left: parent.left; right: parent.right; top: logHead.bottom; bottom: parent.bottom; topMargin: 14; leftMargin: 18; rightMargin: 14; bottomMargin: 14 }
                        clip: true
                        spacing: 4
                        model: logModel
                        cacheBuffer: 240
                        reuseItems: true
                        boundsBehavior: Flickable.StopAtBounds
                        property bool follow: true
                        onMovementEnded: follow = atYEnd
                        onCountChanged: if (follow) Qt.callLater(function () { logList.positionViewAtEnd() })
                        delegate: Text {
                            required property string t
                            required property string c
                            width: ListView.view.width
                            text: t
                            wrapMode: Text.WrapAnywhere
                            textFormat: Text.PlainText
                            color: c === "bad" ? root.pal.bad : (c === "warn" ? root.pal.warn : root.pal.text)
                            font.family: root.pal.mono
                            font.pixelSize: root.pal.tBody - 1
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: logList.count === 0
                            text: root.logPaused ? "Paused" : "Waiting for events…"
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: root.pal.tBody
                        }
                    }
                }
            }
        }
    }
}
