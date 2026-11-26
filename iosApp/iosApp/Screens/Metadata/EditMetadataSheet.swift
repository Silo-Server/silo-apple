#if os(iOS)
import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
final class EditMetadataViewModel {
    enum SidebarSection: String, CaseIterable, Identifiable {
        case general
        case datesRatings
        case tags
        case externalIds
        case locks
        case translate

        var id: String { rawValue }
    }

    let target: MetadataCurationTarget

    private(set) var original: ItemDetail?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var isResetting = false
    private(set) var errorMessage: String?

    // Draft fields
    var title = ""
    var sortTitle = ""
    var originalTitle = ""
    var tagline = ""
    var overview = ""
    var contentRating = ""
    var yearText = ""
    var runtimeText = ""
    var seasonNumberText = ""
    var episodeNumberText = ""

    var releaseDate = ""
    var firstAirDate = ""
    var lastAirDate = ""
    var airDate = ""
    var airTime = ""
    var airTimezone = ""

    var ratingImdb = ""
    var ratingTmdb = ""
    var ratingRtCritic = ""
    var ratingRtAudience = ""

    var genres: [String] = []
    var studios: [String] = []
    var networks: [String] = []
    var countries: [String] = []

    var imdbId = ""
    var tmdbId = ""
    var tvdbId = ""

    // Field lock state
    private(set) var originalLocks: Set<MetadataFieldLock> = []
    /// Lock IDs stored on the server that this editor does not expose (e.g.
    /// `FieldCast=4`, `FieldCrew=5`, `FieldVideos=12`, or future server IDs).
    /// Always preserved when saving `locked_fields` so unrelated edits never
    /// silently wipe them.
    private(set) var preservedUnknownLockIds: Set<Int> = []
    var lockedFields: Set<MetadataFieldLock> = []
    /// Tracks explicit user lock toggles so auto-lock on edit respects manual unlock.
    private var explicitLockOverrides: Set<MetadataFieldLock> = []

    /// Initial rendered strings for floating-point rating fields so untouched
    /// scores never look dirty due to decimal formatting.
    private var initialRatingImdbText = ""
    private var initialRatingTmdbText = ""

    // AI Translation state
    var translateLanguage = ""
    var translateForce = false
    private(set) var isStartingTranslation = false
    private(set) var activeTranslationJob: AdminMetadataTranslationJob?
    private(set) var translationFeedback: String?
    @ObservationIgnored private var translationPollTask: Task<Void, Never>?

    var translationLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(for: .catalogMetadataLanguage)
            .filter { $0.code != PlaybackPrefSentinel.originalLanguage }
    }

    init(target: MetadataCurationTarget, preloadedDetail: ItemDetail?) {
        self.target = target
        self.translateLanguage = PlaybackLanguageOption.options(for: .catalogMetadataLanguage)
            .first(where: { $0.code != PlaybackPrefSentinel.originalLanguage })?.code ?? "en"
        if let preloadedDetail {
            self.original = preloadedDetail
            self.isLoading = false
            populateDraft(from: preloadedDetail)
        }
    }

    var mediaType: String {
        if let original { return MetadataCurationTarget.normalizedType(original.type) }
        return target.mediaType
    }

    var isMovie: Bool { mediaType == "movie" }
    var isSeries: Bool { mediaType == "series" }
    var isSeason: Bool { mediaType == "season" }
    var isEpisode: Bool { mediaType == "episode" }
    var isMovieOrSeries: Bool { isMovie || isSeries }

    var supportedLocks: [MetadataFieldLock] {
        MetadataFieldLock.supportedLocks(for: mediaType)
    }

    var availableSections: [SidebarSection] {
        var sections: [SidebarSection] = [.general, .datesRatings]
        if isMovieOrSeries {
            sections.append(.tags)
            sections.append(.externalIds)
        } else if isEpisode {
            sections.append(.externalIds)
        }
        if !supportedLocks.isEmpty {
            sections.append(.locks)
        }
        if AICapabilities.shared.metadataEnabled {
            sections.append(.translate)
        }
        return sections
    }

    var effectiveLocks: Set<MetadataFieldLock> {
        effectiveLocks(for: computeFieldDiff())
    }

    var hasUnsavedChanges: Bool {
        guard original != nil else { return false }
        let diff = computeFieldDiff()
        if !diff.patch.isEmpty || diff.validationError != nil { return true }
        return effectiveLocks(for: diff) != originalLocks
    }

    var validationError: String? {
        computeFieldDiff().validationError
    }

    func loadIfNeeded() async {
        if original != nil {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await SiloAPI.shared.itemDetail(
                contentId: target.contentId,
                libraryId: target.libraryId
            )
            original = fetched
            populateDraft(from: fetched)
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
        }
        isLoading = false
    }

    func isLocked(_ lock: MetadataFieldLock) -> Bool {
        effectiveLocks.contains(lock)
    }

    func toggleLock(_ lock: MetadataFieldLock) {
        let next = !isLocked(lock)
        explicitLockOverrides.insert(lock)
        if next {
            lockedFields.insert(lock)
        } else {
            lockedFields.remove(lock)
        }
    }

    func setAllLocks(_ locked: Bool) {
        for lock in supportedLocks {
            explicitLockOverrides.insert(lock)
            if locked {
                lockedFields.insert(lock)
            } else {
                lockedFields.remove(lock)
            }
        }
    }

    func buildPatch() -> AdminItemMetadataPatch {
        buildPatch(from: computeFieldDiff())
    }

    private func effectiveLocks(for diff: FieldDiffResult) -> Set<MetadataFieldLock> {
        var result = lockedFields
        for lock in diff.changedLocks where !explicitLockOverrides.contains(lock) {
            result.insert(lock)
        }
        return result
    }

    private func buildPatch(from diff: FieldDiffResult) -> AdminItemMetadataPatch {
        var patch = diff.patch
        let finalLocks = effectiveLocks(for: diff)
        if finalLocks != originalLocks {
            // Preserve lock IDs the server stores for non-edited groups (cast, crew, videos, …).
            let mergedIds = Set(finalLocks.map(\.rawValue)).union(preservedUnknownLockIds)
            patch.lockedFields = mergedIds.sorted()
        }
        return patch
    }

    func save() async -> Bool {
        let diff = computeFieldDiff()
        if let validationError = diff.validationError {
            errorMessage = validationError
            return false
        }
        let patch = buildPatch(from: diff)
        guard !patch.isEmpty else { return true }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let updated = try await SiloAPI.shared.apiV2Client.updateAdminItemMetadata(
                id: target.contentId,
                patch: patch
            )
            original = updated
            populateDraft(from: updated)
            MetadataCurationCache.invalidateAfterMutation(
                contentId: target.contentId,
                seriesId: target.seriesId
            )
            return true
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
            return false
        }
    }

    func resetToProvider() async -> Bool {
        isResetting = true
        errorMessage = nil
        defer { isResetting = false }

        do {
            let unlockPatch = AdminItemMetadataPatch(lockedFields: [])
            _ = try await SiloAPI.shared.apiV2Client.updateAdminItemMetadata(
                id: target.contentId,
                patch: unlockPatch
            )
            MetadataCurationCache.invalidateAfterMutation(
                contentId: target.contentId,
                seriesId: target.seriesId
            )
            return true
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
            return false
        }
    }

    func startTranslation() async {
        guard !translateLanguage.isEmpty else { return }
        isStartingTranslation = true
        translationFeedback = nil
        errorMessage = nil
        defer { isStartingTranslation = false }

        do {
            let job = try await SiloAPI.shared.apiV2Client.translateAdminItemMetadata(
                id: target.contentId,
                request: AdminTranslateMetadataRequest(
                    targetLanguage: translateLanguage,
                    includeChildren: isSeries,
                    force: translateForce
                )
            )
            activeTranslationJob = job
            pollTranslationJobs()
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
        }
    }

    func cancelBackgroundTasks() {
        translationPollTask?.cancel()
        translationPollTask = nil
    }

    // MARK: - Private Helpers

    private func populateDraft(from detail: ItemDetail) {
        title = detail.title
        sortTitle = detail.sortTitle ?? ""
        originalTitle = detail.originalTitle ?? ""
        tagline = detail.tagline ?? ""
        overview = detail.overview ?? ""
        contentRating = detail.contentRating ?? ""
        yearText = (detail.year ?? 0) > 0 ? String(detail.year!) : ""
        runtimeText = (detail.runtime ?? 0) > 0 ? String(detail.runtime!) : ""
        seasonNumberText = detail.seasonNumber.map(String.init) ?? ""
        episodeNumberText = detail.episodeNumber.map(String.init) ?? ""

        releaseDate = detail.releaseDate ?? ""
        firstAirDate = detail.firstAirDate ?? ""
        lastAirDate = detail.lastAirDate ?? ""
        airDate = detail.airDate ?? ""
        airTime = detail.airTime ?? ""
        airTimezone = detail.airTimezone ?? ""

        ratingImdb = Self.formatDecimal(detail.ratingImdb)
        ratingTmdb = Self.formatDecimal(detail.ratingTmdb)
        initialRatingImdbText = ratingImdb
        initialRatingTmdbText = ratingTmdb
        ratingRtCritic = detail.ratingRtCritic.map(String.init) ?? ""
        ratingRtAudience = detail.ratingRtAudience.map(String.init) ?? ""

        genres = detail.genres ?? []
        studios = detail.studios ?? []
        networks = detail.networks ?? []
        countries = detail.countries ?? []

        imdbId = detail.imdbId ?? ""
        tmdbId = detail.tmdbId ?? ""
        tvdbId = detail.tvdbId ?? ""

        let rawLockIds = detail.lockedFields ?? []
        var known: Set<MetadataFieldLock> = []
        var unknown: Set<Int> = []
        for raw in rawLockIds {
            if let lock = MetadataFieldLock(rawValue: raw) {
                known.insert(lock)
            } else {
                unknown.insert(raw)
            }
        }
        originalLocks = known
        preservedUnknownLockIds = unknown
        lockedFields = known
        explicitLockOverrides = []
    }

    private struct FieldDiffResult {
        var patch = AdminItemMetadataPatch()
        var changedLocks: Set<MetadataFieldLock> = []
        var validationError: String?
    }

    /// Single source of truth computing both the outgoing PATCH payload and
    /// the auto-locked field groups so the two can never drift apart.
    private func computeFieldDiff() -> FieldDiffResult {
        guard let orig = original else { return FieldDiffResult() }
        var result = FieldDiffResult()

        func markLock(_ field: String) {
            if let lock = MetadataFieldLock.lock(forFieldKey: field, mediaType: mediaType) {
                result.changedLocks.insert(lock)
            }
        }

        if title != orig.title {
            result.patch.title = title
            markLock("title")
        }
        if overview != (orig.overview ?? "") {
            result.patch.overview = overview
            markLock("overview")
        }

        if isMovieOrSeries {
            if sortTitle != (orig.sortTitle ?? "") {
                result.patch.sortTitle = sortTitle
                markLock("sort_title")
            }
            if originalTitle != (orig.originalTitle ?? "") {
                result.patch.originalTitle = originalTitle
                markLock("original_title")
            }
            if tagline != (orig.tagline ?? "") {
                result.patch.tagline = tagline
                markLock("tagline")
            }
            if contentRating != (orig.contentRating ?? "") {
                result.patch.contentRating = contentRating
                markLock("content_rating")
            }

            let yearDiff = diffZeroableInt(yearText, original: orig.year, fieldName: MetadataStrings.fieldYear)
            if let err = yearDiff.error { result.validationError = result.validationError ?? err }
            if let yearValue = yearDiff.value {
                result.patch.year = yearValue
                markLock("year")
            }

            if genres != (orig.genres ?? []) {
                result.patch.genres = genres
                markLock("genres")
            }
            if studios != (orig.studios ?? []) {
                result.patch.studios = studios
                markLock("studios")
            }
            if isSeries, networks != (orig.networks ?? []) {
                result.patch.networks = networks
                markLock("networks")
            }
            if countries != (orig.countries ?? []) {
                result.patch.countries = countries
                markLock("countries")
            }

            let imdbDiff = diffDouble(
                ratingImdb,
                initialText: initialRatingImdbText,
                original: orig.ratingImdb,
                fieldName: MetadataStrings.fieldRatingImdb
            )
            if let err = imdbDiff.error { result.validationError = result.validationError ?? err }
            result.patch.ratingImdb = imdbDiff.patch
            if imdbDiff.patch.isChanged { markLock("rating_imdb") }

            let tmdbDiff = diffDouble(
                ratingTmdb,
                initialText: initialRatingTmdbText,
                original: orig.ratingTmdb,
                fieldName: MetadataStrings.fieldRatingTmdb
            )
            if let err = tmdbDiff.error { result.validationError = result.validationError ?? err }
            result.patch.ratingTmdb = tmdbDiff.patch
            if tmdbDiff.patch.isChanged { markLock("rating_tmdb") }

            let criticDiff = diffInt(ratingRtCritic, original: orig.ratingRtCritic, fieldName: MetadataStrings.fieldRatingRtCritic)
            if let err = criticDiff.error { result.validationError = result.validationError ?? err }
            result.patch.ratingRtCritic = criticDiff.patch
            if criticDiff.patch.isChanged { markLock("rating_rt_critic") }

            let audienceDiff = diffInt(ratingRtAudience, original: orig.ratingRtAudience, fieldName: MetadataStrings.fieldRatingRtAudience)
            if let err = audienceDiff.error { result.validationError = result.validationError ?? err }
            result.patch.ratingRtAudience = audienceDiff.patch
            if audienceDiff.patch.isChanged { markLock("rating_rt_audience") }
        }

        if isMovie || isEpisode {
            let runtimeDiff = diffZeroableInt(runtimeText, original: orig.runtime, fieldName: MetadataStrings.fieldRuntime)
            if let err = runtimeDiff.error { result.validationError = result.validationError ?? err }
            if let runtimeValue = runtimeDiff.value {
                result.patch.runtime = runtimeValue
                markLock("runtime")
            }
        }

        if isMovie {
            result.patch.releaseDate = diffNullableString(releaseDate, original: orig.releaseDate)
            if result.patch.releaseDate.isChanged { markLock("release_date") }
        } else if isSeries {
            result.patch.firstAirDate = diffNullableString(firstAirDate, original: orig.firstAirDate)
            if result.patch.firstAirDate.isChanged { markLock("first_air_date") }
            result.patch.lastAirDate = diffNullableString(lastAirDate, original: orig.lastAirDate)
            if result.patch.lastAirDate.isChanged { markLock("last_air_date") }
            result.patch.airTime = diffNullableString(airTime, original: orig.airTime)
            if result.patch.airTime.isChanged { markLock("air_time") }
            result.patch.airTimezone = diffNullableString(airTimezone, original: orig.airTimezone)
            if result.patch.airTimezone.isChanged { markLock("air_timezone") }
        } else if isSeason || isEpisode {
            result.patch.airDate = diffNullableString(airDate, original: orig.airDate)
            if result.patch.airDate.isChanged { markLock("air_date") }
        }

        if isSeason || isEpisode {
            let seasonDiff = diffRequiredInt(seasonNumberText, original: orig.seasonNumber, fieldName: MetadataStrings.fieldSeasonNumber)
            if let err = seasonDiff.error { result.validationError = result.validationError ?? err }
            result.patch.seasonNumber = seasonDiff.value
        }
        if isEpisode {
            let epDiff = diffRequiredInt(episodeNumberText, original: orig.episodeNumber, fieldName: MetadataStrings.fieldEpisodeNumber)
            if let err = epDiff.error { result.validationError = result.validationError ?? err }
            result.patch.episodeNumber = epDiff.value
        }

        if isMovieOrSeries || isEpisode {
            if imdbId.trimmed != (orig.imdbId ?? "") { result.patch.imdbId = imdbId.trimmed }
            if tmdbId.trimmed != (orig.tmdbId ?? "") { result.patch.tmdbId = tmdbId.trimmed }
            if isSeries || isEpisode {
                if tvdbId.trimmed != (orig.tvdbId ?? "") { result.patch.tvdbId = tvdbId.trimmed }
            }
        }

        return result
    }

    private func diffNullableString(_ draft: String, original: String?) -> NullablePatch<String> {
        let clean = draft.trimmed
        let orig = (original ?? "").trimmed
        guard clean != orig else { return .unchanged }
        return clean.isEmpty ? .clear : .set(clean)
    }

    private func diffDouble(
        _ draft: String,
        initialText: String,
        original: Double?,
        fieldName: String
    ) -> (patch: NullablePatch<Double>, error: String?) {
        let clean = draft.trimmed
        if clean == initialText { return (.unchanged, nil) }
        if clean.isEmpty {
            return (original == nil ? .unchanged : .clear, nil)
        }
        guard let parsed = Double(clean), parsed.isFinite else {
            return (.unchanged, MetadataStrings.invalidNumberError(fieldName))
        }
        if parsed == original { return (.unchanged, nil) }
        return (.set(parsed), nil)
    }

    /// Clearable nullable integer ratings (`rating_rt_critic`, `rating_rt_audience`).
    private func diffInt(
        _ draft: String,
        original: Int?,
        fieldName: String
    ) -> (patch: NullablePatch<Int>, error: String?) {
        let clean = draft.trimmed
        if clean.isEmpty {
            return (original == nil ? .unchanged : .clear, nil)
        }
        guard let parsed = Int(clean) else {
            return (.unchanged, MetadataStrings.invalidNumberError(fieldName))
        }
        if parsed == original { return (.unchanged, nil) }
        return (.set(parsed), nil)
    }

    /// Server non-nullable integer columns (`year`, `runtime`) where `0` clears
    /// the stored value (see `silo-server/internal/catalog/update.go`).
    private func diffZeroableInt(
        _ draft: String,
        original: Int?,
        fieldName: String
    ) -> (value: Int?, error: String?) {
        let orig = original ?? 0
        let clean = draft.trimmed
        if clean.isEmpty {
            return orig == 0 ? (nil, nil) : (0, nil)
        }
        guard let parsed = Int(clean), parsed >= 0 else {
            return (nil, MetadataStrings.invalidNumberError(fieldName))
        }
        return parsed == orig ? (nil, nil) : (parsed, nil)
    }

    /// Server non-nullable structural numbers (`season_number`, `episode_number`)
    /// that cannot be cleared to NULL.
    private func diffRequiredInt(
        _ draft: String,
        original: Int?,
        fieldName: String
    ) -> (value: Int?, error: String?) {
        let clean = draft.trimmed
        if clean.isEmpty {
            return original == nil ? (nil, nil) : (nil, MetadataStrings.invalidNumberError(fieldName))
        }
        guard let parsed = Int(clean), parsed >= 0 else {
            return (nil, MetadataStrings.invalidNumberError(fieldName))
        }
        return parsed == original ? (nil, nil) : (parsed, nil)
    }

    /// Formats stored rating scores losslessly (e.g., `8.24` stays `"8.24"`,
    /// `8.0` renders as `"8"` or `"8.0"` without rounding away decimals).
    static func formatDecimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(value)
    }

    private func pollTranslationJobs() {
        translationPollTask?.cancel()
        translationPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let jobs = try? await SiloAPI.shared.apiV2Client.adminMetadataTranslationJobs(id: self.target.contentId) else {
                    continue
                }
                if let running = jobs.first(where: \.isActive) {
                    self.activeTranslationJob = running
                } else if let latest = jobs.first {
                    self.activeTranslationJob = nil
                    if latest.status == "completed" {
                        let done = latest.fieldsDone ?? 0
                        self.translationFeedback = done == 0
                            ? "Nothing needed translation."
                            : "Translated \(done) field\(done == 1 ? "" : "s")."
                        MetadataCurationCache.invalidateAfterMutation(
                            contentId: self.target.contentId,
                            seriesId: self.target.seriesId
                        )
                    } else if latest.status == "failed" {
                        self.translationFeedback = latest.errorMessage ?? "Translation failed."
                    }
                    return
                } else {
                    self.activeTranslationJob = nil
                    return
                }
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - View

struct EditMetadataSheet: View {
    let target: MetadataCurationTarget
    var preloadedDetail: ItemDetail? = nil
    let onSaved: () -> Void
    let onResetAndRefresh: () -> Void

    @State private var viewModel: EditMetadataViewModel
    @State private var selectedSection: EditMetadataViewModel.SidebarSection = .general
    @State private var showDiscardDialog = false
    @State private var showResetAlert = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        target: MetadataCurationTarget,
        preloadedDetail: ItemDetail? = nil,
        onSaved: @escaping () -> Void,
        onResetAndRefresh: @escaping () -> Void
    ) {
        self.target = target
        self.preloadedDetail = preloadedDetail
        self.onSaved = onSaved
        self.onResetAndRefresh = onResetAndRefresh
        _viewModel = State(initialValue: EditMetadataViewModel(target: target, preloadedDetail: preloadedDetail))
    }

    private var usesSidebarLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesSidebarLayout {
                sidebarLayout
            } else {
                compactFormLayout
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color.siloPrimary)
        .interactiveDismissDisabled(viewModel.hasUnsavedChanges || viewModel.isSaving || viewModel.isResetting)
        .task {
            await viewModel.loadIfNeeded()
        }
        .onDisappear {
            viewModel.cancelBackgroundTasks()
        }
        .confirmationDialog(
            MetadataStrings.discardChangesTitle,
            isPresented: $showDiscardDialog,
            titleVisibility: .visible
        ) {
            Button(MetadataStrings.discardChangesButton, role: .destructive) { dismiss() }
            Button(MetadataStrings.keepEditingButton, role: .cancel) {}
        } message: {
            Text(MetadataStrings.discardChangesMessage)
        }
        .alert(
            MetadataStrings.resetAlertTitle,
            isPresented: $showResetAlert
        ) {
            Button(MetadataStrings.resetAlertConfirm, role: .destructive) {
                Task {
                    if await viewModel.resetToProvider() {
                        dismiss()
                        onResetAndRefresh()
                    }
                }
            }
            Button(MetadataStrings.cancelButton, role: .cancel) {}
        } message: {
            Text(MetadataStrings.resetAlertMessage)
        }
    }

    // MARK: - Compact (iPhone) Inset-Grouped Form

    private var compactFormLayout: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    loadingPlaceholder
                } else {
                    Form {
                        if let error = viewModel.errorMessage {
                            Section {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(MetadataPalette.destructiveRed)
                            }
                            .listRowBackground(MetadataPalette.destructiveRed.opacity(0.14))
                        }

                        if !viewModel.supportedLocks.isEmpty {
                            Section {
                                NavigationLink {
                                    MetadataLockManagerView(viewModel: viewModel)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(
                                                viewModel.effectiveLocks.isEmpty
                                                    ? MetadataPalette.secondaryText
                                                    : MetadataPalette.lockedAmber
                                            )
                                        Text(MetadataStrings.lockedFieldsSummary(count: viewModel.effectiveLocks.count))
                                            .foregroundStyle(MetadataPalette.primaryText)
                                    }
                                }
                            } footer: {
                                Text(MetadataStrings.autoLockFooter)
                            }
                            .listRowBackground(MetadataPalette.cellSurface)
                        }

                        MetadataGeneralSections(viewModel: viewModel)
                        MetadataDatesRatingsSections(viewModel: viewModel)
                        if viewModel.isMovieOrSeries {
                            MetadataTagsSections(viewModel: viewModel)
                        }
                        if viewModel.isMovieOrSeries || viewModel.isEpisode {
                            MetadataExternalIDsSections(viewModel: viewModel)
                        }
                        if AICapabilities.shared.metadataEnabled {
                            MetadataTranslateSection(viewModel: viewModel)
                        }

                        Section {
                            Button(role: .destructive) {
                                showResetAlert = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(MetadataStrings.resetToProviderButton)
                                        .foregroundStyle(MetadataPalette.destructiveRed)
                                    Spacer()
                                }
                            }
                            .disabled(viewModel.isSaving || viewModel.isResetting)
                        }
                        .listRowBackground(MetadataPalette.cellSurface)
                    }
                    .scrollContentBackground(.hidden)
                    .background(MetadataPalette.sheetCanvas)
                }
            }
            .navigationTitle(MetadataStrings.editMetadataTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MetadataStrings.cancelButton) {
                        requestClose()
                    }
                    .disabled(viewModel.isSaving || viewModel.isResetting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isSaving ? MetadataStrings.savingButton : MetadataStrings.saveButton) {
                        commitSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.hasUnsavedChanges || viewModel.isSaving || viewModel.isResetting)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(MetadataPalette.sheetCanvas)
    }

    // MARK: - Split Sidebar (iPadOS Regular)

    private var sidebarLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Sidebar navigation
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MetadataStrings.editMetadataTitle)
                            .font(.headline)
                            .foregroundStyle(MetadataPalette.primaryText)
                        Text(target.displayTitle)
                            .font(.caption)
                            .foregroundStyle(MetadataPalette.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                    ForEach(viewModel.availableSections) { section in
                        sidebarRow(section)
                    }

                    Spacer()
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 10)
                .frame(width: 210)
                .background(MetadataPalette.sidebarCanvas)

                Divider().overlay(MetadataPalette.hairline)

                // Detail form pane
                Group {
                    if viewModel.isLoading {
                        loadingPlaceholder
                    } else {
                        Form {
                            if let error = viewModel.errorMessage {
                                Section {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(MetadataPalette.destructiveRed)
                                }
                                .listRowBackground(MetadataPalette.destructiveRed.opacity(0.14))
                            }

                            switch selectedSection {
                            case .general:
                                MetadataGeneralSections(viewModel: viewModel)
                            case .datesRatings:
                                MetadataDatesRatingsSections(viewModel: viewModel)
                            case .tags:
                                MetadataTagsSections(viewModel: viewModel)
                            case .externalIds:
                                MetadataExternalIDsSections(viewModel: viewModel)
                            case .locks:
                                MetadataLocksInlineSections(viewModel: viewModel)
                            case .translate:
                                MetadataTranslateSection(viewModel: viewModel)
                            }
                        }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        .background(MetadataPalette.sheetCanvas)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(MetadataPalette.hairline)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    Text(MetadataStrings.resetToProviderButton)
                        .foregroundStyle(MetadataPalette.destructiveRed)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSaving || viewModel.isResetting)

                Spacer()

                Button(MetadataStrings.cancelButton) {
                    requestClose()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isSaving || viewModel.isResetting)

                Button {
                    commitSave()
                } label: {
                    Text(viewModel.isSaving ? MetadataStrings.savingButton : MetadataStrings.saveButton)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            viewModel.hasUnsavedChanges ? Color.siloPrimary : Color.white.opacity(0.16),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.hasUnsavedChanges ? Color.black : MetadataPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!viewModel.hasUnsavedChanges || viewModel.isSaving || viewModel.isResetting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(MetadataPalette.sidebarCanvas)
        }
    }

    private func sidebarRow(_ section: EditMetadataViewModel.SidebarSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: sidebarIcon(for: section))
                    .font(.subheadline)
                    .frame(width: 18)
                Text(sidebarTitle(for: section))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Spacer()
                if section == .locks && !viewModel.effectiveLocks.isEmpty {
                    Text(verbatim: "\(viewModel.effectiveLocks.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MetadataPalette.lockedAmber, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? MetadataPalette.primaryText : MetadataPalette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.white.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarTitle(for section: EditMetadataViewModel.SidebarSection) -> String {
        switch section {
        case .general: return MetadataStrings.sectionGeneral
        case .datesRatings: return MetadataStrings.sectionDatesRatings
        case .tags: return MetadataStrings.sectionTags
        case .externalIds: return MetadataStrings.sectionExternalIds
        case .locks: return MetadataStrings.sectionFieldLocks
        case .translate: return MetadataStrings.sectionTranslate
        }
    }

    private func sidebarIcon(for section: EditMetadataViewModel.SidebarSection) -> String {
        switch section {
        case .general: return "text.alignleft"
        case .datesRatings: return "calendar"
        case .tags: return "tag"
        case .externalIds: return "link"
        case .locks: return "lock.fill"
        case .translate: return "translate"
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Color.siloPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MetadataPalette.sheetCanvas)
    }

    private func requestClose() {
        if viewModel.hasUnsavedChanges {
            showDiscardDialog = true
        } else {
            dismiss()
        }
    }

    private func commitSave() {
        Task {
            if await viewModel.save() {
                onSaved()
                dismiss()
            }
        }
    }
}

// MARK: - Concrete Section Views (Flat Generic Depth)

private struct MetadataLockBadgeButton: View {
    let lock: MetadataFieldLock
    let isLocked: Bool
    let onToggle: () -> Void

    var body: some View {
        if isLocked {
            Button(action: onToggle) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MetadataPalette.lockedAmber)
                    .padding(6)
                    .background(MetadataPalette.lockedAmber.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(MetadataStrings.unlockAction): \(MetadataStrings.lockTitle(lock))")
        }
    }
}

private struct MetadataLockableTextFieldRow: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    let lock: MetadataFieldLock?
    let isLocked: Bool
    let onToggleLock: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LabeledContent(label) {
                TextField(placeholder, text: $text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
            if let lock {
                MetadataLockBadgeButton(lock: lock, isLocked: isLocked, onToggle: onToggleLock)
            }
        }
        .contextMenu {
            if lock != nil {
                Button(action: onToggleLock) {
                    Label(
                        isLocked ? MetadataStrings.unlockAction : MetadataStrings.lockAction,
                        systemImage: isLocked ? "lock.open" : "lock.fill"
                    )
                }
            }
        }
    }
}

private struct MetadataGeneralSections: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section(MetadataStrings.sectionGeneral) {
            MetadataLockableTextFieldRow(
                label: MetadataStrings.fieldTitle,
                text: $viewModel.title,
                lock: .name,
                isLocked: viewModel.isLocked(.name),
                onToggleLock: { viewModel.toggleLock(.name) }
            )
            if viewModel.isMovieOrSeries {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldSortTitle,
                    text: $viewModel.sortTitle,
                    lock: .name,
                    isLocked: viewModel.isLocked(.name),
                    onToggleLock: { viewModel.toggleLock(.name) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldOriginalTitle,
                    text: $viewModel.originalTitle,
                    lock: .name,
                    isLocked: viewModel.isLocked(.name),
                    onToggleLock: { viewModel.toggleLock(.name) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldTagline,
                    text: $viewModel.tagline,
                    lock: .overview,
                    isLocked: viewModel.isLocked(.overview),
                    onToggleLock: { viewModel.toggleLock(.overview) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldContentRating,
                    text: $viewModel.contentRating,
                    lock: .contentRating,
                    isLocked: viewModel.isLocked(.contentRating),
                    onToggleLock: { viewModel.toggleLock(.contentRating) }
                )
            }
            if viewModel.isSeason || viewModel.isEpisode {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldSeasonNumber,
                    text: $viewModel.seasonNumberText,
                    lock: nil,
                    isLocked: false,
                    onToggleLock: {}
                )
            }
            if viewModel.isEpisode {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldEpisodeNumber,
                    text: $viewModel.episodeNumberText,
                    lock: nil,
                    isLocked: false,
                    onToggleLock: {}
                )
            }
        }
        .listRowBackground(MetadataPalette.cellSurface)

        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(MetadataStrings.fieldOverview)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MetadataPalette.secondaryText)
                    Spacer()
                    MetadataLockBadgeButton(
                        lock: .overview,
                        isLocked: viewModel.isLocked(.overview),
                        onToggle: { viewModel.toggleLock(.overview) }
                    )
                }
                TextEditor(text: $viewModel.overview)
                    .font(.body)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
            }
            .contextMenu {
                let locked = viewModel.isLocked(.overview)
                Button {
                    viewModel.toggleLock(.overview)
                } label: {
                    Label(
                        locked ? MetadataStrings.unlockAction : MetadataStrings.lockAction,
                        systemImage: locked ? "lock.open" : "lock.fill"
                    )
                }
            }
        }
        .listRowBackground(MetadataPalette.cellSurface)
    }
}

private struct MetadataDatesRatingsSections: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section(MetadataStrings.sectionDatesRatings) {
            if viewModel.isMovieOrSeries {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldYear,
                    text: $viewModel.yearText,
                    lock: .releaseDates,
                    isLocked: viewModel.isLocked(.releaseDates),
                    onToggleLock: { viewModel.toggleLock(.releaseDates) }
                )
            }
            if viewModel.isMovie || viewModel.isEpisode {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldRuntime,
                    text: $viewModel.runtimeText,
                    lock: .runtime,
                    isLocked: viewModel.isLocked(.runtime),
                    onToggleLock: { viewModel.toggleLock(.runtime) }
                )
            }
            if viewModel.isMovie {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldReleaseDate,
                    placeholder: MetadataStrings.datePlaceholder,
                    text: $viewModel.releaseDate,
                    lock: .releaseDates,
                    isLocked: viewModel.isLocked(.releaseDates),
                    onToggleLock: { viewModel.toggleLock(.releaseDates) }
                )
            } else if viewModel.isSeries {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldFirstAirDate,
                    placeholder: MetadataStrings.datePlaceholder,
                    text: $viewModel.firstAirDate,
                    lock: .releaseDates,
                    isLocked: viewModel.isLocked(.releaseDates),
                    onToggleLock: { viewModel.toggleLock(.releaseDates) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldLastAirDate,
                    placeholder: MetadataStrings.datePlaceholder,
                    text: $viewModel.lastAirDate,
                    lock: .releaseDates,
                    isLocked: viewModel.isLocked(.releaseDates),
                    onToggleLock: { viewModel.toggleLock(.releaseDates) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldAirTime,
                    placeholder: MetadataStrings.timePlaceholder,
                    text: $viewModel.airTime,
                    lock: .airSchedule,
                    isLocked: viewModel.isLocked(.airSchedule),
                    onToggleLock: { viewModel.toggleLock(.airSchedule) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldAirTimezone,
                    placeholder: MetadataStrings.timezonePlaceholder,
                    text: $viewModel.airTimezone,
                    lock: .airSchedule,
                    isLocked: viewModel.isLocked(.airSchedule),
                    onToggleLock: { viewModel.toggleLock(.airSchedule) }
                )
            } else if viewModel.isSeason || viewModel.isEpisode {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldAirDate,
                    placeholder: MetadataStrings.datePlaceholder,
                    text: $viewModel.airDate,
                    lock: .releaseDates,
                    isLocked: viewModel.isLocked(.releaseDates),
                    onToggleLock: { viewModel.toggleLock(.releaseDates) }
                )
            }
        }
        .listRowBackground(MetadataPalette.cellSurface)

        if viewModel.isMovieOrSeries {
            Section("Ratings") {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldRatingImdb,
                    placeholder: "8.4",
                    text: $viewModel.ratingImdb,
                    lock: .rating,
                    isLocked: viewModel.isLocked(.rating),
                    onToggleLock: { viewModel.toggleLock(.rating) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldRatingTmdb,
                    placeholder: "8.2",
                    text: $viewModel.ratingTmdb,
                    lock: .rating,
                    isLocked: viewModel.isLocked(.rating),
                    onToggleLock: { viewModel.toggleLock(.rating) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldRatingRtCritic,
                    placeholder: "92",
                    text: $viewModel.ratingRtCritic,
                    lock: .rating,
                    isLocked: viewModel.isLocked(.rating),
                    onToggleLock: { viewModel.toggleLock(.rating) }
                )
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldRatingRtAudience,
                    placeholder: "95",
                    text: $viewModel.ratingRtAudience,
                    lock: .rating,
                    isLocked: viewModel.isLocked(.rating),
                    onToggleLock: { viewModel.toggleLock(.rating) }
                )
            }
            .listRowBackground(MetadataPalette.cellSurface)
        }
    }
}

private struct MetadataTagsSections: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section(MetadataStrings.sectionTags) {
            MetadataTokenFieldRow(
                label: MetadataStrings.fieldGenres,
                tokens: $viewModel.genres,
                isLocked: viewModel.isLocked(.genres),
                onToggleLock: { viewModel.toggleLock(.genres) }
            )
            MetadataTokenFieldRow(
                label: MetadataStrings.fieldStudios,
                tokens: $viewModel.studios,
                isLocked: viewModel.isLocked(.studios),
                onToggleLock: { viewModel.toggleLock(.studios) }
            )
            if viewModel.isSeries {
                MetadataTokenFieldRow(
                    label: MetadataStrings.fieldNetworks,
                    tokens: $viewModel.networks,
                    isLocked: viewModel.isLocked(.studios),
                    onToggleLock: { viewModel.toggleLock(.studios) }
                )
            }
            MetadataTokenFieldRow(
                label: MetadataStrings.fieldCountries,
                tokens: $viewModel.countries,
                isLocked: viewModel.isLocked(.tags),
                onToggleLock: { viewModel.toggleLock(.tags) }
            )
        }
        .listRowBackground(MetadataPalette.cellSurface)
    }
}

private struct MetadataExternalIDsSections: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section(MetadataStrings.sectionExternalIds) {
            MetadataLockableTextFieldRow(
                label: MetadataStrings.fieldImdbId,
                placeholder: "tt15239678",
                text: $viewModel.imdbId,
                lock: nil,
                isLocked: false,
                onToggleLock: {}
            )
            MetadataLockableTextFieldRow(
                label: MetadataStrings.fieldTmdbId,
                placeholder: "693134",
                text: $viewModel.tmdbId,
                lock: nil,
                isLocked: false,
                onToggleLock: {}
            )
            if viewModel.isSeries || viewModel.isEpisode {
                MetadataLockableTextFieldRow(
                    label: MetadataStrings.fieldTvdbId,
                    placeholder: "371980",
                    text: $viewModel.tvdbId,
                    lock: nil,
                    isLocked: false,
                    onToggleLock: {}
                )
            }
        }
        .listRowBackground(MetadataPalette.cellSurface)
    }
}

private struct MetadataLocksInlineSections: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section {
            HStack {
                Text(MetadataStrings.lockedFieldsSummary(count: viewModel.effectiveLocks.count))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(MetadataStrings.lockAllAction) { viewModel.setAllLocks(true) }
                    .font(.caption.weight(.medium))
                Button(MetadataStrings.unlockAllAction) { viewModel.setAllLocks(false) }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MetadataPalette.secondaryText)
            }
            ForEach(viewModel.supportedLocks) { lock in
                Toggle(
                    isOn: Binding(
                        get: { viewModel.isLocked(lock) },
                        set: { _ in viewModel.toggleLock(lock) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MetadataStrings.lockTitle(lock))
                            .foregroundStyle(MetadataPalette.primaryText)
                        Text(MetadataStrings.lockSubtitle(lock, mediaType: viewModel.mediaType))
                            .font(.caption)
                            .foregroundStyle(MetadataPalette.secondaryText)
                    }
                }
            }
        } header: {
            Text(MetadataStrings.sectionFieldLocks)
        } footer: {
            Text(MetadataStrings.locksManagerFooter)
        }
        .listRowBackground(MetadataPalette.cellSurface)
    }
}

private struct MetadataTranslateSection: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section {
            Text(
                viewModel.isSeries
                    ? MetadataStrings.translateBodySeries
                    : (viewModel.isMovie ? MetadataStrings.translateBodyMovie : MetadataStrings.translateBodyOther)
            )
            .font(.caption)
            .foregroundStyle(MetadataPalette.secondaryText)

            Picker(MetadataStrings.translateLanguageLabel, selection: $viewModel.translateLanguage) {
                ForEach(viewModel.translationLanguageOptions) { lang in
                    Text("\(lang.label) (\(lang.code))").tag(lang.code)
                }
            }

            Toggle(MetadataStrings.translateForceLabel, isOn: $viewModel.translateForce)

            Button {
                Task { await viewModel.startTranslation() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isStartingTranslation || viewModel.activeTranslationJob != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "translate")
                    }
                    Text(
                        (viewModel.isStartingTranslation || viewModel.activeTranslationJob != nil)
                            ? MetadataStrings.translatingButton
                            : MetadataStrings.translateStartButton
                    )
                }
            }
            .disabled(viewModel.isStartingTranslation || viewModel.activeTranslationJob != nil)

            if let job = viewModel.activeTranslationJob {
                let progress = (job.fieldsTotal ?? 0) > 0
                    ? "\(job.progressMessage ?? "Translating…") (\(job.fieldsDone ?? 0)/\(job.fieldsTotal ?? 0))"
                    : (job.progressMessage ?? "Translating…")
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(MetadataPalette.secondaryText)
            } else if let feedback = viewModel.translationFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(MetadataPalette.secondaryText)
            }
        } header: {
            Text(MetadataStrings.translateHeading)
        }
        .listRowBackground(MetadataPalette.cellSurface)
    }
}

// MARK: - iPhone Lock Manager Push Destination

private struct MetadataLockManagerView: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        List {
            Section {
                ForEach(viewModel.supportedLocks) { lock in
                    Toggle(
                        isOn: Binding(
                            get: { viewModel.isLocked(lock) },
                            set: { _ in viewModel.toggleLock(lock) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MetadataStrings.lockTitle(lock))
                                .foregroundStyle(MetadataPalette.primaryText)
                            Text(MetadataStrings.lockSubtitle(lock, mediaType: viewModel.mediaType))
                                .font(.caption)
                                .foregroundStyle(MetadataPalette.secondaryText)
                        }
                    }
                }
            } footer: {
                Text(MetadataStrings.locksManagerFooter)
            }
            .listRowBackground(MetadataPalette.cellSurface)
        }
        .scrollContentBackground(.hidden)
        .background(MetadataPalette.sheetCanvas)
        .navigationTitle(MetadataStrings.sectionFieldLocks)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let allLocked = viewModel.supportedLocks.allSatisfy { viewModel.isLocked($0) }
                Button(allLocked ? MetadataStrings.unlockAllAction : MetadataStrings.lockAllAction) {
                    viewModel.setAllLocks(!allLocked)
                }
            }
        }
    }
}

// MARK: - Monochrome Token / Tag Field Row

private struct MetadataTokenFieldRow: View {
    let label: String
    @Binding var tokens: [String]
    let isLocked: Bool
    let onToggleLock: () -> Void

    @State private var draftToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MetadataPalette.secondaryText)
                Spacer()
                if isLocked {
                    Button(action: onToggleLock) {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MetadataPalette.lockedAmber)
                            .padding(5)
                            .background(MetadataPalette.lockedAmber.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !tokens.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: 4) {
                            Text(token)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(MetadataPalette.primaryText)
                            Button {
                                tokens.removeAll { $0 == token }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(MetadataPalette.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.10), in: Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(MetadataStrings.addTagPlaceholder, text: $draftToken)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .onSubmit(commitDraft)
                if !draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Add", action: commitDraft)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.siloPrimary, in: Capsule())
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(action: onToggleLock) {
                Label(
                    isLocked ? MetadataStrings.unlockAction : MetadataStrings.lockAction,
                    systemImage: isLocked ? "lock.open" : "lock.fill"
                )
            }
        }
    }

    private func commitDraft() {
        let parts = draftToken
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in parts where !tokens.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            tokens.append(part)
        }
        draftToken = ""
    }
}
#endif
