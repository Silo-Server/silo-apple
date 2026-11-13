#if !os(tvOS)
import SwiftUI

struct DownloadRequestOptions {
    let fileId: Int?
    let quality: String

    /// The file a download pins: the version the detail screen displays.
    /// Auto resolves the way the version selector shows it (the best file
    /// for the quality preference in the current edition), so the saved
    /// file and the sidecar subtitles that travel with it match what the
    /// user saw. Leaving Auto to the server let it pick its own default, a
    /// different file. Nil only when the item has no version metadata.
    static func fileId(
        versions: [FileVersion],
        selectedFileId: Int?,
        lastFileId: Int?,
        preferredQualityId: String?,
        editionId: String? = nil,
        lastEditionKey: String? = nil
    ) -> Int? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: selectedFileId,
            lastFileId: lastFileId,
            preferredQualityId: preferredQualityId,
            editionId: editionId,
            lastEditionKey: lastEditionKey
        )?.fileId
    }
}

struct DownloadOptionsSheet: View {
    let title: String
    let versions: [FileVersion]
    let lastVersionFileId: Int?
    let lastEditionKey: String?
    let onStart: (DownloadRequestOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var fileId: Int?
    /// The edition picked here or on the page; Auto stays within it.
    @State private var editionId: String?
    @State private var quality: String
    /// Free space for the size warning, read once in `.task` rather than on
    /// every render.
    @State private var availableBytes: Int64 = 0

    init(
        title: String,
        versions: [FileVersion],
        selectedVersionFileId: Int?,
        selectedEditionId: String?,
        lastVersionFileId: Int?,
        lastEditionKey: String?,
        onStart: @escaping (DownloadRequestOptions) -> Void
    ) {
        self.title = title
        self.versions = versions
        self.lastVersionFileId = lastVersionFileId
        self.lastEditionKey = lastEditionKey
        self.onStart = onStart

        _fileId = State(initialValue: selectedVersionFileId)
        // The cut the sheet opens on stays its cut: without one, Auto would
        // re-rank across editions if the connection's quality changed.
        let opening = DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: selectedVersionFileId,
            lastFileId: lastVersionFileId,
            preferredQualityId: PlayerSettings.shared.connectionPreferredQuality,
            editionId: selectedEditionId,
            lastEditionKey: lastEditionKey
        )
        _editionId = State(
            initialValue: selectedEditionId ?? PlaybackEditions.edition(forFileId: opening?.fileId, in: versions)?.id
        )
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
        resolvedVersion(fileId: fileId)
    }

    private func resolvedVersion(fileId: Int?) -> FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: fileId,
            lastFileId: lastVersionFileId,
            preferredQualityId: PlayerSettings.shared.connectionPreferredQuality,
            editionId: editionId,
            lastEditionKey: lastEditionKey
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
                    Text(.downloadsOptionsSummaryHeader)
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
            .navigationTitle(Text(.downloadsOptionsTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .siloScrollContentBackgroundHidden()
            .siloSheetBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.audiobookDetailDownload) {
                        // Auto sends the version this sheet summarizes, not
                        // nil, so the server can't substitute another file.
                        onStart(DownloadRequestOptions(fileId: effectiveVersion?.fileId, quality: quality))
                        dismiss()
                    }
                }
            }
            .onAppear(perform: clampQuality)
            .task {
                availableBytes = DownloadFilePaths.availableCapacity()
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
                .foregroundColor(.siloOnSurface)
                .lineLimit(2)
            Text(summaryDetail)
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var summaryDetail: String {
        let qualityLabel = DownloadFormat(rawValue: quality).map(label(for:)) ?? quality
        let versionLabel = effectiveVersion.map(DetailPlaybackFormatting.versionPrimaryText)
            ?? AppLanguage.string(fileId == nil ? .downloadsOptionsAutoVersion : .downloadsOptionsSelectedVersion, locale: locale)
        var parts = [versionLabel, qualityLabel]
        if let estimate = selectionEstimate {
            parts.append(estimate.sizeLabel)
        }
        return parts.joined(separator: " · ")
    }

    /// Exact size of the file the current selection downloads; Auto
    /// resolves to a concrete version before the request is sent.
    private var selectionEstimate: DownloadSizeEstimate? {
        DownloadSizeEstimate.estimate(versions: versions, fileId: effectiveVersion?.fileId)
    }

    /// Over-threshold / insufficient-space caveat for the current selection,
    /// mirroring the one-tap confirmation so switching versions in the sheet
    /// keeps the warning honest.
    private var selectionSizeWarning: String? {
        selectionEstimate?.warningMessage(availableBytes: availableBytes)
    }

    private var editionSection: some View {
        Section {
            ForEach(editions) { edition in
                optionButton(
                    title: edition.label,
                    detail: AppLanguage.string(
                        .downloadsOptionsVersionCount(count: edition.versions.count, LocaleFormat.integer(edition.versions.count)),
                        locale: locale
                    ),
                    isSelected: currentEdition?.id == edition.id
                ) {
                    editionId = edition.id
                    fileId = nil
                }
            }
        } header: {
            Text(.downloadsOptionsEdition)
        }
    }

    private var versionSection: some View {
        Section {
            optionButton(
                title: AppLanguage.string(.playerVersionsAuto, locale: locale),
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
            Text(.detailVersion)
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
        return AppLanguage.string(.downloadsOptionsFileFallback("\(version.fileId)"), locale: locale)
    }

    /// Names the version Auto resolves to, the one the detail screen shows,
    /// so choosing Auto never hides which file will be saved.
    private var autoVersionDetail: String {
        guard let autoVersion = resolvedVersion(fileId: nil) else {
            return AppLanguage.string(.downloadsOptionsServerChooses, locale: locale)
        }
        let label = DetailPlaybackFormatting.versionPrimaryText(autoVersion)
        guard let estimate = DownloadSizeEstimate.estimate(versions: versions, fileId: autoVersion.fileId) else {
            return label
        }
        return "\(label) · \(estimate.sizeLabel)"
    }

    private var qualitySection: some View {
        Section {
            if formats.count > 1 {
                ForEach(formats, id: \.self) { format in
                    optionButton(
                        title: label(for: format),
                        detail: qualityDetail(for: format),
                        isSelected: quality == format.rawValue
                    ) {
                        quality = format.rawValue
                    }
                }
            } else {
                optionButton(
                    title: label(for: formats.first ?? .original),
                    detail: qualityDetail(for: formats.first ?? .original),
                    isSelected: true,
                    isEnabled: false
                ) {}
            }
        } header: {
            Text(.optionsQuality)
        } footer: {
            Text(.downloadsOptionsQualityFooter)
        }
    }

    private func label(for format: DownloadFormat) -> String {
        manager.capability?.label(for: format) ?? format.displayName
    }

    private func qualityDetail(for format: DownloadFormat) -> String {
        switch format {
        case .original:
            return AppLanguage.string(.downloadsOptionsQualityOriginalDetail, locale: locale)
        case .twentyMbps, .tenMbps, .fiveMbps, .twoMbps, .oneMbps:
            return AppLanguage.string(.downloadsOptionsQualityPreparedDetail, locale: locale)
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
                    title: .playerTracksAudio,
                    detail: DetailPlaybackFormatting.audioValueLabel(
                        version: effectiveVersion,
                        selectedAudioTrackIndex: nil
                    )
                )
                readOnlyRow(
                    title: .playerTracksSubtitles,
                    detail: subtitleSummary(for: effectiveVersion)
                )
            } else {
                readOnlyRow(
                    title: .playerTracksAudio,
                    detail: AppLanguage.string(.downloadsOptionsAudioFileDefault, locale: locale)
                )
                readOnlyRow(
                    title: .playerTracksSubtitles,
                    detail: AppLanguage.string(.downloadsOptionsSubtitlesAvailable, locale: locale)
                )
            }
        } header: {
            Text(.downloadsOptionsIncludedMedia)
        } footer: {
            Text(.downloadsOptionsIncludedMediaFooter)
        }
    }

    /// Capped at three languages — a file with dozens of tracks would
    /// otherwise render a wall of language names in one row.
    private static let subtitleLanguageDisplayCap = 3

    private func subtitleSummary(for version: FileVersion) -> String {
        let tracks = version.subtitleTracks ?? []
        guard !tracks.isEmpty else { return AppLanguage.string(.detailNone, locale: locale) }
        let languages = tracks
            .compactMap { languageDisplayName($0.language) }
            .uniqued()
        if languages.isEmpty {
            return AppLanguage.string(.downloadsOptionsTrackCount(count: tracks.count, LocaleFormat.integer(tracks.count, locale: locale)), locale: locale)
        }
        let shown = languages.prefix(Self.subtitleLanguageDisplayCap).joined(separator: ", ")
        let remainder = languages.count - Self.subtitleLanguageDisplayCap
        guard remainder > 0 else { return shown }
        return AppLanguage.string(.downloadsOptionsLanguagesMore(count: remainder, shown, LocaleFormat.integer(remainder, locale: locale)), locale: locale)
    }

    private func languageDisplayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.count <= 3 {
            return locale.localizedString(forLanguageCode: value.lowercased()) ?? value.uppercased()
        }
        return value
    }

    private func readOnlyRow(title: LocalizedStringResource, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(detail)
                .foregroundColor(.siloSecondaryText)
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
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.siloCaption)
                            .foregroundColor(.siloSecondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.siloOnSurface)
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
