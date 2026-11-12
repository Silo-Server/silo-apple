#!/usr/bin/env bash
# Blocks text lookups that ignore the app language in the Apple sources:
# String(localized:), AttributedString(localized:), NSLocalizedString( and
# Bundle.localizedString(forKey:).
#
# They resolve text in the process language, so they ignore the profile's app
# language until the next launch. SwiftUI views take text from the root's
# \.locale; a String built anywhere else goes through AppLanguage.string(_:),
# the one file allowed to call String(localized:).
#
# Usage: scripts/ci/check-string-localized.sh [--root DIR]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
case "${1:-}" in
  "") ;;
  --root) [[ -n "${2:-}" ]] || { echo "check-string-localized: --root needs a directory" >&2; exit 2; }; root="$2" ;;
  *) echo "check-string-localized: unknown argument: $1" >&2; exit 2 ;;
esac
cd "$root"

allowed="iosApp/iosApp/Shared/AppLanguage.swift"
scan_dirs=()
for dir in iosApp/iosApp iosApp/TopShelf iosApp/NotificationService iosApp/DownloadsActivity; do
  [[ -d "$dir" ]] && scan_dirs+=("$dir")
done

matches="$(grep -rnIE --include='*.swift' 'String\([[:space:]]*localized:|NSLocalizedString\(|\.localizedString\(forKey:' "${scan_dirs[@]}" | grep -v "^${allowed}:" || true)"
if [[ -z "$matches" ]]; then
  echo "check-string-localized: ok"
  exit 0
fi
printf '%s\n' "$matches"
cat <<'MSG'

error: these lines resolve text in the process language, not the app language.
Return a LocalizedStringResource for the view to render, or call
AppLanguage.string(_:) when a String is needed outside a view.
MSG
exit 1
