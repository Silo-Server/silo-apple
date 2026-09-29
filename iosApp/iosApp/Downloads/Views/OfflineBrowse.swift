#if !os(tvOS)
import SwiftUI

// MARK: - Series browse

/// Offline series browse: a season/episode list scoped to downloaded
/// content, reachable from the Downloads Manager. Rendered entirely from
/// `DownloadManager.seriesGroups` + stored progress — no network.
struct OfflineSeriesBrowseView: View {
    let seriesId: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var selectedSeasonNumber: Int?

    private var group: DownloadSeriesGroup? {
        manager.seriesGroups.first { $0.seriesId == seriesId }
    }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                EmptyStateView(
                    icon: "tv",
                    title: "No Downloads",
                    subtitle: "This series has no downloaded episodes."
                )
            }
        }
        .siloPageBackground()
        .navigationTitle(group?.title ?? "Series")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let group {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            manager.deleteDownloads(ids: group.allRecords.map(\.id))
                            dismiss()
                        } label: {
                            Label("Delete All Episodes", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .siloToolbarColorSchemeDark()
    }

    private func content(_ group: DownloadSeriesGroup) -> some View {
        let season = currentSeason(group)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                OfflineBrowseHero(
                    title: group.title,
                    eyebrow: heroEyebrow(group),
                    posterThumbhash: group.posterThumbhash,
                    availability: "Downloaded · \(group.episodeCount) episode\(group.episodeCount == 1 ? "" : "s") · \(DownloadFormatting.bytes(group.totalBytes))",
                    isMonitored: group.isMonitored,
                    playTitle: playTitle(season),
                    onPlay: { if let record = playTarget(season) { play(record) } }
                )

                if group.seasons.count > 1 {
                    seasonChips(group)
                }

                if let season {
                    seasonHeaderRow(season)
                    ForEach(season.records) { record in
                        DownloadEpisodeRow(record: record, watched: manager.isWatched(record)) {
                            play(record)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                manager.deleteDownload(id: record.id)
                            } label: {
                                Label("Delete Download", systemImage: "trash")
                            }
                        }
                    }
                }

                Color.clear.frame(height: 30)
            }
        }
    }

    private func seasonChips(_ group: DownloadSeriesGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(group.seasons) { season in
                    let isSelected = season.seasonNumber == currentSeason(group)?.seasonNumber
                    Button {
                        selectedSeasonNumber = season.seasonNumber
                    } label: {
                        Text(season.isSpecials ? "Specials" : "Season \(season.seasonNumber)")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(isSelected ? .siloOnSurface : .siloSecondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill)
                                    .overlay(
                                        Capsule().stroke(
                                            isSelected ? Color.siloChromeSelectedBorder : Color.siloChromeRestingBorder,
                                            lineWidth: 1
                                        )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 14)
    }

    private func seasonHeaderRow(_ season: DownloadSeasonGroup) -> some View {
        HStack {
            Text("Episodes")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.siloOnSurface)
            Spacer()
            Text("\(season.episodeCount) on this device · \(DownloadFormatting.bytes(season.totalBytes))")
                .font(.system(size: 11.5))
                .foregroundColor(.siloOnSurface.opacity(0.38))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func currentSeason(_ group: DownloadSeriesGroup) -> DownloadSeasonGroup? {
        if let selectedSeasonNumber,
           let match = group.seasons.first(where: { $0.seasonNumber == selectedSeasonNumber }) {
            return match
        }
        return group.seasons.first
    }

    private func heroEyebrow(_ group: DownloadSeriesGroup) -> String {
        let seasons = group.seasonCount
        return seasons > 1 ? "Series · \(seasons) seasons" : "Series"
    }

    private func playTarget(_ season: DownloadSeasonGroup?) -> DownloadRecord? {
        guard let season else { return nil }
        return season.records.first(where: { !manager.isWatched($0) }) ?? season.records.first
    }

    private func playTitle(_ season: DownloadSeasonGroup?) -> String {
        guard let record = playTarget(season) else { return "Play" }
        if manager.localProgress(forMediaItemId: record.leafMediaItemId)?.position ?? 0 > 30 {
            return "Resume\(episodeTag(record))"
        }
        return "Play\(episodeTag(record))"
    }

    private func episodeTag(_ record: DownloadRecord) -> String {
        guard let episode = record.episodeNumber else { return "" }
        if let season = record.seasonNumber, season > 0 { return " S\(season)·E\(episode)" }
        return " E\(episode)"
    }

    private func play(_ record: DownloadRecord) {
        guard record.isPlayableOffline else { return }
        let leafId = record.leafMediaItemId
        router.presentOfflinePlayer(
            downloadId: record.id,
            contentId: leafId,
            resumePosition: manager.localProgress(forMediaItemId: leafId)?.position
        )
    }
}

// MARK: - Leaf detail (movie or episode)

/// Offline leaf detail for one downloaded movie or episode, built from the
/// same hero as the online detail page: the downloaded backdrop (or poster)
/// and title logo, metadata, Play/Resume, then what this download contains
/// and a confirmed delete. Everything comes from the download bundle on disk.
struct OfflineDownloadDetailView: View {
    let downloadId: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var manifest: OfflineManifest?
    @State private var confirmingDelete = false

    private var record: DownloadRecord? { manager.record(id: downloadId) }

    var body: some View {
        Group {
            if let record {
                content(record)
            } else {
                EmptyStateView(icon: "arrow.down.circle", title: "Download Removed", subtitle: nil)
                    .siloPageBackground()
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .siloNavigationBarBackgroundHidden()
        .task {
            if manifest == nil, let record { manifest = await manager.loadManifest(for: record) }
        }
        .siloToolbarColorSchemeDark()
    }

    private func content(_ record: DownloadRecord) -> some View {
        let backdrop = manager.backdropImageURL(for: record)?.absoluteString
        let poster = manager.posterImageURL(for: record)?.absoluteString
        return PhoneDetailPageSurface(
            backdropURL: backdrop ?? poster,
            backdropThumbhash: backdrop != nil ? manifest?.backdropThumbhash : record.posterThumbhash,
            enablesArtworkGlass: true
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    hero(record, backdrop: backdrop, poster: poster)
                    downloadSection(record)
                        .padding(.horizontal, SiloTheme.safePadding)
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
        }
        .alert("Delete this download?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                manager.deleteDownload(id: record.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(DownloadFormatting.bytes(record.fileSize)) on this device.")
        }
    }

    private func hero(_ record: DownloadRecord, backdrop: String?, poster: String?) -> some View {
        PhoneDetailHero(
            title: record.title ?? record.contentId,
            // A series logo would misname an episode, so only movies use one.
            logoUrl: record.type == "episode" ? nil : manager.logoImageURL(for: record)?.absoluteString,
            posterUrl: poster,
            posterThumbhash: record.posterThumbhash,
            backdropUrl: backdrop,
            backdropThumbhash: manifest?.backdropThumbhash,
            // The series and episode number already lead the metadata line.
            eyebrow: nil,
            sourceTokens: sourceTokens(record),
            ratingChip: ratingChip,
            overview: manifest?.overview,
            factsLine: factsLine,
            enablesArtworkParallax: true,
            actions: { actions(record) },
            belowOverview: { EmptyView() }
        )
    }

    private func actions(_ record: DownloadRecord) -> some View {
        VStack(spacing: 14) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: playLabel(record),
                action: { play(record) },
                fullWidth: true,
                progress: resumeFraction(record)
            )

            PhoneLabeledActionRow {
                if resumeFraction(record) != nil {
                    PhoneLabeledAction(icon: "gobackward", label: "Start Over", isToggle: false) {
                        playFromStart(record)
                    }
                }
                PhoneLabeledAction(icon: "trash", label: "Delete", isToggle: false) {
                    confirmingDelete = true
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// What this copy on the device contains, in the online page's
    /// Details layout.
    private func downloadSection(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Download")
            VStack(spacing: 0) {
                ForEach(Array(factRows(record).enumerated()), id: \.element.0) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Text(row.0.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.siloOnSurface.opacity(0.5))
                            .frame(width: 100, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 14))
                            .foregroundColor(.siloOnSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Hero metadata

    private var factsLine: [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if let year = manifest?.year, year > 0 { tokens.append(.text(String(year))) }
        if let runtime = manifest?.runtime, runtime > 0 {
            tokens.append(.text(PhoneHeroMetadata.formatRuntime(runtime)))
        }
        if let resolution = manifest?.resolution, !resolution.isEmpty { tokens.append(.text(resolution)) }
        if manifest?.hdr == true { tokens.append(.text("HDR")) }
        return tokens
    }

    private func sourceTokens(_ record: DownloadRecord) -> [String] {
        var tokens: [String] = []
        if record.type == "episode" {
            if let series = record.seriesTitle ?? manifest?.seriesTitle, !series.isEmpty {
                tokens.append(series)
            }
            let tag = [record.seasonNumber.map { "S\($0)" }, record.episodeNumber.map { "E\($0)" }]
                .compactMap { $0 }
                .joined(separator: " ")
            if !tag.isEmpty { tokens.append(tag) }
        } else if let genres = manifest?.genres, !genres.isEmpty {
            tokens.append(genres.prefix(2).joined(separator: ", "))
        }
        return tokens
    }

    private var ratingChip: String? {
        guard let rating = manifest?.contentRating?.trimmingCharacters(in: .whitespaces),
              !rating.isEmpty else { return nil }
        return rating
    }

    // MARK: - Derived text

    private func factRows(_ record: DownloadRecord) -> [(String, String)] {
        var rows: [(String, String)] = [("Size", DownloadFormatting.bytes(record.fileSize))]
        if let audio = manifest?.codecAudio, !audio.isEmpty {
            rows.append(("Audio", audio.uppercased()))
        }
        if let subtitles = manifest?.subtitles, !subtitles.isEmpty {
            let langs = subtitles.compactMap { $0.language }.joined(separator: ", ")
            rows.append(("Subtitles", langs.isEmpty ? "\(subtitles.count) track\(subtitles.count == 1 ? "" : "s")" : langs))
        }
        var quality: [String] = []
        if let resolution = manifest?.resolution, !resolution.isEmpty { quality.append(resolution) }
        if let codec = manifest?.codecVideo, !codec.isEmpty { quality.append(codec.uppercased()) }
        if manifest?.hdr == true { quality.append("HDR") }
        let qualityValue = manifest?.effectiveQuality ?? record.effectiveQuality ?? record.format
        quality.append(DownloadFormat(rawValue: qualityValue)?.displayName ?? qualityValue.capitalized)
        if let delivery = manifest?.deliveryFormat ?? record.deliveryFormat,
           delivery != "original",
           !delivery.isEmpty {
            quality.append(deliveryDisplayName(delivery))
        }
        if !quality.isEmpty { rows.append(("Quality", quality.joined(separator: " · "))) }
        if let date = record.downloadedAt {
            rows.append(("Downloaded", date.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }

    private func deliveryDisplayName(_ raw: String) -> String {
        switch raw {
        case "remux": return "Remux"
        case "transcode": return "Transcode"
        default: return raw.capitalized
        }
    }

    private func playLabel(_ record: DownloadRecord) -> String {
        guard let progress = manager.localProgress(forMediaItemId: record.leafMediaItemId),
              progress.position > 30 else { return "Play" }
        return "Resume \(PlayerTimeFormatter.formatHMS(progress.position))"
    }

    private func resumeFraction(_ record: DownloadRecord) -> Double? {
        guard let progress = manager.localProgress(forMediaItemId: record.leafMediaItemId),
              progress.position > 30, progress.duration > 0 else { return nil }
        let fraction = progress.position / progress.duration
        guard fraction < 0.98 else { return nil }
        return min(max(fraction, 0), 1)
    }

    private func play(_ record: DownloadRecord) {
        guard record.isPlayableOffline else { return }
        let leafId = record.leafMediaItemId
        router.presentOfflinePlayer(
            downloadId: record.id,
            contentId: leafId,
            resumePosition: manager.localProgress(forMediaItemId: leafId)?.position
        )
    }

    private func playFromStart(_ record: DownloadRecord) {
        guard record.isPlayableOffline else { return }
        router.presentOfflinePlayer(
            downloadId: record.id,
            contentId: record.leafMediaItemId,
            resumePosition: 0
        )
    }
}

// MARK: - Shared hero

/// A compact cinematic header for the offline browse screens. The downloaded
/// poster's ThumbHash keeps its artwork identity available before local poster
/// data is ready.
private struct OfflineBrowseHero: View {
    let title: String
    let eyebrow: String
    let posterThumbhash: String?
    let availability: String
    var isMonitored: Bool = false
    let playTitle: String
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .bottom, spacing: 14) {
                DownloadPosterThumb(thumbhash: posterThumbhash, width: 72, corner: 10)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(eyebrow)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.siloSecondaryText)
                        if isMonitored {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.siloOnSurface)
                        }
                    }
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(availability)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(.siloOnSurface)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.siloChromeSelectedFill)
                    .overlay(Capsule().stroke(Color.siloChromeSelectedBorder, lineWidth: 1))
            )

            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(playTitle).fontWeight(.bold)
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.siloOnSurface)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.siloSurfaceVariant, Color.siloBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
#endif
