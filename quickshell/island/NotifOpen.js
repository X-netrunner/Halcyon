.pragma library

// What a click on a notification does. Used by the popup card, the centre's rows, the timeline lines and the grouped cards.
//
//   var p = NO.plan(notif, Quickshell.env("HOME"))
//   if (p.def) p.def.invoke()            // the app's own "default" action first (a browser opens the tab, a chat the conversation)
//   Quickshell.execDetached(p.cmd)       // then scripts/notif-open.py
//
// With a "default" action the helper only brings the app's window to the front (a safety net: on Wayland an app often may not raise
// itself). Without one (notify-send, the app withdrew it, ...) it first looks for a file in the notification (a screenshot's picture, a
// recording's path) and opens it (a video or sound plays, anything else is shown in the file manager); otherwise a notice from Halcyon
// itself goes to the place it is about (the matching Settings page, the notes ...: ROUTES in the script), and any other app's window
// is focused.
function plan(n, home) {
    var acts = n && n.actions ? n.actions : []
    var def = null
    for (var i = 0; i < acts.length; i++)
        if (acts[i].identifier === "default") { def = acts[i]; break }
    var body = String((n && n.body) || "").replace(/<[^>]*>/g, "")
    return {
        def: def,
        cmd: ["python3", home + "/.config/Halcyon/scripts/notif-open.py",
              String((n && n.appName) || ""), String((n && n.desktopEntry) || ""), String((n && n.appIcon) || ""),
              String((n && n.summary) || ""), body, def ? "focus" : "auto"]
    }
}
