#if !os(tvOS)
import SwiftUI

// MARK: - In-progress row

/// A pinned active-transfer row (downloading / paused / queued / preparing)
/// whose circular progress ring toggles pause/resume. Cancelling is
/// deliberately harder to reach — context menu or swipe, both behind a
/// confirmation that states how much downloaded data would be discarded.
struct DownloadActiveRow: View {
    let record: DownloadRecord
    /// Smoothed transfer rate from the manager; nil until enough progress
    /// deltas have landed for the estimate to be meaningful.
    var bytesPerSecond: Double? = nil
    var onPauseResume: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var confirmingCancel = false

    var body: some View {
        DownloadSwipeRevealContainer(actionLabel: "Cancel") {
            confirmingCancel = true
        } content: {
            card
        }
        .padding(.horizontal, 16)
        .contextMenu { menuItems }
        .confirmationDialog(
            cancelPrompt,
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Discard Download", role: .destructive, action: onCancel)
            Button("Keep Download", role: .cancel) {}
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            DownloadPosterThumb(
                thumbhash: record.posterThumbhash,
                fileURL: DownloadManager.shared.posterImageURL(for: record),
                width: 40
            )

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
    }

    @ViewBuilder private var menuItems: some View {
        if record.localStatus == .downloading {
            Button(action: onPauseResume) {
                Label("Pause", systemImage: "pause")
            }
        } else if record.localStatus == .paused {
            Button(action: onPauseResume) {
                Label("Resume", systemImage: "play")
            }
        }
        Button(role: .destructive) { confirmingCancel = true } label: {
            Label("Cancel Download", systemImage: "xmark.circle")
        }
    }

    /// States what a destructive cancel throws away; bytes are omitted when
    /// nothing has transferred yet.
    private var cancelPrompt: String {
        if record.bytesDownloaded > 0 {
            return "Discard \(DownloadFormatting.bytes(record.bytesDownloaded)) of downloaded data?"
        }
        return "Cancel this download?"
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
            return ([percentText, sizeText] + rateParts).joined(separator: " · ")
        case .paused:
            return "Paused · \(percentText) · \(sizeText)"
        case .registering, .queued: return "Queued"
        case .preparing: return "Preparing on server…"
        case .fetchingAssets: return "Finishing…"
        case .completed: return DownloadFormatting.bytes(record.fileSize)
        case .failed: return "Failed"
        case .revoked: return "No longer available"
        }
    }

    private var percentText: String {
        "\(Int((record.progressFraction * 100).rounded()))%"
    }

    private var sizeText: String {
        "\(DownloadFormatting.bytes(record.bytesDownloaded)) of \(DownloadFormatting.bytes(record.fileSize))"
    }

    /// "12 MB/s · 3 min left" once the manager has a smoothed rate; omitted
    /// while the rate is still settling so the line never shows garbage.
    private var rateParts: [String] {
        guard let bytesPerSecond, bytesPerSecond >= 1 else { return [] }
        var parts = ["\(DownloadFormatting.bytes(Int64(bytesPerSecond)))/s"]
        let remaining = record.fileSize - record.bytesDownloaded
        if remaining > 0 {
            parts.append(Self.remainingText(seconds: Double(remaining) / bytesPerSecond))
        }
        return parts
    }

    private static func remainingText(seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under 1 min left" }
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) hr \(minutes % 60) min left"
    }

    @ViewBuilder private var progressRing: some View {
        switch record.localStatus {
        case .downloading, .paused:
            let paused = record.localStatus == .paused
            Button(action: onPauseResume) {
                ZStack {
                    Circle().stroke(Color.continuumOnSurface.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, record.progressFraction))
                        .stroke(
                            Color.continuumOnSurface.opacity(paused ? 0.55 : 1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.continuumOnSurface)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Resume download" : "Pause download")
        default:
            ProgressView().controlSize(.small).tint(.continuumOnSurface)
        }
    }
}

// MARK: - Swipe-to-reveal (LazyVStack rows)

/// Trailing swipe affordance for rows hosted in the Manager's `LazyVStack`
/// (`.swipeActions` only functions inside a `List`). The drag activates
/// only when clearly horizontal so it doesn't fight the scroll view.
struct DownloadSwipeRevealContainer<Content: View>: View {
    let actionLabel: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
            revealButton
            content()
                .offset(x: offset)
                .simultaneousGesture(drag)
                .onTapGesture {
                    if isOpen { close() }
                }
        }
        .animation(.easeInOut(duration: 0.2), value: offset)
    }

    private var revealButton: some View {
        Button {
            close()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                Text(actionLabel)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(width: revealWidth - 8)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.continuumError)
            )
        }
        .buttonStyle(.plain)
        .opacity(offset < -8 ? 1 : 0)
        // Opacity alone leaves the closed button in the hierarchy —
        // reachable by VoiceOver and hit testing under the row content.
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                // Ignore mostly-vertical drags — those belong to the scroll.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isOpen ? -revealWidth : 0
                offset = min(0, max(-revealWidth, base + value.translation.width))
            }
            .onEnded { _ in
                if offset < -revealWidth / 2 {
                    offset = -revealWidth
                    isOpen = true
                } else {
                    close()
                }
            }
    }

    private func close() {
        offset = 0
        isOpen = false
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
            DownloadPosterThumb(
                thumbhash: record.posterThumbhash,
                fileURL: DownloadManager.shared.posterImageURL(for: record),
                width: 40
            )
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
                DownloadPosterThumb(
                    thumbhash: record.posterThumbhash,
                    fileURL: DownloadManager.shared.posterImageURL(for: record),
                    width: 40
                )
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
            DownloadPosterThumb(
                thumbhash: group.posterThumbhash,
                fileURL: posterFileURL,
                width: 46
            )
        }
        .frame(width: 59, height: 66, alignment: .leading)
    }

    /// First on-disk poster among the group's episodes — every episode of a
    /// series carries the same series poster in its download bundle.
    private var posterFileURL: URL? {
        group.allRecords.lazy
            .compactMap { DownloadManager.shared.posterImageURL(for: $0) }
            .first
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
