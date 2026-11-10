.pragma library

// Time-of-day grade for the wallpaper (Settings > Splash, sky & time of day > "Time-of-day wallpaper").
// A soft colour wash and a little dimming laid over the picture, following the sun through the day:
//   deep blue night  ->  rose dawn  ->  clear morning  ->  untouched noon  ->  warm afternoon  ->  amber golden hour
//   ->  magenta dusk  ->  blue evening  ->  night again
// The wallpaper file itself is never changed, and the same wash is drawn on any picture. Pure functions, no Qt: tests/timeofday.test.js.
//
// A key is [hour, r, g, b, tint alpha, dim alpha]: the wash colour (0..1), how strongly it is laid on (at full strength), and how much
// black goes on top. Between two keys everything is blended linearly; the list wraps, so 24:00 equals 00:00.
var KEYS = [
    [0.0,  0.10, 0.16, 0.42, 0.34, 0.18],
    [4.5,  0.12, 0.18, 0.45, 0.30, 0.14],
    [6.0,  1.00, 0.55, 0.45, 0.20, 0.06],
    [8.0,  1.00, 0.80, 0.55, 0.08, 0.00],
    [12.0, 1.00, 1.00, 1.00, 0.00, 0.00],
    [16.0, 1.00, 0.92, 0.75, 0.06, 0.00],
    [18.0, 1.00, 0.62, 0.30, 0.22, 0.03],
    [19.5, 0.85, 0.35, 0.55, 0.26, 0.08],
    [21.0, 0.25, 0.25, 0.62, 0.30, 0.14],
    [24.0, 0.10, 0.16, 0.42, 0.34, 0.18]
]

// name of the part of the day (for a tooltip, the weekly sky card, `halcyon` output ...)
function phaseName(hour) {
    var h = wrap(hour)
    if (h < 5) return "night"
    if (h < 8) return "dawn"
    if (h < 16.5) return "day"
    if (h < 19) return "golden hour"
    if (h < 21) return "dusk"
    return "night"
}

function wrap(h) {
    var x = Number(h)
    if (!isFinite(x)) x = 12
    x = x % 24
    return x < 0 ? x + 24 : x
}

function clamp01(x) { return Math.max(0, Math.min(1, x)) }

// hour: 0 .. 24 (12.5 = 12:30); strength: 0 .. 1 (how much of the effect; 0 = none)
// -> { r, g, b, tint (alpha of the wash), dim (alpha of the black), name }
function at(hour, strength) {
    var h = wrap(hour)
    var s = clamp01(strength === undefined ? 1 : Number(strength))
    if (!isFinite(s)) s = 1
    var a = KEYS[0], b = KEYS[KEYS.length - 1]
    for (var i = 0; i < KEYS.length - 1; i++) {
        if (h >= KEYS[i][0] && h <= KEYS[i + 1][0]) { a = KEYS[i]; b = KEYS[i + 1]; break }
    }
    var span = b[0] - a[0]
    var t = span > 0 ? (h - a[0]) / span : 0
    t = t * t * (3 - 2 * t)                                  // smoothstep: the change eases in and out of every key
    function mix(k) { return a[k] + (b[k] - a[k]) * t }
    return { r: mix(1), g: mix(2), b: mix(3), tint: mix(4) * s, dim: mix(5) * s, name: phaseName(h) }
}

// the hour as a number from a Date (or a SystemClock's hours / minutes)
function hourOf(d) { return d.getHours() + d.getMinutes() / 60 }
