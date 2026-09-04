# tvOS Item Detail Redesign — "Squared Skyline" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine the tvOS item-detail pages (movie/series/season/episode/audiobook) into a squared, Skyline-native control family with a pre-Play playback-selection row, a cover-forward audiobook hero, and a cleaner focus model — without restructuring the cinematic layout.

**Architecture:** A view-layer change on the existing `TVDetailHero` + per-type detail views. Today's round controls (`Capsule` pills, `Circle` icon buttons, capsule season chips) are reshaped to one 8 pt rounded-rectangle family. A new `TVPlaybackSelectorRow` consolidates the version picker and the audio/subtitle menus (which already exist in the `⋯` menu) into a webapp-parity row, and adds an Edition selector derived from `FileVersion.edition`. The `ReadableFocusSection` focus workaround is removed; the synopsis becomes an expand-in-place control. The audiobook page gets a cover-forward cinematic hero.

**Tech Stack:** Swift 5 / SwiftUI, tvOS. XcodeGen (`project.yml` → `Silo.xcodeproj`). Design tokens in `SiloTheme.swift`.

---

## Conventions & Verification

**Read before starting any task.**

- **Design language:** Skyline — OLED black, monochrome chrome, white-at-opacity. Squared-control radius = `SiloTheme.smallCornerRadius` (8 pt). Spec: `docs/superpowers/specs/2026-06-15-tvos-detail-redesign-design.md`. Mockups: `docs/tvos-detail-mockups/`.
- **TDD reconciliation (important):** `CLAUDE.md` says *do not add tests for UI changes* — only focused tests for critical/high-risk shared logic. So **only Task 3 (edition grouping) is test-first.** Every other task is **build-and-verify**: make the change, build `SiloTV`, then visually confirm in the tvOS Simulator (`admin` / `water1234` per the SiloTV debugging notes).
- **Build gate (run after every task, must succeed):**
  ```bash
  cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloTV \
    -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
  ```
  Expected: `** BUILD SUCCEEDED **`.
- **After creating any new `.swift` file**, regenerate the project so XcodeGen picks it up (the source dirs are glob-included):
  ```bash
  cd iosApp && xcodegen generate
  ```
- **Logic-test harness caveat:** `iosApp/Tests/DetailVersionSelectionTests.swift` is a standalone `@main` precondition runner; it is **not** wired into `project.yml` or any in-repo CI script. Add Task 3's cases there (matching the existing pattern) and run them via the team's existing harness process. The authoritative per-task gate remains the `SiloTV` build above.
- **Commit** at the end of each task. End every commit message with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

---

## File Structure

**Create:**
- `iosApp/iosApp/Screens/Detail/PlaybackEditions.swift` — pure edition-grouping logic (shared, not tvOS-gated; sibling of `DetailVersionSelection.swift`).
- `iosApp/iosApp/tvOS/Screens/Detail/TVPlaybackSelectorRow.swift` — the squared Edition·Version·Audio·Subtitles row + its menu button style.
- `iosApp/iosApp/tvOS/Screens/Detail/TVExpandableSynopsis.swift` — the hero's expand-in-place synopsis control.

**Modify:**
- `iosApp/iosApp/tvOS/Screens/Detail/TVDetailActions.swift` — reshape `TVPillButtonStyle`, `TVCircleButtonStyle`, `TVVersionPillPlaceholder` to the 8 pt family.
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonChip.swift` — capsule → 8 pt.
- `iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift` — add `tagline`; replace the plain overview `Text` with `TVExpandableSynopsis`.
- `iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift` — selector row in `actionColumn`; drop audio/sub submenus from `⋯`; remove `.readableFocusSection()` + fold About into the hero; pass `tagline`.
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift` — same integration (mirrors movie).
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift` — same integration (mirrors movie).
- `iosApp/iosApp/Screens/Detail/AudiobookDetailContent.swift` — cover-forward tvOS hero + Narration selector + squared chapter rows.
- `iosApp/Tests/DetailVersionSelectionTests.swift` — add edition-grouping cases.

**Delete:**
- `iosApp/iosApp/tvOS/Screens/Detail/ReadableFocusSection.swift`.

---

## Phase 1 — Squared control family

### Task 1: Square the action-button styles

**Files:**
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVDetailActions.swift`

- [ ] **Step 1: Reshape `TVPillButtonStyle` to 8 pt.** In `TVPillButtonBody.body`, replace the three `Capsule()` usages with a rounded rectangle. Change:

```swift
            .overlay(
                Capsule().stroke(
                    innerBorderColor,
                    lineWidth: innerBorderWidth
                )
            )
            .background(Capsule().fill(background))
            .overlay {
                if isFocused {
                    Capsule()
                        .stroke(focusOutlineColor, lineWidth: focusOutlineWidth)
                        .padding(-focusOutlineInset)
                }
            }
```

to:

```swift
            .overlay(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(
                    innerBorderColor,
                    lineWidth: innerBorderWidth
                )
            )
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(background)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius + 2, style: .continuous)
                        .stroke(focusOutlineColor, lineWidth: focusOutlineWidth)
                        .padding(-focusOutlineInset)
                }
            }
```

- [ ] **Step 2: Reshape `TVCircleButtonStyle` into a square tile.** In `TVCircleButtonBody.body`, replace the three `Circle()` usages and keep the 72×72 frame:

```swift
            .background(
                Circle().fill(
                    isFocused ? .white : Color.white.opacity(0.10)
                )
            )
            .overlay(
                Circle().stroke(
                    isFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.34),
                    lineWidth: isFocused ? 1.6 : 1.4
                )
            )
            .overlay {
                if isFocused {
                    Circle()
                        .stroke(Color.white.opacity(0.96), lineWidth: 3)
                        .padding(-5)
                }
            }
```

to:

```swift
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(
                    isFocused ? .white : Color.white.opacity(0.10)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(
                    isFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.34),
                    lineWidth: isFocused ? 1.6 : 1.4
                )
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius + 2, style: .continuous)
                        .stroke(Color.white.opacity(0.96), lineWidth: 3)
                        .padding(-5)
                }
            }
```

- [ ] **Step 3: Square the version placeholder.** In `TVVersionPillPlaceholder.body`, replace both `Capsule()` usages:

```swift
        .background(Capsule().fill(Color.black.opacity(0.42)))
        .overlay(
            Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1.2)
        )
```

to:

```swift
        .background(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(Color.black.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1.2)
        )
```

- [ ] **Step 4: Build.** Run the build gate. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Visually verify** in the tvOS Simulator: open any movie detail — Play/Start Over are squared, the Favorite/Watchlist/Watched/More buttons are square tiles, focus shows a white ring + lift.

- [ ] **Step 6: Commit.**
```bash
git add iosApp/iosApp/tvOS/Screens/Detail/TVDetailActions.swift
git commit -m "tvOS detail: square the hero action-button family (8pt)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: Square the season chips

**Files:**
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonChip.swift`

- [ ] **Step 1: Replace the chip shapes.** In `TVSeasonChipBody.background`, swap the three `Capsule()` for the 8 pt rounded rectangle:

```swift
    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(Color.white)
        } else if isFocused {
            RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(Color.white.opacity(0.18))
        } else {
            RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1.5)
        }
    }
```

- [ ] **Step 2: Build.** Run the build gate. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Visually verify:** open a multi-season series — the season chips are squared; the selected chip is a solid white rounded-rect, focus shows the ring.

- [ ] **Step 4: Commit.**
```bash
git add iosApp/iosApp/tvOS/Screens/Detail/TVSeasonChip.swift
git commit -m "tvOS detail: square the season selector chips

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — Playback selector row

### Task 3: Edition-grouping logic (test-first)

**Files:**
- Create: `iosApp/iosApp/Screens/Detail/PlaybackEditions.swift`
- Test: `iosApp/Tests/DetailVersionSelectionTests.swift`

- [ ] **Step 1: Write the failing tests.** In `DetailVersionSelectionTests.swift`, register two new cases in `main()` (add the two calls right after `testAutoDisplayPrefersBestVersionOverFirstReturnedVersion()`):

```swift
        testEditionsGroupVersionsByEditionLabel()
        testEditionForFileIdFindsOwningEdition()
```

Then add the two functions (place them after `testAutoDisplayPrefersBestVersionOverFirstReturnedVersion`):

```swift
    private static func decodedVersions(_ json: String) -> [FileVersion] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data(json.utf8))
    }

    private static func testEditionsGroupVersionsByEditionLabel() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "edition": "Director's Cut", "resolution": "4K" },
          { "file_id": 2, "edition": "Director's Cut", "resolution": "1080p" },
          { "file_id": 3, "resolution": "1080p" }
        ]
        """)

        let editions = PlaybackEditions.editions(from: versions)

        precondition(editions.count == 2, "Expected 2 editions; got \(editions.count)")
        precondition(editions[0].label == "Director's Cut", "First edition label wrong: \(editions[0].label)")
        precondition(editions[0].versions.count == 2, "Director's Cut should hold 2 versions")
        precondition(editions[1].label == "Standard", "Untitled edition should be labeled Standard; got \(editions[1].label)")
    }

    private static func testEditionForFileIdFindsOwningEdition() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "edition": "Theatrical", "resolution": "1080p" },
          { "file_id": 2, "edition": "Extended", "resolution": "1080p" }
        ]
        """)

        let edition = PlaybackEditions.edition(forFileId: 2, in: versions)

        precondition(edition?.label == "Extended", "fileId 2 should resolve to Extended; got \(edition?.label ?? "nil")")
    }
```

- [ ] **Step 2: Run the tests to verify they fail.** Run the repo's `DetailVersionSelectionTests` harness (per the Conventions caveat). Expected: a compile failure — `cannot find 'PlaybackEditions' in scope` — because the type doesn't exist yet.

- [ ] **Step 3: Write the implementation.** Create `iosApp/iosApp/Screens/Detail/PlaybackEditions.swift`:

```swift
import Foundation

/// Groups a content's file versions into editions (Director's Cut, Theatrical,
/// …) and resolves the edition that owns a given file. tvOS has no server-side
/// `PlaybackVariant` grouping, so editions are derived from `FileVersion.edition`.
/// A version with no edition label is grouped under "Standard".
enum PlaybackEditions {
    struct Edition: Identifiable, Hashable {
        let id: String          // normalized (lowercased) key
        let label: String       // display name
        let versions: [FileVersion]
    }

    /// Distinct editions in first-seen order.
    static func editions(from versions: [FileVersion]) -> [Edition] {
        var order: [String] = []
        var groups: [String: [FileVersion]] = [:]
        for version in versions {
            let label = normalizedLabel(version.edition)
            let key = label.lowercased()
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(version)
        }
        return order.map { key in
            Edition(
                id: key,
                label: normalizedLabel(groups[key]?.first?.edition),
                versions: groups[key] ?? []
            )
        }
    }

    /// The edition that owns `fileId`, if any.
    static func edition(forFileId fileId: Int?, in versions: [FileVersion]) -> Edition? {
        guard let fileId else { return nil }
        return editions(from: versions).first { edition in
            edition.versions.contains { $0.fileId == fileId }
        }
    }

    private static func normalizedLabel(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Standard" : trimmed
    }
}
```

- [ ] **Step 4: Regenerate + run tests to verify they pass.**
```bash
cd iosApp && xcodegen generate
```
Run the `DetailVersionSelectionTests` harness. Expected: process exits 0 (no `precondition` traps).

- [ ] **Step 5: Build gate.** Expected: `** BUILD SUCCEEDED **` (confirms `PlaybackEditions` compiles into the app targets).

- [ ] **Step 6: Commit.**
```bash
git add iosApp/iosApp/Screens/Detail/PlaybackEditions.swift iosApp/Tests/DetailVersionSelectionTests.swift iosApp/Silo.xcodeproj
git commit -m "Add edition-grouping logic derived from FileVersion.edition

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4: The `TVPlaybackSelectorRow` component

**Files:**
- Create: `iosApp/iosApp/tvOS/Screens/Detail/TVPlaybackSelectorRow.swift`

This consolidates Edition·Version·Audio·Subtitles into one squared row, reusing the detail views' existing selection callbacks. It owns the menu contents (today duplicated across the three detail views).

- [ ] **Step 1: Create the file.**

```swift
#if os(tvOS)
import SwiftUI

/// Pre-Play playback-selection row shown under the hero actions. Renders
/// Edition · Version · Audio · Subtitles as squared menu buttons, mirroring
/// the Silo webapp. Each selector auto-hides when there is no real choice.
/// Uses the detail view's existing version/audio/subtitle callbacks; Edition
/// is derived from `FileVersion.edition` and selecting one routes through
/// `onSelectVersion`.
struct TVPlaybackSelectorRow: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    private var editions: [PlaybackEditions.Edition] { PlaybackEditions.editions(from: versions) }
    private var audioTracks: [AudioTrack] { currentVersion?.audioTracks ?? [] }
    private var subtitleTracks: [SubtitleTrack] { currentVersion?.subtitleTracks ?? [] }

    var body: some View {
        if hasAnySelector {
            HStack(spacing: 16) {
                if editions.count > 1 { editionSelector }
                if versions.count > 1 { versionSelector }
                if audioTracks.count > 1 { audioSelector }
                if currentVersion != nil { subtitleSelector }
            }
            .focusSection()
        }
    }

    private var hasAnySelector: Bool {
        editions.count > 1 || versions.count > 1 || audioTracks.count > 1 || currentVersion != nil
    }

    // MARK: - Edition

    private var currentEdition: PlaybackEditions.Edition? {
        PlaybackEditions.edition(forFileId: currentVersion?.fileId, in: versions) ?? editions.first
    }

    private var editionSelector: some View {
        TVSelectorButton(icon: "rectangle.stack", label: "Edition", value: currentEdition?.label ?? "—") {
            ForEach(editions) { edition in
                Button {
                    // Selecting an edition selects its best version.
                    let best = DetailVersionSelection.displayVersion(
                        versions: edition.versions, selectedFileId: nil, lastFileId: nil
                    )
                    onSelectVersion(best?.fileId)
                } label: {
                    selectorMenuItem(title: edition.label,
                                     detail: "\(edition.versions.count) version\(edition.versions.count == 1 ? "" : "s")",
                                     isSelected: currentEdition?.id == edition.id)
                }
            }
        }
    }

    // MARK: - Version

    private var versionSelector: some View {
        TVSelectorButton(icon: "4k.tv", label: "Version", value: versionShortLabel(currentVersion)) {
            Button { onSelectVersion(nil) } label: {
                selectorMenuItem(title: "Auto", detail: "Best match for this device", isSelected: selectedVersionFileId == nil)
            }
            ForEach(scopedVersions) { version in
                Button { onSelectVersion(version.fileId) } label: {
                    selectorMenuItem(title: versionShortLabel(version),
                                     detail: versionDetailLabel(version),
                                     isSelected: selectedVersionFileId == version.fileId)
                }
            }
        }
    }

    /// When an edition is active, the Version menu lists only that edition's files.
    private var scopedVersions: [FileVersion] {
        if editions.count > 1, let edition = currentEdition { return edition.versions }
        return versions
    }

    private func versionShortLabel(_ version: FileVersion?) -> String {
        guard let version else { return "Auto" }
        var tokens: [String] = []
        if let res = version.resolution, !res.isEmpty { tokens.append(res.uppercased()) }
        if version.hdr == true { tokens.append("HDR") }
        return tokens.isEmpty ? "Auto" : tokens.joined(separator: " · ")
    }

    private func versionDetailLabel(_ version: FileVersion) -> String {
        var tokens: [String] = []
        if let codec = version.codecVideo, !codec.isEmpty { tokens.append(codec.uppercased()) }
        if let container = version.container, !container.isEmpty { tokens.append(container.uppercased()) }
        return tokens.joined(separator: " · ")
    }

    // MARK: - Audio

    private var audioSelector: some View {
        TVSelectorButton(icon: "speaker.wave.2", label: "Audio", value: audioValueLabel) {
            Button { onSelectAudioTrack(nil) } label: {
                selectorMenuItem(title: "Auto", detail: "Use the file default track", isSelected: selectedAudioTrackIndex == nil)
            }
            ForEach(audioTracks) { track in
                Button { onSelectAudioTrack(track.index) } label: {
                    selectorMenuItem(title: audioTitle(track), detail: audioDetail(track),
                                     isSelected: selectedAudioTrackIndex == (track.index ?? -1))
                }
            }
        }
    }

    private var audioValueLabel: String {
        if selectedAudioTrackIndex == nil { return "Auto" }
        if let track = audioTracks.first(where: { ($0.index ?? -1) == selectedAudioTrackIndex }) { return audioTitle(track) }
        return "Auto"
    }

    private func audioTitle(_ track: AudioTrack) -> String {
        if let title = track.title, !title.isEmpty { return title }
        var tokens: [String] = []
        if let lang = track.language, !lang.isEmpty { tokens.append(lang.uppercased()) }
        if let codec = track.codec, !codec.isEmpty { tokens.append(codec.uppercased()) }
        return tokens.isEmpty ? "Track \((track.index ?? 0) + 1)" : tokens.joined(separator: " ")
    }

    private func audioDetail(_ track: AudioTrack) -> String {
        track.isDefault == true ? "Default" : ""
    }

    // MARK: - Subtitles

    private var subtitleSelector: some View {
        TVSelectorButton(icon: "captions.bubble", label: "Subtitles", value: subtitleValueLabel) {
            Button { onSelectSubtitleTrack(nil) } label: {
                selectorMenuItem(title: "Auto", detail: "Use your subtitle preferences", isSelected: selectedSubtitleTrackIndex == nil)
            }
            Button { onSelectSubtitleTrack(-1) } label: {
                selectorMenuItem(title: "Off", detail: "Start without subtitles", isSelected: selectedSubtitleTrackIndex == -1)
            }
            ForEach(subtitleTracks) { track in
                Button { onSelectSubtitleTrack(track.index) } label: {
                    selectorMenuItem(title: subtitleTitle(track), detail: subtitleDetail(track),
                                     isSelected: selectedSubtitleTrackIndex == (track.index ?? -1))
                }
            }
        }
    }

    private var subtitleValueLabel: String {
        if selectedSubtitleTrackIndex == nil { return "Auto" }
        if selectedSubtitleTrackIndex == -1 { return "Off" }
        if let track = subtitleTracks.first(where: { ($0.index ?? -1) == selectedSubtitleTrackIndex }) { return subtitleTitle(track) }
        return "Auto"
    }

    private func subtitleTitle(_ track: SubtitleTrack) -> String {
        if let title = track.title, !title.isEmpty { return title }
        if let lang = track.language, !lang.isEmpty { return lang.uppercased() }
        return "Track \((track.index ?? 0) + 1)"
    }

    private func subtitleDetail(_ track: SubtitleTrack) -> String {
        var tokens: [String] = []
        if track.forced == true { tokens.append("Forced") }
        if track.isDefault == true { tokens.append("Default") }
        return tokens.joined(separator: " · ")
    }

    // MARK: - Shared menu item

    @ViewBuilder
    private func selectorMenuItem(title: String, detail: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(detail.isEmpty ? title : "\(title) — \(detail)", systemImage: "checkmark")
        } else {
            Text(detail.isEmpty ? title : "\(title) — \(detail)")
        }
    }
}

/// One squared selector button: `[icon] LABEL  value  ⌄`, opening a `Menu`.
/// Matches the secondary squared button look (translucent fill + hairline).
private struct TVSelectorButton<MenuContent: View>: View {
    let icon: String
    let label: String
    let value: String
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .tracking(1.0)
                    .opacity(0.6)
                Text(value).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).opacity(0.6)
            }
        }
        .menuStyle(.button)
        .buttonStyle(TVPillButtonStyle(kind: .secondary))
    }
}
#endif
```

- [ ] **Step 2: Verify the model property names compile.** `TVPlaybackSelectorRow` reads `version.resolution`, `version.hdr`, `version.codecVideo`, `version.container`, `version.audioTracks`, `version.subtitleTracks`, and `track.index`, `track.language`, `track.codec`, `track.title`, `track.isDefault`, `track.forced`. If any name differs (e.g. `track.isDefault` vs `track.default`), open `iosApp/iosApp/Networking/Models.swift`, find the `AudioTrack` / `SubtitleTrack` / `FileVersion` structs, and adjust the references to the real names. (The build in Step 4 will surface mismatches.)

- [ ] **Step 3: Regenerate the project.**
```bash
cd iosApp && xcodegen generate
```

- [ ] **Step 4: Build gate.** Fix any property-name mismatches reported, then re-build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**
```bash
git add iosApp/iosApp/tvOS/Screens/Detail/TVPlaybackSelectorRow.swift iosApp/Silo.xcodeproj
git commit -m "Add TVPlaybackSelectorRow (edition/version/audio/subtitles)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5: Wire the selector row into the detail views

Replace the standalone version picker with the selector row, and remove the now-duplicated audio/subtitle submenus from the `⋯` menu. The view-model state and callbacks already exist.

**Files:**
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift`
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift`
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift`

- [ ] **Step 1: Movie — swap the version picker for the selector row.** In `TVMovieDetailView.actionColumn`, replace:

```swift
    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionRow
            if availableVersions.count > 1 {
                versionPicker
            }
        }
    }
```

with:

```swift
    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionRow
            TVPlaybackSelectorRow(
                versions: availableVersions,
                currentVersion: DetailVersionSelection.displayVersion(
                    versions: availableVersions,
                    selectedFileId: selectedVersionFileId,
                    lastFileId: detail.userData?.lastFileId
                ),
                selectedVersionFileId: selectedVersionFileId,
                selectedAudioTrackIndex: selectedAudioTrackIndex,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                onSelectVersion: onSelectVersion,
                onSelectAudioTrack: onSelectAudioTrack,
                onSelectSubtitleTrack: onSelectSubtitleTrack
            )
        }
    }
```

- [ ] **Step 2: Movie — slim the `⋯` menu.** The audio/subtitle pickers now live in the selector row, so delete the two `Menu { … }` blocks from `moreMenu` (the `if !selectableAudioTracks.isEmpty { Menu … }` block and the `if supportsSubtitleSelection { Menu … }` block, lines ~150–213). Keep only the "Go to Season" / "Go to Series" buttons. Then update `hasMoreMenu` so the `⋯` only appears for navigation:

```swift
    private var hasMoreMenu: Bool {
        hasOverflowNavigation
    }
```

Delete the now-unused `versionPicker` computed property. (Leave `selectableAudioTracks` / `supportsSubtitleSelection` if still referenced elsewhere; the build will flag any unused-and-now-undefined references.)

- [ ] **Step 3: Series — same swap.** In `TVSeriesDetailView`, find the action area that renders `TVVersionPillButton(currentLabel:)` (≈ line 154) and the `TVVersionPillPlaceholder()` (≈ line 74). Replace the `TVVersionPillButton(...) { … }` with the same `TVPlaybackSelectorRow(...)` call as Step 1, using the series' next-up version/track state (`selectedVersionFileId`, `selectedAudioTrackIndex`, `selectedSubtitleTrackIndex`, and the next-up detail's `versions`/`userData?.lastFileId`). Keep the `TVVersionPillPlaceholder()` for the loading state. Remove the audio/subtitle submenus from the series `⋯` menu as in Step 2.

- [ ] **Step 4: Season — same swap.** In `TVSeasonDetailView`, replace the `TVVersionPillButton(currentLabel: currentVersionLabel(for: episode))` (≈ line 226) with `TVPlaybackSelectorRow(...)` for the season's next-up episode, and remove the audio/subtitle submenus from its `⋯` menu.

- [ ] **Step 5: Build gate.** Resolve any references to deleted helpers. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Visually verify:** on a movie with multiple versions/tracks, the selector row appears under the actions showing Version/Audio/Subtitles (and Edition if the title has cuts); each opens a squared menu; the `⋯` button only shows for episode navigation.

- [ ] **Step 7: Commit.**
```bash
git add iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift \
        iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift \
        iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift
git commit -m "tvOS detail: surface edition/version/audio/subtitles as a pre-Play selector row

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 3 — Focus & scroll model

### Task 6: Expand-in-place synopsis

**Files:**
- Create: `iosApp/iosApp/tvOS/Screens/Detail/TVExpandableSynopsis.swift`
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift`

- [ ] **Step 1: Create the control.**

```swift
#if os(tvOS)
import SwiftUI

/// The hero's overview as an expand-in-place control. Clamped to 3 lines;
/// Select expands to the full overview (with the tagline above it) and back.
/// This is the detail page's only text focus stop — reachable by pressing Up
/// from the action row — and it is actionable, so it never feels "stuck".
struct TVExpandableSynopsis: View {
    let overview: String
    let tagline: String?

    @State private var expanded = false
    private let maxWidth: CGFloat = 1200

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 12) {
                if expanded, let tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.system(size: 28, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(.white.opacity(0.85))
                }
                Text(overview)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(.white.opacity(0.82))
                    .lineSpacing(8)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVSynopsisButtonStyle())
        .animation(.easeOut(duration: SiloTheme.normalDuration), value: expanded)
    }
}

/// No chrome at rest; on focus a faint underline-style fill cue so the user
/// knows it's actionable. Suppresses the system halo (matches the page idiom).
private struct TVSynopsisButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration) }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        var body: some View {
            configuration.label
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous)
                        .fill(Color.siloSurfaceElevated.opacity(isFocused ? 0.55 : 0))
                )
                .padding(.horizontal, -20)
                .padding(.vertical, -14)
                .focusEffectDisabled()
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        }
    }
}
#endif
```

- [ ] **Step 2: Add a `tagline` parameter to the hero.** In `TVDetailHero`, after the `overview` stored property add:

```swift
    /// Optional tagline shown above the overview when the synopsis is expanded.
    let tagline: String?
```

- [ ] **Step 3: Use the control in the hero.** In `editorialColumn`, replace:

```swift
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.82))
                    .lineSpacing(8)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
            }
```

with:

```swift
            if let overview, !overview.isEmpty {
                TVExpandableSynopsis(overview: overview, tagline: tagline)
            }
```

- [ ] **Step 4: Pass `tagline` from the three call sites.** In `TVMovieDetailView`, `TVSeriesDetailView`, and `TVSeasonDetailView`, every `TVDetailHero(...)` initializer call must add `tagline: detail.tagline,` (place it right after the `overview:` argument). There is one call in each file (movie ≈ line 38).

- [ ] **Step 5: Regenerate + build gate.**
```bash
cd iosApp && xcodegen generate
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Visually verify:** open a movie, press **Up** from Play — focus lands on the synopsis with a faint fill; press Select — it expands to full text (with tagline); Select again collapses.

- [ ] **Step 7: Commit.**
```bash
git add iosApp/iosApp/tvOS/Screens/Detail/TVExpandableSynopsis.swift \
        iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift \
        iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift \
        iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift \
        iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift \
        iosApp/Silo.xcodeproj
git commit -m "tvOS detail: expand-in-place hero synopsis (with tagline)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 7: Remove the ReadableFocusSection workaround

The synopsis (Task 6) now owns the full overview + tagline, so the body **About** section is redundant; the **Details** (facts) block stays but as plain, non-focusable content that scrolls into view with its neighboring rail.

**Files:**
- Delete: `iosApp/iosApp/tvOS/Screens/Detail/ReadableFocusSection.swift`
- Modify: `TVMovieDetailView.swift`, `TVSeriesDetailView.swift`, `TVSeasonDetailView.swift`

- [ ] **Step 1: Movie — drop About + the focus modifier.** In `TVMovieDetailView.body`, replace:

```swift
                    detailsSection
                        .readableFocusSection()
                    aboutSection
                        .readableFocusSection()
```

with:

```swift
                    detailsSection
```

Then delete the now-unused `aboutSection` computed property from the file.

- [ ] **Step 2: Series — same.** In `TVSeriesDetailView` (call sites ≈ lines 54, 56), remove both `.readableFocusSection()` modifiers and the `aboutSection` usage; delete the unused `aboutSection` property. Keep `detailsSection` plain.

- [ ] **Step 3: Season — same.** In `TVSeasonDetailView` (call sites ≈ lines 63, 66), do the same. (Season already omits About when the overview is empty — remove the `aboutSection` usage and the `.readableFocusSection()` modifiers; keep `detailsSection` plain.)

- [ ] **Step 4: Delete the file.**
```bash
git rm iosApp/iosApp/tvOS/Screens/Detail/ReadableFocusSection.swift
```

- [ ] **Step 5: Regenerate + build gate.**
```bash
cd iosApp && xcodegen generate
```
Expected: `** BUILD SUCCEEDED **` (and no remaining references to `readableFocusSection`).

- [ ] **Step 6: Visually verify:** pressing **Down** from the hero moves action row → selector row → first rail → next rail, never dead-ending on a paragraph; the Details facts scroll into view as you reach the rail above/below them.

- [ ] **Step 7: Commit.**
```bash
git add -A iosApp/iosApp/tvOS/Screens/Detail/ iosApp/Silo.xcodeproj
git commit -m "tvOS detail: remove ReadableFocusSection; fold About into hero synopsis

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 4 — Audiobook facelift

### Task 8: Cover-forward audiobook hero

**Files:**
- Modify: `iosApp/iosApp/Screens/Detail/AudiobookDetailContent.swift`

- [ ] **Step 1: Replace the tvOS header with a cinematic cover-forward hero.** Replace the `header` computed property's tvOS branch. Change:

```swift
    @ViewBuilder
    private var header: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 48) {
            cover(size: coverSize)
            headerText
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.top, 24)
            Spacer(minLength: 0)
        }
        .padding(.top, 120)
        #else
```

to:

```swift
    @ViewBuilder
    private var header: some View {
        #if os(tvOS)
        ZStack(alignment: .bottomLeading) {
            audiobookBackdrop
            HStack(alignment: .center, spacing: 56) {
                cover(size: coverSize)
                headerText
                    .frame(maxWidth: 900, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.bottom, 64)
            .padding(.top, 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
```

- [ ] **Step 2: Add the backdrop + an eyebrow.** Add these to the tvOS section of the file (e.g. just before `cover(size:)`):

```swift
    #if os(tvOS)
    /// A blurred, darkened wash of the square cover stands in for a 16:9
    /// backdrop, keeping the audiobook page in the cinematic family.
    @ViewBuilder
    private var audiobookBackdrop: some View {
        ZStack {
            if let url = detail.posterUrl, !url.isEmpty {
                AsyncImageView(url: url, thumbhash: detail.posterThumbhash,
                               targetSize: CGSize(width: 600, height: 600), contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 760)
                    .clipped()
                    .blur(radius: 60)
                    .opacity(0.5)
            } else {
                Color.siloSurface.frame(height: 760)
            }
            LinearGradient(
                stops: [
                    .init(color: Color.siloBackground.opacity(0.55), location: 0.0),
                    .init(color: Color.siloBackground.opacity(0.30), location: 0.5),
                    .init(color: Color.siloBackground, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 760)
        }
        .frame(height: 760)
        .clipped()
    }

    private var audiobookEyebrow: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.85))
                .frame(width: 34, height: 4).cornerRadius(2)
            Text("AUDIOBOOK")
                .font(.system(size: 18, weight: .bold)).tracking(3)
                .foregroundColor(.white.opacity(0.78))
        }
    }
    #endif
```

- [ ] **Step 3: Show the eyebrow above the title (tvOS only).** In `headerText`, add the eyebrow at the top of the `VStack`:

```swift
    private var headerText: some View {
        VStack(alignment: headerAlignment, spacing: 14) {
            #if os(tvOS)
            audiobookEyebrow
            #endif
            Text(detail.title)
                .font(titleFont)
```

- [ ] **Step 4: Build gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Visually verify:** open an audiobook — the cover sits left over a blurred-cover backdrop with the eyebrow tick; the squared Resume/Start Over buttons sit beneath the metadata.

- [ ] **Step 6: Commit.**
```bash
git add iosApp/iosApp/Screens/Detail/AudiobookDetailContent.swift
git commit -m "tvOS audiobook: cover-forward cinematic hero

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 9: Narration selector + squared chapter rows

**Files:**
- Modify: `iosApp/iosApp/Screens/Detail/AudiobookDetailContent.swift`

- [ ] **Step 1: Square the chapter rows.** In the tvOS `TVAudiobookRowBody`, change the fill radius from 14 to the 8 pt family:

```swift
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.06))
            )
```

- [ ] **Step 2: Add a Narration selector under the actions (tvOS).** In the tvOS `actionRow`, append a narration menu after the Start Over button when alternate narrations exist:

```swift
        HStack(spacing: 24) {
            TVPrimaryPillButton(icon: "play.fill", title: primaryPlayLabel) {
                audioStore.play(contentId: detail.contentId, restart: false, startPosition: resumePosition)
            }

            TVSecondaryPillButton(icon: "arrow.counterclockwise", title: "Start Over") {
                audioStore.play(contentId: detail.contentId, restart: true)
            }

            if !otherNarrations.isEmpty {
                Menu {
                    ForEach(otherNarrations) { narration in
                        Button { onNavigateToItem(narration.contentId) } label: {
                            Text(narration.narrators.isEmpty ? narration.title
                                 : narration.narrators.joined(separator: ", "))
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.wave.2").font(.system(size: 22, weight: .semibold))
                        Text("NARRATION").font(.system(size: 18, weight: .bold)).tracking(1.0).opacity(0.6)
                        Text(currentNarratorLabel).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).opacity(0.6)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(TVPillButtonStyle(kind: .secondary))
            }
        }
```

- [ ] **Step 3: Add the `currentNarratorLabel` helper** (tvOS-safe; place near `metadataLine`):

```swift
    private var currentNarratorLabel: String {
        joinedNames(detail.audiobook?.narrators) ?? "Default"
    }
```

- [ ] **Step 4: Build gate.** If `TVPillButtonStyle` is not visible from this file's module scope, confirm it is in the same target (it is — both build into `SiloTV`). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Visually verify:** an audiobook with multiple narrations shows the squared Narration selector; chapter rows are squared.

- [ ] **Step 6: Commit.**
```bash
git add iosApp/iosApp/Screens/Detail/AudiobookDetailContent.swift
git commit -m "tvOS audiobook: narration selector + squared chapter rows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 5 — Polish & final pass

### Task 10: Reduce Motion + full verification

**Files:**
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVExpandableSynopsis.swift` (and any control using a scale/expand animation)

- [ ] **Step 1: Honor Reduce Motion in the synopsis.** In `TVExpandableSynopsis`, gate the expand animation:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
```
and change the modifier to:
```swift
        .animation(reduceMotion ? nil : .easeOut(duration: SiloTheme.normalDuration), value: expanded)
```

- [ ] **Step 2: Confirm the squared button/chip focus already respects Reduce Motion** or is acceptable (the existing styles animate `isFocused` via `SiloTheme.springAnimation`; leave as-is unless it visibly janks — these predate this redesign).

- [ ] **Step 3: Full build gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Full visual pass** against the spec's acceptance criteria (`docs/superpowers/specs/2026-06-15-tvos-detail-redesign-design.md` §13): movie, series (season chips + episodes), season, episode, and audiobook — squared controls everywhere, selector row behavior, synopsis expand, focus path, audiobook hero.

- [ ] **Step 5: Commit.**
```bash
git add iosApp/iosApp/tvOS/Screens/Detail/TVExpandableSynopsis.swift
git commit -m "tvOS detail: respect Reduce Motion in synopsis expand

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the executor

- **Property-name reality check (Task 4):** the selector formatters assume `AudioTrack`/`SubtitleTrack`/`FileVersion` field names (`isDefault`, `forced`, `index`, `language`, `codec`, `title`, `resolution`, `hdr`, `codecVideo`, `container`). Verify against `iosApp/iosApp/Networking/Models.swift` and adjust; the build will flag mismatches.
- **Series/Season next-up (Task 5):** these pages target the *next-up episode's* file. Reuse whatever next-up version/track state each view already feeds its `TVVersionPillButton` (the same `selected*`/`onSelect*` values) — just route them into `TVPlaybackSelectorRow` instead.
- **Open questions from the spec (§14):** editions are grouped by raw label here (no server `edition_key`); edition stickiness rides on the sticky version; downloaded-subtitle flows are out of tvOS scope for now. Revisit with the server team if needed.
- **Out of scope:** iOS/iPadOS/macOS detail layouts (the `Phone*`/Mac paths) — do not touch.
