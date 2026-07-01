#if !os(tvOS)
import SwiftUI

struct DownloadRequestOptions: Hashable {
    let fileId: Int?
    let quality: String
}

struct DownloadOptionsSheet: View {
    let title: String
    let versions: [FileVersion]
    let selectedVersionFileId: Int?
    let lastVersionFileId: Int?
    let onStart: (DownloadRequestOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var fileId: Int?
    @State private var quality: String

    init(
        title: String,
        versions: [FileVersion],
        selectedVersionFileId: Int?,
        lastVersionFileId: Int?,
        onStart: @escaping (DownloadRequestOptions) -> Void
    ) {
        self.title = title
        self.versions = versions
        self.selectedVersionFileId = selectedVersionFileId
        self.lastVersionFileId = lastVersionFileId
        self.onStart = onStart

        _fileId = State(initialValue: selectedVersionFileId)
        _quality = State(initialValue: DownloadSettings.shared.preferredFormat)
    }

    private var formats: [DownloadFormat] {
        let available = manager.availableFormats
        return available.isEmpty ? [.original] : available
    }

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    private var effectiveVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: fileId,
            lastFileId: lastVersionFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(
            versions: versions,
            currentVersion: effectiveVersion
        )
    }

    private var scopedVersions: [FileVersion] {
        if editions.count > 1, let currentEdition {
            return currentEdition.versions
        }
        return versions
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    summaryRow
                } header: {
                    Text("Download")
                }

                if editions.count > 1 {
                    editionSection
                }

                if !versions.isEmpty {
                    versionSection
                }

                qualitySection
                mediaSummarySection
            }
            .navigationTitle("Download Options")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .continuumScrollContentBackgroundHidden()
            .background(Color.continuumBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onStart(DownloadRequestOptions(fileId: fileId, quality: quality))
                        dismiss()
                    }
                }
            }
            .onAppear(perform: clampQuality)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.continuumOnSurface)
                .lineLimit(2)
            Text(summaryDetail)
                .font(.continuumCaption)
                .foregroundColor(.continuumSecondaryText)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var summaryDetail: String {
        let qualityLabel = DownloadFormat(rawValue: quality)?.displayName ?? quality
        let versionLabel = fileId == nil
            ? "Auto version"
            : (effectiveVersion.map(DetailPlaybackFormatting.versionPrimaryText) ?? "Selected version")
        return "\(versionLabel) · \(qualityLabel)"
    }

    private var editionSection: some View {
        Section("Edition") {
            ForEach(editions) { edition in
                optionButton(
                    title: edition.label,
                    detail: "\(edition.versions.count) version\(edition.versions.count == 1 ? "" : "s")",
                    isSelected: currentEdition?.id == edition.id
                ) {
                    let best = DetailVersionSelection.displayVersion(
                        versions: edition.versions,
                        selectedFileId: nil,
                        lastFileId: lastVersionFileId,
                        preferredQualityId: PlayerSettings.shared.preferredQuality
                    )
                    fileId = best?.fileId
                }
            }
        }
    }

    private var versionSection: some View {
        Section("Version") {
            optionButton(
                title: "Auto",
                detail: "Let the server choose the file",
                isSelected: fileId == nil
            ) {
                fileId = nil
            }
            ForEach(scopedVersions) { version in
                optionButton(
                    title: DetailPlaybackFormatting.versionPrimaryText(version),
                    detail: DetailPlaybackFormatting.versionSecondaryText(version),
                    isSelected: fileId == version.fileId
                ) {
                    fileId = version.fileId
                }
            }
        }
    }

    private var qualitySection: some View {
        Section {
            if formats.count > 1 {
                ForEach(formats, id: \.self) { format in
                    optionButton(
                        title: format.displayName,
                        detail: qualityDetail(for: format),
                        isSelected: quality == format.rawValue
                    ) {
                        quality = format.rawValue
                    }
                }
            } else {
                optionButton(
                    title: formats.first?.displayName ?? DownloadFormat.original.displayName,
                    detail: qualityDetail(for: formats.first ?? .original),
                    isSelected: true,
                    isEnabled: false
                ) {}
            }
        } header: {
            Text("Quality")
        } footer: {
            Text("This starts from your global Downloads default. Changing it here applies only to this download.")
        }
    }

    private func qualityDetail(for format: DownloadFormat) -> String {
        switch format {
        case .original:
            return "Source quality, with compatibility fallback if needed"
        case .twentyMbps, .tenMbps, .fiveMbps, .twoMbps, .oneMbps:
            return "Prepared server-side before transfer"
        }
    }

    private func clampQuality() {
        guard !formats.contains(where: { $0.rawValue == quality }) else { return }
        quality = DownloadSettings.shared.resolvedFormat(
            allowedFormats: manager.capability?.qualityPresets ?? []
        )
    }

    private var mediaSummarySection: some View {
        Section {
            if let effectiveVersion {
                readOnlyRow(
                    title: "Audio",
                    detail: DetailPlaybackFormatting.audioValueLabel(
                        version: effectiveVersion,
                        selectedAudioTrackIndex: nil
                    )
                )
                readOnlyRow(
                    title: "Subtitles",
                    detail: subtitleSummary(for: effectiveVersion)
                )
            } else {
                readOnlyRow(title: "Audio", detail: "File default")
                readOnlyRow(title: "Subtitles", detail: "Available tracks")
            }
        } header: {
            Text("Included Media")
        } footer: {
            Text("Audio and subtitle selection is resolved by the server for the selected file. Available subtitle files are cached for offline playback.")
        }
    }

    private func subtitleSummary(for version: FileVersion) -> String {
        let tracks = version.subtitleTracks ?? []
        guard !tracks.isEmpty else { return "None advertised" }
        let languages = tracks
            .compactMap { languageDisplayName($0.language) }
            .uniqued()
        if languages.isEmpty {
            return "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
        }
        return languages.joined(separator: ", ")
    }

    private func languageDisplayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.count <= 3 {
            let locale = Locale.current
            return locale.localizedString(forLanguageCode: value.lowercased()) ?? value.uppercased()
        }
        return value
    }

    private func readOnlyRow(title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(detail)
                .foregroundColor(.continuumSecondaryText)
                .multilineTextAlignment(.trailing)
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
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
#endif
