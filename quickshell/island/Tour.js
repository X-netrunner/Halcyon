.pragma library

// Decides which steps the guided tour shows. The steps themselves live in features.json (the only file you edit).
//   mode "fresh"  : first install, or `>tour` replay      -> every entry
//   mode "legacy" : existing user, never saw a tour        -> entries that are not "core"
//   mode "seen"   : the user has a copy of features.json   -> entries that are new in the current file, or whose rev went up
// cur / seen are the parsed features.json files; env = { sysmode: bool, firewall: bool }.

// An entry with "only" is about something the user picks at install time. When it is not installed the tour does not skip it
// silently: it shows one short card saying so and how to add it.
var NAMES = { sysmode: "Sysmode", firewall: "ai-firewall", antivirus: "ai-antivirus", luna: "Luna" }

function usable(f, env) {
    return !f.only || env[f.only] === true
}

function absent(f) {
    var n = NAMES[f.only] || f.only
    return { id: f.id, title: f.title, missing: true, rev: f.rev, core: f.core, quick: f.quick,
             body: n + " is not installed on this machine, so there is nothing to show here. To add it, run ./install.sh --choose in the Halcyon folder and pick " + n + "." }
}

function plan(mode, cur, seen, env) {
    var list = (cur && cur.features) ? cur.features : []
    var known = {}
    if (mode === "seen" && seen && seen.features)
        for (var i = 0; i < seen.features.length; i++) known[seen.features[i].id] = seen.features[i].rev || 1
    var steps = []
    for (var j = 0; j < list.length; j++) {
        var f = list[j]
        var take = false
        if (mode === "fresh") take = true
        else if (mode === "legacy") take = !f.core
        else take = known[f.id] === undefined || known[f.id] !== (f.rev || 1)
        if (take) steps.push(usable(f, env) ? f : absent(f))
    }
    return { mode: mode === "fresh" ? "welcome" : "new", steps: steps }
}
