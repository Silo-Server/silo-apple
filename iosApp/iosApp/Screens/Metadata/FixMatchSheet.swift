#if !os(tvOS)
import SwiftUI

struct FixMatchSheet: View {
    let target: MetadataCurationTarget
    var preloadedDetail: ItemDetail? = nil
    let onMatchApplied: () -> Void

    @State private var viewModel: FixMatchViewModel
    @State private var isExternalIdsExpanded = false
    @State private var isFilesExpanded = false
    @State private var showReplaceConfirmation = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        target: MetadataCurationTarget,
        preloadedDetail: ItemDetail? = nil,
        onMatchApplied: @escaping () -> Void
    ) {
        self.target = target
        self.preloadedDetail = preloadedDetail
        self.onMatchApplied = onMatchApplied
        _viewModel = State(initialValue: FixMatchViewModel(target: target, preloadedDetail: preloadedDetail))
    }

    private var usesSplitLayout: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                compactLayout
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color.siloPrimary)
        .task {
            await viewModel.loadInitial()
        }
        .onDisappear {
            viewModel.cancelPendingWork()
        }
        .alert(
            MetadataStrings.replaceMatchAlertTitle,
            isPresented: $showReplaceConfirmation
        ) {
            Button(MetadataStrings.replaceMatchConfirm, role: .destructive) {
                commitApply()
            }
            Button(MetadataStrings.cancelButton, role: .cancel) {}
        } message: {
            if let candidate = viewModel.selectedCandidate {
                Text(MetadataStrings.replaceMatchMessage(
                    currentTitle: viewModel.currentDisplayTitle,
                    candidate: candidate
                ))
            }
        }
    }

    // MARK: - Compact (iPhone) Layout

    private var compactLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        currentMatchHeader
                        searchControlsCard
                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                        }
                        resultsSection
                    }
                    .padding(16)
                }
                .background(MetadataPalette.sheetCanvas)

                bottomApplyBar
            }
            .navigationTitle(MetadataStrings.fixMatchTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel) { dismiss() }
                        .disabled(viewModel.isApplying)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationBackground(MetadataPalette.sheetCanvas)
        #endif
    }

    // MARK: - Split (iPadOS Regular & macOS) Layout

    private var splitLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text(MetadataStrings.fixMatchTitle)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(MetadataPalette.primaryText)
                            Spacer()
                        }

                        currentMatchHeader
                        searchControlsCard
                    }
                    .padding(18)
                }
                .frame(width: 310)
                .background(MetadataPalette.sidebarCanvas)

                Divider().overlay(MetadataPalette.hairline)

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let error = viewModel.errorMessage {
                                errorBanner(error)
                            }
                            resultsSection
                        }
                        .padding(18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MetadataPalette.sheetCanvas)
                }
            }

            Divider().overlay(MetadataPalette.hairline)

            HStack(spacing: 12) {
                if let candidate = viewModel.selectedCandidate {
                    Text(candidate.year > 0 ? "\(candidate.displayTitle) (\(candidate.year))" : candidate.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MetadataPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button(.commonCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isApplying)
                applyButton
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(MetadataPalette.sidebarCanvas)
        }
        #if os(macOS)
        .frame(minWidth: 780, idealWidth: 880, minHeight: 560, idealHeight: 640)
        #endif
    }

    // MARK: - Shared Sections

    private var currentMatchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let url = viewModel.currentPosterUrl, !url.isEmpty {
                        AsyncImageView(
                            url: url,
                            targetSize: CGSize(width: 44, height: 66),
                            contentMode: .fill
                        )
                    } else {
                        MetadataPalette.elevatedSurface
                            .overlay {
                                Image(systemName: viewModel.effectiveMediaType == "series" ? "tv" : "film")
                                    .foregroundStyle(MetadataPalette.secondaryText)
                            }
                    }
                }
                .frame(width: 44, height: 66)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.isCurrentlyMatched ? MetadataStrings.currentlyMatchedHeader : MetadataStrings.unmatchedLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.isCurrentlyMatched ? MetadataPalette.secondaryText : MetadataPalette.lockedAmber)
                        .textCase(.uppercase)

                    Text(viewModel.currentDisplayTitle)
                        .font(.headline)
                        .foregroundStyle(MetadataPalette.primaryText)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let year = viewModel.currentYear, year > 0 {
                            Text(verbatim: String(year))
                                .font(.caption)
                                .foregroundStyle(MetadataPalette.secondaryText)
                        }
                        ForEach(viewModel.currentExternalIdBadges, id: \.0) { label, value in
                            Text("\(label) \(value)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(MetadataPalette.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if !viewModel.localPaths.isEmpty {
                DisclosureGroup(
                    isExpanded: $isFilesExpanded,
                    content: {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.localPaths, id: \.self) { path in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(path)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(MetadataPalette.secondaryText)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        viewModel.copyPath(path)
                                    } label: {
                                        Text(viewModel.copiedPath == path ? MetadataStrings.copiedPathLabel : MetadataStrings.copyPathLabel)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(MetadataPalette.primaryText)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.10), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.top, 6)
                    },
                    label: {
                        Label(
                            viewModel.effectiveMediaType == "series" && viewModel.itemFiles.isEmpty
                                ? MetadataStrings.localFoldersHeader
                                : MetadataStrings.localFilesHeader,
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MetadataPalette.secondaryText)
                    }
                )
            }
        }
        .padding(12)
        .background(MetadataPalette.cellSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MetadataPalette.hairline, lineWidth: 1)
        )
    }

    private var searchControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.libraryOptions.isEmpty {
                HStack {
                    Text(MetadataStrings.libraryScopeLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MetadataPalette.secondaryText)
                    Spacer()
                    Picker(
                        MetadataStrings.libraryScopeLabel,
                        selection: Binding(
                            get: { viewModel.selectedLibraryId ?? viewModel.libraryOptions.first?.id ?? 0 },
                            set: { viewModel.switchLibrary(to: $0) }
                        )
                    ) {
                        ForEach(viewModel.libraryOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(MetadataPalette.secondaryText)
                    TextField(MetadataStrings.searchTitlePlaceholder, text: $viewModel.queryText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        #endif
                        .onSubmit { viewModel.triggerSearch() }
                    if !viewModel.queryText.isEmpty {
                        Button {
                            viewModel.queryText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MetadataPalette.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                TextField(MetadataStrings.yearPlaceholder, text: $viewModel.yearText)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.center)
                    .frame(width: 68)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit { viewModel.triggerSearch() }
            }

            if let detectedChip = detectedQueryBadge {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                    Text(detectedChip)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(MetadataPalette.lockedAmber)
            }

            DisclosureGroup(MetadataStrings.externalIdsDisclosure, isExpanded: $isExternalIdsExpanded) {
                VStack(spacing: 8) {
                    if viewModel.isVideoItem {
                        idFieldRow(label: MetadataStrings.fieldImdbId, placeholder: "tt15239678", text: $viewModel.imdbIdText)
                        idFieldRow(label: MetadataStrings.fieldTmdbId, placeholder: "693134", text: $viewModel.tmdbIdText)
                        if viewModel.effectiveMediaType == "series" {
                            idFieldRow(label: MetadataStrings.fieldTvdbId, placeholder: "371980", text: $viewModel.tvdbIdText)
                        }
                    } else {
                        ForEach($viewModel.customProviders) { $entry in
                            HStack(spacing: 8) {
                                TextField(MetadataStrings.providerKeyPlaceholder, text: $entry.key)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                TextField(MetadataStrings.providerValuePlaceholder, text: $entry.value)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Button(role: .destructive) {
                                    viewModel.removeCustomProvider(id: entry.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(MetadataPalette.secondaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button {
                            viewModel.addCustomProvider()
                        } label: {
                            Label(MetadataStrings.addProviderIdButton, systemImage: "plus.circle")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(MetadataPalette.secondaryText)

            Button {
                viewModel.triggerSearch()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSearching {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(MetadataStrings.searchButton)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.siloPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSearching || viewModel.isApplying)
        }
        .padding(12)
        .background(MetadataPalette.cellSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MetadataPalette.hairline, lineWidth: 1)
        )
    }

    private var detectedQueryBadge: String? {
        let detected = viewModel.detectedQuery
        if let imdb = detected.imdbId { return "Detected IMDb ID: \(imdb)" }
        if let tmdb = detected.tmdbId { return "Detected TMDB ID: \(tmdb)" }
        if let tvdb = detected.tvdbId { return "Detected TVDB ID: \(tvdb)" }
        return nil
    }

    private func idFieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MetadataPalette.secondaryText)
                .frame(width: 72, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .font(.subheadline.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { viewModel.triggerSearch() }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if viewModel.isLoadingInitial || (viewModel.isSearching && viewModel.candidates.isEmpty) {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color.siloPrimary)
                Text(viewModel.isLoadingInitial ? MetadataStrings.loadingHints : MetadataStrings.searchingMatches)
                    .font(.subheadline)
                    .foregroundStyle(MetadataPalette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else if viewModel.candidates.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(MetadataPalette.secondaryText)
                Text(MetadataStrings.noMatchesTitle)
                    .font(.headline)
                    .foregroundStyle(MetadataPalette.primaryText)
                Text(MetadataStrings.noMatchesMessage)
                    .font(.subheadline)
                    .foregroundStyle(MetadataPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isTruncated {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(MetadataStrings.truncatedResultsNotice)
                    }
                    .font(.caption)
                    .foregroundStyle(MetadataPalette.secondaryText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                ForEach(viewModel.candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: AdminMatchCandidate) -> some View {
        let isSelected = viewModel.selectedCandidate == candidate
        return Button {
            viewModel.selectedCandidate = candidate
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let url = candidate.imageUrl, !url.isEmpty {
                            AsyncImageView(
                                url: url,
                                targetSize: CGSize(width: 54, height: 81),
                                contentMode: .fill
                            )
                        } else {
                            MetadataPalette.elevatedSurface
                                .overlay {
                                    Image(systemName: "film")
                                        .foregroundStyle(MetadataPalette.secondaryText)
                                }
                        }
                    }
                    .frame(width: 54, height: 81)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(candidate.displayTitle)
                                .font(.headline)
                                .foregroundStyle(MetadataPalette.primaryText)
                                .multilineTextAlignment(.leading)

                            if candidate.year > 0 {
                                Text(verbatim: String(candidate.year))
                                    .font(.subheadline)
                                    .foregroundStyle(MetadataPalette.secondaryText)
                            }
                            Spacer(minLength: 4)
                            if let scoreLabel = candidate.formattedMatchScore {
                                Text(scoreLabel)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(isSelected ? Color.black : MetadataPalette.primaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        isSelected ? Color.siloPrimary : Color.white.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                        }

                        if let secondary = candidate.secondaryTitle {
                            Text(secondary)
                                .font(.caption)
                                .foregroundStyle(MetadataPalette.secondaryText)
                                .lineLimit(1)
                        }

                        if let overview = candidate.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.caption)
                                .foregroundStyle(MetadataPalette.secondaryText)
                                .lineLimit(isSelected ? 4 : 2)
                                .multilineTextAlignment(.leading)
                        }

                        HStack(spacing: 6) {
                            ForEach(candidate.sources, id: \.self) { source in
                                Text(source.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(MetadataPalette.primaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.10), in: Capsule())
                            }
                            if let agreements = candidate.agreementHints, !agreements.isEmpty {
                                Text(agreements.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(MetadataPalette.lockedAmber)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                let reasons = candidate.formattedMatchReasons
                if isSelected, !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MetadataStrings.matchReasonsTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MetadataPalette.secondaryText)
                            .textCase(.uppercase)
                        Text(reasons.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(MetadataPalette.primaryText)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.white.opacity(0.10) : MetadataPalette.cellSurface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.siloPrimary : MetadataPalette.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bottomApplyBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(MetadataPalette.hairline)
            applyButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(MetadataPalette.sidebarCanvas)
        }
    }

    private var applyButton: some View {
        Button {
            if viewModel.isCurrentlyMatched {
                showReplaceConfirmation = true
            } else {
                commitApply()
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isApplying {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(
                    viewModel.isApplying
                        ? MetadataStrings.applyingMatch
                        : viewModel.selectedCandidate.map(MetadataStrings.applyMatchButton)
                            ?? MetadataStrings.applyMatchDefault
                )
                .fontWeight(.semibold)
                .lineLimit(1)
            }
            .frame(maxWidth: usesSplitLayout ? nil : .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                viewModel.canApply ? Color.siloPrimary : Color.white.opacity(0.18),
                in: Capsule()
            )
            .foregroundStyle(viewModel.canApply ? Color.black : MetadataPalette.secondaryText)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canApply)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MetadataPalette.destructiveRed)
            Text(message)
                .font(.caption)
                .foregroundStyle(MetadataPalette.primaryText)
            Spacer()
        }
        .padding(10)
        .background(MetadataPalette.destructiveRed.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func commitApply() {
        Task {
            if await viewModel.applySelectedMatch() != nil {
                onMatchApplied()
                dismiss()
            }
        }
    }
}
#endif
