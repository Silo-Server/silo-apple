#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/check-no-api-v1.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/iosApp/iosApp/Networking" "$tmp/iosApp/Tests" "$tmp/iosApp/Other"
cat > "$tmp/iosApp/iosApp/Networking/Client.swift" <<'SWIFT'
let a = "/api/v1/health"
let b = base + ["api", "v1", "stream"]
let c = url.appendingPathComponent("api").appendingPathComponent("v1")
let d = "/api/v2/items" // /api/v1/items and api/v1/users on one line
SWIFT
printf 'let e = "/api/v2/items"\n' > "$tmp/iosApp/Tests/ClientTests.swift"
printf 'let f = "/api/v1/ignored"\n' > "$tmp/iosApp/Other/Outside.swift"

run() { "$script" --root "$tmp" --allowlist "$tmp/allow.txt" "$@"; }

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }

run --print-counts > "$tmp/allow.txt"
grep -qx $'iosApp/iosApp/Networking/Client.swift\t5' "$tmp/allow.txt" || fail "counts every occurrence in scanned dirs"
grep -q 'Outside.swift\|ClientTests.swift' "$tmp/allow.txt" && fail "skips clean files and unscanned dirs"
ok "print-counts"

run > /dev/null || fail "matching tree passes"
ok "unchanged tree passes"

printf 'let g = "/api/v1/more"\n' >> "$tmp/iosApp/iosApp/Networking/Client.swift"
out="$(run 2>&1)" && fail "raised count fails"
[[ "$out" == *"has 6 /api/v1 path match(es); the allowlist permits 5"* ]] || fail "raised count message: $out"
[[ "$out" == *"Client.swift:5:"* ]] || fail "raised count lists offending lines: $out"
ok "raised count fails"

printf 'let h = "api/v1/new"\n' >> "$tmp/iosApp/Tests/ClientTests.swift"
out="$(run 2>&1)" && fail "new file fails"
[[ "$out" == *"iosApp/Tests/ClientTests.swift has 1 /api/v1 path match(es) and is not in the allowlist"* ]] || fail "new file message: $out"
[[ "$out" == *"--print-counts"* ]] || fail "explains how to update: $out"
ok "unlisted file fails"

: > "$tmp/empty.txt"
out="$("$script" --root "$tmp" --allowlist "$tmp/empty.txt" 2>&1)" && fail "empty allowlist fails"
[[ "$out" == *"allowlist is empty or missing its header"* ]] || fail "empty allowlist message: $out"
grep -v '^#' "$tmp/allow.txt" > "$tmp/headerless.txt"
"$script" --root "$tmp" --allowlist "$tmp/headerless.txt" > /dev/null 2>&1 && fail "headerless allowlist fails"
ok "empty or headerless allowlist fails"

printf 'let a = "/api/v2/health"\n' > "$tmp/iosApp/iosApp/Networking/Client.swift"
printf 'let e = "/api/v2/items"\n' > "$tmp/iosApp/Tests/ClientTests.swift"
run > /dev/null || fail "lowered count passes the ceiling check"
ok "lowered count passes"
out="$(run --exact 2>&1)" && fail "lowered count fails with --exact"
[[ "$out" == *"has 0 /api/v1 path match(es); the allowlist still records 5"* ]] || fail "exact message: $out"
ok "lowered count fails with --exact"

echo "ALL PASS"
