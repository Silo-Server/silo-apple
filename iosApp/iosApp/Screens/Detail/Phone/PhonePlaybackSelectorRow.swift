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

/// Opaque, low-cost placeholder for the common version/audio/subtitle card.
/// It deliberately mirrors `PhonePlaybackSelectorRow`'s three 44pt rows so an
/// episode change never removes or inserts vertical space while networking.
struct PhonePlaybackSelectorSkeleton: View {
    static let standardHeight: CGFloat = 133

    private let kinds: [PhonePlaybackSelectorKind] = [.version, .audio, .subtitles]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, 30)
                }

                HStack(spacing: 10) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.24))
                        .frame(width: 20, alignment: .leading)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: kind == .subtitles ? 64 : 50, height: 10)

                    Spacer(minLength: 12)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: skeletonValueWidth(for: kind), height: 10)
                }
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.standardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func skeletonValueWidth(for kind: PhonePlaybackSelectorKind) -> CGFloat {
        switch kind {
        case .version: return 126
        case .audio: return 102
        case .subtitles: return 42
        case .edition: return 82
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var activeSelector: PhonePlaybackSelectorKind?

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    var body: some View {
        if currentVersion != nil, !selectorKinds.isEmpty {
            #if os(iOS)
            if usesPopoverLayout {
                selectorCard
                    .popover(
                        item: $activeSelector,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) { kind in
                        selectorPresentation(for: kind)
                    }
            } else {
                selectorCard
                    .sheet(item: $activeSelector) { kind in
                        selectorPresentation(for: kind)
                    }
            }
            #else
            selectorCard
                .sheet(item: $activeSelector) { kind in
                    selectorPresentation(for: kind)
                }
            #endif
        }
    }

    private func selectorPresentation(
        for kind: PhonePlaybackSelectorKind
    ) -> PhonePlaybackSelectorSheet {
        PhonePlaybackSelectorSheet(
            kinds: [kind],
            versions: versions,
            currentVersion: currentVersion,
            selectedVersionFileId: selectedVersionFileId,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            usesPopoverLayout: usesPopoverLayout,
            onSelectVersion: onSelectVersion,
            onSelectAudioTrack: onSelectAudioTrack,
            onSelectSubtitleTrack: onSelectSubtitleTrack
        )
    }

    private var usesPopoverLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && verticalSizeClass == .regular
        #else
        false
        #endif
    }

    /// Settings-style rows: icon and label lead, value trails, chevron last.
    ///
    /// Replaced a two-column `LazyVGrid` that stranded the third selector
    /// alone in the leading column, so the common version / audio /
    /// subtitles case always read as a broken form. A horizontally
    /// scrollable chip strip was tried first and was worse: three chips need
    /// more width than a phone has, so subtitles fell off the edge entirely
    /// and the most-hunted control became the invisible one. Rows never
    /// truncate, never go ragged, and absorb a fourth edition picker by
    /// simply growing.
    private var selectorCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(selectorKinds.enumerated()), id: \.element.id) { index, kind in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 30)
                }

                selectorButton(kind) {
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(width: 20, alignment: .leading)

                        Text(kind.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))

                        Spacer(minLength: 12)

                        Text(value(for: kind))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if isInteractive(kind) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.35))
                        }
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }
    /// Wraps a layout's row/column in a button when that selector can
    /// actually be changed, and leaves it inert when it cannot.
    @ViewBuilder
    private func selectorButton<Content: View>(
        _ kind: PhonePlaybackSelectorKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isInteractive(kind) {
            Button { activeSelector = kind } label: { content() }
                .buttonStyle(.plain)
                .accessibilityLabel("\(kind.title), \(value(for: kind))")
        } else {
            content()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kind.title), \(value(for: kind))")
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
private struct PhonePlaybackSelectorSheet: View {
    /// One entry when opened from a single control, all of them when opened
    /// from the `.summary` row.
    let kinds: [PhonePlaybackSelectorKind]
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let usesPopoverLayout: Bool
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
            .navigationTitle(sheetTitle)
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
        #if os(iOS)
        // Regular-width iPad uses this view as an anchored popover instead
        // of forcing a phone detent into the split-view detail column.
        .frame(
            width: usesPopoverLayout ? 440 : nil,
            height: usesPopoverLayout ? 480 : nil
        )
        .presentationCompactAdaptation(.sheet)
        #endif
        #if !os(macOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var optionContent: some View {
        ForEach(kinds) { kind in
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
    }

    private var sheetTitle: String {
        kinds.count == 1 ? (kinds.first?.title ?? "Playback") : "Playback"
    }

    /// Section headers only earn their space when the sheet holds more than
    /// one selector; a single-selector sheet already says so in its title.
    @ViewBuilder
    private func sectionHeader(_ kind: PhonePlaybackSelectorKind) -> some View {
        if kinds.count > 1 {
            Text(kind.title)
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
        } header: {
            sectionHeader(.edition)
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
        } header: {
            sectionHeader(.version)
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
        } header: {
            sectionHeader(.audio)
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
        } header: {
            sectionHeader(.subtitles)
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
