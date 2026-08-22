> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

# Apple Route Capability Matrix

Snapshot date: 2026-07-24 (SiloPlayer AirPlay hardware validation;
SiloPlayer loopback-primary Stages 0–4 validated 2026-07-03;
previous snapshot 2026-04-29 at `6c2b4af`)

This matrix is the implementation-facing truth source for the current Apple
player routes in `silo-apple`. It separates:

- `Repo-verified`: behavior grounded in the current code path
- `Validation required`: behavior that may exist on some device/output paths
  but cannot be claimed yet
- `Unsupported` / `Unclaimed`: behavior Silo does not currently promise on
  that route

## Routes

| Implementation route | Route family | Display label | Current role |
| --- | --- | --- | --- |
| `playerCoreDirect` | CompatibilityPlayer | CompatibilityPlayer Direct | Codec-tail fallback (AV1/VP9/legacy via the opened codec gate) + runtime fallback when the loopback degrades |
| `avPlayerHLS` | NativePlayer | NativePlayer HLS | Native adaptive path for explicit quality/bitrate-reduction HLS behind the local rollout gate |
| `avPlayerNativeDirect` | NativePlayer | NativePlayer Direct | Narrow native-direct path for allowlisted `mp4` / `mov` / `m4v` assets |
| `siloPlayerLoopback` | SiloPlayer | SiloPlayer Loopback | **Primary** direct playback for H.264/HEVC (incl. SDR) via the static-VOD serving mode; gate `player.apple.siloplayer_primary_enabled` default ON (explicit `false` = kill switch to the EVENT path). Hardware-validated 2026-07-03 (DV P8 + EAC3 on Apple TV 4K) |

## Matrix

| Capability | `playerCoreDirect` | `avPlayerHLS` | `avPlayerNativeDirect` | `siloPlayerLoopback` |
| --- | --- | --- | --- | --- |
| Primary audio selection | Repo-verified | Repo-verified | Repo-verified | Repo-verified |
| Primary subtitle selection | Repo-verified | Repo-verified | Repo-verified on allowlisted assets | Repo-verified |
| Sidecar primary subtitles | Repo-verified | Repo-verified | Repo-verified | Repo-verified |
| Secondary subtitles | Repo-verified | Repo-verified, sidecar-only | Repo-verified, sidecar-only | Repo-verified, sidecar-only |
| Chapters | Repo-verified | Repo-verified | Repo-verified | Repo-verified |
| Buffered-ahead reporting | Unsupported | Repo-verified | Repo-verified | Repo-verified |
| Video gravity control | Repo-verified | Unsupported | Unsupported | Unsupported |
| HDR toggle | Repo-verified | Unsupported | Unsupported | Unsupported |
| Audio delay | Unsupported | Unsupported | Unsupported | Unsupported |
| Subtitle delay | Repo-verified | Silo-rendered tracks only | Silo-rendered tracks only | Silo-rendered tracks only |
| Subtitle styling | Repo-verified | Silo-rendered tracks only | Silo-rendered tracks only | Silo-rendered tracks only |
| tvOS custom shell / Siri Remote ownership | Repo-verified | Repo-verified | Repo-verified | Repo-verified |
| Now Playing / remote commands | Repo-verified | Repo-verified | Repo-verified | Repo-verified |
| PiP | Unsupported | Validation required | Validation required | Validation required |
| AirPlay / external playback | Unsupported | Unsupported | Validation required, downloads only | Repo-verified |
| Premium HDR / DV / Atmos claims | Validation required | Validation required | Validation required | Validation required |

## Notes

- `PlayerCore.setAudioDelay(...)` is still a TODO, so audio delay must not be
  surfaced as supported even on the compatibility route.
- `avPlayerNativeDirect` is intentionally narrow. It only applies to direct
  assets whose container, codecs, and embedded subtitle shape match the
  client-side allowlist.
- NativePlayer and SiloPlayer secondary subtitles remain sidecar-only today.
  The UI should not imply arbitrary embedded-secondary subtitle parity on those
  routes.
- "Silo-rendered tracks" means subtitle tracks whose presentation goes
  through the shared libass session: text sidecars, FFmpeg-extracted text
  tracks, and ASS/SSA streams. Silo delay and styling controls apply
  only to those tracks.
- Native AVFoundation caption fallback (used when the libass extraction path
  is unavailable on a given asset/route) does not honor Silo
  delay/styling. The capability rows above describe what Silo can
  promise on each route; they are not a claim about every embedded subtitle
  on a NativePlayer or SiloPlayer asset.
- PiP stays intentionally conservative until Silo has route-specific lifecycle
  handling and device/output validation. PiP itself is enabled on the iOS
  AVPlayer-backed routes.
- AirPlay video hands the receiver a URL and nothing else: the receiver opens
  its own HTTP connection, without the asset's `AVURLAssetHTTPHeaderFieldsKey`
  headers. Two things make a NativePlayer URL unfetchable from a receiver, and
  a direct-play session can hit either: the URL is authenticated by an
  `Authorization` header (`/api/v1/...` sits behind `RequireAuth` on the
  server, so the fetch answers 401), or `prepareSourceProxy` has rewritten it
  to the on-device caching proxy at 127.0.0.1, which drops the headers but is
  unreachable off-device. External playback and the route picker are enabled
  only for assets that survive both checks — offline `file://` downloads, and
  unauthenticated origin URLs.
- On iOS, SiloPlayer publishes its generated HLS through a LAN URL carrying a
  per-session access token, so the selected receiver can fetch the playlist and
  segments. The server binds to the LAN but refuses off-device connections
  until a handoff is actually live, and advertises only a Wi-Fi/Ethernet
  RFC1918 address. If no such address exists, playback stays on the device with
  a notice instead of stranding the receiver. SiloPlayer AirPlay was
  hardware-validated 2026-07-24 from an iPhone 16 Pro to Apple TV with a Dolby
  Vision source. This validates external playback for that route, not a
  generalized Dolby Vision output-mode or premium-format claim.
- Premium-media claims stay validation-gated even when playback itself uses a
  NativePlayer or SiloPlayer route.
