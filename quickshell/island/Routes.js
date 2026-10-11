.pragma library
// Apps the island knows about: they are sent to their special workspace when they open (SUPER+M music, SUPER+D communication)
// and they are listed in the background-apps box (bottom-left corner), even when their window is closed.
//   id       short name
//   name     shown in the box
//   ws       special workspace the window goes to ("music" -> SUPER+M, "communication" -> SUPER+D)
//   glyph    Nerd Font code point
//   classes  window classes (lower case) that belong to the app; `hyprctl clients` shows the class of a window
//   match    regex (ERE, also used by pkill -f) that finds the app's main process in `ps -u $USER -o args`
//   cmd      shell command that starts it (or raises it if it is already running in the background)
// To add an app: copy a line, change the five fields. Turn the automatic moving off with `>app routing` in the launcher.
var apps = [
    { id: "spotify",  name: "Spotify",  ws: "music",         glyph: 0xF04C7, classes: ["spotify", "com.spotify.client"],
      match: "(^|/)spotify( |$)", cmd: "sh -c 'command -v spotify >/dev/null && exec spotify; exec spotify-launcher'" },
    { id: "discord",  name: "Discord",  ws: "communication", glyph: 0xF066F, classes: ["discord"],
      match: "/[Dd]iscord( |$)", cmd: "discord" },
    { id: "vesktop",  name: "Vesktop",  ws: "communication", glyph: 0xF066F, classes: ["vesktop"],
      match: "vesktop", cmd: "vesktop" },
    { id: "telegram", name: "Telegram", ws: "communication", glyph: 0xF0501, classes: ["org.telegram.desktop", "telegramdesktop"],
      match: "(^|/)(Telegram|telegram-desktop)( |$)", cmd: "sh -c 'command -v telegram-desktop >/dev/null && exec telegram-desktop; exec Telegram'" },
    { id: "signal",   name: "Signal",   ws: "communication", glyph: 0xF0361, classes: ["signal"],
      match: "signal-desktop|/Signal/", cmd: "signal-desktop" },
    { id: "slack",    name: "Slack",    ws: "communication", glyph: 0xF04B1, classes: ["slack"],
      match: "(^|/)slack( |$)", cmd: "slack" }
]

// Chat sites opened as a web app by a browser (Settings > Default apps > Chat, e.g. WhatsApp). A Chromium-family browser run with
// --app=URL gives the window a class like "chrome-web.whatsapp.com__-Default": the browser's name, the site, the profile.
var webBrowsers = ["chrome", "chromium", "brave", "google-chrome", "vivaldi", "microsoft-edge"]
var webHosts = ["web.whatsapp.com", "web.telegram.org", "messenger.com", "messages.google.com", "discord.com", "teams.microsoft.com", "instagram.com"]

function appForClass(cls) {
    var c = String(cls || "").toLowerCase()
    if (c === "") return null
    for (var i = 0; i < apps.length; i++)
        if (apps[i].classes.indexOf(c) >= 0) return apps[i]
    for (var b = 0; b < webBrowsers.length; b++)
        if (c.indexOf(webBrowsers[b] + "-") === 0)
            for (var h = 0; h < webHosts.length; h++)
                if (c.indexOf(webHosts[h]) > 0) return { id: "web-" + webHosts[h], name: webHosts[h], ws: "communication" }
    return null
}
