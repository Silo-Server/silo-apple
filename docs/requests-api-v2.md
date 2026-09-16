# Requests API v2 consumer

Request capabilities, search, discovery, detail, create, list, and cancel use `/api/v2/requests`. Calls use the existing v2 contract gate and problem decoder and never fall back to v1. Create and cancel have no automatic transport-error replay; authentication refresh remains the transport's existing 401-only behavior.

Discovery collections decode `items`. Provider search and section pages retain page-number pagination. My Requests follows `page.next_cursor` with a maximum page size of 50 under one captured viewer identity. A failed page, missing or repeated continuation, identity change, or 100-page safety limit fails the load instead of publishing a partial list. Request target and account identifiers are strings; TMDB identifiers remain integers.

This migrates existing request consumers only. It does not add watch-provider or history-import management screens. Jellyfin protocol behavior is unchanged.
