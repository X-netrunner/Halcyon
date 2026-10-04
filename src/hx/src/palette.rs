//! Wallpaper -> dark palette (port of palette.py). Writes ~/.cache/island/palette.json as one line.
//! Needs ImageMagick (magick or convert) to decode a 64x64 thumbnail.
use crate::util::home;
use serde_json::json;
use std::process::Command;

fn pixels(path: &str) -> Vec<u8> {
    for exe in ["magick", "convert"] {
        if let Ok(o) = Command::new(exe)
            .args([&format!("{}[0]", path), "-resize", "64x64!", "-depth", "8", "rgb:-"])
            .output()
        {
            if o.status.success() && o.stdout.len() >= 3 {
                return o.stdout;
            }
        }
    }
    Vec::new()
}

fn rgb_to_hsv(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let mx = r.max(g).max(b);
    let mn = r.min(g).min(b);
    let v = mx;
    if mn == mx { return (0.0, 0.0, v); }
    let d = mx - mn;
    let s = d / mx;
    let (rc, gc, bc) = ((mx - r) / d, (mx - g) / d, (mx - b) / d);
    let h = if r == mx { bc - gc } else if g == mx { 2.0 + rc - bc } else { 4.0 + gc - rc };
    ((h / 6.0).rem_euclid(1.0), s, v)
}

fn hls_to_rgb(h: f64, l: f64, s: f64) -> (f64, f64, f64) {
    if s == 0.0 { return (l, l, l); }
    let m2 = if l <= 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let m1 = 2.0 * l - m2;
    let v = |mut hue: f64| {
        hue = hue.rem_euclid(1.0);
        if hue < 1.0 / 6.0 { m1 + (m2 - m1) * hue * 6.0 }
        else if hue < 0.5 { m2 }
        else if hue < 2.0 / 3.0 { m1 + (m2 - m1) * (2.0 / 3.0 - hue) * 6.0 }
        else { m1 }
    };
    (v(h + 1.0 / 3.0), v(h), v(h - 1.0 / 3.0))
}

fn hsl(h: f64, s: f64, l: f64) -> String {
    let (r, g, b) = hls_to_rgb(h.rem_euclid(1.0), l.clamp(0.0, 1.0), s.clamp(0.0, 1.0));
    format!("#{:02x}{:02x}{:02x}", (r * 255.0).round() as u8, (g * 255.0).round() as u8, (b * 255.0).round() as u8)
}

pub fn palette(image: Option<&str>) {
    const BINS: usize = 24;
    let data = image.map(pixels).unwrap_or_default();
    let (mut w, mut hs, mut ss) = ([0.0f64; BINS], [0.0f64; BINS], [0.0f64; BINS]);
    for px in data.chunks_exact(3) {
        let (h, s, v) = rgb_to_hsv(px[0] as f64 / 255.0, px[1] as f64 / 255.0, px[2] as f64 / 255.0);
        if s < 0.18 || v < 0.2 { continue; }
        let wt = s * (0.3 + v);
        let k = (h * BINS as f64) as usize % BINS;
        w[k] += wt; hs[k] += h * wt; ss[k] += s * wt;
    }
    let smooth: Vec<f64> = (0..BINS).map(|k| w[k] + 0.5 * (w[(k + BINS - 1) % BINS] + w[(k + 1) % BINS])).collect();
    let top = (0..BINS).fold(0, |b, k| if smooth[k] > smooth[b] { k } else { b });

    let (h1, mut sat) = if w[top] < 1e-6 { (0.62, 0.35) } else { (hs[top] / w[top], (ss[top] / w[top]).clamp(0.35, 0.8)) };
    let mut h2 = h1 + 0.08;
    let mut best = 0.0;
    for k in 0..BINS {
        let d = ((k + BINS - top) % BINS).min((top + BINS - k) % BINS);
        if d >= 3 && w[k] > 0.3 * w[top] && w[k] > best { best = w[k]; h2 = hs[k] / w[k]; }
    }
    // calm by design: low-saturation surfaces, pastel accent, soft-white text
    sat = sat.min(0.55);
    let pal = json!({
        "bg": hsl(h1, 0.26, 0.095), "surface": hsl(h1, 0.22, 0.155), "surfaceHi": hsl(h1, 0.22, 0.205),
        "accent": hsl(h1, sat * 0.85, 0.74), "accent2": hsl(h2, sat * 0.80, 0.74),
        "text": hsl(h1, 0.20, 0.89), "muted": hsl(h1, 0.10, 0.64),
    });
    let out = format!("{}/.cache/island/palette.json", home());
    let _ = std::fs::create_dir_all(format!("{}/.cache/island", home()));
    // in-place write (no rename) so `tail -F` sees it
    let _ = std::fs::write(out, format!("{}\n", pal));
}
