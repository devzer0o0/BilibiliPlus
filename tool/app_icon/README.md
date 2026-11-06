# App icon pipeline

The PiliPlus icon is a rendered object, not a recoloured screenshot.

- **Design source**: `render_icon.py` - a small CPU renderer (SDF raymarch + height-field
  relief + procedural studio IBL + GGX direct lights). Every shape parameter is a
  constant at the top of the file, so the design is editable and deterministic.
- **Masters** (`design/app_icon/`): `master-2048.png` (opaque design master),
  `icon-1024.png` (final iOS art, 4x supersampled), `tv-transparent-1024.png`
  (cutout used by the launch screen and Android foreground).
- **Derivatives**: `build_assets.py` reads only the three masters and rewrites the
  iOS AppIcon set, launch images, logo assets and the .ico. Re-running is idempotent.

## Requirements

Python 3.9+ with Pillow and numpy:

    python3 -m venv /tmp/piliplus-icon-venv
    /tmp/piliplus-icon-venv/bin/pip install pillow numpy

## Rebuild

    /tmp/piliplus-icon-venv/bin/python tool/app_icon/render_icon.py       --master design/app_icon/master-2048.png       --icon design/app_icon/icon-1024.png       --transparent design/app_icon/tv-transparent-1024.png
    /tmp/piliplus-icon-venv/bin/python tool/app_icon/build_assets.py

`build_assets.py` prints `VERIFIED` after checking every AppIcon size and output mode.

## Design notes

- Body 1.19 : 1, bevel 0.074, body width 76.4% of the canvas, total height 78.0%.
- Screen inset 0.105, recess 0.030; eyes are raised golden bars (tilt +/-14 deg);
  the mouth is a mirrored cubic-bezier omega.
- Gold: metallic 1, roughness 0.13 (screen) / 0.175 (body), F0 (1.0, 0.67, 0.235).
- Lighting: large warm window upper-left, cool fill right, thin rim strip, floor
  bounce; ACES tonemap and a mild saturation grade (1.12).

The reference is "B站100万粉丝奖牌开箱 & 评测｜大耳朵TV" (BV1afN7zeEJ7). See
`docs/app-icon-and-launch-screen.md` for the full verification record.
