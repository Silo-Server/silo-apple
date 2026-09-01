#if os(tvOS)
import SwiftUI

/// Android-parity playback controls for the hero action row. Each choice is a
/// native tvOS `Menu`, so the focus engine owns lateral movement and returns
/// focus to the same circular trigger after a selection.
struct TVPlaybackActionSelectors: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    var subtitleMode: String? = nil
    var subtitleSignature: SubtitleTrackSignature? = nil
    var showForcedSubtitles = false
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    @State private var preferredSubtitleLanguage: String?

    var body: some View {
        HStack(spacing: 18) {
            versionMenu
            audioMenu
            subtitleMenu
        }
        .task {
            await ProfilePrefsStore.shared.hydrateIfNeeded()
            preferredSubtitleLanguage = ProfilePrefsStore.shared.preferredSubtitleLanguage
        }
    }

    private var versionMenu: some View {
        TVCircleMenuButton(
            icon: "movieclapper",
            accessibilityLabel: "Version, \(versionValue)",
            stabilizesFocusMotion: true
        ) {
            Button { onSelectVersion(nil) } label: {
                menuItem(
                    title: "Auto",
                    detail: "Best match for this device",
                    isSelected: selectedVersionFileId == nil
                )
            }
            ForEach(versions) { version in
                Button { onSelectVersion(version.fileId) } label: {
                    menuItem(
                        title: DetailPlaybackFormatting.versionShortLabel(version),
                        detail: versionDetail(version),
                        isSelected: selectedVersionFileId == version.fileId
                    )
                }
            }
        }
        .disabled(currentVersion == nil || versions.isEmpty)
    }

    private var audioMenu: some View {
        TVCircleMenuButton(
            icon: "speaker.wave.2",
            accessibilityLabel: "Audio, \(audioValue)",
            stabilizesFocusMotion: true
        ) {
            Button { onSelectAudioTrack(nil) } label: {
                menuItem(
                    title: "Auto",
                    detail: "Use your Playback audio preference",
                    isSelected: selectedAudioTrackIndex == nil
                )
            }
            ForEach(audioOptions) { option in
                Button { onSelectAudioTrack(option.ordinal) } label: {
                    menuItem(
                        title: option.title,
                        detail: option.detail,
                        isSelected: option.isSelected
                    )
                }
            }
        }
        .disabled(currentVersion == nil || audioOptions.isEmpty)
    }

    private var subtitleMenu: some View {
        TVCircleMenuButton(
            icon: "captions.bubble",
            accessibilityLabel: "Subtitles, \(subtitleValue)",
            stabilizesFocusMotion: true
        ) {
            Button { onSelectSubtitleTrack(nil) } label: {
                menuItem(
                    title: "Auto",
                    detail: "Use your subtitle preferences",
                    isSelected: selectedSubtitleTrackIndex == nil
                )
            }
            Button { onSelectSubtitleTrack(-1) } label: {
                menuItem(
                    title: "Off",
                    detail: "Start without subtitles",
                    isSelected: selectedSubtitleTrackIndex == -1
                )
            }
            ForEach(subtitleOptions) { option in
                if option.isSelectable, let selectionIndex = option.selectionIndex {
                    Button { onSelectSubtitleTrack(selectionIndex) } label: {
                        menuItem(
                            title: option.title,
                            detail: option.detail,
                            isSelected: option.isSelected
                        )
                    }
                } else {
                    Button { } label: {
                        menuItem(
                            title: option.title,
                            detail: option.detail,
                            isSelected: false
                        )
                    }
                    .disabled(true)
                }
            }
        }
        .disabled(currentVersion == nil)
    }

    private var versionValue: String {
        let value = DetailPlaybackFormatting.versionCompactLabel(currentVersion)
        return selectedVersionFileId == nil ? "Auto, \(value)" : value
    }

    private var audioValue: String {
        DetailPlaybackFormatting.audioValueLabel(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            annotateAuto: true
        )
    }

    private var subtitleValue: String {
        DetailPlaybackFormatting.subtitleValueLabel(
            version: currentVersion,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            autoContext: subtitleAutoContext
        )
    }

    private var audioOptions: [DetailPlaybackFormatting.AudioOption] {
        DetailPlaybackFormatting.audioOptions(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex
        )
    }

    private var subtitleOptions: [DetailPlaybackFormatting.SubtitleOption] {
        DetailPlaybackFormatting.subtitleOptions(
            version: currentVersion,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            preferredLanguage: preferredSubtitleLanguage
        )
    }

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

    private func versionDetail(_ version: FileVersion) -> String {
        DetailPlaybackFormatting.versionDetailLabel(version)
    }

    @ViewBuilder
    private func menuItem(title: String, detail: String, isSelected: Bool) -> some View {
        let label = detail.isEmpty ? title : "\(title) — \(detail)"
        if isSelected {
            Label(label, systemImage: "checkmark")
        } else {
            Text(label)
        }
    }
}

/// Compact passive disclosure paired with the circular action menus. This
/// preserves the selected values that used to live inside the lower selector
/// capsule without adding another focus destination.
struct TVPlaybackSelectionSummary: Equatable {
    let version: String?
    let audio: String?
    let subtitles: String?

    static func make(
        currentVersion: FileVersion?,
        selectedVersionFileId: Int?,
        selectedAudioTrackIndex: Int?,
        selectedSubtitleTrackIndex: Int?,
        subtitleMode: String?,
        subtitleSignature: SubtitleTrackSignature?,
        preferredSubtitleLanguage: String?,
        showForcedSubtitles: Bool
    ) -> TVPlaybackSelectionSummary {
        guard let currentVersion else {
            return TVPlaybackSelectionSummary(
                version: nil,
                audio: nil,
                subtitles: nil
            )
        }

        let versionDetail = DetailPlaybackFormatting.versionCompactLabel(currentVersion)
        let version = selectedVersionFileId == nil
            && versionDetail != "Auto"
            ? "Auto · \(versionDetail)"
            : versionDetail

        let resolvedAudio = DetailPlaybackFormatting.audioValueLabel(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            annotateAuto: false
        )
        let audio = selectedAudioTrackIndex == nil
            ? "Auto · \(resolvedAudio)"
            : resolvedAudio

        let autoContext = DetailPlaybackFormatting.SubtitleAutoContext(
            preferredLanguage: preferredSubtitleLanguage,
            mode: subtitleMode,
            signature: subtitleSignature,
            audioLanguage: DetailPlaybackFormatting.resolvedAudioLanguage(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            ),
            showForced: showForcedSubtitles
        )
        let resolvedSubtitle = DetailPlaybackFormatting.subtitleValueLabel(
            version: currentVersion,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            autoContext: autoContext
        )
        let subtitle = summarySubtitleValue(
            resolvedSubtitle,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex
        )

        return TVPlaybackSelectionSummary(
            version: version,
            audio: audio,
            subtitles: subtitle
        )
    }

    private static func summarySubtitleValue(
        _ value: String,
        selectedSubtitleTrackIndex: Int?
    ) -> String {
        guard selectedSubtitleTrackIndex == nil else { return value }
        let resolved = value.hasPrefix("Auto: ")
            ? String(value.dropFirst("Auto: ".count))
            : value
        return "Auto · \(resolved == "Off" ? "None" : resolved)"
    }
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
    /// Series overview treats the three playback choices as one visual zone:
    /// entering the row expands every segment once, lateral movement only
    /// moves the highlight, and leaving the row collapses everything once.
    /// Other detail pages retain their existing per-segment expansion.
    var expandsAsGroup: Bool = false
    /// Removes the small focus scale from the selected segment. The Series
    /// hero uses this with `expandsAsGroup` so its leading edge and overall
    /// geometry stay still while focus moves laterally.
    var stabilizesFocusMotion: Bool = false
    /// Places the variable-width capsule inside a stable leading-aligned
    /// region before its width animation runs. Series uses this so entering
    /// the row can only reveal new width at the trailing edge.
    var pinsLeadingEdgeOnExpansion: Bool = false
    /// Makes Version the entry target for the Series selector focus scope.
    /// Lateral movement inside the row remains native.
    var prefersVersionFocusOnEntry: Bool = false
    /// Non-zero changes explicitly hand focus from the composite Series
    /// episode carousel into the leading selector segment.
    var focusRequest = 0
    /// Series observes row-level focus so its vertical scroll choreography can
    /// use the same stable viewport as seasons and episodes.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Series owns its vertical focus chain explicitly so tvOS cannot process
    /// the same gesture again and bounce through an intermediate destination.
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
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
            managedSelectorRow
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
                .modifier(SelectorDefaultFocus(focus: selectorDefaultFocus, binding: $focusedSelector))
                .onChange(of: focusedSelector) { _, newValue in
                    onFocusChange?(newValue != nil)
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
                        defaultSelectorFocus = entrySelector
                    }
                }
                .onChange(of: focusRequest) { _, request in
                    guard request > 0 else { return }
                    let target = entrySelector
                    // Let the episode composite finish handling the remote
                    // command before transferring focus. This avoids rebuilding
                    // the selector's default-focus subtree mid-gesture.
                    Task { @MainActor in
                        await Task.yield()
                        focusedSelector = target
                    }
                }
                .task {
                    await ProfilePrefsStore.shared.hydrateIfNeeded()
                    preferredSubtitleLanguage = ProfilePrefsStore.shared.preferredSubtitleLanguage
                }
                .onDisappear {
                    onFocusChange?(false)
                }
        }
    }

    @ViewBuilder
    private var managedSelectorRow: some View {
        if onMoveUp != nil || onMoveDown != nil {
            selectorRow.onMoveCommand(perform: handleMoveCommand)
        } else {
            selectorRow
        }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            moveSelectorFocus(by: -1)
        case .right:
            moveSelectorFocus(by: 1)
        case .up:
            onMoveUp?()
        case .down:
            onMoveDown?()
        default:
            break
        }
    }

    private func moveSelectorFocus(by delta: Int) {
        let selectors = visibleSelectors
        guard let focusedSelector,
              let index = selectors.firstIndex(of: focusedSelector) else { return }
        let nextIndex = index + delta
        guard selectors.indices.contains(nextIndex) else { return }
        self.focusedSelector = selectors[nextIndex]
    }

    @ViewBuilder
    private var selectorRow: some View {
        if pinsLeadingEdgeOnExpansion {
            selectorCapsule
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            selectorCapsule
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0),
                    value: selectorExpansionKey
                )
        }
    }

    private var selectorCapsule: some View {
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
    }

    /// A stable key while focus moves between segments in grouped mode. This
    /// prevents SwiftUI from starting a fresh width animation on every D-pad
    /// click after the row has already expanded.
    private var selectorExpansionKey: SelectorFocus? {
        if expandsAsGroup {
            return focusedSelector == nil ? nil : firstSelector
        }
        return focusedSelector
    }

    private func isExpanded(_ selector: SelectorFocus) -> Bool {
        expandsAsGroup ? focusedSelector != nil : focusedSelector == selector
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

    private var visibleSelectors: [SelectorFocus] {
        var selectors: [SelectorFocus] = []
        if shouldShowEditionSelector { selectors.append(.edition) }
        if shouldShowVersionValue { selectors.append(.version) }
        if shouldShowAudioValue { selectors.append(.audio) }
        if shouldShowSubtitleValue { selectors.append(.subtitles) }
        return selectors
    }

    private var entrySelector: SelectorFocus {
        if prefersVersionFocusOnEntry, shouldShowVersionValue {
            return .version
        }
        return firstSelector
    }

    private var selectorDefaultFocus: SelectorFocus? {
        defaultSelectorFocus ?? (prefersVersionFocusOnEntry ? entrySelector : nil)
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
            isExpanded: isExpanded(.edition),
            stabilizesFocusMotion: stabilizesFocusMotion,
            pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
                isExpanded: isExpanded(.version),
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
                isExpanded: isExpanded(.version),
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
                isExpanded: isExpanded(.audio),
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
                isExpanded: isExpanded(.audio),
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
                isExpanded: isExpanded(.subtitles),
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
                isExpanded: isExpanded(.subtitles),
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
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
    let stabilizesFocusMotion: Bool
    let pinsLeadingEdgeOnExpansion: Bool
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
                showsChevron: true,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
            )
        }
        .menuStyle(.button)
        .buttonStyle(
            TVSelectorSegmentButtonStyle(
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
            )
        )
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
    let stabilizesFocusMotion: Bool
    let pinsLeadingEdgeOnExpansion: Bool

    var body: some View {
        Button { } label: {
            TVSelectorSegmentLabel(
                icon: icon,
                fullValue: fullValue,
                compactValue: compactValue,
                isExpanded: isExpanded,
                showsChevron: false,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
            )
        }
        .buttonStyle(
            TVSelectorSegmentButtonStyle(
                stabilizesFocusMotion: stabilizesFocusMotion,
                pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
            )
        )
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
    let pinsLeadingEdgeOnExpansion: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactTextWidth: CGFloat?
    @State private var fullTextWidth: CGFloat?

    @ViewBuilder
    var body: some View {
        if pinsLeadingEdgeOnExpansion {
            labelContent
        } else {
            labelContent
                .geometryGroup()
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0),
                    value: isExpanded
                )
        }
    }

    private var labelContent: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .frame(width: 30, height: 28, alignment: .center)

            valueRegion
        }
        // A fixed leading inset means expansion happens only at the trailing
        // edge; the icon never slides away from the page margin.
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background { textMeasurements }
    }

    @ViewBuilder
    private var valueRegion: some View {
        if pinsLeadingEdgeOnExpansion,
           let compactTextWidth,
           let fullTextWidth {
            measuredValueCanvas(
                compactTextWidth: compactTextWidth,
                fullTextWidth: fullTextWidth
            )
            .modifier(
                TVSelectorLeadingWidth(
                    width: isExpanded
                        ? fullTextWidth + (showsChevron ? 26 : 0)
                        : compactTextWidth
                )
            )
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0),
                value: isExpanded
            )
        } else {
            HStack(spacing: 8) {
                animatedValue
                selectorChevron
            }
            .frame(width: expandingValueWidth, alignment: .leading)
            .clipped()
        }
    }

    private func measuredValueCanvas(
        compactTextWidth: CGFloat,
        fullTextWidth: CGFloat
    ) -> some View {
        let expandedWidth = fullTextWidth + (showsChevron ? 26 : 0)
        return ZStack(alignment: .leading) {
            selectorText(compactValue)
                .opacity(isExpanded ? 0 : 1)
            selectorText(fullValue)
                .opacity(isExpanded ? 1 : 0)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(isExpanded ? 0.78 : 0)
                    .offset(x: fullTextWidth + 8)
            }
        }
        .frame(width: max(compactTextWidth, expandedWidth), alignment: .leading)
    }

    @ViewBuilder
    private var selectorChevron: some View {
        if showsChevron {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .opacity(isExpanded ? 0.78 : 0)
        }
    }

    @ViewBuilder
    private var animatedValue: some View {
        if let valueWidth = selectedTextWidth {
            ZStack(alignment: .leading) {
                selectorText(compactValue)
                    .opacity(isExpanded ? 0 : 1)
                selectorText(fullValue)
                    .opacity(isExpanded ? 1 : 0)
            }
            .frame(width: valueWidth, alignment: .leading)
            .clipped()
        } else {
            selectorText(isExpanded ? fullValue : compactValue)
        }
    }

    private var selectedTextWidth: CGFloat? {
        isExpanded ? fullTextWidth : compactTextWidth
    }

    private var expandingValueWidth: CGFloat? {
        guard let selectedTextWidth else { return nil }
        return selectedTextWidth + (showsChevron && isExpanded ? 26 : 0)
    }

    private func selectorText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 20, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var textMeasurements: some View {
        ZStack {
            selectorText(compactValue)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    compactTextWidth = width
                }
            selectorText(fullValue)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    fullTextWidth = width
                }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

private struct TVSelectorSegmentButtonStyle: ButtonStyle {
    var stabilizesFocusMotion = false
    var pinsLeadingEdgeOnExpansion = false

    func makeBody(configuration: Configuration) -> some View {
        TVSelectorSegmentButtonBody(
            configuration: configuration,
            stabilizesFocusMotion: stabilizesFocusMotion,
            pinsLeadingEdgeOnExpansion: pinsLeadingEdgeOnExpansion
        )
    }
}

private struct TVSelectorSegmentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let stabilizesFocusMotion: Bool
    let pinsLeadingEdgeOnExpansion: Bool
    @Environment(\.isFocused) private var isFocused

    @ViewBuilder
    var body: some View {
        if pinsLeadingEdgeOnExpansion {
            styledLabel
                // The width animator inside the label owns the focus-entry
                // transaction. Applying a second focus animation around the
                // whole button would interpolate its geometry from the center.
                .animation(
                    .easeOut(duration: ContinuumTheme.fastDuration),
                    value: configuration.isPressed
                )
        } else {
            styledLabel
                .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
                .animation(
                    .easeOut(duration: ContinuumTheme.fastDuration),
                    value: configuration.isPressed
                )
        }
    }

    private var styledLabel: some View {
        configuration.label
            .foregroundColor(isFocused ? .black : .white)
            .background(
                Capsule().fill(isFocused ? Color.white : Color.clear)
            )
            // Keep the new value masked to the capsule's animated bounds.
            // Without this mask, SwiftUI lays out the longer string at its
            // final width before the background's presentation catches up.
            .clipShape(Capsule())
            .overlay {
                if isFocused {
                    if pinsLeadingEdgeOnExpansion {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.95), lineWidth: 2.5)
                            .padding(
                                EdgeInsets(
                                    top: -3,
                                    leading: 0,
                                    bottom: -3,
                                    trailing: -3
                                )
                            )
                    } else {
                        Capsule()
                            .stroke(Color.white.opacity(0.95), lineWidth: 2.5)
                            .padding(-3)
                    }
                }
            }
            .scaleEffect(
                configuration.isPressed
                    ? 0.98
                    : (isFocused && !stabilizesFocusMotion ? 1.02 : 1)
            )
            .shadow(color: .black.opacity(isFocused ? 0.24 : 0), radius: 8, y: 3)
            .focusEffectDisabled()
    }
}

/// Interpolates the label's reported width on every animation frame while
/// keeping its content fixed to x=0. This avoids SwiftUI's intrinsic-size
/// interpolation moving the leading edge before the row grows to the right.
private struct TVSelectorLeadingWidth: AnimatableModifier {
    var width: CGFloat

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: width, alignment: .leading)
            .clipped()
    }
}

/// Fixed-height stand-in for a Series playback selector while an uncached
/// episode's full playback metadata is loading. Reserving the same capsule
/// footprint keeps the Play and season rows still during the request.
struct TVPlaybackSelectorPlaceholder: View {
    var body: some View {
        HStack(spacing: 0) {
            placeholderSegment(icon: "tv", width: 190)
            divider
            placeholderSegment(icon: "speaker.wave.2", width: 210)
            divider
            placeholderSegment(icon: "captions.bubble", width: 220)
        }
        .frame(height: 50)
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.26)))
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityHidden(true)
    }

    private func placeholderSegment(icon: String, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .frame(width: 30, height: 28)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.32))
                .frame(width: width - 70, height: 16)
        }
        .foregroundColor(.white.opacity(0.48))
        .frame(width: width, height: 46)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 34)
    }
}
#endif
