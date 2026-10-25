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
    [/^(help|what can you do|what do you do|who are you|what are you)$/, "I answer security questions about this computer from live checks: the firewall (ports, bans, traffic, rules) and the antivirus (alerts, scans, exceptions). Type /test to run the firewall's checks."]
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
