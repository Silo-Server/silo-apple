# Resuming a progressive remux never starts playback

Status: app-side guard on `fix/progressive-remux-resume`. Engine fix planned, not started. Tracked in [Silo-Server/silo-apple#656](https://github.com/Silo-Server/silo-apple/issues/656).

## What happens

A title the server delivers as `server_remux_progressive` ("Server Remux") plays from the
beginning but shows a black player when it is resumed. The engine reports ready, reads
nothing, and its clock stays at 0. The app shows no error.

Seen on macOS on 2026-10-06 with AetherEngine `b1e4879e`, HEVC HDR10 + E-AC-3, resuming at
1004.87 s. The same title played from 0 on the same engine revision 20 minutes earlier. The
player code and the engine pin are shared, so iOS and tvOS are expected to behave the same;
neither has been tested.

## Evidence

Engine log for the failed load (host and session id removed):

```
[AVIOReader] pump tail prefetch rejected after 1024ms: status=200 (no suffix range support)
[AVIOReader] File size: -1 bytes (HEAD fallback)
[AVIOReader] no probe resolved a size, streaming mode (forward-only)
[Demuxer] Opened: 2 streams, duration=3838000 us
[AetherEngine] load url=https://<server>/api/v2/stream/<session>?seek=1004.873900416 source-format=hdr10 effective-format=hdr10 rate=23.976
[AetherEngine] source is forward-only, forcing software path
[AetherEngine] #361 startup 7/8 ready (gen 1)
[mov,mp4,m4a,3gp,3g2,mj2] [error] stream 0, offset 0xaad: partial file
[SWHost] demux read failed: Demuxer: read failed (Invalid data found when processing input (-1094995529))
[SWDiag] clk=0.00 dclk=0.00 rate=0.00 ... status=unknown        (repeats every second)
```

The load that worked differs in one respect: its URL has no `seek`, so its start position
was 0.

## Cause

1. The server starts a resumed progressive remux at the keyframe before the requested
   position and sets `timeline.player_start_seconds` to the distance between the two, so
   the client skips the copied pre-roll (`silo-server`,
   `docs/architecture/playback-protocol-v3.md`, section 5, "Progressive remux").
2. `AetherLoadSpec` passes that value to `AetherEngine.load(startPosition:)`.
3. A progressive remux is one chunked response with no size and no ranges. The engine's
   reader falls back to streaming mode, which cannot move backwards
   (`AVIOReader.isSeekable == false`).
4. `SoftwarePlaybackHost.load` handles every `startPosition > 0` with
   `dem.seekBounded(to: start, ...)`. That calls `avformat_seek_file` and then
   `avformat_flush`, which throws away the packets the probe already read.
5. The demuxer then has to read the first sample again, at byte `0xaad`. The reader is
   megabytes past that and cannot rewind, so `avio_seek` fails and libavformat reports
   `partial file`. The read loop stops on the error.

Step 1 is inferred from the protocol document and the URL. The plan the server returned
was not captured. Steps 3 to 5 are read from the engine source at `b1e4879e` and match the
log line for line.

## The guard in this app

`AetherLoadSpec.init(validating:)` now passes `startPosition: 0` to the engine whenever
`plan.delivery == server_remux_progressive`. Covered by
`AetherPlaybackBoundaryTests.testProgressiveRemuxStartsAetherAtTheStreamOrigin`.

What it costs:

- Playback restarts at the keyframe before the resume point, so up to one GOP (typically a
  few seconds) is shown again. `timeline_offset_seconds` still maps the engine clock to
  the source position, and `PlayerViewModel.loadAether` moves `currentTime` back to the
  stream origin so the scrubber and progress follow the replay instead of waiting for it
  to catch up.
- A credential-recovery reload on this route (`resumeSourcePosition`) returns to the
  stream origin instead of the current position. Before the guard that reload hit the same
  failure, so this is a worse position, not a new failure.
- A watch party member on this delivery starts up to one GOP behind the room and relies
  on the party's catch-up to close the gap. Not tested.

Not covered by the guard: audiobooks. `AudioPlayerViewModel` passes the plan's start
straight to the engine without `AetherLoadSpec`. If the server plans a progressive remux
for an audiobook resume, the original failure remains.

Remove the guard when the engine fix below is pinned.

## Engine fix plan

Repository: `Silo-Server/AetherEngine` (the fork pinned in `iosApp/project.yml`).

### Change

In `Sources/AetherEngine/Native/SoftwarePlaybackHost.swift`, `load(demuxer:startPosition:...)`,
at `if let start = startPosition, start > 0`:

- When the demuxer is forward-only (`!dem.isSourceSeekable`, no `timeSeekableReader`, not
  live), do not call `seekBounded`. The read position is already at the start of the
  stream and the probe's packets are still queued.
- Keep the rest of the branch: set `videoDecoder.skipUntilPTS`, `renderer.setSkipThreshold`,
  `initialClockTime` and `currentTime` to `start`. The decoder then decodes from the
  keyframe at the stream origin and drops frames until `start`, which is what the server's
  pre-roll offset asks for.
- Log one line naming the skipped seek, so a trace shows which path ran.

### To check while implementing

- Audio before `start`: confirm the feeder drops or holds audio packets earlier than the
  armed clock time, as it does after a normal seek that lands on an earlier keyframe.
- Bound the skip. A forward-only source can only reach `start` by decoding to it. If
  `start` is beyond a small limit (suggest 30 s), start at 0 and report the start as
  dropped instead of decoding silently for minutes.
- `SoftwarePlaybackHost.seek(to:)` on a forward-only source during playback. The app
  sends a seek to the server as a replan only when the plan says so
  (`can_seek_anywhere: false` with an open seek window, which the protocol specifies for
  this delivery); nothing in the client keys on the delivery itself. A plan that allowed
  local seeks would reach this path, which runs the same seek and flush and should refuse
  cleanly.
- Upstream `superuser404notfound/AetherEngine` no longer contains this exact branch, and
  its issue 693 describes a sequential origin that drops `startPosition`. Check whether a
  newer upstream revision already handles forward-only starts before writing new code; the
  fork is 55 commits ahead and 405 behind.
- `LoadOptions.sequentialOrigin` is the engine's existing declaration for a source where
  only byte 0 is addressable. Decide whether the app should declare it for progressive
  remux instead of relying on the probe falling back to streaming mode. It needs
  `declaredDurationSeconds`, which the plan carries as `source.duration_seconds`.

### Tests

- Unit test beside `Issue203SoftwareColdStartTests`: a forward-only reader over a
  fragmented MP4 fixture, loaded with `startPosition` inside the first GOP. Expect the
  first presented frame at or after `start`, no `demux read failed`, and the clock armed at
  `start`. The same test must fail on `b1e4879e`.
- The same fixture with `startPosition: 0`, to hold the path that works today.

### Rollout

1. Land the engine change and note the new revision.
2. In this repository: update the `AetherEngine` revision in `iosApp/project.yml`, run
   `xcodegen generate`, and commit the updated `Package.resolved`.
3. Remove the guard in `AetherLoadSpec` and change
   `testProgressiveRemuxStartsAetherAtTheStreamOrigin` to expect the plan's
   `player_start_seconds`.
4. Verify on macOS, iOS and tvOS: resume a Server Remux title mid-film, confirm the first
   frame is at the resume position and the scrubber agrees, then seek and confirm the
   replanned stream starts the same way.

## Related problems found in the same session

Neither is fixed here.

- The player shows nothing when the engine's read loop fails after `ready`. It should
  surface the typed failure and offer a retry.
- After the server drops the session, `PlaybackRealtime` retries the control websocket
  every 1.7 s and logs `Playback session not found` (404) each time. A 404 for the session
  should end the loop.
