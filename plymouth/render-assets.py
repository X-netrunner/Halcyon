#!/usr/bin/env python3
# Renders the pictures for the Halcyon Plymouth theme (plymouth/halcyon.script), the boot version of quickshell/island/Splash.qml.
# Plymouth's script plugin cannot draw curves, gradients or lines, so everything the QML splash paints live is drawn here once:
#
#   mark-0 .. mark-N.png   the sparkle unfolding (main star, hot core, flare lines, the two companions), one picture per step
#   halo.png               the soft glow behind it (its opacity pulses in the script)
#   tint.png               the faint accent wash in the middle of the screen (small; the script stretches it to the screen)
#   word-0 .. word-N.png   HALCYON, its letter spacing closing from 1.4x to 1x (each one exactly centred: no trailing spacing)
#   star-I-L.png           star I's streak at length L (0 short .. 2 long), already pointing the way it flies
#   dot.png                a password bullet (encrypted disks)
#   layout.script          the numbers the script needs (sizes, colours, the stars), glued in front of halcyon.script
#
#   render-assets.py OUTDIR WIDTH HEIGHT ACCENT ACCENT2 BG TEXT [DIM]     colours as rrggbb
# Needs python-pillow (the word and the stars) and rsvg-convert from librsvg (the mark).
import math, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

out, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
hexes = sys.argv[4:8]
dim = float(sys.argv[8]) if len(sys.argv) > 8 else 0.75
os.makedirs(out, exist_ok=True)

def rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
a1, a2, bg, tx = (rgb(h) for h in hexes)
lum = lambda c: (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255
# the screen under the splash is the theme background under the same dark veil as the desktop splash
stage = tuple(round(v * (1 - dim)) for v in bg)
# on that dark stage a light theme's dark text would vanish: soft white then (the same rule as Splash.qml's `ink`)
ink = tx if lum(tx) > 0.5 else (242, 242, 250)

def eo(x): return 1 - (1 - x) ** 3
def seg(p, a, b): return max(0.0, min(1.0, (p - a) / (b - a)))
def hx(c): return "#%02x%02x%02x" % c

S = min(W, H)
R = S * 0.13                                     # the mark's radius, as in Splash.qml
MS = int(R * 5.2) // 2 * 2                       # the mark's canvas
NMARK, NWORD = 48, 12
P0, P1 = 0.10, 0.76                              # the mark frames cover p = P0 .. P1 (before that it is not there, after it is whole)

def svg_png(svg, path):
    subprocess.run(["rsvg-convert", "-o", path], input=svg.encode(), check=True)

def star_path(rv, rh, k):
    c = min(rv, rh) * k
    return (f"M0,{-rv:.2f} Q{c:.2f},{-c:.2f} {rh:.2f},0 Q{c:.2f},{c:.2f} 0,{rv:.2f} "
            f"Q{-c:.2f},{c:.2f} {-rh:.2f},0 Q{-c:.2f},{-c:.2f} 0,{-rv:.2f} Z")

def mark_svg(p):
    g, flare = eo(seg(p, 0.10, 0.50)), eo(seg(p, 0.40, 0.68))
    s1, s2 = eo(seg(p, 0.46, 0.68)), eo(seg(p, 0.54, 0.76))
    defs, body = [], []
    fl = R * 2.3 * flare
    if fl > 1:
        vl = fl * 0.55
        defs.append(f'<linearGradient id="lh" x1="{-fl}" y1="0" x2="{fl}" y2="0" gradientUnits="userSpaceOnUse">'
                    f'<stop offset="0" stop-color="{hx(a1)}" stop-opacity="0"/><stop offset="0.5" stop-color="{hx(ink)}" stop-opacity="{0.55 * flare:.3f}"/>'
                    f'<stop offset="1" stop-color="{hx(a1)}" stop-opacity="0"/></linearGradient>'
                    f'<linearGradient id="lv" x1="0" y1="{-vl}" x2="0" y2="{vl}" gradientUnits="userSpaceOnUse">'
                    f'<stop offset="0" stop-color="{hx(a2)}" stop-opacity="0"/><stop offset="0.5" stop-color="{hx(ink)}" stop-opacity="{0.35 * flare:.3f}"/>'
                    f'<stop offset="1" stop-color="{hx(a2)}" stop-opacity="0"/></linearGradient>')
        body.append(f'<rect x="{-fl}" y="-0.9" width="{2 * fl}" height="1.8" fill="url(#lh)"/>'
                    f'<rect x="-0.8" y="{-vl}" width="1.6" height="{2 * vl}" fill="url(#lv)"/>')
    rv, rh = R * g, R * 0.84 * g
    if rv > 1:
        cr = R * 0.38 * g
        defs.append(f'<linearGradient id="fg" x1="{-rh}" y1="{-rv}" x2="{rh}" y2="{rv}" gradientUnits="userSpaceOnUse">'
                    f'<stop offset="0" stop-color="{hx(a1)}"/><stop offset="0.5" stop-color="{hx(ink)}" stop-opacity="0.96"/>'
                    f'<stop offset="1" stop-color="{hx(a2)}"/></linearGradient>'
                    f'<radialGradient id="cg" cx="0" cy="0" r="{cr}" gradientUnits="userSpaceOnUse">'
                    f'<stop offset="0" stop-color="#fff" stop-opacity="0.95"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>')
        body.append(f'<g transform="rotate({math.degrees((1 - g) * -1.1):.3f})"><path d="{star_path(rv, rh, 0.11)}" fill="url(#fg)"/>'
                    f'<circle r="{cr}" fill="url(#cg)"/></g>')
    if s1 > 0.01:
        body.append(f'<g transform="translate({R * 1.18},{-R * 0.92}) rotate({math.degrees(0.2):.3f})">'
                    f'<path d="{star_path(R * 0.26 * s1, R * 0.22 * s1, 0.12)}" fill="{hx(a2)}" fill-opacity="0.95"/></g>')
    if s2 > 0.01:
        body.append(f'<g transform="translate({-R * 1.05},{R * 0.98})">'
                    f'<path d="{star_path(R * 0.15 * s2, R * 0.13 * s2, 0.12)}" fill="{hx(ink)}" fill-opacity="0.8"/></g>')
    h = MS / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{MS}" height="{MS}" viewBox="{-h} {-h} {MS} {MS}">'
            f'<defs>{"".join(defs)}</defs>{"".join(body)}</svg>')

for i in range(NMARK):
    svg_png(mark_svg(P0 + (P1 - P0) * i / (NMARK - 1)), os.path.join(out, f"mark-{i}.png"))

# halo at its widest (the script fades it with the pulse)
hr = R * 1.95
svg_png(f'<svg xmlns="http://www.w3.org/2000/svg" width="{MS}" height="{MS}" viewBox="{-MS / 2} {-MS / 2} {MS} {MS}"><defs>'
        f'<radialGradient id="h" cx="0" cy="0" r="{hr}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{hx(a1)}" stop-opacity="0.42"/>'
        f'<stop offset="0.5" stop-color="{hx(a2)}" stop-opacity="0.14"/><stop offset="1" stop-color="{hx(a2)}" stop-opacity="0"/></radialGradient>'
        f'</defs><circle r="{hr}" fill="url(#h)"/></svg>', os.path.join(out, "halo.png"))

# the accent wash: drawn small, stretched by the script (a smooth gradient loses nothing)
TW, TH = max(64, W // 8), max(64, H // 8)
tcx, tcy, trr = TW / 2, TH * 0.45, max(TW, TH) * 0.6
svg_png(f'<svg xmlns="http://www.w3.org/2000/svg" width="{TW}" height="{TH}"><defs><radialGradient id="t" cx="{tcx}" cy="{tcy}" r="{trr}" '
        f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{hx(a1)}" stop-opacity="0.16"/><stop offset="1" stop-color="{hx(a1)}" stop-opacity="0"/>'
        f'</radialGradient></defs><rect width="{TW}" height="{TH}" fill="url(#t)"/></svg>', os.path.join(out, "tint.png"))

# the word: each letter placed by hand, so the spacing sits only BETWEEN letters and the word is truly centred
def find_font():
    for q in ("Inter:light", "Inter Variable:light", "Noto Sans:light", "Cantarell:light", "DejaVu Sans:light"):
        try:
            f = subprocess.run(["fc-match", "-f", "%{file}", q], capture_output=True, text=True).stdout.strip()
            if f and os.path.exists(f): return f, q
        except OSError: pass
    return None, None
fpath, fq = find_font()
px = max(18, round(R * 0.5))
font = None
if fpath:
    try:
        font = ImageFont.truetype(fpath, px)
        try: font.set_variation_by_name("Light")
        except Exception:
            # Inter.ttc holds many faces: pick the first called Light
            for idx in range(20):
                try:
                    f2 = ImageFont.truetype(fpath, px, index=idx)
                    if f2.getname()[1].strip().lower() == "light": font = f2; break
                except OSError: break
    except OSError: font = None
if font is None: font = ImageFont.load_default(size=px)
word = "HALCYON"
asc, desc = font.getmetrics()
base_sp = max(8, R * 0.34)
adv = [font.getlength(ch) for ch in word]
maxw = int(sum(adv) + base_sp * 1.4 * (len(word) - 1)) + 8
wh = asc + desc
for i in range(NWORD):
    sp = base_sp * (1.4 - 0.4 * i / (NWORD - 1))
    tw = sum(adv) + sp * (len(word) - 1)
    im = Image.new("RGBA", (maxw, wh), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    x = (maxw - tw) / 2
    for ch, a in zip(word, adv):
        d.text((x, 0), ch, font=font, fill=ink + (255,))
        x += a + sp
    im.save(os.path.join(out, f"word-{i}.png"))

# the stars: the same 90 as Splash.qml, each streak already turned to the way that star flies (head at the picture's centre,
# tail trailing back towards the middle of the screen)
NST = 90
LENS = (6, 20, 40)
WIDS = (1.0, 1.6, 2.3)
cols = (a1, a2, ink)
SS = 4
stars = []
for i in range(NST):
    ang = i * 2.399963 + (i % 7) * 0.05
    c, s = math.cos(ang), math.sin(ang)
    base, v = (i * 0.6180339 + 0.13) % 1, 0.55 + (i % 5) * 0.22
    w, al, k = (0.5 if i % 4 == 0 else 0), 0.35 + 0.1 * (i % 5), i % 3
    stars.append((c, s, base, v, al))
    for L, (ln, wd) in enumerate(zip(LENS, WIDS)):
        half = ln + 4
        n = 2 * half
        im = Image.new("RGBA", (n * SS, n * SS), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        col = cols[k]
        steps = 12
        for j in range(steps):                     # a tail that fades: short segments, brighter towards the head
            t0, t1 = j / steps, (j + 1) / steps
            x0, y0 = half - c * ln * (1 - t0), half - s * ln * (1 - t0)
            x1, y1 = half - c * ln * (1 - t1), half - s * ln * (1 - t1)
            d.line([(x0 * SS, y0 * SS), (x1 * SS, y1 * SS)], fill=col + (int(255 * (0.15 + 0.85 * t1)),), width=max(1, round((wd + w) * SS)))
        r = (wd + w) * SS / 2
        d.ellipse([half * SS - r, half * SS - r, half * SS + r, half * SS + r], fill=col + (255,))
        im.resize((n, n), Image.LANCZOS).save(os.path.join(out, f"star-{i}-{L}.png"))

# a password bullet
dsz = max(8, round(R * 0.07)) * SS
im = Image.new("RGBA", (dsz, dsz), (0, 0, 0, 0))
ImageDraw.Draw(im).ellipse([0, 0, dsz - 1, dsz - 1], fill=ink + (230,))
im.resize((dsz // SS, dsz // SS), Image.LANCZOS).save(os.path.join(out, "dot.png"))

# the numbers the script needs, as script: install glues this in front of halcyon.script
with open(os.path.join(out, "layout.script"), "w") as f:
    f.write(f"# rendered for {W}x{H}, font {fq or 'default'}\n")
    f.write(f"refS = {S};\nRm = {R:.3f};\nnmark = {NMARK};\nnword = {NWORD};\np0 = {P0};\np1 = {P1};\nnst = {NST};\n")
    f.write("stage_r = %.4f; stage_g = %.4f; stage_b = %.4f;\n" % tuple(v / 255 for v in stage))
    for i, (c, s, base, v, al) in enumerate(stars):
        f.write(f"sc[{i}] = {c:.5f}; ss[{i}] = {s:.5f}; sb[{i}] = {base:.5f}; sv[{i}] = {v:.3f}; sa[{i}] = {al:.3f};\n")
print(out)
