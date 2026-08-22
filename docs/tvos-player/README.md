# Apple Library Playback Documentation

Current architecture as of 2026-08-22: Silo's library-media implementation is
being replaced by one AetherEngine route across iOS, tvOS, and macOS. The
canonical product, ownership, deletion, capability, privacy, legal, and
validation contract is the
[AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

The source migration is implemented in this worktree, but the complete
hardware/media matrix, signed release-archive purity audit, privacy gate, and
external-distribution legal gate are still pending. Do not infer a verified
format, HDR, Atmos, PiP, AirPlay, lifecycle, or release claim from a successful
compile.

## Current source entrypoints

- [`AetherPlaybackController.swift`](../../iosApp/iosApp/Screens/Player/AetherPlaybackController.swift)
  owns library-video loads and transport projection.
- [`AetherLoadSpec.swift`](../../iosApp/iosApp/Screens/Player/AetherLoadSpec.swift)
  maps Silo online/offline plans into Aether load inputs.
- [`PlaybackTimelineMapper.swift`](../../iosApp/iosApp/Screens/Player/ProtocolV3/PlaybackTimelineMapper.swift)
  maps the server, stream, and presentation time axes.
- [`PlayerViewModel.swift`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift)
  retains Silo product/session behavior while delegating media execution to
  AetherEngine.
- [`AetherAudioPlaybackController.swift`](../../iosApp/iosApp/Screens/Audio/AetherAudioPlaybackController.swift)
  owns audiobook media execution through AetherEngine's audio path.

The removed PlayerCore, AVPlayerBackend, local-HLS/loopback, source-proxy,
direct Libav/libass, and legacy audiobook-engine files are not alternate
routes. Rollback is an older app build, not an in-process fallback.
Decorative media and trailers are outside the library-playback boundary
defined by the canonical specification.

## Historical pre-Aether archive

The documents below are retained only as design and validation history. Each
has a prominent historical banner. They describe removed custom-player code
and must not be used as current implementation guidance:

- [01 - Overview and entrypoints](01-overview-and-entrypoints.md)
- [02 - CoreMedia pipeline](02-coremedia-pipeline.md)
- [03 - Dolby Vision and AVPlayer route](03-dolby-vision-and-avplayer-route.md)
- [04 - tvOS controls and historical behavior](04-tvos-controls-and-current-behavior.md)
- [05 - Historical route capability matrix](05-route-capability-matrix.md)
- [06 - Historical validation record template](06-validation-record-template.md)
- [07 - Profile 7 Dolby Vision and TrueHD loopback spec](07-profile7-dv-truehd-loopback-spec.md)
- [08 - Historical validated-player review](08-validated-player-review.md)
- [Cast/remote notes](cast-remote.md)
- [Legacy validation records](validations/README.md)
- [Pre-migration AetherEngine gap audit](2026-07-07-aetherengine-gap-audit.md)

When an archive document conflicts with the replacement specification or live
source, the replacement specification and executable source are authoritative.
