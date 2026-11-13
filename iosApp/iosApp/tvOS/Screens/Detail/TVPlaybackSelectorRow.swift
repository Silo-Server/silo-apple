#if os(tvOS)
import SwiftUI

/// Playback controls for the hero action row. Each trigger opens a lightweight
/// popover with native focusable options and restores focus after selection.
struct TVPlaybackActionSelectors: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    var subtitleMode: String? = nil
    var subtitleSignature: SubtitleTrackSignature? = nil
    var showForcedSubtitles = false
    /// Read live from `ProfilePrefsStore` by the parent page.
    let preferredSubtitleLanguage: String?
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    /// The action row's focus binding, so the row can return to the selector
    /// the viewer left.
    let focusedAction: FocusState<TVDetailAction?>.Binding

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 18) {
            if showsEditions {
                editionMenu
                    .focused(focusedAction, equals: .edition)
            }
            versionMenu
                .focused(focusedAction, equals: .version)
            audioMenu
                .focused(focusedAction, equals: .audio)
            subtitleMenu
                .focused(focusedAction, equals: .subtitles)
        }
        .preference(key: TVDisabledDetailActionsKey.self, value: disabledActions)
        // The parent observes the store, so hydration repaints it.
        .task { await ProfilePrefsStore.shared.hydrateIfNeeded() }
    }

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    /// Edition appears only when the title has more than one, as on iPhone.
    private var showsEditions: Bool { editions.count > 1 }

    private var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(versions: versions, currentVersion: currentVersion)
    }

    /// The current edition's files when editions show, else every file.
    private var scopedVersions: [FileVersion] {
        DetailPlaybackFormatting.versionSelectorVersions(versions: versions, currentVersion: currentVersion)
    }

    /// The file Auto would pick within `edition`. Choosing an edition pins
    /// it, turning Auto off; Auto in Versions chooses across every edition.
    private func preferredVersion(in edition: PlaybackEditions.Edition) -> FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: edition.versions,
            selectedFileId: nil,
            lastFileId: nil,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private var isEditionDisabled: Bool { currentVersion == nil || !showsEditions }
    private var isVersionDisabled: Bool { currentVersion == nil || scopedVersions.isEmpty }
    private var isAudioDisabled: Bool { currentVersion == nil || audioOptions.isEmpty }
    private var isSubtitleDisabled: Bool { currentVersion == nil }

    /// Includes Edition while it is unmounted, so the row never returns
    /// focus to a button that is gone.
    private var disabledActions: Set<TVDetailAction> {
        var actions: Set<TVDetailAction> = []
        if isEditionDisabled { actions.insert(.edition) }
        if isVersionDisabled { actions.insert(.version) }
        if isAudioDisabled { actions.insert(.audio) }
        if isSubtitleDisabled { actions.insert(.subtitles) }
        return actions
    }

    private var editionMenu: some View {
        TVCircleMenuButton(
            icon: "rectangle.stack",
            title: AppLanguage.string(.detailEdition, locale: locale),
            accessibilityLabel: AppLanguage.string(.detailEditionSpoken(editionValue), locale: locale),
            stabilizesFocusMotion: true,
            menuTitle: AppLanguage.string(.detailEdition, locale: locale),
            items: {
                editions.map { edition in
                    TVActionPopoverItem(
                        id: "edition-\(edition.id)",
                        title: PlaybackEditions.displayLabel(edition.label, locale: locale),
                        detail: AppLanguage.string(
                            .detailEditionVersionCount(edition.versions.count),
                            locale: locale
                        ),
                        isSelected: currentEdition?.id == edition.id
                    )
                }
            },
            onSelect: { item in
                let id = String(item.id.dropFirst("edition-".count))
                guard let edition = editions.first(where: { $0.id == id }),
                      let version = preferredVersion(in: edition) else { return }
                onSelectVersion(version.fileId)
            }
        )
        .disabled(isEditionDisabled)
    }

    private var versionMenu: some View {
        TVCircleMenuButton(
            icon: "4k.tv",
            title: AppLanguage.string(.detailVersionsButton, locale: locale),
            accessibilityLabel: AppLanguage.string(.detailVersionSpoken(versionValue), locale: locale),
            stabilizesFocusMotion: true,
            menuTitle: AppLanguage.string(.detailVersion, locale: locale),
            items: {
                [
                    TVActionPopoverItem(
                        id: "auto",
                        title: AppLanguage.string(.detailAuto, locale: locale),
                        detail: AppLanguage.string(.detailAutoVersion, locale: locale),
                        isSelected: selectedVersionFileId == nil
                    )
                ] + scopedVersions.map { version in
                    TVActionPopoverItem(
                        id: "file-\(version.fileId)",
                        title: DetailPlaybackFormatting.versionShortLabel(version),
                        detail: DetailPlaybackFormatting.versionDetailLabel(version),
                        isSelected: selectedVersionFileId == version.fileId
                    )
                }
            },
            onSelect: { item in
                if item.id == "auto" {
                    onSelectVersion(nil)
                } else if let fileId = Int(item.id.dropFirst("file-".count)) {
                    onSelectVersion(fileId)
                }
            }
        )
        .disabled(isVersionDisabled)
    }

    private var audioMenu: some View {
        TVCircleMenuButton(
            icon: "speaker.wave.2",
            title: AppLanguage.string(.detailAudioButton, locale: locale),
            accessibilityLabel: AppLanguage.string(.detailAudioSpoken(audioValue), locale: locale),
            stabilizesFocusMotion: true,
            menuTitle: AppLanguage.string(.detailAudio, locale: locale),
            items: {
                [
                    TVActionPopoverItem(
                        id: "auto",
                        title: AppLanguage.string(.detailAuto, locale: locale),
                        detail: AppLanguage.string(.detailAutoAudio, locale: locale),
                        isSelected: selectedAudioTrackIndex == nil
                    )
                ] + audioOptions.map { option in
                    TVActionPopoverItem(
                        id: "track-\(option.ordinal)",
                        title: option.title,
                        detail: option.detail,
                        isSelected: option.isSelected
                    )
                }
            },
            onSelect: { item in
                if item.id == "auto" {
                    onSelectAudioTrack(nil)
                } else if let ordinal = Int(item.id.dropFirst("track-".count)) {
                    onSelectAudioTrack(ordinal)
                }
            }
        )
        .disabled(isAudioDisabled)
    }

    private var subtitleMenu: some View {
        TVCircleMenuButton(
            icon: "captions.bubble",
            title: AppLanguage.string(.detailSubtitles, locale: locale),
            accessibilityLabel: AppLanguage.string(.detailSubtitlesSpoken(subtitleValue), locale: locale),
            stabilizesFocusMotion: true,
            menuTitle: AppLanguage.string(.detailSubtitles, locale: locale),
            items: {
                [
                    TVActionPopoverItem(
                        id: "auto",
                        title: AppLanguage.string(.detailAuto, locale: locale),
                        detail: AppLanguage.string(.detailAutoSubtitles, locale: locale),
                        isSelected: selectedSubtitleTrackIndex == nil
                    ),
                    TVActionPopoverItem(
                        id: "off",
                        title: AppLanguage.string(.detailOff, locale: locale),
                        detail: AppLanguage.string(.detailOffDetail, locale: locale),
                        isSelected: selectedSubtitleTrackIndex == -1
                    ),
                ] + subtitleOptions.map { option in
                    TVActionPopoverItem(
                        id: "sub-\(option.stableId)",
                        title: option.title,
                        detail: option.detail,
                        isSelected: option.isSelected,
                        isEnabled: option.isSelectable && option.selectionIndex != nil
                    )
                }
            },
            onSelect: { item in
                switch item.id {
                case "auto":
                    onSelectSubtitleTrack(nil)
                case "off":
                    onSelectSubtitleTrack(-1)
                default:
                    let stableId = String(item.id.dropFirst("sub-".count))
                    if let option = subtitleOptions.first(where: { $0.stableId == stableId }),
                       let selectionIndex = option.selectionIndex {
                        onSelectSubtitleTrack(selectionIndex)
                    }
                }
            }
        )
        .disabled(isSubtitleDisabled)
    }

    private var editionValue: String {
        PlaybackEditions.displayLabel(
            currentEdition?.label ?? currentVersion?.editionDisplayLabel ?? PlaybackEditions.standardLabel,
            locale: locale
        )
    }

    private var versionValue: String {
        let value = DetailPlaybackFormatting.versionCompactLabel(currentVersion)
        return selectedVersionFileId == nil
            ? AppLanguage.string(.detailAutoSpoken(value), locale: locale)
            : value
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
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            preferredLanguage: preferredSubtitleLanguage,
            mode: subtitleMode,
            signature: subtitleSignature,
            showForced: showForcedSubtitles
        )
    }
}

/// Passive readout of the selected version, audio, and subtitles beside the
/// circular menus; adds no focus target.
struct TVPlaybackSelectionSummary: Equatable {
    let version: String?
    let audio: String?
    let subtitles: String?

    /// Built in the parent view's body; pass the view's `\.locale` so the
    /// readout follows the app language.
    static func make(
        currentVersion: FileVersion?,
        selectedVersionFileId: Int?,
        selectedAudioTrackIndex: Int?,
        selectedSubtitleTrackIndex: Int?,
        subtitleMode: String?,
        subtitleSignature: SubtitleTrackSignature?,
        preferredSubtitleLanguage: String?,
        showForcedSubtitles: Bool,
        locale: Locale = AppLanguage.displayedLocale
    ) -> TVPlaybackSelectionSummary {
        guard let currentVersion else {
            return TVPlaybackSelectionSummary(
                version: nil,
                audio: nil,
                subtitles: nil
            )
        }
        func autoValue(_ value: String) -> String {
            AppLanguage.string(.detailAutoValue(value), locale: locale)
        }

        let versionDetail = DetailPlaybackFormatting.versionCompactLabel(currentVersion)
        let version = selectedVersionFileId == nil
            && !DetailPlaybackFormatting.versionCompactTokens(currentVersion).isEmpty
            ? autoValue(versionDetail)
            : versionDetail

        let resolvedAudio = DetailPlaybackFormatting.audioValueLabel(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            annotateAuto: false
        )
        let audio = selectedAudioTrackIndex == nil
            ? autoValue(resolvedAudio)
            : resolvedAudio

        let autoContext = DetailPlaybackFormatting.SubtitleAutoContext(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            preferredLanguage: preferredSubtitleLanguage,
            mode: subtitleMode,
            signature: subtitleSignature,
            showForced: showForcedSubtitles
        )
        let subtitle: String
        if selectedSubtitleTrackIndex == nil {
            // Auto shows what it resolves to, or None when that is Off.
            subtitle = autoValue(
                DetailPlaybackFormatting.autoSubtitlePreview(version: currentVersion, context: autoContext)
                    ?? AppLanguage.string(.detailNone, locale: locale)
            )
        } else {
            subtitle = DetailPlaybackFormatting.subtitleValueLabel(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                autoContext: autoContext
            )
        }

        return TVPlaybackSelectionSummary(
            version: version,
            audio: audio,
            subtitles: subtitle
        )
    }
}

#endif
