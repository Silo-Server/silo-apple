import SwiftUI

/// Full-screen detail for a requestable TMDB title: backdrop, poster/meta,
/// ONE server-state-computed primary action, overview, and a "More like
/// this" rail. No confirmation dialog — the button is the confirmation and
/// morphs into the status in place.
///
/// tvOS focus safety: the primary action is a single `Button` whose label
/// and enabled state vary by `RequestPrimaryAction`. It is never swapped
/// for a different view identity mid-morph, so focus stays put across
/// request → submitting → pending.
struct RequestDetailView: View {
    @State private var viewModel: RequestDetailViewModel
    @Environment(AppRouter.self) private var router

    init(mediaType: RequestMediaType, tmdbId: Int) {
        _viewModel = State(initialValue: RequestDetailViewModel(mediaType: mediaType, tmdbId: tmdbId))
    }

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                loadedContent(detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.load() } })
                    .siloPageBackground()
            } else {
                LoadingView(usesPageBackground: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .siloPageBackground()
            }
        }
        .task(id: viewModel.tmdbId) {
            await viewModel.load()
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update {
                viewModel.applyRequestUpdate(update)
            }
        }
        #if !os(tvOS)
        .navigationTitle(viewModel.detail?.title ?? "")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .siloNavigationBarSurfaceBackground()
        #endif
    }

    // MARK: - Layout

    private func loadedContent(_ detail: RequestMediaDetail) -> some View {
        ScrollView {
            #if os(tvOS)
            tvContent(detail)
            #else
            phoneContent(detail)
            #endif
        }
        .siloPageBackground()
        #if os(tvOS)
        .background(alignment: .top) {
            tvBackdrop(detail)
        }
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private func phoneContent(_ detail: RequestMediaDetail) -> some View {
        VStack(alignment: .leading, spacing: SiloTheme.padding) {
            phoneHero(detail)

            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                primaryActionButton(detail)

                if let message = viewModel.actionErrorMessage {
                    actionErrorBanner(message)
                }

                if let overview = detail.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.siloBody)
                        .foregroundColor(.siloSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                recommendationsRail
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.bottom, SiloTheme.largePadding)
        }
    }

    private func phoneHero(_ detail: RequestMediaDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let backdrop = RequestImageURL.build(detail.backdropPath, size: .backdrop) {
                AsyncImageView(url: backdrop, contentMode: .fill)
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [.clear, Color.siloBackground.opacity(0.65), .siloBackground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                Rectangle()
                    .fill(Color.siloSurfaceElevated)
                    .frame(height: 120)
            }

            HStack(alignment: .bottom, spacing: SiloTheme.padding) {
                if let poster = RequestImageURL.build(detail.posterPath, size: .poster) {
                    AsyncImageView(url: poster, contentMode: .fill)
                        .frame(width: 96, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title)
                        .font(.siloTitle)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2)

                    Text(metaLine(detail))
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(2)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, SiloTheme.padding)
            .offset(y: 48)
        }
        .padding(.bottom, 48)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private func tvBackdrop(_ detail: RequestMediaDetail) -> some View {
        Group {
            if let backdrop = RequestImageURL.build(detail.backdropPath, size: .backdrop) {
                AsyncImageView(url: backdrop, contentMode: .fill)
            } else {
                Color.siloSurface
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.72),
                    Color.siloBackground,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }

    private func tvContent(_ detail: RequestMediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 40) {
            Spacer(minLength: 240)

            VStack(alignment: .leading, spacing: 18) {
                Text(eyebrow(detail))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(.siloSecondaryText)

                Text(detail.title)
                    .font(.system(size: 68, weight: .heavy))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(2)

                Text(metaLine(detail))
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)

                if let overview = detail.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.siloBody)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(3)
                        .frame(maxWidth: 980, alignment: .leading)
                }
            }

            HStack(spacing: 24) {
                primaryActionButton(detail)

                if let message = viewModel.actionErrorMessage {
                    Text(message)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                } else if case .request = viewModel.primaryAction {
                    Text("Reviewed by your server admin")
                        .font(.siloSmall)
                        .foregroundColor(.siloSecondaryText.opacity(0.7))
                }
            }
            .focusSection()

            recommendationsRail
                .padding(.bottom, 60)
        }
        .padding(.horizontal, 80)
    }

    private func eyebrow(_ detail: RequestMediaDetail) -> String {
        var parts = ["REQUEST", detail.mediaType.displayName.uppercased()]
        if detail.availability != .available {
            parts.append("NOT IN YOUR LIBRARY")
        }
        return parts.joined(separator: " · ")
    }
    #endif

    // MARK: - Primary action (single Button, morphs in place)

    @ViewBuilder
    private func primaryActionButton(_ detail: RequestMediaDetail) -> some View {
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
            HStack(spacing: buttonContentSpacing) {
                buttonIcon(for: action)
                Text(buttonTitle(for: action))
                    .fontWeight(.bold)
                    .lineLimit(1)
            }
            .font(buttonFont)
            .foregroundColor(buttonForeground(for: action))
            .padding(.horizontal, buttonHPadding)
            .padding(.vertical, buttonVPadding)
            .frame(maxWidth: buttonMaxWidth)
            .background(
                Capsule().fill(action.isInteractive ? Color.siloOnSurface : Color.siloChromeRestingFill)
            )
            .overlay(
                Capsule().stroke(
                    action.isInteractive ? Color.clear : Color.siloChromeRestingBorder,
                    lineWidth: 1
                )
            )
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(.borderless)
        #endif
        .disabled(isButtonDisabled(for: action))
        .accessibilityLabel(buttonTitle(for: action))
        .animation(.easeOut(duration: 0.15), value: action.isInteractive)
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
            Image(systemName: "play.fill")
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
        case .request: viewModel.mediaType == .series ? "Request Series" : "Request Movie"
        case .submitting: "Requesting…"
        case .openInLibrary: "In Your Library · Open"
        case .status(let state): statusTitle(state)
        }
    }

    private func statusTitle(_ state: RequestDisplayState) -> String {
        switch state {
        case .pending: "Requested · Pending"
        case .onTheWay: "On the way"
        case .inLibrary: "In your library"
        case .needsAttention(let reason):
            RequestErrorCopy.message(forToken: reason).map { "Declined · \($0)" } ?? "Needs attention"
        case .unavailable(let reason):
            RequestErrorCopy.message(forToken: reason) ?? "Unavailable"
        }
    }

    private func buttonForeground(for action: RequestPrimaryAction) -> Color {
        action.isInteractive ? .siloBackground : .siloOnSurface
    }

    private func actionErrorBanner(_ message: String) -> some View {
        Text(message)
            .font(.siloCaption)
            .foregroundColor(.siloSecondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationsRail: some View {
        let recommendations = viewModel.recommendations
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
                Text("More like this")
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)

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

    private func metaLine(_ detail: RequestMediaDetail) -> String {
        var parts: [String] = []
        if let year = detail.year, year > 0 { parts.append(String(year)) }
        if let genres = detail.genres, !genres.isEmpty {
            parts.append(genres.prefix(3).joined(separator: ", "))
        }
        if detail.mediaType == .series {
            if let seasons = detail.numberOfSeasons, seasons > 0 {
                parts.append("\(seasons) season\(seasons == 1 ? "" : "s")")
            }
        } else if let runtime = detail.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        if let director = detail.director, !director.isEmpty {
            parts.append(director)
        } else if let creators = detail.creators, !creators.isEmpty {
            parts.append(creators.prefix(2).joined(separator: ", "))
        }
        if let rating = detail.voteAverage, rating > 0 {
            parts.append(String(format: "TMDB %.1f", rating))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Metrics

    private var buttonFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .siloHeadline
        #endif
    }

    private var buttonContentSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        8
        #endif
    }

    private var buttonHPadding: CGFloat {
        #if os(tvOS)
        44
        #else
        20
        #endif
    }

    private var buttonVPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        13
        #endif
    }

    private var buttonMaxWidth: CGFloat? {
        #if os(tvOS)
        nil
        #else
        .infinity
        #endif
    }

    private var statusDotSize: CGFloat {
        #if os(tvOS)
        14
        #else
        8
        #endif
    }

}
