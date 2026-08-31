#if os(tvOS)
import SwiftUI

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
        static let outerHeight: CGFloat = 50
    }

    private enum SelectorFocus: Hashable {
        case edition
        case version
        case audio
        case subtitles
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

    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectorFocusScope
    @FocusState private var focusedSelector: SelectorFocus?
    @State private var defaultSelectorFocus: SelectorFocus?
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
                .focusScope(selectorFocusScope)
                .focusSection()
                .modifier(SelectorDefaultFocus(focus: defaultSelectorFocus, binding: $focusedSelector))
                .onChange(of: focusedSelector) { _, newValue in
                    // The restore default (see `restoreFocus`) must only
                    // outlive the menu dismissal it serves. Once focus leaves
                    // the row — up to the action row, or into an opening menu
                    // — repoint it at the leading pill so re-entering the row
                    // lands like untouched geometry instead of jumping back
                    // to the last-modified selector. Swap the value rather
                    // than clearing it: `SelectorDefaultFocus` branches on
                    // nil, and re-identifying the row subtree would tear down
                    // an open Menu.
                    if newValue == nil, defaultSelectorFocus != nil {
                        defaultSelectorFocus = firstSelector
                    }
                }
                .task {
                    await ProfilePrefsStore.shared.hydrateIfNeeded()
                    preferredSubtitleLanguage = ProfilePrefsStore.shared.preferredSubtitleLanguage
                }
        }
    }

    private var selectorRow: some View {
        HStack(spacing: 0) {
            if shouldShowEditionSelector {
                editionSelector
                if shouldShowVersionValue || shouldShowAudioValue || shouldShowSubtitleValue {
                    selectorDivider
                }
            }
            if shouldShowVersionValue {
                versionSelector
                if shouldShowAudioValue || shouldShowSubtitleValue {
                    selectorDivider
                }
            }
            if shouldShowAudioValue {
                audioSelector
                if shouldShowSubtitleValue {
                    selectorDivider
                }
            }
            if shouldShowSubtitleValue {
                subtitleSelector
            }
        }
        .frame(height: Layout.outerHeight)
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.26)))
        .overlay(Capsule().stroke(Color.white.opacity(0.42), lineWidth: 1.5))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: focusedSelector
        )
    }

    private var selectorDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 1, height: 34)
    }

    /// Leading visible pill — where entry into the row should land once the
    /// post-menu restore default has served its purpose.
    private var firstSelector: SelectorFocus {
        if shouldShowEditionSelector { return .edition }
        if shouldShowVersionValue { return .version }
        if shouldShowAudioValue { return .audio }
        return .subtitles
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
        let value = currentEdition?.label ?? currentVersion?.editionDisplayLabel ?? "Standard"
        return TVSelectorButton(
            icon: "rectangle.stack",
            label: "Edition",
            fullValue: value,
            compactValue: value,
            isExpanded: focusedSelector == .edition
        ) {
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
                        selectVersion(best?.fileId, returningFocusTo: .edition)
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
        .focused($focusedSelector, equals: .edition)
    }

    // MARK: - Version

    @ViewBuilder
    private var versionSelector: some View {
        let summary = DetailPlaybackFormatting.versionShortLabel(currentVersion)
        let value = selectedVersionFileId == nil ? "Auto: \(summary)" : summary
        let compactValue = DetailPlaybackFormatting.versionCompactLabel(currentVersion)
        if shouldEnableVersionSelector {
            TVSelectorButton(
                icon: versionQualityIcon,
                label: "Version",
                fullValue: value,
                compactValue: compactValue,
                isExpanded: focusedSelector == .version
            ) {
                Button { selectVersion(nil, returningFocusTo: .version) } label: {
                    selectorMenuItem(title: "Auto", detail: "Best match for this device", isSelected: selectedVersionFileId == nil)
                }
                ForEach(scopedVersions) { version in
                    Button {
                        selectVersion(version.fileId, returningFocusTo: .version)
                    } label: {
                        selectorMenuItem(
                            title: DetailPlaybackFormatting.versionShortLabel(version),
                            detail: DetailPlaybackFormatting.versionDetailLabel(version),
                            isSelected: selectedVersionFileId == version.fileId
                        )
                    }
                }
            }
            .focused($focusedSelector, equals: .version)
        } else {
            TVSelectorValue(
                icon: versionQualityIcon,
                label: "Version",
                fullValue: value,
                compactValue: compactValue,
                isExpanded: focusedSelector == .version
            )
            .focused($focusedSelector, equals: .version)
        }
    }

    /// Keep the glyph honest when the chosen file changes. `4k.tv` is the
    /// established design for UHD; Apple's HD/SD symbols cover the lower
    /// tiers rather than leaving a misleading 4K badge beside 1080p/720p.
    private var versionQualityIcon: String {
        let quality = [
            currentVersion?.resolution,
            DetailPlaybackFormatting.versionShortLabel(currentVersion),
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if quality.contains("2160") || quality.contains("4k") || quality.contains("uhd") {
            return "4k.tv"
        }
        if quality.contains("1080") || quality.contains("720") || quality.contains("hd") {
            return "hd"
        }
        if quality.contains("576") || quality.contains("480") || quality.contains("sd") {
            return "sd"
        }
        return "tv"
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
        let compactValue = DetailPlaybackFormatting.audioValueLabel(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            annotateAuto: false
        )
        if shouldEnableAudioSelector {
            TVSelectorButton(
                icon: "speaker.wave.2",
                label: "Audio",
                fullValue: value,
                compactValue: compactValue,
                isExpanded: focusedSelector == .audio
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
            .focused($focusedSelector, equals: .audio)
        } else {
            TVSelectorValue(
                icon: "speaker.wave.2",
                label: "Audio",
                fullValue: value,
                compactValue: compactValue,
                isExpanded: focusedSelector == .audio
            )
            .focused($focusedSelector, equals: .audio)
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
        let compactValue = compactSubtitleValue(value)
        if shouldEnableSubtitleSelector {
            TVSelectorButton(
                icon: "captions.bubble",
                label: "Subtitles",
                fullValue: "Subtitles \(value)",
                compactValue: compactValue,
                isExpanded: focusedSelector == .subtitles
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
            .focused($focusedSelector, equals: .subtitles)
        } else {
            TVSelectorValue(
                icon: "captions.bubble",
                label: "Subtitles",
                fullValue: "Subtitles \(value)",
                compactValue: compactValue,
                isExpanded: focusedSelector == .subtitles
            )
            .focused($focusedSelector, equals: .subtitles)
        }
    }

    /// Idle subtitle segment shows only the effective state: Off, Auto, or
    /// the selected/resolved language. The focused segment keeps the richer
    /// existing wording and the menu remains completely unchanged.
    private func compactSubtitleValue(_ value: String) -> String {
        let withoutAutoPrefix = value.hasPrefix("Auto: ")
            ? String(value.dropFirst("Auto: ".count))
            : value
        return withoutAutoPrefix.components(separatedBy: " · ").first
            ?? withoutAutoPrefix
    }

    private func selectVersion(_ fileId: Int?, returningFocusTo focus: SelectorFocus) {
        onSelectVersion(fileId)
        restoreFocus(to: focus)
    }

    private func selectAudioTrack(_ index: Int?) {
        onSelectAudioTrack(index)
        restoreFocus(to: .audio)
    }

    private func selectSubtitleTrack(_ index: Int?) {
        onSelectSubtitleTrack(index)
        restoreFocus(to: .subtitles)
    }

    private func restoreFocus(to focus: SelectorFocus) {
        defaultSelectorFocus = focus
        focusedSelector = focus
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: selectorFocusScope)
            focusedSelector = focus
        }
    }

    private struct SelectorDefaultFocus: ViewModifier {
        let focus: SelectorFocus?
        let binding: FocusState<SelectorFocus?>.Binding

        @ViewBuilder
        func body(content: Content) -> some View {
            if let focus {
                content.defaultFocus(binding, focus, priority: .userInitiated)
            } else {
                content
            }
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

/// One segment inside the connected selector capsule. Each segment remains a
/// real Menu so the existing version/audio/subtitle callbacks and native Siri
/// Remote menu behavior remain unchanged.
private struct TVSelectorButton<MenuContent: View>: View {
    let icon: String
    let label: String
    let fullValue: String
    let compactValue: String
    let isExpanded: Bool
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            TVSelectorSegmentLabel(
                icon: icon,
                fullValue: fullValue,
                compactValue: compactValue,
                isExpanded: isExpanded,
                showsChevron: true
            )
        }
        .menuStyle(.button)
        .buttonStyle(TVSelectorSegmentButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(fullValue)")
    }
}

/// Single-choice version of the selector pill. Still focusable so the box can
/// be highlighted ("hovered") on tvOS even when there is only one option;
/// pressing Select is a no-op since there is nothing to choose. Shares the
/// interactive pill's styling and focus treatment so the row reads uniformly.
private struct TVSelectorValue: View {
    let icon: String
    let label: String
    let fullValue: String
    let compactValue: String
    let isExpanded: Bool

    var body: some View {
        Button { } label: {
            TVSelectorSegmentLabel(
                icon: icon,
                fullValue: fullValue,
                compactValue: compactValue,
                isExpanded: isExpanded,
                showsChevron: false
            )
        }
        .buttonStyle(TVSelectorSegmentButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(fullValue)")
    }
}

/// Label whose intrinsic width follows focus. Keeping the icon in a fixed
/// frame prevents the SVG from drifting while the value and chevron animate.
private struct TVSelectorSegmentLabel: View {
    let icon: String
    let fullValue: String
    let compactValue: String
    let isExpanded: Bool
    let showsChevron: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .frame(width: 30, height: 28, alignment: .center)
            Text(isExpanded ? fullValue : compactValue)
                .font(.system(size: 20, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.opacity)
            if showsChevron && isExpanded {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(0.78)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, isExpanded ? 14 : 12)
        .frame(height: 46)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: isExpanded
        )
    }
}

private struct TVSelectorSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVSelectorSegmentButtonBody(configuration: configuration)
    }
}

private struct TVSelectorSegmentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(isFocused ? .black : .white)
            .background(
                Capsule().fill(isFocused ? Color.white : Color.clear)
            )
            .overlay {
                if isFocused {
                    Capsule()
                        .stroke(Color.white.opacity(0.95), lineWidth: 2.5)
                        .padding(-3)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.02 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.24 : 0), radius: 8, y: 3)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }
}
#endif
