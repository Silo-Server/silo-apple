# Repository Guidelines

## Project Structure & Module Organization

This repository contains only the Silo Apple clients. SwiftUI app code lives under `iosApp/iosApp/`, tests live in `iosApp/Tests/`, Top Shelf code lives in `iosApp/TopShelf/`, resources live in `iosApp/Resources/`, and generated Xcode structure is controlled by `iosApp/project.yml`. Apple TV playback notes live in `docs/tvos-player/`; release automation lives in `fastlane/`.

## Silo Workspace Context

This repository is part of a broader multi-repo Silo workspace. The sibling
repositories are usually checked out alongside this repository.

- `silo-apple` owns iOS, tvOS, and macOS client code only.
- `silo-server` owns the Go backend, web admin UI, API contracts, auth/session
  behavior, catalog/scanner/playback services, database migrations, Jellyfin
  compatibility, and host-side plugin runtime.
- `silo-android` owns the Android phone and TV clients. When changing shared
  client behavior, compare Android so Apple and Android stay aligned.

When a task touches auth, API models, playback/session state, library browsing,
metadata display, or server-driven behavior, check whether the server and
Android client need coordinated changes. Do not force server concerns into this
repo.

## Build, Test, and Development Commands

- `cd iosApp && xcodegen generate` regenerates `Silo.xcodeproj` from `project.yml`; do this after target or source layout changes.
- `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` builds iOS without local signing.
- Use scheme `SiloTV` with a tvOS simulator destination for tvOS builds.
- Use scheme `SiloMac` with `platform=macOS` for macOS builds.

Those commands assume a local Xcode. When developing from a Linux host, every Apple toolchain
operation runs on the remote `mac-builder` Mac instead — read the `mac-builder` skill first, and
`docs/mac-builder.md` for setup and background.

## Coding Style & Naming Conventions

Use Swift 5 and SwiftUI naming conventions. Types use `PascalCase`; functions and properties use `camelCase`. Keep platform-specific code under the existing `iOS`, `tvOS`, or `macOS` folders and update `project.yml` instead of hand-editing generated `.xcodeproj` files. Preserve existing Apple bundle IDs and keychain groups during this migration for TestFlight continuity.

For tvOS focus work, read `docs/tvos-focus.md` before editing navigation,
menus, grids, or custom controls. Prefer a stable native focus graph or a
single composite focus owner; do not mix row-level focusable controls with
manual directional focus mutation.

## Testing Guidelines

Apple tests use XCTest under `iosApp/Tests/`. Do not add tests for small changes or UI changes unless requested. For shared logic changes, add focused tests only for critical or high-risk behavior.

## Writing

Run a final readability pass on every human-facing issue, pull request,
document, or status update.

- Lead with the outcome.
- Use concrete, plain language and active voice.
- Cut filler, stock framing, repetition, and promotional claims.
- Preserve meaning, evidence, citations, uncertainty, and established
  terminology.
- Never rewrite exact quotations, commands, logs, identifiers, API names, or
  contractual language.
- Match the tone to the audience and use only formatting that improves
  readability.

## Pull requests

Never create a pull request unless the developer explicitly asks for one.

Use a Conventional Commit title in plain language. Start the body with the
problem, explain the solution next, and end with the required AI disclosure,
including the exact model identifier, agent harness, and any other AI tooling.
Include repository-required issue links, validation evidence, risks, and
follow-up work.

- Keep one concern per pull request. If an honest description needs the word
  "also," split the work.
- Include before-and-after images for UI changes. Include a short video when
  motion or timing matters.
- Upload pull request evidence to GitHub. Never commit PR-only assets such as
  `.github/pr-assets/`.
- When babysitting a pull request, poll checks and review comments created
  after the last push. Verify bot findings against the source, fix real issues,
  and dismiss false positives with a written reason. Remain quiet when nothing
  new has appeared. Stop when the latest commit is green.

## Security & Configuration Tips

Do not commit local signing overrides. Start from `iosApp/Signing/Local.xcconfig.sample`, create `iosApp/Signing/Local.xcconfig`, and regenerate with XcodeGen after signing changes. Keep App Store Connect keys, Match repo URLs, and team identifiers in environment variables only.
