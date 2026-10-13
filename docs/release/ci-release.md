# CI / TestFlight Release

Releases run from GitHub Actions on `main`. Each run picks its own version and
build number.

## TestFlight build

Actions → **TestFlight Release** → Run workflow, leaving `bump` on `build` and
`platform` on `both` (or pick `ios` / `tvos`). The very first run has no
earlier tag to continue from: enter `1.0.0` as `version`.

The run tags the commit `v1.0.0-beta.66`, publishes a GitHub prerelease with the
pull requests merged since the previous build (grouped by label), and uploads
iOS and tvOS `1.0.0 (66)` to TestFlight's external groups. The Features and
Fixes from those notes become TestFlight's "What to Test".

Every run first runs the Apple regression workflow (SiloTests, SiloTVTests,
SiloMac build) on the release commit, or reuses a matching main run's result.
If it fails, the run publishes nothing and uploads nothing. The gate adds about
one regression run (20-30 minutes) unless a main run can be reused.

The prerelease and its source archive are published before any binary, because
the app links that archive (see `THIRD_PARTY_NOTICES.md`). Never delete a
prerelease whose build shipped.

When distribution succeeds, the run adds a "TestFlight: distributed …" line to
the prerelease. If a run fails before that, use **Re-run failed jobs**: it keeps
the same build number. To abandon the build instead, delete its GitHub release
and tag. The next run refuses to start while the newest prerelease lacks that
line, so its notes don't skip changes no tester got, and Promote only accepts a
build that has it.

## Store release

1. Actions → **Promote to App Store** → enter the TestFlight build to ship, such
   as `v1.0.0-beta.66`. It drafts the GitHub release `v1.0.0` on that build's
   commit, with notes since the last App Store release. Nothing is rebuilt.
2. In App Store Connect, add that build to the iOS and tvOS versions and submit
   them for review.
3. Edit the draft notes on GitHub, and publish them as the latest release once
   Apple approves the version.

While the draft exists, the version counts as released: TestFlight Release
refuses `bump: build`, and `bump: minor` starts the next version. If App Review
rejects the build, delete the draft, fix the problem, make another TestFlight
build of the same version, and promote that one.

## After an App Store release

App Store Connect closes a marketing version to new builds, TestFlight
included, once it is approved. The next run needs `bump: minor` (the next
version has new features) or `bump: patch` (fixes only); `bump: build` refuses a
released version. The first build of each new version goes through Beta App
Review once; later builds of the same version don't.

## Numbers

- `1.0.0` is the marketing version. It stays the same for every TestFlight build
  until it is approved for the App Store.
- `66` is the build number, shared by iOS and tvOS: one more than the latest
  TestFlight build on either platform (and any build already tagged).
- Tags: `vX.Y.Z-beta.B` for TestFlight builds (GitHub prereleases) and `vX.Y.Z`
  for App Store releases. Earlier manual runs published `source-<commit>`
  releases instead; those stay, because shipped builds link their archives.

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
