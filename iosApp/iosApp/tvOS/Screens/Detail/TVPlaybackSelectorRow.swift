#if os(tvOS)
import SwiftUI

enum TVPlaybackSelectorFocus: Hashable {
    case edition
    case version
    case audio
    case subtitles
}

/// Pre-Play playback metadata row shown under the hero actions. Version ·
/// Audio · Subtitles stay visible as squared value boxes; boxes become menus
/// only when there are multiple real choices. Edition is included only when
/// there are multiple edition groups.
/// Once an effective playable version is known, the active playback metadata
/// stays visible.
/// Uses the detail view's existing version/audio/subtitle callbacks; Edition
/// is derived from `FileVersion.editionRaw` / `editionKey` and selecting one
/// routes through `onSelectVersion`.
struct TVPlaybackSelectorRow: View {
    private enum Layout {
        static let selectorSpacing: CGFloat = 28
    }

    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// Server-resolved subtitle policy for this item, used to preview what
    /// "Auto" will land on. Defaulted so callers without it keep a bare "Auto".
    var subtitleMode: String? = nil
    var subtitleSignature: SubtitleTrackSignature? = nil
    /// Profile/item "Show Forced Subtitles" preference — feeds the Auto
    /// preview's forced-track branch so the row doesn't show "Auto: Off"
    /// when playback would actually start with a forced track.
    var showForcedSubtitles: Bool = false
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let focusedSelector: FocusState<TVPlaybackSelectorFocus?>.Binding
    /// Runs synchronously when Down is pressed from this row, before tvOS
    /// resolves the next focus target. Detail pages use it to make the
    /// already-mounted browser eligible for native focus entry.
    var onPrepareBrowserEntry: () -> Void = {}
    /// Reports focus anywhere in this row. The detail canvas uses it to
    /// restore the hero framing when focus returns from the episode browser.
    let onSelectorRowFocusChanged: (Bool) -> Void

    @State private var preferredSubtitleLanguage: String?

    private var editions: [PlaybackEditions.Edition] { PlaybackEditions.editions(from: versions) }

    var body: some View {
        if hasAnySelector {
            selectorRow
                // Stretch the focus section to the full action-area width even
                // though the buttons sit on the left. Entering a focus section
                // is resolved by the section's *bounds* overlapping the move
                // vector, so a full-width section sits under every top-row
                // control — including the far-right circle buttons (List /
                // Watched / More). A Down press from any of them then lands on
                // the nearest selector instead of skipping the row. Buttons
                // stay left-aligned.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                .onMoveCommand { direction in
                    guard direction == .down else { return }
                    onPrepareBrowserEntry()
                }
                .onChange(of: focusedSelector.wrappedValue) { oldValue, newValue in
                    TVDetailFocusDiagnostics.record(
                        "selector.focusChanged",
                        target: selectorName(newValue),
                        action: newValue == nil ? "lost" : "focused",
                        state: "from=\(selectorName(oldValue)) to=\(selectorName(newValue))",
                        essential: oldValue == nil || newValue == nil
                    )
                    if (oldValue == nil) != (newValue == nil) {
                        onSelectorRowFocusChanged(newValue != nil)
                    }
                }
                .task {
                    await ProfilePrefsStore.shared.hydrateIfNeeded()
                    preferredSubtitleLanguage = ProfilePrefsStore.shared.preferredSubtitleLanguage
                }
                .onDisappear {
                    onSelectorRowFocusChanged(false)
                }
        }
    }

    private var selectorRow: some View {
        HStack(spacing: Layout.selectorSpacing) {
            if shouldShowEditionSelector {
                editionSelector
            }
            if shouldShowVersionValue {
                versionSelector
            }
            if shouldShowAudioValue {
                audioSelector
            }
            if shouldShowSubtitleValue {
                subtitleSelector
            }
        }
    }

    private var hasAnySelector: Bool {
        shouldShowEditionSelector
            || shouldShowVersionValue
            || shouldShowAudioValue
            || shouldShowSubtitleValue
    }

    private var shouldShowEditionSelector: Bool {
        editions.count > 1
    }

    private var shouldShowVersionValue: Bool {
        currentVersion != nil
    }

    private var shouldEnableVersionSelector: Bool {
        DetailPlaybackFormatting.shouldEnableVersionSelector(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    private var shouldShowAudioValue: Bool {
        DetailPlaybackFormatting.shouldShowAudioValue(version: currentVersion)
    }

    private var shouldEnableAudioSelector: Bool {
        DetailPlaybackFormatting.shouldEnableAudioSelector(version: currentVersion)
    }

    private var shouldShowSubtitleValue: Bool {
        DetailPlaybackFormatting.shouldShowSubtitleValue(version: currentVersion)
    }

    private var shouldEnableSubtitleSelector: Bool {
        DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: currentVersion)
    }

    // MARK: - Edition

    private var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    private var editionSelector: some View {
        TVSelectorButton(icon: "rectangle.stack", label: "Edition", value: currentEdition?.label ?? currentVersion?.editionDisplayLabel ?? "Standard") {
            if editions.isEmpty {
                Button("Standard") { }.disabled(true)
            } else {
                ForEach(editions) { edition in
                    Button {
                        let best = DetailVersionSelection.displayVersion(
                            versions: edition.versions,
                            selectedFileId: nil,
                            lastFileId: nil,
                            preferredQualityId: PlayerSettings.shared.preferredQuality
                        )
                        selectVersion(best?.fileId)
                    } label: {
                        selectorMenuItem(
                            title: edition.label,
                            detail: "\(edition.versions.count) version\(edition.versions.count == 1 ? "" : "s")",
                            isSelected: currentEdition?.id == edition.id
                        )
                    }
                }
            }
        }
            .focused(focusedSelector, equals: .edition)
    }

    // MARK: - Version

    @ViewBuilder
    private var versionSelector: some View {
        let summary = DetailPlaybackFormatting.versionShortLabel(currentVersion)
        let value = selectedVersionFileId == nil ? "Auto: \(summary)" : summary
        if shouldEnableVersionSelector {
            TVSelectorButton(
                icon: "tv",
                label: "Version",
                value: value
            ) {
                Button { selectVersion(nil) } label: {
                    selectorMenuItem(title: "Auto", detail: "Best match for this device", isSelected: selectedVersionFileId == nil)
                }
                ForEach(scopedVersions) { version in
                    Button {
                        selectVersion(version.fileId)
                    } label: {
                        selectorMenuItem(
                            title: DetailPlaybackFormatting.versionShortLabel(version),
                            detail: DetailPlaybackFormatting.versionDetailLabel(version),
                            isSelected: selectedVersionFileId == version.fileId
                        )
                    }
                }
            }
            .focused(focusedSelector, equals: .version)
        } else {
            TVSelectorValue(icon: "tv", label: "Version", value: value)
                .focused(focusedSelector, equals: .version)
        }
    }

    private var scopedVersions: [FileVersion] {
        DetailPlaybackFormatting.versionSelectorVersions(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSelector: some View {
        let value = DetailPlaybackFormatting.audioValueLabel(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            annotateAuto: true
        )
        if shouldEnableAudioSelector {
            TVSelectorButton(
                icon: "speaker.wave.2",
                label: "Audio",
                value: value
            ) {
                Button { selectAudioTrack(nil) } label: {
                    selectorMenuItem(title: "Auto", detail: "Use the file default track", isSelected: selectedAudioTrackIndex == nil)
                }
                let options = DetailPlaybackFormatting.audioOptions(
                    version: currentVersion,
                    selectedAudioTrackIndex: selectedAudioTrackIndex
                )
                if options.isEmpty {
                    Button("Unknown") { }.disabled(true)
                } else {
                    ForEach(options) { option in
                        Button { selectAudioTrack(option.ordinal) } label: {
                            selectorMenuItem(
                                title: option.title,
                                detail: option.detail,
                                isSelected: selectedAudioTrackIndex == option.ordinal
                            )
                        }
                    }
                }
            }
            .focused(focusedSelector, equals: .audio)
        } else {
            TVSelectorValue(icon: "speaker.wave.2", label: "Audio", value: value)
                .focused(focusedSelector, equals: .audio)
        }
    }

    // MARK: - Subtitles

    private var subtitleAutoContext: DetailPlaybackFormatting.SubtitleAutoContext {
        DetailPlaybackFormatting.SubtitleAutoContext(
            preferredLanguage: preferredSubtitleLanguage,
            mode: subtitleMode,
            signature: subtitleSignature,
            audioLanguage: DetailPlaybackFormatting.resolvedAudioLanguage(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            ),
            showForced: showForcedSubtitles
        )
    }

    @ViewBuilder
    private var subtitleSelector: some View {
        let value = DetailPlaybackFormatting.subtitleValueLabel(
            version: currentVersion,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            autoContext: subtitleAutoContext
        )
        if shouldEnableSubtitleSelector {
            TVSelectorButton(
                icon: "captions.bubble",
                label: "Subtitles",
                value: value
            ) {
                Button { selectSubtitleTrack(nil) } label: {
                    selectorMenuItem(title: "Auto", detail: "Use your subtitle preferences", isSelected: selectedSubtitleTrackIndex == nil)
                }
                Button { selectSubtitleTrack(-1) } label: {
                    selectorMenuItem(title: "Off", detail: "Start without subtitles", isSelected: selectedSubtitleTrackIndex == -1)
                }
                ForEach(DetailPlaybackFormatting.subtitleOptions(
                    version: currentVersion,
                    selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                    preferredLanguage: preferredSubtitleLanguage
                )) { option in
                    if option.isSelectable, let selectionIndex = option.selectionIndex {
                        Button { selectSubtitleTrack(selectionIndex) } label: {
                            selectorMenuItem(title: option.title, detail: option.detail, isSelected: option.isSelected)
                        }
                    } else {
                        Button {
                        } label: {
                            selectorMenuItem(title: option.title, detail: option.detail, isSelected: false)
                        }
                        .disabled(true)
                    }
                }
            }
            .focused(focusedSelector, equals: .subtitles)
        } else {
            TVSelectorValue(icon: "captions.bubble", label: "Subtitles", value: value)
                .focused(focusedSelector, equals: .subtitles)
        }
    }

    private func selectVersion(_ fileId: Int?) {
        onSelectVersion(fileId)
    }

    private func selectAudioTrack(_ index: Int?) {
        onSelectAudioTrack(index)
    }

    private func selectSubtitleTrack(_ index: Int?) {
        onSelectSubtitleTrack(index)
    }

    private func selectorName(_ focus: TVPlaybackSelectorFocus?) -> String {
        guard let focus else { return "none" }
        switch focus {
        case .edition: return "edition"
        case .version: return "version"
        case .audio: return "audio"
        case .subtitles: return "subtitles"
        }
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
///
/// Uses the system glass style rather than `TVPillButtonStyle` so it matches
/// the detail hero's action row directly above it and lets tvOS draw the
/// focus highlight. `TVPillButtonStyle` is shared with the player HUD and
/// keeps custom sizing and focus geometry for those playback-only controls.
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
        .tvDetailGlassControl(
            shape: .roundedRectangle(radius: ContinuumTheme.smallCornerRadius)
        )
        .accessibilityIdentifier("detail.selector.\(label.lowercased())")
    }
}

/// Single-choice version of the selector pill. Still focusable so the box can
/// be highlighted ("hovered") on tvOS even when there is only one option;
/// pressing Select is a no-op since there is nothing to choose. Shares the
/// interactive pill's styling and focus treatment so the row reads uniformly.
private struct TVSelectorValue: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        Button { } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .tracking(1.0)
                    .opacity(0.6)
                Text(value).font(.system(size: 22, weight: .semibold)).lineLimit(1)
            }
        }
        .tvDetailGlassControl(
            shape: .roundedRectangle(radius: ContinuumTheme.smallCornerRadius)
        )
        .accessibilityIdentifier("detail.selector.\(label.lowercased())")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}
#endif
