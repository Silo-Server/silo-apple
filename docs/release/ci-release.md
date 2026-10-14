# CI / TestFlight Release

Releases run from GitHub Actions on `main`. Each run picks its own version and
build number.

## TestFlight build

Actions → **TestFlight Release** → Run workflow, leaving `bump` on `build` and
`platform` on `both` (or pick `ios` / `tvos`). The very first run has no
earlier tag to continue from: enter `1.0.0` as `version`.

The run tags the commit `v1.0.0-beta.66`, publishes a GitHub prerelease with the
pull requests merged since the previous build (grouped by label), and uploads
iOS and tvOS `1.0.0 (66)` to TestFlight's external groups.

TestFlight's "What to Test" is Claude's short summary of those pull request
titles: what's new, and where to test. The run sends Claude only the section
names and titles, never pull request bodies, comments, or code. If the summary
fails, or `ANTHROPIC_API_KEY` isn't set, the run uses the plain list of
Features and Fixes instead. Either way the run's summary page shows the text,
and you can edit it in App Store Connect.

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
line, so its notes don't skip changes no tester got. Promote only accepts a
build distributed on both iOS and tvOS, because one App Store release covers
both.

## Store release

1. Actions → **Promote to App Store** → enter the TestFlight build to ship, such
   as `v1.0.0-beta.66`. It drafts the GitHub release `v1.0.0` on that build's
   commit, with notes since the last App Store release. Nothing is rebuilt.
2. In App Store Connect, add that build to the iOS and tvOS versions and submit
   them for review.
3. Start the next version right away: run TestFlight Release with `bump: patch`
   (fixes only) or `bump: minor` (new features). Its first build goes through
   Beta App Review while App Review checks the submitted version, so external
   testers wait only for that review. Internal testers get the build as soon as
   it is processed.
4. Edit the draft notes on GitHub, and publish them as the latest release once
   Apple approves the version.

App Store Connect accepts more builds of a submitted version until Apple
approves it, then closes it to new builds, TestFlight included. Release stops
earlier, at the draft: while it exists the version counts as released and
`bump: build` refuses it, so only one version is in testing at a time.

If App Review rejects the build, delete the draft and fix the problem. Then run
TestFlight Release with `version: 1.0.0`, because once the next version has
started, `bump: build` continues that one. Promote the new build.

## Numbers

- `1.0.0` is the marketing version. It stays the same for every TestFlight build
  until it is promoted to the App Store. The first build of each version goes
  through Beta App Review; later builds of the same version usually don't.
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
| `ANTHROPIC_API_KEY` | Optional. Claude API key for the What to Test summary; without it the run uses the plain list |

## Renewing signing assets (run LOCALLY, not in CI)
CI runs `match` read-only and cannot create certs/profiles. When a cert expires,
a device is added, or entitlements / App IDs change (e.g. the keychain-group or
bundle-namespace change), regenerate locally and push to the certs repo:

    bundle exec fastlane match appstore --platform ios  --readonly false
    bundle exec fastlane match appstore --platform tvos --readonly false

Then re-run the release. If CI fails with a missing-profile error, this is the fix.
