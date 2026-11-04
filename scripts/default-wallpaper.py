#!/usr/bin/env python3
"""The first Halcyon wallpaper, drawn on the machine: deep space in the Halcyon colours.

    default-wallpaper.py OUT.jpg [WIDTH HEIGHT] [--seed N]

A dark indigo sky, two soft nebula clouds (periwinkle and lavender) along a diagonal band of stars, a few brighter stars with
a faint glow, and the lit edge of a planet in the lower right. The left and middle stay calm for the desktop widgets.
Only Pillow (python-pillow); every step is a whole-image operation, so 2560x1600 takes a couple of seconds.
user-setup.sh wallpaper runs it when ~/Pictures/Wallpapers is empty (the ImageMagick gradient is the fallback).
"""
import math
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

BG_TOP = (9, 11, 22)
BG_BOTTOM = (20, 22, 38)
NEBULA_A = (122, 140, 214)      # periwinkle (the default accent, a little deeper)
NEBULA_B = (176, 140, 214)      # lavender
NEBULA_C = (86, 150, 178)       # a touch of teal deep inside the clouds
STAR_TINTS = [(255, 255, 255), (214, 222, 255), (236, 226, 255), (255, 240, 226)]


def fbm(w, h, rng, base=6, octaves=6, persistence=0.55):
    """Fractal noise in 0..255 (L): random grids upscaled smoothly, finer and fainter each octave."""
    acc = None
    amp, total = 1.0, 0.0
    for o in range(octaves):
        gw, gh = max(2, base * 2 ** o), max(2, int(base * 2 ** o * h / w))
        grid = Image.frombytes("L", (gw, gh), bytes(rng.getrandbits(8) for _ in range(gw * gh)))
        layer = grid.resize((w, h), Image.BICUBIC)
        if acc is None:
            acc = layer
        else:
            acc = Image.blend(acc, layer, amp / (total + amp))
        total += amp
        amp *= persistence
    return acc.filter(ImageFilter.GaussianBlur(max(1, w // 400)))


def curve(img, lo, hi, gamma=1.0, gain=255):
    """Map lo..hi to 0..gain with a gamma: turns smooth noise into clouds with soft edges."""
    def f(v):
        t = min(1.0, max(0.0, (v - lo) / float(hi - lo)))
        return int(gain * t ** gamma)
    return img.point([f(v) for v in range(256)])


def band(w, h, angle, width, offset=0.0):
    """A soft diagonal band (L): brightest along a line through the centre, fading out over `width` (0..1 of the diagonal)."""
    g = Image.linear_gradient("L").resize((w * 2, h * 2))
    g = g.rotate(angle, resample=Image.BICUBIC)
    g = g.crop((w // 2, h // 2, w // 2 + w, h // 2 + h))
    mid = 128 + offset * 128

    def f(v):
        d = (v - mid) / (128.0 * width)
        return int(255 * math.exp(-d * d))
    return g.point([f(v) for v in range(256)])


def tint(mask, colour):
    """An RGB layer of `colour` scaled by mask."""
    solid = Image.new("RGB", mask.size, colour)
    return ImageChops.multiply(solid, Image.merge("RGB", (mask, mask, mask)))


def main():
    args, seed = sys.argv[1:], 7
    if "--seed" in args:
        i = args.index("--seed")
        seed = int(args[i + 1])
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    out = args[0]
    W, H = (int(args[1]), int(args[2])) if len(args) >= 3 else (2560, 1600)
    rng = random.Random(seed)
    # nebula and glow are smooth: draw them at half size and scale up (4x less work, no visible difference)
    w, h = max(64, W // 2), max(64, H // 2)

    sky = Image.linear_gradient("L").resize((w, h)).point(lambda v: int(v * 0.8))
    sky = Image.composite(Image.new("RGB", (w, h), BG_BOTTOM), Image.new("RGB", (w, h), BG_TOP), sky)

    milky = band(w, h, -28, 0.34, 0.05)                         # the band the clouds and most stars follow
    n1, n2, n3 = fbm(w, h, rng), fbm(w, h, rng, base=4), fbm(w, h, rng, base=9)
    cloud_a = ImageChops.multiply(curve(n1, 110, 196, 1.4, 215), milky)
    cloud_b = ImageChops.multiply(curve(n2, 116, 200, 1.5, 190), band(w, h, -34, 0.26, -0.18))
    core = ImageChops.multiply(curve(n3, 140, 215, 2.2, 90), ImageChops.multiply(cloud_a, cloud_b).point(lambda v: min(255, v * 4)))
    dust = curve(fbm(w, h, rng, base=10, octaves=5), 130, 190, 1.2, 170)   # dark lanes across the glow

    glow = ImageChops.add(tint(cloud_a, NEBULA_A), tint(cloud_b, NEBULA_B))
    glow = ImageChops.add(glow, tint(core, NEBULA_C))
    glow = ImageChops.subtract(glow, tint(ImageChops.multiply(dust, milky), (60, 60, 70)))
    glow = glow.filter(ImageFilter.GaussianBlur(w / 300))
    img = ImageChops.screen(sky, glow).resize((W, H), Image.BICUBIC)

    # ---- stars: many faint ones, denser in the band; a few bright ones with a soft halo
    density = milky.resize((W, H), Image.BILINEAR)
    stars = Image.new("RGB", (W, H), (0, 0, 0))
    halos = Image.new("RGB", (W, H), (0, 0, 0))
    ds, dh = ImageDraw.Draw(stars), ImageDraw.Draw(halos)
    k = W * H / (2560 * 1600)
    placed, tries = 0, 0
    target = int(2600 * k)
    while placed < target and tries < target * 6:
        tries += 1
        x, y = rng.random() * W, rng.random() * H
        if rng.random() > 0.25 + 0.75 * density.getpixel((int(x), int(y))) / 255:
            continue
        placed += 1
        m = rng.random() ** 3.2                                  # most stars are faint
        c = rng.choice(STAR_TINTS)
        a = 0.25 + 0.75 * m
        col = tuple(int(v * a) for v in c)
        r = 0.6 + 1.5 * m
        ds.ellipse((x - r, y - r, x + r, y + r), fill=col)
        if m > 0.93:                                             # about one in fifty
            hr = r * 4
            dh.ellipse((x - hr, y - hr, x + hr, y + hr), fill=tuple(int(v * 0.3) for v in c))
    stars = stars.filter(ImageFilter.GaussianBlur(0.6))
    halos = halos.filter(ImageFilter.GaussianBlur(5 * max(1, W / 2560)))
    img = ImageChops.screen(img, ImageChops.add(stars, halos))

    # ---- the planet: a dark disc low on the right, lit along its upper-left edge, with a thin haze of atmosphere
    R = int(H * 1.35)
    cx, cy = int(W * 0.9), int(H + R * 0.86)
    disc = Image.new("L", (W, H), 0)
    ImageDraw.Draw(disc).ellipse((cx - R, cy - R, cx + R, cy + R), fill=255)
    shift = int(H * 0.009)
    inner = Image.new("L", (W, H), 0)
    ImageDraw.Draw(inner).ellipse((cx - R + shift, cy - R + shift, cx + R + shift, cy + R + shift), fill=255)
    rim = ImageChops.subtract(disc, inner).filter(ImageFilter.GaussianBlur(H * 0.004))
    haze = disc.filter(ImageFilter.GaussianBlur(H * 0.035))
    haze = ImageChops.multiply(haze, ImageChops.invert(disc))            # only outside the planet
    glow_in = ImageChops.subtract(disc, disc.filter(ImageFilter.GaussianBlur(H * 0.05)))   # faint light just inside the edge
    body = Image.composite(Image.new("RGB", (W, H), (7, 8, 16)), img, disc.filter(ImageFilter.GaussianBlur(1.2)))
    shade = band(W, H, -28, 0.9, 0.55)                          # the lit side fades towards the lower right
    img = ImageChops.add(body, tint(ImageChops.multiply(rim, shade), (200, 196, 255)))
    img = ImageChops.add(img, tint(ImageChops.multiply(glow_in.point(lambda v: v // 3), shade), (110, 110, 190)))
    img = ImageChops.screen(img, tint(ImageChops.multiply(haze, shade), (120, 120, 210)))

    # ---- a soft vignette, then a little grain so the dark gradients do not band on 8-bit screens
    vig = Image.radial_gradient("L").resize((W, H), Image.BICUBIC).point(lambda v: 255 - int(110 * (v / 255) ** 2.2))
    img = ImageChops.multiply(img, Image.merge("RGB", (vig, vig, vig)))
    grain = Image.effect_noise((W, H), 3).point(lambda v: max(0, v - 124))
    img = ImageChops.add(img, Image.merge("RGB", (grain, grain, grain)))
    img = ImageChops.subtract(img, Image.new("RGB", (W, H), (2, 2, 2)))

    img.save(out, quality=94, subsampling=0) if out.lower().endswith((".jpg", ".jpeg")) else img.save(out)


if __name__ == "__main__":
    main()
