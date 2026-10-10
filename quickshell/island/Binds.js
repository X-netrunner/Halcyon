.pragma library
// Every shortcut, gesture and CLI helper Halcyon documents. The cheatsheet tree (Cheatsheet.qml) draws this list, and the
// entries that have an `id` can be changed there: the new keys are saved by the island in
// ~/.local/state/island/binds.json and written for Hyprland to ~/.local/state/island/binds.lua, which
// hyprland/keybinds.lua reads (and applies with a Hyprland reload).
//
//   id      the name used in hyprland/keybinds.lua  (no id = shown only, cannot be changed here)
//   keys    the DEFAULT keys, in Hyprland's notation ("SUPER + ALT + T"). hyprland/keybinds.lua has the same defaults,
//           so keep the two in step when you change one
//   kind    bind (default) | text (free text instead of keycaps: gestures, mouse, ...) | cli (a command in a terminal)

var groups = [
    { id: "apps", title: "Apps", items: [
        { id: "terminal", label: "Terminal", keys: "SUPER + T" },
        { id: "files", label: "File manager", keys: "SUPER + E" },
        { id: "browser", label: "Browser", keys: "SUPER + W" },
        { id: "editor", label: "Code editor", keys: "SUPER + C" }
    ] },
    { id: "windows", title: "Windows", items: [
        { id: "close", label: "Close window", keys: "SUPER + Q" },
        { id: "fullscreen", label: "Fullscreen", keys: "SUPER + F" },
        { id: "pin", label: "Pin window", keys: "SUPER + P" },
        { id: "float", label: "Toggle floating", keys: "SUPER + ALT + space" },
        { label: "Move a window with the mouse", kind: "text", keys: "Super + right button, drag" },
        { label: "Resize a window with the mouse", kind: "text", keys: "Super + left button, drag" },
        { id: "swapsplit", label: "Swap split", keys: "SUPER + Y" },
        { id: "layout", label: "Layout: dwindle / scrolling", keys: "SUPER + ALT + T" }
    ] },
    { id: "workspaces", title: "Workspaces", items: [
        { label: "Go to workspace", kind: "text", keys: "Super + 1..9" },
        { label: "Move window to workspace", kind: "text", keys: "Super + Alt + 1..9" },
        { id: "wsnext", label: "Next workspace (a new one after the last)", keys: "SUPER + CTRL + Right" },
        { id: "wsprev", label: "Previous workspace (first wraps to last)", keys: "SUPER + CTRL + Left" },
        { id: "ws_scroll_down", label: "Next workspace (scroll down)", keys: "SUPER + mouse_down" },
        { id: "ws_scroll_up", label: "Previous workspace (scroll up)", keys: "SUPER + mouse_up" },
        { id: "scratch", label: "Scratch workspace (overlay)", keys: "SUPER + S" },
        { id: "toscratch", label: "Send window to scratch", keys: "SUPER + ALT + S" },
        { id: "music", label: "Music (your default player)", keys: "SUPER + M" },
        { id: "sysmon", label: "System monitor", keys: "CTRL + SHIFT + Escape" },
        { id: "comm", label: "Communication (your chat app)", keys: "SUPER + D" },
        { id: "todo", label: "Tasks", keys: "SUPER + R" }
    ] },
    { id: "island", title: "Island", items: [
        { id: "launcher", label: "Launcher", keys: "Super" },
        { id: "overview", label: "Live workspace tree", keys: "SUPER + TAB" },
        { id: "cheatsheet", label: "This cheatsheet", keys: "SUPER + slash" },
        { id: "settings", label: "Rice settings", keys: "SUPER + F11" },
        { id: "theme", label: "Light / dark theme", keys: "SUPER + SHIFT + T" },
        { id: "notifcenter", label: "Notification centre", keys: "SUPER + SHIFT + N" },
        { id: "dnd", label: "Do not disturb", keys: "SUPER + SHIFT + D" },
        { id: "clearnotifs", label: "Clear all notifications", keys: "CTRL + ALT + C" },
        { id: "quickterm", label: "Quick console", keys: "SUPER + SHIFT + Return" },
        { id: "apps", label: "Background apps box", keys: "SUPER + SHIFT + A" },
        { id: "gaming", label: "Gaming mode", keys: "SUPER + F10" },
        { label: "Drag the bar left / right", kind: "text", keys: "perf / media page" },
        { label: "Hover the bottom-right corner", kind: "text", keys: "utilities" },
        { label: "Hover the bottom-left corner", kind: "text", keys: "background apps" }
    ] },
    { id: "toggles", title: "Toggles", items: [
        { id: "power", label: "Auto power manager", keys: "SUPER + ALT + P" },
        { id: "caffeine", label: "Caffeine (screen stays awake)", keys: "SUPER + ALT + C" },
        { id: "focus", label: "Focus mode (timer, do not disturb, blocked apps)", keys: "SUPER + ALT + F" },
        { id: "gestures", label: "Touchpad edge gestures", keys: "SUPER + ALT + G" },
        { id: "livewall", label: "Live wallpaper", keys: "SUPER + ALT + W" },
        { id: "nextwall", label: "Next wallpaper", keys: "SUPER + SHIFT + W" },
        { id: "nightlight", label: "Nightlight", keys: "SUPER + ALT + N" },
        { label: "Touchpad on / off", kind: "text", keys: "Fn + touchpad key" }
    ] },
    { id: "system", title: "System", items: [
        { id: "clipboard", label: "Clipboard history", keys: "SUPER + V" },
        { id: "emoji", label: "Emoji picker", keys: "SUPER + period" },
        { id: "shot", label: "Screenshot (full)", keys: "Print" },
        { id: "shotarea", label: "Screenshot area (freeze, save + copy)", keys: "SUPER + SHIFT + S" },
        { id: "shotplain", label: "Screenshot area (save only)", keys: "SUPER + SHIFT + Print" },
        { id: "lock", label: "Lock screen", keys: "SUPER + L" },
        { id: "session", label: "Session menu", keys: "CTRL + ALT + Delete" }
    ] },
    { id: "touchpad", title: "Touchpad", items: [
        { label: "Volume up / down", kind: "text", keys: "right edge, slide" },
        { label: "Brightness up / down", kind: "text", keys: "top edge, slide" },
        { label: "Next / previous track", kind: "text", keys: "left edge, flick" },
        { label: "Next / previous workspace (new one at the end)", kind: "text", keys: "3 fingers right = next; 4 fingers left = next" },
        { label: "Scratch workspace", kind: "text", keys: "3 fingers, up / down" },
        { label: "Sleep", kind: "text", keys: "4 fingers, down" },
        { label: "Workspace tree", kind: "text", keys: "3-finger pinch" }
    ] },
    { id: "mouse", title: "Mouse & Gestures", items: [
        { label: "Move a window", kind: "text", keys: "Super + right drag" },
        { label: "Resize a window", kind: "text", keys: "Super + left drag" },
        { label: "Switch workspaces", kind: "text", keys: "Super + scroll wheel" },
        { label: "Toggle island control center", kind: "text", keys: "Click status ring / notch" },
        { label: "Media / performance page", kind: "text", keys: "Drag island bar left / right" },
        { label: "Cycle workspaces on bar", kind: "text", keys: "Scroll on island bar" }
    ] },
    { id: "sysmode", title: "Sysmode (terminal, sudo)", items: [
        { label: "Active profile and kernel metrics", kind: "cli", keys: "sysmode status" },
        { label: "Daily hardening", kind: "cli", keys: "sysmode secure" },
        { label: "Relaxed mode (training lab)", kind: "cli", keys: "sysmode relaxed" },
        { label: "Decoy / counter-recon lab", kind: "cli", keys: "sysmode stealth" },
        { label: "Fortress mode (reboot to exit)", kind: "cli", keys: "sysmode lockdown" },
        { label: "Audit the profile / check dependencies", kind: "cli", keys: "sysmode verify | doctor" }
    ] }
]

// ---------------------------------------------------------------- notation helpers
var modOrder = ["CTRL", "SUPER", "ALT", "SHIFT"]
var modNames = { "SUPER": "Super", "ALT": "Alt", "CTRL": "Ctrl", "SHIFT": "Shift" }
var keyNames = {
    "slash": "/", "period": ".", "comma": ",", "space": "Space", "return": "Enter", "escape": "Esc", "tab": "Tab",
    "grave": "`", "backslash": "\\", "delete": "Del", "backspace": "⌫", "print": "Print", "left": "←", "right": "→",
    "up": "↑", "down": "↓", "minus": "-", "equal": "=", "semicolon": ";", "apostrophe": "'", "bracketleft": "[",
    "bracketright": "]", "pageup": "PgUp", "pagedown": "PgDn", "home": "Home", "end": "End", "insert": "Ins",
    "mouse_down": "Scroll Down", "mouse_up": "Scroll Up", "mouse:272": "Left Click", "mouse:273": "Right Click", "mouse:274": "Middle Click"
}

// "SUPER + ALT + slash" -> { mods: { SUPER: true, ALT: true }, key: "slash" }
function parse(keys) {
    var out = { mods: {}, key: "" }
    var parts = String(keys || "").split("+")
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim()
        if (p === "") continue
        var up = p.toUpperCase()
        if (up === "SUPER" || up === "ALT" || up === "CTRL" || up === "SHIFT") out.mods[up] = true
        else out.key = p
    }
    return out
}

// the inverse. Letters are written upper case like the rest of the config ("SUPER + T")
function build(mods, key) {
    var parts = []
    for (var i = 0; i < modOrder.length; i++) if (mods && mods[modOrder[i]]) parts.push(modOrder[i])
    if (key) parts.push(key.length === 1 ? key.toUpperCase() : key)
    return parts.join(" + ")
}

// compare two key strings no matter how they are written
function norm(keys) {
    var p = parse(keys)
    var m = []
    for (var i = 0; i < modOrder.length; i++) if (p.mods[modOrder[i]]) m.push(modOrder[i])
    return m.join("+") + "|" + p.key.toLowerCase()
}

// the keycaps to draw: "SUPER + ALT + slash" -> ["Super", "Alt", "/"]
function parts(keys) {
    var p = parse(keys)
    var out = []
    for (var i = 0; i < modOrder.length; i++) if (p.mods[modOrder[i]]) out.push(modNames[modOrder[i]])
    if (p.key !== "") {
        var low = p.key.toLowerCase()
        out.push(keyNames[low] !== undefined ? keyNames[low] : (p.key.length === 1 ? p.key.toUpperCase() : p.key.charAt(0).toUpperCase() + p.key.slice(1)))
    }
    return out
}

// ---------------------------------------------------------------- capturing a key press (Qt key code -> Hyprland key name)
var qtNames = {
    0x20: "space", 0x27: "apostrophe", 0x2c: "comma", 0x2d: "minus", 0x2e: "period", 0x2f: "slash", 0x3b: "semicolon",
    0x3d: "equal", 0x5b: "bracketleft", 0x5c: "backslash", 0x5d: "bracketright", 0x60: "grave",
    0x01000001: "Tab", 0x01000003: "BackSpace", 0x01000004: "Return", 0x01000005: "Return", 0x01000006: "Insert",
    0x01000007: "Delete", 0x01000009: "Print", 0x01000010: "Home", 0x01000011: "End", 0x01000012: "Left",
    0x01000013: "Up", 0x01000014: "Right", 0x01000015: "Down", 0x01000016: "Prior", 0x01000017: "Next"
}
var qtModifierKeys = [0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01000024, 0x01000025, 0x01000053, 0x01000054,
                      0x01000055, 0x01000056, 0x01000057, 0x01001103, 0x0100117e]

function isModifierKey(code) { return qtModifierKeys.indexOf(code) >= 0 }
function qtKey(code) {
    if (code >= 0x41 && code <= 0x5a) return String.fromCharCode(code)           // A..Z
    if (code >= 0x30 && code <= 0x39) return String.fromCharCode(code)           // 0..9
    if (code >= 0x01000030 && code <= 0x0100003b) return "F" + (code - 0x01000030 + 1)
    return qtNames[code] || ""
}
// Qt modifier flags -> { SUPER, ALT, CTRL, SHIFT }
function qtMods(flags) {
    var m = {}
    if (flags & 0x10000000) m.SUPER = true
    if (flags & 0x08000000) m.ALT = true
    if (flags & 0x04000000) m.CTRL = true
    if (flags & 0x02000000) m.SHIFT = true
    return m
}
// a shortcut without a modifier would swallow that key everywhere, so only these may go alone
function mayBeAlone(key) { return /^F([1-9]|1[0-2])$/.test(key) || key === "Print" }

// ---------------------------------------------------------------- the effective list, conflicts
function effectiveKeys(item, keyMap) {
    if (!item.id) return item.keys
    return keyMap && keyMap[item.id] !== undefined ? keyMap[item.id] : item.keys
}

// name of whatever already uses `keys` (ignoring `exceptId`), or "" when it is free
function conflict(keys, exceptId, keyMap, customs) {
    var n = norm(keys)
    for (var g = 0; g < groups.length; g++) {
        var its = groups[g].items
        for (var i = 0; i < its.length; i++) {
            if (!its[i].id || its[i].id === exceptId) continue
            var k = effectiveKeys(its[i], keyMap)
            if (k === "none" || k === "") continue
            if (norm(k) === n) return its[i].label
        }
    }
    for (var c = 0; c < (customs || []).length; c++) {
        if (("custom:" + c) === exceptId) continue
        if (norm(customs[c].keys) === n) return customs[c].label || customs[c].cmd
    }
    return ""
}

function countAll(customs) {
    var n = (customs || []).length
    for (var g = 0; g < groups.length; g++) n += groups[g].items.length
    return n
}

// ---------------------------------------------------------------- export for Hyprland (binds.lua)
function luaStr(s) {
    return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, " ") + '"'
}
function toLua(keyMap, customs) {
    var out = ["-- written by the island (Cheatsheet): do not edit, change shortcuts there", "return {", "  keys = {"]
    for (var id in keyMap) out.push("    [" + luaStr(id) + "] = " + luaStr(keyMap[id]) + ",")
    out.push("  },", "  custom = {")
    for (var i = 0; i < (customs || []).length; i++)
        out.push("    { keys = " + luaStr(customs[i].keys) + ", cmd = " + luaStr(customs[i].cmd) + " },")
    out.push("  },", "}", "")
    return out.join("\n")
}
