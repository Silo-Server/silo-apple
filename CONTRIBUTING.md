# Contributing to Silo Apple

The [Silo contribution guide](https://github.com/Silo-Server/.github/blob/main/CONTRIBUTING.md)
covers project-wide coordination, focused changes, evidence, AI disclosure, and
pull request expectations. Those requirements apply here; this guide adds the
Apple-specific workflow.

## Before you start

Open an [issue](https://github.com/Silo-Server/silo-apple/issues) before
implementing a feature, navigation or behavior change, large refactor, or work
that changes the shared server contract. Documentation, narrow fixes, and
well-scoped parity corrections can go straight to a pull request.

This repository owns the iOS, tvOS, and macOS clients. Server/API work belongs
in [`silo-server`](https://github.com/Silo-Server/silo-server), and shared client
behavior should be checked against
[`silo-android`](https://github.com/Silo-Server/silo-android).

## Development setup

Read [README.md](README.md) for prerequisites, signing setup, and build commands,
then read [AGENTS.md](AGENTS.md) for module ownership and platform guidance.
Regenerate `iosApp/Silo.xcodeproj` from `iosApp/project.yml`; never hand-edit the
generated project.

## Validate your change

Build every affected platform and run the focused XCTest targets. A typical
iOS build and simulator test gate is:

```sh
cd iosApp
xcodegen generate
xcodebuild build \
  -project Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test \
  -project Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Simulator tests use ad-hoc signing so Keychain-dependent tests have an application
identity; they do not require a distribution certificate.

The `SiloTests` bundle belongs to the `Silo` scheme; there are currently no
separate tvOS or macOS test bundles. Use `SiloTV` with a tvOS simulator for tvOS
builds and `SiloMac` with `platform=macOS` for macOS builds. Exercise visible
changes in each affected app.

## Show visible changes

A pull request that changes what a user sees must show the change in its
Evidence section, so reviewers can see it without building the branch. In this
repository that means iOS, tvOS, and macOS. A change is visible when it alters
any of these:

- layout, styling, copy, navigation, focus, empty and error states;
- which items a screen shows, or in what order: search results, home sections,
  recommendations, library browsing, collections, sorting, or filtering;
- what an item shows: titles, artwork, descriptions, ratings, badges, episode
  grouping, or availability;
- playback behavior a user notices, such as default audio or subtitle tracks,
  markers, controls, or resume position.

Provide evidence that fits the change:

- **Changes to a screen:** before-and-after screenshots of the same screen with
  the same data, one pair per affected surface. Add a short recording when
  motion, timing, focus movement, or a multi-step flow matters.
- Name the surface and the build or commit each capture came from.

Capture against a test library or public-domain media where you can. Crop or
blur hostnames, URLs, account names, and personal library contents. When the
evidence cannot be made public, a maintainer may link an
`evidence.siloserver.org` page instead. If you could not capture evidence,
say why; the reviewer decides whether the pull request can merge without it.
Changes users cannot see write `Evidence: none, no user-visible change`.

## Open the pull request

Use a Conventional Commit title, fill in the pull request template, explain
which platforms are affected, paste the actual validation results, and call out
any server or Android coordination.
Read the [AI-assisted contribution policy](https://github.com/Silo-Server/silo-server/blob/main/docs/ai-contributions.md)
and include its disclosure block.

## Licensing of contributions

This project is licensed under `AGPL-3.0-or-later` with the App Store /
DRM additional permission in
[APPSTORE-EXCEPTION.md](APPSTORE-EXCEPTION.md).

By submitting a contribution, you agree that it is licensed under those
same terms — the AGPL *including* the App Store additional permission —
and that the project may distribute builds containing your contribution
through application stores such as the Apple App Store and TestFlight as
that permission describes. If you cannot agree to the additional
permission, say so in your pull request before it is merged.

You retain copyright in your contribution; no assignment is requested.

## Practical notes

- Repository layout, build commands, and coding conventions are in
  [AGENTS.md](AGENTS.md) and the docs under `docs/`.
- Third-party components and their licenses are inventoried in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); update it when a
  dependency changes.

## Instructions for coding agents

Coding agents must read [AGENTS.md](AGENTS.md) before changing the repository
(`CLAUDE.md` points to the same guidance). The organization-wide contribution
guide and AI-assisted contribution policy apply to agent and human authors
equally.
