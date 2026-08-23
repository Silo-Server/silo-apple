# Deploy SiloTV from the Mac Studio to the bedroom Apple TV

Use this procedure when the active Silo Apple checkout is on the Mac Studio and the requested
target is the physical `bedroom TV`. The TV is paired to the home Mac mini, not the Studio.

The required topology is:

```text
active checkout on Mac Studio
  -> XcodeGen and signed generic tvOS build on Studio
  -> transfer the finished Debug-appletvos bundle through ssh-mac-builder
  -> devicectl install, launch, and verify on the paired mini
  -> bedroom Apple TV
```

`/Users/macdev/.local/bin/ssh-mac-builder` is the Studio-to-mini gateway. It routes through the
trusted dev-builder hop. Do not replace it with direct SSH merely because the direct route looks
shorter; direct reachability and credentials differ.

## 1. Pin and preserve the requested source

Run from the active Silo Apple checkout:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
```

Build the current working tree, including intentional uncommitted application changes. Record the
commit and status first, do not reset or clean the checkout, and compare `git status --short` again
after deployment. Generated `iosApp/Silo.xcodeproj` state is expected to remain ignored.

## 2. Confirm the mini can see the correct TV

Discover devices on the paired mini immediately before deployment. Never reuse a saved UUID:

```bash
/Users/macdev/.local/bin/ssh-mac-builder 'xcrun devicectl list devices'
```

Continue only when the row named `bedroom TV` says `available (paired)`. If it is unavailable, the
TV is probably asleep; ask the user to wake it instead of repeatedly installing or launching.

`devicectl` may print `CoreDeviceError Code=1002 "No provider was found"` and still continue
successfully. Treat that message as noise only when the same command subsequently reports the
real device result. It is not proof of success by itself.

## 3. Regenerate and build on the Studio

The Studio owns compilation and signing. Do not sync this checkout to the mini and do not build a
simulator or unsigned product.

Make the Silo development-team identifier available through the existing local signing
configuration or the `SILO_APPLE_TEAM_ID` shell variable; do not add it to the repository. The
commands below use the variable and fail early when it is missing. If `Local.xcconfig` already
supplies `DEVELOPMENT_TEAM`, omit both the early check and the command-line override. Then run:

```bash
cd iosApp
/opt/homebrew/bin/xcodegen generate

test -n "${SILO_APPLE_TEAM_ID:-}" || {
  echo 'SILO_APPLE_TEAM_ID is not set' >&2
  exit 1
}

set -o pipefail
xcodebuild build \
  -project Silo.xcodeproj \
  -scheme SiloTV \
  -configuration Debug \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath "$HOME/silo-build-tvos" \
  DEVELOPMENT_TEAM="$SILO_APPLE_TEAM_ID" \
  -allowProvisioningUpdates \
  2>&1 | tee "/tmp/silo-tvos-build-$(git rev-parse --short=8 HEAD).log" \
  | grep -E --line-buffered 'error:|warning:|BUILD (SUCCEEDED|FAILED)'
```

The installable product must be:

```text
$HOME/silo-build-tvos/Build/Products/Debug-appletvos/SiloTV.app
```

Never substitute `Debug-appletvsimulator`. `CODE_SIGNING_ALLOWED=NO` is also wrong for this
workflow because it produces a compile check, not an installable authenticated device build.

If the filtered command reports failure, inspect the full `/tmp/silo-tvos-build-<sha>.log` before
diagnosing. Do not infer the cause from the last few Xcode lines.

## 4. Validate the exact bundle before transfer

```bash
app="$HOME/silo-build-tvos/Build/Products/Debug-appletvos/SiloTV.app"
test -d "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements :- "$app" 2>/dev/null | plutil -p -
```

Require bundle identifier `org.siloserver.silo`, a successful deep signature check, and signed
application/keychain entitlements. Stop before transfer if any check fails.

## 5. Transfer the signed device bundle to the mini

Create a unique remote staging path and stream the finished bundle. This preserves the app bundle
structure and avoids rebuilding or signing through the mini's noninteractive keychain session.

```bash
stage="/tmp/silo-bedroom-$(git rev-parse --short=8 HEAD)-$(date +%Y%m%d%H%M%S)"
printf '%s\n' "$stage" > /tmp/silo-bedroom-stage-path

tar -C "$HOME/silo-build-tvos/Build/Products/Debug-appletvos" -cf - SiloTV.app \
  | /Users/macdev/.local/bin/ssh-mac-builder \
    "mkdir -p '$stage' && \
     tar -C '$stage' -xf - && \
     codesign --verify --deep --strict --verbose=2 '$stage/SiloTV.app' && \
     /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$stage/SiloTV.app/Info.plist'"
```

Require the mini-side signature verification and bundle identifier check to pass before install.

## 6. Install, confirm app metadata, and launch

```bash
stage=$(< /tmp/silo-bedroom-stage-path)

/Users/macdev/.local/bin/ssh-mac-builder \
  "xcrun devicectl device install app --device 'bedroom TV' '$stage/SiloTV.app'"

/Users/macdev/.local/bin/ssh-mac-builder \
  "xcrun devicectl device info apps \
     --device 'bedroom TV' \
     --bundle-id org.siloserver.silo; \
   xcrun devicectl device process launch \
     --device 'bedroom TV' \
     org.siloserver.silo"
```

Do not stop at `BUILD SUCCEEDED` or `App installed`. Require all three outcomes:

1. Install output names bundle ID `org.siloserver.silo`.
2. App info lists the expected Silo version/build.
3. Launch output says the application was launched.

If launch says the system is asleep, the install may still be valid but deployment is incomplete.
Ask the user to wake the TV, then retry only the launch and verification steps.

## 7. Verify the running process and clean staging

```bash
stage=$(< /tmp/silo-bedroom-stage-path)

/Users/macdev/.local/bin/ssh-mac-builder \
  "xcrun devicectl device info processes --device 'bedroom TV' \
     | grep -E 'org\\.siloserver\\.silo|SiloTV|Silo' || true; \
   mkdir -p \"\$HOME/.Trash\"; \
   mv '$stage' \"\$HOME/.Trash/\""

git status --short
```

Require an on-device process path ending in `/SiloTV.app/SiloTV`. The Top Shelf extension may also
appear. Move remote staging into Trash so cleanup is recoverable, and confirm that the local
checkout still contains exactly the pre-existing changes.

## Completion report

Report the pinned branch and short commit, signed physical-tvOS build result, installed version and
build, launch result, process verification, and whether pre-existing working-tree changes were
preserved. Do not claim success from a simulator build, unsigned compile, install without launch,
or launch without process evidence.
