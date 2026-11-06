.pragma library

// Security center > Ask: which messages may reach ai-firewall / ai-antivirus (SecurityCenter.qml, ask()).
// Both tools answer with live checks on this machine, so only security questions and /test go to them. Small talk and
// everything else get a fixed reply here, without starting either tool.  Tested by tests/secask.test.js.
//
//   route(q, target)  ->  { send: true }                         ask the module (target "firewall" | "antivirus")
//                         { send: false, reply: "..." }          answer here, nothing is started

var SHARED = /\b(secur\w*|safe(ty)?|unsafe|hack(ed|er|ers|ing)?|attack\w*|threats?|risk\w*|vulnerab\w*|exploit\w*|cve|breach\w*|compromis\w*|suspicious|malicious|intrusion|intruders?|leak\w*|protect\w*|alerts?|detections?|detected|incidents?|sysmode|lockdown|posture|stealth|honeypot|exceptions?|exclu\w*|whitelist\w*|allowlist\w*|false positives?|flagged)\b/i
var FIREWALL = /\b(firewall|ufw|ai-firewall|ports?|bann?(ed|s)?|unban\w*|block(ed|ing|s)?|traffic|packets?|dropped|firewall rules?|ssh|dns|ip|ips|ipv[46]|network\w*|connect\w*|internet|wi-?fi|vpn|nmap|scan(ned|ning|s)?|ddos|brute|docker|libvirt|vms?|virtual machines?|containers?|listening|exposed|open ports?|doctor)\b/i
var ANTIVIRUS = /\b(virus\w*|anti-?virus|ai-antivirus|clamav|malware|trojans?|ransomware|rootkits?|worms?|spyware|adware|miners?|infect\w*|quarantin\w*|scan(ned|ning|s)?|signatures?|yara|edr|acknowledge\w*)\b/i

var SMALL = [
    [/^(hi|hello|hey|heya|hiya|yo|sup|howdy|good (morning|afternoon|evening))( there)?$/, "Hi! Ask me about this computer's security: open ports, bans, alerts, scans or exceptions. Or run a test with the chips below."],
    [/^(thanks?|thank you( so much| very much)?|thx|ty|cheers|great|nice|cool|ok(ay)?|perfect|awesome)$/, "You're welcome."],
    [/^(bye|goodbye|see you|see ya|good ?night|gn)$/, "Bye!"],
    [/^(how are you|how are you doing|how's it going|what's up)$/, "All good. Ask me about the firewall or the antivirus."],
    [/^(help|what can you do|what do you do|who are you|what are you)$/, "I answer security questions about this computer from live checks: the firewall (ports, bans, traffic, rules) and the antivirus (alerts, scans, exceptions). I can also scan a folder for you: say \"scan my Downloads\" or \"scan ~/projects\". Type /test to run the firewall's checks."]
]

var OTHER = "This tab only answers security questions about this computer (firewall, antivirus, ports, bans, alerts, scans). For anything else, use >ask in the launcher."

function clean(q) {
    return String(q || "").trim().toLowerCase().replace(/[\s!.?,:;)(*~-]+$/, "").replace(/\s+/g, " ")
}

function route(q, target) {
    var raw = String(q || "").trim()
    if (raw === "") return { send: false, reply: "" }
    if (/^\/test(\s|$)/.test(raw)) return { send: true }
    var t = clean(raw)
    for (var i = 0; i < SMALL.length; i++)
        if (SMALL[i][0].test(t)) return { send: false, reply: SMALL[i][1] }
    var own = target === "antivirus" ? ANTIVIRUS : FIREWALL
    if (SHARED.test(raw) || own.test(raw)) return { send: true }
    // a security word of the other module still counts: the user may not have switched the target
    if ((target === "antivirus" ? FIREWALL : ANTIVIRUS).test(raw)) return { send: true }
    return { send: false, reply: OTHER }
}

// ---- "scan my Downloads", "can you run a scan on ~/projects", "check /tmp/x for viruses": a request to DO a scan, not a question about
// scans. It is answered in the window itself (SecurityCenter.qml, askScan): the antivirus scans the folder and the result is told in
// the chat. Questions about scans ("what is a scan", "how long did the last scan take", "scan results") are not requests.
//   scanRequest(q) -> null                          not a request to scan
//                     { path: "~/Downloads", whole: false }   scan this (~ is the home folder; whole: they asked for "everything")
//                     { path: "", whole: false }              wants a scan, named no place: the window asks which
var FOLDERS = { download: "~/Downloads", downloads: "~/Downloads", document: "~/Documents", documents: "~/Documents", desktop: "~/Desktop",
                picture: "~/Pictures", pictures: "~/Pictures", photo: "~/Pictures", photos: "~/Pictures", video: "~/Videos", videos: "~/Videos",
                music: "~/Music", home: "~", tmp: "/tmp", temp: "/tmp" }
var NOT_A_NAME = /^(this|that|a|an|the|my|our|your|whole|entire|same|another|any|one|some|each|every|current|other|new|old|whole|full|next|last)$/
var PATHCH = "[^\\s\"'`,;?!]"

function scanRequest(q) {
    var raw = String(q || "").trim()
    if (raw === "" || /^\/test(\s|$)/.test(raw)) return null
    var t = raw.toLowerCase()
    var asksScan = /\bscan\b/.test(t)
    var asksCheck = /\b(check|examine|inspect|look (in|into|through|at)|go through)\b/.test(t) && /\b(virus\w*|malware|threats?|infect\w*|malicious|suspicious|trojans?|ransomware)\b/.test(t)
    if (!asksScan && !asksCheck) return null
    // a question about scans, or about an earlier one: not a request (but "can you scan ..." / "could you ..." is one)
    if (/^(how|what|why|when|where|which|who|does|did|is|are|was|were|has|have|should)\b/.test(t) && !/^(can|could|would|will) you\b/.test(t)) return null
    if (/\bscan (results?|history|log|report|time|speed|finished|done|status)\b|\b(last|previous|latest|earlier) scan\b|\bscans (found|show|say)\b/.test(t)) return null
    var whole = /\b(everything|whole (pc|computer|system|disk|drive)|entire (pc|computer|system|disk|drive)|full (system )?scan|the whole thing)\b/.test(t)
    // 1. a path: ~, ~/x, /abs/path, $HOME/x (not the "/" inside "and/or")
    var m = raw.match(new RegExp("(?:^|[\\s\"'`(])(~(?:/" + PATHCH + "*)?|\\$HOME(?:/" + PATHCH + "*)?|/" + PATHCH + "+)"))
    if (m) {
        var p = m[1].replace(/^\$HOME/, "~").replace(/[.)]+$/, "")
        if (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.slice(0, -1)
        return { path: p, whole: false }
    }
    // 2. "the projects folder", "my work directory"
    var f = t.match(/\b([\w.-]+) (?:folder|directory|dir)\b/)
    if (f && !NOT_A_NAME.test(f[1])) return { path: FOLDERS[f[1]] || ("~/" + (f[1] === "home" ? "" : f[1])).replace(/\/$/, ""), whole: false }
    // 3. a usual place by its name
    var w = t.match(/\b(downloads?|documents?|desktop|pictures?|photos?|videos?|music|home|tmp|temp)\b/)
    if (w) return { path: FOLDERS[w[1]], whole: false }
    if (whole) return { path: "~", whole: true }
    return { path: "", whole: false }
}
