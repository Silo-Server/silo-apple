# Personal collection API v2

Personal collection lists decode `items` and `groups`. Collection and group creation use POST. Move and group rename use PATCH; moving to Ungrouped sends an explicit `group_id: null`.

An editor or delete confirmation first reads the canonical collection or group resource. Its ETag stays attached to the captured account and profile and is sent unchanged as `If-Match`. Background list refreshes do not replace it. A 412 keeps the sheet and draft open, blocks submission, and requires an explicit reload and review. Group controls require the server's `groups` capability.

Apple has no existing collection/group/item reorder, membership mutation, import, artwork, or template consumers. Those actions are not added by this migration. Personal collection cards use `GET /api/v2/catalog?source=user_collection&collection_id=...` and the shared catalog card model. Each load follows opaque cursor pages of 50 under one account/profile identity. The existing complete-list views publish only the finished result; malformed continuation, a failed page, identity changes, or the 100-page safety limit fail the load. Refresh explicitly restarts after an invalid cursor. Raw membership records are never decoded as cards.

Regular library collection listing/browsing and general catalog browsing remain on their existing transport; this slice changes only the personal collection source.
