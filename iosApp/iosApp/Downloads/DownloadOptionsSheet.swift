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
            .continuumPageBackground()
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
            .task {
                // Permissions and server-side download settings can change at
                // any time; re-fetch so the quality list reflects them now
                // rather than after the next app foreground.
                await manager.refreshCapability()
                clampQuality()
            }
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
        var parts = [versionLabel, qualityLabel]
        if let estimate = selectionEstimate {
            parts.append(estimate.isRange ? "\(estimate.sizeLabel) depending on server choice" : estimate.sizeLabel)
        }
        return parts.joined(separator: " · ")
    }

    /// Size expectation for what the current selection would download:
    /// candidate range for Auto, exact size for a chosen version.
    private var selectionEstimate: DownloadSizeEstimate? {
        DownloadSizeEstimate.estimate(versions: versions, fileId: fileId)
    }

    /// Over-threshold / insufficient-space caveat for the current selection,
    /// mirroring the one-tap confirmation so switching versions in the sheet
    /// keeps the warning honest.
    private var selectionSizeWarning: String? {
        selectionEstimate?.warningMessage(
            availableBytes: DownloadFilePaths.deviceStorage().available
        )
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
        Section {
            optionButton(
                title: "Auto",
                detail: autoVersionDetail,
                isSelected: fileId == nil
            ) {
                fileId = nil
            }
            ForEach(versionRows, id: \.version.fileId) { row in
                optionButton(
                    title: row.title,
                    detail: row.detail,
                    isSelected: fileId == row.version.fileId
                ) {
                    fileId = row.version.fileId
                }
            }
        } header: {
            Text("Version")
        } footer: {
            if let selectionSizeWarning {
                Text(selectionSizeWarning)
                    .foregroundColor(.orange)
            }
        }
    }

    /// Version rows with a disambiguator appended when two distinct files
    /// would otherwise render identical primary/secondary text (same
    /// resolution/codec/size), so every row stays tellable-apart.
    private var versionRows: [(version: FileVersion, title: String, detail: String?)] {
        let rows = scopedVersions.map { version in
            (
                version: version,
                title: DetailPlaybackFormatting.versionPrimaryText(version),
                detail: DetailPlaybackFormatting.versionSecondaryText(version)
            )
        }
        var counts: [String: Int] = [:]
        for row in rows {
            counts["\(row.title)|\(row.detail ?? "")", default: 0] += 1
        }
        return rows.map { row in
            guard counts["\(row.title)|\(row.detail ?? "")", default: 0] > 1 else { return row }
            let detail = [row.detail, disambiguator(for: row.version)]
                .compactMap { $0 }
                .joined(separator: " · ")
            return (row.version, row.title, detail)
        }
    }

    /// Edition name when the file has one, else a filename fragment — just
    /// enough to tell apart two files whose technical summary reads the same.
    private func disambiguator(for version: FileVersion) -> String {
        let edition = version.editionDisplayLabel
        if edition != "Standard" { return edition }
        if let fragment = version.fileName?
            .components(separatedBy: "/").last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fragment.isEmpty {
            return fragment
        }
        return "File \(version.fileId)"
    }

    /// Auto spans every version the server might pick, so disclose the full
    /// candidate range rather than pretending the size is unknown.
    private var autoVersionDetail: String {
        guard let estimate = DownloadSizeEstimate.estimate(versions: versions, fileId: nil) else {
            return "Let the server choose the file"
        }
        if estimate.isRange {
            return "\(estimate.sizeLabel) depending on server choice"
        }
        return "\(estimate.sizeLabel) · Let the server choose the file"
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
            return "Prepared on the server before download starts"
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
            Text("Audio and subtitles are chosen automatically for the selected file. Available subtitles are saved for offline playback.")
        }
    }

    /// Capped at three languages — a file with dozens of tracks would
    /// otherwise render a wall of language names in one row.
    private static let subtitleLanguageDisplayCap = 3

    private func subtitleSummary(for version: FileVersion) -> String {
        let tracks = version.subtitleTracks ?? []
        guard !tracks.isEmpty else { return "None" }
        let languages = tracks
            .compactMap { languageDisplayName($0.language) }
            .uniqued()
        if languages.isEmpty {
            return "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
        }
        let shown = languages.prefix(Self.subtitleLanguageDisplayCap).joined(separator: ", ")
        let remainder = languages.count - Self.subtitleLanguageDisplayCap
        return remainder > 0 ? "\(shown) +\(remainder) more" : shown
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
