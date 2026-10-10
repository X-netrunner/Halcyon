#!/usr/bin/env bash
# palette.sh <image>   wallpaper -> ~/.cache/island/palette.json (one line; the island tails it, terminals follow it)
#
# Same job as `hx palette`, rewritten so the island really takes on the wallpaper's colours:
#   * the accent is the wallpaper's own dominant colour (hue AND saturation), only lightened enough to read on dark glass
#   * dark / dull wallpapers no longer fall back to a fixed blue: the accent follows whatever colour they do have,
#     and a truly grey picture gets a neutral accent
#   * accent2 is the second most important hue (or a close neighbour of the first when there is only one)
#   * "dominant" is the raw average colour of the main hue, for anything that wants the real colour
#   * "swatches" is every colour the picture really has: up to 6 hues (about 50 degrees apart, each with a real share of
#     the picture), strongest first. Settings > Colours > "Cycle through the wallpaper" slides the accent from one to the
#     next, and the terminal colours (scripts/term-colors.sh) use them for red / green / blue / magenta ...
# Needs ImageMagick (magick or convert), od and awk: all of them are on every Arch install.
export LC_ALL=C          # awk must print 12.5, never 12,5
img="${1:-}"
# no argument = the wallpaper in use (Settings > Colour intensity re-runs it this way)
[ -n "$img" ] || img=$(sed -n 2p "$HOME/.local/state/island/wallpaper" 2>/dev/null)
[ -f "$img" ] || exit 1
# Settings > Look > Colour intensity: 0.5 (calm) .. 1.5 (vivid), default 1
boost=$(head -n1 "$HOME/.local/state/island/color-boost" 2>/dev/null)
case "$boost" in ''|*[!0-9.]*) boost=1 ;; esac
out="$HOME/.cache/island/palette.json"
mkdir -p "$(dirname "$out")"
IM=magick; command -v magick >/dev/null 2>&1 || IM=convert
command -v "$IM" >/dev/null 2>&1 || exit 2

json=$("$IM" "${img}[0]" -resize 64x64! -depth 8 rgb:- 2>/dev/null | od -An -v -tu1 -w3 | awk -v BOOST="$boost" '
function max3(a, b, c) { return (a > b ? (a > c ? a : c) : (b > c ? b : c)) }
function min3(a, b, c) { return (a < b ? (a < c ? a : c) : (b < c ? b : c)) }
function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x) }
function hex2(x) { x = int(x * 255 + 0.5); if (x < 0) x = 0; if (x > 255) x = 255; return sprintf("%02x", x) }
function hue2rgb(m1, m2, h) {
    h = h - int(h); if (h < 0) h += 1
    if (h < 1/6) return m1 + (m2 - m1) * h * 6
    if (h < 0.5) return m2
    if (h < 2/3) return m1 + (m2 - m1) * (2/3 - h) * 6
    return m1
}
function hsl(h, s, l,    m1, m2) {
    h = h - int(h); if (h < 0) h += 1
    s = clamp(s, 0, 1); l = clamp(l, 0, 1)
    if (s == 0) return "#" hex2(l) hex2(l) hex2(l)
    m2 = (l <= 0.5) ? l * (1 + s) : l + s - l * s
    m1 = 2 * l - m2
    return "#" hex2(hue2rgb(m1, m2, h + 1/3)) hex2(hue2rgb(m1, m2, h)) hex2(hue2rgb(m1, m2, h - 1/3))
}
# weighted circular mean of the hue histogram bins around k (k-1, k, k+1): sets H, S, V, R, G, B (R,G,B = raw mean colour)
function around(k,    j, kk, cx, cy, ws, ss_, vs, rs, gs, bs) {
    for (j = -1; j <= 1; j++) {
        kk = (k + j + BINS) % BINS
        cx += CX[kk]; cy += CY[kk]; ws += W[kk]; ss_ += SS[kk]; vs += SV[kk]; rs += SR[kk]; gs += SG[kk]; bs += SB[kk]
    }
    if (ws <= 0) { H = 0.62; S = 0.3; V = 0.6; RR = GG = BB = 0.5; return 0 }
    H = atan2(cy, cx) / 6.283185307; if (H < 0) H += 1
    S = ss_ / ws; V = vs / ws; RR = rs / ws; GG = gs / ws; BB = bs / ws
    return ws
}
BEGIN { BINS = 36; PI2 = 6.283185307 }
NF >= 3 {
    r = $1 / 255; g = $2 / 255; b = $3 / 255
    n++; mr += r; mg += g; mb += b; lsum += 0.2126 * r + 0.7152 * g + 0.0722 * b
    mx = max3(r, g, b); mn = min3(r, g, b); v = mx; d = mx - mn
    if (mx <= 0) next
    s = d / mx
    if (s < 0.10 || v < 0.10) next            # grey / near-black pixels say nothing about the colour
    if (r == mx) h = (g - b) / d; else if (g == mx) h = 2 + (b - r) / d; else h = 4 + (r - g) / d
    h = h / 6; if (h < 0) h += 1
    wt = (s ^ 2) * (0.25 + v)
    k = int(h * BINS) % BINS
    W[k] += wt; CX[k] += wt * cos(h * PI2); CY[k] += wt * sin(h * PI2)
    SS[k] += wt * s; SV[k] += wt * v; SR[k] += wt * r; SG[k] += wt * g; SB[k] += wt * b
}
END {
    if (n == 0) exit 1
    for (k = 0; k < BINS; k++) SM[k] = W[k] + 0.5 * (W[(k + BINS - 1) % BINS] + W[(k + 1) % BINS])
    top = 0; for (k = 1; k < BINS; k++) if (SM[k] > SM[top]) top = k
    mr /= n; mg /= n; mb /= n
    if (SM[top] < 3.0) {
        # (almost) grey picture: a neutral accent in its own faint tint, never a random colour
        mx = max3(mr, mg, mb); mn = min3(mr, mg, mb); d = mx - mn
        h1 = 0.60; if (d > 0.02) { if (mr == mx) h1 = (mg - mb) / d; else if (mg == mx) h1 = 2 + (mb - mr) / d; else h1 = 4 + (mr - mg) / d; h1 = h1 / 6; if (h1 < 0) h1 += 1 }
        sa = 0.16; sa2 = 0.14; h2 = h1 + 0.05; sbg = 0.12
        if (d <= 0.02) { sa = 0.08; sa2 = 0.08; sbg = 0.04 }      # truly neutral: no tint at all
        dom = sprintf("#%s%s%s", hex2(mr), hex2(mg), hex2(mb))
    } else {
        around(top); h1 = H; sat1 = S; dom = sprintf("#%s%s%s", hex2(RR), hex2(GG), hex2(BB)); wtop = SM[top]
        # second hue: at least 30 degrees away, with a real share of the picture
        sec = -1; best = 0
        for (k = 0; k < BINS; k++) {
            dist = (k - top + BINS) % BINS; if (BINS - dist < dist) dist = BINS - dist
            if (dist >= 3 && SM[k] > 0.22 * wtop && SM[k] > best) { best = SM[k]; sec = k }
        }
        if (sec >= 0) { around(sec); h2 = H; sat2 = S } else { h2 = h1 + 0.08; sat2 = sat1 * 0.9 }
        sa = clamp(sat1 * BOOST, 0.34 * BOOST, 0.92); sa2 = clamp(sat2 * BOOST, 0.30 * BOOST, 0.90)
        sbg = 0.30
        # every real colour of the picture, strongest first; a hue "uses up" the 50 degrees around it
        nsw = 0
        for (k = 0; k < BINS; k++) SM2[k] = SM[k]
        for (pick = 0; pick < 6; pick++) {
            bk = -1; bw = 0
            for (k = 0; k < BINS; k++) if (SM2[k] > bw) { bw = SM2[k]; bk = k }
            if (bk < 0 || bw < 0.14 * wtop) break
            around(bk)
            SW[nsw++] = hsl(H, clamp(S * BOOST, 0.34 * BOOST, 0.92), 0.70)
            for (j = -2; j <= 2; j++) SM2[(bk + j + BINS) % BINS] = 0
        }
        for (i = 0; i < nsw; i++) sws = sws (i ? "," : "") "\"" SW[i] "\""
    }
    printf "{\"bg\":\"%s\",\"surface\":\"%s\",\"surfaceHi\":\"%s\",\"accent\":\"%s\",\"accent2\":\"%s\",\"text\":\"%s\",\"muted\":\"%s\",\"dominant\":\"%s\",\"lum\":%.3f,\"swatches\":[%s]}\n", \
        hsl(h1, sbg, 0.095), hsl(h1, sbg - 0.04, 0.155), hsl(h1, sbg - 0.04, 0.205), \
        hsl(h1, sa, 0.70), hsl(h2, sa2, 0.72), hsl(h1, 0.20, 0.89), hsl(h1, 0.10, 0.64), dom, lsum / n, sws
}')
[ -n "$json" ] || exit 1
# in place (no rename), so `tail -F` in the island sees it
printf '%s\n' "$json" > "$out"

# Notify the island directly via IPC so it updates immediately
if command -v quickshell >/dev/null 2>&1; then
  quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island reloadPalette >/dev/null 2>&1 || true
fi
