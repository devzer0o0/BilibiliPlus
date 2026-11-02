# Catalogue (pgc/pugv) play-url envelopes

Probed against the live API on 2026-11-03 with a 大会员 account.
Episode used: `ep_id=733316` (凡人修仙传 season 28747).

## The endpoints

| Role | Constant | Path | Envelope |
| --- | --- | --- | --- |
| primary | `Api.ogvUrl` | `/ogv/player/playview` | `data{...}` |
| fallback | `Api.pgcUrl` | `/pgc/player/web/v2/playurl` | `result{...}` |
| pugv fallback | `Api.pugvUrl` | `/pugv/player/web/playurl` | `result{...}` |

> Correction: an earlier revision of this file claimed the primary was
> `/pgc/player/web/playurl`. That is wrong. The app's primary is
> `/ogv/player/playview`, confirmed from the request line in the simulator log:
>
> ```text
> https://api.bilibili.com/ogv/player/playview?bvid=...&ep_id=733316&qn=127&fnval=4048...
> ```

## Primary envelope (verified)

```text
data -> arc, exp_info, play_video_type, plugins, supplement,
        user_status, video_extra, video_info, watch_progress
```

`VideoHttp.videoUrl` reads exactly `data['video_info']`, `data['watch_progress']`
and `data['arc']['is_drm']`, so the primary branch matches the payload.

## Fallback envelope (verified)

```text
result -> exp_info, play_check, play_view_business_info, video_info, view_info
```

The retry branch reads `result['video_info']`, which also matches.

## How the DRM retry is triggered

The primary response omits `video_info` and sets `arc.is_drm` beside it:

```json
{"data": {"arc": {"is_drm": true}, "video_info": null}}
```

That makes `videoUrl` re-enter itself with `fallback: true`. It cannot loop
because the primary branch is guarded with
`case .pgc || .pugv when !fallback`.

## Quality ids: 122 is plain 4K, not HDR

The simulator logged `picked=122` for this episode, an id the `VideoQuality`
enum does not declare. The live payload settles what it is:

| id | HEVC profile | Bit depth | Meaning |
| --- | --- | --- | --- |
| 125 | `hvc1.2.4.L153.90` | **10-bit** | HDR 真彩 |
| 122 | `hvc1.1.6.L153.90` | 8-bit | plain 4K, no HDR |
| 120 | `hvc1.1.6.L153.90` | 8-bit | 4K 超高清 |

In HEVC, `hvc1.2.4` is Main10 and `hvc1.1.6` is Main. So 122 is an 8-bit
3840x2160 rendition and cannot reproduce the green screen. The earlier worry
that an unknown id could bypass the HDR gate does not apply here.

## The gate also checks the codec profile

The id blocklist only knows today's rungs, so the player additionally inspects
the codec string:

- `VideoUtils.isTenBitCodec` - HEVC `hvc1.2.4`/`hev1.2.4` is Main10; for
  `av01.` the fourth field is the bit depth
- `VideoUtils.isSupportedVideoStream` - combines the id check with the
  bit-depth check
- `VideoUtils.selectVideoVariant` - when several variants share a quality id it
  will not pick a 10-bit one, including in the last-resort fallback that used to
  return `variants.first`

With the switch closed a future 10-bit rung under an unknown id is now skipped
instead of played. Ordinary 4K is unaffected: 122 and 120 are `hvc1.1.6`
(8-bit) and still play.

Verified in the simulator after the change: `prefer=120` still yields
`picked=120 codec=AVC`, and `prefer=125` with tone mapping off still degrades
to 120.

`fromCode` handles an unknown id safely by falling back to
`fromId(code, code.toString())`.

## Tests

- `test/models/pgc_envelope_test.dart` - envelope shapes
- `test/models/video_quality_code_test.dart` - unknown id handling
- `test/utils/video_stream_gate_test.dart` - codec-profile gate