//! `hx stars <image> [count]`: turn a picture (the profile avatar) into a constellation.
//! Prints { w, h, stars:[[x,y,size]], edges:[[a,b]], dust:[] } for ModeArt.qml.
//! Method: decode a 96x96 centre crop (ImageMagick, like `hx palette`), score every pixel by edge strength plus how far
//! its brightness is from the picture's average, then pick stars greedily from the best scores while keeping them a
//! minimum distance apart (so the picture's outline and bright features get stars, flat areas stay dark).
//! Each star is joined to its two nearest neighbours.
use std::process::Command;

const N: usize = 96;

fn gray(path: &str) -> Vec<f64> {
    for exe in ["magick", "convert"] {
        if let Ok(o) = Command::new(exe)
            .args([&format!("{}[0]", path), "-resize", &format!("{n}x{n}^", n = N), "-gravity", "center", "-extent", &format!("{n}x{n}", n = N),
                   "-colorspace", "Gray", "-depth", "8", "gray:-"])
            .output()
        {
            if o.status.success() && o.stdout.len() >= N * N {
                return o.stdout[..N * N].iter().map(|b| *b as f64 / 255.0).collect();
            }
        }
    }
    Vec::new()
}

pub fn run(path: &str, count: usize) {
    let g = gray(path);
    if g.is_empty() {
        println!("{{\"w\":{n},\"h\":{n},\"stars\":[],\"edges\":[],\"dust\":[]}}", n = N);
        return;
    }
    let mean = g.iter().sum::<f64>() / g.len() as f64;
    let at = |x: usize, y: usize| g[y * N + x];
    // score = Sobel edge strength + brightness deviation, limited to a soft circle so the frame corners stay empty
    let mut score = vec![0.0f64; N * N];
    for y in 1..N - 1 {
        for x in 1..N - 1 {
            let gx = -at(x - 1, y - 1) - 2.0 * at(x - 1, y) - at(x - 1, y + 1) + at(x + 1, y - 1) + 2.0 * at(x + 1, y) + at(x + 1, y + 1);
            let gy = -at(x - 1, y - 1) - 2.0 * at(x, y - 1) - at(x + 1, y - 1) + at(x - 1, y + 1) + 2.0 * at(x, y + 1) + at(x + 1, y + 1);
            let edge = (gx * gx + gy * gy).sqrt();
            let dev = (at(x, y) - mean).abs();
            let (dx, dy) = (x as f64 - N as f64 / 2.0, y as f64 - N as f64 / 2.0);
            let r = (dx * dx + dy * dy).sqrt() / (N as f64 / 2.0);
            let mask = if r < 0.95 { 1.0 } else { (1.0 - (r - 0.95) * 10.0).max(0.0) };
            score[y * N + x] = (edge * 0.7 + dev * 0.6) * mask;
        }
    }
    let mut order: Vec<usize> = (0..N * N).collect();
    order.sort_by(|a, b| score[*b].partial_cmp(&score[*a]).unwrap_or(std::cmp::Ordering::Equal));
    let min_d2 = {
        let d = (N as f64 * N as f64 / count.max(1) as f64).sqrt() * 0.62;
        d * d
    };
    let mut pts: Vec<(f64, f64, f64)> = Vec::new();
    for i in order {
        if pts.len() >= count || score[i] < 0.02 {
            break;
        }
        let (x, y) = ((i % N) as f64, (i / N) as f64);
        if pts.iter().all(|(px, py, _)| (px - x).powi(2) + (py - y).powi(2) >= min_d2) {
            pts.push((x, y, score[i]));
        }
    }
    let top = pts.iter().map(|p| p.2).fold(0.0001, f64::max);
    let mut edges: Vec<(usize, usize)> = Vec::new();
    let maxd2 = (N as f64 * 0.28).powi(2);
    for (i, p) in pts.iter().enumerate() {
        let mut near: Vec<(f64, usize)> = pts
            .iter()
            .enumerate()
            .filter(|(j, _)| *j != i)
            .map(|(j, q)| ((p.0 - q.0).powi(2) + (p.1 - q.1).powi(2), j))
            .collect();
        near.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        for (d2, j) in near.into_iter().take(2) {
            let e = if i < j { (i, j) } else { (j, i) };
            if d2 <= maxd2 && !edges.contains(&e) {
                edges.push(e);
            }
        }
    }
    let stars: Vec<serde_json::Value> = pts
        .iter()
        .map(|(x, y, s)| serde_json::json!([*x, *y, (0.9 + 1.9 * (s / top)).min(2.8)]))
        .collect();
    let e: Vec<serde_json::Value> = edges.iter().map(|(a, b)| serde_json::json!([a, b])).collect();
    println!("{}", serde_json::json!({ "w": N, "h": N, "stars": stars, "edges": e, "dust": [] }));
}
