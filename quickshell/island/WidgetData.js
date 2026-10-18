.pragma library

// The desktop widgets' data (Desktop builder = where they sit, Widget builder = how each one looks).
// One place for the list of widget types, their layouts ("styles"), their options and the rules for editing them. Used by
// DeskWidgets.qml (draws them), WidgetHost.qml (the frame), WidgetBuilderWindow.qml (the per-widget editor),
// DesktopBuilderWindow.qml (the overview) and WidgetBuilder.qml (the Settings entry).
//
// Saved in settings.json as opt.deskWidgets = { items: [ item, ... ] } and opt.deskStyles = [ { name, look }, ... ]
//   item = { uid, type, px, py, scale, style, opts: { key: value }, look: { ... } }
//     px, py  0 .. 1: where the widget sits inside the free room of the screen (0 = against the left / top margin,
//             1 = against the right / bottom margin, 0.5 = centred). So a widget can never fall off the screen and the
//             layout still fits on another resolution.
//     scale   0.5 .. 2.5: the whole widget bigger or smaller
//     style   one of the type's layouts (catalog[type].styles)
//     look    the surface and colours: see lookDefaults

// ------------------------------------------------------------------------------------------------ catalog
// size = the widget's rough size at scale 1 [w, h] (only used for the little pictures in the builders)
// opts: kind toggle | chips | slider | text | multi.   chips: options [[id, "Label"], ...]   multi: the same, several may be on
var cats = [["time", "Time"], ["system", "System"], ["media", "Media"], ["focus", "Focus"], ["desk", "Desktop"], ["info", "Info"]]

var catalog = [
    { id: "clock", cat: "time", name: "Clock", icon: 0xF0150, size: [220, 90], hint: "The time, in eight looks",
      styles: [["digital", "Digital"], ["big", "Big"], ["stacked", "Stacked"], ["analog", "Analog"], ["minimal", "Minimal"], ["glow", "Glow"], ["eclipse", "Eclipse"], ["roman", "Roman"]],
      opts: [
        { k: "h24", kind: "chips", label: "Hours", def: "follow", options: [["follow", "Like the bar"], ["12", "12 h"], ["24", "24 h"]] },
        { k: "seconds", kind: "toggle", label: "Show seconds", def: false },
        { k: "date", kind: "toggle", label: "Show the date", def: true },
        { k: "ampm", kind: "toggle", label: "Show AM / PM", def: true }
      ] },
    { id: "date", cat: "time", name: "Date", icon: 0xF00ED, size: [200, 70], hint: "Day and date (Kanji needs a CJK font: noto-fonts-cjk)",
      styles: [["line", "One line"], ["card", "Card"], ["stack", "Stacked"], ["hairline", "Hairline"], ["kanji", "Kanji"]],
      opts: [{ k: "year", kind: "toggle", label: "Show the year", def: false }] },
    { id: "month", cat: "time", name: "Month calendar", icon: 0xF0E17, size: [250, 230], hint: "The month, today lit",
      styles: [["grid", "Month grid"], ["week", "Week strip"], ["mini", "Compact grid"], ["dots", "Dot grid"]],
      opts: [
        { k: "mon", kind: "chips", label: "Week starts", def: "mon", options: [["mon", "Monday"], ["sun", "Sunday"]] },
        { k: "weeks", kind: "toggle", label: "Week numbers", def: false }
      ] },
    { id: "cpu", cat: "system", name: "CPU", icon: 0xF061A, size: [120, 120], hint: "Processor load", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "ram", cat: "system", name: "Memory", icon: 0xF035B, size: [120, 120], hint: "RAM in use", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }, { k: "gb", kind: "toggle", label: "Show GB, not %", def: false }] },
    { id: "temp", cat: "system", name: "Temperature", icon: 0xF050F, size: [120, 120], hint: "CPU temperature", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "gpu", cat: "system", name: "GPU", icon: 0xF0379, size: [120, 120], hint: "Graphics load (when the machine reports it)", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"], ["history", "History"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "disk", cat: "system", name: "Disk", icon: 0xF02CA, size: [120, 120], hint: "How full the main disk is", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "battery", cat: "system", name: "Battery", icon: 0xF0079, size: [120, 120], hint: "Charge, and charging", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }, { k: "hideNoBat", kind: "toggle", label: "Hide on a desktop PC", def: true }] },
    { id: "volume", cat: "system", name: "Volume", icon: 0xF057E, size: [120, 120], hint: "Speaker volume (scroll on it to change)", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "brightness", cat: "system", name: "Brightness", icon: 0xF00DF, size: [120, 120], hint: "Screen brightness (scroll on it to change)", metric: true,
      styles: [["ring", "Ring"], ["arc", "Arc"], ["bar", "Bar"], ["pill", "Pill"], ["number", "Number"]],
      opts: [{ k: "label", kind: "toggle", label: "Show the name", def: true }] },
    { id: "sysmon", cat: "system", name: "System usage", icon: 0xF04C5, size: [260, 150], hint: "CPU, memory, temperature, disk and network together",
      styles: [["bars", "Bars"], ["rings", "Rings"], ["list", "List"], ["compact", "Compact"]],
      opts: [
        { k: "show", kind: "multi", label: "Show", def: ["cpu", "ram", "temp", "net"], options: [["cpu", "CPU"], ["ram", "Memory"], ["temp", "Temp"], ["disk", "Disk"], ["gpu", "GPU"], ["net", "Network"]] },
        { k: "width", kind: "slider", label: "Width", def: 260, min: 180, max: 460, unit: " px" }
      ] },
    { id: "net", cat: "system", name: "Network", icon: 0xF05A9, size: [220, 90], hint: "Wi-Fi name and signal, and the speed",
      styles: [["card", "Card"], ["speed", "Speed only"], ["signal", "Signal bars"]],
      opts: [{ k: "ssid", kind: "toggle", label: "Show the Wi-Fi name", def: true }] },
    { id: "uptime", cat: "system", name: "Uptime", icon: 0xF0150, size: [200, 70], hint: "How long the computer has been on",
      styles: [["line", "One line"], ["card", "Card"], ["words", "In words"], ["digital", "Digital blocks"], ["ring", "Ring"], ["bar", "Day bar"], ["boot", "Since boot"], ["dot", "Dot"]], opts: [] },
    { id: "music", cat: "media", name: "Now playing", icon: 0xF075A, size: [320, 120], hint: "The song, the cover and the buttons",
      styles: [["card", "Card"], ["compact", "Compact"], ["cover", "Cover"], ["minimal", "Minimal"]],
      opts: [
        { k: "controls", kind: "toggle", label: "Buttons", def: true },
        { k: "progress", kind: "toggle", label: "Progress bar", def: true },
        { k: "width", kind: "slider", label: "Width", def: 320, min: 220, max: 520, unit: " px" },
        { k: "hideIdle", kind: "toggle", label: "Hide while nothing plays", def: false }
      ] },
    { id: "lyrics", cat: "media", name: "Lyrics", icon: 0xF0387, size: [380, 170], hint: "The words of the song that plays: the line being sung is lit, the others fade away (needs lyrics with time stamps, found by itself)",
      styles: [["fade", "Fade"], ["karaoke", "Karaoke sweep"], ["spotlight", "Spotlight"], ["single", "One line"]],
      opts: [
        { k: "lines", kind: "slider", label: "Lines on screen", def: 5, min: 3, max: 9, unit: "" },
        { k: "size", kind: "slider", label: "Text size", def: 20, min: 12, max: 40, unit: " px" },
        { k: "fall", kind: "slider", label: "How fast the other lines fade", def: 3, min: 1, max: 6, unit: "" },
        { k: "width", kind: "slider", label: "Width", def: 380, min: 220, max: 800, unit: " px" },
        { k: "sync", kind: "slider", label: "Timing, in tenths of a second (+ earlier, - later)", def: 0, min: -30, max: 30, unit: "" },
        { k: "hideIdle", kind: "toggle", label: "Hide while nothing plays", def: true }
      ] },
    { id: "viz", cat: "media", name: "Audio visualizer", icon: 0xF075A, size: [280, 90], hint: "Bars that move with the music (needs cava)",
      styles: [["bars", "Bars"], ["mirror", "Mirror"], ["wave", "Wave"], ["dots", "Dots"], ["circle", "Circle"]],
      opts: [
        { k: "count", kind: "slider", label: "Bars", def: 24, min: 8, max: 48, unit: "" },
        { k: "width", kind: "slider", label: "Width", def: 280, min: 120, max: 700, unit: " px" },
        { k: "height", kind: "slider", label: "Height", def: 90, min: 40, max: 240, unit: " px" },
        { k: "idle", kind: "chips", label: "While silent", def: "dots", options: [["dots", "Resting dots"], ["hide", "Hide it"]] }
      ] },
    { id: "focus", cat: "focus", name: "Focus timer & streak", icon: 0xF051B, size: [220, 120], hint: "The focus session and how many days in a row you kept it",
      styles: [["ring", "Ring"], ["card", "Card"], ["compact", "Compact"], ["streak", "Streak"]],
      opts: [
        { k: "goal", kind: "slider", label: "Minutes that count as a focus day", def: 25, min: 5, max: 180, unit: " min" },
        { k: "streak", kind: "toggle", label: "Show the streak", def: true },
        { k: "buttons", kind: "toggle", label: "Start / stop button", def: true },
        { k: "week", kind: "toggle", label: "Last 7 days", def: true }
      ] },
    { id: "workspaces", cat: "desk", name: "Workspaces", icon: 0xF0208, size: [260, 50], hint: "Switch workspace (click, scroll)",
      styles: [["dots", "Dots"], ["numbers", "Numbers"], ["capsules", "Capsules"], ["pills", "Pills"], ["roman", "Roman"], ["lines", "Hairlines"], ["squares", "Squares"], ["outline", "Outline"]],
      opts: [{ k: "min", kind: "slider", label: "Always show at least", def: 5, min: 1, max: 10, unit: "" }] },
    { id: "special", cat: "desk", name: "Special workspaces", icon: 0xF0208, size: [300, 50], hint: "Scratch, music, chat and monitor workspaces, in ten looks: lit when shown, a click shows / hides one",
      styles: [["pills", "Pills"], ["icons", "Icons"], ["dots", "Dots"], ["outline", "Outline"], ["segmented", "Segmented"], ["tabs", "Tabs"], ["labels", "Labels"], ["rings", "Rings"], ["stack", "Stack"], ["glow", "Glow"]],
      opts: [{ k: "show", kind: "multi", label: "Workspaces", def: ["special", "music", "communication", "sysmon"], options: [["special", "Scratch"], ["music", "Music"], ["communication", "Chat"], ["sysmon", "Monitor"]] }] },
    { id: "toggles", cat: "desk", name: "Quick toggles", icon: 0xF0521, size: [300, 70], hint: "Buttons for Wi-Fi, Bluetooth, Do not disturb, Caffeine, Gaming, Num Lock ...",
      styles: [["row", "Row"], ["grid", "Grid"], ["icons", "Icons only"], ["list", "List"], ["outline", "Outline"], ["glyphs", "Bare icons"]],
      opts: [
        { k: "show", kind: "multi", label: "Buttons", def: ["wifi", "bt", "dnd", "caffeine", "gaming", "theme"], options: [["wifi", "Wi-Fi"], ["bt", "Bluetooth"], ["dnd", "Do not disturb"], ["caffeine", "Caffeine"], ["gaming", "Gaming"], ["numlock", "Num Lock"], ["theme", "Theme"], ["night", "Night light"], ["lock", "Lock"], ["power", "Power"]] }
      ] },
    { id: "shortcuts", cat: "desk", name: "App shortcuts", icon: 0xF003B, size: [300, 70], hint: "Your own buttons that start apps or commands",
      styles: [["row", "Row"], ["grid", "Grid"], ["list", "List"], ["outline", "Outline"], ["glyphs", "Bare"]],
      opts: [{ k: "items", kind: "text", label: "Buttons", def: "Browser=xdg-open https://;Files=thunar;Terminal=kitty", hintText: "Name=command;Name=command" }] },
    { id: "notes", cat: "desk", name: "Notes & agenda", icon: 0xF03EB, size: [290, 150], hint: "Your pinned notes and today's calendar",
      styles: [["glass", "List"], ["cards", "Cards"]],
      opts: [
        { k: "events", kind: "toggle", label: "Today's calendar", def: false },
        { k: "add", kind: "toggle", label: "\"Add a note\" row (opens the Super + N panel; the widget itself takes no typing)", def: true },
        { k: "max", kind: "slider", label: "Most lines", def: 4, min: 1, max: 8, unit: "" },
        { k: "width", kind: "slider", label: "Width", def: 290, min: 200, max: 480, unit: " px" }
      ] },
    { id: "console", cat: "desk", name: "Console", icon: 0xF018D, size: [380, 170], hint: "A console box on the desktop: shows what a command prints (refreshed by itself). Click it to open the real console",
      styles: [["terminal", "Terminal"], ["window", "Window"], ["glass", "Glass lines"], ["retro", "Retro green"], ["minimal", "Minimal"]],
      opts: [
        { k: "cmd", kind: "text", label: "Command to show", def: "printf '%s@%s\\n' \"$USER\" \"$(hostname)\"; uptime -p; free -h | sed -n 2p; df -h / | tail -1", hintText: "any shell command" },
        { k: "title", kind: "text", label: "Title", def: "console", hintText: "shown on the top bar of the box" },
        { k: "lines", kind: "slider", label: "Most lines", def: 8, min: 3, max: 24, unit: "" },
        { k: "width", kind: "slider", label: "Width", def: 380, min: 240, max: 800, unit: " px" },
        { k: "every", kind: "slider", label: "Run again every", def: 10, min: 2, max: 300, unit: " s" },
        { k: "prompt", kind: "toggle", label: "Show the command line", def: true },
        { k: "click", kind: "toggle", label: "A click opens the real console", def: true }
      ] },
    { id: "utilbox", cat: "desk", name: "Utilities box", icon: 0xF0493, size: [260, 200], hint: "The utilities box on the desktop: Wi-Fi, Bluetooth, volume, brightness, power",
      styles: [["list", "List"], ["tiles", "Tiles"], ["slim", "Slim bar"]],
      opts: [
        { k: "show", kind: "multi", label: "Show", def: ["wifi", "bt", "volume", "brightness", "power"], options: [["wifi", "Wi-Fi"], ["bt", "Bluetooth"], ["dnd", "Do not disturb"], ["volume", "Volume"], ["brightness", "Brightness"], ["power", "Power"]] },
        { k: "width", kind: "slider", label: "Width", def: 260, min: 200, max: 460, unit: " px" }
      ] },
    { id: "appsbox", cat: "desk", name: "Background apps box", icon: 0xF0570, size: [260, 120], hint: "The apps running in the background (the system tray): click one to open it",
      styles: [["list", "List"], ["icons", "Icons"], ["count", "Count only"]],
      opts: [
        { k: "width", kind: "slider", label: "Width", def: 260, min: 160, max: 460, unit: " px" },
        { k: "hideEmpty", kind: "toggle", label: "Hide when nothing runs", def: false }
      ] },
    { id: "weather", cat: "info", name: "Weather", icon: 0xF0590, size: [220, 100], hint: "Temperature and sky (asks wttr.in every 30 minutes)",
      styles: [["card", "Card"], ["compact", "Compact"], ["big", "Big"], ["whisper", "Whisper"]],
      opts: [
        { k: "place", kind: "text", label: "Place (empty = by your address)", def: "", hintText: "Berlin" },
        { k: "unit", kind: "chips", label: "Unit", def: "c", options: [["c", "Celsius"], ["f", "Fahrenheit"]] }
      ] },
    { id: "text", cat: "info", name: "Text & greeting", icon: 0xF0757, size: [260, 60], hint: "A greeting, or any words you want on the desktop",
      styles: [["greeting", "Greeting"], ["plain", "Plain text"], ["quote", "Quote"], ["epigraph", "Epigraph"], ["caption", "Caption"]],
      opts: [
        { k: "text", kind: "text", label: "Your text", def: "Stay curious.", hintText: "what to say" },
        { k: "by", kind: "text", label: "Said by (Epigraph)", def: "", hintText: "a name, or leave empty" }
      ] },
    { id: "moon", cat: "info", name: "Moon phase", icon: 0xF0F64, size: [150, 150], hint: "Tonight's moon, worked out on this computer (no internet)",
      styles: [["disc", "Disc"], ["line", "One line"], ["big", "Big"]],
      opts: [
        { k: "label", kind: "toggle", label: "Show the phase name", def: true },
        { k: "next", kind: "toggle", label: "Days to the full moon", def: true },
        { k: "south", kind: "toggle", label: "Southern hemisphere (turns it round)", def: false }
      ] },
    { id: "horizon", cat: "time", name: "Horizon", icon: 0xF0150, size: [300, 70], hint: "A hairline with a glowing dot: how far through the day (or the year) you are, with its reflection",
      styles: [["horizon", "Horizon"], ["dual", "Day and year"], ["quiet", "Quiet"], ["arc", "Sun arc"], ["ticks", "Hour ticks"]],
      opts: [
        { k: "width", kind: "slider", label: "Width", def: 300, min: 140, max: 700, unit: " px" },
        { k: "reflect", kind: "toggle", label: "Reflection", def: true },
        { k: "percent", kind: "toggle", label: "Show the percent", def: true }
      ] },
    { id: "breathe", cat: "focus", name: "Breathe", icon: 0xF051B, size: [150, 170], hint: "A flower that opens and closes slowly: a calm pace to breathe with",
      styles: [["bloom", "Bloom"], ["ring", "Ring"], ["dot", "Dot"], ["orbs", "Ripples"], ["bars", "Bars"]],
      opts: [
        { k: "secs", kind: "slider", label: "Seconds per breath", def: 10, min: 4, max: 20, unit: " s" },
        { k: "words", kind: "toggle", label: "Say in / out", def: true }
      ] }
]

// every metric widget (CPU, memory, temperature ...) also gets the two quiet styles
for (var mi = 0; mi < catalog.length; mi++)
    if (catalog[mi].metric === true) catalog[mi].styles = catalog[mi].styles.concat([["hairline", "Hairline"], ["petals", "Petals"]])

function typeOf(id) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].id === id) return catalog[i]
    return null
}
function nameOf(id) { var t = typeOf(id); return t ? t.name : id }
function iconOf(id) { var t = typeOf(id); return t ? t.icon : 0xF0A1A }
function hintOf(id) { var t = typeOf(id); return t ? t.hint : "" }

// which QML file draws each type
var files = {
    clock: "WClock.qml", date: "WClock.qml", month: "WMonth.qml",
    cpu: "WMetric.qml", ram: "WMetric.qml", temp: "WMetric.qml", gpu: "WMetric.qml", disk: "WMetric.qml", battery: "WMetric.qml", volume: "WMetric.qml", brightness: "WMetric.qml",
    sysmon: "WSysmon.qml", net: "WNet.qml", uptime: "WNet.qml",
    music: "WMusic.qml", lyrics: "WLyrics.qml", viz: "WViz.qml", focus: "WFocus.qml", workspaces: "WWorkspaces.qml", special: "WSpecial.qml", toggles: "WToggles.qml", shortcuts: "WToggles.qml",
    notes: "WNotes.qml", weather: "WWeather.qml", text: "WText.qml",
    console: "WConsole.qml", utilbox: "WBoxes.qml", appsbox: "WBoxes.qml",
    moon: "WMoon.qml", horizon: "WHorizon.qml", breathe: "WBreathe.qml"
}
function fileOf(type) { return files[type] || "WText.qml" }

// ------------------------------------------------------------------------------------------------ looks (the surface and the colours)
//   surface  glass | solid | clear | outline | pill
//   op       how solid the surface is, 0.1 .. 1
//   radius   corner radius in px, -1 = automatic
//   pad      room between the surface and the content in px, -1 = automatic
//   tone     theme | second | custom : the colour of lit parts (accent)
//   color    #rrggbb for tone = custom
//   textTone theme | light | dark | custom   ;  textColor  #rrggbb
//   depth    0 .. 1 : Colour depth. How much of the wallpaper accent goes into the box, the quiet text, the bars and the hairline
//   contrast 0 .. 1 : Readability. Lifts the lit colour a little, brightens quiet text and outlines every letter (never a box: "No box" stays see-through)
//   match    true: everything (lit colour, text, box tint) follows the wallpaper accent, whatever tone / textTone say
//   font     ui | mono | serif
//   fs       0.7 .. 1.6 : text size
//   border   a hairline around it     shadow  a soft shadow
var lookDefaults = { surface: "glass", op: 0.65, radius: -1, pad: -1, tone: "theme", color: "#9aa9d4", textTone: "theme", textColor: "#ffffff", font: "ui", fs: 1, border: true, shadow: true, contrast: 0.6, depth: 0.5, match: false }
var surfaces = [["glass", "Frosted glass"], ["solid", "Solid"], ["clear", "No box"], ["outline", "Outline"], ["pill", "Pill"]]
var tones = [["theme", "Wallpaper accent"], ["second", "Second colour"], ["custom", "My colour"]]
var swatches = ["#ffffff", "#e6e8ee", "#b9bdc8", "#9aa9d4", "#7ec8e3", "#c2add8", "#e58a8a", "#f5a623"]

// built-in styles (the Widget builder lists these, and your saved ones, under "Styles")
var presets = [
    { name: "Glass", look: { surface: "glass", op: 0.65, radius: -1, pad: -1, tone: "theme", font: "ui", fs: 1, border: true, shadow: true } },
    { name: "Clear", look: { surface: "clear", op: 0.0, radius: -1, pad: 4, tone: "theme", font: "ui", fs: 1, border: false, shadow: false } },
    { name: "Solid card", look: { surface: "solid", op: 0.94, radius: 16, pad: -1, tone: "theme", font: "ui", fs: 1, border: true, shadow: true } },
    { name: "Outline", look: { surface: "outline", op: 0.0, radius: 14, pad: -1, tone: "theme", font: "ui", fs: 1, border: true, shadow: false } },
    { name: "Terminal", look: { surface: "solid", op: 0.88, radius: 6, pad: 12, tone: "second", font: "mono", fs: 0.92, border: true, shadow: false } },
    { name: "Pill", look: { surface: "pill", op: 0.7, radius: 999, pad: 10, tone: "theme", font: "ui", fs: 0.95, border: true, shadow: true } },
    { name: "Void", look: { surface: "clear", op: 0.0, radius: -1, pad: 4, tone: "custom", color: "#ffffff", textTone: "custom", textColor: "#f2f3f7", font: "ui", fs: 1, border: false, shadow: false } },
    { name: "Moonlit", look: { surface: "glass", op: 0.22, radius: 18, pad: 16, tone: "custom", color: "#ffffff", textTone: "custom", textColor: "#eceef4", font: "ui", fs: 1, border: true, shadow: false } },
    { name: "Ink", look: { surface: "solid", op: 0.55, radius: 4, pad: 14, tone: "custom", color: "#d9dbe1", textTone: "custom", textColor: "#eceef4", font: "ui", fs: 0.96, border: true, shadow: false } },
    { name: "Haiku", look: { surface: "clear", op: 0.0, radius: -1, pad: 6, tone: "custom", color: "#e6e8ee", textTone: "custom", textColor: "#f2f3f7", font: "serif", fs: 1.05, border: false, shadow: false } },
    { name: "Silver edge", look: { surface: "outline", op: 0.0, radius: 2, pad: 14, tone: "custom", color: "#cfd2db", textTone: "custom", textColor: "#eceef4", font: "serif", fs: 1, border: true, shadow: false } },
    { name: "Neon", look: { surface: "outline", op: 0.0, radius: 12, pad: -1, tone: "custom", color: "#7ef2d0", font: "mono", fs: 1, border: true, shadow: true } }
]

function clamp(v, a, b) { return Math.max(a, Math.min(b, v)) }
function num(v, d) { var n = Number(v); return isNaN(n) ? d : n }

// anything saved -> a complete look
function look(l) {
    var o = {}
    for (var k in lookDefaults) o[k] = lookDefaults[k]
    if (l && typeof l === "object") for (var x in l) if (x in lookDefaults) o[x] = l[x]
    if (["glass", "solid", "clear", "outline", "pill"].indexOf(o.surface) < 0) o.surface = "glass"
    if (["theme", "second", "custom"].indexOf(o.tone) < 0) o.tone = "theme"
    if (["theme", "light", "dark", "custom"].indexOf(o.textTone) < 0) o.textTone = "theme"
    o.contrast = clamp(num(o.contrast, 0.6), 0, 1)
    o.depth = clamp(num(o.depth, 0.5), 0, 1)
    if (o.font !== "mono" && o.font !== "serif") o.font = "ui"
    o.op = clamp(num(o.op, 0.65), 0, 1)
    o.radius = Math.round(clamp(num(o.radius, -1), -1, 999))
    o.pad = Math.round(clamp(num(o.pad, -1), -1, 60))
    o.fs = clamp(num(o.fs, 1), 0.6, 1.8)
    o.match = o.match === true
    o.border = o.border !== false
    o.shadow = o.shadow !== false
    if (!/^#[0-9a-fA-F]{6}$/.test(String(o.color))) o.color = lookDefaults.color
    if (!/^#[0-9a-fA-F]{6}$/.test(String(o.textColor))) o.textColor = lookDefaults.textColor
    return o
}

// ------------------------------------------------------------------------------------------------ items
function optDefault(type, k) {
    var t = typeOf(type)
    if (!t) return undefined
    for (var i = 0; i < t.opts.length; i++) if (t.opts[i].k === k) return t.opts[i].def
    return undefined
}
function optOf(item, k) {
    if (item && item.opts && item.opts[k] !== undefined) return item.opts[k]
    return optDefault(item ? item.type : "", k)
}
function styleList(type) { var t = typeOf(type); return t ? t.styles : [] }
function styleOf(item) {
    var l = styleList(item.type)
    for (var i = 0; i < l.length; i++) if (l[i][0] === item.style) return item.style
    return l.length ? l[0][0] : ""
}

function nextUid(items) {
    var n = 1
    for (var i = 0; i < items.length; i++) {
        var m = /^w(\d+)$/.exec(String(items[i].uid))
        if (m) n = Math.max(n, Number(m[1]) + 1)
    }
    return "w" + n
}

function cleanItem(it, used) {
    if (!it || typeof it !== "object" || !typeOf(it.type)) return null
    var o = { uid: String(it.uid || ""), type: it.type }
    if (o.uid === "" || used[o.uid]) return null
    used[o.uid] = true
    o.px = clamp(num(it.px, 0), 0, 1)
    o.py = clamp(num(it.py, 0), 0, 1)
    o.scale = clamp(num(it.scale, 1), 0.5, 2.5)
    o.style = styleOf({ type: it.type, style: it.style })
    o.opts = {}
    if (it.opts && typeof it.opts === "object") for (var k in it.opts) o.opts[k] = it.opts[k]
    o.look = look(it.look)
    if (it.off === true) o.off = true
    // a link: this widget is tied to another one (see "links" below); the target is checked in normalize()
    if (typeof it.link === "string" && it.link !== "" && it.link !== o.uid) {
        o.link = it.link
        o.linkSide = sideOf(it.linkSide)
        o.linkGap = Math.round(clamp(num(it.linkGap, 14), 0, 200))
        var lo = Math.round(clamp(num(it.linkOrder, 0), 0, 99))
        if (lo > 0) o.linkOrder = lo
    }
    return o
}
function unlink(it) { delete it.link; delete it.linkSide; delete it.linkGap; delete it.linkOrder }

// whatever was saved -> a clean list: known types only, unique ids
function normalize(d) {
    var out = { items: [] }
    var used = {}
    var a = d && d.items && d.items.length !== undefined ? d.items : []
    for (var i = 0; i < a.length; i++) {
        var c = cleanItem(a[i], used)
        if (c) out.items.push(c)
    }
    // links: the target must exist and a chain of links must never run back to itself
    var i2, it2, anyLink = false
    for (i2 = 0; i2 < out.items.length; i2++) {
        it2 = out.items[i2]
        if (it2.link && !used[it2.link]) unlink(it2)
        if (it2.link) anyLink = true
    }
    for (i2 = 0; anyLink && i2 < out.items.length; i2++) {
        it2 = out.items[i2]
        var u = it2.link, n = 0
        while (u && n++ < 100) {
            if (u === it2.uid) { unlink(it2); break }
            var t = null
            for (var q = 0; q < out.items.length; q++) if (out.items[q].uid === u) { t = out.items[q]; break }
            u = t ? t.link : ""
        }
    }
    return out
}

function copy(d) { return normalize(JSON.parse(JSON.stringify(d || { items: [] }))) }
function find(d, uid) {
    for (var i = 0; i < d.items.length; i++) if (d.items[i].uid === uid) return d.items[i]
    return null
}

// a new widget of this type, in a free-ish spot, with the default style
function add(d, type, look0) {
    var o = copy(d)
    var t = typeOf(type)
    if (!t) return o
    var n = o.items.length
    var it = { uid: nextUid(o.items), type: type, px: clamp(0.04 + (n % 5) * 0.09, 0, 1), py: clamp(0.14 + (n % 6) * 0.08, 0, 1),
               scale: 1, style: t.styles.length ? t.styles[0][0] : "", opts: {}, look: look(look0) }
    o.items.push(it)
    return o
}
function remove(d, uid) {
    var o = copy(d)
    o.items = o.items.filter(function (i) { return i.uid !== uid })
    // widgets that followed it are freed now (nextUid() can hand the same id to a new widget, which they would then follow by accident)
    for (var i = 0; i < o.items.length; i++) if (o.items[i].link === uid) unlink(o.items[i])
    return o
}
function duplicate(d, uid) {
    var o = copy(d), src = find(o, uid)
    if (!src) return o
    var c = JSON.parse(JSON.stringify(src))
    c.uid = nextUid(o.items)
    c.px = clamp(src.px + 0.04, 0, 1); c.py = clamp(src.py + 0.06, 0, 1)
    unlink(c)
    o.items.push(c)
    return o
}
function patch(d, uid, fn) {
    var o = copy(d), it = find(o, uid)
    if (it) fn(it)
    return o
}
function setPos(d, uid, px, py) { return patch(d, uid, function (it) { it.px = clamp(px, 0, 1); it.py = clamp(py, 0, 1) }) }
function setScale(d, uid, s) { return patch(d, uid, function (it) { it.scale = clamp(s, 0.5, 2.5) }) }
// resize AND keep the widget's top-left corner where it is (positions are fractions of the free room, which changes with the size)
function setScalePos(d, uid, s, px, py) { return patch(d, uid, function (it) { it.scale = clamp(s, 0.5, 2.5); it.px = clamp(px, 0, 1); it.py = clamp(py, 0, 1) }) }

// ---- links: "this widget follows that one"
// A linked widget (item.link = the uid of its leader) sits linkGap px away from its leader: "below" / "above" it (same left edge, and
// they share one width: the widest of the stacked ones, so a visualizer and a song title line up edge to edge) or beside it, "right"
// / "left" (side by side, vertically centred on the leader; each keeps its OWN width, so when one grows - "9h" becoming "1d 11h" - the
// one next to it is pushed along instead of being overlapped). Linked widgets always share the leader's size (scale).
// Moving or resizing any of them moves / resizes the whole chain. Several widgets can follow the SAME leader: on one side of it they
// line up one after the other (see siblings()), so "two widgets linked to one" sit neatly in a row or a column.
function sideOf(s) { return (s === "above" || s === "left" || s === "right") ? s : "below" }
function isStacked(s) { return s !== "left" && s !== "right" }
function leaderOf(d, uid) { var it = find(d, uid); return (it && it.link && find(d, it.link)) ? it.link : "" }
function linkRoot(d, uid) {
    var u = uid, n = 0
    while (n++ < 100) { var l = leaderOf(d, u); if (!l) return u; u = l }
    return uid
}
// every uid tied to this one by links, in either direction (the widget itself included)
function linkGroup(d, uid) {
    var set = {}, queue = [uid], out = [uid]
    set[uid] = true
    while (queue.length) {
        var u = queue.pop(), l = leaderOf(d, u)
        if (l && !set[l]) { set[l] = true; queue.push(l); out.push(l) }
        for (var i = 0; i < d.items.length; i++) {
            var it = d.items[i]
            if (it.link === u && !set[it.uid]) { set[it.uid] = true; queue.push(it.uid); out.push(it.uid) }
        }
    }
    return out
}
// the widgets that share one width with this one: those tied to it by "above" / "below" links only (side-by-side links share size, not width)
function widthGroup(d, uid) {
    var set = {}, queue = [uid], out = [uid]
    set[uid] = true
    while (queue.length) {
        var u = queue.pop(), it0 = find(d, u)
        if (it0 && it0.link && isStacked(it0.linkSide) && find(d, it0.link) && !set[it0.link]) { set[it0.link] = true; queue.push(it0.link); out.push(it0.link) }
        for (var i = 0; i < d.items.length; i++) {
            var it = d.items[i]
            if (it.link === u && isStacked(it.linkSide) && !set[it.uid]) { set[it.uid] = true; queue.push(it.uid); out.push(it.uid) }
        }
    }
    return out
}
// the widgets that follow `leader` on one side of it, in the order they are laid out. Several widgets may follow the same one: on the
// same side they line up one after the other (the first sits against the leader, the next against the first ...), so they never cover
// each other. item.linkOrder says who is first; widgets with the same number keep the order they were added in.
function siblings(d, leader, side) {
    var out = []
    for (var i = 0; i < d.items.length; i++) {
        var c = d.items[i]
        if (c.link === leader && leaderOf(d, c.uid) === leader && sideOf(c.linkSide) === side) out.push({ uid: c.uid, o: num(c.linkOrder, 0), i: i })
    }
    out.sort(function (a, b) { return a.o !== b.o ? a.o - b.o : a.i - b.i })
    return out.map(function (x) { return x.uid })
}
// put `uid` at place `slot` (0 = first) among the widgets that follow the same one on the same side
function setLinkSlot(d, uid, slot) {
    var o = copy(d), it = find(o, uid)
    if (!it || !it.link) return o
    var sib = siblings(o, it.link, sideOf(it.linkSide)).filter(function (u) { return u !== uid })
    sib.splice(Math.max(0, Math.min(sib.length, Math.round(num(slot, 0)))), 0, uid)
    for (var i = 0; i < sib.length; i++) { var s = find(o, sib[i]); if (i > 0) s.linkOrder = i; else delete s.linkOrder }
    return o
}
// can `uid` follow `to`? (not itself, it exists, and `to` does not already follow `uid`)
function canLink(d, uid, to) {
    if (!to || to === uid || !find(d, to)) return false
    var u = to, n = 0
    while (u && n++ < 100) { if (u === uid) return false; u = leaderOf(d, u) }
    return true
}
// to = "" removes the link
function setLink(d, uid, to, side, gap) {
    var ok = canLink(d, uid, to)
    return patch(d, uid, function (it) {
        if (ok) {
            // a new leader or a new side: it goes to the end of the line of widgets that follow there (a gap slider keeps its place)
            if (it.link !== to || sideOf(it.linkSide) !== sideOf(side)) it.linkOrder = 99
            it.link = to; it.linkSide = sideOf(side); it.linkGap = Math.round(clamp(num(gap, 14), 0, 200))
        }
        else unlink(it)
    })
}

// ---- the builder's list: linked widgets are kept together, one coloured bracket and name per group
var groupColors = ["#7ec8e3", "#f5a623", "#9be37d", "#e58a8a", "#c2add8", "#7ef2d0"]
function groupColor(g) { return groupColors[((g % groupColors.length) + groupColors.length) % groupColors.length] }
// rows: [{ it, g (group number, -1 = not linked), pos (solo | first | mid | last), n (members), label, rel ("below Clock") }]
function listRows(d) {
    var done = {}, rows = [], g = 0
    var sides = { below: "below", above: "above", right: "right of", left: "left of" }
    function kids(u) {
        var o = []
        for (var i = 0; i < d.items.length; i++) { var c = d.items[i]; if (c.link === u && leaderOf(d, c.uid) === u) o.push(c.uid) }
        return o
    }
    function rel(it) {
        var l = it.link ? find(d, it.link) : null
        return l ? sides[sideOf(it.linkSide)] + " " + nameOf(l.type) : ""
    }
    for (var i = 0; i < d.items.length; i++) {
        var it = d.items[i]
        if (done[it.uid]) continue
        var members = linkGroup(d, it.uid)
        if (members.length < 2) { done[it.uid] = true; rows.push({ it: it, g: -1, pos: "solo", n: 1, label: "", rel: "" }); continue }
        var order = [], seen = {}
        var walk = function (u) { if (seen[u]) return; seen[u] = true; order.push(u); var k = kids(u); for (var j = 0; j < k.length; j++) walk(k[j]) }
        walk(linkRoot(d, it.uid))
        for (var m = 0; m < members.length; m++) if (!seen[members[m]]) { seen[members[m]] = true; order.push(members[m]) }
        for (var q = 0; q < order.length; q++) {
            var mi = find(d, order[q])
            done[order[q]] = true
            rows.push({ it: mi, g: g, pos: q === 0 ? "first" : (q === order.length - 1 ? "last" : "mid"), n: order.length,
                        label: "Group " + String.fromCharCode(65 + g % 26), rel: rel(mi) })
        }
        g++
    }
    return rows
}

// ---- snapping while a widget is dragged (one axis at a time)
// pos / size: where the dragged widget starts and how long it is on this axis. lo / hi: its allowed start range. total: the screen.
// others: [{ p, s, near }] start and length of every other widget on this axis; near = it is next to us on the OTHER axis (so
// "sit beside it" only offers itself for neighbours, not for a widget half a screen away).
// Snaps to: the screen middle and margins, another widget's start / end / middle lining up with ours, and "one gap away" from a neighbour.
// Returns { pos, guide, kind } or null. guide is where to draw the line.
function snapAxis(pos, size, lo, hi, total, others, gap, T) {
    var best = null
    function tryC(v, g, kind) {
        var d = Math.abs(pos - v)
        if (d <= T && (best === null || d < best.d - 0.001)) best = { d: d, pos: v, guide: g, kind: kind }
    }
    tryC((total - size) / 2, total / 2, "mid")
    tryC(lo, lo, "edge")
    tryC(hi, hi + size, "edge")
    for (var i = 0; i < others.length; i++) {
        var o = others[i]
        tryC(o.p, o.p, "align")
        tryC(o.p + o.s - size, o.p + o.s, "align")
        tryC(o.p + (o.s - size) / 2, o.p + o.s / 2, "align")
        if (o.near) {
            tryC(o.p + o.s + gap, o.p + o.s + gap / 2, "gap")
            tryC(o.p - gap - size, o.p - gap / 2, "gap")
        }
    }
    return best
}
// switch a widget off (it stays in the layout, nothing is drawn, no reader runs) and on again
function setOff(d, uid, off) { return patch(d, uid, function (it) { if (off) it.off = true; else delete it.off }) }
function isOff(it) { return !!it && it.off === true }
function setStyle(d, uid, s) { return patch(d, uid, function (it) { it.style = s }) }
function setOpt(d, uid, k, v) { return patch(d, uid, function (it) { it.opts[k] = v }) }
// one look value on EVERY widget (for example "match the wallpaper" on all of them)
function setLookAll(d, k, v) {
    var o = copy(d)
    for (var i = 0; i < o.items.length; i++) { o.items[i].look = o.items[i].look || {}; o.items[i].look[k] = v; o.items[i].look = look(o.items[i].look) }
    return o
}
function setLook(d, uid, k, v) { return patch(d, uid, function (it) { it.look[k] = v; it.look = look(it.look) }) }
function applyLook(d, uid, l) { return patch(d, uid, function (it) { it.look = look(l) }) }
function bringFront(d, uid) {
    var o = copy(d), it = find(o, uid)
    if (!it) return o
    o.items = o.items.filter(function (i) { return i.uid !== uid })
    o.items.push(it)
    return o
}

// ------------------------------------------------------------------------------------------------ places
var spots = [["tl", "Top-left", 0, 0], ["tc", "Top", 0.5, 0], ["tr", "Top-right", 1, 0], ["ml", "Left", 0, 0.5], ["mc", "Centre", 0.5, 0.5], ["mr", "Right", 1, 0.5],
             ["bl", "Bottom-left", 0, 1], ["bc", "Bottom", 0.5, 1], ["br", "Bottom-right", 1, 1]]
function placeAt(d, uid, spotId) {
    uid = linkRoot(d, uid)      // a linked widget can not be placed on its own: the first widget of its chain moves and the rest follow
    for (var i = 0; i < spots.length; i++) if (spots[i][0] === spotId) return setPos(d, uid, spots[i][2], spots[i][3])
    return d
}
function spotName(it) {
    for (var i = 0; i < spots.length; i++) if (Math.abs(spots[i][2] - it.px) < 0.06 && Math.abs(spots[i][3] - it.py) < 0.06) return spots[i][1]
    return Math.round(it.px * 100) + " %, " + Math.round(it.py * 100) + " %"
}

// pixel position of a widget: free = the screen minus the margins and the widget itself
function posX(it, screenW, w, margin) { return Math.round(margin + it.px * Math.max(0, screenW - w - 2 * margin)) }
function posY(it, screenH, h, top, bottom) { return Math.round(top + it.py * Math.max(0, screenH - h - top - bottom)) }
function fracX(x, screenW, w, margin) { var r = screenW - w - 2 * margin; return r <= 0 ? 0 : clamp((x - margin) / r, 0, 1) }
function fracY(y, screenH, h, top, bottom) { var r = screenH - h - top - bottom; return r <= 0 ? 0 : clamp((y - top) / r, 0, 1) }

// the old Desktop builder's notes / calendar choice (opt.deskNotes: off | notes | both) -> one notes widget, once
function migrate(opt) {
    if (!opt) return null
    if (opt.deskWidgets && opt.deskWidgets.items) return null
    var m = opt.deskNotes
    if (m !== "notes" && m !== "both") return null
    var o = add({ items: [] }, "notes")
    o.items[0].px = 0.03; o.items[0].py = 0.12
    o.items[0].opts.events = (m === "both")
    return o
}

// "Name=command;Name=command" -> [{ name, cmd }]
function parseShortcuts(s) {
    var out = [], parts = String(s || "").split(";")
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim()
        if (p === "") continue
        var j = p.indexOf("=")
        if (j < 1) continue
        var n = p.substring(0, j).trim(), c = p.substring(j + 1).trim()
        if (n !== "" && c !== "") out.push({ name: n, cmd: c })
        if (out.length >= 8) break
    }
    return out
}

// which feeds the widgets on the desktop need (shell.qml starts a reader only while one of its widgets exists)
function needs(d) {
    var n = { viz: false, ctl: false, disk: false, gpu: false, numlock: false, weather: false, focusLog: false }
    if (!d || !d.items) return n
    for (var i = 0; i < d.items.length; i++) {
        if (d.items[i].off === true) continue
        var t = d.items[i].type
        if (t === "viz") n.viz = true
        if (t === "volume" || t === "brightness") n.ctl = true
        if (t === "disk") n.disk = true
        if (t === "gpu") n.gpu = true
        if (t === "focus") n.focusLog = true
        if (t === "weather") n.weather = true
        if (t === "toggles") {
            var s = optOf(d.items[i], "show") || []
            if (s.indexOf("numlock") >= 0) n.numlock = true
        }
        if (t === "utilbox") {          // its volume / brightness sliders read the same feed as the volume and brightness widgets
            var us = optOf(d.items[i], "show") || []
            if (us.indexOf("volume") >= 0 || us.indexOf("brightness") >= 0) n.ctl = true
        }
        if (t === "sysmon") {
            var sh = optOf(d.items[i], "show") || []
            if (sh.indexOf("disk") >= 0) n.disk = true
            if (sh.indexOf("gpu") >= 0) n.gpu = true
        }
    }
    return n
}

// ------------------------------------------------------------------------------------------------ desktop editor: grid and measuring
var gridSizes = [[20, "20 px"], [40, "40 px"], [80, "80 px"], [120, "120 px"]]
// the thin lines of the editor's grid, as px positions from a start (margin / top inset) to an end
function gridLines(start, end, step) {
    var out = []
    if (step < 8) return out
    for (var v = start; v <= end + 0.5; v += step) out.push(Math.round(v))
    return out
}
// distances (px) from a rectangle to the screen's four edges and to the nearest widget on each side
// r = { x, y, w, h }, others = [{ x, y, w, h }], screen = { w, h }. A side with no neighbour reports the screen edge (kind "edge").
function measure(r, others, screen) {
    var res = {
        left:   { d: r.x, kind: "edge", from: 0, at: r.y + r.h / 2 },
        right:  { d: screen.w - (r.x + r.w), kind: "edge", from: r.x + r.w, at: r.y + r.h / 2 },
        top:    { d: r.y, kind: "edge", from: 0, at: r.x + r.w / 2 },
        bottom: { d: screen.h - (r.y + r.h), kind: "edge", from: r.y + r.h, at: r.x + r.w / 2 }
    }
    for (var i = 0; i < others.length; i++) {
        var o = others[i]
        var vOverlap = o.y < r.y + r.h && o.y + o.h > r.y
        var hOverlap = o.x < r.x + r.w && o.x + o.w > r.x
        if (vOverlap) {
            var cy = (Math.max(o.y, r.y) + Math.min(o.y + o.h, r.y + r.h)) / 2
            if (o.x + o.w <= r.x && r.x - (o.x + o.w) < res.left.d)  res.left  = { d: r.x - (o.x + o.w), kind: "widget", from: o.x + o.w, at: cy }
            if (o.x >= r.x + r.w && o.x - (r.x + r.w) < res.right.d) res.right = { d: o.x - (r.x + r.w), kind: "widget", from: r.x + r.w, at: cy }
        }
        if (hOverlap) {
            var cx = (Math.max(o.x, r.x) + Math.min(o.x + o.w, r.x + r.w)) / 2
            if (o.y + o.h <= r.y && r.y - (o.y + o.h) < res.top.d)  res.top    = { d: r.y - (o.y + o.h), kind: "widget", from: o.y + o.h, at: cx }
            if (o.y >= r.y + r.h && o.y - (r.y + r.h) < res.bottom.d) res.bottom = { d: o.y - (r.y + r.h), kind: "widget", from: r.y + r.h, at: cx }
        }
    }
    return res
}
