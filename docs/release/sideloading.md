# Sideloading (unsigned IPA) builds

The **Sideload IPA Build** workflow (`.github/workflows/sideload-ipa.yml`) produces
**unsigned** iOS and tvOS IPAs. They are meant to be re-signed by the end user
with their own Apple account and sideloaded via AltStore, SideStore, Sideloadly,
or similar. This is separate from the TestFlight pipeline
([ci-release.md](ci-release.md)).

## How it differs from the TestFlight build
- **No signing.** Archives are built with `CODE_SIGNING_ALLOWED=NO`; the IPA is
  just `Payload/<App>.app` zipped. The user's sideloading tool strips the
  (absent) signature and applies their own certificate.
- **No secrets.** No Match repo, distribution cert, or App Store Connect key is
  read. The workflow runs on any macOS runner without release credentials.
- **No upload.** Nothing goes to Apple. Artifacts are published to the workflow
  run and, on tag builds, attached to the GitHub Release.

## How it triggers
- Push tag `vX.Y.Z` → builds both IPAs and attaches them to that tag's release.
- Manual: Actions → "Sideload IPA Build" → Run workflow → enter `version` and
  pick `platform` (`both` / `ios` / `tvos`); the run mints a
  `v<version>-build.<run>` tag and attaches the IPAs to it. Tag pushes always
  build both platforms.

The marketing version resolves the same way as the TestFlight workflow
(`scripts/ci/resolve-marketing-version.sh`). The archives are unsigned, so
nothing is sequenced against App Store Connect and the two jobs run in
parallel.

## Telling two sideload builds apart
Both trigger paths stamp `CFBundleVersion` from the workflow's
`github.run_number`, so every sideloaded IPA is distinguishable from every
other build of the same marketing version — including several prerelease tags
of one version, which carry no build number of their own to count from.
Re-running a workflow run reproduces its build number rather than minting a
new one, so a re-run cannot republish a different binary under a number that
already shipped.

The unsigned lanes additionally set `SILO_BUILD_CHANNEL=sideload`, which the
app reports to the server as `X-Silo-Client-Channel`. That is what separates a
re-signed sideload build from the TestFlight build of the same marketing
version and build number in the server's Activity page.

## Fastlane lanes
    bundle exec fastlane ios ipa_ios_unsigned    # -> build/ios-unsigned/Silo-unsigned.ipa
    bundle exec fastlane ios ipa_tvos_unsigned   # -> build/tvos-unsigned/SiloTV-unsigned.ipa

Both run locally with no credentials.

## Caveats to communicate to users
- **Re-signing changes entitlements.** When re-signed with a personal/free
  account, the app's keychain-sharing group and any App Groups are remapped to
  the user's team prefix. The app runs, but features that depend on a fixed
  group identifier may behave differently.
- **Free accounts expire in 7 days** and are limited to 3 active apps; a paid
  developer account lasts ~1 year.
- **tvOS needs a host machine.** Unlike iOS, Apple TV has no on-device
  installer. Users pair the Apple TV with a host (Mac + AltServer/Xcode, or a
  Linux box running atvloadly) over the network before installing, and the host
  must be reachable for refreshes.
- **tvOS Top Shelf extension.** It is embedded in `SiloTV.app` and archived
  automatically. Re-signers who cannot sign the extension (common on free
  accounts) can strip it before sideloading — the app installs without Top Shelf.
- tvOS sideloading is more sensitive to OS version; new tvOS releases can
  temporarily break the sideloading tools.
