<div align="center">
  <h1>Bilibili+</h1>
  <p><b>A third-party Bilibili client that took the iPhone Air playback path apart, fixed it, and kept the evidence</b></p>
  <p>An iOS fork of <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> · GPL-3.0 · 0.0.4+5</p>
  <p><a href="https://github.com/devzer0o0/BilibiliPlus/releases">Downloads</a> · <a href="README.md">中文</a></p>
</div>

> This README describes only what **this repository actually changed and can back with evidence**. Features inherited from upstream are not repeated here, and anything unverified is marked as unverified instead of "should work".

## What this fork changed

Upstream PiliPlus is a complete Bilibili client. This fork focuses on the iOS playback path, but it is not only playback:

| Area | Upstream | This fork | Status |
| --- | --- | --- | --- |
| Playback backends | mpv only | mpv + AVPlayerLayer; HDR10 / 10-bit take the native path, Dolby Vision uses the same route | ✅ HDR10 on device |
| AV1 hardware decode | stock FFmpeg has no AV1 VideoToolbox | injects `av1_videotoolbox` and verifies UUID, exports and dependencies at build time | ✅ 4K60 on device |
| Capability reporting | a successful request implies support | system / build / backend / session are four separate answers; refusals carry a reason | ✅ automation + device |
| Output sizing | texture allocated at source resolution | allocated at the fitted physical size, 120 ms debounce | ✅ tests + device |
| Tab bar | Flutter material | native iOS 26 `UIGlassEffect` capsule, with a fallback | ✅ material / taps on device |
| Icon / launch screen | recolor of the old art | SDF-redrawn gold TV; deterministic master-to-asset pipeline | ✅ assets + device install |
| Recommendation feed | rule-based filters | optional AI semantic filtering / ranking with a local profile | 🟡 tests / build |
| Backup | local / WebDAV | S3-compatible + AES-256-GCM + recovery code | 🟡 logic + MinIO connection |
| Shared-video strip | — | three fixes: text shares, filter order, titles | ✅ logs + tests |
| Platforms | iOS / Android / Windows / Linux | iOS only | ✅ tree / CI |

Legend: ✅ device or artefact evidence; 🟡 automation / simulator / partial service; ▶️ implemented but never run on a device; ⛔ unverified. The rest of this README uses that standard.

## Playback: four separate facts behind "AV1 support"

"The chip supports AV1" does not mean "this app is decoding AV1 in hardware". This fork requires all four:

1. **the chip can** — VideoToolbox reports AV1 support;
2. **the build can** — the FFmpeg shipped inside the app registers `av1_videotoolbox`;
3. **the rendition is chosen correctly** — an AV1 variant that can be decoded, without overriding your codec preference;
4. **the session really is decoding in hardware** — the player reports `hwdec-current=videotoolbox` per frame, and the frame format is `CVPixelBuffer`.

When (2) was false, the app still claimed AV1 was available and decoded 3840×2160 on the CPU: the symptoms were heat and dropped frames, with nothing useful in the log. Today `tool/ios_av1_package.sh` replaces `Avcodec.framework` and then checks:

- **Mach-O UUID** — re-signing cannot change it, so it separates "our decoder" from the pod's;
- **the complete exported symbol set** — compared one by one, not counted (ABI 61.3.100, 359 exports);
- **dependent libraries** — exactly the set the ABI expects, no more and no less;
- **device / simulator slice** — a device binary never ends up in a simulator bundle.

If any check fails, the build fails. **No decoder, no build** — there is no silent downgrade path.

### Capabilities and measurements

| Capability | Path | Status |
| --- | --- | --- |
| AV1 8-bit SDR | mpv + FFmpeg + VideoToolbox | ✅ measured in hardware on device (4K60 / 4K30) |
| HEVC / H.264 | mpv + VideoToolbox | ✅ measured, including a 4K60 regression run |
| HDR10 | AVPlayerLayer (native HDR passthrough) | ✅ device selected a Main10 / PQ variant and rendered; HDR compositing on screen not verified |
| HLG | AVPlayerLayer | ▶️ route wired; no HLG source this round |
| Dolby Vision | AVPlayerLayer, RPU applied by the system | ▶️ route wired; no `dvh1` rendition in sampled titles, not measured |
| AV1 10-bit SDR | AVPlayerLayer | ✅ device screenshots show the expected picture, no green cast; hardware state recorded as `unavailable` |

**Measured on iPhone Air (iPhone18,4, iOS 27.3, diagnostic build before the signed release):**

| Source | Rendition | Samples | Hardware |
| --- | --- | --- | --- |
| AV1 | 3840×2160 @60fps `av01.0.13M.08` | 31 | 31 |
| AV1 | 4096×2160 @59.994fps `av01.0.13M.08` | 32 | 32 |
| AV1 | 3840×2024 @59.932fps `av01.0.13M.08` | 32 | 32 |
| AV1 | 3840×2160 @29.97fps `av01.0.13M.08` | 2 | 2 |
| H.264 | 3840×2160 @60fps (regression) | 13 | 13 |

The evidence is not "we asked for `hwdec=videotoolbox`". It is the per-frame `hwdec-current=videotoolbox` the player reports, plus libmpv's `vd: Decoder format … videotoolbox[nv12]`, which says the frames arriving are VideoToolbox `CVPixelBuffer`s rather than CPU frames uploaded afterwards.

Full evidence, build identity and unmeasured cases: [docs/ios-av1-hardware-evidence-2026-11-05.md](docs/ios-av1-hardware-evidence-2026-11-05.md).

### Two backends, one timeline

- **8-bit SDR goes through mpv**: danmaku, subtitles, speed, super resolution and WebP capture all stay available.
- **HDR10 / HLG / Dolby Vision / AV1 10-bit go through AVPlayerLayer**: real EDR passthrough instead of HDR squeezed into SDR and presented as if it were not; per-format acceptance is in the table above.
- A session has exactly one active backend. On a source switch the old backend is disposed first; there are never two backends running with one merely hidden.
- Position, duration and playback state come from one snapshot; the media generation is allocated once by the facade, so rotation, fullscreen and control visibility never create a new generation.
- Features the native path cannot provide (audio-track switching, animated screenshots, super resolution, player volume, AirPlay video) go through `PlaybackCapabilities` + `PlaybackRoute` and return a Chinese reason keyed by the `preparing / native / disposed / none` state instead of failing silently.

Architecture and evidence levels: [docs/ios-native-playback-architecture.md](docs/ios-native-playback-architecture.md).

### Output follows the screen, not the source

A 4K source no longer makes Flutter allocate a 3840×2160 texture. The player sizes its output to the fitted area in physical pixels: on iPhone Air a full-width 16:9 video settles around **1260×709**. DPR, BoxFit crop/stretch, explicit aspect ratios, rotation, window changes and pinch zoom all participate, capped at the source size. A 120 ms debounce plus serialised native calls avoids rebuilding the output on every drag; Anime4K or software decoding keeps the full source output.

The logic lives in the shared player layer and covers media-kit's iOS, macOS, Windows and Linux backends (this fork only builds iOS). Android does not use it: changing its surface size re-initialises the mpv output. On Windows every applied resize flashes for at least one frame; that is a known cost of the pinned plugin, accepted in exchange for a much smaller output buffer on 4K sources.

## The liquid glass tab bar (redesigned here)

The mobile tab bar follows the liquid-glass capsule in the reference recording: three entries (Home / Dynamics / Profile), no labels, centred icons, and a light capsule behind the selected item. Page switching, scroll-to-top refresh, the unread badge, the avatar and the safe area are still owned by the existing controllers.

<p align="center">
  <img src="docs/images/liquid-glass/device-light-home.jpg" width="45%" alt="iPhone Air light-mode Home: a search field and an AI status bar reading 'AI · strict selection · currently using local rules' at the top, and a native liquid-glass capsule with three label-free entries at the bottom, with Home selected.">
  <img src="docs/images/liquid-glass/device-light-mine.jpg" width="45%" alt="iPhone Air light-mode Profile: the selected block of the liquid-glass capsule sits on the round avatar entry on the right; the page shows account details, following counts and favourites.">
</p>

*Figure 1 (left): Home. The capsule is not a screenshot pasted on top; it is iOS 26 `UIGlassEffect` sampling the content underneath as it scrolls. Figure 2 (right): Profile, with the selection on the avatar entry. Both are iPhone Air device captures.*

- **iOS 26 and later**: `UIVisualEffectView` + `UIGlassEffect(style: .clear)`, `isInteractive = true`, capsule 52 pt high, at most 360 pt wide, 30 pt side margins, 26 pt corner radius; selected block 82×36 at 18 pt radius. Flutter owns pages, business state, outer layout and accessibility labels; the native view owns the material, the three buttons, the selection, the badge and hit testing.
- **iOS below 26 / non-iOS / capability query failure / platform view not created within 3 s**: the Flutter fallback (BackdropFilter + shader) runs, logging `[native-glass] Flutter fallback: <reason>`. A device that supports the native path is not allowed to fall back silently and still be accepted as native.
- **Accessibility and preferences**: VoiceOver labels, selected state and unread count have corresponding fields; Reduce Transparency, Increase Contrast and Reduce Motion each have a path. When the keyboard appears, the bar leaves layout, hit testing and semantics.
- **Verified**: device log `material=UIGlassEffect.clear`, taps on all three entries, capsule luminance changing with the content while scrolling (111→235→252→118), capsule disappearing on the video detail page and returning on back.
- **Not verified**: dark mode on a device, the feel of the press animation, VoiceOver, Reduce Transparency / Increase Contrast, keyboard, rotation, foreground/background restore, memory and frame rate.

Protocol and device acceptance steps: [docs/liquid-glass-bottom-bar.md](docs/liquid-glass-bottom-bar.md).

## The gold TV icon and launch screen (redesigned here)

The previous icon was the official bilibili international icon with a recolour (gold background, white wordmark, globe in the corner). This one is redrawn from the **gold TV** at the centre of Bilibili's one-million-follower medal: a wide rounded-rectangle body, two antennas, a recessed screen frame, and an embossed face. No wordmark, globe, feet, knobs or text.

<p align="center">
  <img src="docs/images/app-icon-before-after.png" width="100%" alt="Icon before and after: the old icon is a gold background with a white bilibili wordmark and a globe badge; the new icon is a gold TV on a black background with two antennas, a recessed screen frame, and embossed slanted eyes and an omega-shaped mouth.">
</p>

*Figure 3: this is not a recolour. Left is the previous icon; right is the version redrawn from the medal's TV, with metal reflections, bevels and screen-frame shadows generated from geometry and lighting.*

- **Master**: `design/app_icon/master-2048.png` (2048²) is the single source of truth; the 1024 icon and the transparent TV are derived from it. The master is never overwritten by a derived file.
- **Generation**: `tool/app_icon/render_icon.py` uses SDF ray marching (body / antennas / eyes), a front-surface height field for the screen and lips, a procedural studio environment, GGX and ACES. No image-generation model is involved; every shape parameter is an editable constant.
- **Deterministic pipeline**: `tool/app_icon/build_assets.py` re-samples the three masters to produce every iOS AppIcon size, the launch image, logo, ICO and Android foreground. ICC timestamps are fixed, so identical input produces byte-identical output (two full runs matched by SHA-256).
- **Acceptance**: 25 AppIcon references over 21 unique files, 20–1024 px, all dimensions matching; the 1024 icon is RGB, alpha-free and sRGB; at 60 px the TV and antennas are still recognisable; `actool` compiles the asset catalogue.

The launch screen stays black with the transparent gold TV centred. iOS caches a launch-storyboard snapshot, so replacing only the image can keep showing the old one. The resource was renamed from `LaunchImage` to **`LaunchImageGoldTV`** and the build number raised to **0.0.3+4**; after an over-install all four snapshots under `Library/SplashBoard` were rebuilt and the old one disappeared.

<p align="center">
  <img src="docs/images/app-icon-simulator-launch.png" width="34%" alt="Simulator cold-launch capture: a gold TV on a pure black background, with no rounded-square plate behind it, labelled 0.0.3+4 at the bottom.">
</p>

*Figure 4: the cold-launch screen. This is a simulator capture, not device launch-screen evidence; the device-side evidence is the SplashBoard snapshot rebuild and `Assets.car` containing only `LaunchImageGoldTV`.*

Design source, material parameters and acceptance records: [docs/app-icon-and-launch-screen.md](docs/app-icon-and-launch-screen.md).

## AI recommendation filtering (new here)

AI is an **optional layer**, off by default. It runs after the existing hard filters: ads, blocklists, title regexes, publish time, duration, like ratio and following exemptions are still applied by `RecommendFilter` first. AI only scores, ranks or folds candidates that already passed; it **cannot bring a removed item back**.

- **Two modes**: `Preference ranking` only changes order, and high-confidence "less of this" topics can be folded with a status-bar entry to restore them. `Strict selection` removes only items the model actually scored below the threshold; unscored items stay. When the model is unavailable the status says "currently using local rules" instead of pretending strict selection is active.
- **Ranking**: semantic relevance, local profile/keywords, explicit more/less signals, freshness, Bilibili's original order and author preference. Missing scores are not treated as zero; only the known components are renormalised. Exploration is about 20%, and an author appearing twice in a row gets one adjacent down-weight, but these soft constraints never override hard filters.
- **Request boundary**: a separate Dio client with no Bilibili interceptors, cookies, CSRF, access key or device headers. HTTPS is the default; loopback or explicitly allowed private-network addresses may use HTTP, while public HTTP is always rejected. Redirects are disabled so Authorization cannot be forwarded. The API key goes only into platform secure storage.
- **Budget and fallback**: at most 20 candidates per batch, 2 batches per refresh, 100 requests per day by default; a 2 s first-screen budget falls back to local rules, while background prefetch uses a longer timeout. A refresh itself does not call the model; it reads the result already prepared.
- **Cold-start snapshot**: after every successful presentation, up to 40 visible and 20 folded cards (card fields, AI score, reason, fold/exploration markers) are written to Hive `localCache` under `aiFeedSnapshot` and restored synchronously at launch, so the first frame shows the previous feed instead of a skeleton. The snapshot is scoped by account, source and settings fingerprint, with a 7-day TTL; mismatches are ignored. After a successful restore, startup **does not auto-request the feed**: the page stays on the snapshot and reports "using cache"; only a pull-to-refresh or a missing/unusable snapshot goes upstream, and a failed or timed-out refresh keeps the visible content.
- **Privacy**: enabling the feature never reads history automatically. Import is an explicit tap (last 30 days, at most 200 items, archive only), is refused when the history account differs, and is blocked by paused learning, anonymous/incognito mode or beginner mode. Only content preferences are stored; no identity, health or political attributes are inferred.

Implementation, ranking weights, cache keys, fallback semantics and verification: [docs/ai-recommend-and-s3-backup.md](docs/ai-recommend-and-s3-backup.md).

## S3-compatible encrypted backup (new here)

This is a new path parallel to the existing local ZIP / WebDAV entries, which are unchanged. It is off by default and configured under Settings → S3-compatible backup.

- **Services**: AWS S3, Cloudflare R2, MinIO and other S3-compatible endpoints; optional path-style / virtual-hosted addressing, Prefix, Region, timeout, auto-backup interval and retention count.
- **Backed up by default**: general settings, UI and theme, playback and danmaku preferences, recommendation filter rules, local blocklist, explicit AI preferences. **Opt-in and off by default**: inferred AI profile and feedback, search history, local comment history, playback progress, custom fonts.
- **Never backed up**: Bilibili account / cookies / CSRF / access key / refresh token, AI API key, S3 credentials, WebDAV password, recovery key, private messages, caches / logs / downloaded media. Unknown new settings are excluded by default and must be added to the explicit `BackupRegistry` allowlist.
- **Objects and encryption**: the key is `<prefix>/v1/<backupSetId>/<deviceId>/<UTC time>-<snapshotId>.ppbackup`, immutable; uploads use `If-None-Match: *` and a 412/409 triggers a read-back comparison rather than overwriting different content. There is no mutable `latest.json`. The outer format is a `PPBK` header plus AES-256-GCM ciphertext with a fresh nonce per encryption; the inner ZIP contains `manifest.json`, `data.json` and an optional `font.bin`.
- **Recovery code**: a random 256-bit recovery key lives in platform secure storage by default; the code looks like `PPB1-...` (Base32 plus a checksum byte), so a new device with the same S3 configuration and recovery code can decrypt the matching keyId.
- **Restore**: download / decrypt / verify writes nothing to existing settings. `RestorePlanner` first previews category changes, skipped items and whether a restart is needed; a restore log is written before applying, and a failure rolls back to the old values in that log. Restoring AI preferences forces `enabled=false` and never turns external requests on by itself.
- **How far verification goes**: about 44 tests cover encryption round-trips, wrong keys, tampering, truncation, path traversal, archive versions, restore planning and rollback. MinIO List / Put / Get / Delete connection tests passed. **A full upload to real S3 and an end-to-end restore from real S3 have not been accepted on a device**, and neither has Keychain access on a device.

## Home "shared with me" strip (fixed here)

The top of the Home recommendation feed shows videos a specific user shared by private message. Three real defects were fixed:

1. **Text-only shares were dropped entirely**: the user sends `EN_MSG_TYPE_TEXT` messages with video links in the body, while the parser accepted only share cards, so 12 messages produced 0 results. A body scan for `BV[0-9A-Za-z]{10}` was added, restricted to text messages so live/dynamic cards rejected by the card rules cannot come back; parsed results went from 0 to 11.
2. **Deduplication ran before filtering**: the sender filter sat after "keep the newest copy per bvid", so anyone forwarding the same video later could displace the wanted user's copy and make it disappear intermittently. Filtering now runs first, extracted into `foldForWanted()` shared by production code and tests.
3. **Titles showed the URL**: the link occupies its own line and the title is on the line above, but the first version took the line containing the bvid. It now prefers non-URL text on the same line, walks up to the nearest non-empty line when the line is only a link, and strips list prefixes such as `1.` / `1、` / `1《`. After loading, `VideoHttp.videoIntro` fills the real title and cover; a failed lookup keeps the original value instead of dropping the item.

The session scan window grew from 10 to at most 40 sessions and reads the wanted user's session first, stopping on a hit. Tests cover text parsing, filter order and title/cover completion; details in [docs/home-shared-videos.md](docs/home-shared-videos.md).

## Build and verify

Requires **Flutter 3.47.9**, **Xcode 27.x** and an Apple Development certificate. The iOS deployment target is 15.0.

~~~bash
# Signed release: injects the AV1 VideoToolbox decoder, verifies it, re-signs
PILIPLUS_DEVELOPMENT_TEAM=XXXXXXXXXX tool/ios_build.sh release

# Verify an artefact: decoder identity, export set, dependencies, diagnostics
tool/verify_release_constraints.sh build/ios/iphoneos/Runner.app

# Six-stage regression that needs no device
tool/full_regression.sh
~~~

`tool/ios_av1_package.sh` is the single implementation shared by every build entry point (local scripts and CI). `tool/verify_release_constraints.sh` also checks the bundle id, AV1 ABI, exported symbols and debug markers; any drift fails the build. `tool/full_regression.sh` chains script self-checks, the unit suite, release constraints, an experiment-scaffolding scan, the HDR rendition gate and 4K exactness, exiting non-zero on failure.

CI in `.github/workflows/ios.yml` runs `flutter test`, then builds, injects the AV1 decoder, verifies the bundle and packages an IPA. The repository used to build without ever running the tests; this fork added that step.

## Platform, version and scope

- **iOS only**: this fork removed the Android / Windows / Linux / macOS runners; only resource or Flutter plugin-registration skeletons remain. Use upstream PiliPlus for those platforms. All verification is built around iPhone Air — that is a deliberate trade-off.
- **OS**: iOS 15.0+; native liquid glass needs iOS 26+ and falls back automatically below that; the native HDR path is available from iOS 15; AV1 hardware decode depends on the chip and the source.
- **Primary target**: iPhone Air (iPhone18,4), measured on iOS 27.3. Bundle ID remains `com.example.pilipalax`, display name `bilibili+`.
- **Inherited from upstream**: dynamics, live, private messages, favourites, multiple accounts, WebDAV, SponsorBlock and advanced danmaku are still present, but this fork has not regressed each one; they are not claimed as "verified" here.
- **Version**: `0.0.4+5`.

## Everyday features (inherited, not regressed one by one)

This fork did not rewrite the everyday client. These still ship:

- Recommendations / trending / partitions, search, video detail, comments and comment notes
- Danmaku, subtitles, speed, quality and audio selection, resume, super resolution
- Dynamics, live, private messages, favourites, history, watch later, offline cache
- Multiple accounts, WebDAV, SponsorBlock, advanced danmaku, WebP / Live Photo capture

They keep the upstream implementation; this fork's changes are concentrated in playback, the tab bar, the icon, AI recommendation filtering, S3 backup and the shared-video strip. See upstream for the complete feature list.

## What is not verified

This table is the boundary of the README, not decoration on a to-do list:

| Item | Status | Why |
| --- | --- | --- |
| Whether tone mapping cures the HDR green screen on the VideoToolbox path | ⛔ | The simulator cannot reproduce it; a device HDR title needs frame-by-frame comparison |
| Whether HDR10 is actually composited on screen; HLG / Dolby Vision sources | ⛔ | Device evidence proves the native path renders, not that the display presents HDR; the other two formats had no source |
| Dark liquid glass, VoiceOver, Reduce Transparency / Increase Contrast, frame rate | ⛔ | Accessibility settings were not changed on the device; xctrace could not attach to it |
| Device screenshots of the home-screen icon and launch screen | ⛔ | The launch screen disappears faster than the capture; only snapshot rebuilds and simulator captures exist |
| Native PiP, audio-only, native screenshot | ▶️ | Code and unit tests exist; no device or simulator interaction has been run |
| Real AI model service | ⛔ | No user credentials; only test doubles and a local service |
| Full S3 backup / restore end to end | ▶️ | MinIO connection and object round-trips passed; the full path has not been accepted on a device |
| macOS / Windows / Linux / Android | ⛔ | This fork does not build them |

## Download and license

Download from [Releases](https://github.com/devzer0o0/BilibiliPlus/releases), or clone the repository and build as above. iOS builds need your own signing identity; the repository ships no certificates, provisioning profiles or credentials.

The code is released under **GPL-3.0**. This project is for learning and testing only; delete it within 24 hours of download. All APIs are collected from official sources, and no cracking content is provided.

## Acknowledgements

- Upstream and predecessors: [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus), [PiliPalaX](https://github.com/orz12/PiliPalaX), [pilipala](https://github.com/guozhigq/pilipala)
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [media-kit](https://github.com/media-kit/media-kit), [melodink-libmpv-darwin-build](https://github.com/gungun974/melodink-libmpv-darwin-build)
- [FFmpeg](https://ffmpeg.org/), [mpv](https://mpv.io/), [dio](https://pub.dev/packages/dio)
- Multi-account support: [My-Responsitories](https://github.com/My-Responsitories)
