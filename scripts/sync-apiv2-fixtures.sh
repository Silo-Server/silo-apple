#!/usr/bin/env bash
# Vendor the silo-server contract fixtures the Apple tests consume, at an
# explicit server commit, and record that commit in a SOURCE file:
#
#   iosApp/Tests/Fixtures/APIv2               <- contracts/api/v2/fixtures
#                                                (SELECTED bodies, their index
#                                                entries) + fixtures.schema.json
#   iosApp/Tests/Fixtures/DiagnosticsContract <- docs/design/schemas/client-diagnostics/v1
#
# Every byte comes from `git show <commit>:<path>` in the server repository,
# never from its working tree or its current HEAD, so the commit recorded in
# SOURCE always reproduces the vendored files and the result does not depend
# on what the server checkout happens to have checked out. The OpenAPI
# document is never vendored. Tests/Fixtures/SettingsContract is vendored
# separately (see its SOURCE).
#
# Usage: scripts/sync-apiv2-fixtures.sh <server-ref>
#   <server-ref>      any commit-ish the server repository resolves (a full or
#                     abbreviated commit is preferred over a moving branch)
#   SILO_SERVER_REPO  path to a silo-server checkout (required)
#
# Afterwards regenerate the project: cd iosApp && xcodegen generate.
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <server-ref>   (server repository: \$SILO_SERVER_REPO)" >&2
  exit 2
fi
REF="$1"
SERVER="${SILO_SERVER_REPO:-}"
[ -n "$SERVER" ] || { echo "set SILO_SERVER_REPO to a silo-server checkout" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APIV2_DEST="$ROOT/iosApp/Tests/Fixtures/APIv2"
APIV2_SRC="contracts/api/v2/fixtures"
APIV2_SCHEMA="contracts/api/v2/fixtures.schema.json"
DIAG_DEST="$ROOT/iosApp/Tests/Fixtures/DiagnosticsContract"
DIAG_SRC="docs/design/schemas/client-diagnostics/v1"

# Server fixtures the Apple tests read. listAdminUsers is web-only and
# deliberately absent. An AUTHORED fixture that the server starts publishing
# must move here (the script refuses to run until it does).
SELECTED=(
  # System, account, progress, profile and the generic problem shapes.
  get_setup_status_ok
  get_current_user_ok
  get_system_info_ok
  list_progress_ok
  list_progress_profile_header_required
  list_progress_offset_rejected
  update_profile_ok
  update_profile_null_not_clearable
  authentication_required
  validation_failed_body
  not_found
  rate_limited
  profile_verification_required
  not_acceptable
  # Downloads.
  download_capability
  download_manifest
  download_status_event
  downloads_empty
  # Playback.
  playback_capability_available
  playback_capability_unconfigured
  playback_installation_changed
  playback_invalid_protocol
  playback_progress_applied
  playback_progress_stale
  playback_start_opaque_ids
  playback_stop_completed
  # Subtitles and libraries.
  subtitle_ai_job_opaque_id
  subtitle_ai_quota
  subtitles_search_partial
  subtitles_stored
  user_libraries
  # Catalog and metadata AI capability documents; they pin the unwired v2
  # decoders.
  get_catalog_filters_ok
  get_catalog_search_capabilities_ok
  get_metadata_ai_capability_ok
  # Item detail and trailer refresh.
  get_catalog_item_ok
  refresh_catalog_item_trailers_ok
  # Image size negotiation.
  get_image_capabilities_ok
  # Device sign-in, pairing and Apple push display; the tests replay these
  # bodies through the stubbed transport.
  login_ok
  start_device_login_ok
  get_device_login_ok
  poll_device_login_ok
  get_device_login_capability_ok
  notification_apple_push_display
)

# Fixtures written by hand from the server OpenAPI document, for cases the
# server fixture set does not publish. The script never overwrites them. Any
# other *.json in the APIv2 directory is stale and the script deletes it.
AUTHORED=(
  playback_control_capabilities
  playback_stop_draining
)

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
git -C "$SERVER" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "not a git repository: $SERVER (set SILO_SERVER_REPO)" >&2; exit 1; }
SHA="$(git -C "$SERVER" rev-parse --verify --quiet "$REF^{commit}")" \
  || { echo "server ref $REF does not name a commit in $SERVER" >&2; exit 1; }
COMMIT_DATE="$(git -C "$SERVER" show -s --format=%cs "$SHA")"

show() { git -C "$SERVER" show "$SHA:$1"; }
list_tree() { git -C "$SERVER" ls-tree -r --name-only "$SHA" -- "$1/"; }

for path in "$APIV2_SRC/index.json" "$APIV2_SCHEMA" "$DIAG_SRC/manifest.schema.json"; do
  git -C "$SERVER" cat-file -e "$SHA:$path" 2>/dev/null \
    || { echo "$path does not exist at $SHA" >&2; exit 1; }
done

# --- API v2 fixtures ---------------------------------------------------------

published="$(list_tree "$APIV2_SRC" | sed "s|^$APIV2_SRC/||")"
# A here-string, not a pipe: grep -q exits on the first match, and under
# pipefail a writer still filling the pipe would fail the lookup.
is_published() { grep -qxF -- "$1" <<< "$published"; }
in_list() { local needle="$1" n; shift; for n in "$@"; do [ "$n" = "$needle" ] && return 0; done; return 1; }

for name in "${SELECTED[@]}"; do
  is_published "$name.json" || { echo "$APIV2_SRC/$name.json does not exist at $SHA" >&2; exit 1; }
done
for name in ${AUTHORED[@]+"${AUTHORED[@]}"}; do
  if in_list "$name" "${SELECTED[@]}"; then
    echo "$name is in both SELECTED and AUTHORED" >&2
    exit 1
  fi
  if is_published "$name.json"; then
    echo "$name.json is client-authored but the server publishes it at $SHA; move it from AUTHORED to SELECTED" >&2
    exit 1
  fi
  [ -f "$APIV2_DEST/$name.json" ] || { echo "client-authored $APIV2_DEST/$name.json is missing" >&2; exit 1; }
done

# Drop fixtures that are in neither list, such as one removed from SELECTED
# after the server deleted or renamed it, so they are never kept as if they
# were client-authored.
removed=0
for file in "$APIV2_DEST"/*.json; do
  [ -e "$file" ] || continue
  name="$(basename "$file" .json)"
  case "$name" in index|fixtures.schema) continue ;; esac
  in_list "$name" "${SELECTED[@]}" ${AUTHORED[@]+"${AUTHORED[@]}"} && continue
  rm "$file"
  echo "removed stale $name.json (in neither SELECTED nor AUTHORED)"
  removed=$((removed + 1))
done

mkdir -p "$APIV2_DEST"
for name in "${SELECTED[@]}"; do
  show "$APIV2_SRC/$name.json" > "$APIV2_DEST/$name.json"
done
names_json="$(printf '%s\n' "${SELECTED[@]}" | jq -R . | jq -s .)"
show "$APIV2_SRC/index.json" | jq --argjson names "$names_json" \
  '{fixtures: [.fixtures[] | select(.name as $n | $names | index($n))]}' \
  > "$APIV2_DEST/index.json"
show "$APIV2_SCHEMA" > "$APIV2_DEST/fixtures.schema.json"

{
  printf 'Source: silo-server %s (plus %s)\n' "$APIV2_SRC" "$APIV2_SCHEMA"
  printf 'Server ref: %s\n' "$REF"
  printf 'Server commit: %s (%s)\n\n' "$SHA" "$COMMIT_DATE"
  printf 'Written by scripts/sync-apiv2-fixtures.sh %s. Every vendored byte is read\n' "$REF"
  printf 'with git show <commit>:<path> from the server repository, never from a\n'
  printf 'working tree. Do not hand-edit the vendored files; re-run the script at a\n'
  printf 'new server commit instead, then cd iosApp && xcodegen generate.\n\n'
  printf 'Vendored from the server, %d files: the SELECTED bodies in the script,\n' "$(( ${#SELECTED[@]} + 2 ))"
  printf 'index.json filtered to those entries, and fixtures.schema.json.\n'
  printf '  fixtures.schema.json\n'
  printf '  index.json\n'
  printf '%s\n' "${SELECTED[@]}" | sort | sed 's/^/  /; s/$/.json/'
  printf '\nClient-authored, %d file(s): the AUTHORED list in the script, written by\n' "${#AUTHORED[@]}"
  printf 'hand from the server OpenAPI document for cases the server fixture set does\n'
  printf 'not publish. They are absent from index.json and the script never\n'
  printf 'overwrites them; it refuses to run once the server publishes one of them,\n'
  printf 'so it can move to SELECTED. The script deletes any other *.json here.\n'
  if [ "${#AUTHORED[@]}" -gt 0 ]; then printf '%s\n' "${AUTHORED[@]}" | sort | sed 's/^/  /; s/$/.json/'; fi
} > "$APIV2_DEST/SOURCE"

# --- Diagnostics contract ----------------------------------------------------

# Mirror the server directory exactly: drop files it no longer carries, keep
# only this directory's own README.md and SOURCE.
diag_files="$(list_tree "$DIAG_SRC" | sed "s|^$DIAG_SRC/||")"
mkdir -p "$DIAG_DEST"
find "$DIAG_DEST" -type f ! -path "$DIAG_DEST/README.md" ! -path "$DIAG_DEST/SOURCE" -delete
find "$DIAG_DEST" -mindepth 1 -type d -empty -delete
while IFS= read -r rel; do
  mkdir -p "$(dirname "$DIAG_DEST/$rel")"
  show "$DIAG_SRC/$rel" > "$DIAG_DEST/$rel"
done <<< "$diag_files"

{
  printf 'Source: silo-server %s\n' "$DIAG_SRC"
  printf 'Server ref: %s\n' "$REF"
  printf 'Server commit: %s (%s)\n\n' "$SHA" "$COMMIT_DATE"
  printf 'Written by scripts/sync-apiv2-fixtures.sh %s, which mirrors the server\n' "$REF"
  printf 'directory with git show <commit>:<path>. README.md and this SOURCE are the\n'
  printf 'only files not copied from the server. Do not hand-edit the rest.\n\n'
  printf 'Vendored from the server, %d files:\n' "$(printf '%s\n' "$diag_files" | grep -c .)"
  printf '%s\n' "$diag_files" | sed 's/^/  /'
} > "$DIAG_DEST/SOURCE"

echo "vendored ${#SELECTED[@]} API v2 fixtures and the diagnostics contract from $SHA ($REF)"
echo "left ${#AUTHORED[@]} client-authored API v2 fixtures untouched, removed $removed stale"
