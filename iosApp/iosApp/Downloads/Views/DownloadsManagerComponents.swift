#if !os(tvOS)
import SwiftUI

// MARK: - Storage hero

/// The storage hero at the top of the Downloads Manager: a big "used of
/// device" figure with a typed breakdown bar (series / movies / in
/// progress / other).
struct DownloadsStorageHeader: View {
    let used: Int64
    let breakdown: DownloadStorageBreakdown
    var activeCount: Int = 0

    @State private var device = DownloadFilePaths.deviceStorage()

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            (
                Text(DownloadFormatting.bytes(used))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.siloOnSurface)
                + Text(contextSuffix)
                    .font(.system(size: 14))
                    .foregroundColor(.siloSecondaryText)
            )

            if activeCount > 0 {
                Text(inProgressLine)
                    .font(.system(size: 12.5))
                    .foregroundColor(.siloSecondaryText)
            }

            if breakdown.total > 0 {
                breakdownBar
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.siloSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.siloOutline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private var contextSuffix: String {
        device.total > 0
            ? "  of \(DownloadFormatting.bytes(device.total)) on this device"
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
                segment(width: width * CGFloat(breakdown.series) / total, opacity: 1)
                segment(width: width * CGFloat(breakdown.movies) / total, opacity: 0.52)
                segment(width: width * CGFloat(breakdown.inProgress) / total, opacity: 0.34)
                segment(width: width * CGFloat(breakdown.other) / total, opacity: 0.18)
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

    private func segment(width: CGFloat, opacity: Double) -> some View {
        Color.siloOnSurface.opacity(opacity).frame(width: max(0, width))
    }

    @ViewBuilder private var legend: some View {
        HStack(spacing: 16) {
            legendItem(opacity: 1, bytes: breakdown.series, label: "Series")
            legendItem(opacity: 0.52, bytes: breakdown.movies, label: "Movies")
            legendItem(opacity: 0.34, bytes: breakdown.inProgress, label: "In progress")
            legendItem(opacity: 0.18, bytes: breakdown.other, label: "Other")
        }
    }

    @ViewBuilder private func legendItem(opacity: Double, bytes: Int64, label: String) -> some View {
        if bytes > 0 {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.siloOnSurface.opacity(opacity))
                    .frame(width: 9, height: 9)
                Text(DownloadFormatting.bytes(bytes))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.siloSecondaryText)
            }
        }
    }
}

// MARK: - Reclaim banner

/// "Free up X — N watched episodes" suggestion. Tapping opens the reclaim
/// review sheet.
struct DownloadReclaimBanner: View {
    let episodeCount: Int
    let bytes: Int64
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.siloChromeSelectedFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.siloChromeSelectedBorder, lineWidth: 1)
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.siloOnSurface)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Free up \(DownloadFormatting.bytes(bytes))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                    Text("\(episodeCount) item\(episodeCount == 1 ? "" : "s") you've finished")
                        .font(.system(size: 12.5))
                        .foregroundColor(.siloSecondaryText)
                }

                Spacer(minLength: 8)

                Text("Review")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(Color.siloChromeSelectedFill)
                            .overlay(Capsule().stroke(Color.siloChromeSelectedBorder, lineWidth: 1))
                    )
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.siloSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.siloChromeSelectedBorder, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

// MARK: - Sort control

/// "Sort: Largest first ▾   N items" row above the Manager list.
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
                        .font(.system(size: 13.5, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.siloOnSurface)
            }

            Spacer()

            Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                .font(.system(size: 12.5))
                .foregroundColor(.siloOnSurface.opacity(0.38))
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 2)
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

/// A 2:3 poster tile sized for a Manager / browse row.
struct DownloadPosterThumb: View {
    let thumbhash: String?
    /// Poster image on local disk, fetched by the download pipeline before
    /// the media transfer starts — drawn over the thumbhash placeholder so
    /// in-progress rows aren't a blank tile for the whole transfer.
    var fileURL: URL? = nil
    var width: CGFloat = 40
    var corner: CGFloat = 7

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
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// "MOVIE" / "SERIES" capsule chip used in Manager rows.
struct DownloadKindChip: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.4)
            .foregroundColor(.siloSecondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.siloChromeRestingFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.siloChromeRestingBorder, lineWidth: 1)
                    )
            )
    }
}
#endif
