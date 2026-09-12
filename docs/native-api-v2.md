# Native API v2 ownership

The stable native business API is `/api/v2`. Apple release callers use the
accepted v2 operation contracts and refuse unavailable operations. A failed or
unconfigured v2 playback request must not silently start a v1 session. The
retained `/api/v1/health` probe is an operational exception, not a playback
fallback. The server's [native API contract](https://github.com/Silo-Server/silo-server/blob/main/docs/architecture/api-contract.md)
defines the release boundary.

## Displayed reads authorize card actions

A catalog response belongs to the account, profile, credential owner and profile
proof captured for that read. Its collection, library or recommendation scope
also belongs to that response. A later tap uses this displayed owner; it does
not capture whichever profile happens to be current when an asynchronous task
runs.

Collection, library-collection, History and recommendation cards provide this
owner to their membership model. Browse, search, person, saved-list, Home and
library landing cards retain their existing owning models or captured callbacks.
Cards without an owning read do not offer an ownerless membership mutation.
Section watched actions inherit the library or recommendation read owner;
Home continues to supply its own model-owned callbacks.

Opaque catalog continuations retain the original query and authority. Personal
collection reads publish only after the bounded complete read succeeds.
Library-collection and History grids keep incremental paging. Legacy cached
cards without an owner cannot authorize a fresh action or seed a different
owner's display. Accepted membership flags on existing cards survive appending
the next page.

Membership uses the accepted PUT/DELETE favorite and watchlist operations;
watched state uses POST/DELETE. Each prepared action dispatches once. Receipt
application checks the captured owner and displayed generation again, so a late
response cannot update a replacement profile's cards or caches. These callers
do not add revision headers, refresh-authentication retries or a v1 fallback.
An uncertain action stays held by its owning model across refreshes. A new read
is not proof that the earlier mutation reached a terminal outcome. These models
do not create an offline replay queue.

## Durable commands keep their original authority

Playback and canonical settings journals preserve exact command bytes and
captured durable ownership before dispatch. Persistent target matching and
transient dispatch checks serve different purposes: a process restart alone
must not erase an unresolved durable target barrier, while a different login
or profile cannot take ownership of an old command.

Recovery is operation-specific. Canonical settings use typed single-dispatch
contracts and hold uncertain writes; they do not invent an idempotency or
revision-precondition contract. Playback can resolve an exact retained command
where its accepted protocol explicitly supports that resolution. Neither path
may convert old queued intent bytes, infer new authorization or rebase an
unresolved operation onto a new owner.

See [bound audiobook playback](bound-audiobook-playback.md) for timeline identity,
sequenced receipts and part-transition rules.

## Media request credentials stay ephemeral

A validated immutable playback plan is joined with the authority already
captured by its start or replan request. Where an accepted auxiliary transport
requires account authentication, Authorization and the matching `X-Profile-Id`
belong only in ephemeral, scoped request headers. Their use must be fenced by
the exact issued origin, session, path, pins and authority lifetime.

The server must not echo a bearer into `stream.headers`. Clients must not add
one to durable start responses, current plans, replacement JSON or journal
records. A later ambient token/profile read cannot supply authority for an old
plan. The recipe profile remains authoritative; a selector only selects media.
Signed URL and opaque-token transports retain their own contracts. This rule
does not imply that a particular auxiliary route is implemented or available.
