#if !os(tvOS)
import SwiftUI

// MARK: - Inset-grouped rows

/// Where a row sits in an inset-grouped block of the Manager. Rows stay
/// direct children of the Manager's `LazyVStack`, so long lists stay lazy,
/// and each draws its own slice of the group: rounded outer corners on the
/// ends and a hairline separator above every row but the first.
enum DownloadGroupPosition {
    case only, first, middle, last

    init(index: Int, count: Int) {
        switch (index, count) {
        case (_, 1): self = .only
        case (0, _): self = .first
        case (count - 1, _): self = .last
        default: self = .middle
        }
    }

    var roundsTop: Bool { self == .only || self == .first }
    var roundsBottom: Bool { self == .only || self == .last }
    var hasSeparator: Bool { self == .middle || self == .last }
}

private struct DownloadGroupedRowModifier: ViewModifier {
    let position: DownloadGroupPosition
    let separatorInset: CGFloat
    @Environment(\.displayScale) private var displayScale

    private static let cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position.roundsTop ? Self.cornerRadius : 0,
            bottomLeadingRadius: position.roundsBottom ? Self.cornerRadius : 0,
            bottomTrailingRadius: position.roundsBottom ? Self.cornerRadius : 0,
            topTrailingRadius: position.roundsTop ? Self.cornerRadius : 0,
            style: .continuous
        )
        content
            .background(Color.siloGroupedCell)
            .overlay(alignment: .top) {
                if position.hasSeparator {
                    Rectangle()
                        .fill(Color.siloDivider)
                        .frame(height: 1 / displayScale)
                        .padding(.leading, separatorInset)
                }
            }
            .clipShape(shape)
            #if os(iOS)
            .contentShape(.contextMenuPreview, shape)
            #endif
    }
}

extension View {
    /// Draws this row as one slice of an inset-grouped block: background,
    /// rounded ends, and separator. Apply it inside any `.contextMenu` so the
    /// lifted preview keeps the cell's shape, then inset the result with
    /// `downloadGroupInset()`. The default separator inset lines up with the
    /// text beside a 40-point poster.
    func downloadGroupSlice(
        _ position: DownloadGroupPosition,
        separatorInset: CGFloat = 68
    ) -> some View {
        modifier(DownloadGroupedRowModifier(position: position, separatorInset: separatorInset))
    }

    /// Horizontal margin between an inset group and the screen edges.
    func downloadGroupInset() -> some View {
        padding(.horizontal, 16)
    }

    /// `downloadGroupSlice` plus the group margin, for rows without a
    /// context menu.
    func downloadGroupedRow(
        _ position: DownloadGroupPosition,
        separatorInset: CGFloat = 68
    ) -> some View {
        downloadGroupSlice(position, separatorInset: separatorInset)
            .downloadGroupInset()
    }
}

/// Sentence-case header above an inset group, with an optional trailing
/// count, matching the system grouped-list headers in Settings.
struct DownloadSectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let count {
                Text("\(count)")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundColor(.siloSecondaryText)
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 7)
    }
}

// MARK: - Storage summary

/// The storage card at the top of the Downloads Manager: a big "used of
/// device" figure over a breakdown bar in the Silo wordmark's colors
/// (series / movies / in progress / other).
struct DownloadsStorageHeader: View {
    let used: Int64
    let breakdown: DownloadStorageBreakdown
    var activeCount: Int = 0

    private static let seriesColor = Color.siloBrandBlue
    private static let moviesColor = Color.siloBrandRed
    private static let inProgressColor = Color.siloBrandOrange
    private static let otherColor = Color.siloOnSurface.opacity(0.3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let amount = Text(DownloadFormatting.bytes(used))
                .font(.title2.bold())
                .foregroundColor(.siloOnSurface)
            let context = Text(contextSuffix)
                .font(.subheadline)
                .foregroundColor(.siloSecondaryText)
            Text("\(amount)\(context)")

            if activeCount > 0 {
                Text(inProgressLine)
                    .font(.footnote)
                    .foregroundColor(.siloSecondaryText)
            }

            if breakdown.total > 0 {
                breakdownBar
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var contextSuffix: String {
        let deviceTotal = DownloadFilePaths.totalCapacity
        return deviceTotal > 0
            ? "  of \(DownloadFormatting.bytes(deviceTotal)) on this device"
            : "  downloaded"
    }

    /// Mid-flight transfers are invisible to `used` (partial media sits in
    /// the session's staging area), so this line keeps the hero honest
    /// while something is downloading.
    private var inProgressLine: String {
        var line = "\(activeCount) download\(activeCount == 1 ? "" : "s") in progress"
        if breakdown.inProgress > 0 {
            line += " · \(DownloadFormatting.bytes(breakdown.inProgress)) so far"
        }
        return line
    }

    private var breakdownBar: some View {
        GeometryReader { geo in
            let total = max(CGFloat(breakdown.total), 1)
            let width = geo.size.width
            HStack(spacing: 2) {
                segment(width: width * CGFloat(breakdown.series) / total, color: Self.seriesColor)
                segment(width: width * CGFloat(breakdown.movies) / total, color: Self.moviesColor)
                segment(width: width * CGFloat(breakdown.inProgress) / total, color: Self.inProgressColor)
                segment(width: width * CGFloat(breakdown.other) / total, color: Self.otherColor)
            }
        }
        .frame(height: 18)
        .background(Color.siloChromeRestingFill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        color.frame(width: max(0, width))
    }

    /// Two columns, so four categories fit a phone width without wrapping
    /// inside a label.
    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            legendItem(color: Self.seriesColor, bytes: breakdown.series, label: "Series")
            legendItem(color: Self.moviesColor, bytes: breakdown.movies, label: "Movies")
            legendItem(color: Self.inProgressColor, bytes: breakdown.inProgress, label: "In progress")
            legendItem(color: Self.otherColor, bytes: breakdown.other, label: "Other")
        }
    }

    @ViewBuilder private func legendItem(color: Color, bytes: Int64, label: String) -> some View {
        if bytes > 0 {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .foregroundColor(.siloSecondaryText)
                Text(DownloadFormatting.bytes(bytes))
                    .fontWeight(.semibold)
                    .foregroundColor(.siloOnSurface)
            }
            .font(.footnote)
            .lineLimit(1)
        }
    }
}

// MARK: - Reclaim suggestion

/// "Free up X · N watched" row under the storage summary. Tapping opens the
/// reclaim review sheet.
struct DownloadReclaimBanner: View {
    let episodeCount: Int
    let bytes: Int64
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 12) {
                let amount = Text("Free up \(DownloadFormatting.bytes(bytes))")
                    .foregroundColor(.siloOnSurface)
                let count = Text(" · \(episodeCount) watched")
                    .foregroundColor(.siloSecondaryText)
                Text("\(amount)\(count)")
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("Review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.siloOnSurface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.siloChromeSelectedFill))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Reviews \(episodeCount) item\(episodeCount == 1 ? "" : "s") you've finished")
    }
}

// MARK: - Sort control

/// "Largest First ▾   N items" row above the Manager list.
struct DownloadSortControl: View {
    @Binding var option: DownloadSortOption
    let itemCount: Int

    var body: some View {
        HStack {
            Menu {
                Picker("Sort", selection: $option) {
                    ForEach(DownloadSortOption.allCases) { opt in
                        Label(opt.displayName, systemImage: opt.systemImage).tag(opt)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(option.displayName)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(.siloOnSurface)
            }

            Spacer()

            Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundColor(.siloSecondaryText)
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

// MARK: - Small reusable bits

/// Selection circle shown on the leading edge of rows in select mode.
struct DownloadSelectionCircle: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(selected ? Color.siloOnSurface : Color.clear)
                .overlay(
                    Circle().stroke(
                        selected ? Color.siloOnSurface : Color.siloOnSurface.opacity(0.35),
                        lineWidth: 1.5
                    )
                )
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Downloaded artwork filling its frame: the image on local disk drawn over
/// its thumbhash, which stays visible until the file loads or when there is
/// none.
struct DownloadArtworkImage: View {
    let thumbhash: String?
    /// Image on local disk, fetched by the download pipeline before the media
    /// transfer starts, so in-progress rows aren't a placeholder for the whole
    /// transfer.
    let fileURL: URL?

    var body: some View {
        ZStack {
            ThumbhashImage(thumbhash: thumbhash)
            if let fileURL {
                AsyncImage(url: fileURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
    }
}

/// A 2:3 poster tile sized for a Manager / browse row.
struct DownloadPosterThumb: View {
    let thumbhash: String?
    var fileURL: URL? = nil
    var width: CGFloat = 40
    var corner: CGFloat = 7

    var body: some View {
        DownloadArtworkImage(thumbhash: thumbhash, fileURL: fileURL)
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
#endif
