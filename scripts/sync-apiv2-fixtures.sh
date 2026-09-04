#!/usr/bin/env bash
# Vendor the API v2 contract fixtures this client consumes from a silo-server
# checkout into iosApp/Tests/Fixtures/APIv2 and record the exact server commit
# in SOURCE. Only the selected fixtures, the index entries that describe them,
# and fixtures.schema.json are copied; the OpenAPI document is never vendored.
#
# Usage: scripts/sync-apiv2-fixtures.sh /path/to/silo-server
set -euo pipefail

SERVER="${1:?usage: $0 <silo-server checkout>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/iosApp/Tests/Fixtures/APIv2"
SRC_DIR="contracts/api/v2/fixtures"
SRC="$SERVER/$SRC_DIR"
SCHEMA="contracts/api/v2/fixtures.schema.json"

# Pilot operations Apple consumes (getSetupStatus, getCurrentUser,
# listProgress, updateProfile), the probe's system-info contract, and the
# generic problem shapes. listAdminUsers is web-only and deliberately absent.
SELECTED=(
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
)

[ -d "$SRC" ] || { echo "no fixtures at $SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

mkdir -p "$DEST"
find "$DEST" -maxdepth 1 -name '*.json' -delete
for name in "${SELECTED[@]}"; do
  cp "$SRC/$name.json" "$DEST/$name.json"
done

names_json="$(printf '%s\n' "${SELECTED[@]}" | jq -R . | jq -s .)"
jq --argjson names "$names_json" \
  '{fixtures: [.fixtures[] | select(.name as $n | $names | index($n))]}' \
  "$SRC/index.json" > "$DEST/index.json"
cp "$SERVER/$SCHEMA" "$DEST/fixtures.schema.json"

sha="$(git -C "$SERVER" rev-parse HEAD)"
ref="$(git -C "$SERVER" rev-parse --abbrev-ref HEAD)"
{
  printf 'Source: silo-server %s (plus %s)\n' "$SRC_DIR" "$SCHEMA"
  printf 'Server ref: %s\n' "$ref"
  printf 'Server commit: %s\n' "$sha"
  printf 'Vendored: %s\n\n' "$(date -u +%Y-%m-%d)"
  printf 'Selected fixtures only (see SELECTED in scripts/sync-apiv2-fixtures.sh); index.json is\n'
  printf 'filtered to those entries. Refresh with scripts/sync-apiv2-fixtures.sh <silo-server checkout>\n'
  printf 'from the server commit above, then regenerate Silo.xcodeproj with cd iosApp && xcodegen generate.\n'
} > "$DEST/SOURCE"

echo "vendored ${#SELECTED[@]} fixtures from $sha into $DEST"
