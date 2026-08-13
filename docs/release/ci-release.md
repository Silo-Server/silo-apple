# CI / TestFlight Release

## How releases trigger
- Push tag `vX.Y.Z` (e.g. `v1.4.0`) → builds iOS + tvOS, uploads to TestFlight,
  distributes to external groups, notifies testers.
- Push prerelease tag `vX.Y.Z-beta.N` → same, marketing version `X.Y.Z`.
- **Single platform via tag:** append a `+ios` or `+tvos` build-metadata suffix
  — `vX.Y.Z+ios` releases iOS only, `vX.Y.Z+tvos` tvOS only. Plain `vX.Y.Z`
  releases both. Works with prereleases too (`vX.Y.Z-beta.N+ios`). The marketing
  version stays `X.Y.Z` (the suffix is stripped).
- Manual: Actions tab → "TestFlight Release" → Run workflow → enter `version`
  and pick `platform` (`both` / `ios` / `tvos`).

A single-platform selection builds only that platform; the other job is skipped.

The git tag is the marketing version. A preflight `build-numbers` job reserves
the next per-platform build number from App Store Connect once, then the iOS and
tvOS jobs **build in parallel** consuming those fixed numbers (no build-number
race). On a both-platform run the two are independent — tvOS still releases even
if iOS fails; their build-number sequences are separate, so a gap is harmless.

## Required repository secrets
| Secret | Purpose |
|---|---|
| `TEAM_ID` | Apple Developer team ID |
| `MATCH_GIT_URL` | Private match certs repo URL |
| `MATCH_PASSWORD` | match encryption passphrase |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 `user:token` for read-only HTTPS clone of the certs repo |
| `APP_STORE_CONNECT_API_KEY_KEY_ID` | ASC API key ID |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | ASC API key issuer ID |
| `APP_STORE_CONNECT_API_KEY_KEY` | base64 of the `.p8` key (`base64 < AuthKey_XXX.p8 \| tr -d '\n'`) |
| `TESTFLIGHT_EXTERNAL_GROUPS` | comma-separated external TestFlight group name(s) |

## Renewing signing assets (run LOCALLY, not in CI)
CI runs `match` read-only and cannot create certs/profiles. When a cert expires,
a device is added, or entitlements / App IDs change (e.g. the keychain-group or
bundle-namespace change), regenerate locally and push to the certs repo:

    bundle exec fastlane match appstore --platform ios  --readonly false
    bundle exec fastlane match appstore --platform tvos --readonly false

Then re-run the release. If CI fails with a missing-profile error, this is the fix.
