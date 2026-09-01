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
                .background(Color.continuumBackground)
            }
        }
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
        .continuumToolbarColorSchemeDark()
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
        .background(Color.continuumBackground)
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
                            .foregroundColor(isSelected ? .continuumOnSurface : .continuumSecondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.continuumChromeSelectedFill : Color.continuumChromeRestingFill)
                                    .overlay(
                                        Capsule().stroke(
                                            isSelected ? Color.continuumChromeSelectedBorder : Color.continuumChromeRestingBorder,
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
                .foregroundColor(.continuumOnSurface)
            Spacer()
            Text("\(season.episodeCount) on this device · \(DownloadFormatting.bytes(season.totalBytes))")
                .font(.system(size: 11.5))
                .foregroundColor(.continuumOnSurface.opacity(0.38))
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

/// Offline leaf detail for one downloaded movie or episode: synopsis,
/// resume, the audio/subtitle/quality baked into the stored manifest, and
/// a single-item delete.
struct OfflineDownloadDetailView: View {
    let downloadId: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var manifest: OfflineManifest?

    private var record: DownloadRecord? { manager.record(id: downloadId) }

    var body: some View {
        Group {
            if let record {
                content(record)
            } else {
                EmptyStateView(icon: "arrow.down.circle", title: "Download Removed", subtitle: nil)
                    .background(Color.continuumBackground)
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if manifest == nil, let record { manifest = await manager.loadManifest(for: record) }
        }
        .continuumToolbarColorSchemeDark()
    }

    private func content(_ record: DownloadRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                still(record)

                VStack(alignment: .leading, spacing: 0) {
                    if record.type == "episode" {
                        Text(episodeEyebrow(record))
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.4)
                            .foregroundColor(.continuumSecondaryText)
                            .padding(.bottom, 5)
                    }
                    Text(record.title ?? record.contentId)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(.continuumOnSurface)
                    Text(metaLine(record))
                        .font(.system(size: 12))
                        .foregroundColor(.continuumSecondaryText)
                        .padding(.top, 4)

                    availabilityChip(record)
                        .padding(.top, 13)

                    playRow(record)
                        .padding(.top, 14)

                    if let overview = manifest?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundColor(.continuumSecondaryText)
                            .lineSpacing(2)
                            .padding(.top, 16)
                    }

                    facts(record)
                        .padding(.top, 16)

                    deleteButton(record)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Color.clear.frame(height: 30)
            }
        }
        .background(Color.continuumBackground)
    }

    private func still(_ record: DownloadRecord) -> some View {
        Button { play(record) } label: {
            ZStack {
                LinearGradient(
                    colors: [Color.continuumSurfaceElevated, Color.continuumBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white.opacity(0.92))
                if let fraction = resumeFraction(record) {
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.continuumOnSurface.opacity(0.22)
                                Color.continuumOnSurface.frame(width: geo.size.width * fraction)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            .frame(height: 190)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
    }

    private func availabilityChip(_ record: DownloadRecord) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(availabilityText(record))
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundColor(.continuumOnSurface)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.continuumChromeSelectedFill)
                .overlay(Capsule().stroke(Color.continuumChromeSelectedBorder, lineWidth: 1))
        )
    }

    private func playRow(_ record: DownloadRecord) -> some View {
        HStack(spacing: 11) {
            Button { play(record) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(playLabel(record)).fontWeight(.bold)
                }
                .font(.system(size: 14.5))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.continuumOnSurface)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)

            if resumeFraction(record) != nil {
                Button { playFromStart(record) } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                        .frame(width: 46, height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.continuumChromeRestingFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(Color.continuumChromeRestingBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart from beginning")
            }
        }
    }

    private func facts(_ record: DownloadRecord) -> some View {
        VStack(spacing: 0) {
            ForEach(factRows(record), id: \.0) { key, value in
                HStack {
                    Text(key)
                        .font(.system(size: 12.5))
                        .foregroundColor(.continuumSecondaryText)
                    Spacer()
                    Text(value)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.continuumOnSurface)
                }
                .padding(.vertical, 11)
                Divider().overlay(Color.continuumDivider)
            }
        }
        .overlay(Divider().overlay(Color.continuumDivider), alignment: .top)
    }

    private func deleteButton(_ record: DownloadRecord) -> some View {
        Button {
            manager.deleteDownload(id: record.id)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Delete download · Free \(DownloadFormatting.bytes(record.fileSize))")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13.5))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundColor(.continuumError)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.continuumChromeRestingFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.continuumChromeRestingBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived text

    private func episodeEyebrow(_ record: DownloadRecord) -> String {
        let series = (record.seriesTitle ?? manifest?.seriesTitle ?? "").uppercased()
        let tag = [record.seasonNumber.map { "S\($0)" }, record.episodeNumber.map { "E\($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return [series, tag].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func metaLine(_ record: DownloadRecord) -> String {
        var parts: [String] = []
        if let runtime = manifest?.runtime, runtime > 0 { parts.append("\(runtime) min") }
        if let year = manifest?.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private func availabilityText(_ record: DownloadRecord) -> String {
        var parts = ["Downloaded", DownloadFormatting.bytes(record.fileSize)]
        if let resolution = manifest?.resolution, !resolution.isEmpty { parts.append(resolution) }
        return parts.joined(separator: " · ")
    }

    private func factRows(_ record: DownloadRecord) -> [(String, String)] {
        var rows: [(String, String)] = []
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
                            .foregroundColor(.continuumSecondaryText)
                        if isMonitored {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.continuumOnSurface)
                        }
                    }
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(availability)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(.continuumOnSurface)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.continuumChromeSelectedFill)
                    .overlay(Capsule().stroke(Color.continuumChromeSelectedBorder, lineWidth: 1))
            )

            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(playTitle).fontWeight(.bold)
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.continuumOnSurface)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.continuumSurfaceVariant, Color.continuumBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
#endif
