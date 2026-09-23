# Requests API v2 consumer

The Apple clients call `/api/v2/requests` for the request capability, search, discovery, detail, create, My Requests, and cancel. The methods live in `APIv2Client+Requests.swift`; `SiloAPI+Requests.swift` forwards to them. No request falls back to v1.

## Scope and ownership

Every operation is profile scoped. A call needs a selected profile, sends `X-Profile-Id` (plus `X-Profile-Token` when the profile has a proof), and runs under the owner captured when it starts. A profile, account, or server change before dispatch refuses the call; a change while it is in flight discards the response.

## Capability

`GET /api/v2/requests/status` returns `FeatureStatus`. Entry points show only when `requests_enabled` is true, `allowed` is true, and `state` is `available`. A blocked account gets `requests_enabled: true` with `allowed: false`, so its entry points stay hidden. A server without the requests service omits `allowed`; the client reads that as not allowed. A failed probe keeps the previous value.

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
| Definite failure | Never sent (no connection, DNS or TLS failure), or any problem response | Show the error once. The user may try again. |
| Uncertain | Connection lost or timed out after sending, an unexpected 2xx, an unreadable 2xx body | Never resend. Hold the action (the detail CTA shows "Not confirmed yet"; a held cancel hides its menu item) and re-read. A successful re-read releases the hold. |

## Error copy

v2 folds "already requested", "already available" and "invalid state" into one `conflict` problem, and the quota problem carries its counts. `RequestErrorCopy` therefore shows the problem's `detail`, which the contract marks safe to show. `validation_failed` and the capability problems use fixed copy, and `client_upgrade_required` uses the app-update message.

This covers the existing request screens only. It does not add watch-provider or history-import management. Jellyfin protocol behavior is unchanged.
