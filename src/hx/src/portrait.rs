//! `hx portrait <image> [grid] [max-stars]`: the profile picture as a high-detail, growing constellation.
//! Same algorithm and same JSON as scripts/portrait.sh (which does it in awk and needs minutes), done in milliseconds:
//!   { "w":N, "h":N, "stars":[[x,y,size,t],...], "edges":[[a,b,t],...], "dust":[] }
//! t is the growth (0..1) at which a star / line is born. Exit code 1 = the picture gives no usable stars,
//! 2 is left for "unknown command" (an older hx), so the caller can tell the two apart.
use std::cmp::Ordering;
use std::process::Command;

fn gray(path: &str, n: usize) -> Vec<f64> {
    for exe in ["magick", "convert"] {
        if let Ok(o) = Command::new(exe)
            .args([&format!("{}[0]", path), "-background", "white", "-alpha", "remove", "-alpha", "off",
                   "-resize", &format!("{n}x{n}^", n = n), "-gravity", "center", "-extent", &format!("{n}x{n}", n = n),
                   "-colorspace", "Gray", "-depth", "8", "gray:-"])
            .output()
        {
            if o.status.success() && o.stdout.len() >= n * n {
                return o.stdout[..n * n].iter().map(|b| *b as f64 / 255.0).collect();
            }
        }
    }
    Vec::new()
}

// separable box blur, radius r, same window as the awk version (x-r .. x+r, clipped at the edges)
fn box_blur(src: &[f64], n: usize, r: usize) -> Vec<f64> {
    let mut t = vec![0.0; n * n];
    for y in 0..n {
        let (mut s, mut c) = (0.0, 0i32);
        for x in 0..r.min(n) { s += src[y * n + x]; c += 1; }
        for x in 0..n {
            if x + r < n { s += src[y * n + x + r]; c += 1; }
            if x >= r + 1 { s -= src[y * n + x - r - 1]; c -= 1; }
            t[y * n + x] = s / c as f64;
        }
    }
    let mut o = vec![0.0; n * n];
    for x in 0..n {
        let (mut s, mut c) = (0.0, 0i32);
        for y in 0..r.min(n) { s += t[y * n + x]; c += 1; }
        for y in 0..n {
            if y + r < n { s += t[(y + r) * n + x]; c += 1; }
            if y >= r + 1 { s -= t[(y - r - 1) * n + x]; c -= 1; }
            o[y * n + x] = s / c as f64;
        }
    }
    o
}

pub fn run(path: &str, n: usize, max_stars: usize) -> i32 {
    let n = n.clamp(48, 256);
    let g = gray(path, n);
    if g.is_empty() { return 1; }
    let nf = n as f64;

    // background tone = mean of the outer ring
    let m = (nf * 0.04) as usize + 1;
    let (mut ring, mut rc) = (0.0, 0usize);
    for y in 0..n { for x in 0..n {
        if x < m || y < m || x >= n - m || y >= n - m { ring += g[y * n + x]; rc += 1; }
    } }
    let bg = ring / rc as f64;
    let lm = box_blur(&g, n, 7);

    // stage A: per-pixel importance
    let mut e = vec![0.0f64; n * n];
    let mut c = vec![0.0f64; n * n];
    let mut d = vec![0.0f64; n * n];
    let (mut emax, mut cmax, mut dmax) = (0.8f64, 0.15f64, 0.5f64);
    let at = |x: usize, y: usize| g[y * n + x];
    for y in 1..n - 1 { for x in 1..n - 1 {
        let gx = -at(x - 1, y - 1) - 2.0 * at(x - 1, y) - at(x - 1, y + 1) + at(x + 1, y - 1) + 2.0 * at(x + 1, y) + at(x + 1, y + 1);
        let gy = -at(x - 1, y - 1) - 2.0 * at(x, y - 1) - at(x + 1, y - 1) + at(x - 1, y + 1) + 2.0 * at(x, y + 1) + at(x + 1, y + 1);
        let i = y * n + x;
        e[i] = (gx * gx + gy * gy).sqrt();
        c[i] = (g[i] - lm[i]).abs();
        d[i] = (g[i] - bg).abs();
        emax = emax.max(e[i]); cmax = cmax.max(c[i]); dmax = dmax.max(d[i]);
    } }
    // candidates: (score as printed with 5 decimals, x, y, text key). Sorted like `sort -gr`: score descending, then the
    // whole line descending, so the order (and therefore the picture) is the same as the awk version.
    let mut cand: Vec<(f64, String, usize, usize)> = Vec::new();
    for y in 1..n - 1 { for x in 1..n - 1 {
        let (dx, dy) = (x as f64 - nf / 2.0, y as f64 - nf / 2.0);
        let rr = (dx * dx + dy * dy).sqrt() / (nf / 2.0);
        let mut mask = if rr < 0.96 { 1.0 } else { 1.0 - (rr - 0.96) * 12.0 };
        if mask < 0.0 { mask = 0.0; }
        let i = y * n + x;
        let sc = mask * (0.75 * (e[i] / emax).powf(0.8) + 0.42 * (c[i] / cmax).powf(0.8) + 0.22 * (d[i] / dmax).powf(1.9) + 0.02);
        if sc > 0.03 {
            let key = format!("{:.5} {} {}", sc, x, y);
            let rounded: f64 = format!("{:.5}", sc).parse().unwrap_or(sc);
            cand.push((rounded, key, x, y));
        }
    } }
    cand.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(Ordering::Equal).then_with(|| b.1.cmp(&a.1)));
    if cand.len() < 20 { return 1; }
    let top = cand[0].0;

    // stage B: level-by-level blue-noise sampling
    const CELL: usize = 3;
    let gw = n / CELL + 2;
    let mut cells: Vec<Vec<usize>> = vec![Vec::new(); gw * gw];
    let (mut sx, mut sy, mut ss, mut sr, mut sl): (Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>, Vec<usize>) = (vec![], vec![], vec![], vec![], vec![]);
    let rb = [17.0, 10.5, 6.6, 4.4];
    let th = [0.10, 0.08, 0.07, 0.06];
    let (lo, hi) = ([0.0, 0.03, 0.30, 0.65], [0.0, 0.30, 0.65, 0.97]);
    let mut lvl_start = [0usize; 4];
    let mut lvl_end = [0usize; 4];
    let free = |x: f64, y: f64, r: f64, cells: &Vec<Vec<usize>>, sx: &Vec<f64>, sy: &Vec<f64>| -> bool {
        let (cx, cy) = ((x / CELL as f64) as i64, (y / CELL as f64) as i64);
        let rc = (r / CELL as f64) as i64 + 1;
        for a in cx - rc..=cx + rc {
            for b in cy - rc..=cy + rc {
                if a < 0 || b < 0 || a as usize >= gw || b as usize >= gw { continue; }
                for &idx in &cells[b as usize * gw + a as usize] {
                    let (ddx, ddy) = (sx[idx] - x, sy[idx] - y);
                    if ddx * ddx + ddy * ddy < r * r { return false; }
                }
            }
        }
        true
    };
    for l in 0..4 {
        lvl_start[l] = sx.len();
        for cd in &cand {
            if sx.len() >= max_stars { break; }
            if cd.0 < th[l] { break; }
            let s = (cd.0 / top).min(1.0);
            let r = rb[l] * (1.0 - 0.55 * s.powf(0.55));
            let (x, y) = (cd.2 as f64, cd.3 as f64);
            if free(x, y, r, &cells, &sx, &sy) {
                let k = (cd.3 / CELL) * gw + cd.2 / CELL;
                cells[k].push(sx.len());
                sx.push(x); sy.push(y); ss.push(s); sr.push(r); sl.push(l);
            }
        }
        lvl_end[l] = sx.len();
    }
    let ns = sx.len();
    if ns < 12 { return 1; }

    // birth time of every star
    let mut t = vec![0.0f64; ns];
    for i in 0..ns {
        let l = sl[i];
        if l > 0 {
            t[i] = lo[l] + (hi[l] - lo[l]) * (i - lvl_start[l] + 1) as f64 / (lvl_end[l] - lvl_start[l] + 1) as f64;
        }
    }
    // every star is joined to its two nearest neighbours that exist no later than itself
    let mut edges: Vec<(usize, usize, f64)> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut add = |a: usize, b: usize, edges: &mut Vec<(usize, usize, f64)>| {
        let (lo_i, hi_i) = if a < b { (a, b) } else { (b, a) };
        if !seen.insert((lo_i, hi_i)) { return; }
        let mut tt = t[a].max(t[b]);
        if tt > 0.0 { tt += 0.012; }
        edges.push((lo_i, hi_i, tt));
    };
    for i in 0..ns {
        let (mut b1, mut b2): (Option<usize>, Option<usize>) = (None, None);
        let (mut d1, mut d2) = (1e18f64, 1e18f64);
        for j in 0..ns {
            if j == i || t[j] > t[i] || (t[j] == t[i] && j > i) { continue; }
            let (dx, dy) = (sx[i] - sx[j], sy[i] - sy[j]);
            let dd = dx * dx + dy * dy;
            if dd < d1 { d2 = d1; b2 = b1; d1 = dd; b1 = Some(j); }
            else if dd < d2 { d2 = dd; b2 = Some(j); }
        }
        let cap = (sr[i] * 2.1).min(20.0).powi(2);
        if let Some(j) = b1 { if d1 <= cap { add(i, j, &mut edges); } }
        if let Some(j) = b2 { if d2 <= cap { add(i, j, &mut edges); } }
    }

    // print (same number formats as the awk version)
    let mut out = String::with_capacity(ns * 28 + edges.len() * 20 + 64);
    out.push_str(&format!("{{\"w\":{},\"h\":{},\"stars\":[", n, n));
    for i in 0..ns {
        let sz = (0.45 + 1.25 * ss[i].powf(0.7)).min(1.8);
        if i > 0 { out.push(','); }
        out.push_str(&format!("[{:.1},{:.1},{:.2},{:.3}]", sx[i], sy[i], sz, t[i]));
    }
    out.push_str("],\"edges\":[");
    for (k, (a, b, tt)) in edges.iter().enumerate() {
        if k > 0 { out.push(','); }
        out.push_str(&format!("[{},{},{:.3}]", a, b, tt));
    }
    out.push_str("],\"dust\":[]}");
    println!("{}", out);
    0
}
