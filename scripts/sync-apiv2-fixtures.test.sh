#!/usr/bin/env bash
# Runs scripts/sync-apiv2-fixtures.sh against a throwaway server repository
# and a copy of the Apple fixture layout, so it never touches this checkout.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# The names in one of the script's arrays, one per line.
array_names() {
  sed -n "/^$1=(/,/^)/p" "$here/sync-apiv2-fixtures.sh" | sed -n 's/^  \([a-z0-9_]*\)$/\1/p'
}
selected="$(array_names SELECTED)"
authored="$(array_names AUTHORED)"
[ -n "$selected" ] || fail "could not read SELECTED from the script"
[ -n "$authored" ] || fail "could not read AUTHORED from the script"
first_authored="$(printf '%s\n' "$authored" | head -n 1)"

apple="$tmp/apple"
dest="$apple/iosApp/Tests/Fixtures/APIv2"
mkdir -p "$apple/scripts" "$dest"
cp "$here/sync-apiv2-fixtures.sh" "$apple/scripts/"
sync="$apple/scripts/sync-apiv2-fixtures.sh"

server="$tmp/server"
fixtures="$server/contracts/api/v2/fixtures"
mkdir -p "$fixtures" "$server/docs/design/schemas/client-diagnostics/v1"
git -C "$server" init -q
commit() {
  git -C "$server" add -A
  git -C "$server" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    commit -q -m "$1"
  git -C "$server" rev-parse HEAD
}

while IFS= read -r name; do
  printf '{"fixture":"%s"}\n' "$name" > "$fixtures/$name.json"
done <<< "$selected"
# Pad the listing well past a pipe buffer. A lookup that pipes the listing
# into grep -q under pipefail fails for names near the top of this list.
i=0
while [ "$i" -lt 3000 ]; do
  printf '{}\n' > "$fixtures/zz_padding_fixture_with_a_long_enough_name_$i.json"
  i=$((i + 1))
done
{
  printf '{"fixtures":['
  printf '%s\n' "$selected" | sed 's/.*/{"name":"&"}/' | paste -sd, -
  printf ',{"name":"not_selected"}]}\n'
} > "$fixtures/index.json"
printf '{"title":"fixtures"}\n' > "$server/contracts/api/v2/fixtures.schema.json"
printf '{"title":"manifest"}\n' > "$server/docs/design/schemas/client-diagnostics/v1/manifest.schema.json"
base="$(commit base)"

# Must fail and leave the fixture directory exactly as it was.
expect_reject() {
  local desc="$1" pattern="$2"; shift 2
  local before after status=0 out
  before="$(cd "$dest" && ls -A)"
  out="$(SILO_SERVER_REPO="$server" "$sync" "$@" 2>&1)" || status=$?
  [ "$status" -ne 0 ] || fail "$desc: expected a non-zero exit"
  printf '%s\n' "$out" | grep -qF -- "$pattern" || fail "$desc: expected '$pattern' in: $out"
  after="$(cd "$dest" && ls -A)"
  [ "$before" = "$after" ] || fail "$desc: the fixture directory changed"
  ok "$desc"
}

status=0
env -u SILO_SERVER_REPO "$sync" "$base" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "no SILO_SERVER_REPO: expected exit 2, got $status"
ok "requires SILO_SERVER_REPO"

expect_reject "missing client-authored file" "$first_authored.json is missing" "$base"

while IFS= read -r name; do
  printf '{"hand":"%s"}\n' "$name" > "$dest/$name.json"
done <<< "$authored"
printf '{"stale":true}\n' > "$dest/dropped_from_selected.json"

SILO_SERVER_REPO="$server" "$sync" "$base" >/dev/null
while IFS= read -r name; do
  cmp -s "$fixtures/$name.json" "$dest/$name.json" || fail "$name.json differs from the server copy"
done <<< "$selected"
ok "vendors every SELECTED fixture despite a listing larger than a pipe buffer"
while IFS= read -r name; do
  [ "$(cat "$dest/$name.json")" = "{\"hand\":\"$name\"}" ] || fail "$name.json was overwritten"
done <<< "$authored"
ok "keeps client-authored fixtures"
[ ! -e "$dest/dropped_from_selected.json" ] || fail "stale fixture was kept"
! grep -qF dropped_from_selected "$dest/SOURCE" || fail "SOURCE lists the stale fixture"
ok "deletes a fixture in neither SELECTED nor AUTHORED"
authored_block="$(sed -n '/^Client-authored/,$p' "$dest/SOURCE" | sed -n 's/^  //p')"
[ "$authored_block" = "$(printf '%s\n' "$authored" | sort | sed 's/$/.json/')" ] \
  || fail "SOURCE client-authored block is: $authored_block"
ok "SOURCE lists exactly the AUTHORED fixtures as client-authored"
[ "$(jq '.fixtures | length' "$dest/index.json")" -eq "$(printf '%s\n' "$selected" | grep -c .)" ] \
  || fail "index.json is not filtered to SELECTED"
ok "filters index.json to SELECTED"

printf '{}\n' > "$fixtures/$first_authored.json"
shadowing="$(commit "publish $first_authored")"
printf '{"stale":true}\n' > "$dest/dropped_from_selected.json"
expect_reject "server publishes a client-authored fixture" "move it from AUTHORED to SELECTED" "$shadowing"

first_selected="$(printf '%s\n' "$selected" | head -n 1)"
git -C "$server" rm -q "contracts/api/v2/fixtures/$first_authored.json" "contracts/api/v2/fixtures/$first_selected.json"
removed="$(commit "remove $first_selected")"
expect_reject "server drops a SELECTED fixture" "$first_selected.json does not exist" "$removed"

echo "ALL PASS"
