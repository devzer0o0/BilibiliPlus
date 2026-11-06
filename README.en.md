<div align="center">
  <img src="docs/images/readme/anime-hero.svg" width="100%" alt="Anime-style hero illustration: an original chibi TV girl against a cream and pink background; the headline reads BILIBILI+ and a speech bubble says 4K60, rolling!">
  <br>
  <sub>Key art: the TV girl presses play amid sakura petals and speed lines. Original character, not official artwork.</sub>
  <br><br>
  <img src="docs/images/readme/anime-badge-ios.svg" width="150" alt="Badge: iOS 15+ ONLY">
  <img src="docs/images/readme/anime-badge-flutter.svg" width="172" alt="Badge: Flutter 3.47.9">
  <img src="docs/images/readme/anime-badge-gpl.svg" width="124" alt="Badge: GPL-3.0">
  <img src="docs/images/readme/anime-badge-version.svg" width="134" alt="Badge: v0.0.6+7">
  <p><b>An iOS-only third-party Bilibili client: playback, interface and data paths taken apart, fixed, and backed by evidence.</b></p>
  <p>
    <a href="https://github.com/devzer0o0/BilibiliPlus/releases"><b>Download IPA</b></a> ·
    <a href="#quick-start">Quick start</a> ·
    <a href="#features">Features</a> ·
    <a href="#docs">Design docs</a> ·
    <a href="README.md">中文</a>
  </p>
  <sub>Badges: iOS 15+; Flutter 3.47.9; GPL-3.0; current version 0.0.6+7.</sub>
</div>

> [!IMPORTANT]
> **This is an iOS-only fork.** Android / Windows / Linux / macOS runners were removed; use upstream [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) for those platforms. Every "verified on device" claim below is scoped to iPhone Air (iPhone18,4) and the stated OS / build version. Simulator, artifact and automated evidence are labelled separately.

> [!NOTE]
> This README only expands what this fork **actually changed and can prove**. Features inherited from upstream are listed by name only, not claimed as individually regression-tested. No image from the upstream original README is reused.

## Contents

- [Why this fork](#why-this-fork)
- [Screenshots](#screenshots)
- [Features](#features)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [Build and verify](#build-and-verify)
- [Compatibility](#compatibility)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Docs](#docs)
- [License](#license)

<a id="why-this-fork"></a>
## Why this fork

Upstream PiliPlus is already a complete Bilibili client. This fork does not attempt a cross-platform rewrite. It goes deep on one platform: playback first, then the native interface, then the AI recommendation and S3 backup paths — each with a reproducible check.

> Not a re-skin: two backends, one route, evidence for every frame.

| Episode | What this fork changed | Evidence |
| --- | --- | --- |
| Playback | mpv + AVPlayerLayer dual backend; AV1 VideoToolbox injected and checked at build time; output sized to physical screen pixels | ✅ 4K60 on device |
| Interface | iOS 26 liquid-glass tab bar; gold TV icon and launch screen | ✅ device material / artifacts |
| Recommendations | Optional AI semantic filter / ranking; hard filter runs first; 7-day cold-start snapshot | 🟡 unit tests / build |
| Backup | S3-compatible + AES-256-GCM + recovery code | 🟡 logic + MinIO |
| Shared videos | Three real fixes: plain-text shares, filter order, titles | ✅ logs / unit tests |
| Platform | iOS-only tree; tests added to CI | ✅ tree / CI |

Legend: ✅ device or artifact evidence; 🟡 automated / simulator / local-service evidence; ▶️ implemented but not exercised on device; ⛔ not verified.

<a id="screenshots"></a>
## Screenshots

<p align="center">
  <img src="docs/images/readme/anime-screens.png" width="100%" alt="Four-panel manga-style screenshot sheet: the top row shows Release builds on an iPhone Air (Home and Mine) with the textless liquid-glass tab bar; the bottom row shows light and dark Dynamics screens from an iPhone Air simulator, each with a DEBUG badge.">
</p>

<p align="center"><sub><b>Figure 1</b> · Top: Release on device; bottom: DEBUG on simulator. The device proves material and selection; the simulator only proves layout and dark-mode adaptation.</sub></p>

The top row is from a Release build on iPhone Air; the glass capsule samples the content underneath in real time. The bottom row is from an iPhone Air simulator (iOS 27.2), with a DEBUG badge in the top-right corner to distinguish build provenance.

Dark mode has simulator screenshots, but dark-mode device material and accessibility checks are still incomplete. Treating simulator captures as device acceptance is the exact mistake this README avoids.

<a id="features"></a>
## Features

The four episodes below cover only the parts this fork touched. Upstream features — search, video details, comments, danmaku, live, messages and the rest — still ship, but are not re-explained here.

<p align="center">
  <img src="docs/images/readme/anime-episode-playback.svg" width="100%" alt="Chapter banner: EPISODE 01 / PLAYBACK; large 01 and Playback; subtitle says two backends, one timeline; a play button and film strip on the right.">
</p>

<a id="playback"></a>
### 01 · Playback — two backends, one timeline (rebuilt)

"The SoC supports AV1" does not mean "this app is decoding AV1 in hardware." Four conditions must hold at once:

1. **The SoC can decode it** — VideoToolbox reports AV1 support.
2. **The decoder is actually in the build** — the bundled FFmpeg registers `av1_videotoolbox`; `tool/ios_av1_package.sh` verifies the Mach-O UUID, 359 exported symbols (ABI 61.3.100), dependencies, and device / simulator slices. Any mismatch fails the build.
3. **The right stream is selected** — prefer AV1 variants that can be hardware-decoded, while respecting the user's codec preference.
4. **The session really decodes in hardware** — every frame reports `hwdec-current=videotoolbox`, the frame format is `CVPixelBuffer`, and libmpv logs `videotoolbox[nv12]`.

| Capability | Path | Status |
| --- | --- | --- |
| AV1 8-bit SDR | mpv + FFmpeg + VideoToolbox | ✅ hardware decode on device (4K60 / 4K30) |
| HEVC / H.264 | mpv + VideoToolbox | ✅ hardware decode on device (including 4K60 regression) |
| HDR10 | AVPlayerLayer | ✅ Main10 / PQ variant selected and presented on device; screen HDR composition not verified |
| HLG | AVPlayerLayer | ▶️ route wired; no HLG source this round |
| Dolby Vision | AVPlayerLayer + system RPU restoration | ▶️ route wired; no `dvh1` in the sample, not exercised |
| AV1 10-bit SDR | AVPlayerLayer | ✅ correct picture, no green screen; hardware state reported as `unavailable`, never faked |

<p align="center">
  <img src="docs/images/readme/anime-playback-route.svg" width="100%" alt="Playback routing diagram: a build gate checks AV1 VideoToolbox registration, Mach-O UUID, 359 exported symbols, ABI 61.3.100, and device/simulator slices; any drift fails the build. A stream selector prefers hardware-decodable AV1. 8-bit SDR goes to mpv + FFmpeg + VideoToolbox; HDR10, HLG, Dolby Vision and AV1 10-bit go to AVPlayerLayer. Only one backend stays active per session; output is sized to physical screen pixels.">
</p>

<p align="center"><sub><b>Figure 2</b> · Playback routing: prove the decoder is in the bundle before deciding which backend gets the frame. This is a structure diagram, not a call sequence.</sub></p>

**Measurements (iPhone Air, iPhone18,4, iOS 27.3, diagnostic build before signed Release)**

| Source | Spec | Samples | Hardware-decoded |
| --- | --- | --- | --- |
| AV1 | 3840×2160 @60fps `av01.0.13M.08` | 31 | 31 |
| AV1 | 4096×2160 @59.994fps `av01.0.13M.08` | 32 | 32 |
| AV1 | 3840×2024 @59.932fps `av01.0.13M.08` | 32 | 32 |
| AV1 | 3840×2160 @29.97fps `av01.0.13M.08` | 2 | 2 |
| H.264 | 3840×2160 @60fps (regression) | 13 | 13 |

Design trade-offs:

- **8-bit SDR goes through mpv**: danmaku, subtitles, speed control, super-resolution and animated screenshots remain available.
- **HDR10 / HLG / Dolby Vision / AV1 10-bit go through AVPlayerLayer**: true EDR passthrough, not HDR compressed to SDR and dressed up.
- One backend per session. Switching sources disposes the old backend first; two backends are never alive with one hidden. Position, duration and play state come from one snapshot; rotation, fullscreen and control-bar visibility do not create a new media generation.
- Capabilities missing from the native path (audio-track switching, animated screenshots, super-resolution, player volume, AirPlay video) go through `PlaybackCapabilities` + `PlaybackRoute`, returning a Chinese reason for `preparing / native / disposed / none` instead of failing silently.
- **Output follows the screen, not the source**: allocation uses physical display pixels. iPhone Air full-width 16:9 sits around **1260×709**; DPR, BoxFit crop / stretch, explicit aspect ratio, rotation, window changes and pinch zoom all participate, capped by source size. A 120 ms debounce and serialized native commands prevent rebuild storms while dragging; Anime4K or disabled hardware decode keeps full source output.

Architecture and evidence levels: [docs/ios-native-playback-architecture.md](docs/ios-native-playback-architecture.md); raw measurements: [docs/ios-av1-hardware-evidence-2026-11-05.md](docs/ios-av1-hardware-evidence-2026-11-05.md).

<p align="center">
  <img src="docs/images/readme/anime-episode-interface.svg" width="100%" alt="Chapter banner: EPISODE 02 / INTERFACE; large 02 and Interface; subtitle mentions liquid glass, the gold TV and a little magic; a phone icon on the right.">
</p>

<a id="interface"></a>
### 02 · Interface — liquid glass and a gold TV (rebuilt)

The mobile tab bar follows the liquid-glass capsule from the reference recording: Home / Dynamics / Mine, no labels, centered icons, and a light capsule behind the selected item. Page switching, scroll-to-refresh, badges, avatars and safe areas remain with the existing controllers.

<p align="center">
  <img src="docs/images/readme/anime-nav-compare.png" width="100%" alt="Liquid-glass tab bar comparison: the top half is the reference recording with four labeled or icon-only entries; the bottom half is the candidate implementation on an iPhone Air simulator with three textless entries and a selection capsule behind Home. A speech bubble reads that a simulator is not device acceptance.">
</p>

<p align="center"><sub><b>Figure 3</b> · Reference recording (top) vs. candidate implementation on an iPhone Air simulator (bottom). The candidate uses Impeller Metal refraction and blur; this is not device acceptance.</sub></p>

- **iOS 26+**: `UIVisualEffectView` + `UIGlassEffect(style: .clear)`, `isInteractive = true`; capsule height 52 pt, max width 360 pt, horizontal margin 30 pt, corner radius 26; selection block 82×36, radius 18. Flutter owns pages, business state, outer layout and accessibility labels; the native view owns material, the three buttons, selection, badge and hit testing.
- **iOS < 26 / non-iOS / capability query failure / platform view not created within 3 s**: Flutter fallback (BackdropFilter + shader), logging `[native-glass] Flutter fallback: <reason>`. A device with native support must not silently fall back and still claim native acceptance.
- **Accessibility and preferences**: VoiceOver labels, selected state and unread counts map to native fields; Reduce Transparency, Increase Contrast and Reduce Motion each have a path. The bar leaves layout, hit testing and semantics while the keyboard is up.
- **Verified**: device log `material=UIGlassEffect.clear`, all three entries tappable, capsule luminance changing with content while scrolling (111→235→252→118), bar disappearing in video details and returning on back.
- **Not verified**: dark-mode material and accessibility checks, press animation feel, VoiceOver, Reduce Transparency / Increase Contrast, keyboard, rotation, foreground / background restore, memory and frame rate.

The previous icon was "the official bilibili international icon with a new colour" (gold background, white wordmark, globe in the corner). This version redraws the **gold TV** from the centre of Bilibili's million-follower commemorative medal: wide rounded body, twin antennas, inset screen frame, embossed eyes and mouth. No wordmark, globe, feet, knobs or text.

<p align="center">
  <img src="docs/images/readme/anime-icon-before-after.png" width="100%" alt="Icon before/after: the old icon has a gold background, white bilibili wordmark and a globe badge; the new icon is a gold TV on black with twin antennas, an inset screen frame and an embossed expression. A speech bubble says this is a redraw, not a recolour.">
</p>

<p align="center"><sub><b>Figure 4</b> · The old icon on the left; the redrawn medal TV on the right. Metal reflection, bevels and screen-frame shadow are generated from geometry and lighting.</sub></p>

<p align="center">
  <img src="docs/images/readme/anime-icon-ladder.png" width="100%" alt="Icon size ladder and simulator home screen: gold TV icons from 20 px to 1024 px on the left, still recognizable at 60 px; on the right, an iPhone 17e simulator home screen with the icon installed and labelled bilibili+; the page notes this is a simulator, not device acceptance.">
</p>

<p align="center"><sub><b>Figure 5</b> · 20–1024 px ladder and an iPhone 17e simulator home screen. The right side is a simulator install; a device home-screen capture is still missing.</sub></p>

- **Master**: `design/app_icon/master-2048.png` (2048²) is the single source of truth; the 1024 icon and transparent TV asset derive from it. The master is never overwritten by derivatives.
- **Rendering**: `tool/app_icon/render_icon.py` uses SDF ray marching (body / antennas / eyes) + front-surface height-field relief (screen / lips) + a procedural studio environment + GGX + ACES. No image-generation model; every shape is an editable constant.
- **Repeatable pipeline**: `tool/app_icon/build_assets.py` resamples from three masters every run and emits the full iOS AppIcon set, launch image, logo, ICO and Android foreground. ICC timestamps are fixed; identical input produces byte-identical output (two full runs share the same SHA-256).
- **Acceptance**: 25 AppIcon references / 21 unique files, 20–1024 px all matched; 1024 icon is RGB, no alpha, embedded sRGB; the gold TV stays recognizable at 60 px; `actool` compiles.
- **Launch screen**: black background with the transparent gold TV centred. iOS caches launch-storyboard snapshots, so replacing only the image can keep showing the old one. The asset was renamed from `LaunchImage` to **`LaunchImageGoldTV`** and the build number raised to **0.0.3+4**; after an over-install, all four snapshots under `Library/SplashBoard` were rebuilt and the old ones disappeared.

<p align="center">
  <img src="docs/images/readme/anime-launch-sheet.png" width="88%" alt="Launch screen explainer: on the left, a simulator cold-boot capture with a gold TV centred on pure black and no rounded-square plate, labelled 0.0.3+4; on the right, text explaining the asset rename and SplashBoard snapshot rebuild.">
</p>

<p align="center"><sub><b>Figure 6</b> · Simulator cold boot. The capture still says 0.0.3+4 because the launch-cache experiment happened in that build; the current version is 0.0.6+7. On device the launch screen disappears faster than a capture can be taken; the indirect evidence is the SplashBoard snapshot rebuild and only LaunchImageGoldTV remaining in Assets.car.</sub></p>

Full design source, material parameters, asset list and acceptance: [docs/liquid-glass-bottom-bar.md](docs/liquid-glass-bottom-bar.md) and [docs/app-icon-and-launch-screen.md](docs/app-icon-and-launch-screen.md).

<p align="center">
  <img src="docs/images/readme/anime-episode-data.svg" width="100%" alt="Chapter banner: EPISODE 03 / DATA; large 03 and Data; subtitle says AI only adds, S3 only carries encrypted luggage; a database icon on the right.">
</p>

<a id="data"></a>
### 03 · Data — AI only adds, S3 only carries encrypted luggage (new)

AI recommendations and S3 backup are optional side paths, off by default. They share one rule: a local hard filter or explicit allow-list decides what may enter, before any remote request or upload. Restores always preview before writing.

<p align="center">
  <img src="docs/images/readme/anime-data-route.svg" width="100%" alt="Recommendation and backup path diagram: recommendations pass ad, blocklist, title, duration and other hard filters first, then optional AI ranking or strict selection, then a 7-day cold-start snapshot. S3 backup starts from an explicit allow-list, goes through ZIP, AES-256-GCM and immutable object keys, and on restore a planner previews and applies changes, rolling back from a log on failure.">
</p>

<p align="center"><sub><b>Figure 7</b> · Recommendation and backup paths. AI cannot bypass hard filters; backup only takes allow-listed data, and restore never writes existing settings before preview.</sub></p>

#### AI recommendation filter

AI sits after the existing hard filter: ads, blocklists, title regexes, publish time, duration, like ratio and follow exemptions still run in `RecommendFilter` first. AI only scores, ranks or folds candidates that already passed; **it cannot restore a removed item**.

- **Two modes**: `Preference ranking` only changes order, with high-confidence "show less" topics folded and recoverable from the status bar. `Strict selection` removes only content the model actually scored below threshold; unscored items stay. When the model is unavailable the status says "using local rules", not a fake strict mode.
- **Ranking**: semantic relevance, local profile / keywords, explicit more / less, freshness, Bilibili order and author preference; missing scores are not treated as zero — known components are renormalised. Exploration is about 20%; repeated adjacent authors get one neighbour penalty; soft constraints never override hard filters.
- **Request boundary**: dedicated Dio client, no Bilibili interceptors, no Cookie / CSRF / access key / device headers. HTTPS only by default; loopback or explicitly allowed private addresses may use HTTP; public HTTP is always rejected. Redirects are disabled so Authorization cannot be forwarded. The API key stays in platform secure storage.
- **Budget and degradation**: at most 20 candidates per batch, 2 batches per refresh, 100 requests per day by default; first-screen budget 2 s, then local rules. Background prefetch uses a longer timeout. Refresh itself does not call the model; it prefers prepared results.
- **Cold-start snapshot**: after each successful display, up to 40 visible + 20 folded card fields, AI scores / reasons / fold flags are written to Hive `localCache` under `aiFeedSnapshot`. Startup restores synchronously, so the first frame shows the previous feed instead of a skeleton. The snapshot is scoped by account, source and settings fingerprint, TTL 7 days; a mismatch is ignored. After a successful restore, startup does not auto-request recommendations; only pull-to-refresh or a missing / unusable snapshot requests upstream. A failed refresh keeps visible content.
- **Privacy**: enabling does not read history automatically; import is an explicit tap (last 30 days, max 200 items, archive only) and refuses a different account. Paused learning, anonymous / incognito and beginner mode block writes. Only content preferences are stored; no identity, health or political inference.

#### S3-compatible encrypted backup

This is a new path alongside the existing local ZIP / WebDAV entries; the old entries stay. Off by default, configured under Settings → S3-compatible backup.

- **Services**: AWS S3, Cloudflare R2, MinIO and other S3-compatible endpoints; optional path-style / virtual-hosted, prefix, region, timeout, auto-backup interval and retention count.
- **Backed up by default**: general settings, interface and theme, playback and danmaku preferences, recommendation filters, local blocklist, explicit AI preferences. **Opt-in, off by default**: inferred AI profile and feedback, search history, local comment history, playback progress, custom fonts.
- **Never backed up**: Bilibili account / Cookie / CSRF / access key / refresh token, AI API keys, S3 credentials, WebDAV passwords, recovery keys, private messages, cache / logs / downloaded media. Unknown new settings are excluded by default and must be added to the explicit allow-list in `BackupRegistry`.
- **Objects and encryption**: object key `<prefix>/v1/<backupSetId>/<deviceId>/<UTC time>-<snapshotId>.ppbackup`, immutable; upload uses `If-None-Match: *`, and a 412/409 triggers a read-back comparison instead of overwriting different content. There is no mutable `latest.json`. The outer layer is a `PPBK` header + AES-256-GCM ciphertext with a fresh nonce per encryption; the inner ZIP contains `manifest.json`, `data.json` and optional `font.bin`.
- **Recovery code**: a 256-bit random recovery key lives in platform secure storage by default; the recovery code looks like `PPB1-...` (Base32 + checksum). A new device with the same S3 config and code can decrypt snapshots for that keyId.
- **Restore**: download / decrypt / verify do not write existing settings. `RestorePlanner` previews category changes, skips and required restarts; a restore log is written before apply, and failures roll back from it. Restoring AI preferences forces `enabled=false`; it never turns external requests back on.
- **Verified to date**: about 44 tests pass across encrypt round-trip, wrong key, tampering, truncation, path traversal, archive versions, restore planning and rollback; MinIO List / Put / Get / Delete connectivity is verified. **Full backup to real S3 and restore from real S3 on device is not done**, and on-device Keychain access is not verified.

See [docs/ai-recommend-and-s3-backup.md](docs/ai-recommend-and-s3-backup.md) for wiring, ranking weights, cache keys, encryption format and restore semantics.

<p align="center">
  <img src="docs/images/readme/anime-episode-build.svg" width="100%" alt="Chapter banner: EPISODE 04 / BUILD; large 04 and Build; subtitle says turn should run into a reproducible command; a terminal window reading build --verify on the right.">
</p>

### 04 · Build — shared-video fixes and a reproducible build (repaired)

The Home feed shows videos shared by a chosen user through direct messages. Three real defects were fixed here, and the iOS tree and CI were reduced to one reproducible command.

| Defect | Fix | Evidence |
| --- | --- | --- |
| **Plain-text shares were dropped** | The chosen user sent `EN_MSG_TYPE_TEXT` with the video link in the body; the parser only accepted share cards. Added body extraction for `BV[0-9A-Za-z]{10}`, with the fallback limited to plain text so live / dynamics cards are not "revived" | 12 messages matched 0 → 11 |
| **Filter ran after deduplication** | The filter used to run after "keep the newest copy per bvid", so a reshare could displace the chosen user's copy and make items intermittently vanish. Filtering now runs first and is extracted into `foldForWanted()`, shared by production and tests | intermittent disappearance no longer reproduces |
| **Title shown as a URL** | The link occupied its own line and the title sat above it; the first version read the link line. Now prefer same-line non-URL text; if the line is only a link, walk upward to the nearest non-empty line and strip `1.` / `1、` / `1《` numbering. After load, `VideoHttp.videoIntro` fills in the real title and cover; a failed query keeps the original instead of dropping the item | title / cover tests pass |

The conversation scan window grew from 10 to at most 40, prioritizing the chosen user's conversation and stopping on a hit. Tests cover plain-text parsing, filter order and title / cover backfill; see [docs/home-shared-videos.md](docs/home-shared-videos.md).

- **iOS only**: Android / Windows / Linux / macOS runners removed; only resources or Flutter plugin registration skeletons remain. Use upstream for those platforms.
- **CI now tests**: `.github/workflows/ios.yml` runs `flutter test`, then builds, injects the AV1 decoder, verifies the artifact and packages the IPA. Previously it built without tests.
- **Build gate**: `tool/ios_av1_package.sh` is the single implementation shared by local builds and CI; `tool/verify_release_constraints.sh` checks bundle id, AV1 ABI, exports and debug markers; any drift fails the build.
- **Device-free regression**: `tool/full_regression.sh` chains script self-checks, unit tests, Release constraints, experiment-scaffold scan, HDR stream-selection gate and 4K exactness; failure exits non-zero.

This episode has no new screenshot; it speaks through logs and tests.

<a id="quick-start"></a>
## Quick start

- **Install directly**: download the IPA from [Releases](https://github.com/devzer0o0/BilibiliPlus/releases), sign / sideload with your own Apple Development certificate. No certificates, provisioning profiles or credentials are shipped.
- **Build from source**: Flutter 3.47.9, Xcode 27.x and an Apple Development certificate. Deployment target is iOS 15.0.
- **Just want the changes**: start with [Why this fork](#why-this-fork) and [Screenshots](#screenshots); every episode links to its design / evidence doc.

```bash
git clone https://github.com/devzer0o0/BilibiliPlus.git
cd BilibiliPlus
flutter pub get

# Signed Release: inject AV1 VideoToolbox, verify its identity, re-sign
PILIPLUS_DEVELOPMENT_TEAM=XXXXXXXXXX tool/ios_build.sh release
```

More verification and CI details: [Build and verify](#build-and-verify).

<a id="repository-layout"></a>
## Repository layout

| Path | Purpose |
| --- | --- |
| `lib/` | Flutter pages, playback facade, recommendation filtering and backup logic |
| `ios/` | Runner, native liquid-glass bridge, AVPlayerLayer, launch assets |
| `tool/` | AV1 packaging / verification, Release constraints, regression scripts, icon pipeline |
| `test/` | Unit / widget tests, including shared videos and backup restore |
| `docs/` | Design, evidence, acceptance records and boundary notes |
| `design/app_icon/` | Icon masters and derivatives |
| `.github/workflows/ios.yml` | iOS CI: test, build, inject decoder, verify artifact, package IPA |

<a id="build-and-verify"></a>
## Build and verify

Requires **Flutter 3.47.9**, **Xcode 27.x** and an Apple Development certificate. Deployment target is iOS 15.0.

```bash
# Verify an artifact only: decoder identity, exports, dependencies, debug leftovers
tool/verify_release_constraints.sh build/ios/iphoneos/Runner.app

# Six-stage regression that runs without a device
tool/full_regression.sh
```

- `tool/ios_av1_package.sh` is the only implementation shared by local builds and CI; `tool/verify_release_constraints.sh` also checks bundle id, AV1 ABI, exports and debug markers. Any drift fails the build.
- `tool/full_regression.sh` chains script self-checks, unit tests, Release constraints, experiment-scaffold scan, HDR stream-selection gate and 4K exactness; failure exits non-zero.
- CI in `.github/workflows/ios.yml` runs `flutter test`, builds, injects the AV1 decoder, verifies the artifact and packages the IPA. The repository used to build without tests; this fork adds that step.
- Build artifacts, certificates, profiles, API keys, S3 credentials and recovery codes never enter the repository.

<a id="compatibility"></a>
## Compatibility and status

- **iOS only**: Android / Windows / Linux / macOS runners removed; only resources or Flutter plugin registration skeletons remain. Use upstream PiliPlus for those platforms. Device validation revolves around iPhone Air; simulator and automated evidence are labelled separately.
- **OS**: iOS 15.0+. Native liquid glass needs iOS 26+ and falls back on older versions; the native HDR path works from iOS 15; AV1 hardware decode depends on the SoC and source.
- **Primary target**: iPhone Air (iPhone18,4), tested on iOS 27.3; bundle id remains `com.example.pilipalax`, display name `bilibili+`.
- **Version**: `0.0.6+7`.

**This table defines what this README does not claim; it is not a decorative backlog:**

| Item | Status | Reason |
| --- | --- | --- |
| Whether tone mapping fixes HDR green screens on the VideoToolbox path | ⛔ | Not reproducible on simulator; needs frame-by-frame comparison with device HDR sources |
| Whether HDR10 is actually composited to the screen; HLG / Dolby Vision sources | ⛔ | Device only proves the native path presents a picture, not HDR luminance presentation; the latter two have no sources |
| Dark liquid glass, VoiceOver, Reduce Transparency / Increase Contrast, frame rate | ⛔ | Dark screenshots exist, but material and accessibility are not individually accepted; xctrace cannot attach to this device |
| Device home-screen icon and launch-screen captures | ⛔ | The launch screen disappears faster than capture; only snapshot rebuild and simulator captures exist |
| Native PiP, audio-only, native screenshots | ▶️ | Code and unit tests exist; neither device nor simulator interaction has been run |
| Real AI model service | ⛔ | No user credentials; only test doubles and local services |
| Full S3 backup / restore end-to-end | ▶️ | MinIO connectivity and object round-trip verified; full path not accepted on device |
| On-device Keychain access | ⛔ | Not verified |
| macOS / Windows / Linux / Android | ⛔ | This fork does not build those platforms |

### Inherited from upstream (not individually regression-tested)

This fork does not rewrite the daily client. These still ship:

- Recommendations / trending / partitions, search, video details, comments and comment notes
- Danmaku / subtitles / speed / quality and audio selection / resume / super-resolution
- Dynamics / live / messages / favourites / history / watch later / offline cache
- Multi-account, WebDAV, SponsorBlock, advanced danmaku, animated video clips / Live Photos

They follow upstream implementations. This fork concentrates on playback, the tab bar, the icon, AI recommendation filtering, S3 backup and the Home shared-video section. The complete feature list is upstream's README.

<a id="roadmap"></a>
## Roadmap

This is a verification roadmap, not feature marketing. Completed items have device or automated evidence; open items state what is missing.

- [x] AV1 4K60 hardware decode with build-time decoder identity checks
- [x] Native liquid-glass tab bar + Flutter fallback
- [x] Reproducible gold TV icon and launch screen
- [x] Optional AI filter + 7-day cold-start snapshot
- [x] S3-compatible encrypted backup + recovery code
- [ ] HDR10 screen composition and green-screen tone mapping
- [ ] HLG / Dolby Vision source measurements
- [ ] Native PiP / audio-only / screenshot device interaction
- [ ] Full S3 backup / restore end-to-end on device
- [ ] Dark liquid glass, VoiceOver, Reduce Transparency, frame rate
- [ ] Feature-by-feature regression of inherited daily features

<a id="contributing"></a>
## Contributing

- Issues and PRs are welcome, but this is a personal fork: general upstream issues / features belong in [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus).
- Keep changes small and explain what changed, why, and how it was verified. Playback PRs should include device model, iOS version, build identity and `hwdec-current` logs; UI PRs should include before / after captures; backup PRs should run the relevant tests.
- Do not commit certificates, provisioning profiles, API keys, S3 credentials, recovery codes or personal data.
- By submitting, you agree to release your contribution under GPL-3.0.

<a id="docs"></a>
## Docs

| Document | Contents |
| --- | --- |
| [iOS native playback architecture](docs/ios-native-playback-architecture.md) | Dual backends, capability contract, output sizing, state machine |
| [AV1 hardware-decode evidence](docs/ios-av1-hardware-evidence-2026-11-05.md) | Test sources, build identity, untested range |
| [Liquid-glass tab bar](docs/liquid-glass-bottom-bar.md) | Native bridge, fallback, accessibility, acceptance steps |
| [Icon and launch screen](docs/app-icon-and-launch-screen.md) | Design source, material parameters, asset list, acceptance |
| [AI recommendations and S3 backup](docs/ai-recommend-and-s3-backup.md) | Ranking weights, cache keys, encryption format, restore semantics |
| [Home shared videos](docs/home-shared-videos.md) | Plain-text parsing, filter order, title backfill |

<a id="license"></a>
## License and acknowledgements

Code is released under **GPL-3.0**, see [LICENSE](LICENSE). Bilibili+ is not affiliated with Bilibili; the bilibili name and marks belong to their owners.

> This project is for learning and testing only. Delete it within 24 hours of download. APIs are collected from official sites; no cracking content is provided.

- Upstream and predecessors: [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus), [PiliPalaX](https://github.com/orz12/PiliPalaX), [pilipala](https://github.com/guozhigq/pilipala)
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [media-kit](https://github.com/media-kit/media-kit), [melodink-libmpv-darwin-build](https://github.com/gungun974/melodink-libmpv-darwin-build)
- [FFmpeg](https://ffmpeg.org/), [mpv](https://mpv.io/), [dio](https://pub.dev/packages/dio)
- Multi-account support: [My-Responsitories](https://github.com/My-Responsitories)

<p align="center">
  <img src="docs/images/readme/anime-divider.svg" width="100%" alt="Divider illustration: a pink diamond play button between dark dashes, with cyan and pink accents; the caption reads TO BE CONTINUED.">
</p>

<p align="center">
  <a href="https://github.com/devzer0o0/BilibiliPlus/releases">
    <img src="docs/images/readme/anime-cta.svg" width="100%" alt="End card: FIN / NEXT EPISODE; the TV girl stands on a pink moon; text asks the reader to star the repo to follow the next episode; Star on GitHub and Download Release buttons below.">
  </a>
</p>

<p align="center"><sub>If this episode was worth watching, star the repo. The next episode keeps fixing playback on iPhone Air.</sub></p>
