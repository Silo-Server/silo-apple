# Resume-First Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the featured card carousel from the iOS/iPadOS/macOS clients and render Home and the library "Recommended" tab as resume-first section rows led by Continue Watching, matching the tvOS Skyline philosophy.

**Architecture:** This is predominantly *subtraction*. The clients already filter the server's `featured` section out of their row lists (`regularSections`); `FeaturedCarousel` is the only thing that renders it. We stop rendering the carousel in both places (`HomeView`, `LibraryRecommendedView`), strip the page-level ambient backdrop/tint that only existed to back the hero, fix the one layout coupling it leaves behind (the Libraries-tab refresh-pill inset), redirect startup artwork prefetch to the first content row, then delete `FeaturedCarousel.swift` and regenerate the project.

**Tech Stack:** Swift 5, SwiftUI, XcodeGen (`project.yml` → `Silo.xcodeproj`), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-06-15-resume-first-home-design.md`

---

## Verification approach (read first)

This change is UI removal in a codebase whose `CLAUDE.md` says **not** to add tests for small or UI changes. So tasks are verified by **compiling** (`xcodebuild`) and, at the end, a **manual run**, rather than TDD red/green cycles. Each task ends green and is committed.

**Build commands (memorize):**

- iOS: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
- macOS: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- tvOS: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO`

If a simulator name is unavailable, list with `xcrun simctl list devices available` and substitute. `Silo.xcodeproj/` is gitignored, so regeneration never shows up in `git status`.

**Task order matters:** Tasks 1 and 2 each remove one `FeaturedCarousel` usage. The file is only deleted in Task 4, after both usages are gone, so every intermediate task still compiles.

---

## File Structure

- `iosApp/iosApp/Screens/Home/HomeViewModel.swift` — drop `featuredSection`; keep `regularSections`.
- `iosApp/iosApp/Screens/Home/HomeView.swift` — remove carousel branch + page-level ambient backdrop/tint; flat background; permanent top runway; empty state; helper cleanup.
- `iosApp/iosApp/Screens/Browse/BrowseView.swift` — `LibraryRecommendedView` + `LibraryRecommendedViewModel`: remove carousel, `featuredSection`, hero-bleed safe-area, and the `extendsBackdropToTop` inset path.
- `iosApp/iosApp/Screens/Browse/LibrariesTabView.swift` — drop the `extendsBackdropToTop: true` argument and refresh the now-stale hero comments.
- `iosApp/iosApp/Startup/StartupContentPrefetcher.swift` — warm the first content row instead of the featured item; collapse the `#if os(tvOS)` split.
- `iosApp/iosApp/Screens/Home/FeaturedCarousel.swift` — **delete** (~1,600 lines, no remaining references).

---

## Task 1: Home screen — drop the carousel, go resume-first

**Files:**
- Modify: `iosApp/iosApp/Screens/Home/HomeViewModel.swift`
- Modify: `iosApp/iosApp/Screens/Home/HomeView.swift`

- [ ] **Step 1: Remove `featuredSection` from the view model**

In `HomeViewModel.swift`, delete the `featuredSection` computed property (the `regularSections` property below it already excludes featured and stays unchanged):

```swift
// DELETE these lines:
    /// Featured section (first section if marked as featured).
    var featuredSection: ResolvedSection? {
        sections.first(where: { $0.isFeatured })
    }
```

- [ ] **Step 2: Remove hero state and constants from `HomeView`**

In `HomeView.swift`, inside the `#if !os(tvOS)` state block, delete the three hero state vars (keep `currentProfile`, `homeScrollOffset`, `isRefreshing`, `refreshStartedAt`, `refreshHideTask`, `chromeFadeDistance`):

```swift
// DELETE these three lines:
    @State private var heroTintColor: Color = .siloBackground
    @State private var heroBackdropURL: String?
    @State private var heroBackdropThumbhash: String?
```

Then delete the entire `#if !os(tvOS)` block that defines the two backdrop constants (the doc comment + `heroBackdropFadeExtension` + `heroBackdropHorizontalBleed`):

```swift
// DELETE this whole block:
    #if !os(tvOS)
    /// How far the blurred page backdrop extends below the hero's
    /// visible bottom edge. ...
    private let heroBackdropFadeExtension: CGFloat = 260

    private let heroBackdropHorizontalBleed: CGFloat = 0
    #endif
```

- [ ] **Step 3: Replace the hero background layers with a flat OLED background**

In `HomeView.swift`, in the non-tvOS `body` (the `#else` branch), the `ZStack(alignment: .top)` begins with `heroTintBackground` and `heroBackdropImage`. Replace those two lines with a single flat background:

```swift
        ZStack(alignment: .top) {
            Color.siloBackground
                .ignoresSafeArea()

            Group {
                if viewModel.sections.isEmpty {
                    // ... (replaced in Step 5) ...
```

- [ ] **Step 4: Delete the hero background/height computed properties**

In `HomeView.swift`, delete the entire `#if !os(tvOS)` block (immediately after `body`) that contains `heroTintBackground`, `heroBackdropImage`, `heroBackdropFadeMask`, and `computedHeroHeight`. It starts with the comment `/// Plex-style page-level gradient.` and ends at the `#endif` after `computedHeroHeight`'s closing brace. None of these are referenced anywhere else after Step 3.

- [ ] **Step 5: Rewrite the body's content branch with an empty state**

In `HomeView.swift`, replace the `Group { ... }` content selector in the non-tvOS `body` (the block that today renders `content` or `Color.clear`) with this version, which adds a friendly empty state and calls `scrollContent` directly:

```swift
            Group {
                if !viewModel.sections.isEmpty {
                    scrollContent
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadSections() } })
                } else if viewModel.isLoading {
                    Color.clear
                } else {
                    EmptyStateView(
                        icon: "play.rectangle.on.rectangle",
                        title: "Nothing to watch yet",
                        subtitle: "Add media to your libraries or start watching to see it here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
```

Then delete the now-unused `content` computed property (the `#if !os(tvOS)` `@ViewBuilder private var content` that branched on `sections.isEmpty`). Leave `scrollContent` in place.

- [ ] **Step 6: Make the top runway permanent and simplify the focus enum in `scrollContent`**

In `HomeView.swift`, replace the body of `scrollContent`'s `LazyVStack` so there is no featured branch — just a permanent header runway spacer, then the rows:

```swift
                LazyVStack(spacing: sectionSpacing, pinnedViews: []) {
                    // No hero — reserve runway for the floating Home header so
                    // the first row doesn't slide under the status-bar chrome.
                    Color.clear
                        .frame(height: topRunwaySpacing(topSafeAreaInset: geometry.safeAreaInsets.top))
                        .id(HomeFocusTarget.topSpacer)

                    ForEach(Array(displayedSections.enumerated()), id: \.element.id) { index, section in
                        SectionRow(
                            section: section,
                            onItemTap: { navigateToDetail($0) },
                            prefersDefaultFocusOnFirstItem: index == 0,
                            onMoveUp: index == 0 ? onTopMenuFocusRequest : nil
                        )
                        .id(HomeFocusTarget.row(section.id))
                    }
                }
                .padding(.bottom, SiloTheme.largePadding)
```

Update the `HomeFocusTarget` enum to drop the featured case and rename the spacer:

```swift
    private enum HomeFocusTarget: Hashable {
        case topSpacer
        case row(String)
    }
```

Rename the helper `noFeaturedTopSpacing(topSafeAreaInset:)` to `topRunwaySpacing(topSafeAreaInset:)` (body unchanged):

```swift
    private func topRunwaySpacing(topSafeAreaInset: CGFloat) -> CGFloat {
        let headerContentHeight: CGFloat = 40 + (SiloTheme.smallPadding * 2)
        return topSafeAreaInset + headerContentHeight + SiloTheme.largePadding + SiloTheme.smallPadding
    }
```

- [ ] **Step 7: Remove the dead hero play action and its environment**

In `HomeView.swift`, delete the `#if !os(tvOS)` `navigateToPlayer(_:)` method (its only caller was the carousel's `onPlayTap`). Then confirm `audioStore` is now unused and remove it:

Run: `grep -n "audioStore" iosApp/iosApp/Screens/Home/HomeView.swift`
Expected: no matches after deleting `navigateToPlayer`. If so, delete the declaration:

```swift
// DELETE this line:
    @Environment(AudioPlaybackStore.self) private var audioStore
```

(`navigateToDetail(_:)` stays — it is still used by `SectionRow`.)

- [ ] **Step 8: Build iOS**

Run: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. (`FeaturedCarousel.swift` still compiles — it is still referenced by `LibraryRecommendedView` until Task 2.)

- [ ] **Step 9: Commit**

```bash
git add iosApp/iosApp/Screens/Home/HomeView.swift iosApp/iosApp/Screens/Home/HomeViewModel.swift
git commit -m "Drop featured carousel from Home, render resume-first rows" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Library "Recommended" tab — drop the carousel and hero-bleed insets

**Files:**
- Modify: `iosApp/iosApp/Screens/Browse/BrowseView.swift` (`LibraryRecommendedViewModel`, `LibraryRecommendedView`)
- Modify: `iosApp/iosApp/Screens/Browse/LibrariesTabView.swift`

- [ ] **Step 1: Remove `featuredSection` from `LibraryRecommendedViewModel`**

In `BrowseView.swift`, delete the property (keep `regularSections`):

```swift
// DELETE these lines:
    var featuredSection: ResolvedSection? {
        sections.first(where: { $0.isFeatured })
    }
```

- [ ] **Step 2: Remove the carousel from `LibraryRecommendedView.content`**

In `BrowseView.swift`, in `LibraryRecommendedView`'s `content`, delete the entire `if let featured = viewModel.featuredSection { FeaturedCarousel(...) }` block, leaving the rows:

```swift
    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: SiloTheme.largePadding) {
                ForEach(viewModel.regularSections) { section in
                    SectionRow(
                        section: section,
                        onItemTap: { router.navigate(to: .itemDetail(contentId: $0)) }
                    )
                }
            }
            .padding(.bottom, SiloTheme.largePadding)
        }
        // Report the distance scrolled from the resting top position. We add
        // the top content inset so the value starts at 0 at rest regardless
        // of whether a safe-area inset is applied.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            onScrollOffsetChange(max(0, newValue))
        }
    }
```

Note this also removes the `.ignoresSafeArea(.container, edges: ...)` modifier and its comment — without a hero backdrop there is nothing to bleed behind the chrome, so the content now respects the safe area and sits below the Libraries-tab chrome (which is installed via `safeAreaInset`). `onScrollOffsetChange` / `.onScrollGeometryChange` stay — they still drive the chrome scrim that darkens rows as they scroll behind the top bar.

- [ ] **Step 3: Drop the `extendsBackdropToTop` inset path**

In `BrowseView.swift`, `extendsBackdropToTop` is now used only by `refreshStatusTopPadding`. Because the content is no longer bleeding to the top (Step 2), the refresh pill must use normal padding, not the hero inset. Replace `refreshStatusTopPadding` and delete `libraryHeroTopInset`:

```swift
    private var refreshStatusTopPadding: CGFloat {
        SiloTheme.padding
    }
```

```swift
// DELETE libraryHeroTopInset entirely (and its doc comment):
    private var libraryHeroTopInset: CGFloat {
        let topBarHeight: CGFloat = 52
        let tabSelectorHeight: CGFloat = 40
        return topBarHeight + tabSelectorHeight
    }
```

Then delete the now-unused `extendsBackdropToTop` stored property and its doc comment from `LibraryRecommendedView`:

```swift
// DELETE this property + comment:
    /// When true, the underlying scroll view ignores the top safe area so
    /// the featured carousel's backdrop renders all the way up behind any
    /// chrome ...
    var extendsBackdropToTop: Bool = false
```

(Keep `onScrollOffsetChange`.)

- [ ] **Step 4: Update the Libraries-tab call site**

In `LibrariesTabView.swift`, drop the `extendsBackdropToTop: true,` argument so the call matches the new signature:

```swift
        case .recommended:
            LibraryRecommendedView(
                libraryId: activeLibrary.id,
                onScrollOffsetChange: { recommendedScrollOffset = $0 }
            )
```

- [ ] **Step 5: Refresh the stale hero comments (no behavior change)**

In `LibrariesTabView.swift`, update the two comments that describe a featured carousel so future readers aren't misled. Replace the `loadedContent` comment:

```swift
        // Switch tab content directly here (rather than going through
        // `LibraryDetailView`) so we can hoist the top bar + tab selector
        // into a single `safeAreaInset` overlay shared by all three tabs.
```

And the `topChrome` `.background` comment:

```swift
        // On the Recommended tab the chrome sits over the scrolling rows.
        // The scrim is transparent at rest and fades in as the user scrolls,
        // so rows passing behind the top bar stay legible.
```

- [ ] **Step 6: Build iOS**

Run: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. (`FeaturedCarousel.swift` now has zero references but still compiles as an unused file — deleted in Task 4.)

- [ ] **Step 7: Commit**

```bash
git add iosApp/iosApp/Screens/Browse/BrowseView.swift iosApp/iosApp/Screens/Browse/LibrariesTabView.swift
git commit -m "Drop featured carousel from library Recommended tab" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Startup prefetch — warm the first row, not the featured item

**Files:**
- Modify: `iosApp/iosApp/Startup/StartupContentPrefetcher.swift`

- [ ] **Step 1: Collapse the platform branch in `prefetchHomeArtwork`**

The `#if os(tvOS)` branch already warms the first content row (correct for a no-hero layout); the `#else` branch warms the now-removed featured hero. Replace the entire `#if os(tvOS) ... #else ... #endif` block (from the `#if os(tvOS)` line through the matching `#endif`, just before `guard !urls.isEmpty`) with this single shared implementation:

```swift
        // No client renders a featured hero anymore: entry lands on the first
        // card of the first content row. Warm that row's logo + art first (so a
        // cold start paints a finished first row), then the rest.
        let contentSections = response.sections.filter { !$0.isFeatured && !$0.items.isEmpty }
        if let firstRow = contentSections.first {
            append(firstRow.items.first?.logoUrl)
            for item in firstRow.items {
                if episodeSectionTypes.contains(firstRow.sectionType) {
                    // Episode thumbs already render the backdrop, so the card
                    // art and the first-row art are one fetch.
                    append(item.backdropUrl ?? item.posterUrl)
                } else {
                    append(item.posterUrl)
                    append(item.backdropUrl)
                }
                if urls.count >= maxHomeArtworkURLs { break }
            }
        }
        for section in contentSections.dropFirst() {
            for item in section.items {
                if episodeSectionTypes.contains(section.sectionType) {
                    append(item.backdropUrl ?? item.posterUrl)
                } else {
                    append(item.posterUrl)
                }
                if urls.count >= maxHomeArtworkURLs { break }
            }
            if urls.count >= maxHomeArtworkURLs { break }
        }
```

- [ ] **Step 2: Build iOS**

Run: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Startup/StartupContentPrefetcher.swift
git commit -m "Prefetch first home row instead of featured hero art" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Delete `FeaturedCarousel`, regenerate, and verify every platform

**Files:**
- Delete: `iosApp/iosApp/Screens/Home/FeaturedCarousel.swift`

- [ ] **Step 1: Confirm there are no remaining references**

Run: `grep -rn "FeaturedCarousel" iosApp --include="*.swift"`
Expected: no matches (the only earlier hits were the two usages removed in Tasks 1–2 and a doc comment removed in Task 1 Step 4). If anything remains, resolve it before deleting.

- [ ] **Step 2: Delete the file**

```bash
git rm iosApp/iosApp/Screens/Home/FeaturedCarousel.swift
```

- [ ] **Step 3: Regenerate the Xcode project**

Run: `cd iosApp && xcodegen generate`
Expected: `Created project at .../Silo.xcodeproj`. (XcodeGen globs sources by directory, so the deleted file drops out automatically; `Silo.xcodeproj/` is gitignored.)

- [ ] **Step 4: Build iOS**

Run: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Build macOS**

Run: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Build tvOS (regression guard)**

Run: `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. (tvOS never referenced `FeaturedCarousel`; this confirms the deletion didn't disturb the shared Home/prefetch code.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Delete unused FeaturedCarousel component" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Manual verification

No code changes — confirm behavior on a simulator signed into a dev server with content.

- [ ] **Step 1: iPhone Home**

Run the `Silo` scheme on an iPhone simulator. Confirm: no hero/carousel; the floating "Home" header sits over a flat OLED background; the first row is Continue Watching (when present); the header chrome fades in on scroll; rows are not clipped under the header.

- [ ] **Step 2: Library Recommended tab**

Open the Libraries tab → Recommended. Confirm: no hero; the first row sits cleanly below the library switcher + tab chips; scrolling darkens rows behind the top bar (scrim) and keeps the library name legible; pull-to-refresh shows the refresh pill below the chrome, not floating too low or hidden behind it.

- [ ] **Step 3: Empty state**

If a profile with no Continue Watching / empty library is available, confirm Home shows the "Nothing to watch yet" empty state rather than a blank screen. (Skip if no such account is handy — it is a low-risk additive path.)

- [ ] **Step 4: iPad + macOS spot check**

Run the `Silo` scheme on an iPad simulator and the `SiloMac` scheme; confirm Home and the library Recommended tab render resume-first rows with no carousel and no layout breakage.

---

## Self-Review (against the spec)

- **Drop featured, all non-tvOS, library pages too** → Tasks 1 (Home), 2 (library Recommended), 4 (delete). ✓
- **Flat OLED background; remove ambient hero machinery** → Task 1 Steps 2–4. ✓
- **Permanent top runway** → Task 1 Step 6. ✓
- **Empty state instead of blank** → Task 1 Step 5. ✓
- **`LibraryRecommendedView` chrome-inset cleanup (the flagged non-mechanical spot)** → Task 2 Steps 2–5. ✓
- **Prefetch warms first row, branch collapsed** → Task 3. ✓
- **Delete `FeaturedCarousel.swift`, regenerate, build all platforms** → Task 4. ✓
- **tvOS unchanged** → only `#if !os(tvOS)` / shared code touched; Task 4 Step 6 builds tvOS as a guard. ✓
- **No server change; Android flagged** → documented in the spec; no client task needed. ✓

Naming is consistent across tasks: `topRunwaySpacing`, `HomeFocusTarget.topSpacer`, `regularSections`, `refreshStatusTopPadding`, `onScrollOffsetChange`.
