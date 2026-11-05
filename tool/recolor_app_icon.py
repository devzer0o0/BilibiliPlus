#!/usr/bin/env python3
"""Recolour the app icon to metallic gold, and regenerate every derived size.

    tool/recolor_app_icon.py

The artwork is not redrawn: this only moves its colours. Hues rotate to the gold
family, and saturation/brightness shift so the *mean* of the coloured pixels lands
on #D4AF37 - "metallic gold", the usual sRGB stand-in for real gold (212, 175, 55).
Per-pixel offsets around the mean are preserved, so the existing gradient and the
antialiased edges survive instead of flattening into one flat fill.

Whites, the transparent ring and the globe's highlights (saturation below the
floor) are left exactly as they are.

Outputs regenerated from the single 1024 master:
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png   (all sizes)
  ios/Runner/Assets.xcassets/LaunchImage.imageset/*.png (light + dark)
  assets/images/logo/logo.png, logo_2.png, desktop/logo_large.png
  assets/images/logo/ico/app_icon.ico
"""
import colorsys
import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("BLOCKED_TOOLING: Pillow is required (pip install pillow)")

ROOT = pathlib.Path(__file__).resolve().parent.parent
MASTER = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"

TARGET = (212, 175, 55)        # #D4AF37 metallic gold
SAT_FLOOR = 0.08               # below this a pixel is treated as neutral


def hsv(rgb):
    return colorsys.rgb_to_hsv(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255)


def measure(im):
    """Mean hue/sat/val over the coloured pixels only."""
    px = im.load()
    w, h = im.size
    step = max(1, min(w, h) // 128)
    hs = ss = vs = n = 0
    for y in range(0, h, step):
        for x in range(0, w, step):
            r, g, b, a = px[x, y]
            if a < 200:
                continue
            hh, s, v = hsv((r, g, b))
            if s < SAT_FLOOR:
                continue
            hs += hh
            ss += s
            vs += v
            n += 1
    if not n:
        raise SystemExit("BLOCKED: no coloured pixels to map")
    # Hue is circular; average the vectors instead of the raw angles.
    sx = sum(1 for _ in ())  # placeholder, replaced below
    return hs / n, ss / n, vs / n, n


def circular_mean_hue(im):
    px = im.load()
    w, h = im.size
    step = max(1, min(w, h) // 128)
    x = y = n = 0.0
    for yy in range(0, h, step):
        for xx in range(0, w, step):
            r, g, b, a = px[xx, yy]
            if a < 200:
                continue
            hh, s, v = hsv((r, g, b))
            if s < SAT_FLOOR:
                continue
            import math
            x += math.cos(hh * 2 * math.pi)
            y += math.sin(hh * 2 * math.pi)
            n += 1
    import math
    return (math.atan2(y / n, x / n) / (2 * math.pi)) % 1.0


def recolor(image):
    im = image.convert("RGBA")
    px = im.load()
    w, h = im.size
    src_h = circular_mean_hue(im)
    _, src_s, src_v, _ = measure(im)
    t_h, t_s, t_v = hsv(TARGET)
    dh = (t_h - src_h) % 1.0
    ds = t_s - src_s
    dv = t_v - src_v
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hh, s, v = hsv((r, g, b))
            if s < SAT_FLOOR:
                continue
            nh = (hh + dh) % 1.0
            ns = min(1.0, max(0.0, s + ds))
            nv = min(1.0, max(0.0, v + dv))
            nr, ng, nb = colorsys.hsv_to_rgb(nh, ns, nv)
            px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    return im


def rounded(img, radius_ratio=0.225):
    """Rounded-corner version with a transparent outside, for the splash."""
    from PIL import ImageDraw
    w, h = img.size
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, w - 1, h - 1], radius=int(w * radius_ratio), fill=255
    )
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main():
    if not MASTER.exists():
        sys.exit(f"BLOCKED: {MASTER} missing")
    master = recolor(Image.open(MASTER))
    master.save(MASTER)
    print(f"  master      {MASTER.relative_to(ROOT)} 1024x1024")

    # Every AppIcon size, derived from the single master that was just recoloured.
    spec = json.loads(
        (MASTER.parent / "Contents.json").read_text(encoding="utf-8")
    )
    sizes = {}
    for entry in spec["images"]:
        base, scale = entry["size"].split("x")
        px = round(float(base) * int(entry["scale"].rstrip("x")))
        sizes[entry["filename"]] = px
    for name, px in sorted(sizes.items(), key=lambda kv: kv[1]):
        out = master.resize((px, px), Image.LANCZOS)
        out.save(MASTER.parent / name)
    print(f"  app icons   {len(sizes)} sizes, 40px .. 1024px")

    # Launch images: recolour the existing ones in place, so their rounded shape
    # and transparency are the ones already shipped rather than a new guess.
    launch_dir = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
    for p in sorted(launch_dir.glob("*.png")):
        recolor(Image.open(p)).save(p)
    print(f"  launch      {len(list(launch_dir.glob('*.png')))} images")

    logo_dir = ROOT / "assets/images/logo"
    master.resize((512, 512), Image.LANCZOS).save(logo_dir / "logo.png")
    rounded(master.resize((512, 512), Image.LANCZOS)).save(logo_dir / "logo_2.png")
    master.resize((512, 512), Image.LANCZOS).save(logo_dir / "desktop/logo_large.png")
    print("  masters     logo.png / logo_2.png / desktop/logo_large.png 512x512")

    ico_path = logo_dir / "ico/app_icon.ico"
    master.save(ico_path, sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                                 (64, 64), (128, 128), (256, 256)])
    print("  ico         app_icon.ico 16..256")

    print("GOLD_APPLIED")


if __name__ == "__main__":
    main()
