#!/usr/bin/env bash
# Runs summarize-what-to-test.sh against a fake curl that records the request
# and replays a canned response.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/summarize-what-to-test.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }

mkdir "$tmp/bin"
cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/args"
for arg in "$@"; do
  # The key header arrives as @<file descriptor>.
  [[ "$arg" == @/dev/fd/* ]] && cat "${arg#@}" > "$FAKE_DIR/key-header"
done
cat > "$FAKE_DIR/request"
cat "$FAKE_DIR/response"
exit "${FAKE_EXIT:-0}"
CURL
chmod +x "$tmp/bin/curl"

cat > "$tmp/notes.md" <<'NOTES'
<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### 🚀 Features
* feat(player): skip recaps automatically by @dev in https://github.com/Silo-Server/silo-apple/pull/764
### 🐛 Fixes
* fix(home): reload Home when the app returns by @dev in https://github.com/Silo-Server/silo-apple/pull/760

## New Contributors
* @newcomer made their first contribution in https://github.com/Silo-Server/silo-apple/pull/700

**Full Changelog**: https://github.com/Silo-Server/silo-apple/compare/a...b
NOTES

reply() { jq -n --arg text "$1" --arg stop "${2:-end_turn}" \
  '{stop_reason: $stop, content: [{type: "thinking", thinking: ""}, {type: "text", text: $text}]}' > "$tmp/response"; }
run() { PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" ANTHROPIC_API_KEY="test-key" "$script" "$tmp/notes.md" "$@"; }

reply $'\nNew\n• Skip recaps automatically\n'
out="$(run)" || fail "summary succeeds"
[[ "$out" == $'New\n• Skip recaps automatically' ]] || fail "prints the trimmed text: $out"
ok "prints the summary"

content="$(jq -r '.messages[0].content' "$tmp/request")"
[[ "$content" == *"- feat(player): skip recaps automatically"* ]] || fail "sends the titles: $content"
[[ "$content" == *"Fixes:"* ]] || fail "sends section names: $content"
[[ "$content" != *"@dev"* && "$content" != *"https://"* && "$content" != *"newcomer"* ]] || fail "sends titles only: $content"
[[ "$(jq -r .model "$tmp/request")" == "claude-opus-5-5" ]] || fail "model"
grep -q "test-key" "$tmp/args" && fail "keeps the key off curl's command line"
[[ "$(cat "$tmp/key-header")" == "x-api-key: test-key" ]] || fail "passes the key header: $(cat "$tmp/key-header")"
ok "sends only titles, and the key only through a file descriptor"

reply "" refusal
out="$(run 2>&1)" && fail "a refusal fails"
[[ "$out" == *"stopped with refusal"* ]] || fail "refusal message: $out"
ok "refusal falls back"

reply "   "
run > /dev/null 2>&1 && fail "an empty summary fails"
reply "$(printf 'x%.0s' {1..50})"
out="$(run 20 2>&1)" && fail "a long summary fails"
[[ "$out" == *"50 characters; the limit is 20"* ]] || fail "length message: $out"
ok "empty and over-long summaries fall back"

reply $'New\n• Sign in at https://example.com/login'
out="$(run 2>&1)" && fail "a summary with a link fails"
[[ "$out" == *"contains a link"* ]] || fail "link message: $out"
ok "a summary with a link falls back"

echo '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' > "$tmp/response"
out="$(FAKE_EXIT=22 run 2>&1)" && fail "an API error fails"
[[ "$out" == *"request failed: Overloaded"* ]] || fail "API error message: $out"
ok "API errors fall back"

out="$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" ANTHROPIC_API_KEY="" "$script" "$tmp/notes.md" 2>&1)" && fail "a missing key fails"
[[ "$out" == *"not set"* ]] || fail "missing key message: $out"
ok "a missing key falls back"
