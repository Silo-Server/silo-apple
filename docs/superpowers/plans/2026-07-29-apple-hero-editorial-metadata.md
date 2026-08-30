# Apple Hero Editorial Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove hard-coded technical quality metadata and duplicate cast copy from Apple-client hero surfaces while preserving editorial metadata, artwork enrichment, playback/version selectors, dedicated cast rails, and the current iOS Home experience.

**Architecture:** Keep the existing platform split: `PhoneHeroMetadata` remains the non-tvOS detail formatter, `TVMarqueeContent`/`TVMarqueeEnrichment` remain the shared tvOS Home and library Browse marquee payloads, and `TVHeroMetadata` remains the tvOS detail formatter. Narrow those formatters and hero interfaces instead of changing API models or server contracts; retain the marquee detail fetch because episode backdrops depend on its enriched artwork even after cast text is removed.

**Tech Stack:** Swift 5, SwiftUI, XCTest, XcodeGen, `xcodebuild`, iOS 26, tvOS 26, macOS 26.

## Global Constraints

- Preserve the iOS/macOS Home no-hero layout and all current `HomeFeedRow`, `HomePosterCard`, and `HomeStillCard` behavior.
- Remove hard-coded resolution, HDR/Dolby Vision, audio-layout, and CC tokens from iOS/macOS detail hero facts.
- On the shared tvOS Home and library Browse marquee, preserve editorial facts and content-rating badges while removing resolution, HDR/Dolby Vision, audio badges, and cast-name enrichment.
- Preserve tvOS episode marquee detail enrichment for air date and higher-quality series backdrop artwork; air date may remain.
- Remove hard-coded technical facts and the right-side `Starring …` overlay from tvOS movie, episode, series, and season detail heroes.
- Preserve iOS/macOS and tvOS version/audio/subtitle selectors and their technical labels.
- Preserve dedicated phone and tvOS cast sections and person navigation.
- Preserve configurable overlay systems on iOS detail artwork and tvOS cards; this change targets hard-coded hero facts/marquee badges, not administrator-configured overlays.
- Make no server, API contract, networking-model, or playback-protocol changes.
- Do not change `iosApp/project.yml`; its source globs already include the focused iOS test file, and the repository has no tvOS unit-test target.
- Use the local Xcode toolchain first. Consult `.claude/skills/mac-builder/SKILL.md` only if `xcode-select`, `xcodebuild`, or the required simulator runtimes prove unavailable locally.
- Use iOS and tvOS simulators for visual smoke testing only; do not install on or launch physical devices.
- Keep this work isolated on `feat/apple-hero-editorial-metadata` and submit it as its own pull request.

---

## File Map

**Create**

- `iosApp/Tests/HeroEditorialMetadataTests.swift` — focused regression tests proving rich file metadata cannot leak into non-tvOS detail hero facts.

**Modify**

- `iosApp/iosApp/Screens/Detail/Phone/PhoneHeroMetadata.swift` — return editorial facts only and remove the hard-coded quality-token builder.
- `iosApp/iosApp/Screens/Detail/Phone/PhoneDetailHero.swift` — remove the now-unreachable `.chip` rendering branch while retaining text and rating fact rendering.
- `iosApp/iosApp/Screens/Detail/MovieDetailContent.swift` — call the version-independent editorial facts interface.
- `iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift` — retain content rating/editorial metadata and episode artwork enrichment, but remove technical badge creation and cast names.
- `iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift` — remove the starring input/overlay and all hard-coded quality-token production/rendering.
- `iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift` — adopt the simplified hero and facts interfaces.
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift` — stop supplying duplicate starring copy.
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift` — stop supplying duplicate starring copy.

**Explicitly leave unchanged**

- `iosApp/iosApp/Screens/Home/HomeView.swift`
- `iosApp/iosApp/Screens/Home/Feed/HomeFeedKit.swift`
- `iosApp/iosApp/Screens/Home/Feed/HomeFeedRow.swift`
- `iosApp/iosApp/Components/MediaRow.swift`
- `iosApp/iosApp/Screens/Detail/Phone/PhoneCastRail.swift`
- `iosApp/iosApp/tvOS/Screens/Detail/TVDetailCastRail.swift`
- `iosApp/iosApp/Screens/Detail/Phone/PhonePlaybackSelectorRow.swift`
- `iosApp/iosApp/tvOS/Screens/Detail/TVPlaybackSelectorRow.swift`
- `iosApp/iosApp/Screens/Detail/DetailPlaybackFormatting.swift`
- `iosApp/iosApp/Screens/Detail/DetailVersionSelection.swift`
- `iosApp/iosApp/Networking/Models.swift`
- `iosApp/iosApp/Networking/ContinuumAPI.swift`
- `iosApp/project.yml`

## Local Execution Preflight

- [ ] **Step 1: Confirm the branch, base, and clean starting state**

Run:

```bash
git status --short --branch
git rev-parse HEAD
git merge-base HEAD upstream/main
```

Expected: branch `feat/apple-hero-editorial-metadata`, `HEAD` and merge-base `b9bdfb08d62807736614dcfa87bebf495b065d7b`, with no unplanned source changes. The plan file may be present as the only documentation change before implementation begins.

- [ ] **Step 2: Prove the local Apple toolchain is available before considering the remote builder**

Run:

```bash
xcode-select -p
xcodebuild -version
command -v xcodegen
xcrun simctl list devices available
```

Expected: a local Xcode developer directory, Xcode version output, an `xcodegen` executable, and available iOS 26/tvOS 26 simulators including `iPhone 17 Pro` and `Apple TV 4K (3rd generation)`. If any command is unavailable, stop this local workflow, read `.claude/skills/mac-builder/SKILL.md`, and follow its sync-and-verify procedure before running the same logical build/test gates remotely.

- [ ] **Step 3: Generate the project from the checked-in specification**

Run:

```bash
cd iosApp
xcodegen generate
cd ..
```

Expected: `Silo.xcodeproj` is generated successfully. Do not hand-edit the generated project.

- [ ] **Step 4: Commit the approved implementation plan before source work**

The repository ignores `docs/*`, so force-add this one approved plan explicitly:

```bash
git add -f docs/superpowers/plans/2026-07-29-apple-hero-editorial-metadata.md
git commit -m "docs: plan Apple hero editorial metadata"
```

Expected: the plan is the only file in this documentation commit. Do not force-add any other ignored documentation.

### Task 1: Make iOS/macOS Detail Hero Facts Editorial-Only

**Files:**

- Create: `iosApp/Tests/HeroEditorialMetadataTests.swift`
- Modify: `iosApp/iosApp/Screens/Detail/Phone/PhoneHeroMetadata.swift:3-224`
- Modify: `iosApp/iosApp/Screens/Detail/Phone/PhoneDetailHero.swift:334-385`
- Modify: `iosApp/iosApp/Screens/Detail/MovieDetailContent.swift:66-78`

**Interfaces:**

- Consumes: `ItemDetail`, `PhoneHeroFactToken`, and `DetailDateFormatting` from the existing app target.
- Produces: `PhoneHeroMetadata.movieFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken]` and the unchanged `PhoneHeroMetadata.seriesFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken]`, both guaranteed to return editorial tokens only.
- Produces: `PhoneHeroFactToken` with `.text(String)` and `.rating(String)` cases; `.chip(String)` is removed because no hard-coded phone hero quality token remains.

- [ ] **Step 1: Add failing regression tests for movie and series facts**

Create `iosApp/Tests/HeroEditorialMetadataTests.swift` with:

```swift
import Foundation
import XCTest
@testable import Silo

final class HeroEditorialMetadataTests: XCTestCase {
    func testMovieFactsExcludeTechnicalFileMetadata() throws {
        let detail = try decodeDetail(
            """
            {
              "content_id": "movie-1",
              "type": "movie",
              "title": "Editorial Movie",
              "year": 2026,
              "runtime": 125,
              "rating_imdb": 8.4,
              "versions": [
                {
                  "file_id": 10,
                  "resolution": "2160p",
                  "hdr": true,
                  "video_tracks": [
                    { "index": 0, "dolby_vision": "Profile 8.1" }
                  ],
                  "audio_tracks": [
                    { "index": 1, "layout": "7.1 Atmos", "default": true }
                  ],
                  "subtitle_tracks": [
                    { "index": 2, "codec": "srt", "language": "eng" }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(
            PhoneHeroMetadata.movieFactsLine(from: detail),
            [.text("2026"), .text("2h 5m"), .text("★ 8.4")]
        )
    }

    func testSeriesFactsExcludeTechnicalFileMetadata() throws {
        let detail = try decodeDetail(
            """
            {
              "content_id": "series-1",
              "type": "series",
              "title": "Editorial Series",
              "year": 2024,
              "season_count": 3,
              "rating_imdb": 9.1,
              "versions": [
                {
                  "file_id": 20,
                  "resolution": "1080p",
                  "hdr": true,
                  "audio_tracks": [
                    { "index": 1, "layout": "5.1", "default": true }
                  ],
                  "subtitle_tracks": [
                    { "index": 2, "codec": "srt", "language": "eng" }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(
            PhoneHeroMetadata.seriesFactsLine(from: detail),
            [.text("2024"), .text("3 Seasons"), .text("★ 9.1")]
        )
    }

    private func decodeDetail(_ json: String) throws -> ItemDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }
}
```

- [ ] **Step 2: Regenerate the project so the new test source enters `SiloTests`**

Run:

```bash
cd iosApp
xcodegen generate
cd ..
```

Expected: generation succeeds without editing `iosApp/project.yml`.

- [ ] **Step 3: Run the focused tests and verify the red state**

Run:

```bash
xcodebuild test \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SiloTests/HeroEditorialMetadataTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both tests execute and fail because the current arrays contain `.chip` entries such as `4K`, `DOLBY VISION`, `ATMOS`, `5.1`, or `CC`.

- [ ] **Step 4: Narrow the phone fact token and metadata interfaces**

In `PhoneHeroMetadata.swift`, replace the token declaration and facts builders with:

```swift
/// A token in the hero's editorial facts row. `.text` items get a
/// middle-dot separator; `.rating` retains the supported rating treatment.
enum PhoneHeroFactToken: Hashable {
    case text(String)
    case rating(String)
}

enum PhoneHeroMetadata {
    // Existing source-row, eyebrow, title-splitting, and helper code stays.

    static func movieFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if detail.type == "episode",
           let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(.text(airDate))
        } else if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let runtime = detail.runtime, runtime > 0 {
            tokens.append(.text(formatRuntime(runtime)))
        }
        if let imdb = detail.ratingImdb {
            tokens.append(.text(String(format: "★ %.1f", imdb)))
        }
        return tokens
    }

    static func seriesFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let count = detail.seasonCount, count > 0 {
            tokens.append(.text("\(count) Season\(count == 1 ? "" : "s")"))
        }
        if let imdb = detail.ratingImdb {
            tokens.append(.text(String(format: "★ %.1f", imdb)))
        }
        return tokens
    }
}
```

Delete these private helpers from `PhoneHeroMetadata` because they have no remaining caller:

```swift
qualityTokens(from:version:)
preferredVersion(from:)
resolutionLabel(_:)
dolbyVisionLabel(version:)
primaryAudioLabel(version:)
hasSubtitles(version:)
```

Retain `formatRuntime(_:)`, `typeLabel(detail:)`, episode-number formatting, source tokens, content rating, eyebrow logic, and title splitting unchanged.

- [ ] **Step 5: Remove the unreachable phone chip renderer**

In `PhoneDetailHero.swift`, keep the `.text` and `.rating` branches in `FlowingFactsRow.factsItem(_:)` and delete only:

```swift
case .chip(let value):
    Text(value)
        .font(.system(size: 10, weight: .heavy))
        .tracking(0.8)
        .foregroundColor(.continuumOnSurface)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.continuumOnSurface.opacity(0.45), lineWidth: 1)
        )
```

Update the nearby `FlowingFactsRow` comment so it describes wrapping editorial facts rather than a quality-badge row.

- [ ] **Step 6: Stop coupling movie hero facts to the selected file version**

In `MovieDetailContent.hero`, replace:

```swift
factsLine: PhoneHeroMetadata.movieFactsLine(from: detail, version: effectiveVersion),
```

with:

```swift
factsLine: PhoneHeroMetadata.movieFactsLine(from: detail),
```

Do not change `effectiveVersion`, `PhonePlaybackSelectorRow`, downloads, or playback launch selection; those still consume the chosen file version.

- [ ] **Step 7: Run the focused tests and verify the green state**

Run:

```bash
xcodebuild test \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SiloTests/HeroEditorialMetadataTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `HeroEditorialMetadataTests` passes both tests.

- [ ] **Step 8: Prove the retained playback formatter still exposes technical information**

Run:

```bash
xcodebuild test \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SiloTests/DetailVersionSelectionTests/testVersionSelectorUsesRichPrePlaySummary \
  -only-testing:SiloTests/DetailVersionSelectionTests/testVersionSelectorUsesDVForDolbyVisionMetadata \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both existing selector-formatting tests pass, proving technical metadata was removed from hero facts rather than from playback selection.

- [ ] **Step 9: Commit the independently tested phone/macOS formatter change**

Run:

```bash
git add \
  iosApp/Tests/HeroEditorialMetadataTests.swift \
  iosApp/iosApp/Screens/Detail/Phone/PhoneHeroMetadata.swift \
  iosApp/iosApp/Screens/Detail/Phone/PhoneDetailHero.swift \
  iosApp/iosApp/Screens/Detail/MovieDetailContent.swift
git commit -m "refactor(detail): keep phone hero facts editorial"
```

Expected: one commit containing only the focused tests and non-tvOS detail metadata/interface changes.

### Task 2: Make the Shared tvOS Home/Browse Marquee Editorial-Only

**Files:**

- Modify: `iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift:7-228`
- Verify unchanged: `iosApp/iosApp/tvOS/Components/TVSkylineSectionFeed.swift`
- Verify unchanged: `iosApp/iosApp/Components/MediaRow.swift`

**Interfaces:**

- Consumes: `SectionItem.contentRating`, editorial `SectionItem` fields, and `ItemDetail.airDate`, `backdropUrl`, and `backdropThumbhash`.
- Produces: unchanged `TVMarqueeContent.badges: [String]`, now containing only the editorial content-rating badge.
- Produces: unchanged `TVMarqueeEnrichment.detailLine: String?`, now containing only formatted air date, plus unchanged enriched backdrop fields.
- Preserves: `TVFocusMarqueeModel.loadEnrichment(for:)`, `backdropURL`, and `backdropThumbhash`, which are required to upgrade episode stills to detail-level series artwork.

There is no tvOS test bundle in `project.yml`, and `TVFocusMarquee.swift` is compiled out of the iOS-hosted `SiloTests` target. Keep this task narrowly covered by source-level acceptance checks, a tvOS compile gate, and the simulator smoke task below rather than adding a new test target.

- [ ] **Step 1: Record the current failing source-level acceptance state**

Run:

```bash
rg -n \
  'Self\.badges\(from: item\.overlaySummary\)|summary\.(resolution|hdr|audio)|detail\.cast|map\(\\\.name\)' \
  iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift
```

Expected: matches in `TVMarqueeContent.init(item:rowTitle:)`, `badges(from:)`, and `TVMarqueeEnrichment.init(detail:)`. These are the technical badge and cast-enrichment paths to remove.

- [ ] **Step 2: Build marquee badges from content rating only**

In `TVMarqueeContent.init(item:rowTitle:)`, replace:

```swift
var badges = Self.badges(from: item.overlaySummary)
if let contentRating = Self.nonEmpty(item.contentRating) {
    badges.append(contentRating.uppercased())
}
```

with:

```swift
let badges = Self.nonEmpty(item.contentRating).map {
    [$0.uppercased()]
} ?? []
```

Delete `badges(from:)` and `prettyResolution(_:)`. Retain `episodeToken`, time-left, length, runtime, and non-empty formatting.

Update `TVMarqueeContent.badges` documentation to say:

```swift
/// Editorial badge chips, currently the uppercased content rating.
let badges: [String]
```

Do not remove `SectionItem.overlaySummary` from the networking model or card overlay extraction; other surfaces still use it.

- [ ] **Step 3: Remove cast names while retaining air date and episode artwork enrichment**

Replace `TVMarqueeEnrichment.init(detail:)` with:

```swift
init(detail: ItemDetail) {
    backdropUrl = detail.backdropUrl
    backdropThumbhash = detail.backdropThumbhash
    detailLine = Self.airDateText(detail.airDate).map { "Aired \($0)" }
}
```

Update the type and property comments to describe air-date/artwork enrichment, not air-date/cast enrichment. Keep `airDateText(_:)` unchanged.

Do not change this existing model behavior:

```swift
private func loadEnrichment(for candidate: TVMarqueeContent) {
    enrichTask?.cancel()
    guard let contentId = candidate.contentId else {
        enrichment = nil
        return
    }
    if let cached = enrichmentCache[contentId] {
        enrichment = cached
        sampleTintIfNeeded(for: backdropURL)
        return
    }

    enrichment = nil
    enrichTask = Task { [weak self] in
        guard let detail = try? await ContinuumAPI.shared.itemDetail(contentId: contentId) else { return }
        guard !Task.isCancelled, let self else { return }
        let enrichment = TVMarqueeEnrichment(detail: detail)
        self.enrichmentCache[contentId] = enrichment
        if self.content?.contentId == contentId {
            self.enrichment = enrichment
            self.sampleTintIfNeeded(for: self.backdropURL)
        }
    }
}
```

That fetch and cache remain necessary because `backdropURL` prefers `enrichment.backdropUrl` for episode content.

- [ ] **Step 4: Update view/accessibility comments without changing layout**

In `TVFocusMarquee` and `TVMarqueeBlock`, update references from “air date + top-billed cast” to “air date” and retain:

```swift
enrichment?.detailLine
```

in both the visible `detailLine` and `accessibilityDescription`. This preserves air-date accessibility and the stable one-line layout reservation while ensuring cast names are absent.

- [ ] **Step 5: Verify technical badge and cast paths are gone while episode enrichment remains**

Run:

```bash
! rg -n \
  'summary\.(resolution|hdr|audio)|detail\.cast|map\(\\\.name\)|prettyResolution|private static func badges' \
  iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift

rg -n \
  'contentRating|backdropUrl = detail\.backdropUrl|backdropThumbhash = detail\.backdropThumbhash|loadEnrichment|enrichment\?\.backdropUrl|airDateText' \
  iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift
```

Expected: the negative search succeeds with no matches; the positive search shows content rating, air-date formatting, detail loading/caching, and enriched episode backdrop selection.

- [ ] **Step 6: Compile the tvOS app after the marquee change**

Run:

```bash
xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit the independently compiled shared-marquee change**

Run:

```bash
git add iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift
git commit -m "refactor(tvos): keep marquee metadata editorial"
```

Expected: one commit touching only the shared tvOS marquee implementation. Both Home and library Browse inherit the same policy because both intentionally use `TVSkylineSectionFeed`.

### Task 3: Simplify the tvOS Detail Hero and Remove Duplicate Starring Copy

**Files:**

- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift:5-625`
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift:63-75`
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift:110-122`
- Modify: `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift:74-86`
- Verify unchanged: `iosApp/iosApp/tvOS/Screens/Detail/TVDetailCastRail.swift`
- Verify unchanged: `iosApp/iosApp/tvOS/Screens/Detail/TVPlaybackSelectorRow.swift`

**Interfaces:**

- Produces: `TVDetailHero` without a `starringText` initializer argument.
- Produces: `TVHeroMetadata.movieFactsLine(from detail: ItemDetail) -> [TVHeroFactToken]`, no longer coupled to `FileVersion`.
- Preserves: `TVHeroMetadata.seriesFactsLine(from:)`, now editorial-only.
- Produces: `TVHeroFactToken` with `.text(String)` and `.rating(String)` cases; `.chip(String)` is removed.
- Preserves: all `TVDetailCastRail` and `TVPlaybackSelectorRow` call sites below and within the hero.

As in Task 2, these types are tvOS-only and have no test host. Use a source-level red/green acceptance check, compile gate, and simulator smoke verification.

- [ ] **Step 1: Record the current failing source-level acceptance state**

Run:

```bash
rg -n \
  'starringText|starringOverlay|qualityTokens|case chip|case \.chip|movieFactsLine\(from: detail, version:' \
  iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift
```

Expected: matches for the right-side starring API/rendering, technical token builder/renderer, and the selected-version facts call.

- [ ] **Step 2: Remove the starring input and overlay from `TVDetailHero`**

Delete:

```swift
let starringText: String?
```

Delete this modifier from `body`:

```swift
.overlay(alignment: .trailing) { starringOverlay }
```

Delete the complete `starringOverlay` computed property:

```swift
@ViewBuilder
private var starringOverlay: some View {
    if let starringText, !starringText.isEmpty {
        Text(starringText)
            .font(.system(size: 24, weight: .regular))
            .foregroundColor(Color.white.opacity(0.8))
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .frame(maxWidth: 460, alignment: .trailing)
            .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
            .padding(.trailing, ContinuumTheme.safePadding)
            .padding(.bottom, heroHeight * 0.45)
    }
}
```

Update the top-level hero comment so it describes only the left editorial stack and below-fold rail preview.

- [ ] **Step 3: Make tvOS detail fact tokens editorial-only**

Replace the fact token declaration with:

```swift
/// A token in the combined editorial facts row. `.text` items get
/// separators; `.rating` retains the supported rating treatment.
enum TVHeroFactToken: Hashable {
    case text(String)
    case rating(String)
}
```

Delete only the `.chip` branch from `factsItem(_:)`; retain the `.text` and `.rating` view treatments.

Replace the two facts builders with:

```swift
static func movieFactsLine(from detail: ItemDetail) -> [TVHeroFactToken] {
    var tokens: [TVHeroFactToken] = []
    if detail.type == "episode",
       let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
        tokens.append(.text(airDate))
    } else if let year = detail.year, year > 0 {
        tokens.append(.text(String(year)))
    }
    if let runtime = detail.runtime, runtime > 0 {
        tokens.append(.text(formatRuntime(runtime)))
    }
    if let imdb = detail.ratingImdb {
        tokens.append(.text(String(format: "★ %.1f", imdb)))
    }
    return tokens
}

static func seriesFactsLine(from detail: ItemDetail) -> [TVHeroFactToken] {
    var tokens: [TVHeroFactToken] = []
    if let year = detail.year, year > 0 {
        tokens.append(.text(String(year)))
    }
    if let count = detail.seasonCount, count > 0 {
        tokens.append(.text("\(count) Season\(count == 1 ? "" : "s")"))
    }
    if let imdb = detail.ratingImdb {
        tokens.append(.text(String(format: "★ %.1f", imdb)))
    }
    return tokens
}
```

Delete:

```swift
starringText(from:)
qualityTokens(from:version:)
preferredVersion(from:)
resolutionLabel(_:)
dolbyVisionLabel(version:)
primaryAudioLabel(version:)
hasSubtitles(version:)
```

Retain source tokens, content-rating chip, episode numbering, eyebrow, type labels, and runtime formatting.

- [ ] **Step 4: Update all three tvOS detail call sites**

In `TVMovieDetailView`, use:

```swift
factsLine: TVHeroMetadata.movieFactsLine(from: detail),
actions: { actionColumn },
belowSynopsis: belowSynopsis
```

and remove:

```swift
starringText: TVHeroMetadata.starringText(from: detail),
```

In `TVSeriesDetailView`, retain:

```swift
factsLine: TVHeroMetadata.seriesFactsLine(from: detail),
actions: { actionColumn },
belowSynopsis: belowSynopsis
```

and remove its `starringText` argument.

In `TVSeasonDetailView`, retain:

```swift
factsLine: [],
actions: { actionColumn },
belowSynopsis: belowSynopsis
```

and remove its `starringText` argument.

Do not remove `currentVersion` from `TVMovieDetailView`; it remains the input to `TVPlaybackSelectorRow`.

- [ ] **Step 5: Verify the removed paths are absent and retained cast/selector surfaces still exist**

Run:

```bash
! rg -n \
  'starringText|starringOverlay|qualityTokens|case chip|case \.chip|movieFactsLine\(from: detail, version:' \
  iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift

rg -n \
  'TVDetailCastRail|TVPlaybackSelectorRow' \
  iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift
```

Expected: no removed-path matches; cast rail calls remain on movie/episode, series, and season pages, and playback selectors remain on each playable detail path.

- [ ] **Step 6: Compile the tvOS app after the detail interface change**

Run:

```bash
xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`, proving every `TVDetailHero` initializer was updated consistently.

- [ ] **Step 7: Commit the independently compiled tvOS detail change**

Run:

```bash
git add \
  iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift
git commit -m "refactor(tvos): simplify detail hero metadata"
```

Expected: one commit limited to tvOS detail hero metadata/interfaces.

### Task 4: Run Cross-Platform Automated Verification

**Files:**

- Verify unchanged paths listed in the File Map.
- Test: all files under `iosApp/Tests/` through the `SiloTests` bundle.

**Interfaces:**

- Consumes: the three implementation commits from Tasks 1-3.
- Produces: evidence that iOS, tvOS, and macOS compile unsigned and that the full iOS test bundle remains green.

- [ ] **Step 1: Regenerate from `project.yml` once more**

Run:

```bash
cd iosApp
xcodegen generate
cd ..
```

Expected: generation succeeds with no `project.yml` change.

- [ ] **Step 2: Run the complete iOS unit-test bundle**

Run:

```bash
xcodebuild test \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `TEST SUCCEEDED`, including `HeroEditorialMetadataTests` and existing playback selector tests.

- [ ] **Step 3: Run the unsigned iOS build**

Run:

```bash
xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the unsigned tvOS build**

Run:

```bash
xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run the unsigned macOS build**

Run:

```bash
xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`. This gate is required because the phone metadata and hero files are guarded by `#if !os(tvOS)` and therefore also compile into `SiloMac`.

- [ ] **Step 6: Prove protected source areas did not change**

Run:

```bash
git diff --exit-code b9bdfb0 -- \
  iosApp/iosApp/Screens/Home/HomeView.swift \
  iosApp/iosApp/Screens/Home/Feed/HomeFeedKit.swift \
  iosApp/iosApp/Screens/Home/Feed/HomeFeedRow.swift \
  iosApp/iosApp/Components/MediaRow.swift \
  iosApp/iosApp/Screens/Detail/Phone/PhoneCastRail.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVDetailCastRail.swift \
  iosApp/iosApp/Screens/Detail/Phone/PhonePlaybackSelectorRow.swift \
  iosApp/iosApp/tvOS/Screens/Detail/TVPlaybackSelectorRow.swift \
  iosApp/iosApp/Screens/Detail/DetailPlaybackFormatting.swift \
  iosApp/iosApp/Screens/Detail/DetailVersionSelection.swift \
  iosApp/iosApp/Networking/Models.swift \
  iosApp/iosApp/Networking/ContinuumAPI.swift \
  iosApp/project.yml
```

Expected: no diff. This is the explicit guard for iOS no-hero Home/cards, configurable card overlays, cast rails, selectors, models/API, and project structure.

- [ ] **Step 7: Check whitespace and repository state**

Run:

```bash
git diff --check upstream/main...HEAD
git status --short
git log --oneline --decorate upstream/main..HEAD
```

Expected: no whitespace errors, no uncommitted implementation changes, and the three focused implementation commits plus the plan documentation change in the branch history.

### Task 5: Perform iOS and tvOS Simulator Visual Smoke Tests

**Files:**

- No source changes.
- Capture evidence outside the repository under `/tmp`.

**Interfaces:**

- Consumes: locally built simulator apps and an existing signed-in or cached Silo profile/library.
- Produces: visual confirmation of metadata composition, retained navigation/actions, and episode backdrop enrichment without touching a physical device.

- [ ] **Step 1: Build and launch iOS in an isolated simulator derived-data directory**

Run:

```bash
xcrun simctl shutdown all
xcrun simctl boot 'iPhone 17 Pro'
open -a Simulator

xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/silo-apple-hero-editorial-ios \
  CODE_SIGNING_ALLOWED=NO

xcrun simctl install booted \
  /tmp/silo-apple-hero-editorial-ios/Build/Products/Debug-iphonesimulator/Silo.app
xcrun simctl launch booted org.siloserver.silo
```

Expected: the iOS app launches in the iPhone simulator. No physical-device command is used.

- [ ] **Step 2: Inspect iOS Home and representative detail pages**

Using the simulator UI, verify all of the following:

- Home starts directly with section rows beneath the floating header; no hero appears.
- Existing poster, still, progress, watched, downloaded, S/E, square-audiobook, caption, and selective row-differentiating badge treatments are unchanged.
- A movie detail hero shows editorial facts such as year, runtime, and IMDb score but no `4K`, `HD`, `HDR`, `DOLBY VISION`, `ATMOS`, `7.1`, `5.1`, or `CC` hard-coded fact chip.
- An episode detail hero may show air date/runtime/rating but no technical fact chip.
- A series detail hero shows year/season count/rating but no technical fact chip.
- Version, Audio, and Subtitles selector rows still display their rich technical values and remain interactive when multiple choices exist.
- The below-fold Cast & Crew section still appears and person cards still navigate.
- Configurable artwork overlays, when enabled in overlay settings, remain independent of the removed hard-coded facts.

- [ ] **Step 3: Capture an iOS simulator screenshot outside the repository**

Run:

```bash
xcrun simctl io booted screenshot /tmp/apple-hero-editorial-ios.png
```

Expected: `/tmp/apple-hero-editorial-ios.png` contains the currently inspected iOS screen and no repository file is created.

- [ ] **Step 4: Build and launch tvOS in an isolated simulator derived-data directory**

Run:

```bash
xcrun simctl shutdown all
xcrun simctl boot 'Apple TV 4K (3rd generation)'
open -a Simulator

xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -derivedDataPath /tmp/silo-apple-hero-editorial-tvos \
  CODE_SIGNING_ALLOWED=NO

xcrun simctl install booted \
  /tmp/silo-apple-hero-editorial-tvos/Build/Products/Debug-appletvsimulator/SiloTV.app
xcrun simctl launch booted org.siloserver.silo
```

Expected: the tvOS app launches in the Apple TV simulator. No physical Apple TV is addressed.

- [ ] **Step 5: Inspect shared Home/Library marquee behavior**

Using the simulator remote/keyboard navigation, verify:

- Home marquee retains title/logo, synopsis, content-rating badge, year/genre/runtime/IMDb facts, episode S/E/title/runtime/time-left facts, backdrop, and focus-driven crossfade.
- No marquee emits resolution, HDR/Dolby Vision, or audio badges.
- No marquee enrichment line emits actor names.
- An episode with an air date may still show `Aired …`.
- After an episode rests in focus, the backdrop can still upgrade from section artwork to the detail-level series backdrop; the enrichment fetch must not have been removed.
- A library Browse landing exhibits the same metadata policy because it shares `TVSkylineSectionFeed` and `TVFocusMarquee`.
- Configurable poster/thumbnail card overlays remain unchanged.

- [ ] **Step 6: Inspect tvOS detail behavior**

Verify representative movie/episode, series, and season detail pages:

- The hero facts remain editorial and contain no resolution, HDR/Dolby Vision, audio-layout, or CC token.
- No right-side `Starring …` overlay appears.
- The below-fold Cast & Crew rail remains present and focusable.
- Version, Audio, and Subtitles selectors retain technical values and focus behavior.
- Season/episode rails, details facts, synopsis expansion, action buttons, and person navigation remain intact.

- [ ] **Step 7: Capture a tvOS simulator screenshot outside the repository**

Run:

```bash
xcrun simctl io booted screenshot /tmp/apple-hero-editorial-tvos.png
```

Expected: `/tmp/apple-hero-editorial-tvos.png` contains the inspected tvOS screen and no repository file is created.

- [ ] **Step 8: Confirm visual smoke testing did not dirty the worktree**

Run:

```bash
git status --short
```

Expected: no simulator-generated repository changes.

### Task 6: Independent Review and Separate Pull Request

**Files:**

- Review the complete `upstream/main...HEAD` diff.
- No new production files unless a concrete review finding requires returning to Tasks 1-3.

**Interfaces:**

- Consumes: green automated verification, simulator smoke evidence, and the complete commit range.
- Produces: an independent review verdict and one dedicated GitHub pull request for this feature branch.

- [ ] **Step 1: Prepare the exact review range and acceptance brief**

Run:

```bash
git fetch upstream
git log --oneline upstream/main..HEAD
git diff --stat upstream/main...HEAD
git diff --check upstream/main...HEAD
```

Expected: a small diff limited to the plan, one focused test file, phone/macOS hero metadata, shared tvOS marquee metadata, and tvOS detail hero interfaces.

- [ ] **Step 2: Request an independent code review**

Invoke `superpowers:requesting-code-review` with:

```text
Base: upstream/main
Head: HEAD
Review the Apple hero editorial metadata change for:
1. iOS Home and editorial cards remain untouched.
2. iOS/macOS detail facts exclude hard-coded resolution, HDR/DV, audio-layout, and CC tokens.
3. tvOS Home and library Browse marquee preserve editorial facts/content rating and remove technical badges/cast names.
4. tvOS episode enrichment still fetches/caches detail artwork and may show air date.
5. tvOS detail removes technical facts and the right-side Starring overlay.
6. Dedicated cast rails, person navigation, configurable overlays, and playback/version selectors remain intact.
7. No server/API/model/project.yml changes.
8. Tests and all three unsigned platform builds support the claims.
```

Expected: an independent reviewer reports either no findings or concrete findings with file/line references and severity.

- [ ] **Step 3: Resolve review findings through the relevant test/build gate**

If the reviewer reports a finding, return to the task owning that file:

- Phone facts/interface finding: add or tighten an assertion in `HeroEditorialMetadataTests`, run the focused red/green command from Task 1, then commit with `fix(detail): address editorial metadata review`.
- Shared marquee finding: run the Task 2 negative/positive source checks and tvOS build after the correction, then commit with `fix(tvos): address marquee metadata review`.
- tvOS detail finding: run the Task 3 source checks and tvOS build after the correction, then commit with `fix(tvos): address detail hero review`.
- Preservation/build finding: rerun the protected-path diff and the affected full platform build from Task 4 before committing with `fix(apple): preserve hero metadata boundaries`.

After any correction, repeat Step 2 against the new `HEAD`. Proceed only when the independent review has no unresolved findings.

- [ ] **Step 4: Run the final verification-before-completion gate**

Invoke `superpowers:verification-before-completion`, then rerun:

```bash
xcodebuild test \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme Silo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project iosApp/Silo.xcodeproj \
  -scheme SiloMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

git diff --check upstream/main...HEAD
git status --short
```

Expected: full iOS tests pass, all three unsigned builds succeed, no whitespace errors exist, and the worktree is clean.

- [ ] **Step 5: Push only the dedicated feature branch**

Run:

```bash
git push -u origin feat/apple-hero-editorial-metadata
```

Expected: the isolated branch is published without merging or pushing unrelated branches.

- [ ] **Step 6: Open the separate pull request**

Run:

```bash
gh pr create \
  --base main \
  --head feat/apple-hero-editorial-metadata \
  --title 'Keep Apple hero metadata editorial' \
  --body $'## Summary\n- remove hard-coded technical quality tokens from iOS/macOS and tvOS detail hero facts\n- keep tvOS Home and library Browse marquee editorial while removing technical badges and cast-name enrichment\n- preserve episode backdrop enrichment, content ratings, cast rails, configurable overlays, and playback selectors\n\n## Verification\n- full SiloTests on iPhone 17 Pro simulator\n- unsigned iOS simulator build\n- unsigned tvOS simulator build\n- unsigned macOS build\n- iOS and tvOS simulator visual smoke\n- independent code review with no unresolved findings'
```

Expected: one new pull request from `feat/apple-hero-editorial-metadata` to `main`, containing only this plan and implementation.

## Plan Self-Review

- Spec coverage: Tasks 1-3 cover every requested platform surface; Task 4 explicitly guards iOS Home/cards, selectors, cast rails, API/models, and `project.yml`; Task 5 covers simulator-only visual behavior; Task 6 covers independent review and the separate PR.
- Testability: non-tvOS pure metadata receives focused XCTest red/green coverage; tvOS-only types use explicit source acceptance checks, compile gates, and simulator verification because the repository has no tvOS test target.
- Placeholder scan: the plan contains no unresolved marker, deferred implementation instruction, unnamed test, or undefined interface.
- Type consistency: both simplified `movieFactsLine` functions take only `ItemDetail`; both token enums remove `.chip`; every affected call site is listed; marquee enrichment retains its existing property names and model API.
- Boundary consistency: `OverlaySummary`, configurable `OverlayData`, `currentVersion`, playback selectors, cast rails, and episode artwork enrichment remain deliberately intact.
