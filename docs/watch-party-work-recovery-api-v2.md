# Watch Party work recovery

The shared `WatchPartySession` owns room delivery and recovery. A locally queued
write or a completed WebSocket send does not prove that the server applied it.
The client enables work recovery when the v2 room capability or socket ticket
advertises `work_admission.version: 1`. Backend, scope, and epoch describe the
server's enforcement; the client does not infer cluster enforcement from Redis
being present. Servers without the capability keep the existing behavior.

`transport_request` and `lobby_ready` use optional request IDs. Only a matching
`action_result` with `status: applied` confirms the one-shot action. The server
queues existing operation snapshots and commands before this result, so a
generation advance does not invalidate an otherwise current acknowledgement.
Attachment, readiness, and buffering use current authoritative snapshot echoes.
Lobby readiness can also reconcile through the member's snapshot. Pending
readiness is displayed separately from confirmed member readiness.

Only a correlated `realtime_rate_limited` or `realtime_unavailable` error with
`work_started: false` permits an automatic transport retry. It keeps the request
ID and payload, runs once within five seconds, and requires unchanged engagement,
socket, room, selection, generation, playback session, command, and authority.
An acknowledgement timeout, failed send, disconnect, downstream error, or identity
change causes reconciliation and visible uncertainty without transport replay.
Distinct play and pause requests remain separate. Absolute seeks retain their
latest target in one 250 ms input window; the player's existing held seek shows
the pending target immediately.

The reporting loop services one pending desire per action kind and recomputes
current payloads at execution. Refusal floors apply to the whole operation class.
Retry jitter is nonnegative and at most 250 ms. A refused buffering report clears
the local sent flag while retaining the stall grace; a recovered player never
retries that old stall. Command, session, selection, authority, and engagement
changes invalidate pending desires. Leaving the lobby cancels lobby readiness.

Unavailable work backs off by 2, 4, 8, 16, then 30 seconds. A 1008 close is an
input-shield close only with reason `realtime input shield`. The corresponding
notice uses `realtime_input_limited`. Its reconnect delays are 5, 10, 20, then 30 seconds;
opaque connection failures use 1, 2, 4, 8, 16, then 30 seconds. Opens alone never
reset these sequences. Reset requires 30 seconds of useful acknowledged activity.
HTTP ticket 429/503 responses retain the greater of structured `retry_after_ms`
and `Retry-After`, rather than becoming permission failures.

This code uses v2 room sockets. It adds no generic events consumer, changes no
playback-control socket, and exposes no new Watch Party entry point. The macOS
target compiles the shared room core but currently excludes the Watch Party
screens and shared player view. Its existing feature exposure stays unchanged.

`WatchPartyWorkRecoveryTests` exercises the production bookkeeping with explicit
fake times. `WatchPartySessionRecoveryTests` drives the real session through stub
HTTP/socket transports and fake timers, including rendered lobby fixtures. These
tests establish synthetic regression behavior; they do not prove real-server
playback, released-build compatibility, or human validation acceptance.
