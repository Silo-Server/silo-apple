import SwiftUI

/// Full-screen detail for a requestable TMDB title, built on the same page
/// surfaces as a library title: `PhoneDetailPageSurface` + `PhoneDetailHero`
/// on iOS, `TVDetailPageSurface` + `TVDetailHero` on tvOS. One
/// server-state-computed primary action, a status card with the stage track
/// once a request exists, and a "More like this" rail. No confirmation
/// dialog for requesting — the button is the confirmation and morphs into
/// the status in place.
///
/// tvOS focus safety: the primary action is a single `Button` whose label
/// and enabled state vary by `RequestPrimaryAction`. It is never swapped
/// for a different view identity mid-morph, so focus stays put across
/// request → submitting → pending.
struct RequestDetailView: View {
    @State private var viewModel: RequestDetailViewModel
    @Environment(AppRouter.self) private var router
    @State private var isConfirmingDecline = false
    /// Closes the whole detail card; set when this page is the card's root.
    private let onClose: (() -> Void)?
    #if os(tvOS)
    @FocusState private var primaryFocused: Bool
    #endif
    #if os(iOS)
    @State private var scrollState = PhoneDetailScrollState()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(mediaType: RequestMediaType, tmdbId: Int, onClose: (() -> Void)? = nil) {
        _viewModel = State(initialValue: RequestDetailViewModel(mediaType: mediaType, tmdbId: tmdbId))
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                loadedContent(detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.load() } })
                    .siloPageBackground()
            } else {
                loadingContent
            }
        }
        .task(id: viewModel.tmdbId) {
            await viewModel.load()
        }
        // A cached or provisional first frame settles into the fresh read
        // (and the status into its latest state) instead of popping.
        .animation(.smooth(duration: 0.3), value: viewModel.hasFreshDetail)
        .animation(.smooth(duration: 0.3), value: viewModel.progress)
        .sensoryFeedback(.success, trigger: viewModel.submittedCount)
        .sensoryFeedback(.success, trigger: viewModel.moderatedCount)
        .sensoryFeedback(trigger: viewModel.actionErrorMessage) { _, message in
            guard let message else { return nil }
            // An unconfirmed create, cancel, or decision may still have
            // landed, so it warns.
            let unconfirmed = viewModel.isSubmissionUnconfirmed
                || viewModel.isModerationUnconfirmed
                || message == RequestErrorCopy.unconfirmedCancelMessage
            return unconfirmed ? .warning : .error
        }
        .alert("Decline this request?", isPresented: $isConfirmingDecline) {
            Button("Decline", role: .destructive) {
                Task { await viewModel.moderate(.decline) }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The person who asked for it will see it as declined.")
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update {
                viewModel.applyRequestUpdate(update)
            }
        }
        #if os(iOS)
        // Same card chrome as a library title: controls float over the
        // artwork, and glass fades in behind them as the page scrolls.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topControls }
        #elseif os(macOS)
        .navigationTitle(viewModel.detail?.title ?? "")
        #endif
    }

    @ViewBuilder
    private var loadingContent: some View {
        #if os(tvOS)
        TVItemDetailLoadingView(seed: nil)
        #else
        RequestDetailSkeleton()
            .ignoresSafeArea(edges: .top)
            .siloPageBackground()
        #endif
    }

    private func loadedContent(_ detail: RequestMediaDetail) -> some View {
        #if os(tvOS)
        tvContent(detail)
        #else
        phoneContent(detail)
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private func phoneContent(_ detail: RequestMediaDetail) -> some View {
        let backdrop = RequestImageURL.build(detail.backdropPath, size: .backdrop)
        return PhoneDetailPageSurface(
            backdropURL: backdrop,
            backdropThumbhash: nil,
            enablesArtworkGlass: true
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    PhoneDetailHero(
                        title: detail.title,
                        logoUrl: nil,
                        posterUrl: RequestImageURL.build(detail.posterPath, size: .poster),
                        posterThumbhash: nil,
                        backdropUrl: backdrop,
                        backdropThumbhash: nil,
                        eyebrow: eyebrow,
                        sourceTokens: sourceTokens(detail),
                        ratingChip: detail.contentRating,
                        overview: detail.overview,
                        factsLine: factTokens(detail).map { PhoneHeroFactToken.text($0) },
                        ratings: ratings(detail),
                        creditText: creditText(detail),
                        overlayData: nil,
                        enablesArtworkParallax: true,
                        actions: { phoneActions },
                        belowOverview: { EmptyView() }
                    )

                    recommendationsRail
                        .padding(.horizontal, SiloTheme.padding)
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
            #if os(iOS)
            .detailScrollDismissal()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                return offset <= 150 ? 0 : min(offset, 480)
            } action: { _, offset in
                scrollState.update(offset)
            }
            #endif
        }
    }

    #if os(iOS)
    private var topControls: some View {
        let showsClose = onClose != nil
        let showsBack = !showsClose && (!router.itemDetailPath.isEmpty || !router.path.isEmpty)
        return PhoneDetailTopChrome(
            title: viewModel.detail?.title ?? "",
            isScrollGlassEnabled: UIDevice.current.userInterfaceIdiom == .phone
                && horizontalSizeClass != .regular
                && viewModel.detail != nil,
            scrollState: scrollState,
            leadingSystemName: showsClose ? "xmark" : (showsBack ? "chevron.left" : nil),
            leadingAccessibilityLabel: showsClose ? "Close details" : (showsBack ? "Back" : nil),
            onLeadingTap: {
                if let onClose {
                    onClose()
                } else if !router.itemDetailPath.isEmpty {
                    router.itemDetailPath.removeLast()
                } else {
                    router.goBack()
                }
            },
            trailingSystemName: nil,
            onTrailingTap: nil
        )
    }
    #endif

    @ViewBuilder
    private var phoneActions: some View {
        VStack(spacing: 14) {
            primaryActionButton

            if let message = viewModel.actionErrorMessage {
                Text(message)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if case .request = viewModel.primaryAction, viewModel.endedRequest == nil {
                Text("Not in your library yet. Your server admin reviews requests.")
                    .font(.caption)
                    .foregroundColor(.siloSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if let progress = viewModel.progress, progress.display != .inLibrary {
                RequestStatusCard(progress: progress, record: viewModel.displayedRecord)
            }

            if !viewModel.moderationActions.isEmpty {
                phoneModerationRow
            }

            if viewModel.canCancel {
                Button(role: .destructive) {
                    Task { await viewModel.cancel() }
                } label: {
                    Text("Cancel Request")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.requestRose)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }
    /// Admin decision on someone's request, under their status.
    private var phoneModerationRow: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.moderationActions, id: \.self) { action in
                Button {
                    if action == .decline {
                        isConfirmingDecline = true
                    } else {
                        Task { await viewModel.moderate(action) }
                    }
                } label: {
                    Label(moderationTitle(action), systemImage: moderationIcon(action))
                        .font(.subheadline.weight(action == .decline ? .semibold : .bold))
                        .foregroundStyle(action == .decline ? Color.siloOnSurface : Color.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(action == .decline ? Color.siloChromeSelectedFill : Color.white))
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

    private func moderationTitle(_ action: AdminRequestAction) -> String {
        switch action {
        case .approve: "Approve"
        case .decline: "Decline"
        case .retry: "Retry"
        }
    }

    private func moderationIcon(_ action: AdminRequestAction) -> String {
        switch action {
        case .approve: "checkmark"
        case .decline: "xmark"
        case .retry: "arrow.clockwise"
        }
    }

    // MARK: - tvOS

    #if os(tvOS)
    private func tvContent(_ detail: RequestMediaDetail) -> some View {
        let backdrop = RequestImageURL.build(detail.backdropPath, size: .backdrop)
        return TVDetailPageSurface(backdropURL: backdrop) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TVDetailHero(
                        title: detail.title,
                        logoUrl: nil,
                        backdropUrl: backdrop,
                        backdropThumbhash: nil,
                        eyebrow: eyebrow,
                        sourceTokens: sourceTokens(detail),
                        ratingChip: detail.contentRating,
                        overview: detail.overview,
                        factsLine: factTokens(detail).map { TVHeroFactToken.text($0) },
                        ratings: ratings(detail),
                        starringText: creditText(detail),
                        playbackSummary: TVPlaybackSelectionSummary(version: nil, audio: nil, subtitles: nil),
                        showsPlaybackSummary: false,
                        // The status strip adds ~120pt above the actions;
                        // grow the hero, not the backdrop, so the actions
                        // stay inside its clip.
                        backdropHeight: TVDetailLayout.heroHeight,
                        heroHeight: showsStatusStrip ? TVDetailLayout.heroHeight + 120 : TVDetailLayout.heroHeight,
                        actions: { tvActions },
                        belowSynopsis: { tvStatusStrip }
                    )

                    VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                        recommendationsRail
                    }
                    .padding(.horizontal, TVDetailLayout.horizontalInset)
                    .padding(.bottom, TVDetailLayout.pageBottomPadding)
                }
            }
            .ignoresSafeArea()
            .defaultFocus($primaryFocused, true, priority: .userInitiated)
        }
    }

    private var tvActions: some View {
        HStack(spacing: 18) {
            primaryActionButton
                .focused($primaryFocused)

            ForEach(viewModel.moderationActions, id: \.self) { action in
                if action == .decline {
                    TVSecondaryPillButton(icon: moderationIcon(action), title: moderationTitle(action)) {
                        isConfirmingDecline = true
                    }
                } else {
                    TVPrimaryPillButton(icon: moderationIcon(action), title: moderationTitle(action)) {
                        Task { await viewModel.moderate(action) }
                    }
                }
            }

            if viewModel.canCancel {
                TVSecondaryPillButton(icon: "xmark", title: "Cancel Request") {
                    Task { await viewModel.cancel() }
                }
            }

            if let message = viewModel.actionErrorMessage {
                Text(message)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .focusSection()
    }

    /// The labeled summary under the synopsis, in the playback summary's
    /// VERSION / AUDIO / SUBTITLES grammar, plus the stage track.
    private var showsStatusStrip: Bool {
        guard let progress = viewModel.progress else { return false }
        return progress.display != .inLibrary
    }

    @ViewBuilder
    private var tvStatusStrip: some View {
        if showsStatusStrip, let progress = viewModel.progress {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 8) {
                    summaryField("STATUS", value: progress.longLabel, tint: progress.tint)
                    if let record = viewModel.displayedRecord {
                        summaryField("REQUESTED", value: record.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                        if let quality = RequestTargetSummary.text(for: record.targets)
                            ?? RequestTargetSummary.qualities(for: record.targets) {
                            summaryField("QUALITY", value: quality)
                        }
                    }
                }
                RequestStepTrackWithLabels(progress: progress)
                    .frame(width: 840)
            }
            .padding(.top, 14)
        }
    }

    private func summaryField(_ label: String, value: String, tint: RequestStatusTint? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.42))
            HStack(spacing: 10) {
                if let tint {
                    Circle().fill(tint.color).frame(width: 11, height: 11)
                }
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .frame(width: 300, alignment: .leading)
    }
    #endif

    // MARK: - Primary action (single Button, morphs in place)

    @ViewBuilder
    private var primaryActionButton: some View {
        let action = viewModel.primaryAction

        Button {
            switch action {
            case .request:
                Task { await viewModel.submitRequest() }
            case .openInLibrary(let contentId):
                router.navigate(to: .itemDetail(contentId: contentId))
            case .loading, .submitting, .status:
                break
            }
        } label: {
            primaryLabel(for: action)
        }
        #if os(tvOS)
        .buttonStyle(TVPillButtonStyle(kind: action.isInteractive ? .primary : .secondary, focusTreatment: .compact))
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isButtonDisabled(for: action))
        .accessibilityLabel(buttonTitle(for: action))
        .animation(.easeOut(duration: 0.15), value: action.isInteractive)
    }

    @ViewBuilder
    private func primaryLabel(for action: RequestPrimaryAction) -> some View {
        #if os(tvOS)
        HStack(spacing: 14) {
            buttonIcon(for: action)
            Text(buttonTitle(for: action))
                .lineLimit(1)
        }
        .font(.system(size: 28, weight: .semibold))
        .padding(.horizontal, 40)
        #else
        HStack(spacing: 9) {
            buttonIcon(for: action)
            Text(buttonTitle(for: action))
                .lineLimit(1)
        }
        .font(.body.weight(.semibold))
        .foregroundColor(action.isInteractive ? .black : .siloOnSurface)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            Capsule().fill(action.isInteractive ? Color.white : Color.siloChromeRestingFill)
        )
        .overlay(
            Capsule().stroke(action.isInteractive ? Color.clear : Color.siloChromeRestingBorder, lineWidth: 1)
        )
        .contentShape(Capsule())
        #endif
    }

    /// tvOS keeps the CTA enabled even in non-interactive states — a
    /// disabled Button drops out of the focus graph, which would yank focus
    /// mid-morph after a submit (the exact drop the single-Button design
    /// exists to prevent). The action closure already ignores presses in
    /// non-interactive states, so the button is inert but focusable.
    private func isButtonDisabled(for action: RequestPrimaryAction) -> Bool {
        #if os(tvOS)
        false
        #else
        !action.isInteractive
        #endif
    }

    @ViewBuilder
    private func buttonIcon(for action: RequestPrimaryAction) -> some View {
        switch action {
        case .request:
            Image(systemName: "plus")
        case .submitting:
            ProgressView()
                .controlSize(.small)
                .tint(.siloSecondaryText)
        case .openInLibrary:
            Image(systemName: "arrow.up.right")
        case .status(let state):
            Circle()
                .fill(state.tint.color)
                .frame(width: statusDotSize, height: statusDotSize)
        case .loading:
            EmptyView()
        }
    }

    private func buttonTitle(for action: RequestPrimaryAction) -> String {
        switch action {
        case .loading: ""
        case .request: viewModel.endedRequest == nil ? "Request" : "Request Again"
        case .submitting: "Requesting…"
        case .openInLibrary: "Open in Library"
        case .status(let state):
            viewModel.progress.map { state == $0.display && state != .pending ? $0.longLabel : state.detailTitle }
                ?? state.detailTitle
        }
    }

    private var statusDotSize: CGFloat {
        #if os(tvOS)
        14
        #else
        9
        #endif
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationsRail: some View {
        let recommendations = viewModel.recommendations
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
                RequestsSectionHeader(title: "More like this")

                RequestCardRail(items: recommendations) { result in
                    RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    // MARK: - Meta helpers

    /// Where the title stands, in the slot a library title uses for its
    /// editorial eyebrow.
    private var eyebrow: String? {
        if viewModel.moderationRecord != nil, viewModel.openedForModeration || viewModel.record == nil {
            return "Requested by someone on this server"
        }
        guard let display = viewModel.progress?.display else { return "Not in your library" }
        return display == .inLibrary ? nil : "Requested"
    }

    private func sourceTokens(_ detail: RequestMediaDetail) -> [String] {
        (detail.genres ?? []).prefix(3).map { $0 }
    }

    private func factTokens(_ detail: RequestMediaDetail) -> [String] {
        var parts: [String] = []
        if let year = detail.year, year > 0 { parts.append(String(year)) }
        if detail.mediaType == .series {
            if let seasons = detail.numberOfSeasons, seasons > 0 {
                parts.append("\(seasons) season\(seasons == 1 ? "" : "s")")
            }
        } else if let runtime = MediaTextFormatting.runtime(minutes: detail.runtime) {
            parts.append(runtime)
        }
        // The TMDB score renders as a rating entry (logo + score), not text.
        return parts
    }

    /// Requests carry only TMDB's vote average, shown like a title page's
    /// TMDB rating.
    private func ratings(_ detail: RequestMediaDetail) -> [DisplayRating] {
        DisplayRating.tmdb(detail.voteAverage).map { [$0] } ?? []
    }

    private func creditText(_ detail: RequestMediaDetail) -> String? {
        if let director = detail.director, !director.isEmpty {
            return "Directed by \(director)"
        }
        if let creators = detail.creators, !creators.isEmpty {
            return "Created by \(creators.prefix(2).joined(separator: ", "))"
        }
        return nil
    }
}

// MARK: - Status card

/// The four request steps with their timestamps, under the primary action.
struct RequestStatusCard: View {
    let progress: RequestProgress
    let record: MediaRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("REQUEST STATUS")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundColor(.siloOnSurface.opacity(0.55))
                .padding(.bottom, 14)

            ForEach(RequestStep.allCases, id: \.self) { step in
                stepRow(step, isLast: step == .library)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func stepRow(_ step: RequestStep, isLast: Bool) -> some View {
        let isDone = step.rawValue < progress.completedSteps
        let isCurrent = step == progress.currentStep
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker(isDone: isDone, isCurrent: isCurrent)
                if !isLast {
                    Rectangle()
                        .fill(isDone ? Color.siloOnSurface.opacity(0.6) : Color.white.opacity(0.14))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: step, isCurrent: isCurrent))
                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                    .foregroundColor(isDone || isCurrent ? .siloOnSurface : .siloOnSurface.opacity(0.45))
                if let detail = detail(for: step, isDone: isDone, isCurrent: isCurrent) {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.siloSecondaryText)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func marker(isDone: Bool, isCurrent: Bool) -> some View {
        if isDone {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.black)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.siloOnSurface.opacity(0.9)))
        } else if isCurrent {
            Circle()
                .fill(progress.tint.color)
                .frame(width: 9, height: 9)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(progress.tint.color, lineWidth: 2))
        } else {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
                .frame(width: 22, height: 22)
        }
    }

    /// The current step reads as what's happening now: "Declined" instead
    /// of "Approved", "Queued" instead of "Downloading".
    private func title(for step: RequestStep, isCurrent: Bool) -> String {
        guard isCurrent else { return step.title }
        switch progress.display {
        case .needsAttention, .onTheWay: return progress.shortLabel
        default: return step.title
        }
    }

    private func detail(for step: RequestStep, isDone: Bool, isCurrent: Bool) -> String? {
        switch step {
        case .requested:
            return record.map { Self.timestamp($0.createdAt) }
        case .approval:
            if isDone, let approved = record?.approvedAt { return Self.timestamp(approved) }
            if isCurrent {
                if case .needsAttention(_, let reason) = progress.display {
                    return RequestErrorCopy.message(forToken: reason)
                }
                return "Waiting for your server admin"
            }
            return nil
        case .download:
            guard isCurrent || isDone else { return nil }
            if case .needsAttention(_, let reason) = progress.display, isCurrent {
                return RequestErrorCopy.message(forToken: reason)
            }
            return RequestTargetSummary.text(for: record?.targets)
        case .library:
            return isCurrent ? "Your library is picking it up" : nil
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Stage track with the step names under it, for the tvOS detail page.
struct RequestStepTrackWithLabels: View {
    let progress: RequestProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RequestStageTrack(progress: progress)
            HStack(spacing: 0) {
                ForEach(RequestStep.allCases, id: \.self) { step in
                    Text(step.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color(for: step))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.longLabel)
    }

    private func color(for step: RequestStep) -> Color {
        if step == progress.currentStep { return progress.tint.color }
        if step.rawValue < progress.completedSteps { return .siloOnSurface }
        return .siloOnSurface.opacity(0.45)
    }
}

/// Detail layout shared by the page and its loading skeleton.
enum RequestDetailLayout {
    static let heroHeight: CGFloat = 330
}
