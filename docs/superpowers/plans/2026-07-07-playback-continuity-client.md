# Playback continuity across server outages and restarts (client side)

**Date:** 2026-07-07
**Status:** planned
**Server counterpart:** [silo-server#333](https://github.com/Silo-Server/silo-server/issues/333) — reconstruct-wire the control-plane endpoints (progress, audio change, subtitle, ws, start-transcode). This plan is the silo-apple half; it must also degrade gracefully against servers that predate #333.

## Problem

With the disk-spill source cache the client can hold minutes-to-hours of a file, yet any server blip or restart still interrupts playback visibly:

1. **Outage (server unreachable):** `PlaybackOriginReconnectPolicy` gives up after ~8–15 s (`httpOutage` cap 4, backoff 0.5/1/2/4 s — `PlaybackSourceOriginStream.swift:110`). If a demuxer read is blocked at the cache edge (it almost always is during a real outage), `escalateInterruption` (`PlaybackSourceProxy.swift:1360`) fires `attemptServerOutageRecovery` (`PlayerViewModel.swift:3277`), which *immediately* does `sourceProxy.stop()` + `activePlayer.dispose()` + "Reconnecting" notice + full `beginFreshLoad` — black screen even when the playhead has minutes of runway.
2. **Server restart:** the in-memory session dies; the client sees the `playback_session_not_found` sentinel (from the 10 s progress heartbeat, or a stream 404 pre-#174) and `attemptStaleSessionRenewal` (`PlayerViewModel.swift:3219`) tears everything down.
3. **Cache discard:** every renewal/recovery path constructs a fresh empty `PlaybackSourceCache` (`PlayerViewModel.swift:2101`), throwing away potentially GBs of spilled cache for the *same file*.

Additionally (found during research): when the proxy fails a blocked read today, `LoopbackSegmentWriter.runMuxLoop` treats the resulting negative `av_read_frame` as **clean EOF** (`LoopbackSegmentWriter.swift:1657-1662`), finalizes the playlist as VOD, and reports `onFinished(nil)` — a silently **truncated movie reported as success**. Recovery only happens because the proxy separately escalates. Any fix here must not leave that truncation latent.

## Key facts the design leans on (from code research)

- The writer reads the proxy via FFmpeg avio http with `rw_timeout = 10 s` (`LoopbackSegmentWriter.swift:1970-1972`). A read parked longer than 10 s returns `ETIMEDOUT` → the same `rc < 0` clean-EOF-finalize path. **Parking proxy waiters alone cannot hold the demuxer.**
- No writer-side watchdog covers the *input* read; the VOD backpressure park (`waitForVODWindowIfNeeded`, `LoopbackSegmentWriter.swift:1457-1499`) is output-side and unbounded once the consumer has fetched a segment.
- Consumer-side starvation watchdog (`AVPlayerBackend.swift:2236-2249`): playhead frozen ≥ 30 s + `bufferedAhead < 2.0` + no segment serve ≥ 15 s → `onLoopbackStallUnrecoverable("loopback_starvation")` → Compatibility-route fallback. This fires ~30 s after the buffer drains and would defeat a quiet park unless gated.
- Runway signals already exist, all reachable from `PlayerViewModel`:
  - (a) `bufferedAheadSeconds` (AVPlayer `loadedTimeRanges`, live via `onBufferedAheadChange`, `PlayerViewModel.swift:408`)
  - (b) `generatedVisibleAheadSeconds` / `generatedAheadSeconds` (segments remuxed/published, `AVPlayerBackend.swift:1855,1873`)
  - (c) `sourceCacheAheadSeconds` (`PlaybackSourceProxy.stats().estimatedForwardCacheAheadSeconds`, `PlaybackSourceProxy.swift:384-393`)
  - Runway ≈ a + max(0, b−a) + c.
- `resolveServerUrl` preserves the `?st=` reconstruct token on the stream URL (`PlayerViewModel.swift:5299`), so post-#174 servers rebuild the session on the next Range request — the data plane already survives restarts; only the client's own escalation defeats it.
- Existing outage machinery worth keeping: `waitForServerReady` health poll (`PlayerViewModel.swift:3372`), `serverOutageRecoveryTimeout = 90 s` (`:949`), single-flight guards per session.

## Design overview

Three workstreams, ordered by user impact. A: restart continuity (background renewal, no teardown). B: outage continuity (runway-gated escalation with a writer suspend/resume). C: cache survival when a teardown does happen. Each stage is independently shippable; A and C are low-risk, B touches the wedge-recovery chain and gets a kill switch.

---

## Workstream A — background session renewal (restarts become invisible)

Goal: a `playback_session_not_found` while the source is direct-play never tears down the player when the same bytes remain reachable. This covers pre-#333 servers (progress 404 after restart), TTL-expired reconstruct tokens, and reaped sessions.

### A1. Proxy origin retarget seam

`PlaybackSourceResource.originURL/originHeaders` (`PlaybackSourceProxy.swift:620-621,655-657`) become lock-protected `var`s read at stream-creation time (`makeStream` `:1188`, chunk fetcher construction).

New API on `PlaybackSourceProxy`:

```swift
func retargetOrigin(url: URL, headers: [String: String])
```

Under `stateLock`: swap URL/headers, cancel the current `windowStream` + `chunkFetcher` (they hold the dead session URL), then restart the window at `cache.nextPrefetchStart(after: lastReadPosition)`. Existing `dataWaiters` stay parked — the restarted window's `didStore` resumes them normally. Reset the unproductive-streak bookkeeping so the fresh session starts with a clean ladder.

Invariants: `totalLength` must not change (same file); `cancelled` short-circuits the retarget.

### A2. Lightweight session renewal in the bridge

Factor the POST-start half out of `PlaybackSessionBridge.startSession` (`PlaybackSessionBridge.swift:190`) into:

```swift
func renewDirectSession(contentId:fileId:position:audioTrackIndex:) async throws -> RenewedSession
// RenewedSession: sessionId, streamUrl (with ?st=), playMethod, fileId
```

It re-fetches watch detail only as needed to POST the start; **no** version re-selection — the fileId is pinned. Validate the response: `playMethod == direct` and `fileId` unchanged. Anything else → throw (caller falls back to visible renewal, because the server has genuinely re-planned playback).

### A3. Silent renewal path in PlayerViewModel

New `attemptBackgroundSessionRenewal(reason:)`, tried *before* `attemptStaleSessionRenewal` from both current triggers:

- `onPlaybackSessionMissing` (stream 404, `PlayerViewModel.swift:2105-2113`)
- progress `.missingSession` (`PlayerViewModel.swift:6364-6369`)

Flow (single-flight per stale session id, mirroring the existing guards):
1. `renewDirectSession(...)` with the current fileId/position/audio selection.
2. On success: `sourceProxy.retargetOrigin(url: resolved streamUrl, headers: auth)`, update `activePlaybackSessionId`, rebind `realtimeClient` and the session bridge to the new id, resume progress reporting. **Player and cache untouched — zero user-visible effect.**
3. On failure (offline, transcode plan, fileId changed): fall through to the existing visible `attemptStaleSessionRenewal`.

Gating: only when the active plan is `delivery == .direct` with a live `sourceProxy` (the loopback + AVPlayer-direct proxied routes). Transcode/HLS keeps today's behavior.

### A4. Soften the progress-404 kill switch

With A3 in place the progress `.missingSession` handler already routes through background renewal first. Additionally, make one failed renewal non-fatal while the stream is healthy: if `renewDirectSession` fails with a *transient* error (timeout, 5xx) and the proxy's window stream is currently delivering, retry on the next heartbeat instead of escalating. Only escalate to visible renewal on a definitive contract failure (fileId change, transcode replan, repeated 404 on renewal itself).

**Tests (A):** retarget under parked waiters resumes them from the new window; retarget rejects mismatched totalLength; renewal validation rejects fileId/playMethod drift; progress-404 → background renewal → no player dispose (assert `activePlayer` untouched via a spy); renewal single-flight under concurrent stream-404 + progress-404.

---

## Workstream B — runway-aware outage handling (loopback route)

Goal: a server outage shorter than the client's runway is invisible; a longer one shows a spinner over the *paused frame* (not a black screen) while recovery polls; teardown happens only at the 90 s budget, exactly like today.

The research killed the naive "park the read" idea: FFmpeg's `rw_timeout=10 s` converts a parked read into a clean-EOF truncation, and no dynamic way exists to extend it per-read. Instead, make the **writer** outage-aware and use its existing reopen machinery.

### B1. Proxy: outage state instead of waiter failure

In `PlaybackSourceResource`:

- New state `originOutage: Bool` + `outageStartedAt: Date?` under `stateLock`.
- `streamEnded`/`chunkFailed` (`PlaybackSourceProxy.swift:1268-1358`): for **retryable** causes (`.network`, `.stalled`, `.httpOutage`) with failed foreground waiters, do *not* resume them `.failed` and do *not* `escalateInterruption`. Enter `originOutage`, keep the waiters parked, and start a slow-cadence re-probe loop (reconnect the window every ~5 s at the write cursor — reuse `PlaybackOriginReconnectPolicy` with an uncapped streak while in outage). Non-retryable causes (`.httpFatal`, `.rangeIgnored`) and `.prematureEOF` keep today's behavior.
- New callback `onOriginOutageChanged: ((Bool) -> Void)` so the VM can arm recovery *silently*. First successful response after an outage flips it back and resumes parked waiters via the normal `didStore` path.
- `stop()` unchanged: still resumes everything `.failed` (dispose must never hang).

The existing "no foreground waiter affected" silent branch (`:1317`) is subsumed: give-ups are now always silent at the transport layer; visibility is the VM's decision.

### B2. Writer: suspend/resume instead of clean-EOF truncation

`LoopbackSegmentWriter.runMuxLoop` (`:1657-1662`): when `av_read_frame` returns `rc < 0` **and** the source reports an active outage **and** the input position is short of the known total, do not finalize. Instead:

1. Close the input context (the http connection is dead after `ETIMEDOUT` anyway).
2. Park in a cancellable wait loop (checking `interruptToken` and the outage flag; the existing 200 µs-sleep park in `waitForVODWindowIfNeeded` is the pattern).
3. On outage clear: reopen input and seek to the resume point — reuse the existing producer-restart/open-input path — and continue appending segments.
4. On writer cancellation or the VM's outage budget expiring: exit with a *real* error (`onFinished(outageError)`), never the silent-truncation success.

Plumbing: the writer needs a thread-safe `isOriginInOutage` closure on `LoopbackSessionSpec` (wired from the proxy in `prepareSourceProxy`, `PlayerViewModel.swift:2098`). This also fixes the latent truncation bug for the *current* failure mode — worth extracting as its own commit (B2a: distinguish outage-EOF from genuine EOF) since it's a correctness fix independent of parking.

### B3. VM: runway-gated escalation

Replace the body of the `onPlaybackSourceInterrupted` trigger with an armed-recovery state machine driven by the new `onOriginOutageChanged`:

- **Outage begins:** start `waitForServerReady` polling (existing, `:3372`) in the background. No UI change. Start a 1 Hz runway monitor (piggyback on stats sampling) computing runway = `bufferedAheadSeconds + max(0, generatedVisibleAhead − bufferedAhead) + sourceCacheAheadSeconds`.
- **Server returns while runway > 0:** proxy re-probe succeeds (the `?st=` token reconstructs the session server-side per #174), outage clears, writer resumes. If the session needs renewal (404 on re-probe), Workstream A's background renewal handles it. **User saw nothing.**
- **Runway exhausted, server still down:** AVPlayer stalls naturally → `isBuffering` spinner over the last frame (existing `onBufferingChange` path). Show the "Reconnecting" *notice* (non-destructive) at this point — but do **not** dispose the player or stop the proxy.
- **90 s outage budget expires (`serverOutageRecoveryTimeout`):** fall back to today's full teardown path (`attemptServerOutageRecovery` body) as the terminal escalation, preserving `finalizeTerminalPlaybackError` semantics.

### B4. Watchdog gating

While `originOutage` is active and within budget, suppress the escalations that would otherwise misread the quiet park as a wedge:

- `AVPlayerBackend` starvation escalation (`:2236-2249`) and playhead-watchdog reanchor exhaustion (`:2272-2280`): add an `isExternallyStalled` input (set by the VM during outage). Starved-during-outage must not degrade the route to PlayerCore — the route isn't broken, the network is.
- The origin-stream stall watchdog (`stallSeconds = 20`, `PlaybackSourceOriginStream.swift:94`) keeps running inside the re-probe loop (it's how a half-open recovery is detected).

### B5. Kill switch

`PlayerSettings` flag (pattern of `seekCacheEnabled`) + env override `SILO_DISABLE_OUTAGE_RIDE_THROUGH`, default ON. Killing it restores today's immediate-teardown behavior verbatim (the `escalateInterruption` path stays compiled in behind the flag).

Scope note: this workstream is loopback-route only. `playerCoreDirect` has no source proxy (`prepareSourceProxy` guard, `PlayerViewModel.swift:2088-2091`) and keeps current behavior; `avPlayerHLS`/transcode likewise.

**Tests (B):** policy-level tests for outage entry/exit (retryable vs fatal causes); parked-waiter resume on recovery; writer suspend does not finalize VOD (assert no `av_write_trailer` on outage-EOF) and resumes appending after outage clears; runway computation unit test; watchdog suppression flag honored; kill switch restores legacy path.

---

## Workstream C — cache survival across teardown reloads

Even with A+B, genuine teardowns remain (terminal errors, transcode replans, budget expiry). Today each builds a fresh empty `PlaybackSourceCache` (`PlayerViewModel.swift:2101`).

- New `SourceCacheHandoff` held by PlayerViewModel: `(fileId: Int, totalLength: Int64, cache: PlaybackSourceCache)`.
- On teardown with `origin == .recovery` (outage recovery, stale renewal): instead of letting the proxy drop the cache, detach it into the handoff slot (proxy `stop()` gains a `preservingCache` variant that skips cache release; disk spans stay on disk — the orphan-dir sweep from PR #68 already tolerates this).
- In `prepareSourceProxy`: if the handoff matches the new plan's `fileId` and the discovered `totalLength` matches, adopt the cache; otherwise release it. Only for `delivery == .direct` (byte-identical source guaranteed).
- Handoff is cleared on user-initiated loads, content change, and player close (release → normal disk cleanup).

**Tests (C):** adoption on matching fileId+length; rejection and release on mismatch; no double-release; disk spans readable after adoption.

---

## Rollout / sequencing

1. **B2a** (writer: outage-EOF ≠ clean EOF) — standalone correctness fix, ship first.
2. **A1–A4** — restart continuity; pairs with server #333 but does not require it.
3. **C** — cache handoff (small, independent).
4. **B1, B3–B5** — outage ride-through; biggest behavioral change, kill-switched, last.

Each lands with `xcodegen generate` + iOS/tvOS/macOS builds green; focused XCTests as listed (this is shared high-risk logic per repo test policy).

## Validation

- **Sim, dev server (LXC 100.86.116.20):** start loopback playback (Vultures 2025), then (a) `systemctl stop` the server 20 s → confirm zero UI change and resumed ingest; (b) restart the server → confirm no black screen, session id rotates only if reconstruct fails, cache stats do not reset; (c) keep the server down > runway → spinner over frame, then teardown at 90 s.
- **Log markers:** new `[CMP-OUTAGE]` lines (enter/exit, parked waiters, writer suspend/resume, runway at each transition) to make the hardware pass diagnosable via tvos-deploy-and-log.
- **Regression:** start-over late-audio repro file (359d20c fix), seek storms during outage, end-of-file within outage window (genuine EOF must still finalize), Android behavior comparison for the progress-404 softening (Android shares the sentinel logic and should eventually align).

## Interaction with existing plans

- AetherEngine gap remediation (docs/superpowers/plans/2026-07-07-aetherengine-gap-remediation.md): workstream A there (recovery-chain) is adjacent; B4's watchdog gating must be reconciled with its deadline-bound-seek / item-death-revive items when both land. D5 (429 rate-limit cause) composes cleanly with B1's retryable-cause set.
- Server #333 removes the *common* trigger for A (progress 404 after restart) but A stays as the fallback for expired tokens, reaped sessions, and older servers.
