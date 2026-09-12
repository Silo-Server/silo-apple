# API v2 playback simplification plan

## Goal

Keep the API v2 playback guarantees that are required by the server contract:

- one start attempt has one durable request body and authority;
- progress and stop mutations keep their sequence and retry identity;
- a changed account, profile, server, or installation cannot replay an old mutation;
- an uncertain response can be resolved after a restart;
- owner-loss responses remain distinct from ordinary stop responses;
- the player can fall back or surface a terminal error without silently changing media authority.

Reduce the implementation to one durable playback transaction, one authority validator,
and one transport boundary. Preserve wire formats and error meanings while removing
duplicate state ownership and platform-specific assumptions from individual stores.

## What the server actually requires

Checked against `silo-server` (`docs/playback-api.md`, `internal/apiv2/playback.go`,
`internal/api/handlers/playback_v3.go`) and the Android client
(`shared/.../repository/SequencedPlayback.kt`). Both siblings are checked out beside
this repository.

Required by server behavior (409, 202 draining, or admission fence):

- Byte-exact original start body retained under a stable `playback_attempt_id`.
  A digest mismatch is `409 playback_attempt_reused`.
- One stop UUID minted once and retried verbatim through `202 draining`. The contract
  forbids inferring completion from a timeout or allocating a new session.
- Restart resolution of an uncertain start. Unresolved owner-loss work fences fresh
  admission for the same source and profile (`planstore/owner_loss_recovery_test.go`).
- Owner-loss handling on START and STOP, including binding validation before release.
- Sequenced progress with once-per-sample allocation. Equal sequence with a changed
  payload is `409 progress_conflict`.
- `installation_id` captured from capabilities and echoed on every mutation.
- Replan bodies retained per `replan_request_id` for the retry window.

Not required:

- Re-fetching `GET /api/v2/playback/capabilities` to validate authority per request.
  The contract says capture the ID once; the server returns `409 installation_changed`
  on mismatch. Android fetches capabilities twice per lifecycle.
- Journaling replan responses or route events. Route events are droppable diagnostics.
- Retaining raw owner-loss response bodies beyond the identity tuple.

Android implements the same guarantee set in roughly 1,100 lines. The Apple layer is
roughly 1,550 lines for the equivalent files. The difference is mostly the capabilities
probe and the auxiliary media plumbing, not the journal design.

## Audit findings

### Confirmed defect: tvOS storage root

`PlaybackMutationStore.shared` constructs its URL from
`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`.
tvOS devices reject that write and produced `NSCocoaErrorDomain` 513 before
`/api/v2/playback/start` was sent. The simulator does not enforce the constraint.

`DiagnosticsStorageRoot` already selects Caches on tvOS. The same latent bug exists in
three other writers that compile into the tvOS target without an OS guard:

- `SettingsMutationJournal.sharedCanonical` and its retained profile journal
- `UICustomizationV2Transport` default journal
- `DownloadFilePaths.rootDirectory` and `ownedScopeDirectory`

### Highest-cost excess: per-call capabilities probe

`PlaybackMutationCoordinator.currentAuth` issues an uncached capabilities GET on every
call. It is invoked twice per progress sample, twice per stop attempt, three times per
replan, twice per route event, and via `validateControlBinding` once per inbound
websocket message and twice per remote command. `APIv2Client.playbackCapabilities` does
no caching and the server sends `Cache-Control: no-store`. This roughly triples request
volume per heartbeat for no contractual gain.

### State ownership is split

The same lifecycle is represented by `PlaybackMutationStore`,
`PlaybackMutationCoordinator`, `PlaybackSessionBridge`, and `PlaybackRealtimeClient`.

- The bridge keeps `sequencedSessionIDs` and `failedSequencedRegistrations` and
  decides "is this a v2 session" at six sites, using two sources of truth. It never
  calls the coordinator's `handles(_:)`.
- Three trackers answer "is a stop already in flight": the bridge's `retiringSession`
  task, the coordinator's `draining` set, and `PlaybackStopNotices.pending`.
- Attempt identity is held in both `ActiveProtocolV3` and the coordinator's `Context`
  and validated independently on each side of a replan.
- Start retry lives in the bridge (`startV2WithNetworkRetry`, one retry). Stop retry
  lives in the coordinator (seven delays, 30 second deadline).

### The durable file carries three related record types

`StoredPlaybackStart`, `StoredPlaybackMutationSession`, and `StoredPlaybackReplan`
share authority, request identity, response retention, and terminal handling but use
separate lookup and acknowledgement paths. The one concrete cost is the
`originalAttemptID` cross-record scan that decodes retained start responses to find a
session's attempt. The records otherwise mirror real server objects, and Android's
single entry with the same fields is not materially simpler. Treat a full merge as
optional, not as a phase gate.

### Authority validation is repeated

`PlaybackMutationCoordinator` rebuilds and compares authority at registration, start,
replan, progress, stop, control binding, and restart recovery. Some repeats guard real
actor suspension points. Others do not: `adoptAuxiliaryAuthority` checks
`stopIntents[...] == nil` three times and `contexts[sessionID]?.recordID` twice inside
one guard with no await between several of them.

### The bridge owns too much policy

`PlaybackSessionBridge.swift` is 2,231 lines. About 110 lines are a generic
cancellation shield with no dependency on the bridge, and about 80 lines are display
DTOs. Inside the actor, `stageProtocolV3Start` and `replanProtocolV3` contain nine
near-identical retire-then-emit-then-throw blocks. The two-phase stage, commit,
promote, and rollback machinery for route transitions lives in the bridge, with a
parallel set of `prior*` rollback snapshots in `PlayerViewModel`.

`AudioPlayerViewModel` is a second full consumer of the coordinator with its own
`startAfterPreviousPartStop` helper. Bridge changes must cover both consumers.

### Test surface

Six playback test files hold about 195 tests. The largest are Protocol V3 tests that
predate this branch. Keep them through the refactor. Consolidate only after state
ownership is reduced and only where two tests exercise the same transition through
different wrappers.

## Implementation phases

Order is by value per unit of risk. Phases 1 through 3 are safe to ship independently.

### Phase 1: make storage safe and explicit

1. Promote `DiagnosticsStorageRoot` into one `AppleStorageRoot` helper with platform
   rules: Caches on tvOS, Application Support elsewhere.
2. Use it in `PlaybackMutationStore.shared`, `SettingsMutationJournal.sharedCanonical`,
   `UICustomizationV2Transport`, and `DownloadFilePaths`. Inject the URL; remove the
   global URL construction from actor declarations.
3. Add a tvOS test that creates, persists, reloads, and removes a playback record under
   the selected root. Keep the file-format version and migrate no data.
4. Add a startup log that records the selected storage category, without a private path.

### Phase 2: stop probing capabilities per request

1. Capture `installation_id` once in `captureStartAuth` and store it on the authority
   as today.
2. Make `currentAuth` compare the token store's durable auth against the stored
   authority locally. Remove the capabilities GET from that path.
3. Make `validateControlBinding` a local comparison. Keep the one capabilities fetch in
   `restorePending` and the one in `captureStartAuth`.
4. Add a test asserting a progress report issues exactly one HTTP request and a stop
   attempt issues exactly one.
5. Rely on `409 installation_changed` from the server for the mismatch case; keep the
   existing mapping to `authorityChanged`.

### Phase 3: mechanical bridge cleanup

1. Move `PlaybackCancellationShieldGate` and `PlaybackCancellationShield` to their own
   file. Move `PreparedPlayback`, `PlayerMetadata`, and `PlaybackDeliveryStrategy` out
   of the bridge file.
2. Add one private helper for retire-then-emit-then-throw and replace the nine blocks.
   Preserve exact reason strings and the retire-before-emit order.
3. Merge the two `replanOperation` overloads.
4. Extract the shared "does this pending transition still match" predicate used by
   commit, promote, and rollback.
5. Choose one start retry policy and put it in the coordinator beside the stop policy.
6. Remove redundant re-checks in `adoptAuxiliaryAuthority` that sit between
   non-suspending reads.

### Phase 4: single owner for v2 session state

1. Expose a tri-state query on the coordinator: not sequenced, registration failed,
   bound. Replace the bridge's `sequencedSessionIDs` and `failedSequencedRegistrations`
   with it. Registration failure must still block a plain DELETE fallback.
2. Fold `PlaybackStopNotices` into coordinator state with one observable projection.
   Remove the bridge's separate in-flight stop tracking where the coordinator's
   `draining` set already answers it.
3. Make `PlaybackRealtimeClient` own only the control socket and event delivery. It
   receives a validated binding and does not call back into authority validation per
   message once Phase 2 lands.
4. Make `PlayerViewModel` and `AudioPlayerViewModel` consume playback outcomes; remove
   file, authority, and restart-journal decisions from them.
5. Keep proxy subtitle and artifact cleanup separate until the coordinator has a proven
   ownership boundary.

### Phase 5: journal shape, if still justified

1. Merge `StoredPlaybackStart` into the session record so a session carries its
   attempt directly and the `originalAttemptID` scan is deleted.
2. Leave `StoredPlaybackReplan` as is unless a caller needs cross-record lookup.
3. Drop retained raw owner-loss response bodies once diagnostics no longer read them.
4. Move all file reads, atomic writes, version checks, and cleanup into the journal
   actor. The actor should not know about HTTP or player UI.
5. Delete wrappers and compatibility overloads with one caller. Reduce comments to
   contract rationale and platform constraints.

## Required validation

- API v2 unit tests for start, progress, stop, replan, owner-loss, restart, and
  authority changes.
- Request-count tests for progress, stop, and websocket command handling after Phase 2.
- tvOS device test proving the journal can be created and playback reaches the server
  start endpoint.
- Negative test proving a changed authority cannot replay a retained request.
- Interrupted-write test proving the previous valid journal remains readable.
- Physical bedroom-TV run with debug logging enabled and a captured diagnostics report.
- Compare `git diff --stat` and startup and playback timings before and after.

Do not remove owner-loss recovery, durable stop intents, restart resolution, or authority
fencing. The server enforces each with a 409, a 202 draining loop, or an admission fence,
and Android carries the same set. The duplication around them is the simplification
target.

Evidence caveat: the server comparison used the newest sibling checkout matching this
branch's owner-loss work. If the shipping server is a different branch, re-confirm the
same-source admission fence before relying on it.
