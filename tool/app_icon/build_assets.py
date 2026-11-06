#!/usr/bin/env python3
"""Derive every shipped icon/splash asset from the design masters.

Inputs (never written by this script):
  design/app_icon/master-2048.png        2048x2048 opaque sRGB design master
  design/app_icon/icon-1024.png          1024x1024 opaque sRGB iOS design
  design/app_icon/tv-transparent-1024.png  transparent gold-TV cutout

Outputs:
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png  (every Contents.json entry)
  ios/Runner/Assets.xcassets/LaunchImage.imageset/*.png (1x/2x/3x, light+dark)
  assets/images/logo/app_icon_ios_1024.png
  assets/images/logo/app_icon_foreground.png (transparent, Android safe zone)
  assets/images/logo/app_icon_monochrome.png (white alpha mask)
  assets/images/logo/logo.png
  assets/images/logo/logo_2.png
  assets/images/logo/desktop/logo_large.png
  assets/images/logo/ico/app_icon.ico

Every output is produced from a master on every run, so repeated runs are
idempotent and never compound a crop/resize/recolour.
"""
import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("BLOCKED_TOOLING: Pillow is required (see tool/app_icon/README.md)")

ROOT = pathlib.Path(__file__).resolve().parents[2]
DESIGN = ROOT / "design/app_icon"
MASTER = DESIGN / "master-2048.png"
ICON = DESIGN / "icon-1024.png"
CUTOUT = DESIGN / "tv-transparent-1024.png"

APPICON = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
LAUNCH = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
LOGO = ROOT / "assets/images/logo"


def load(path):
    if not path.exists():
        sys.exit(f"BLOCKED: {path.relative_to(ROOT)} missing")
    return Image.open(path).convert("RGBA" if path == CUTOUT else "RGB")


def resize(img, size):
    return img.resize((size, size), Image.LANCZOS)


def flatten(img):
    """Guarantee an opaque RGB image (the iOS icon may not carry alpha)."""
    if img.mode != "RGB":
        bg = Image.new("RGB", img.size, (21, 21, 21))
        bg.paste(img, (0, 0), img)
        img = bg
    return img


def save_icon(img, path, profile=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    flatten(img).save(path, "PNG", icc_profile=profile)


def ios_profile():
    """Deterministic sRGB ICC profile (LittleCMS stamps the header with now)."""
    from PIL import ImageCms
    import struct
    prof = bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    prof[24:36] = struct.pack(">6H", 2025, 1, 1, 0, 0, 0)
    return bytes(prof)


def main():
    master = load(MASTER)
    icon = load(ICON)
    cutout = load(CUTOUT)
    if master.size != (2048, 2048) or icon.size != (1024, 1024):
        sys.exit("BLOCKED: design master sizes changed")

    icc = ios_profile()

    spec = json.loads((APPICON / "Contents.json").read_text(encoding="utf-8"))
    sizes = {}
    for entry in spec["images"]:
        base, scale = entry["size"].split("x")
        px = round(float(base) * int(entry["scale"].rstrip("x")))
        sizes[entry["filename"]] = px
    for name, px in sorted(sizes.items(), key=lambda kv: kv[1]):
        src = icon if px == 1024 else master.resize((px, px), Image.LANCZOS)
        save_icon(src, APPICON / name, icc)
    print(f"  app icons   {len(sizes)} files, 20px .. 1024px")

    # Launch screen: transparent cutout, same 128/256/384 layout as before.
    for name, px in {
        "LaunchImage.png": 128, "LaunchImage@2x.png": 256, "LaunchImage@3x.png": 384,
        "LaunchImageDark.png": 128, "LaunchImageDark@2x.png": 256, "LaunchImageDark@3x.png": 384,
    }.items():
        resize(cutout, px).save(LAUNCH / name, "PNG", icc_profile=icc)
    print("  launch      6 files, 128/256/384")

    save_icon(icon, LOGO / "app_icon_ios_1024.png", icc)
    save_icon(resize(icon, 512), LOGO / "logo.png", icc)
    save_icon(resize(icon, 512), LOGO / "desktop/logo_large.png", icc)
    (LOGO / "logo_2.png").parent.mkdir(parents=True, exist_ok=True)
    resize(cutout, 512).save(LOGO / "logo_2.png", "PNG", icc_profile=icc)
    print("  logos       app_icon_ios_1024 / logo / logo_2 / logo_large")

    # Android adaptive foreground + monochrome: keep within the 66% safe circle.
    fg = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    core = resize(cutout, 340)
    fg.paste(core, ((512 - 340) // 2, (512 - 340) // 2), core)
    fg.save(LOGO / "app_icon_foreground.png", "PNG", icc_profile=icc)
    mono = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    mask = resize(cutout, 340).split()[3]
    white = Image.new("RGBA", (340, 340), (255, 255, 255, 255))
    white.putalpha(mask)
    mono.paste(white, ((512 - 340) // 2, (512 - 340) // 2), white)
    mono.save(LOGO / "app_icon_monochrome.png", "PNG", icc_profile=icc)
    print("  android     foreground / monochrome")

    ico_src = Image.frombytes("RGB", icon.size, icon.tobytes())
    ico_src.save(LOGO / "ico/app_icon.ico", sizes=[(16, 16), (24, 24), (32, 32),
                                                  (48, 48), (64, 64), (128, 128), (256, 256)])
    print("  ico         app_icon.ico 16..256")

    # ---- verification -----------------------------------------------------
    for name, px in sizes.items():
        im = Image.open(APPICON / name)
        assert im.size == (px, px), (name, im.size, px)
        assert im.mode == "RGB", (name, im.mode)
    big = Image.open(APPICON / "Icon-App-1024x1024@1x.png")
    assert big.size == (1024, 1024) and big.mode == "RGB"
    for p in LAUNCH.glob("*.png"):
        im = Image.open(p)
        assert im.mode == "RGBA", (p.name, im.mode)
    print("VERIFIED")


if __name__ == "__main__":
    main()