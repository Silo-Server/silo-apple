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
#endif
