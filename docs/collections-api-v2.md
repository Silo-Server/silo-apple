# Personal collection API v2

Personal collection lists decode `items` and `groups`. Collection and group creation use POST. Move and group rename use PATCH; moving to Ungrouped sends an explicit `group_id: null`.

An editor or delete confirmation first reads the canonical collection or group resource. Its ETag stays attached to the captured account and profile and is sent unchanged as `If-Match`. Background list refreshes do not replace it. A 412 keeps the sheet and draft open, blocks submission, and requires an explicit reload and review. Group controls require the server's `groups` capability.

Apple has no existing collection/group/item reorder, membership mutation, import, artwork, or template consumers. Those actions are not added by this migration. Personal collection card browsing is a separate migration slice; raw membership records must not be decoded as catalog cards.
