#if !os(tvOS)
import SwiftUI

/// Series-scope inputs an episode card needs to start a download for one of
/// its episodes; built once per episode rail by the owning detail screen.
struct EpisodeDownloadContext {
    let seriesId: String
    let posterThumbhash: String?
}

/// Per-item download control. Reads the live record straight from
/// `DownloadManager.shared` (an `@Observable` singleton), so it reflects
/// download progress without the detail view model having to thread any
/// state through.
///
/// Two placements share the state machine: the `.regular` style matches the
/// 44pt circle styling of the neighboring favorite / watchlist buttons on
/// the movie / episode detail screen, and the `.compact` style is the small
/// circle drawn over episode-card stills, where a full detail navigation per
/// episode would be the only alternative.
struct DownloadActionButton: View {
    enum Style {
        case regular
        case compact
        /// Bare glyph over a state-derived caption, matching the refined
        /// detail page's named action row. Carries no circular chrome, so it
        /// sits beside Favorite / Watchlist / Mark Seen without looking like
        /// a different species of control.
        case labeled
    }

    /// Card layouts position the compact control over the still's corner,
    /// so they need its footprint at layout time.
    static let compactDiameter: CGFloat = 30

    private let style: Style
    private let contentId: String
    private let isEpisode: Bool
    private let seriesId: String?
    private let displayTitle: String
    private let displaySubtitle: String?
    private let year: Int?
    private let posterThumbhash: String?
    /// Full version metadata for the options sheet; empty in compact style,
    /// which never presents the sheet.
    private let versions: [FileVersion]
    /// Candidate file sizes feeding the pre-download large-file guard.
    private let candidateFileSizes: [Int64]
    private let selectedVersionFileId: Int?
    private let lastVersionFileId: Int?
    /// Owned by the detail screen so its overflow menu can open the same
    /// options sheet — one-tap made the sheet a secondary path, and it must
    /// stay discoverable somewhere visible. Compact placements have no
    /// options sheet, so they bind a constant that never presents.
    @Binding private var showOptions: Bool

    private var manager: DownloadManager { DownloadManager.shared }
    private var record: DownloadRecord? { manager.record(forContentId: contentId) }
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
        showOptions: Binding<Bool>,
        style: Style = .regular
    ) {
        self.style = style
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
        candidateFileSizes = versions.compactMap(\.fileSize)
        self.selectedVersionFileId = selectedVersionFileId
        lastVersionFileId = detail.userData?.lastFileId
        _showOptions = showOptions
    }

    /// Compact episode-card control. Episode list items only carry
    /// `EpisodeFile` metadata, so version options stay on the episode detail
    /// page and the failed state re-runs the same registration instead of
    /// offering the sheet.
    init(episode: EpisodeListItem, context: EpisodeDownloadContext) {
        style = .compact
        contentId = episode.contentId
        isEpisode = true
        seriesId = context.seriesId
        displayTitle = episode.title ?? "Episode \(episode.episodeNumber)"
        displaySubtitle = Self.episodeSubtitle(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            fallback: nil
        )
        year = nil
        posterThumbhash = context.posterThumbhash
        versions = []
        candidateFileSizes = (episode.files ?? []).compactMap(\.fileSize)
        selectedVersionFileId = nil
        lastVersionFileId = nil
        _showOptions = .constant(false)
    }

    var body: some View {
        content
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
                cancelPrompt,
                isPresented: $confirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Discard Download", role: .destructive, action: cancel)
                Button("Keep Download", role: .cancel) {}
            }
            .confirmationDialog(
                "\(largeDownloadWarning ?? "") Download anyway?",
                isPresented: Binding(
                    get: { largeDownloadWarning != nil },
                    set: { if !$0 { largeDownloadWarning = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Download Anyway", action: startWithDefaults)
                if style != .compact {
                    Button("Choose Options…") { showOptions = true }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder
    private var content: some View {
        switch record?.localStatus {
        case .none:
            let button = Button(action: handleDownloadTap) {
                circleLabel(icon: "arrow.down.to.line", active: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download")
            if style != .compact {
                button.contextMenu {
                    Button { showOptions = true } label: {
                        Label("Download Options…", systemImage: "slider.horizontal.3")
                    }
                }
            } else {
                button
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
                progressLabel(fraction: record?.progressFraction ?? 0, paused: false)
            }
            .accessibilityLabel("Downloading")

        case .paused:
            Menu {
                Button(action: resume) {
                    Label("Resume", systemImage: "play")
                }
                Button(role: .destructive) { confirmingCancel = true } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } label: {
                progressLabel(fraction: record?.progressFraction ?? 0, paused: true)
            }
            .accessibilityLabel("Download paused")

        case .registering, .preparing, .queued, .fetchingAssets:
            Menu {
                Button(role: .destructive) { confirmingCancel = true } label: {
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
                if style != .compact {
                    Button { showOptions = true } label: {
                        Label("Retry With Options", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button(action: retry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
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

    /// One-tap entry: start immediately with defaults unless the size that
    /// would land on disk (max of the Auto range, or the exact size of the
    /// selected version) warrants confirming first.
    private func handleDownloadTap() {
        let estimate = versions.isEmpty
            ? DownloadSizeEstimate.estimate(fileSizes: candidateFileSizes)
            : DownloadSizeEstimate.estimate(versions: versions, fileId: selectedVersionFileId)
        let available = DownloadFilePaths.deviceStorage().available
        if let warning = estimate?.warningMessage(availableBytes: available) {
            largeDownloadWarning = warning
            return
        }
        startWithDefaults()
    }

    /// The version picked on the detail screen (Auto when none — matching
    /// what the options sheet preselects) + the global Downloads quality
    /// preference, clamped to what the server currently offers.
    private func startWithDefaults() {
        startDownload(DownloadRequestOptions(
            fileId: selectedVersionFileId,
            quality: DownloadSettings.shared.resolvedFormat(
                allowedFormats: manager.capability?.qualityPresets ?? []
            )
        ))
    }

    /// One-tap gives no sheet dismissal to mark the moment, so pair a
    /// success haptic with a short-lived caption above the button. The
    /// compact style keeps only the haptic — its state flip to the spinner
    /// is visible feedback, and a caption would clip against neighboring
    /// cards in the rail.
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
        guard style != .compact else { return }
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
            } catch {
                announceStartFailure()
            }
        }
    }

    private func pause() {
        if let id = record?.id { manager.pauseDownload(id: id) }
    }

    private func resume() {
        if let id = record?.id { manager.resumeDownload(id: id) }
    }

    private func retry() {
        if let id = record?.id { manager.retryDownload(id: id) }
    }

    private func cancel() {
        if let id = record?.id { manager.deleteDownload(id: id) }
    }

    private func delete() {
        if let id = record?.id { manager.deleteDownload(id: id) }
    }

    /// States what a destructive cancel throws away; bytes are omitted when
    /// nothing has transferred yet.
    private var cancelPrompt: String {
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
                .font(.continuumCaption)
                .foregroundColor(.continuumOnSurface)
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
        tint: Color,
        active: Bool,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        VStack(spacing: 6) {
            glyph()
                .frame(width: 42, height: 42)
                .background(
                    Circle().fill(Color.white.opacity(active ? 0.18 : 0.10))
                )
            Text(captionText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(captionTint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }

    /// A static "Download" caption under a green tick would misreport the
    /// state, so the caption tracks the record like the glyph does.
    private var captionText: String {
        switch record?.localStatus {
        case .none: return "Download"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .registering, .preparing, .queued, .fetchingAssets: return "Preparing"
        case .completed, .revoked: return "Downloaded"
        case .failed: return "Failed"
        default: return "Download"
        }
    }

    private var captionTint: Color {
        switch record?.localStatus {
        case .completed, .revoked: return .green.opacity(0.9)
        case .failed: return .orange.opacity(0.9)
        case .none: return Color.white.opacity(0.6)
        default: return Color.white.opacity(0.85)
        }
    }

    private var diameter: CGFloat {
        style == .regular ? 44 : Self.compactDiameter
    }

    private var iconPointSize: CGFloat {
        style == .regular ? 16 : 12
    }

    /// The regular style sits on the detail hero's dark scrim, so a white
    /// wash reads; the compact style sits directly on episode stills and
    /// needs a darker fill for contrast on bright frames.
    private func circleFill(active: Bool) -> Color {
        switch style {
        case .regular: return Color.white.opacity(active ? 0.18 : 0.10)
        case .compact: return Color.black.opacity(active ? 0.65 : 0.55)
        case .labeled: return .clear
        }
    }

    @ViewBuilder
    private func circleLabel(
        icon: String,
        active: Bool,
        tint: Color = .white,
        showSpinner: Bool = false
    ) -> some View {
        if style == .labeled {
            labeledGlyph(tint: tint, active: active) {
                if showSpinner {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundColor(tint)
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                }
            }
        } else {
            circleChrome(icon: icon, active: active, tint: tint, showSpinner: showSpinner)
        }
    }

    private func circleChrome(
        icon: String,
        active: Bool,
        tint: Color,
        showSpinner: Bool
    ) -> some View {
        ZStack {
            Circle()
                .fill(circleFill(active: active))
                .overlay(
                    Circle().stroke(Color.white.opacity(active ? 0.55 : 0.25), lineWidth: 1)
                )
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: icon)
                    .font(.system(size: iconPointSize, weight: .semibold))
                    .foregroundColor(tint)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func progressLabel(fraction: Double, paused: Bool) -> some View {
        if style == .labeled {
            labeledGlyph(tint: .white, active: true) {
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
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 21, height: 21)
            }
        } else {
            progressChrome(fraction: fraction, paused: paused)
        }
    }

    private func progressChrome(fraction: Double, paused: Bool) -> some View {
        ZStack {
            Circle()
                .fill(circleFill(active: false))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(
                    Color.white.opacity(paused ? 0.55 : 1),
                    style: StrokeStyle(lineWidth: style == .regular ? 2.5 : 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(style == .regular ? 4 : 3)
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: style == .regular ? 10 : 8, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: diameter, height: diameter)
    }
}
#endif
