.pragma library
// Constellation layouts for the flagship sysmodes (generated). stars: [x, y, size], edges: [a, b] indexes.
var dragon = {"w": 320, "h": 240, "stars": [[14.0, 202.0, 2.2], [45.0, 207.2, 1.6], [70.8, 194.4, 1.6], [94.1, 174.3, 2.2], [117.4, 157.5, 1.6], [143.7, 154.5, 1.6], [165.1, 148.0, 2.2], [176.7, 129.5, 1.6], [185.4, 106.9, 1.6], [198.4, 88.4, 2.2], [219.5, 81.3, 1.6], [235.5, 76.9, 1.6], [248.4, 71.6, 2.2], [258.3, 67.8, 1.6], [41.5, 189.8, 1.2], [79.8, 158.2, 1.2], [145.6, 132.0, 1.2], [156.4, 121.1, 1.2], [185.8, 72.6, 1.2], [229.6, 60.3, 1.2], [262.1, 67.0, 2.2], [273.9, 55.5, 2.0], [290.5, 72.3, 2.0], [301.6, 106.8, 2.0], [298.4, 112.4, 2.0], [281.9, 106.1, 2.0], [259.2, 82.9, 2.0], [283.8, 31.3, 1.6], [300.8, 40.8, 1.6], [283.0, 84.4, 3.0], [297.4, 144.6, 1.2], [295.0, 146.2, 1.2]], "edges": [[0, 1], [1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 10], [10, 11], [11, 12], [12, 13], [1, 14], [3, 15], [5, 16], [7, 17], [9, 18], [11, 19], [13, 20], [20, 21], [21, 22], [22, 23], [23, 24], [24, 25], [25, 26], [26, 21], [21, 27], [22, 28], [22, 29], [29, 23], [24, 30], [24, 31]], "dust": [[197.5, 203.9, 0.8], [242.7, 66.2, 0.8], [100.0, 199.1, 0.8], [11.6, 188.4, 0.8], [249.1, 115.9, 0.8], [100.9, 77.1, 0.8], [86.5, 111.2, 0.8], [161.4, 133.5, 0.8], [308.7, 182.5, 0.8], [196.7, 222.7, 0.8], [74.6, 52.8, 0.8], [193.8, 29.0, 0.8], [20.7, 125.6, 0.8], [149.9, 208.0, 0.8], [198.8, 125.4, 0.8], [159.1, 70.7, 0.8], [13.5, 59.4, 0.8], [217.6, 61.1, 0.8], [120.9, 20.8, 0.8], [259.0, 51.7, 0.8], [90.3, 200.5, 0.8], [162.9, 193.7, 0.8]]};
var shield = {"w": 200, "h": 250, "stars": [[100.0, 10.0, 2.6], [150.0, 32.0, 1.6], [188.0, 28.0, 2.2], [188.0, 78.0, 1.6], [186.0, 128.0, 2.0], [170.0, 176.0, 1.6], [140.0, 212.0, 1.8], [100.0, 242.0, 2.8], [60.0, 212.0, 1.8], [30.0, 176.0, 1.6], [14.0, 128.0, 2.0], [12.0, 78.0, 1.6], [12.0, 28.0, 2.2], [50.0, 32.0, 1.6], [100.0, 60.0, 1.4], [100.0, 104.0, 2.4], [100.0, 160.0, 1.6], [40.0, 92.0, 1.4], [70.0, 100.0, 1.4], [130.0, 100.0, 1.4], [160.0, 92.0, 1.4]], "edges": [[0, 1], [1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 10], [10, 11], [11, 12], [12, 13], [13, 0], [0, 14], [14, 15], [15, 16], [16, 7], [17, 18], [18, 15], [15, 19], [19, 20], [17, 11], [20, 3]], "dust": [[127.9, 185.4, 0.8], [18.3, 135.3, 0.8], [101.6, 217.8, 0.8], [72.3, 149.5, 0.8], [11.9, 96.9, 0.8], [64.6, 37.5, 0.8], [163.3, 94.9, 0.8], [195.7, 147.5, 0.8], [121.0, 159.5, 0.8], [135.3, 37.7, 0.8], [88.1, 59.9, 0.8], [80.5, 24.2, 0.8], [193.6, 53.8, 0.8], [134.4, 75.1, 0.8], [174.8, 165.6, 0.8], [26.3, 211.3, 0.8]]};

// ===== growth =====================================================================================================
// A star is [x, y, size] and may carry  [.., t, ax, ay]:  t = growth (0..1) at which it is born, (ax, ay) = where it
// starts (it travels from there to x, y while it grows, so a wing really unfolds). An edge is [a, b] or [a, b, t].
// Everything without t is there from the start. ModeArt.qml reads these; growth = pal.growth.

// ---- dragon: two wings unfold from the shoulders (near wing first, the far one later)
(function () {
    var s = dragon.stars, e = dragon.edges
    function st(x, y, size, t, ax, ay) { s.push([x, y, size, t, ax, ay]); return s.length - 1 }
    function ed(a, b, t) { e.push([a, b, t]) }
    var sh = s[8], sh2 = s[9]                       // shoulder points on the body
    // near wing: arm, wrist, four fingers, trailing edge back to the hip
    var a0 = st(174, 90, 1.4, 0.05, sh[0], sh[1])
    var a1 = st(160, 68, 1.6, 0.12, sh[0], sh[1])
    var wr = st(140, 46, 2.4, 0.20, sh[0], sh[1])   // wrist: the bright one
    var f1 = st(96, 22, 1.8, 0.34, 140, 46)
    var f2 = st(86, 52, 1.6, 0.44, 140, 46)
    var f3 = st(98, 84, 1.6, 0.54, 140, 46)
    var f4 = st(124, 106, 1.6, 0.64, 140, 46)
    ed(8, a0, 0.05); ed(a0, a1, 0.12); ed(a1, wr, 0.20)
    ed(wr, f1, 0.34); ed(wr, f2, 0.44); ed(wr, f3, 0.54); ed(wr, f4, 0.64)
    ed(f1, f2, 0.44); ed(f2, f3, 0.54); ed(f3, f4, 0.64); ed(f4, 7, 0.70)
    // far wing (smaller, behind): from the upper back
    var b0 = st(206, 66, 1.3, 0.50, sh2[0], sh2[1])
    var b1 = st(202, 44, 2.0, 0.58, sh2[0], sh2[1])
    var g1 = st(168, 16, 1.5, 0.70, 202, 44)
    var g2 = st(192, 8, 1.4, 0.78, 202, 44)
    var g3 = st(218, 22, 1.5, 0.86, 202, 44)
    ed(9, b0, 0.50); ed(b0, b1, 0.58)
    ed(b1, g1, 0.70); ed(b1, g2, 0.78); ed(b1, g3, 0.86)
    ed(g1, g2, 0.78); ed(g2, g3, 0.86); ed(g3, 11, 0.92)
    // a last bit of life: glints along the wing edges at full growth
    st(110, 36, 1.0, 0.92, 140, 46); st(92, 70, 1.0, 0.94, 140, 46); st(112, 96, 1.0, 0.96, 124, 106)
    st(182, 14, 1.0, 0.95, 202, 44); st(206, 12, 1.0, 0.97, 202, 44)
})();

// ---- shield: a second rim, a crest around the centre, rays, and finally a crown star
(function () {
    var s = shield.stars, e = shield.edges
    function st(x, y, size, t, ax, ay) { s.push([x, y, size, t, ax, ay]); return s.length - 1 }
    function ed(a, b, t) { e.push([a, b, t]) }
    var cx = 100, cy = 126, k = 0.80
    // 1) inner rim, growing inwards from the outer rim (outline = stars 0..13)
    var rim = []
    for (var i = 0; i < 14; i++) {
        var p = s[i]
        rim.push(st(cx + (p[0] - cx) * k, cy + (p[1] - cy) * k, 1.3, 0.06 + i * 0.016, p[0], p[1]))
    }
    for (var j = 0; j < 14; j++) {
        ed(rim[j], rim[(j + 1) % 14], 0.06 + Math.max(j, (j + 1) % 14) * 0.016 + (j === 13 ? 0 : 0))
        ed(j, rim[j], 0.06 + j * 0.016)
    }
    // 2) a hexagon crest around the centre star (15), blooming outwards
    var hex = []
    for (var h = 0; h < 6; h++) {
        var a = -Math.PI / 2 + h * Math.PI / 3
        hex.push(st(100 + Math.cos(a) * 22, 104 + Math.sin(a) * 22, 1.6, 0.36 + h * 0.04, 100, 104))
    }
    for (var m = 0; m < 6; m++) { ed(hex[m], hex[(m + 1) % 6], 0.36 + ((m + 1) % 6) * 0.04 + 0.01); ed(15, hex[m], 0.36 + m * 0.04) }
    // 3) four rays from the crest out to the inner rim
    var r1 = st(62, 66, 1.4, 0.64, 100, 104), r2 = st(138, 66, 1.4, 0.69, 100, 104)
    var r3 = st(62, 142, 1.4, 0.74, 100, 104), r4 = st(138, 142, 1.4, 0.79, 100, 104)
    ed(hex[5], r1, 0.64); ed(hex[1], r2, 0.69); ed(hex[4], r3, 0.74); ed(hex[2], r4, 0.79)
    // 4) crown: a bright star above the crest that joins the top of the shield
    var cr = st(100, 38, 3.0, 0.88, 100, 104)
    ed(cr, 14, 0.88); ed(cr, hex[0], 0.90)
    // 5) sparkles inside the rim
    st(76, 188, 1.0, 0.92, 100, 160); st(124, 188, 1.0, 0.94, 100, 160)
    st(48, 128, 1.0, 0.96, 100, 126); st(152, 128, 1.0, 0.98, 100, 126)
})();

// ---- the picture constellation grows in levels: every level adds stars in the gaps of the last one, so the sky
// gets closer to the picture itself. `lines` = the output of `hx stars <img> N` for N = 70, 110, 160, 220 (JSON each).
function fromLevels(lines) {
    var counts = [70, 110, 160, 220]
    var pts = [], ends = []
    for (var l = 0; l < lines.length; l++) {
        var d
        try { d = JSON.parse(lines[l]) } catch (err) { continue }
        if (!d || !d.stars) continue
        var mind = Math.sqrt(96 * 96 / counts[Math.min(l, counts.length - 1)]) * 0.62
        for (var i = 0; i < d.stars.length; i++) {
            var p = d.stars[i], ok = true
            for (var j = 0; j < pts.length; j++) {
                var dx = pts[j][0] - p[0], dy = pts[j][1] - p[1]
                if (dx * dx + dy * dy < mind * mind) { ok = false; break }
            }
            if (ok) pts.push([p[0], p[1], p[2]])
        }
        ends.push(pts.length)
    }
    if (pts.length < 8) return null
    return nested(pts, ends, 26 * 26)
}

// stars come in levels (pts[0..ends[0]) first, then the next block ...): the first level is always there, later ones are
// born one by one as growth goes from 0 to 1. Edges: every star is joined to its two nearest neighbours among the
// stars of its level and the earlier ones.
function nested(pts, ends, maxd2) {
    var n0 = ends[0], total = pts.length, stars = []
    for (var i = 0; i < total; i++) {
        var t = i < n0 ? 0 : 0.03 + 0.94 * (i - n0 + 1) / Math.max(1, total - n0)
        stars.push([pts[i][0], pts[i][1], pts[i][2], t])
    }
    var edges = [], seen = {}
    for (var l = 0; l < ends.length; l++) {
        var end = ends[l]
        for (var p = 0; p < end; p++) {
            var near = []
            for (var q = 0; q < end; q++) {
                if (q === p) continue
                var ex = pts[p][0] - pts[q][0], ey = pts[p][1] - pts[q][1]
                near.push([ex * ex + ey * ey, q])
            }
            near.sort(function (m, k) { return m[0] - k[0] })
            for (var k2 = 0; k2 < 2 && k2 < near.length; k2++) {
                if (near[k2][0] > maxd2) continue
                var lo = Math.min(p, near[k2][1]), hi = Math.max(p, near[k2][1])
                if (seen[lo + "-" + hi]) continue
                seen[lo + "-" + hi] = true
                // appears a hair after its second star, so a line never reaches a star that has not shown yet
                edges.push([lo, hi, Math.max(stars[lo][3], stars[hi][3]) + (l === 0 ? 0 : 0.012)])
            }
        }
    }
    return { w: 96, h: 96, stars: stars, edges: edges, dust: [] }
}

// `scripts/portrait.sh <image>` prints one JSON line: a high-detail constellation whose stars and lines carry their own
// birth time t (see ModeArt.qml), so it grows with use and ends as the picture. null = not usable (too few stars).
function fromPortrait(line) {
    var d
    try { d = JSON.parse(line) } catch (err) { return null }
    if (!d || !d.stars || d.stars.length < 12 || !d.edges) return null
    if (!d.dust) d.dust = []
    return d
}

// A constellation made from a name, for when there is no profile picture (or it gives no stars): the same name always
// gives the same sky. Same shape as `hx stars` prints (96 x 96 grid, every star joined to its two nearest neighbours).
function fromName(name) {
    var str = String(name || "halcyon")
    var seed = 2166136261
    for (var i = 0; i < str.length; i++) seed = Math.imul(seed ^ str.charCodeAt(i), 16777619) >>> 0
    function rnd() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296 }
    // four levels (46 -> 80 -> 120 -> 170 stars), each packed a little tighter, so it grows like the picture one
    var pts = [], ends = [], tries = 0
    var plan = [[46, 9], [80, 7], [120, 5.8], [170, 4.8]]
    for (var lv = 0; lv < plan.length; lv++) {
        tries = 0
        var mind2 = plan[lv][1] * plan[lv][1]
        while (pts.length < plan[lv][0] && tries < 6000) {
            tries++
            var a = rnd() * 6.283185, r = Math.sqrt(rnd()) * 44
            var x = 48 + Math.cos(a) * r, y = 48 + Math.sin(a) * r
            var ok = true
            for (var j = 0; j < pts.length; j++) {
                var dx = pts[j][0] - x, dy = pts[j][1] - y
                if (dx * dx + dy * dy < mind2) { ok = false; break }
            }
            if (ok) pts.push([x, y, 0.9 + rnd() * 1.8])
        }
        ends.push(pts.length)
    }
    return nested(pts, ends, 26 * 26)
}

