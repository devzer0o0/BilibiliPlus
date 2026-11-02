# Third-party notices (iOS build)

Date: 2026-11-02.

PiliPlus itself is distributed under the GNU GPL v3 (`LICENSE`). This file lists
the third-party components that end up inside `Runner.app` and where their
licence text lives. It is an inventory, not a replacement for the full texts.

## Bundled binaries (Frameworks/)

The iOS build embeds libmpv's frameworks plus the AV1-capable Avcodec:

| Framework | Project | Licence |
| --- | --- | --- |
| `Mpv`, `Placebo` | mpv / libplacebo | GPL-2.0-or-later / LGPL-2.1-or-later |
| `Avcodec`, `Avformat`, `Avfilter`, `Avutil`, `Swresample`, `Swscale` | FFmpeg 7.0.2 | LGPL-2.1-or-later (this build) |
| `Dav1d` | dav1d | BSD-2-Clause |
| `Ass`, `Fribidi`, `Harfbuzz`, `Freetype`, `Png16`, `Xml2`, `Uchardet` | libass and its dependencies | ISC / LGPL-2.1 / MIT / libpng / libxml2 / MPL-1.1 |
| `Mbedtls`, `Mbedcrypto`, `Mbedx509` | Mbed TLS | Apache-2.0 |
| `OrderedSet` | OrderedSet | MIT |

`Avcodec` is the only modified binary: it is FFmpeg 7.0.2 with the upstream AV1
VideoToolbox backport (`f9c5c5358cfef3847674c6f3b3ded9611ebc5647`). The patch and
the LGPL text ship in the repository:

- `ios/av1/ffmpeg-7.0.2-av1-vt-backport.patch`
- `ios/av1/FFmpeg-LGPL-2.1.txt`
- `ios/av1/README.md`

## Flutter packages

Every Dart package licence is collected by the Flutter tool into
`Runner.app/Frameworks/App.framework/flutter_assets/NOTICES.Z` (zlib-compressed
`NOTICES`). It is generated from `pubspec.lock` at build time and is present in
the shipped bundle; `LicensePage` and any "open source licences" entry read from
that registry.

## Assets

- `assets/shaders/Anime4K_*.glsl` - Anime4K by bloc97, MIT, see
  `assets/shaders/LICENSE`.
- `assets/fonts/custom_icon.ttf`, `assets/fonts/digital_id_num.ttf` - icon and
  digit fonts that ship with the upstream repository.

## Outstanding before a public release

- The frameworks in `Frameworks/` do not embed their licence files; a public
  build should ship the texts alongside `NOTICES.Z` (for example a
  `ThirdPartyNotices.txt` inside the bundle or a linked notices page).
- mpv is linked in GPL mode upstream, which is compatible with PiliPlus' GPLv3
  but means the whole binary must stay GPLv3.
