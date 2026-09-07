# Bound audiobook playback

Bound audiobook playback uses `progress_persistence: "client_bound"` to combine
a part-local player clock with a server-persisted whole-item resume position.
It requires the `bound_client_timeline` playback capability and an available,
admitted v2 playback path. Detail metadata can decorate the player but cannot
supply part order, offsets or durations.

## Discover once for an explicit intent

The client reads
`GET /api/v2/playback/timelines/{file_id}?installation_id=...`
under the captured request authority. The anchor file identifies the edition.
The complete server manifest contains:

| Field | Meaning |
| --- | --- |
| `installation_id` | Server installation owning the mapping |
| `timeline_id` | Digest identifying the immutable mapping |
| `media_item_id`, `edition_id` | Whole item and selected edition |
| `duration_seconds` | Whole-item duration in seconds |
| `parts` | Ordered `file_id`, `offset_seconds`, `duration_seconds` entries |

The client validates identities, unique file IDs, finite positive durations,
contiguous offsets and the whole-item duration. It retains this snapshot to
select initial resume, next-part and cross-part seek targets. It does not
reconstruct the mapping from a detail response or local file-duration guesses.

START advertises `bound_client_timeline` in `client_features`, carries the same
`timeline_id`, requests `client_bound`, and sends a part-local `start_position`,
including zero. The playable decision's `progress_timeline` must match the
retained selected-part binding: timeline, item, file, part offset, part duration
and whole-item duration. The exact start attempt and command remain journaled
under their captured authority through uncertainty.

## Keep local and global positions distinct

Progress and stop carry `timeline_id` for a bound session. A stop requires it
even when there is no final sample. `position` remains local to the selected
part. The server computes the global position from the captured mapping:

```text
item_position = part_offset_seconds + position
```

For a part beginning 900 seconds into a book, a local sample at 30 seconds has
global `item_position` 930. The player seeks to 30 within that part, not 930.
Accepted receipts retain the accepted sequence and local `position`, and carry
`timeline_id` plus global `item_position`. The client validates the relationship
before applying the receipt. A receipt describes the accepted sample, which may
differ from the latest attempted sample.

Fresh bound playback reports through its sequenced session. It does not send a
second whole-item update through the legacy progress-sync path. Existing
unbound sessions and old queued uploads keep their original bytes and authority;
they are not converted into bound playback commands.

## Confirm the old part before starting the next

Next-part playback and cross-part seeks first require the old part's terminal
stop receipt. Local engine shutdown, a draining response, a lost reply or an
error does not establish that terminal state. An unknown stop holds the
transition; starting another part is not a recovery mechanism.

After terminal confirmation, a distinct next-part attempt can use the retained
manifest's selected file and digest. Same-part replanning must preserve the
binding. It cannot silently choose a different part or change the captured
mapping, and unsupported replan capabilities or HTTP 501 remain refusals.

## Settle a changed-manifest refusal exactly

The server reserves the original attempt and request digest before comparing
the trusted manifest. A changed manifest can produce an ordinary, retained
HTTP 201 START decision with these fields:

```json
{
  "outcome": "adaptation_unavailable",
  "terminal": {
    "reason": "client_timeline_changed",
    "retryable": false
  }
}
```

This excerpt is not the complete decision envelope. The client also validates
the ordinary protocol/feature envelope and its original authority and attempt.
This refusal has no session, executable plan or activation. The field is
`terminal.reason`, not `reason_code`.

Exact replay resolves the retained decision before the server consults the
current catalog. A lost publication response remains uncertain, including a
generic HTTP 503. Neither a generic HTTP 409 nor an interim timeline-conflict
409 proves that the old attempt is safely settled.

Only after validating the exact retained terminal decision may a new explicit
user intent discover a fresh manifest. The client must not automatically refresh
the mapping, retry with new bytes or reinterpret the old request under it.

## Configuration and admission are separate

Ordinary server startup leaves the initial playback runtime off. Configuring
that runtime is an explicit server operation with its own dependencies and
startup validation. A reconciliation scope does not enroll an account or create
source admission. Each account still needs its separately admitted source and
exact source identity; issuing START must not perform enrollment.

The client treats `not_configured` as unfinished server playback setup,
`unsupported` as a server-update requirement, and unavailable or unadmitted
profiles as unavailable for playback. Missing bound-timeline capability refuses
bound audiobook playback. None of these states permits a hidden v1 fallback,
and a configured-v2 failure cannot be replayed on v1.

Schema availability, offline conformance tests and successful Apple builds do
not establish live media acceptance or authorize runtime activation. Behavioral
validation needs the exact server implementation, an explicitly configured
isolated runtime and admitted test accounts. Deployment and admission procedures
belong to the server; this client document does not enable them.
