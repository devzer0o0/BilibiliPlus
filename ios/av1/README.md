# AV1 VideoToolbox Avcodec

This directory contains an FFmpeg 7.0.2 `Avcodec` binary for iOS arm64 with
the upstream AV1 VideoToolbox backport applied:

- Upstream commit: `f9c5c5358cfef3847674c6f3b3ded9611ebc5647`
- Patch: [`ffmpeg-7.0.2-av1-vt-backport.patch`](ffmpeg-7.0.2-av1-vt-backport.patch)
- ABI: `61.3.100`, same as the stock PiliPlus `Avcodec.framework`
- Exports: the same 359 symbols as the stock framework
- Minimum iOS: 15.0

Only the executable inside `Avcodec.framework` is replaced. `Mpv`, `Avutil`,
`Swresample`, `Dav1d`, and the rest of the application remain untouched.

This is a modified LGPL FFmpeg build; see `FFmpeg-LGPL-2.1.txt` and the patch
for corresponding source. The binary was built from FFmpeg 7.0.2, not from the
PiliPlus repository.

Use `tool/inject_ios_avcodec.sh` after an Xcode-signed build to replace and
re-sign the framework. Do not run it before all other embedded frameworks are
signed.
