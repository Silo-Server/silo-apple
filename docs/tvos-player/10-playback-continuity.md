Last verified against the code: 2026-08-20

# Playback continuity across server outages and restarts

How the player rides out a server that goes away mid-stream — a restart, a
network blip, a reaped playback session — without tearing down playback while
the same bytes remain reachable. This distills the shipped design (originally
"playback continuity" workstreams A/B/C); the code cited below is the source of
truth.

## Who decides

Every decision below is
[`RecoveryPolicy`](../../iosApp/iosApp/Screens/Player/Recovery/RecoveryPolicy.swift)'s
— a pure function that takes a `RecoveryObservation` plus the load's
`RecoveryContext` and returns at most one `RecoveryAction`. Its only runtime
caller is the load's
[`RecoveryDriver`](../../iosApp/iosApp/Screens/Player/Recovery/RecoveryDriver.swift),
owned by that load's `PlaybackEngineSession`, which makes every latch, budget
and rolling window load-scoped by construction. The engine session and the view
model *execute* actions; neither decides one. The policy's constants
(`serverOutageRecoveryInitialDelay = 1 s`, `serverOutageRecoveryMaxDelay = 8 s`,
`serverOutageRecoveryTimeout = 90 s`) are the ladder's only copy.

## The three mechanisms

### A. Background session renewal (restarts become invisible)

A `playback_session_not_found` on a direct-play source never tears down the
player on its own. The policy answers with
`RecoveryAction.renewSourceInBackground(reason:)`, the control plane runs it as
`Effect.renewSource(SourceRenewal, SessionIdentity)`, and the source proxy is
retargeted at the renewed session's URL without dropping parked reads:

- `PlaybackSourceProxy.retargetOrigin` swaps the origin URL/headers under the
  state lock, cancels the streams holding the dead session URL, and restarts
  the fetch window; parked byte demands stay registered and resume when the
  fresh window stores data. A renewed direct-play session serves byte-identical
  content, so the cache and total length carry over.
- `PlaybackSessionBridge.renewDirectSession` is the renewal call; the effect
  carries the `SessionIdentity` it is conditional on, so a renewal whose
  session was superseded is dropped rather than applied. The single-flight is a
  reducer sub-state (`Playing.Sub.renewingSource`), not a session-id echo.
- When silent renewal is not the right answer, the policy escalates instead:
  `RecoveryAction.renewSessionFresh(reason:)` is the *visible* renewal that
  re-runs the load, and `.recoverFromServerOutage(reason:)` is the full visible
  recovery (tear the proxy and backend down, show "Reconnecting", wait for the
  server, reload).

### B. Runway-aware outage handling (loopback route)

When the origin stops delivering and the reconnect ladder gives up on a
retryable cause, the transport does not fail — it parks and lets the player
play out its buffered runway:

- `PlaybackOriginOutagePolicy` (`PlaybackSourceOriginStream.swift`) is the
  transport's own decision table: park blocked byte demands instead of failing
  them, and re-probe the origin on a slow cadence.
- The *ride-through* on top of it belongs to `RecoveryPolicy`. An origin-outage
  observation becomes `RecoveryAction.rideThroughOutage(probeAfter:)`, whose
  contract is one thing: sleep `probeAfter`, issue one `/api/v1/health` probe,
  report it back as `.serverHealthProbe(ok:)`. Entry carries `probeAfter: 0`
  and the returned delays are 1, 2, 4, 8, 8, … — probe times
  t = 0, 1, 3, 7, 15, 23, …, capped at 8 s within the 90 s timeout. A probe
  that comes back healthy also nudges an immediate origin re-probe
  (`[CMP-OUTAGE] server healthy; nudging origin re-probe`) rather than waiting
  for the transport's own slow cadence. When the origin returns, the policy
  answers `.endOutageRideThrough`, which carries no payload: it clears the
  ride-through state and unconditionally runs the post-outage kick
  (`AVPlayerBackend.kickPlaybackAfterOutage`), which is what re-starts a player
  that parked at rate 0.
- The ride-through deliberately outlives a load. Its health-probe loop is gated
  on the ride-through's own liveness, not on the `LoadID`, so a replan that
  mints a new load mid-outage does not abandon the loop.
- Outage *visibility* is still runway-gated, not transport-driven — but the gate
  is the policy's once-per-outage latch (`RecoveryContext.OutageState.noticeShown`,
  set when buffering is observed while the outage is live). The view model only
  renders the notice from it and clears its own "Reconnected" latch.
- An in-place engine reload carries the ride-through with it: the replacement
  session adopts the outgoing one's `OutageState`
  (`RecoveryDriver.adoptOutageRideThrough`), so a route switch during an outage
  does not restart the backoff or re-show the notice.
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
- Whether a teardown *offers* the prefix at all is carried on the effect, not
  decided at the teardown site: `Effect.disposeEngine(loadID, sourceCache:)`
  takes a `SourceCacheDisposition` of `.stash` (fresh loads, most outage
  recoveries), `.discard` (terminal failure, `cleanup()`, and a
  `source_entity_changed` outage where the cached bytes provably belong to the
  replaced entity) or `.retainProxy` (background suspend, which drops the
  engine and keeps the proxy).

## Invariants worth keeping in mind

- Retargeting requires the total length to be unchanged (same file); a
  cancelled proxy short-circuits the retarget.
- Outage visibility is runway-gated and latched once per outage on the load's
  `RecoveryContext`; the transport only parks and probes, and the view model
  only renders.
- One recovery owner. `RecoveryPolicy` is the only place a recovery decision is
  made, `RecoveryDriver` is its only runtime caller, and both the engine session
  and the view model only execute the `RecoveryAction` they are handed.
- A truncated remux must never finalize as a complete VOD — that is the bug
  class B was built against.
- Cache adoption is only sound for byte-identical sources; when in doubt it
  rejects.

## Device evidence

- [`validations/2026-08-19-tvos-stage2-wave2b-appletv14-1-hdr10-loopback.yaml`](validations/2026-08-19-tvos-stage2-wave2b-appletv14-1-hdr10-loopback.yaml)
  — HDR10 loopback on the one-recovery-owner build, with a control run against
  the pre-extraction build.
- [`validations/2026-08-20-tvos-stage2-wave3-appletv11-1-dv-outage.yaml`](validations/2026-08-20-tvos-stage2-wave3-appletv11-1-dv-outage.yaml)
  — Dolby Vision P7 + TrueHD on the reducer/actor build, with a 76 s production
  outage absorbed by the runway with no user-visible impact. Note what that
  record does *not* claim: because the runway absorbed everything, the visible
  half of the machinery (ride-through backoff → probes → auto-reload) is still
  unexercised on hardware.
