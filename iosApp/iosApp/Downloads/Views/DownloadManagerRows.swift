#if !os(tvOS)
import SwiftUI

// MARK: - In-progress row

/// A pinned active-transfer row (downloading / queued / preparing) with a
/// circular progress ring that doubles as a stop button.
struct DownloadActiveRow: View {
    let record: DownloadRecord
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            DownloadPosterThumb(thumbhash: record.posterThumbhash, width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12.5))
                    .foregroundColor(.continuumSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            progressRing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.continuumSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.continuumOutline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private var displayTitle: String {
        if record.type == "episode", let sub = record.subtitle, !sub.isEmpty {
            return "\(record.title ?? record.contentId) · \(sub)"
        }
        return record.title ?? record.contentId
    }

    private var statusLine: String {
        switch record.localStatus {
        case .downloading:
            let pct = Int((record.progressFraction * 100).rounded())
            return "\(pct)% · \(DownloadFormatting.bytes(record.bytesDownloaded)) of \(DownloadFormatting.bytes(record.fileSize))"
        case .registering, .queued: return "Queued"
        case .preparing: return "Preparing on server…"
        case .fetchingAssets: return "Finishing…"
        case .completed: return DownloadFormatting.bytes(record.fileSize)
        case .failed: return "Failed"
        case .revoked: return "No longer available"
        }
    }

    @ViewBuilder private var progressRing: some View {
        if record.localStatus == .downloading {
            Button(action: onCancel) {
                ZStack {
                    Circle().stroke(Color.continuumOnSurface.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, record.progressFraction))
                        .stroke(Color.continuumOnSurface, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.continuumOnSurface)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
        } else {
            ProgressView().controlSize(.small).tint(.continuumOnSurface)
        }
    }
}

// MARK: - Failed / attention row

/// A failed download surfaced for retry or removal so it isn't silently lost.
struct DownloadAttentionRow: View {
    let record: DownloadRecord
    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            DownloadPosterThumb(thumbhash: record.posterThumbhash, width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title ?? record.contentId)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
                    .lineLimit(1)
                Text("Download failed")
                    .font(.system(size: 12.5))
                    .foregroundColor(.continuumError)
            }
            Spacer(minLength: 8)
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundColor(.continuumSecondaryText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.continuumSurfaceVariant)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.continuumOutline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Movie row

struct DownloadMovieRow: View {
    let record: DownloadRecord
    let watched: Bool
    var selecting: Bool = false
    var selected: Bool = false
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if selecting { DownloadSelectionCircle(selected: selected) }
                DownloadPosterThumb(thumbhash: record.posterThumbhash, width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(record.title ?? record.contentId)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.continuumOnSurface)
                            .lineLimit(1)
                        DownloadKindChip(text: "Movie")
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 12))
                            .foregroundColor(.continuumSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(DownloadFormatting.bytes(record.fileSize))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var meta: String {
        var parts: [String] = []
        if let sub = record.subtitle, !sub.isEmpty { parts.append(sub) }
        if watched { parts.append("watched") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Series row (collapses to one card, expands in place)

struct DownloadSeriesRow: View {
    let group: DownloadSeriesGroup
    var selecting: Bool = false
    var selected: Bool = false
    let isWatched: (DownloadRecord) -> Bool
    var onSelectToggle: () -> Void = {}
    /// When non-nil, tapping the header opens the offline browse detail
    /// (Phase 3). When nil, the header simply toggles inline expansion.
    var onOpenSeries: (() -> Void)? = nil
    var onPlayEpisode: (DownloadRecord) -> Void = { _ in }
    var onDeleteEpisode: (DownloadRecord) -> Void = { _ in }

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded && !selecting {
                ForEach(group.seasons) { season in
                    Divider().overlay(Color.continuumDivider)
                    seasonHeader(season)
                    ForEach(season.records) { record in
                        DownloadEpisodeRow(record: record, watched: isWatched(record)) {
                            onPlayEpisode(record)
                        }
                        .contextMenu {
                            Button(role: .destructive) { onDeleteEpisode(record) } label: {
                                Label("Delete Download", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(expanded ? Color.continuumSurfaceElevated : Color.continuumSurfaceVariant)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.continuumOutline, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 13) {
            if selecting { DownloadSelectionCircle(selected: selected) }
            posterStack
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(group.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(1)
                    if group.isMonitored { monitorBadge }
                }
                Text(subtitleLine)
                    .font(.system(size: 12.5))
                    .foregroundColor(.continuumSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(DownloadFormatting.bytes(group.totalBytes))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.continuumOnSurface)
            if !selecting {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.continuumSecondaryText)
                        .frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse episodes" : "Expand episodes")
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture(perform: headerTap)
    }

    private func headerTap() {
        if selecting {
            onSelectToggle()
        } else if let onOpenSeries {
            onOpenSeries()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
    }

    private var posterStack: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.continuumSurfaceVariant)
                .frame(width: 46, height: 62)
                .offset(x: 9)
                .opacity(0.45)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.continuumSurface)
                .frame(width: 46, height: 64)
                .offset(x: 4)
                .opacity(0.7)
            DownloadPosterThumb(thumbhash: group.posterThumbhash, width: 46)
        }
        .frame(width: 59, height: 66, alignment: .leading)
    }

    private var monitorBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .semibold))
            Text("Monitoring")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundColor(.continuumOnSurface)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.continuumChromeRestingFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.continuumChromeRestingBorder, lineWidth: 1)
                )
        )
    }

    private var subtitleLine: String {
        let seasons = group.seasonCount
        let seasonPart = seasons > 1
            ? "\(seasons) seasons"
            : (group.seasons.first.map { $0.isSpecials ? "Specials" : "Season \($0.seasonNumber)" } ?? "")
        var line = "\(group.episodeCount) episode\(group.episodeCount == 1 ? "" : "s")"
        if !seasonPart.isEmpty { line += " · \(seasonPart)" }
        if group.allWatched {
            line += " · all watched"
        } else if group.watchedCount > 0 {
            line += " · \(group.watchedCount) watched"
        }
        return line
    }

    private func seasonHeader(_ season: DownloadSeasonGroup) -> some View {
        HStack {
            Text(season.isSpecials ? "Specials" : "Season \(season.seasonNumber)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.continuumOnSurface)
            Spacer()
            Text("\(season.episodeCount) ep\(season.episodeCount == 1 ? "" : "s") · \(DownloadFormatting.bytes(season.totalBytes))")
                .font(.system(size: 11.5))
                .foregroundColor(.continuumSecondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }
}

// MARK: - Episode row (inside an expanded series / reclaim sheet)

struct DownloadEpisodeRow: View {
    let record: DownloadRecord
    let watched: Bool
    var onPlay: () -> Void = {}

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 11) {
                ThumbhashImage(thumbhash: record.posterThumbhash)
                    .frame(width: 54, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.9))
                    )
                    .opacity(watched ? 0.5 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(1)
                        .opacity(watched ? 0.55 : 1)
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: watched ? "checkmark" : "play.circle")
                    .font(.system(size: watched ? 13 : 18, weight: watched ? .semibold : .regular))
                    .foregroundColor(watched ? .continuumOnSurface.opacity(0.5) : .continuumOnSurface)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if let episode = record.episodeNumber {
            return "E\(episode) · \(record.title ?? record.contentId)"
        }
        return record.title ?? record.contentId
    }

    private var meta: String {
        let size = DownloadFormatting.bytes(record.fileSize)
        return watched ? "Watched · \(size)" : size
    }
}
#endif
