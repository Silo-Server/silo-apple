# Now-Playing Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the cast/audio "now-playing" bar rest directly above the bottom tab bar instead of covering it, using the iOS 26 native `tabViewBottomAccessory` with an iOS 18 `safeAreaInset` fallback.

**Architecture:** A single `NowPlayingShelf` view selects the one active accessory (cast takes priority over audio) and reuses the existing `SiloCastMiniBar` / `AudioMiniPlayerView` bodies. A `NowPlayingShelfAttachment` view modifier hosts that shelf on the `TabView` — via `tabViewBottomAccessory` on iOS 26, via `safeAreaInset(edge:.bottom)` on iOS 18 — and is gated so nothing shows when idle. The iPad-sidebar / macOS layouts keep a bottom `safeAreaInset`. The old shared inset on the outer `Group` in `MainTabView` (the cause of the overlap) is removed.

**Tech Stack:** Swift 5, SwiftUI, XcodeGen (`project.yml`), XCTest (none added here — UI change per `CLAUDE.md`).

**Reference spec:** `docs/superpowers/specs/2026-06-16-now-playing-shelf-design.md`

**Testing note:** Per `CLAUDE.md`, do not add unit tests for this UI change. Verification is "build passes (iOS + macOS)" plus a visual check in the simulator. Each task ends by building and committing.

---

## File Structure

- **Create** `iosApp/iosApp/Cast/iOS/NowPlayingBarStyle.swift` — shared `NowPlayingBarStyle` enum + `NowPlayingBarChrome` view modifier (card vs chromeless). Cross-platform; no cast/audio dependencies.
- **Create** `iosApp/iosApp/Cast/iOS/NowPlayingShelf.swift` — `NowPlayingShelf` (selects the active accessory) + `NowPlayingShelfAttachment` (iOS-only host modifier).
- **Modify** `iosApp/iosApp/Cast/iOS/SiloCastMiniBar.swift` — accept a `style`, apply chrome via `NowPlayingBarChrome`.
- **Modify** `iosApp/iosApp/Screens/Audio/AudioMiniPlayerView.swift` — accept a `style`, apply chrome via `NowPlayingBarChrome`.
- **Modify** `iosApp/iosApp/ContentView.swift` — remove the outer `.safeAreaInset` cast+audio block; attach the shelf in `tabLayout` (iOS) and `sidebarLayout`.

> The two `Create` files live under `Cast/iOS/` next to `SiloCastMiniBar.swift`. They are compiled on all platforms (the cast-specific code inside is `#if os(iOS)`-guarded), so the folder name is cosmetic. After creating a file, run `cd iosApp && xcodegen generate` before building so the generated project picks it up.

---

## Task 1: Shared bar style + chromeless chrome, applied to both bars

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/NowPlayingBarStyle.swift`
- Modify: `iosApp/iosApp/Cast/iOS/SiloCastMiniBar.swift`
- Modify: `iosApp/iosApp/Screens/Audio/AudioMiniPlayerView.swift`

- [ ] **Step 1: Create the style + chrome file**

Create `iosApp/iosApp/Cast/iOS/NowPlayingBarStyle.swift`:

```swift
import SwiftUI

/// How a now-playing bar renders its background.
/// - `.card`: the bar draws its own translucent rounded card (used when it sits
///   loose above a plain tab bar / sidebar — the iOS 18 fallback and iPad/macOS).
/// - `.accessory`: chromeless — the host (iOS 26 `tabViewBottomAccessory`) provides
///   the Liquid Glass background, so the bar must not draw its own card.
enum NowPlayingBarStyle {
    case card
    case accessory
}

/// Applies (or omits) the rounded translucent card behind a now-playing bar.
struct NowPlayingBarChrome: ViewModifier {
    let style: NowPlayingBarStyle

    func body(content: Content) -> some View {
        switch style {
        case .card:
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.siloOutline, lineWidth: 1)
                )
        case .accessory:
            content
        }
    }
}
```

- [ ] **Step 2: Add `style` to `SiloCastMiniBar` and route chrome through `NowPlayingBarChrome`**

In `iosApp/iosApp/Cast/iOS/SiloCastMiniBar.swift`, add the property just under `@State private var artwork`:

```swift
    @Bindable var controller: SiloCastController
    var style: NowPlayingBarStyle = .card
    @State private var artwork = SiloCastArtworkResolver()
```

Then replace the chrome chain. Change:

```swift
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.siloOutline, lineWidth: 1))
                .foregroundStyle(Color.siloOnSurface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
```

to:

```swift
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(NowPlayingBarChrome(style: style))
                .foregroundStyle(Color.siloOnSurface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, style == .card ? 12 : 0)
```

- [ ] **Step 3: Add `style` to `AudioMiniPlayerView` and route chrome through `NowPlayingBarChrome`**

In `iosApp/iosApp/Screens/Audio/AudioMiniPlayerView.swift`, add the property under the struct's environment line:

```swift
struct AudioMiniPlayerView: View {
    @Environment(AudioPlaybackStore.self) private var audioStore
    var style: NowPlayingBarStyle = .card
```

Then replace the chrome chain. Change:

```swift
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.siloOutline, lineWidth: 1)
            }
            .overlay(alignment: .bottomLeading) {
```

to:

```swift
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(NowPlayingBarChrome(style: style))
            .overlay(alignment: .bottomLeading) {
```

And change the trailing outer padding. Change:

```swift
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
```

to:

```swift
            .padding(.horizontal, style == .card ? 16 : 0)
            .padding(.bottom, style == .card ? 8 : 0)
        }
    }
```

- [ ] **Step 4: Regenerate the project and build (iOS)**

Run:

```bash
cd iosApp && xcodegen generate && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (Existing call sites still compile because `style` defaults to `.card`.)

- [ ] **Step 5: Commit**

```bash
git add iosApp/iosApp/Cast/iOS/NowPlayingBarStyle.swift iosApp/iosApp/Cast/iOS/SiloCastMiniBar.swift iosApp/iosApp/Screens/Audio/AudioMiniPlayerView.swift iosApp/Silo.xcodeproj
git commit -m "cast(iOS): chromeless style option for now-playing bars"
```

---

## Task 2: `NowPlayingShelf` + `NowPlayingShelfAttachment`

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/NowPlayingShelf.swift`

- [ ] **Step 1: Create the shelf + attachment file**

Create `iosApp/iosApp/Cast/iOS/NowPlayingShelf.swift`:

```swift
import SwiftUI

/// The single now-playing accessory shown above the tab bar. Only one bar shows
/// at a time: a cast session takes priority over an audiobook session. Renders
/// nothing (zero space) when neither is active.
struct NowPlayingShelf: View {
    var style: NowPlayingBarStyle = .card

    #if os(iOS)
    @Environment(SiloCastController.self) private var castController
    #endif
    @Environment(AudioPlaybackStore.self) private var audioStore

    var body: some View {
        #if os(iOS)
        if castController.hasActiveSession && !castController.isShowingRemoteControl {
            SiloCastMiniBar(controller: castController, style: style)
                .animation(.snappy, value: castController.hasActiveSession)
                .animation(.snappy, value: castController.isShowingRemoteControl)
        } else if audioStore.player.hasActiveSession {
            AudioMiniPlayerView(style: style)
                .animation(.snappy, value: audioStore.player.hasActiveSession)
        }
        #else
        if audioStore.player.hasActiveSession {
            AudioMiniPlayerView(style: style)
                .animation(.snappy, value: audioStore.player.hasActiveSession)
        }
        #endif
    }
}

#if os(iOS)
/// Hosts `NowPlayingShelf` on a `TabView` so it rests above the tab bar.
/// iOS 26: native `tabViewBottomAccessory` (Liquid Glass, chromeless content).
/// iOS 18: a bottom `safeAreaInset` carrying the card-styled shelf.
/// The accessory is only attached while something is playing, so no empty bar
/// shows when idle.
struct NowPlayingShelfAttachment: ViewModifier {
    @Environment(SiloCastController.self) private var castController
    @Environment(AudioPlaybackStore.self) private var audioStore

    private var isActive: Bool {
        if castController.hasActiveSession && !castController.isShowingRemoteControl {
            return true
        }
        return audioStore.player.hasActiveSession
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isActive {
                content.tabViewBottomAccessory {
                    NowPlayingShelf(style: .accessory)
                }
            } else {
                content
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isActive {
                    NowPlayingShelf(style: .card)
                }
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project and build (iOS)**

Run:

```bash
cd iosApp && xcodegen generate && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (The new types are unused for now — an "unused" note is fine; a hard failure is not.)

> If the compiler reports `tabViewBottomAccessory` as unavailable, confirm the SDK is iOS 26+ and that the modifier is being applied to a `TabView` content type. If the native accessory cannot attach to this app's classic `.tabItem`-style `TabView`, fall back to using the `safeAreaInset` branch for iOS 26 as well (it also fixes the overlap) and note it in the commit.

- [ ] **Step 3: Commit**

```bash
git add iosApp/iosApp/Cast/iOS/NowPlayingShelf.swift iosApp/Silo.xcodeproj
git commit -m "cast(iOS): NowPlayingShelf + tab-bar accessory attachment"
```

---

## Task 3: Wire the shelf into `MainTabView`

**Files:**
- Modify: `iosApp/iosApp/ContentView.swift` (`MainTabView`: body ~479-528, `tabLayout` ~539-563, `sidebarLayout` ~575-599)

- [ ] **Step 1: Remove the overlapping outer inset**

In `MainTabView.body`, delete the `.safeAreaInset` block that currently carries the two bars. Change:

```swift
        .tint(.siloOnSurface)
        #if !os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            #if os(iOS)
            SiloCastMiniBar(controller: castController)
                .animation(.snappy, value: castController.hasActiveSession)
                .animation(.snappy, value: castController.isShowingRemoteControl)
            #endif
            AudioMiniPlayerView()
        }
        .fullScreenCover(isPresented: Binding(
```

to:

```swift
        .tint(.siloOnSurface)
        #if !os(macOS)
        .fullScreenCover(isPresented: Binding(
```

(Leave the three `.fullScreenCover` modifiers and the closing `#endif` exactly as they are.)

- [ ] **Step 2: Attach the shelf in the tab layout**

In `tabLayout`, attach the modifier to the `TabView` after its `.navigationDestination`. Change:

```swift
            .navigationDestination(for: Route.self) { route in
                routeContent(for: route)
            }
        }
    }

    /// iPad regular width: sidebar list + detail pane.
```

to:

```swift
            .navigationDestination(for: Route.self) { route in
                routeContent(for: route)
            }
            #if os(iOS)
            .modifier(NowPlayingShelfAttachment())
            #endif
        }
    }

    /// iPad regular width: sidebar list + detail pane.
```

- [ ] **Step 3: Attach the shelf in the sidebar layout**

In `sidebarLayout`, add a bottom `safeAreaInset` carrying the card-styled shelf (no tab bar here, so no native accessory). Change:

```swift
        }
        .environment(\.sidebarToggle, toggleSidebar)
    }
```

to:

```swift
        }
        .environment(\.sidebarToggle, toggleSidebar)
        #if !os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingShelf(style: .card)
        }
        #else
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingShelf(style: .card)
        }
        #endif
    }
```

> Both branches are identical, so you may instead write a single unconditional `.safeAreaInset(edge: .bottom, spacing: 0) { NowPlayingShelf(style: .card) }`. `NowPlayingShelf` compiles on macOS (audio-only) and iOS (cast + audio), so no platform guard is required here.

- [ ] **Step 4: Build (iOS) and build (macOS) to confirm cross-platform compile**

Run (iOS):

```bash
cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

Run (macOS):

```bash
cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add iosApp/iosApp/ContentView.swift
git commit -m "cast(iOS): host now-playing shelf above the tab bar (fixes mini-bar overlap)"
```

---

## Task 4: Visual verification in the simulator

No code changes unless a defect is found. Verifies the actual fix: the shelf sits above the tab bar and the tab bar stays tappable.

- [ ] **Step 1: Launch the app on the iOS 26 simulator**

```bash
cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
```

Install/launch the freshly built `.app` (path printed in the build log under `Products/Debug-iphonesimulator/Silo.app`):

```bash
xcrun simctl install booted "$(cd iosApp && xcodebuild -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{d=$3}/ FULL_PRODUCT_NAME =/{p=$3}END{print d"/"p}')"
xcrun simctl launch booted com.silo.app 2>/dev/null || xcrun simctl launch booted "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' iosApp/Info.plist 2>/dev/null)"
```

> If the bundle id lookup is unclear, find it with `grep -i bundleIdentifier iosApp/project.yml` or read it from the build settings (`PRODUCT_BUNDLE_IDENTIFIER`). Sign-in for the dev server is admin / water1234 (see the SiloTV simulator-debugging memory).

- [ ] **Step 2: Trigger an active session and confirm placement**

The easiest accessory to trigger is the **audiobook** bar (no second device needed): sign in, open any audiobook, and start playback. Then return to a tab screen.

Confirm:
- The now-playing bar sits **above** the tab bar, not over it.
- All tab-bar items (Home / Library / Search / …) are fully visible and tappable.
- On iOS 26 the bar shows the system Liquid Glass background (chromeless content), not a doubled card-on-glass.

Capture a screenshot:

```bash
xcrun simctl io booted screenshot /tmp/now-playing-shelf-ios26.png
```

- [ ] **Step 3: Confirm idle state shows no bar**

Stop/close the audiobook so no session is active. Confirm the shelf disappears entirely (no empty glass bar, no reserved blank strip above the tab bar).

```bash
xcrun simctl io booted screenshot /tmp/now-playing-idle-ios26.png
```

- [ ] **Step 4 (optional): Cast bar + iOS 18 fallback**

- If a cast target is available (real Apple TV or a second Silo TV simulator per the companion-pairing memory), start a cast session and confirm the cast bar appears above the tab bar and that tapping it opens the full remote.
- Check for an iOS 18 runtime: `xcrun simctl list runtimes | grep "iOS 18"`. If present, build/run on an iOS 18 device sim (e.g. `name=iPhone 15`) and repeat Steps 2–3 to confirm the `safeAreaInset` fallback also rests above the tab bar. If no iOS 18 runtime is installed, note it as skipped — the fallback path still compiled in Task 3.

- [ ] **Step 5: Report**

Summarize: builds (iOS + macOS) passed; shelf sits above the tab bar with tabs tappable on iOS 26; idle shows nothing; cast/iOS-18 checks done or noted as skipped. Attach the screenshots. No commit (verification only) unless a defect required a fix.

---

## Self-Review notes

- **Spec coverage:** shelf above tab bar (Tasks 2–3); native iOS 26 + iOS 18 fallback (Task 2 `NowPlayingShelfAttachment`); single-slot cast-priority (Task 2 `NowPlayingShelf` ordering); unify both bars / remove outer inset (Tasks 1, 3); idle = no bar (Task 2 `isActive` gate + Task 4 Step 3); iPad sidebar / macOS bottom placement (Task 3 Step 3); no unit tests (testing note); verify on iOS 26 + iOS 18 (Task 4). Out-of-scope items (placement-aware expand/inline, stacking, raising deployment target) are not implemented.
- **Type consistency:** `NowPlayingBarStyle` (`.card` / `.accessory`) is defined once (Task 1) and consumed by `NowPlayingBarChrome`, `SiloCastMiniBar`, `AudioMiniPlayerView`, and `NowPlayingShelf`. `SiloCastMiniBar(controller:style:)` and `AudioMiniPlayerView(style:)` signatures match their call sites in `NowPlayingShelf`. `NowPlayingShelfAttachment` is `#if os(iOS)` and applied only under `#if os(iOS)` in `tabLayout`.
- **Risk:** `tabViewBottomAccessory` on a classic `.tabItem` `TabView` — mitigation noted inline (Task 2 Step 2): fall back to the `safeAreaInset` branch for iOS 26 too if needed.
