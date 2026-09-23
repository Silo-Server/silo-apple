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
#   SILO_SERVER_REPO  server repository (default: /Volumes/NVMe/dev/github/SiloServer/silo-server)
#
# Afterwards regenerate the project: cd iosApp && xcodegen generate.
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <server-ref>   (server repository: \$SILO_SERVER_REPO)" >&2
  exit 2
fi
REF="$1"
SERVER="${SILO_SERVER_REPO:-/Volumes/NVMe/dev/github/SiloServer/silo-server}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APIV2_DEST="$ROOT/iosApp/Tests/Fixtures/APIv2"
APIV2_SRC="contracts/api/v2/fixtures"
APIV2_SCHEMA="contracts/api/v2/fixtures.schema.json"
DIAG_DEST="$ROOT/iosApp/Tests/Fixtures/DiagnosticsContract"
DIAG_SRC="docs/design/schemas/client-diagnostics/v1"

# Server fixtures the Apple tests read. listAdminUsers is web-only and
# deliberately absent. A client-authored fixture that the server starts
# publishing must move here (the script refuses to run until it does).
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
is_published() { printf '%s\n' "$published" | grep -qxF "$1"; }
is_selected() { local n; for n in "${SELECTED[@]}"; do [ "$n.json" = "$1" ] && return 0; done; return 1; }

for name in "${SELECTED[@]}"; do
  is_published "$name.json" || { echo "$APIV2_SRC/$name.json does not exist at $SHA" >&2; exit 1; }
done

# Client-authored fixtures are every other *.json here. One the server now
# publishes must be replaced by the published copy, not kept beside it.
authored=()
for file in "$APIV2_DEST"/*.json; do
  base="$(basename "$file")"
  case "$base" in index.json|fixtures.schema.json) continue ;; esac
  is_selected "$base" && continue
  if is_published "$base"; then
    echo "$base is client-authored here but the server publishes it at $SHA; add it to SELECTED" >&2
    exit 1
  fi
  authored+=("$base")
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
  printf '\nClient-authored, %d file(s): written by hand from the server OpenAPI document\n' "${#authored[@]}"
  printf 'for cases the server fixture set does not publish. They are absent from\n'
  printf 'index.json and the script never overwrites them; it refuses to run once the\n'
  printf 'server publishes one of them, so it can move to SELECTED.\n'
  if [ "${#authored[@]}" -gt 0 ]; then printf '  %s\n' "${authored[@]}"; fi
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
echo "left ${#authored[@]} client-authored API v2 fixtures untouched"
