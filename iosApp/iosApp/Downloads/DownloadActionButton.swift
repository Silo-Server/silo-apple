#if !os(tvOS)
import SwiftUI

/// Download control for the movie / episode detail action row. Reads the
/// live record straight from `DownloadManager.shared` (an `@Observable`
/// singleton), so it reflects download progress without the detail view
/// model having to thread any state through.
///
/// Draws a bare glyph over a state-derived caption, sized like the
/// neighboring Favorite / Watchlist / Mark Seen actions.
struct DownloadActionButton: View {
    private let contentId: String
    private let isEpisode: Bool
    private let seriesId: String?
    private let displayTitle: String
    private let displaySubtitle: String?
    private let year: Int?
    private let posterThumbhash: String?
    /// Full version metadata for the options sheet and the large-file guard.
    private let versions: [FileVersion]
    private let selectedVersionFileId: Int?
    private let lastVersionFileId: Int?
    /// Owned by the detail screen so its overflow menu can open the same
    /// options sheet.
    @Binding private var showOptions: Bool

    private var manager: DownloadManager { DownloadManager.shared }
    private var record: DownloadRecord? { manager.record(forContentId: contentId) }
    private var isRegistrationPending: Bool { manager.isRegistering(contentId: contentId) }
    @State private var confirmingCancel = false
    /// Guard text for the pre-download confirmation; non-nil presents it.
    @State private var largeDownloadWarning: String?
    /// Short-lived caption above the button; non-nil shows it.
    @State private var startNotice: String?
    @State private var startFeedbackCount = 0
    @State private var failFeedbackCount = 0

    /// Detail action-row button, driven by the screen's `ItemDetail`.
    init(
        detail: ItemDetail,
        versions: [FileVersion],
        selectedVersionFileId: Int?,
        showOptions: Binding<Bool>
    ) {
        contentId = detail.contentId
        isEpisode = detail.type == "episode"
        seriesId = detail.seriesId
        displayTitle = detail.title
        displaySubtitle = Self.episodeSubtitle(
            seasonNumber: detail.seasonNumber,
            episodeNumber: detail.episodeNumber,
            fallback: detail.seriesTitle
        )
        year = detail.year
        posterThumbhash = detail.posterThumbhash
        self.versions = versions
        self.selectedVersionFileId = selectedVersionFileId
        lastVersionFileId = detail.userData?.lastFileId
        _showOptions = showOptions
    }

    var body: some View {
        // One registry lookup per evaluation; the body re-runs on every
        // progress publish.
        let record = self.record
        content(record: record)
            .overlay(alignment: .top) { noticeCaption }
            .sensoryFeedback(.success, trigger: startFeedbackCount)
            .sensoryFeedback(.error, trigger: failFeedbackCount)
            .sheet(isPresented: $showOptions) {
                DownloadOptionsSheet(
                    title: displayTitle,
                    versions: versions,
                    selectedVersionFileId: selectedVersionFileId,
                    lastVersionFileId: lastVersionFileId,
                    onStart: startDownload
                )
            }
            .confirmationDialog(
                cancelPrompt(for: record),
                isPresented: $confirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Discard Download", role: .destructive, action: delete)
                Button("Keep Download", role: .cancel) {}
            }
            // Keep the large-file gate separate from the cancel menu. Two
            // confirmation dialogs on one control compete for the same SwiftUI
            // presentation host and can consume the tap without showing either.
            .alert(
                "Large Download",
                isPresented: Binding(
                    get: { largeDownloadWarning != nil },
                    set: { if !$0 { largeDownloadWarning = nil } }
                )
            ) {
                Button("Download Anyway", action: startWithDefaults)
                Button("Choose Options…") { showOptions = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(largeDownloadWarning ?? "This download is large.") Download anyway?")
            }
    }

    @ViewBuilder
    private func content(record: DownloadRecord?) -> some View {
        if isRegistrationPending, record == nil {
            circleLabel(icon: "arrow.down.circle", record: record, active: true, showSpinner: true)
                .accessibilityLabel("Registering download")
                .allowsHitTesting(false)
        } else {
            switch record?.localStatus {
            case .none:
                Button(action: handleDownloadTap) {
                    circleLabel(icon: "arrow.down.to.line", record: record, active: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download")
                .contextMenu {
                    Button { showOptions = true } label: {
                        Label("Download Options…", systemImage: "slider.horizontal.3")
                    }
                }

            case .downloading:
                Menu {
                    Button(action: pause) {
                        Label("Pause", systemImage: "pause")
                    }
                    Button(role: .destructive) { confirmingCancel = true } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                } label: {
                    progressLabel(record: record, paused: false)
                }
                .accessibilityLabel("Downloading")
                .accessibilityValue(progressAccessibilityValue(record))

            case .paused:
                Menu {
                    Button(action: resume) {
                        Label("Resume", systemImage: "play")
                    }
                    Button(role: .destructive) { confirmingCancel = true } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                } label: {
                    progressLabel(record: record, paused: true)
                }
                .accessibilityLabel("Download paused")
                .accessibilityValue(progressAccessibilityValue(record))

            case .registering, .preparing, .queued, .fetchingAssets:
                Menu {
                    Button(role: .destructive) { confirmingCancel = true } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                } label: {
                    circleLabel(icon: "arrow.down.circle", record: record, active: true, showSpinner: true)
                }
                .accessibilityLabel("Preparing download")

            case .completed:
                Menu {
                    Button(role: .destructive, action: delete) {
                        Label("Delete Download", systemImage: "trash")
                    }
                } label: {
                    circleLabel(icon: "checkmark.circle.fill", record: record, active: true, tint: .green)
                }
                .accessibilityLabel("Downloaded")

            case .revoked:
                Menu {
                    Button(role: .destructive, action: delete) {
                        Label("Delete Download", systemImage: "trash")
                    }
                } label: {
                    circleLabel(icon: "checkmark.circle", record: record, active: true, tint: .yellow)
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
                    circleLabel(icon: "exclamationmark.triangle", record: record, active: true, tint: .orange)
                }
                .accessibilityLabel("Download failed")
            }
        }
    }

    // MARK: - Actions

    /// One-tap entry: start immediately with defaults unless the size that
    /// would land on disk (the displayed version's size, or the max across
    /// candidates when that size is unknown) warrants confirming first.
    private func handleDownloadTap() {
        guard !isRegistrationPending, record == nil else { return }
        let estimate = DownloadSizeEstimate.estimate(versions: versions, fileId: displayedVersionFileId)
            ?? DownloadSizeEstimate.estimate(fileSizes: versions.compactMap(\.fileSize))
        let available = DownloadFilePaths.availableCapacity()
        if let warning = estimate?.warningMessage(availableBytes: available) {
            largeDownloadWarning = warning
            return
        }
        startWithDefaults()
    }

    /// The version the detail screen displays, with Auto resolved the same
    /// way the selector shows it, + the global Downloads quality preference,
    /// clamped to what the server currently offers.
    private func startWithDefaults() {
        startDownload(DownloadRequestOptions(
            fileId: displayedVersionFileId,
            quality: DownloadSettings.shared.resolvedFormat(
                allowedFormats: manager.capability?.qualityPresets ?? []
            )
        ))
    }

    /// One-tap gives no sheet dismissal to mark the moment, so pair a
    /// success haptic with a short-lived caption above the button.
    private func announceStart() {
        startFeedbackCount += 1
        showNotice("Download started")
    }

    /// A registration that fails before a record exists (offline, 4xx)
    /// surfaces nowhere in Downloads, so the failure must be announced here
    /// or the tap silently evaporates.
    private func announceStartFailure() {
        failFeedbackCount += 1
        showNotice("Couldn't start download")
    }

    private func showNotice(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { startNotice = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeIn(duration: 0.3)) { startNotice = nil }
        }
    }

    private func startDownload(_ options: DownloadRequestOptions) {
        Task {
            do {
                if isEpisode {
                    try await manager.downloadEpisode(
                        seriesId: seriesId ?? contentId,
                        episodeId: contentId,
                        displayTitle: displayTitle,
                        displaySubtitle: displaySubtitle,
                        posterThumbhash: posterThumbhash,
                        fileId: options.fileId,
                        quality: options.quality
                    )
                } else {
                    try await manager.downloadMovie(
                        contentId: contentId,
                        displayTitle: displayTitle,
                        year: year,
                        posterThumbhash: posterThumbhash,
                        fileId: options.fileId,
                        quality: options.quality
                    )
                }
                // Only announce once registration reached the server — a
                // premature "started" over a failed create would be the
                // last the user ever hears of this download.
                announceStart()
            } catch DownloadError.registrationAlreadyInFlight {
                // The original request owns the manager-level Preparing state.
                // Do not announce a second success or replace it with an error.
            } catch {
                announceStartFailure()
            }
        }
    }

    /// Nil when the item has no version metadata; the server then picks
    /// the file.
    private var displayedVersionFileId: Int? {
        DownloadRequestOptions.fileId(
            versions: versions,
            selectedFileId: selectedVersionFileId,
            lastFileId: lastVersionFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private func pause() {
        if let id = record?.id { manager.pauseDownload(id: id) }
    }

    private func resume() {
        if let id = record?.id { manager.resumeDownload(id: id) }
    }

    private func delete() {
        if let id = record?.id { manager.deleteDownload(id: id) }
    }

    /// States what a destructive cancel throws away; bytes are omitted when
    /// nothing has transferred yet.
    private func cancelPrompt(for record: DownloadRecord?) -> String {
        if let bytes = record?.bytesDownloaded, bytes > 0 {
            return "Discard \(DownloadFormatting.bytes(bytes)) of downloaded data?"
        }
        return "Cancel this download?"
    }

    private static func episodeSubtitle(
        seasonNumber: Int?,
        episodeNumber: Int?,
        fallback: String?
    ) -> String? {
        let season = seasonNumber.map { "S\($0)" }
        let episode = episodeNumber.map { "E\($0)" }
        let tag = [season, episode].compactMap { $0 }.joined(separator: " · ")
        return tag.isEmpty ? fallback : tag
    }

    // MARK: - Labels

    @ViewBuilder
    private var noticeCaption: some View {
        if let startNotice {
            Text(startNotice)
                .font(.siloCaption)
                .foregroundColor(.siloOnSurface)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .fixedSize()
                .offset(y: -36)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
        }
    }

    /// Filled, borderless circle over a caption, sized to match
    /// `PhoneLabeledAction` exactly so the row sits on one baseline.
    private func labeledGlyph<Glyph: View>(
        record: DownloadRecord?,
        active: Bool,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        VStack(spacing: 6) {
            glyph()
                .frame(width: 42, height: 42)
                .background(
                    Circle().fill(Color.white.opacity(active ? 0.18 : 0.10))
                )
            Text(captionText(for: record))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(captionTint(for: record?.localStatus))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }

    /// A static "Download" caption under a green tick would misreport the
    /// state, so the caption tracks the record like the glyph does.
    private func captionText(for record: DownloadRecord?) -> String {
        if isRegistrationPending, record == nil { return "Preparing" }
        switch record?.localStatus {
        case .none: return "Download"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .registering, .preparing, .queued, .fetchingAssets: return "Preparing"
        case .completed, .revoked: return "Downloaded"
        case .failed: return "Failed"
        }
    }

    private func captionTint(for status: LocalDownloadStatus?) -> Color {
        switch status {
        case .completed, .revoked: return .green.opacity(0.9)
        case .failed: return .orange.opacity(0.9)
        case .none: return Color.white.opacity(0.6)
        default: return Color.white.opacity(0.85)
        }
    }

    private func circleLabel(
        icon: String,
        record: DownloadRecord?,
        active: Bool,
        tint: Color = .white,
        showSpinner: Bool = false
    ) -> some View {
        labeledGlyph(record: record, active: active) {
            if showSpinner {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(tint)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
        }
    }

    private func progressLabel(record: DownloadRecord?, paused: Bool) -> some View {
        let fraction = record?.progressFraction ?? 0
        return labeledGlyph(record: record, active: true) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(
                        Color.white.opacity(paused ? 0.55 : 1),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                progressCenter(fraction: fraction, paused: paused)
            }
            .frame(width: 21, height: 21)
        }
    }

    @ViewBuilder
    private func progressCenter(fraction: Double, paused: Bool) -> some View {
        if paused {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
        } else {
            Text("\(progressPercent(fraction))")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
        }
    }

    private func progressAccessibilityValue(_ record: DownloadRecord?) -> String {
        "\(progressPercent(record?.progressFraction ?? 0)) percent"
    }

    private func progressPercent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}
#endif
