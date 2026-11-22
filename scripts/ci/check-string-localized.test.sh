#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/check-string-localized.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
run() { "$script" --root "$tmp"; }

mkdir -p "$tmp/iosApp/iosApp/Shared" "$tmp/iosApp/TopShelf" "$tmp/iosApp/Tests"
printf 'return String(localized: resource)\n' > "$tmp/iosApp/iosApp/Shared/AppLanguage.swift"
printf 'let t = String(localized: "x")\n' > "$tmp/iosApp/Tests/Allowed.swift"
run > /dev/null || fail "the helper file and tests are allowed"
ok "allowed files pass"

for line in 'let a = String(localized: .commonCancel)' 'let b = AttributedString(localized: "k")' \
            'let c = NSLocalizedString("k", comment: "")' 'let d = Bundle.main.localizedString(forKey: "k", value: nil, table: nil)' \
            'let e = String( localized: "k")'; do
  printf '%s\n' "$line" > "$tmp/iosApp/TopShelf/Use.swift"
  out="$(run 2>&1)" && fail "flags: $line"
  [[ "$out" == *"TopShelf/Use.swift:1:"* ]] || fail "names the line: $out"
done
ok "each lookup form fails"

"$script" --bogus > /dev/null 2>&1 && fail "unknown argument fails"
ok "unknown argument fails"
