.pragma library

// Which popups (toasts) fold behind which, for the shared popup box (Notifs.qml).
//
// Popups from the same app are folded into one card: the NEWEST one is shown with a "+N more" label and a folded layer behind it,
// the older ones from that app are folded shut (their cards stay in the list, only their height goes to 0, so each popup keeps its
// own card, timer and animations; nothing is created or destroyed by grouping). Clicking "+N more" opens the group.
//
//   list      the popups, oldest first (what Notifs.qml calls toasts); items need .id and .appName
//   expanded  { appName: true } for the groups the user opened
//   crit      function (item) -> true for an urgent one: urgent popups are never folded, so they can not hide behind a quiet one
//
// plan() returns { byId, first, last, shown }:
//   byId[id]  { folded, lead, more, open }   folded = this card is shut; lead = it carries the "+N more" label (only the newest
//             one of a group of 2 or more); more = how many are behind it; open = the group is opened (the label then says "Show less")
//   first / last   id of the first / last card that is showing (the one in the screen corner when the box sits against the border)
//   shown     how many cards are showing (a lone card, or a group, shows its time-left line only when this is 1)
function keyOf(item) {
    return item && item.appName ? String(item.appName) : ""
}

function plan(list, expanded, crit) {
    var open = expanded || {}
    var groups = {}, order = []
    var n = list ? list.length : 0
    for (var i = 0; i < n; i++) {
        var it = list[i]
        var k = keyOf(it)
        if (k === "" || (crit && crit(it))) continue          // no app name or an urgent one: stands alone
        if (!groups[k]) { groups[k] = []; order.push(k) }
        groups[k].push(it)
    }
    var byId = {}
    var first = null, last = null, shown = 0
    for (var j = 0; j < n; j++) byId[list[j].id] = { folded: false, lead: false, more: 0, open: false }
    for (var g = 0; g < order.length; g++) {
        var key = order[g], members = groups[key]
        if (members.length < 2) continue
        var isOpen = open[key] === true
        var newest = members[members.length - 1]
        for (var m = 0; m < members.length; m++) {
            var info = byId[members[m].id]
            if (members[m] === newest) { info.lead = true; info.more = members.length - 1; info.open = isOpen }
            else info.folded = !isOpen
        }
    }
    for (var s = 0; s < n; s++) {
        var id = list[s].id
        if (byId[id].folded) continue
        if (first === null) first = id
        last = id
        shown++
    }
    return { byId: byId, first: first, last: last, shown: shown }
}

// the opened groups that still have two or more popups (an opened group that shrank to one closes by itself, so the next group from
// that app starts shut); returns the same object when nothing changes, so a binding on it does not fire for nothing
function prune(list, expanded, crit) {
    var cur = expanded || {}
    var count = {}
    for (var i = 0; i < (list ? list.length : 0); i++) {
        var k = keyOf(list[i])
        if (k === "" || (crit && crit(list[i]))) continue
        count[k] = (count[k] || 0) + 1
    }
    var out = {}, changed = false
    for (var key in cur) {
        if (cur[key] === true && count[key] >= 2) out[key] = true
        else changed = true
    }
    return changed ? out : cur
}

function toggle(expanded, key) {
    var out = {}
    var cur = expanded || {}
    for (var k in cur) out[k] = cur[k]
    if (out[key] === true) delete out[key]
    else out[key] = true
    return out
}
