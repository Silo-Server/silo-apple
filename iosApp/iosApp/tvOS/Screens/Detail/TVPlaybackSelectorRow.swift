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
            icon: "square.stack",
            title: "Versions",
            accessibilityLabel: "Version, \(versionValue)",
            stabilizesFocusMotion: true,
            menuTitle: "Version",
            items: {
                [
                    TVActionPopoverItem(
                        id: "auto",
                        title: "Auto",
                        detail: "Best match for this device",
                        isSelected: selectedVersionFileId == nil
                    )
                ] + versions.map { version in
                    TVActionPopoverItem(
                        id: "file-\(version.fileId)",
                        title: DetailPlaybackFormatting.versionShortLabel(version),
                        detail: versionDetail(version),
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
        .disabled(currentVersion == nil || versions.isEmpty)
    }

    private var audioMenu: some View {
        TVCircleMenuButton(
            icon: "speaker.wave.2",
            title: "Audio Tracks",
            accessibilityLabel: "Audio, \(audioValue)",
            stabilizesFocusMotion: true,
            menuTitle: "Audio",
            items: {
                [
                    TVActionPopoverItem(
                        id: "auto",
                        title: "Auto",
                        detail: "Use your Playback audio preference",
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
        .disabled(currentVersion == nil || audioOptions.isEmpty)
    }

    private var subtitleMenu: some View {
        TVCircleMenuButton(
            icon: "captions.bubble",
            title: "Subtitles",
            accessibilityLabel: "Subtitles, \(subtitleValue)",
            stabilizesFocusMotion: true,
            menuTitle: "Subtitles",
            items: {
                [
                    TVActionPopoverItem(
                        id: "auto",
                        title: "Auto",
                        detail: "Use your subtitle preferences",
                        isSelected: selectedSubtitleTrackIndex == nil
                    ),
                    TVActionPopoverItem(
                        id: "off",
                        title: "Off",
                        detail: "Start without subtitles",
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
#endif
