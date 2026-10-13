.pragma library

// Decides which steps the guided tour shows. The steps themselves live in features.json (the only file you edit).
//   mode "fresh"  : first install, or `>tour` replay      -> every entry
//   mode "legacy" : existing user, never saw a tour        -> entries that are not "core"
//   mode "seen"   : the user has a copy of features.json   -> entries that are new in the current file, or whose rev went up
// cur / seen are the parsed features.json files; env = { sysmode: bool }.

function usable(f, env) {
    if (f.only === "sysmode" && !env.sysmode) return false
    return true
}

function plan(mode, cur, seen, env) {
    var list = (cur && cur.features) ? cur.features : []
    var known = {}
    if (mode === "seen" && seen && seen.features)
        for (var i = 0; i < seen.features.length; i++) known[seen.features[i].id] = seen.features[i].rev || 1
    var steps = []
    for (var j = 0; j < list.length; j++) {
        var f = list[j]
        if (!usable(f, env)) continue
        var take = false
        if (mode === "fresh") take = true
        else if (mode === "legacy") take = !f.core
        else take = known[f.id] === undefined || known[f.id] !== (f.rev || 1)
        if (take) steps.push(f)
    }
    return { mode: mode === "fresh" ? "welcome" : "new", steps: steps }
}
