# Rebuild Silo with a modified ASS library

This archive contains the tracked Silo app at `revisions.json`'s `app_revision`,
its resolved Swift package sources, and the six native library source trees
listed by SwiftLibass 1.4.0. The manifest records immutable source revisions
and SHA-256 digests of downloaded archives. The app snapshot excludes untracked
files, signing overrides, and credentials.

SwiftLibass's upstream build script clones an unpinned ffmpeg-kit branch.
This archive pins that builder and the tags matching its documented prebuilt
library versions. This makes the included rebuild inputs stable; upstream
does not provide a manifest proving a byte-for-byte match to its prebuilt binaries.

Use a Mac with Xcode and its command-line tools, XcodeGen 2.43.0, and the
prerequisites documented in `packages/swift-libass/.source/ffmpeg-kit/README.md`.
The SDK and your own signing identity are provided separately. Building needs
network access for the builder's additional tools/FFmpeg sources and unchanged
Swift packages. The subtitle library sources listed below are already included.

1. Edit the desired native source under
   `packages/swift-libass/.source/ffmpeg-kit/src/`, for example `fribidi/`.
2. From `packages/swift-libass/`, run `sh build-local.sh`. This runs the upstream
   platform builds and replaces `Libraries/XCFrameworks/` with static libraries
   and headers. The local entry point skips `checkout`, preserving the included
   builder and your source edits. Do not run the upstream checkout/clean paths
   or request source re-downloads over your modifications.
3. In `app/iosApp/project.yml`, replace SwiftLibass's `url` and `exactVersion`
   entries with `path: ../../packages/swift-libass`. Also make SwiftAssRenderer
   local with `path: ../../packages/swift-ass-renderer`, and change its
   SwiftLibass dependency in the applicable `Package*.swift` manifest to
   `.package(path: "../swift-libass")`. This ensures both use your rebuilt library.
4. From `app/iosApp/`, run:

   ```sh
   xcodegen generate
   xcodebuild build -project Silo.xcodeproj -scheme Silo \
     -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
   ```

   Use scheme `SiloTV` and `generic/platform=tvOS Simulator` for tvOS, or
   scheme `SiloMac` and `platform=macOS` for macOS. For a physical device,
   configure your own signing using `Signing/Local.xcconfig.sample` and the
   repository build instructions.

The result links your modified library into a rebuilt application. Release
signing keys and App Store profiles are not needed for simulator compilation
and are not included in this archive.
