# iOS Cast Remote Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the iOS cast/remote UI into a native, artwork-forward "now-playing" experience without changing the wire protocol or the tvOS receiver.

**Architecture:** Pure iOS view-layer change. `SiloCastViews.swift` is split into four focused, `#if os(iOS)`-guarded files under `iosApp/iosApp/Cast/iOS/`. Artwork is resolved client-side from the `contentId` already in the cast state (cache → API), so no protocol field is added. The remote screen is split into a thin controller-observing wrapper plus a pure presentational view driven by plain `SiloCastPlaybackState` + a command callback, which makes it previewable with mock data.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`, XcodeGen (`project.yml`), existing app primitives (`AsyncImageView`, `PlayerTimeFormatter`, `SiloAPI`, `ResponseCache`, `Color.silo*` tokens).

---

## Testing approach (read first)

Per `CLAUDE.md`: **"Do not add tests for small changes or UI changes unless requested."** This is a UI change, so **no XCTest is added.** Verification per task is:

1. **Compile gate (hard):** the iOS build must succeed.
2. **Visual gate:** SwiftUI `#Preview` canvas in Xcode (instant, mock data) and/or the simulator smoke test in Task 5.

The artwork resolver is low-risk network/cache glue (not critical/high-risk shared logic), so it is verified by compile + visual, not a unit test.

## Conventions used in every task

- **Build (iOS):**
  ```bash
  cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
  ```
  Expected: ends with `** BUILD SUCCEEDED **`.
- **Regenerate the project** whenever a file is **added or deleted** (the iOS/tvOS targets glob `iosApp/`, but the generated `Silo.xcodeproj` must be refreshed to pick up new/removed files):
  ```bash
  cd iosApp && xcodegen generate
  ```
- **`Silo.xcodeproj` is gitignored** (XcodeGen output) — never `git add` it. Commit only the Swift/doc files.
- **Every new file under `Cast/iOS/` MUST be wrapped in `#if os(iOS) … #endif`** — the tvOS (`SiloTV`) target also globs `iosApp/` and will otherwise try to compile iOS-only types.
- **Monochrome chrome** (spec §3): no chromatic accent. White (`siloOnSurface`) fills, black (`siloBackground`) glyph on the play button; artwork is the only color.

## File structure (decomposition)

| File | Responsibility | Task |
|---|---|---|
| `iosApp/iosApp/Cast/iOS/SiloCastArtwork.swift` (new) | `SiloCastArtworkResolver` (contentId → poster/backdrop) + `SiloCastArtworkBackground` (blurred backdrop). | 1 |
| `iosApp/iosApp/Cast/iOS/SiloCastRemoteControlView.swift` (new) | `SiloCastRemoteControlView` wrapper + `RemoteNowPlayingContent` presentational view + `RemoteChipLabel` + previews. | 2 |
| `iosApp/iosApp/Cast/iOS/SiloCastTargetPickerView.swift` (new) | `SiloCastTargetPickerView` with searching/found/empty states. | 3 |
| `iosApp/iosApp/Cast/iOS/SiloCastControlModeButton.swift` (new) | `SiloCastControlModeButton` restyled to chrome tokens. | 4 |
| `iosApp/iosApp/Cast/iOS/SiloCastViews.swift` (delete by end of Task 4) | Emptied as structs migrate out; deleted once empty. | 2–4 |

Call sites in `HomeView.swift`, `ContentView.swift`/`MainTabView` reference these types **by name only**, which is preserved — so no call-site edits are required.

---

### Task 1: Artwork resolver + blurred background

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/SiloCastArtwork.swift`

- [ ] **Step 1: Create `SiloCastArtwork.swift`**

```swift
#if os(iOS)
import SwiftUI

/// Resolves poster/backdrop artwork for the cast remote from the `contentId`
/// already present in the cast playback state — no wire-protocol field needed.
/// Reuses the same item-detail path (cache → API) the detail screen uses.
@MainActor
@Observable
final class SiloCastArtworkResolver {
    private(set) var posterURL: String?
    private(set) var backdropURL: String?
    private var resolvedContentId: String?

    func resolve(contentId: String?) async {
        guard let contentId, !contentId.isEmpty else {
            posterURL = nil
            backdropURL = nil
            resolvedContentId = nil
            return
        }
        guard contentId != resolvedContentId else { return }

        if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(contentId)) {
            apply(cached, contentId: contentId)
            return
        }

        do {
            let detail = try await SiloAPI.shared.itemDetail(contentId: contentId)
            apply(detail, contentId: contentId)
        } catch {
            // Degrade silently: the remote simply shows the flat background.
        }
    }

    private func apply(_ detail: ItemDetail, contentId: String) {
        posterURL = detail.posterUrl
        backdropURL = detail.backdropUrl
        resolvedContentId = contentId
    }
}

/// Full-bleed blurred-artwork backdrop behind the now-playing content.
/// Falls back to flat OLED black when no artwork is available.
struct SiloCastArtworkBackground: View {
    let urlString: String?

    var body: some View {
        ZStack {
            Color.siloBackground
            if let urlString, !urlString.isEmpty {
                AsyncImageView(url: urlString, contentMode: .fill, placeholderStyle: .clear)
                    .id(urlString)
                    .blur(radius: 40)
                    .opacity(0.45)
                    .clipped()
            }
            Color.siloBackground.opacity(0.55)
        }
        .ignoresSafeArea()
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project**

Run: `cd iosApp && xcodegen generate`
Expected: `Created project at … Silo.xcodeproj`.

- [ ] **Step 3: Build**

Run the iOS build command (see Conventions).
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add iosApp/iosApp/Cast/iOS/SiloCastArtwork.swift
git commit -m "iOS cast: add client-side artwork resolver + blurred backdrop"
```

---

### Task 2: Native now-playing remote screen

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/SiloCastRemoteControlView.swift`
- Modify: `iosApp/iosApp/Cast/iOS/SiloCastViews.swift` (delete the old `SiloCastRemoteControlView` struct)

- [ ] **Step 1: Create `SiloCastRemoteControlView.swift`**

```swift
#if os(iOS)
import SwiftUI

/// Native "now-playing" remote for controlling Silo playback on an Apple TV.
/// Thin wrapper: observes the cast session and drives the presentational
/// `RemoteNowPlayingContent` with plain state + a command callback.
struct SiloCastRemoteControlView: View {
    @Bindable var controller: SiloCastController
    @Environment(\.dismiss) private var dismiss
    @State private var artwork = SiloCastArtworkResolver()
    @State private var isShowingPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                SiloCastArtworkBackground(urlString: artwork.backdropURL ?? artwork.posterURL)
                content
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        controller.hideRemoteControl()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Minimize")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingPicker = true
                        } label: {
                            Label("Choose a Different TV", systemImage: "tv")
                        }
                        Button {
                            controller.send(.stop)
                        } label: {
                            Label("Stop Playback", systemImage: "stop.fill")
                        }
                        Divider()
                        Button(role: .destructive) {
                            controller.disconnect()
                            dismiss()
                        } label: {
                            Label("Disconnect", systemImage: "tv.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("More options")
                }
            }
            .sheet(isPresented: $isShowingPicker) {
                SiloCastTargetPickerView(request: nil, controller: controller)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: controller.state?.contentId) {
            await artwork.resolve(contentId: controller.state?.contentId)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let state = controller.state {
            RemoteNowPlayingContent(
                state: state,
                targetName: controller.activeTarget?.name,
                posterURL: artwork.posterURL ?? artwork.backdropURL,
                onCommand: { controller.send($0) }
            )
        } else {
            connectingView
        }
    }

    private var connectingView: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.siloSurfaceElevated)
                .frame(width: 150, height: 216)
            if let error = controller.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Color.siloOnSurface)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.siloError.opacity(0.9)))
            } else {
                ProgressView()
                Text("Connecting to \(controller.activeTarget?.name ?? "Silo TV")…")
                    .font(.headline)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .padding(24)
    }
}

/// Pure presentational now-playing layout — no controller dependency, so it
/// previews with mock `SiloCastPlaybackState`.
private struct RemoteNowPlayingContent: View {
    let state: SiloCastPlaybackState
    let targetName: String?
    let posterURL: String?
    let onCommand: (SiloCastControlCommand) -> Void

    @State private var scrubPreview: Double?
    private let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            artwork
            Spacer(minLength: 16)
            titleBlock
            playingOnPill.padding(.top, 10)
            scrubber.padding(.top, 22)
            transport.padding(.top, 18)
            Spacer(minLength: 16)
            secondaryControls
            if let error = state.error, !error.isEmpty {
                errorBanner(error).padding(.top, 12)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var artwork: some View {
        Group {
            if let posterURL, !posterURL.isEmpty {
                AsyncImageView(url: posterURL, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.siloSurfaceElevated)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "tv")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.siloSecondaryText)
                    }
            }
        }
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(state.title.isEmpty ? "Loading" : state.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(Color.siloOnSurface)
            if let subtitle = state.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
    }

    @ViewBuilder
    private var playingOnPill: some View {
        if let targetName, !targetName.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 12, weight: .semibold))
                Text("Playing on \(targetName)")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Color.siloSecondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.siloChromeRestingFill))
        }
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { scrubPreview ?? state.currentTime },
                    set: { scrubPreview = $0 }
                ),
                in: 0...max(state.duration, 1),
                onEditingChanged: { editing in
                    guard !editing, let scrubPreview else { return }
                    onCommand(.seek(seconds: scrubPreview))
                    self.scrubPreview = nil
                }
            )
            .tint(Color.siloOnSurface)
            .disabled(state.duration <= 0)
            .accessibilityLabel("Playback position")

            HStack {
                Text(PlayerTimeFormatter.formatHMS(scrubPreview ?? state.currentTime))
                Spacer()
                Text(remainingLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.siloSecondaryText)
        }
    }

    private var remainingLabel: String {
        guard state.duration > 0 else { return PlayerTimeFormatter.formatHMS(state.duration) }
        let remaining = max(0, state.duration - (scrubPreview ?? state.currentTime))
        return "-" + PlayerTimeFormatter.formatHMS(remaining)
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button {
                onCommand(.seek(seconds: max(0, state.currentTime - 10)))
            } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30, weight: .regular))
            }
            .accessibilityLabel("Back 10 seconds")

            Button {
                onCommand(.playPause)
            } label: {
                ZStack {
                    Circle().fill(Color.siloOnSurface).frame(width: 64, height: 64)
                    if state.isLoading || state.isBuffering {
                        ProgressView().tint(Color.siloBackground)
                    } else {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.siloBackground)
                    }
                }
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            Button {
                let target = state.duration > 0 ? min(state.duration, state.currentTime + 30) : state.currentTime + 30
                onCommand(.seek(seconds: target))
            } label: {
                Image(systemName: "goforward.30").font(.system(size: 30, weight: .regular))
            }
            .accessibilityLabel("Forward 30 seconds")
        }
        .foregroundStyle(Color.siloOnSurface)
        .buttonStyle(.plain)
    }

    private var secondaryControls: some View {
        HStack(alignment: .top, spacing: 8) {
            if !state.audioTracks.isEmpty {
                audioMenu.frame(maxWidth: .infinity)
            }
            if !state.subtitleTracks.isEmpty {
                subtitleMenu.frame(maxWidth: .infinity)
            }
            if !state.qualityOptions.isEmpty {
                qualityMenu.frame(maxWidth: .infinity)
            }
            speedMenu.frame(maxWidth: .infinity)
            if state.supportsVideoGravity || state.supportsHDRToggle {
                displayMenu.frame(maxWidth: .infinity)
            }
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(state.audioTracks) { track in
                Button { onCommand(.selectAudioTrack(track.trackId)) } label: {
                    Label(track.title, systemImage: state.selectedAudioTrackId == track.trackId ? "checkmark" : "waveform")
                }
            }
        } label: { RemoteChipLabel(systemImage: "waveform", caption: "Audio") }
    }

    private var subtitleMenu: some View {
        Menu {
            Button { onCommand(.selectSubtitleTrack(nil)) } label: {
                Label("Off", systemImage: state.selectedSubtitleTrackId == nil ? "checkmark" : "captions.bubble")
            }
            ForEach(state.subtitleTracks) { track in
                Button { onCommand(.selectSubtitleTrack(track.trackId)) } label: {
                    Label(track.title, systemImage: state.selectedSubtitleTrackId == track.trackId ? "checkmark" : "captions.bubble")
                }
            }
        } label: { RemoteChipLabel(systemImage: "captions.bubble", caption: "Subtitles") }
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(state.qualityOptions) { option in
                Button { onCommand(.setQuality(option.id)) } label: {
                    Label(option.label, systemImage: state.activeQualityId == option.id ? "checkmark" : "slider.horizontal.3")
                }
            }
        } label: { RemoteChipLabel(systemImage: "slider.horizontal.3", caption: "Quality") }
        .disabled(state.isQualitySwitching)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(speedOptions, id: \.self) { speed in
                Button { onCommand(.setPlaybackSpeed(speed)) } label: {
                    Label(speedLabel(speed), systemImage: abs(state.playbackSpeed - speed) < 0.01 ? "checkmark" : "speedometer")
                }
            }
        } label: { RemoteChipLabel(systemImage: "speedometer", caption: "Speed") }
    }

    private var displayMenu: some View {
        Menu {
            if state.supportsVideoGravity {
                ForEach(VideoGravity.allCases, id: \.rawValue) { gravity in
                    Button { onCommand(.setVideoGravity(gravity.rawValue)) } label: {
                        Label(gravity.label, systemImage: state.videoGravity == gravity.rawValue ? "checkmark" : "rectangle.inset.filled")
                    }
                }
            }
            if state.supportsHDRToggle {
                Button { onCommand(.setHDREnabled(!state.hdrEnabled)) } label: {
                    Label(state.hdrEnabled ? "HDR On" : "HDR Off", systemImage: state.hdrEnabled ? "checkmark" : "sun.max")
                }
            }
        } label: { RemoteChipLabel(systemImage: "rectangle.inset.filled", caption: "Aspect") }
    }

    private func speedLabel(_ speed: Double) -> String {
        switch speed {
        case 1.0: return "1.0×"
        case 0.75: return "0.75×"
        case 1.25: return "1.25×"
        case 1.5: return "1.5×"
        case 2.0: return "2.0×"
        default: return "\(speed)×"
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Color.siloOnSurface)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.siloError.opacity(0.9)))
    }
}

private struct RemoteChipLabel: View {
    let systemImage: String
    let caption: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
            Text(caption)
                .font(.caption2)
        }
        .foregroundStyle(Color.siloOnSurface.opacity(0.9))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

#if DEBUG
private extension SiloCastPlaybackState {
    static func previewPlaying() -> SiloCastPlaybackState {
        SiloCastPlaybackState(
            contentId: "preview", sessionId: "s1", title: "The Bear",
            subtitle: "Season 3 · Episode 4 · Children",
            isPlaying: true, isLoading: false, isBuffering: false,
            currentTime: 1104, duration: 2895,
            audioTracks: [SiloCastTrack(kind: "audio", trackId: 1, title: "English 5.1", detail: "AC-3")],
            subtitleTracks: [SiloCastTrack(kind: "subtitle", trackId: 10, title: "English", detail: nil)],
            selectedAudioTrackId: 1, selectedSubtitleTrackId: nil,
            qualityOptions: [SiloCastOption(id: "auto", label: "Auto", detail: nil),
                             SiloCastOption(id: "1080", label: "1080p", detail: nil)],
            activeQualityId: "auto", isQualitySwitching: false,
            playbackSpeed: 1.0, videoGravity: VideoGravity.fit.rawValue, hdrEnabled: false,
            supportsVideoGravity: true, supportsHDRToggle: true, error: nil
        )
    }
}

#Preview("Now Playing") {
    ZStack {
        SiloCastArtworkBackground(urlString: nil)
        RemoteNowPlayingContent(
            state: .previewPlaying(),
            targetName: "Living Room",
            posterURL: nil,
            onCommand: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
#endif
#endif
```

- [ ] **Step 2: Delete the old remote view from `SiloCastViews.swift`**

In `iosApp/iosApp/Cast/iOS/SiloCastViews.swift`, delete the **entire** `struct SiloCastRemoteControlView: View { … }` definition (lines ~135–377, including its `content`, `progressControl`, `transportControls`, `commandMenus`, and `speedLabel` members). Leave `SiloCastTargetPickerView`, `SiloCastControlModeButton`, the leading `#if os(iOS)` / `import SwiftUI`, and trailing `#endif` intact.

- [ ] **Step 3: Regenerate the project**

Run: `cd iosApp && xcodegen generate`

- [ ] **Step 4: Build**

Run the iOS build command.
Expected: `** BUILD SUCCEEDED **`. (If it fails with "invalid redeclaration of 'SiloCastRemoteControlView'", Step 2's deletion was incomplete.)

- [ ] **Step 5: Visual check**

Open the `Now Playing` preview in Xcode's canvas (or run the simulator — Task 5). Expected: blurred/flat-black background, centered poster placeholder, "The Bear" + subtitle, "Playing on Living Room" pill, scrubber with `18:24` / `-29:51`, large white play/pause circle flanked by back-10 / forward-30, and one evenly-spaced row of Audio · Subtitles · Quality · Speed · Aspect chips. No row of bordered buttons; no stray Stop.

- [ ] **Step 6: Commit**

```bash
git add iosApp/iosApp/Cast/iOS/SiloCastRemoteControlView.swift iosApp/iosApp/Cast/iOS/SiloCastViews.swift
git commit -m "iOS cast: native now-playing remote (artwork, scrubber, consolidated controls)"
```

---

### Task 3: Target picker with searching state

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/SiloCastTargetPickerView.swift`
- Modify: `iosApp/iosApp/Cast/iOS/SiloCastViews.swift` (delete the old `SiloCastTargetPickerView` struct)

- [ ] **Step 1: Create `SiloCastTargetPickerView.swift`**

```swift
#if os(iOS)
import SwiftUI

struct SiloCastTargetPickerView: View {
    let request: SiloCastPlaybackRequest?
    @Bindable var controller: SiloCastController

    @State private var browser = SiloCastBrowser()
    @State private var searchTimedOut = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if !browser.found.isEmpty {
                    foundList
                } else if searchTimedOut {
                    emptyState
                } else {
                    searchingState
                }
            }
            .background(Color.siloBackground.ignoresSafeArea())
            .navigationTitle("Cast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                browser.start()
                try? await Task.sleep(for: .seconds(8))
                searchTimedOut = true
            }
            .onDisappear { browser.stop() }
        }
        .preferredColorScheme(.dark)
    }

    private var searchingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Searching for Silo TVs…")
                .font(.headline)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Silo TVs Found",
            systemImage: "tv",
            description: Text("Foreground Apple TVs on this server appear here.")
        )
    }

    private var foundList: some View {
        List(browser.found) { target in
            Button {
                Task {
                    if let request {
                        await controller.cast(to: target, request: request)
                    } else {
                        await controller.connect(to: target)
                    }
                    dismiss()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tv")
                        .font(.title3)
                        .foregroundStyle(Color.siloOnSurface)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.siloChromeRestingFill))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name).font(.headline)
                        if let serverName = target.serverName {
                            Text(serverName)
                                .font(.subheadline)
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                    }

                    Spacer()

                    if controller.isConnecting && controller.activeTarget?.id == target.id {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.siloSurface)
        }
        .scrollContentBackground(.hidden)
    }
}

#if DEBUG
#Preview("Searching") {
    SiloCastTargetPickerView(request: nil, controller: SiloCastController())
}
#endif
#endif
```

- [ ] **Step 2: Delete the old picker from `SiloCastViews.swift`**

In `SiloCastViews.swift`, delete the **entire** `struct SiloCastTargetPickerView: View { … }` definition. Leave `SiloCastControlModeButton` and the `#if os(iOS)` / `import SwiftUI` / `#endif` wrapper intact.

- [ ] **Step 3: Regenerate the project**

Run: `cd iosApp && xcodegen generate`

- [ ] **Step 4: Build**

Run the iOS build command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Visual check**

Open the `Searching` preview. Expected: a centered spinner + "Searching for Silo TVs…" — **not** the "No Silo TVs Found" card. (The empty card appears only after the 8s timeout with still-empty results.)

- [ ] **Step 6: Commit**

```bash
git add iosApp/iosApp/Cast/iOS/SiloCastTargetPickerView.swift iosApp/iosApp/Cast/iOS/SiloCastViews.swift
git commit -m "iOS cast: target picker shows Searching state before the empty card"
```

---

### Task 4: Control-mode button restyle + remove dead file

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/SiloCastControlModeButton.swift`
- Delete: `iosApp/iosApp/Cast/iOS/SiloCastViews.swift` (now empty)

- [ ] **Step 1: Create `SiloCastControlModeButton.swift`**

```swift
#if os(iOS)
import SwiftUI

struct SiloCastControlModeButton: View {
    @Bindable var controller: SiloCastController
    let onChooseTarget: () -> Void

    var body: some View {
        if controller.hasActiveSession {
            Menu {
                Button { controller.showRemoteControl() } label: {
                    Label("Remote Control", systemImage: "slider.horizontal.3")
                }
                Button { onChooseTarget() } label: {
                    Label("Choose TV", systemImage: "tv")
                }
                Divider()
                Button(role: .destructive) { controller.turnOffControlMode() } label: {
                    Label("Turn Off Control Mode", systemImage: "tv.slash")
                }
            } label: {
                buttonLabel(isActive: true)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("TV control mode")
        } else {
            Button(action: onChooseTarget) {
                buttonLabel(isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cast to TV")
        }
    }

    private func buttonLabel(isActive: Bool) -> some View {
        Image(systemName: "airplayvideo")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isActive ? Color.siloBackground : Color.siloOnSurface)
            .frame(width: 40, height: 40)
            .background {
                Circle().fill(isActive ? Color.siloOnSurface : Color.siloChromeRestingFill)
            }
            .overlay {
                Circle().stroke(isActive ? Color.clear : Color.siloOutline, lineWidth: 1)
            }
            .contentShape(Circle())
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 20) {
        SiloCastControlModeButton(controller: SiloCastController(), onChooseTarget: {})
    }
    .padding()
    .background(Color.siloBackground)
}
#endif
#endif
```

- [ ] **Step 2: Delete the now-empty `SiloCastViews.swift`**

Confirm only the `#if os(iOS)` / `import SwiftUI` / `#endif` shell remains (all three structs migrated out), then delete the file:

```bash
git rm iosApp/iosApp/Cast/iOS/SiloCastViews.swift
```

- [ ] **Step 3: Regenerate the project**

Run: `cd iosApp && xcodegen generate`

- [ ] **Step 4: Build**

Run the iOS build command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add iosApp/iosApp/Cast/iOS/SiloCastControlModeButton.swift
git commit -m "iOS cast: restyle control-mode button to chrome tokens; remove split-out SiloCastViews"
```

---

### Task 5: Full verification (iOS + tvOS + simulator smoke test)

**Files:** none (verification only).

- [ ] **Step 1: Clean iOS build**

Run the iOS build command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: tvOS build is unaffected**

```bash
cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloTV \
  -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. (All new files are `#if os(iOS)`-guarded, so tvOS compiles them to nothing.)

- [ ] **Step 3: Simulator smoke test**

Boot an iPhone simulator, run the `Silo` scheme, sign in (`admin` / `water1234`), and on Home tap the airplay button in the top bar. Confirm:
- The picker opens showing **"Searching for Silo TVs…"** with a spinner (not the empty card) on first open.
- With no live Apple TV receiver, the remote screen itself is best verified via the Xcode `Now Playing` preview (Task 2, Step 5) since it needs a cast session. If a tvOS receiver is available on the same network, cast a title and confirm the now-playing screen matches the design (artwork, scrubber, transport, single control row, `•••` menu with Stop/Disconnect/Choose TV).

- [ ] **Step 4: Confirm git state**

```bash
git status --short
```
Expected: clean working tree for the cast files; `Silo.xcodeproj` does not appear (gitignored). Codex's other uncommitted cast plumbing (`PlayerViewModel`, `TVCastReceiver`, etc.) is untouched and unchanged from before this plan.

---

## Self-review

**1. Spec coverage:**
- §5 remote anatomy → Task 2. ✓
- §6 artwork resolution (cache→API, contentId) → Task 1 (resolver + background) wired in Task 2. ✓
- §6 scrubber (`−remaining`, preview, disabled when `duration<=0`) + transport (loading spinner) → Task 2. ✓
- §7 adaptive secondary control row → Task 2 `secondaryControls`. ✓
- §8 `•••` menu (Choose TV / Stop / Disconnect) + chevron-down minimize → Task 2 wrapper toolbar. ✓
- §9 connecting / loading / error states → Task 2 (`connectingView`, transport spinner, `errorBanner`). ✓
- §10 picker searching/found/empty → Task 3. ✓
- §11 control-mode button chrome tokens → Task 4. ✓
- §12 accessibility labels on every control → Task 2/3/4; Reduce Motion → no custom animations are introduced (system transitions already honor it), so nothing to gate. ✓
- §13 file split + `xcodegen` → reflected in every task. ✓
- §14 non-goals (no protocol/tvOS/controller logic changes; picker only adds local `@State`) → respected. ✓
- §15 success criteria → Task 5. ✓

**2. Placeholder scan:** No TBD/TODO/"handle errors"/"similar to". Every code step is complete and compilable.

**3. Type consistency:** `SiloCastArtworkResolver.resolve(contentId:)` / `.posterURL` / `.backdropURL`; `SiloCastArtworkBackground(urlString:)`; `RemoteNowPlayingContent(state:targetName:posterURL:onCommand:)`; `RemoteChipLabel(systemImage:caption:)`; `SiloCastPlaybackState.previewPlaying()` — all used consistently across tasks. Command factories (`.seek`, `.playPause`, `.stop`, `.selectAudioTrack`, `.selectSubtitleTrack`, `.setPlaybackSpeed`, `.setQuality`, `.setVideoGravity`, `.setHDREnabled`) match `SiloCastControlCommand`. State fields match `SiloCastPlaybackState`. `VideoGravity.allCases`/`.label`/`.rawValue`, `ResponseCache.shared.get`/`CacheKey.itemDetail`, `SiloAPI.shared.itemDetail(contentId:)`/`ItemDetail.posterUrl`/`.backdropUrl`, `AsyncImageView(url:contentMode:placeholderStyle:)`, `PlayerTimeFormatter.formatHMS` — all verified against the codebase.

No gaps found.
