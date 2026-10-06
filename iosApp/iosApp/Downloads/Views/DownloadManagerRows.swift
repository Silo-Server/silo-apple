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
    /// deltas have landed for the estimate to be meaningful, and again once
    /// progress stops arriving.
    var bytesPerSecond: Double? = nil
    /// What the download waits for, when it can't move right now.
    var wait: DownloadManager.Wait? = nil
    var selecting: Bool = false
    var selected: Bool = false
    /// This row's place in the Downloading group; drawn inside the context
    /// menu so the lifted preview keeps the cell's shape.
    var groupPosition: DownloadGroupPosition = .only
    var onSelectToggle: () -> Void = {}
    var onPauseResume: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var confirmingCancel = false

    var body: some View {
        if selecting {
            Button(action: onSelectToggle) { card }
                .buttonStyle(.plain)
                .downloadGroupSlice(groupPosition)
        } else {
            actionableCard
        }
    }

    private var actionableCard: some View {
        DownloadSwipeRevealContainer(actionLabel: "Cancel") {
            confirmingCancel = true
        } content: {
            card
        }
        .downloadGroupSlice(groupPosition)
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
            if selecting { DownloadSelectionCircle(selected: selected) }
            DownloadPosterThumb(
                thumbhash: record.tileThumbhash,
                fileURL: DownloadManager.shared.tilePosterImageURL(for: record),
                width: 40
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12.5))
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            if !selecting { progressRing }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // Opaque so the swipe-revealed Cancel action stays hidden underneath.
        .background(Color.siloGroupedCell)
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
            if rateParts.isEmpty {
                if let waitText {
                    return record.bytesDownloaded > 0 ? "\(waitText) · \(percentText)" : waitText
                }
                // Handed to iOS, which hasn't started the transfer yet.
                if record.bytesDownloaded == 0 { return "Waiting…" }
            }
            return ([percentText, sizeText] + rateParts).joined(separator: " · ")
        case .paused:
            return "Paused · \(percentText) · \(sizeText)"
        case .registering, .queued: return waitText ?? "Queued"
        case .preparing: return record.preparation?.statusLine ?? "Preparing on server…"
        // Fetching the manifest, before the transfer starts.
        case .fetchingAssets: return waitText ?? "Starting…"
        case .completed: return DownloadFormatting.bytes(record.fileSize)
        case .failed: return "Failed"
        case .revoked: return "No longer available"
        }
    }

    private var waitText: String? { wait?.label }

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
                    Circle().stroke(Color.siloOnSurface.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, record.progressFraction))
                        .stroke(
                            Color.siloOnSurface.opacity(paused ? 0.55 : 1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.siloOnSurface)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Resume download" : "Pause download")
        case .preparing where record.preparation?.progress != nil:
            // The server's encode, not a transfer: nothing to pause.
            ZStack {
                Circle().stroke(Color.siloOnSurface.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, record.preparation?.progress ?? 0))
                    .stroke(Color.siloOnSurface.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
        default:
            ProgressView().controlSize(.small).tint(.siloOnSurface)
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
            .frame(width: revealWidth)
            .frame(maxHeight: .infinity)
            .background(Color.siloError)
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
                thumbhash: record.tileThumbhash,
                fileURL: DownloadManager.shared.tilePosterImageURL(for: record),
                width: 40
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title ?? record.contentId)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Text(record.failureReason)
                    .font(.system(size: 12.5))
                    .foregroundColor(.siloError)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundColor(.siloSecondaryText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title ?? record.contentId)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(1)
                    Text(meta)
                        .font(.subheadline)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var meta: String {
        var parts: [String] = []
        if let sub = record.subtitle, !sub.isEmpty { parts.append(sub) }
        parts.append(DownloadFormatting.bytes(record.fileSize))
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
    /// Tapping the header opens the offline series browse screen.
    let onOpenSeries: () -> Void
    var onPlayEpisode: (DownloadRecord) -> Void = { _ in }
    var onDeleteEpisode: (DownloadRecord) -> Void = { _ in }

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded && !selecting {
                ForEach(group.seasons) { season in
                    Divider().overlay(Color.siloDivider)
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
    }

    private var header: some View {
        HStack(spacing: 12) {
            if selecting { DownloadSelectionCircle(selected: selected) }
            posterStack
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(group.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if group.isMonitored { monitorBadge }
                }
                Text(subtitleLine)
                    .font(.subheadline)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !selecting {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.siloSecondaryText)
                        .frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse episodes" : "Expand episodes")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: headerTap)
    }

    private func headerTap() {
        if selecting {
            onSelectToggle()
        } else {
            onOpenSeries()
        }
    }

    /// The series poster with two cards peeking out behind it, marking the
    /// row as a group of episodes.
    private var posterStack: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 40, height: 54)
                .offset(x: 7)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: 40, height: 57)
                .offset(x: 3.5)
            DownloadPosterThumb(
                thumbhash: group.posterThumbhash,
                fileURL: DownloadManager.shared.seriesPosterImageURL(for: group),
                width: 40
            )
        }
        .frame(width: 47, height: 60, alignment: .leading)
    }

    /// Antenna glyph after the title of a monitored series — the same
    /// glyph as the Monitored row.
    private var monitorBadge: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.footnote.weight(.semibold))
            .foregroundColor(.siloSecondaryText)
            .accessibilityLabel("Monitored")
    }

    private var subtitleLine: String {
        let seasons = group.seasonCount
        let seasonPart = seasons > 1
            ? "\(seasons) seasons"
            : (group.seasons.first.map { $0.isSpecials ? "Specials" : "Season \($0.seasonNumber)" } ?? "")
        var line = "\(group.episodeCount) episode\(group.episodeCount == 1 ? "" : "s")"
        if !seasonPart.isEmpty { line += " · \(seasonPart)" }
        line += " · \(DownloadFormatting.bytes(group.totalBytes))"
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
                .foregroundColor(.siloOnSurface)
            Spacer()
            Text("\(season.episodeCount) ep\(season.episodeCount == 1 ? "" : "s") · \(DownloadFormatting.bytes(season.totalBytes))")
                .font(.system(size: 11.5))
                .foregroundColor(.siloSecondaryText)
        }
        .padding(.horizontal, 16)
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
                DownloadArtworkImage(
                    thumbhash: record.posterThumbhash,
                    fileURL: DownloadManager.shared.posterImageURL(for: record)
                )
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
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(1)
                        .opacity(watched ? 0.55 : 1)
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: watched ? "checkmark" : "play.circle")
                    .font(.system(size: watched ? 13 : 18, weight: watched ? .semibold : .regular))
                    .foregroundColor(watched ? .siloOnSurface.opacity(0.5) : .siloOnSurface)
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
