# Requests API v2 consumer

The Apple clients call `/api/v2/requests` for the request capability, search, discovery, detail, create, My Requests, cancel, and follow. The methods live in `APIv2Client+Requests.swift`; `SiloAPI+Requests.swift` forwards to them. No request falls back to v1.

Request administration (approve, decline, retry, request limits, auto-approve) stays in the web admin. The Apple clients have no approvals queue or moderation actions and never call `/api/v2/admin/requests`, even for an admin account.

## Scope and ownership

Every operation is profile scoped. A call needs a selected profile, sends `X-Profile-Id` (plus `X-Profile-Token` when the profile has a proof), and runs under the owner captured when it starts. A profile, account, or server change before dispatch refuses the call; a change while it is in flight discards the response.

## Capability

`GET /api/v2/requests/status` returns `FeatureStatus`. Entry points show only when `requests_enabled` is true, `allowed` is true, and `state` is `available`. A blocked account gets `requests_enabled: true` with `allowed: false`, so its entry points stay hidden. The contract requires `allowed`; a response without it reads as not allowed. A failed probe keeps the previous value. `follow_supported` gates the follow action; a server that omits it does not offer follow.

## Reads

- Search sends `q`, `media_type` (`movie`, `series` or `all`) and a 1-based `page`. Blank text is refused before dispatch because the server answers 422.
- Discovery decodes `{items}`. The server omits `page` because the collection is bounded. Each row may carry `next_page` when rating backfill used more than one provider page.
- Detail accepts only `movie` and `series` in the path.
- My Requests follows `page.next_cursor` with a page size of 50. A failed page, a missing or repeated cursor, an owner change, or the 100-page bound fails the load instead of showing a partial list.

Every read requires status 200.

## Create and cancel

`POST /api/v2/requests` requires 201. `POST /api/v2/requests/{id}/cancel` requires 200 and percent-encodes the opaque request ID. The contract marks both `non_retryable`: the server keeps no client request identity, so a resend can act twice.

| Outcome | Examples | Behavior |
|---|---|---|
| Definite success | 201 create, 200 cancel with a readable record | Publish the record, then re-read the detail or list. |
| Definite failure | Never sent (no connection, DNS or TLS failure), no selected profile, or any problem response | Show the error once. The user may try again. |
| Uncertain | Connection lost or timed out after sending, an unexpected 2xx, an unreadable 2xx body | Never resend. Hold the action (the detail CTA shows "Not confirmed yet"; a held cancel hides its menu item) and re-read. A successful re-read releases the hold. |
| Uncertain, owner changed | The account, credential owner or profile changed after the call captured its owner (`APIv2RequestsError.outcomeUnknownOwnerChanged`) | Never resend and hold as above, but skip the re-read: it would run under the new owner. The banner tells the user to check My Requests. |

The transport raises the same identity error just before sending and after a response arrives, so the client cannot tell whether a mutation interrupted by an owner change reached the server. It treats every such case as uncertain. Reads keep the ordinary `HTTPError.authorityChanged`.

## Follow

When someone else already requested a title, the detail page offers **Notify Me** instead of a second request. It shows only when `follow_supported` is true and the title's `request` has `reason: "already_requested"`, a request that reads as pending or on the way (the same display state the primary action uses), and `requested_by_viewer: false`. A title in the library, or one the viewer requested, has nothing to follow. The page does not use `/requests/mine` for this: that list covers the whole account, so another profile's request appears in it, and that profile's siblings can still follow. `following` decides the label: **Notify Me** or **Stop Notifying Me**.

- `PUT /api/v2/requests/follows/{media_type}/{tmdb_id}` requires 200 and returns the title's request state, which replaces the page's.
- `DELETE` on the same path requires 204 with no body; the page sets `following` to false.

Both are naturally idempotent and on the replay allowlist, so a 401 refreshes the session and sends them again, and a failure leaves the button as it was for another try. An uncertain outcome holds the button until a re-read of the title shows whether it landed (no re-read after an owner change). When it landed, the page confirms it and publishes it like any other toggle; otherwise it shows the error. A detail read that overlaps a toggle is read again rather than installed, so it cannot undo the toggle. A capability problem refreshes the requests capability, which hides the action when following is gone; any other problem re-reads the title. A successful toggle is published on `RequestsEventBus.lastTitleState`, which patches search and discover cards and the detail cache so the next first frame agrees. On tvOS the button stays enabled while a toggle runs and only its label changes, so focus stays on it.

## Error copy

v2 folds "already requested", "already available" and "invalid state" into one `conflict` problem, and the quota problem carries its counts. `RequestErrorCopy` therefore shows the problem's `detail`, which the contract marks safe to show. `validation_failed` and the capability problems use fixed copy, and `client_upgrade_required` uses the app-update message.

This covers the existing request screens only. It does not add watch-provider or history-import management. Jellyfin protocol behavior is unchanged.
