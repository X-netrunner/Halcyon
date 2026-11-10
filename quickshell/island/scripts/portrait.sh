#!/usr/bin/env bash
# portrait.sh <image> [grid]   profile picture -> a high-detail growing constellation (JSON for ModeArt.qml)
#
#   { "w":160, "h":160, "stars":[[x,y,size,t],...], "edges":[[a,b,t],...], "dust":[] }
#
# t is the growth (0..1) at which a star / line is born, so the sky grows as the island is used and ends as your picture:
#   level 0  a sparse skeleton of the subject (t = 0, there from the start)
#   level 1  more stars between them                  (born while growth goes 0.03 .. 0.30)
#   level 2  the features start to read               (0.30 .. 0.65)
#   level 3  fine detail: eyes, brows, hair, outline  (0.65 .. 0.97)
# Where the picture has detail (edges, strong local contrast, differences from the background) stars sit close together,
# flat areas get few: that is what lets eyes, hair and the outline of a face be told apart at full growth.
# Star size follows how important the spot is. Every star is joined to its two nearest neighbours that exist at its time.
# Needs ImageMagick, od, sort and awk. Prints nothing (exit 1) when the picture gives no usable stars.
export LC_ALL=C          # awk must print 12.5, never 12,5
img="${1:-}"
N="${2:-160}"
[ -f "$img" ] || exit 1
IM=magick; command -v magick >/dev/null 2>&1 || IM=convert
command -v "$IM" >/dev/null 2>&1 || exit 2

# 1) grey picture, centre-cropped to N x N, one row of N numbers per line
# 2) per-pixel importance score (stage A), candidates sorted best first
# 3) level-by-level blue-noise sampling + edges + JSON (stage B)
"$IM" "${img}[0]" -background white -alpha remove -alpha off -resize "${N}x${N}^" -gravity center -extent "${N}x${N}" \
      -colorspace Gray -depth 8 gray:- 2>/dev/null \
  | od -An -v -tu1 -w"$N" \
  | awk -v N="$N" '
function abs(x) { return x < 0 ? -x : x }
{
    for (i = 1; i <= N; i++) G[NR - 1, i - 1] = $i / 255
}
END {
    if (NR < N) exit 1
    # background tone = mean of the outer ring
    ring = 0; rc = 0; m = int(N * 0.04) + 1
    for (y = 0; y < N; y++) for (x = 0; x < N; x++)
        if (x < m || y < m || x >= N - m || y >= N - m) { ring += G[y, x]; rc++ }
    bg = ring / rc
    # local mean: separable box blur (radius 7) through two passes
    R = 7
    for (y = 0; y < N; y++) {
        s = 0; c = 0
        for (x = 0; x < R; x++) { s += G[y, x]; c++ }
        for (x = 0; x < N; x++) {
            if (x + R < N) { s += G[y, x + R]; c++ }
            if (x - R - 1 >= 0) { s -= G[y, x - R - 1]; c-- }
            T[y, x] = s / c
        }
    }
    for (x = 0; x < N; x++) {
        s = 0; c = 0
        for (y = 0; y < R; y++) { s += T[y, x]; c++ }
        for (y = 0; y < N; y++) {
            if (y + R < N) { s += T[y + R, x]; c++ }
            if (y - R - 1 >= 0) { s -= T[y - R - 1, x]; c-- }
            LM[y, x] = s / c
        }
    }
    emax = 0.8; cmax = 0.15; dmax = 0.5            # floors: a flat or smooth picture must not be blown up into a busy sky
    for (y = 1; y < N - 1; y++) for (x = 1; x < N - 1; x++) {
        gx = -G[y-1,x-1] - 2*G[y,x-1] - G[y+1,x-1] + G[y-1,x+1] + 2*G[y,x+1] + G[y+1,x+1]
        gy = -G[y-1,x-1] - 2*G[y-1,x] - G[y-1,x+1] + G[y+1,x-1] + 2*G[y+1,x] + G[y+1,x+1]
        E[y, x] = sqrt(gx * gx + gy * gy)
        C[y, x] = abs(G[y, x] - LM[y, x])
        D[y, x] = abs(G[y, x] - bg)
        if (E[y, x] > emax) emax = E[y, x]
        if (C[y, x] > cmax) cmax = C[y, x]
        if (D[y, x] > dmax) dmax = D[y, x]
    }
    for (y = 1; y < N - 1; y++) for (x = 1; x < N - 1; x++) {
        dx = x - N / 2; dy = y - N / 2
        rr = sqrt(dx * dx + dy * dy) / (N / 2)
        mask = (rr < 0.96) ? 1 : (1 - (rr - 0.96) * 12); if (mask < 0) mask = 0
        sc = mask * (0.75 * (E[y, x] / emax) ^ 0.8 + 0.42 * (C[y, x] / cmax) ^ 0.8 + 0.22 * (D[y, x] / dmax) ^ 1.9 + 0.02)
        if (sc > 0.03) printf "%.5f %d %d\n", sc, x, y
    }
}' \
  | sort -gr \
  | awk -v N="$N" '
function sqrt2(x) { return sqrt(x) }
# is (x, y) at least r away from every star placed so far? (grid of 3 px cells)
function free(x, y, r,    cx, cy, a, b, k, j, rc, ddx, ddy) {
    cx = int(x / CELL); cy = int(y / CELL); rc = int(r / CELL) + 1
    for (a = cx - rc; a <= cx + rc; a++) for (b = cy - rc; b <= cy + rc; b++) {
        k = a "," b
        if (k in CNT) for (j = 0; j < CNT[k]; j++) {
            idx = CELLS[k, j]
            ddx = SX[idx] - x; ddy = SY[idx] - y
            if (ddx * ddx + ddy * ddy < r * r) return 0
        }
    }
    return 1
}
function place(x, y, s, r, lvl,    k) {
    SX[ns] = x; SY[ns] = y; SS[ns] = s; SR[ns] = r; SL[ns] = lvl
    k = int(x / CELL) "," int(y / CELL)
    CELLS[k, CNT[k] + 0] = ns; CNT[k]++
    ns++
}
BEGIN {
    CELL = 3; ns = 0
    # sampling radius per level (grid px) and the faintest score each level may use
    NL = 4
    RB[0] = 17.0; RB[1] = 10.5; RB[2] = 6.6; RB[3] = 4.4
    TH[0] = 0.10; TH[1] = 0.08; TH[2] = 0.07; TH[3] = 0.06
    # growth window of each level
    LO[1] = 0.03; HI[1] = 0.30; LO[2] = 0.30; HI[2] = 0.65; LO[3] = 0.65; HI[3] = 0.97
    MAXSTARS = 900
}
NF == 3 { n++; CS[n] = $1; CX[n] = $2; CY[n] = $3; if ($1 > top) top = $1 }
END {
    if (n < 20) exit 1
    for (l = 0; l < NL; l++) {
        lvlStart[l] = ns
        for (i = 1; i <= n && ns < MAXSTARS; i++) {
            if (CS[i] < TH[l]) break                       # sorted: everything after is fainter still
            s = CS[i] / top; if (s > 1) s = 1
            r = RB[l] * (1 - 0.55 * s ^ 0.55)             # important spots: stars may sit close together
            if (free(CX[i], CY[i], r)) place(CX[i], CY[i], s, r, l)
        }
        lvlEnd[l] = ns
    }
    if (ns < 12) exit 1
    # birth time of every star
    for (i = 0; i < ns; i++) {
        l = SL[i]
        if (l == 0) T[i] = 0
        else T[i] = LO[l] + (HI[l] - LO[l]) * (i - lvlStart[l] + 1) / (lvlEnd[l] - lvlStart[l] + 1)
    }
    # every star is joined to its two nearest neighbours that exist no later than itself
    ne = 0
    for (i = 0; i < ns; i++) {
        b1 = -1; b2 = -1; d1 = 1e18; d2 = 1e18
        for (j = 0; j < ns; j++) {
            if (j == i || T[j] > T[i] || (T[j] == T[i] && j > i)) continue
            dx = SX[i] - SX[j]; dy = SY[i] - SY[j]; d = dx * dx + dy * dy
            if (d < d1) { d2 = d1; b2 = b1; d1 = d; b1 = j } else if (d < d2) { d2 = d; b2 = j }
        }
        cap = (SR[i] * 2.1 > 20 ? 20 : SR[i] * 2.1) ^ 2
        if (b1 >= 0 && d1 <= cap) addEdge(i, b1)
        if (b2 >= 0 && d2 <= cap) addEdge(i, b2)
    }
    # print
    printf "{\"w\":%d,\"h\":%d,\"stars\":[", N, N
    for (i = 0; i < ns; i++) {
        sz = 0.45 + 1.25 * SS[i] ^ 0.7; if (sz > 1.8) sz = 1.8
        printf "%s[%.1f,%.1f,%.2f,%.3f]", (i ? "," : ""), SX[i], SY[i], sz, T[i]
    }
    printf "],\"edges\":["
    for (e = 0; e < ne; e++) printf "%s[%d,%d,%.3f]", (e ? "," : ""), EA[e], EB[e], ET[e]
    printf "],\"dust\":[]}\n"
}
function addEdge(a, b,    lo, hi, key, t) {
    lo = a < b ? a : b; hi = a < b ? b : a; key = lo "-" hi
    if (key in SEEN) return
    SEEN[key] = 1
    t = (T[a] > T[b] ? T[a] : T[b])
    if (t > 0) t += 0.012                                   # a line shows up a hair after its second star
    EA[ne] = lo; EB[ne] = hi; ET[ne] = t; ne++
}'
