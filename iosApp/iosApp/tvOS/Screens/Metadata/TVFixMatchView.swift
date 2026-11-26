#if os(tvOS)
import SwiftUI

/// Native 10-foot Fix Match candidate picker for Apple TV backed by the shared
/// `FixMatchViewModel` (same multi-library resolution, provider-ID hints, and
/// stale-response guards as iOS/iPadOS/macOS).
struct TVFixMatchView: View {
    private enum FocusTarget: Hashable {
        case library
        case editSearch
        case close
        case retry
        case candidate(String)
    }

    let target: MetadataCurationTarget
    let onMatchApplied: () -> Void

    @State private var viewModel: FixMatchViewModel
    @State private var pendingCandidate: AdminMatchCandidate?
    @State private var isShowingEditSearch = false

    @FocusState private var focused: FocusTarget?
    @Namespace private var screenScope
    @Environment(\.dismiss) private var dismiss

    init(target: MetadataCurationTarget, onMatchApplied: @escaping () -> Void) {
        self.target = target
        self.onMatchApplied = onMatchApplied
        _viewModel = State(initialValue: FixMatchViewModel(target: target))
    }

    private var focusedCandidate: AdminMatchCandidate? {
        guard case .candidate(let id) = focused else { return nil }
        return viewModel.candidates.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                headerBar
                    .padding(.horizontal, 80)
                    .padding(.top, 54)
                    .padding(.bottom, 20)
                    .background(Color.siloBackground)
                    .zIndex(2)

                contentArea
                    .padding(.horizontal, 62)
                    .zIndex(1)

                footerBar
                    .padding(.horizontal, 80)
                    .padding(.top, 18)
                    .padding(.bottom, 44)
                    .background(
                        Color.siloBackground
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 1)
                            }
                    )
                    .zIndex(2)
            }
        }
        .focusScope(screenScope)
        .defaultFocus($focused, .editSearch, priority: .userInitiated)
        .onExitCommand { dismiss() }
        .task {
            await viewModel.loadInitial()
            if let first = viewModel.candidates.first {
                await Task.yield()
                focused = .candidate(first.id)
            }
        }
        .onChange(of: viewModel.candidates.first?.id) { _, newFirstId in
            guard let newFirstId, case .candidate = focused else { return }
            focused = .candidate(newFirstId)
        }
        .onDisappear {
            viewModel.cancelPendingWork()
        }
        .sheet(isPresented: $isShowingEditSearch) {
            TVFixMatchSearchSheet(
                title: $viewModel.queryText,
                year: $viewModel.yearText,
                onSubmit: {
                    isShowingEditSearch = false
                    viewModel.triggerSearch(clearExternalIds: true)
                }
            )
        }
        .alert(
            viewModel.isCurrentlyMatched ? MetadataStrings.replaceMatchAlertTitle : MetadataStrings.applyMatchDefault,
            isPresented: Binding(
                get: { pendingCandidate != nil },
                set: { if !$0 { pendingCandidate = nil } }
            ),
            presenting: pendingCandidate
        ) { candidate in
            Button(viewModel.isCurrentlyMatched ? MetadataStrings.replaceMatchConfirm : MetadataStrings.applyMatchDefault) {
                Task {
                    if await viewModel.applyCandidate(candidate) != nil {
                        onMatchApplied()
                        dismiss()
                    }
                }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: { candidate in
            Text(MetadataStrings.replaceMatchMessage(currentTitle: viewModel.currentDisplayTitle, candidate: candidate))
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MetadataStrings.fixMatchTitle)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(searchSummaryLine)
                    .font(.title3)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 24)

            HStack(spacing: 14) {
                if viewModel.libraryOptions.count > 1,
                   let currentOption = viewModel.libraryOptions.first(where: { $0.id == viewModel.selectedLibraryId })
                    ?? viewModel.libraryOptions.first {
                    tvPill(
                        title: currentOption.name,
                        systemImage: "books.vertical"
                    ) {
                        viewModel.cycleLibrary()
                    }
                    .focused($focused, equals: .library)
                }

                tvPill(
                    title: MetadataStrings.editSearchButton,
                    systemImage: "magnifyingglass"
                ) {
                    isShowingEditSearch = true
                }
                .focused($focused, equals: .editSearch)

                tvPill(
                    title: MetadataStrings.doneButton,
                    systemImage: nil
                ) {
                    dismiss()
                }
                .focused($focused, equals: .close)
            }
        }
        .focusSection()
    }

    private var searchSummaryLine: String {
        let base = viewModel.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let yr = viewModel.yearText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty && !yr.isEmpty { return "\(base) (\(yr))" }
        if !base.isEmpty { return base }
        return viewModel.currentDisplayTitle
    }

    private func tvPill(
        title: String,
        systemImage: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 24, weight: .medium))
            }
        }
        .buttonStyle(TVMetadataPillButtonStyle())
    }

    // MARK: - Candidates Grid

    @ViewBuilder
    private var contentArea: some View {
        if viewModel.isLoadingInitial || (viewModel.isSearching && viewModel.candidates.isEmpty) {
            VStack(spacing: 18) {
                ProgressView()
                Text(viewModel.isLoadingInitial ? MetadataStrings.loadingHints : MetadataStrings.searchingMatches)
                    .font(.title3)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 20) {
                Text(errorMessage)
                    .font(.title3)
                    .foregroundStyle(Color.siloErrorInk)
                    .multilineTextAlignment(.center)
                tvPill(title: MetadataStrings.retryButton, systemImage: "arrow.clockwise") {
                    viewModel.triggerSearch()
                }
                .focused($focused, equals: .retry)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.candidates.isEmpty {
            VStack(spacing: 14) {
                Text(MetadataStrings.noMatchesTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(MetadataStrings.noMatchesMessage)
                    .font(.title3)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 740)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 36), count: 5)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(viewModel.candidates) { candidate in
                        candidateCard(candidate)
                    }
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 18)
            }
            .scrollClipDisabled()
            .clipped()
            .focusSection()
        }
    }

    private func candidateCard(_ candidate: AdminMatchCandidate) -> some View {
        let isFocused = focused == .candidate(candidate.id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return Button {
            guard !viewModel.isApplying,
                  !viewModel.isSearching,
                  viewModel.searchedLibraryId == viewModel.selectedLibraryId else { return }
            pendingCandidate = candidate
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        ZStack {
                            Color.siloSurfaceElevated
                            if let url = candidate.imageUrl, !url.isEmpty {
                                AsyncImageView(url: url, contentMode: .fill)
                            } else {
                                Image(systemName: viewModel.effectiveMediaType == "series" ? "tv" : "film")
                                    .font(.system(size: 44))
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                        }
                    }
                    .clipped()
                    .clipShape(shape)
                    .overlay(
                        shape.strokeBorder(
                            isFocused ? Color.siloPrimary : Color.white.opacity(0.12),
                            lineWidth: isFocused ? 4 : 1.5
                        )
                    )
                    .overlay(alignment: .topTrailing) {
                        if let scoreLabel = candidate.formattedMatchScore {
                            Text(scoreLabel)
                                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.siloPrimary, in: Capsule())
                                .padding(12)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.displayTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if candidate.year > 0 {
                            Text(verbatim: String(candidate.year))
                                .font(.system(size: 19))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        ForEach(candidate.sources.prefix(2), id: \.self) { source in
                            Text(source.uppercased())
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.siloSecondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
        }
        .buttonStyle(TVCardFocusButtonStyle(scale: 1.05))
        .focused($focused, equals: .candidate(candidate.id))
    }

    // MARK: - Live Footer

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isApplying {
                HStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text(MetadataStrings.applyingMatch)
                        .font(.headline)
                        .foregroundStyle(Color.siloOnSurface)
                }
            } else if let candidate = focusedCandidate {
                HStack(spacing: 12) {
                    let yearSuffix = candidate.year > 0 ? "(\(candidate.year))" : ""
                    let candidateHeading = (!yearSuffix.isEmpty && !candidate.displayTitle.contains(yearSuffix))
                        ? "\(candidate.displayTitle) \(yearSuffix)"
                        : candidate.displayTitle
                    Text(candidateHeading)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface)
                    let reasons = candidate.formattedMatchReasons
                    if !reasons.isEmpty {
                        Text("·  \(reasons.joined(separator: " · "))")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.siloStatusWarning)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(MetadataStrings.tvSelectToApplyHint)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.siloSecondaryText)
                }
                if let overview = candidate.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    }
}

// MARK: - Optional 10-Foot Search Edit Sheet

private struct TVFixMatchSearchSheet: View {
    @Binding var title: String
    @Binding var year: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(MetadataStrings.fixMatchTitle) {
                    TextField(MetadataStrings.searchTitlePlaceholder, text: $title)
                    TextField(MetadataStrings.yearPlaceholder, text: $year)
                }
                Section {
                    Button(MetadataStrings.searchButton, action: onSubmit)
                    Button(.commonCancel, role: .cancel) { dismiss() }
                }
            }
            .navigationTitle(MetadataStrings.editSearchButton)
        }
    }
}
#endif
