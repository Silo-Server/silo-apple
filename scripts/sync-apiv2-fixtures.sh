#!/usr/bin/env bash
# Vendor the API v2 contract fixtures this client consumes from a silo-server
# checkout into iosApp/Tests/Fixtures/APIv2 and record the exact server commit
# in SOURCE. Only the selected fixtures, the index entries that describe them,
# and fixtures.schema.json are copied; the OpenAPI document is never vendored.
#
# The bytes come from the server checkout's HEAD commit (`git show HEAD:...`),
# never from its working tree, so the commit recorded in SOURCE always
# reproduces the vendored files. The script refuses to run while the fixture
# paths are dirty in that checkout; commit or stash first. There is no
# --allow-dirty escape hatch on purpose: a SOURCE that names a commit the
# fixtures did not come from is worse than no SOURCE at all.
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

# Refuse a dirty source: the bytes below are read from HEAD, and a working
# tree or index that differs from HEAD means the caller is probably looking at
# fixtures the recorded commit cannot reproduce. Untracked files count too.
dirty="$(git -C "$SERVER" status --porcelain -- "$SRC_DIR" "$SCHEMA")"
if [ -n "$dirty" ]; then
  {
    echo "refusing to vendor: $SRC_DIR or $SCHEMA is modified in $SERVER"
    echo "SOURCE records the HEAD commit, so the fixtures must come from it."
    echo "Commit or stash the server changes first (no --allow-dirty is offered on purpose):"
    echo "$dirty"
  } >&2
  exit 1
fi

# Read from HEAD, not the working tree, so a clean status is not even required
# for byte-for-byte reproducibility from the commit recorded in SOURCE.
show_head() { git -C "$SERVER" show "HEAD:$1"; }

mkdir -p "$DEST"
find "$DEST" -maxdepth 1 -name '*.json' -delete
for name in "${SELECTED[@]}"; do
  show_head "$SRC_DIR/$name.json" > "$DEST/$name.json"
done

names_json="$(printf '%s\n' "${SELECTED[@]}" | jq -R . | jq -s .)"
show_head "$SRC_DIR/index.json" | jq --argjson names "$names_json" \
  '{fixtures: [.fixtures[] | select(.name as $n | $names | index($n))]}' \
  > "$DEST/index.json"
show_head "$SCHEMA" > "$DEST/fixtures.schema.json"

sha="$(git -C "$SERVER" rev-parse HEAD)"
ref="$(git -C "$SERVER" rev-parse --abbrev-ref HEAD)"
{
  printf 'Source: silo-server %s (plus %s)\n' "$SRC_DIR" "$SCHEMA"
  printf 'Server ref: %s\n' "$ref"
  printf 'Server commit: %s\n' "$sha"
  printf 'Vendored: %s\n\n' "$(date -u +%Y-%m-%d)"
  printf 'Selected fixtures only (see SELECTED in scripts/sync-apiv2-fixtures.sh); index.json is\n'
  printf 'filtered to those entries. Bytes are read from the server commit above (git show HEAD:...),\n'
  printf 'never from a working tree. Refresh with scripts/sync-apiv2-fixtures.sh <silo-server checkout>\n'
  printf 'with the fixture paths clean in that checkout, then regenerate Silo.xcodeproj with\n'
  printf 'cd iosApp && xcodegen generate.\n'
} > "$DEST/SOURCE"

echo "vendored ${#SELECTED[@]} fixtures from $sha into $DEST"
