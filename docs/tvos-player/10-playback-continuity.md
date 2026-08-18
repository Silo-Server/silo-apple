# Playback continuity across server outages and restarts

How the player rides out a server that goes away mid-stream — a restart, a
network blip, a reaped playback session — without tearing down playback while
the same bytes remain reachable. This distills the shipped design (originally
"playback continuity" workstreams A/B/C); the code cited below is the source of
truth.

## The three mechanisms

### A. Background session renewal (restarts become invisible)

A `playback_session_not_found` on a direct-play source never tears down the
player on its own. `PlayerViewModel` renews the playback session in the
background and the source proxy is retargeted at the renewed session's URL
without dropping parked reads:

- `PlaybackSourceProxy.retargetOrigin` swaps the origin URL/headers under the
  state lock, cancels the streams holding the dead session URL, and restarts
  the fetch window; parked byte demands stay registered and resume when the
  fresh window stores data. A renewed direct-play session serves byte-identical
  content, so the cache and total length carry over.
- `PlaybackSessionBridge` owns the renewal call; `PlayerViewModel` drives the
  silent-renewal path and only escalates to visible recovery when renewal
  itself fails.

### B. Runway-aware outage handling (loopback route)

When the origin stops delivering and the reconnect ladder gives up on a
retryable cause, the transport does not fail — it parks and lets the player
play out its buffered runway:

- `PlaybackOriginOutagePolicy` (`PlaybackSourceOriginStream.swift`) is the
  decision table: park blocked byte demands instead of failing them, re-probe
  the origin on a slow cadence (the view model's server-health poll nudges an
  immediate re-probe when health returns), and leave outage *visibility* to the
  view model — it is runway-gated, not transport-driven.
- `LoopbackIngestEndPolicy` (`AVPlayerRoute/LoopbackIngestEndPolicy.swift`)
  guards the writer's ingest edge: a negative `av_read_frame` is only
  finalized as end-of-content when the available signals (bytes consumed vs
  known file size, VOD plan axis vs end fence) say the content is
  substantially complete. A source that died early is a premature end, never a
  silently truncated remux published as a complete VOD. With no signal at all,
  legacy clean-EOF behavior is preserved.
- Kill switch: `SILO_DISABLE_OUTAGE_RIDE_THROUGH=1` restores the legacy
  give-up-immediately behavior (see `PlaybackOriginOutagePolicy`).

### C. Cache survival across teardown reloads

Genuine teardowns still happen (terminal errors, replans, budget expiry). A
recovery reload may adopt the previous proxy's source cache instead of
starting cold:

- `SourceCacheAdoptionPolicy` (`Screens/Player/SourceCacheAdoptionPolicy.swift`)
  is deliberately strict: adoption requires direct-play delivery of the *same*
  media file with the same cache budget and spill configuration. Anything
  else — different file, re-planned delivery, changed budget, toggled Seek
  Cache setting — rejects, and the stash is released.

## Invariants worth keeping in mind

- Retargeting requires the total length to be unchanged (same file); a
  cancelled proxy short-circuits the retarget.
- Outage visibility is the view model's runway-gated decision; the transport
  only parks and probes.
- A truncated remux must never finalize as a complete VOD — that is the bug
  class B was built against.
- Cache adoption is only sound for byte-identical sources; when in doubt it
  rejects.
