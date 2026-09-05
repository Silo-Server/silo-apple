# Rebuild Silo with a modified ASS library

This archive contains the tracked Silo app at `revisions.json`'s `app_revision`,
all Swift package source snapshots from its `Package.resolved`, and the five
C-library source trees used by its pinned AssKit build. The manifest records
the immutable revisions and SHA-256 digests of the downloaded source archives.
The app snapshot excludes untracked files, signing overrides, and credentials.

Use a Mac with Xcode 26.3 and its command-line tools, XcodeGen 2.43.0, and the
build tools required by AssKit: Meson, Ninja, pkg-config, Autoconf, Automake,
Libtool, Make, and Python 3. The Apple SDK and your own signing identity are
provided separately. The supplied app build uses network access to resolve
its other unchanged, pinned Swift packages; their sources are also included
under `packages/` for inspection or local package overrides in Xcode.

1. Edit the desired library source, for example
   `packages/asskit/build/src/fribidi/`.
2. From `packages/asskit/`, run `bash build-local.sh`. It performs the upstream
   build for iOS, tvOS, their simulators, and macOS, replacing the local Vendor
   frameworks. Its only change from the included upstream `build.sh` is that
   it skips source fetching, so the build uses your edited source trees.
   Do not run the upstream `clean` or fetching paths over your modifications.
3. In `app/iosApp/project.yml`, replace the AssKit package's `url` and
   `revision` entries with `path: ../../packages/asskit`. This makes the app
   link your rebuilt AssKit and FriBidi frameworks.
4. From `app/iosApp/`, run:

   ```sh
   xcodegen generate
   xcodebuild build -project Silo.xcodeproj -scheme Silo \
     -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
   ```

   Use scheme `SiloTV` and `generic/platform=tvOS Simulator` for tvOS, or
   scheme `SiloMac` and `platform=macOS` for macOS. For a physical device,
   configure your own signing using the included
   `app/iosApp/Signing/Local.xcconfig.sample` and repository build instructions.

The result links the modified static library into a rebuilt application.
Release signing keys and App Store provisioning profiles are not needed for
the simulator build and are not included in this archive.
