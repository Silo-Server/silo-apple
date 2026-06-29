#if !os(tvOS)
import SwiftUI

enum PhonePlaybackSelectorKind: String, Identifiable {
    case edition
    case version
    case audio
    case subtitles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edition: return "Edition"
        case .version: return "Version"
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        }
    }

    var icon: String {
        switch self {
        case .edition: return "rectangle.stack"
        case .version: return "4k.tv"
        case .audio: return "speaker.wave.2"
        case .subtitles: return "captions.bubble"
        }
    }
}

struct PhonePlaybackSelectorRow: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    @State private var activeSelector: PhonePlaybackSelectorKind?

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        if currentVersion != nil, !selectorKinds.isEmpty {
            LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
                ForEach(selectorKinds) { kind in
                    PhonePlaybackSelectorPill(
                        kind: kind,
                        value: value(for: kind),
                        isInteractive: isInteractive(kind),
                        action: { activeSelector = kind }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .sheet(item: $activeSelector) { kind in
                PhonePlaybackSelectorSheet(
                    kind: kind,
                    versions: versions,
                    currentVersion: currentVersion,
                    selectedVersionFileId: selectedVersionFileId,
                    selectedAudioTrackIndex: selectedAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                    onSelectVersion: onSelectVersion,
                    onSelectAudioTrack: onSelectAudioTrack,
                    onSelectSubtitleTrack: onSelectSubtitleTrack
                )
            }
        }
    }

    private var selectorKinds: [PhonePlaybackSelectorKind] {
        var kinds: [PhonePlaybackSelectorKind] = []
        if shouldShowEditionSelector {
            kinds.append(.edition)
        }
        if shouldShowVersionValue {
            kinds.append(.version)
        }
        if shouldShowAudioValue {
            kinds.append(.audio)
        }
        if shouldShowSubtitleValue {
            kinds.append(.subtitles)
        }
        return kinds
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

    private func isInteractive(_ kind: PhonePlaybackSelectorKind) -> Bool {
        switch kind {
        case .edition:
            return shouldShowEditionSelector
        case .version:
            return shouldEnableVersionSelector
        case .audio:
            return shouldEnableAudioSelector
        case .subtitles:
            return shouldEnableSubtitleSelector
        }
    }

    private func value(for kind: PhonePlaybackSelectorKind) -> String {
        switch kind {
        case .edition:
            return DetailPlaybackFormatting.currentEdition(
                versions: versions,
                currentVersion: currentVersion
            )?.label ?? currentVersion?.editionDisplayLabel ?? "Standard"
        case .version:
            return DetailPlaybackFormatting.versionShortLabel(currentVersion)
        case .audio:
            return DetailPlaybackFormatting.audioValueLabel(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            )
        case .subtitles:
            return DetailPlaybackFormatting.subtitleValueLabel(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex
            )
        }
    }
}

private struct PhonePlaybackSelectorPill: View {
    let kind: PhonePlaybackSelectorKind
    let value: String
    let isInteractive: Bool
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if isInteractive {
            Button(action: action) {
                labelContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.title), \(value)")
        } else {
            labelContent(showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kind.title), \(value)")
        }
    }

    private func labelContent(showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 4)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.58))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
        )
    }
}

private struct PhonePlaybackSelectorSheet: View {
    let kind: PhonePlaybackSelectorKind
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preferredSubtitleLanguage: String?

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    private var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    var body: some View {
        NavigationStack {
            List {
                optionContent
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(Color.continuumBackground.ignoresSafeArea())
            .task {
                await ProfilePrefsStore.shared.hydrateIfNeeded()
                preferredSubtitleLanguage = ProfilePrefsStore.shared.preferredSubtitleLanguage
            }
            .navigationTitle(kind.title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem {
                    Button("Done") { dismiss() }
                        .tint(.continuumOnSurface)
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(.continuumOnSurface)
                }
                #endif
            }
        }
        #if !os(macOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var optionContent: some View {
        switch kind {
        case .edition:
            editionOptions
        case .version:
            versionOptions
        case .audio:
            audioOptions
        case .subtitles:
            subtitleOptions
        }
    }

    @ViewBuilder
    private var editionOptions: some View {
        Section {
            if editions.isEmpty {
                optionButton(title: "Standard", detail: nil, isSelected: true, isEnabled: false) {}
            } else {
                ForEach(editions) { edition in
                    optionButton(
                        title: edition.label,
                        detail: "\(edition.versions.count) version\(edition.versions.count == 1 ? "" : "s")",
                        isSelected: currentEdition?.id == edition.id
                    ) {
                        let best = DetailVersionSelection.displayVersion(
                            versions: edition.versions,
                            selectedFileId: nil,
                            lastFileId: nil,
                            preferredQualityId: PlayerSettings.shared.preferredQuality
                        )
                        onSelectVersion(best?.fileId)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var versionOptions: some View {
        Section {
            optionButton(
                title: "Auto",
                detail: "Best match for this device",
                isSelected: selectedVersionFileId == nil
            ) {
                onSelectVersion(nil)
                dismiss()
            }
            ForEach(scopedVersions) { version in
                optionButton(
                    title: DetailPlaybackFormatting.versionPrimaryText(version),
                    detail: DetailPlaybackFormatting.versionSecondaryText(version),
                    isSelected: selectedVersionFileId == version.fileId
                ) {
                    onSelectVersion(version.fileId)
                    dismiss()
                }
            }
        }
    }

    private var scopedVersions: [FileVersion] {
        DetailPlaybackFormatting.versionSelectorVersions(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    @ViewBuilder
    private var audioOptions: some View {
        Section {
            optionButton(
                title: "Auto",
                detail: "Use the file default track",
                isSelected: selectedAudioTrackIndex == nil
            ) {
                onSelectAudioTrack(nil)
                dismiss()
            }
            let options = DetailPlaybackFormatting.audioOptions(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            )
            if options.isEmpty {
                optionButton(title: "Unknown", detail: "No audio metadata", isSelected: false, isEnabled: false) {}
            } else {
                ForEach(options) { option in
                    optionButton(
                        title: option.title,
                        detail: option.detail,
                        isSelected: selectedAudioTrackIndex == option.ordinal
                    ) {
                        onSelectAudioTrack(option.ordinal)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleOptions: some View {
        Section {
            optionButton(
                title: "Auto",
                detail: "Use your subtitle preferences",
                isSelected: selectedSubtitleTrackIndex == nil
            ) {
                onSelectSubtitleTrack(nil)
                dismiss()
            }
            optionButton(
                title: "Off",
                detail: "Start without subtitles",
                isSelected: selectedSubtitleTrackIndex == -1
            ) {
                onSelectSubtitleTrack(-1)
                dismiss()
            }
            ForEach(DetailPlaybackFormatting.subtitleOptions(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                preferredLanguage: preferredSubtitleLanguage
            )) { option in
                optionButton(
                    title: option.title,
                    detail: option.detail,
                    isSelected: option.isSelected,
                    isEnabled: option.isSelectable
                ) {
                    if let selectionIndex = option.selectionIndex {
                        onSelectSubtitleTrack(selectionIndex)
                        dismiss()
                    }
                }
            }
        }
    }

    private func optionButton(
        title: String,
        detail: String?,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.continuumCaption)
                            .foregroundColor(.continuumSecondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.continuumOnSurface)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.56)
        .listRowBackground(Color.continuumSurfaceVariant)
    }
}
#endif
