# Catalogue (pgc/pugv) play-url envelopes

Probed against the live API on 2026-11-03 with a 大会员 account.
Episode used: `ep_id=323085` (名侦探柯南 中配).

## The two endpoints do not share a shape

| Role | Constant | Path | Envelope |
| --- | --- | --- | --- |
| primary | `Api.ogvUrl` | `/pgc/player/web/playurl` | `data{...}` |
| fallback | `Api.pgcUrl` | `/pgc/player/web/v2/playurl` | `result{...}` |

Both carry the play model under a `video_info` key, but under different
parents. `VideoHttp.videoUrl` therefore reads:

```dart
// primary, when the response has no DRM marker
data = PlayUrlModel.fromJson(res.data['data']['video_info']);

// fallback after a DRM retry
data = PlayUrlModel.fromJson(res.data['result']['video_info']);
```

Swapping the parents yields an empty `dash`, which surfaces as "resource not
found" for paid content rather than as a parsing error.

## How the DRM retry is triggered

The primary ogv response omits `video_info` and sets `arc.is_drm` beside it:

```json
{"data": {"arc": {"is_drm": true}, "video_info": null}}
```

That combination makes `videoUrl` re-enter itself with `fallback: true`.
The recursion terminates because the primary branch is guarded with
`case .pgc || .pugv when !fallback`, so the retry can never loop.

## Verified live response keys

```text
primary  /pgc/player/web/playurl      data   -> (empty for this account)
fallback /pgc/player/web/v2/playurl   result -> exp_info, play_check,
                                                 play_view_business_info,
                                                 video_info, view_info
```

Tests covering this live in `test/models/pgc_envelope_test.dart`.