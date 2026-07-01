#if !os(tvOS)
import SwiftUI

/// Per-item download control for the movie / episode detail screen. Reads
/// the live record straight from `DownloadManager.shared` (an `@Observable`
/// singleton), so it reflects download progress without the detail view
/// model having to thread any state through. Matches the 44pt circle
/// styling of the neighboring favorite / watchlist buttons.
struct DownloadActionButton: View {
    let detail: ItemDetail
    let versions: [FileVersion]
    let selectedVersionFileId: Int?

    private var manager: DownloadManager { DownloadManager.shared }
    private var record: DownloadRecord? { manager.record(forContentId: detail.contentId) }
    @State private var showOptions = false

    var body: some View {
        content
            .sheet(isPresented: $showOptions) {
                DownloadOptionsSheet(
                    title: detail.title,
                    versions: versions,
                    selectedVersionFileId: selectedVersionFileId,
                    lastVersionFileId: detail.userData?.lastFileId,
                    onStart: startDownload
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch record?.localStatus {
        case .none:
            Button { showOptions = true } label: {
                circleLabel(icon: "arrow.down.to.line", active: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download")

        case .downloading:
            Menu {
                Button(role: .destructive, action: cancel) {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } label: {
                progressLabel(fraction: record?.progressFraction ?? 0)
            }
            .accessibilityLabel("Downloading")

        case .registering, .preparing, .queued, .fetchingAssets:
            Menu {
                Button(role: .destructive, action: cancel) {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } label: {
                circleLabel(icon: "arrow.down.circle", active: true, showSpinner: true)
            }
            .accessibilityLabel("Preparing download")

        case .completed:
            Menu {
                Button(role: .destructive, action: delete) {
                    Label("Delete Download", systemImage: "trash")
                }
            } label: {
                circleLabel(icon: "checkmark.circle.fill", active: true, tint: .green)
            }
            .accessibilityLabel("Downloaded")

        case .revoked:
            Menu {
                Button(role: .destructive, action: delete) {
                    Label("Delete Download", systemImage: "trash")
                }
            } label: {
                circleLabel(icon: "checkmark.circle", active: true, tint: .yellow)
            }
            .accessibilityLabel("Downloaded (re-download no longer allowed)")

        case .failed:
            Menu {
                Button { showOptions = true } label: {
                    Label("Retry With Options", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive, action: delete) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                circleLabel(icon: "exclamationmark.triangle", active: true, tint: .orange)
            }
            .accessibilityLabel("Download failed")
        }
    }

    // MARK: - Actions

    private func startDownload(_ options: DownloadRequestOptions) {
        Task {
            do {
                if detail.type == "episode" {
                    try await manager.downloadEpisode(
                        seriesId: detail.seriesId ?? detail.contentId,
                        episodeId: detail.contentId,
                        displayTitle: detail.title,
                        displaySubtitle: episodeSubtitle,
                        posterThumbhash: detail.posterThumbhash,
                        fileId: options.fileId,
                        quality: options.quality
                    )
                } else {
                    try await manager.downloadMovie(
                        contentId: detail.contentId,
                        displayTitle: detail.title,
                        year: detail.year,
                        posterThumbhash: detail.posterThumbhash,
                        fileId: options.fileId,
                        quality: options.quality
                    )
                }
            } catch {
                // The record (if any) reflects failure; nothing else to do.
            }
        }
    }

    private func cancel() {
        if let id = record?.id { manager.deleteDownload(id: id) }
    }

    private func delete() {
        if let id = record?.id { manager.deleteDownload(id: id) }
    }

    private var episodeSubtitle: String? {
        let season = detail.seasonNumber.map { "S\($0)" }
        let episode = detail.episodeNumber.map { "E\($0)" }
        let tag = [season, episode].compactMap { $0 }.joined(separator: " · ")
        return tag.isEmpty ? detail.seriesTitle : tag
    }

    // MARK: - Labels

    private func circleLabel(
        icon: String,
        active: Bool,
        tint: Color = .white,
        showSpinner: Bool = false
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(active ? 0.18 : 0.10))
                .overlay(
                    Circle().stroke(Color.white.opacity(active ? 0.55 : 0.25), lineWidth: 1)
                )
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
        }
        .frame(width: 44, height: 44)
    }

    private func progressLabel(fraction: Double) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.10))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4)
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 44, height: 44)
    }
}
#endif
