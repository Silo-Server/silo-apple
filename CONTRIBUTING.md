# Contributing to Silo Apple

> [!IMPORTANT]
> The most helpful way to contribute to Silo right now is a clear, accurate
> issue. Pull requests are welcome from contributors who've had one merged in a
> Silo repository, or when a maintainer asks for one. We close other pull
> requests without review.

## Why we're asking for issues

Pull requests now arrive faster than we can review them carefully. Reviewing a
change properly means reading every line, checking it against work already in
flight, re-running validation, and owning the result after it merges. Writing
the change ourselves from a precise issue takes less time, and it keeps every
change on one workflow with the same tests and the same review.

This is about review capacity, not the quality of anyone's work, and it applies
whether or not you used AI. We'll revisit it as Silo approaches 1.0. Thank you
for taking the time to write things up well.

## Write a useful issue

Open an [issue](https://github.com/Silo-Server/silo-apple/issues) for problems
in the iOS, tvOS, and macOS apps. Server and API problems belong in
[`silo-server`](https://github.com/Silo-Server/silo-server/issues/new/choose).
Search first; if an issue already covers the problem, add what's new there.

Using Claude Code or Codex? The
[Silo troubleshooting skill](https://github.com/Silo-Server/silo-troubleshooting-skill)
helps you collect these details and drafts the issue, then has independent
reviewers check it against your evidence before you post it.

- One problem or proposal per issue.
- Describe what you observed before any theory about the cause.
- Give exact steps to reproduce, expected and actual behavior, the app version
  and build, your device and OS version, and the Silo server version.
- Paste raw logs rather than a summary. Redact credentials, tokens, personal
  data, and private media details, mark each redaction, and leave the rest
  untouched.
- For a feature, describe the problem it solves and who it affects.
- If you found the cause or have a fix in mind, add it under a Technical notes
  heading, apart from what you observed. Point to the files involved; a short
  code excerpt is fine. We may implement it differently.
- Disclose AI use, as described in the
  [Silo contribution guide](https://github.com/Silo-Server/.github/blob/main/CONTRIBUTING.md#ai-assisted-contributions).

Report security vulnerabilities privately with **Report a vulnerability** on
the repository's Security tab, not in a public issue.

## Pull requests

Pull requests are welcome from contributors who've had a pull request merged in
a Silo repository, and from anyone a maintainer has asked for one, usually in
an issue comment. The rest of this guide applies to those pull requests.

We close other pull requests without review. That isn't a judgment of the
work. If the problem still matters, open an issue for it and link the closed
pull request; we may use the code as a reference.

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

Capture against a test library or public-domain media where you can, and keep
passwords, tokens, and API keys out of every capture. Then put the evidence in
one of two places:

- **On GitHub:** attach the screenshots or recordings under the pull request's
  Evidence heading. Everything on GitHub is public, so crop or blur hostnames,
  URLs, account names, and personal library contents.
- **On [evidence.siloserver.org](https://evidence.siloserver.org/) (optional):**
  only you and Silo maintainers can open what you publish there, after signing
  in with GitHub, so captures need no cropping or blurring. Captions that start
  with `Before:` and `After:` become a side-by-side comparison, and recordings
  get a player. Upload from the Details link of the pull request's `Evidence`
  check, or with the command line (Node.js 22 or later):
  `npx @silo-server/evidence login` once on each computer, then
  `npx @silo-server/evidence publish <folder> --pr <number>`. The
  [package README](https://www.npmjs.com/package/@silo-server/evidence) describes
  the folder. Then write
  `Evidence: https://evidence.siloserver.org/r/silo-apple/pr-<number>/` under
  the Evidence heading. Until a pull request of yours has merged here, a
  maintainer approves you once before your first upload.

The pull request's `Evidence` check passes once evidence is published or
attached. It asks for evidence when the change touches the app source under `iosApp/iosApp/`,
or when a maintainer adds the `evidence-required` label; a maintainer adds
`evidence-not-needed` when nothing visible changed. Changes users cannot see
write `Evidence: none, no user-visible change`. If you could not capture
evidence, say why; the reviewer decides whether the pull request can merge
without it.

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
