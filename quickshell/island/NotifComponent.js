.pragma library

function componentFor(appName) {
    var a = String(appName || "").trim().toLowerCase()
    if (a.indexOf("firewall") >= 0) return "ai-firewall"
    if (a.indexOf("antivirus") >= 0 || a.indexOf("anti-virus") >= 0) return "ai-antivirus"
    if (a === "luna") return "luna"
    if (a === "halcyon files") return "halcyon-fm"
    if (a === "halcyon music") return "halcyon-music"
    return ""
}
