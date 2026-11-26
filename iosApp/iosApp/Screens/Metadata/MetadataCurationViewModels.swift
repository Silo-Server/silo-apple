import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Shared Fix Match ViewModel (iOS, iPadOS, macOS, tvOS)

@MainActor
@Observable
final class FixMatchViewModel {
    struct CustomProviderEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    struct LibraryOption: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    let target: MetadataCurationTarget

    private(set) var detail: ItemDetail?
    private(set) var hints: AdminMatchHints?
    private(set) var candidates: [AdminMatchCandidate] = []
    private(set) var isTruncated = false
    private(set) var isLoadingInitial = true
    private(set) var isSearching = false
    private(set) var isApplying = false
    private(set) var errorMessage: String?

    var queryText: String
    var yearText: String
    var imdbIdText: String = ""
    var tmdbIdText: String = ""
    var tvdbIdText: String = ""
    var customProviders: [CustomProviderEntry] = []
    var selectedCandidate: AdminMatchCandidate?

    /// Non-empty only when an acting admin opens Fix Match on an item whose
    /// files span multiple libraries.
    private(set) var libraryOptions: [LibraryOption] = []
    var selectedLibraryId: Int?
    /// Tracks which library scope produced the currently displayed `candidates`.
    /// Apply is blocked whenever the user switched libraries and results for
    /// that scope have not finished loading yet.
    private(set) var searchedLibraryId: Int?
    private(set) var hasCompletedSearch = false
    private(set) var itemFiles: [AdminItemFile] = []

    var copiedPath: String?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(target: MetadataCurationTarget, preloadedDetail: ItemDetail? = nil) {
        self.target = target
        self.detail = preloadedDetail
        self.queryText = target.title
        self.yearText = target.year.map(String.init) ?? ""
        self.selectedLibraryId = target.libraryId
    }

    var effectiveMediaType: String {
        if let detail { return MetadataCurationTarget.normalizedType(detail.type) }
        return target.mediaType
    }

    var isVideoItem: Bool {
        effectiveMediaType == "movie" || effectiveMediaType == "series"
    }

    var isCurrentlyMatched: Bool {
        if let status = detail?.status { return status.lowercased() != "unmatched" }
        return target.isMatched
    }

    var currentDisplayTitle: String {
        if let detail, !detail.title.isEmpty { return detail.title }
        return target.displayTitle
    }

    var currentYear: Int? {
        detail?.year ?? target.year
    }

    var currentPosterUrl: String? {
        detail?.posterUrl ?? target.posterUrl
    }

    var currentExternalIdBadges: [(String, String)] {
        var badges: [(String, String)] = []
        if let imdb = detail?.imdbId, !imdb.isEmpty { badges.append(("IMDb", imdb)) }
        if let tmdb = detail?.tmdbId, !tmdb.isEmpty { badges.append(("TMDB", tmdb)) }
        if let tvdb = detail?.tvdbId, !tvdb.isEmpty { badges.append(("TVDB", tvdb)) }
        return badges
    }

    var localPaths: [String] {
        if !itemFiles.isEmpty {
            let scoped: [AdminItemFile]
            if let selectedLibraryId {
                let matching = itemFiles.filter { Int($0.libraryId) == selectedLibraryId }
                scoped = matching.isEmpty ? itemFiles : matching
            } else {
                scoped = itemFiles
            }
            return Array(Set(scoped.map(\.filePath))).sorted()
        }
        if let folders = detail?.folderPaths, !folders.isEmpty {
            return folders
        }
        if !target.folderPaths.isEmpty {
            return target.folderPaths
        }
        let versionFiles = (detail?.versions ?? []).compactMap(\.fileName).filter { !$0.isEmpty }
        return versionFiles.isEmpty ? target.fileNames : versionFiles
    }

    var detectedQuery: DetectedMatchQuery {
        DetectedMatchQuery.parse(queryText)
    }

    var canApply: Bool {
        selectedCandidate != nil
            && hasCompletedSearch
            && !isSearching
            && !isApplying
            && searchedLibraryId == selectedLibraryId
    }

    func loadInitial() async {
        isLoadingInitial = true
        errorMessage = nil

        if detail == nil {
            if let fetched = try? await SiloAPI.shared.itemDetail(
                contentId: target.contentId,
                libraryId: target.libraryId
            ) {
                detail = fetched
            }
        }

        if MetadataCurationAuthorityStore.shared.isActingAdmin {
            await loadMultiLibraryContext()
        }

        await loadHintsAndSearch()
        isLoadingInitial = false
    }

    func switchLibrary(to newLibraryId: Int?) {
        guard selectedLibraryId != newLibraryId else { return }
        searchTask?.cancel()
        searchGeneration &+= 1
        selectedLibraryId = newLibraryId
        candidates = []
        selectedCandidate = nil
        hasCompletedSearch = false
        errorMessage = nil

        searchTask = Task { @MainActor [weak self] in
            await self?.loadHintsAndSearch()
        }
    }

    func cycleLibrary() {
        guard libraryOptions.count > 1 else { return }
        let idx = libraryOptions.firstIndex(where: { $0.id == selectedLibraryId }) ?? 0
        let next = libraryOptions[(idx + 1) % libraryOptions.count]
        switchLibrary(to: next.id)
    }

    func loadHintsAndSearch() async {
        let gen = searchGeneration
        let scopeLibraryId = selectedLibraryId
        isSearching = true

        if let fetchedHints = try? await SiloAPI.shared.apiV2Client.adminItemMatchHints(
            id: target.contentId,
            libraryId: scopeLibraryId
        ) {
            guard !Task.isCancelled, gen == searchGeneration else { return }
            hints = fetchedHints
            if !fetchedHints.title.isEmpty {
                queryText = fetchedHints.title
            }
            yearText = fetchedHints.year > 0 ? String(fetchedHints.year) : ""
            imdbIdText = fetchedHints.providerIds["imdb"] ?? ""
            tmdbIdText = fetchedHints.providerIds["tmdb"] ?? ""
            tvdbIdText = fetchedHints.providerIds["tvdb"] ?? ""
            customProviders = fetchedHints.providerIds
                .filter { !["imdb", "tmdb", "tvdb"].contains($0.key.lowercased()) }
                .sorted { $0.key < $1.key }
                .map { CustomProviderEntry(key: $0.key, value: $0.value) }
        }

        guard !Task.isCancelled, gen == searchGeneration else { return }
        await runSearch(generation: gen, scopeLibraryId: scopeLibraryId)
    }

    func triggerSearch(clearExternalIds: Bool = false) {
        if clearExternalIds {
            imdbIdText = ""
            tmdbIdText = ""
            tvdbIdText = ""
            customProviders = []
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        let gen = searchGeneration
        let scopeLibraryId = selectedLibraryId
        candidates = []
        selectedCandidate = nil
        hasCompletedSearch = false
        errorMessage = nil

        searchTask = Task { @MainActor [weak self] in
            await self?.runSearch(generation: gen, scopeLibraryId: scopeLibraryId)
        }
    }

    func applyCandidate(_ candidate: AdminMatchCandidate) async -> String? {
        guard !isApplying, !isSearching, searchedLibraryId == selectedLibraryId else { return nil }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }

        do {
            let request = AdminMatchApplyRequest(
                providerIds: candidate.providerIds,
                libraryId: searchedLibraryId.map(String.init)
            )
            let response = try await SiloAPI.shared.apiV2Client.applyAdminItemMatch(
                id: target.contentId,
                request: request
            )
            let replaced = response.contentId != target.contentId ? response.contentId : nil
            MetadataCurationCache.invalidateAfterMutation(
                contentId: target.contentId,
                replacedByContentId: replaced,
                seriesId: target.seriesId
            )
            return response.contentId
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
            return nil
        }
    }

    func applySelectedMatch() async -> String? {
        guard let candidate = selectedCandidate else { return nil }
        return await applyCandidate(candidate)
    }

    #if !os(tvOS)
    func copyPath(_ path: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = path
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #endif
        copiedPath = path
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.copiedPath == path { self?.copiedPath = nil }
        }
    }
    #endif

    func addCustomProvider() {
        customProviders.append(CustomProviderEntry(key: "", value: ""))
    }

    func removeCustomProvider(id: UUID) {
        customProviders.removeAll { $0.id == id }
    }

    func cancelPendingWork() {
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - Private

    private func runSearch(generation gen: Int, scopeLibraryId: Int?) async {
        let request = buildSearchRequest(libraryId: scopeLibraryId)
        guard request.title != nil || request.imdbId != nil || request.tmdbId != nil ||
              request.tvdbId != nil || !(request.providerIds?.isEmpty ?? true) else {
            guard gen == searchGeneration else { return }
            candidates = []
            selectedCandidate = nil
            searchedLibraryId = scopeLibraryId
            hasCompletedSearch = true
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        do {
            let response = try await SiloAPI.shared.apiV2Client.searchAdminItemMatches(
                id: target.contentId,
                request: request
            )
            guard !Task.isCancelled, gen == searchGeneration else { return }
            candidates = response.candidates
            isTruncated = response.truncated
            searchedLibraryId = scopeLibraryId
            hasCompletedSearch = true
            selectedCandidate = response.candidates.first
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, gen == searchGeneration else { return }
            errorMessage = MetadataStrings.errorMessage(from: error)
        }
        if gen == searchGeneration {
            isSearching = false
        }
    }

    private func buildSearchRequest(libraryId: Int?) -> AdminMatchSearchRequest {
        let detected = DetectedMatchQuery.parse(queryText)
        let trimmedImdb = imdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTmdb = tmdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTvdb = tvdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)

        let imdb = detected.imdbId ?? (trimmedImdb.isEmpty ? nil : trimmedImdb)
        let tmdb = detected.tmdbId ?? (trimmedTmdb.isEmpty ? nil : trimmedTmdb)
        let tvdb = detected.tvdbId ?? (trimmedTvdb.isEmpty ? nil : trimmedTvdb)

        var customMap: [String: String] = [:]
        for entry in customProviders {
            let k = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let v = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !v.isEmpty { customMap[k] = v }
        }

        let parsedYear = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let validYear = (parsedYear != nil && (1880...2100).contains(parsedYear!)) ? parsedYear : nil

        return AdminMatchSearchRequest(
            title: detected.title,
            year: validYear,
            imdbId: imdb,
            tmdbId: tmdb,
            tvdbId: tvdb,
            providerIds: customMap.isEmpty ? nil : customMap,
            libraryId: libraryId.map(String.init),
            limit: 500
        )
    }

    private func loadMultiLibraryContext() async {
        async let filesFetch: [AdminItemFile]? = try? SiloAPI.shared.apiV2Client.adminItemFiles(id: target.contentId)
        async let librariesFetch: LibrariesResponse? = try? SiloAPI.shared.libraries()
        let (files, librariesResponse) = await (filesFetch, librariesFetch)

        guard let files else { return }
        itemFiles = files
        let distinctLibraryIds = Set(files.compactMap { Int($0.libraryId) })
        guard distinctLibraryIds.count > 1 else { return }

        let namesById = Dictionary(
            uniqueKeysWithValues: (librariesResponse?.libraries ?? []).map { ($0.id, $0.name) }
        )
        libraryOptions = distinctLibraryIds
            .sorted()
            .map { LibraryOption(id: $0, name: namesById[$0] ?? MetadataStrings.libraryFallbackName($0)) }

        if let currentLib = selectedLibraryId, distinctLibraryIds.contains(currentLib) {
            return
        }
        selectedLibraryId = libraryOptions.first?.id
    }
}

// MARK: - Shared Choose Artwork ViewModel (iOS, iPadOS, macOS, tvOS)

@MainActor
@Observable
final class ChooseArtworkViewModel {
    struct ProviderBucket: Identifiable, Equatable {
        let id: String
        let count: Int
    }

    let target: MetadataCurationTarget
    let availableSlots: [MetadataImageSlot]

    var activeSlot: MetadataImageSlot
    var textlessOnly = false
    var activeProvider: String? = nil
    var selectedImage: AdminItemImage?

    private(set) var images: [AdminItemImage] = []
    private(set) var current = AdminCurrentImages(posterUrl: nil, backdropUrl: nil, logoUrl: nil)
    private(set) var providerErrors: [String: String] = [:]
    private(set) var appliedBySlot: [MetadataImageSlot: String] = [:]

    private(set) var isLoading = true
    private(set) var isApplying = false
    private(set) var isUploading = false
    var errorMessage: String?

    init(target: MetadataCurationTarget, initialSlot: MetadataImageSlot = .poster) {
        self.target = target
        let slots = MetadataImageSlot.slots(forMediaType: target.mediaType)
        self.availableSlots = slots
        self.activeSlot = slots.contains(initialSlot) ? initialSlot : (slots.first ?? .poster)
    }

    var isBusy: Bool { isApplying || isUploading }

    var slotImages: [AdminItemImage] {
        images.filter { $0.type == activeSlot.rawValue }
    }

    var visibleImages: [AdminItemImage] {
        if textlessOnly && activeSlot != .logo {
            return slotImages.filter(\.isTextless)
        }
        return slotImages
    }

    var providerBuckets: [ProviderBucket] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for img in slotImages {
            if counts[img.providerId] == nil {
                order.append(img.providerId)
                counts[img.providerId] = 0
            }
        }
        for img in visibleImages {
            counts[img.providerId, default: 0] += 1
        }
        return order.map { ProviderBucket(id: $0, count: counts[$0] ?? 0) }
    }

    var filteredImages: [AdminItemImage] {
        guard let activeProvider,
              providerBuckets.contains(where: { $0.id == activeProvider }) else {
            return visibleImages
        }
        return visibleImages.filter { $0.providerId == activeProvider }
    }

    var previewImage: AdminItemImage? {
        selectedImage ?? filteredImages.first(where: isCurrent) ?? slotImages.first(where: isCurrent)
    }

    func isCurrent(_ image: AdminItemImage) -> Bool {
        if image.isUploaded { return true }
        if let applied = appliedBySlot[activeSlot], applied == image.originalUrl { return true }
        if let stored = current.storedPath(for: activeSlot), !stored.isEmpty, stored == image.originalUrl {
            return true
        }
        return false
    }

    var canApplySelection: Bool {
        guard let selectedImage, !isBusy else { return false }
        return !isCurrent(selectedImage)
    }

    func resetFiltersForSlotChange() {
        textlessOnly = false
        activeProvider = nil
        selectedImage = nil
    }

    func selectSlot(_ slot: MetadataImageSlot) {
        guard activeSlot != slot else { return }
        activeSlot = slot
        resetFiltersForSlotChange()
    }

    func toggleTextless() {
        textlessOnly.toggle()
        if let selectedImage, !filteredImages.contains(selectedImage) {
            self.selectedImage = nil
        }
    }

    func selectProvider(_ providerId: String?) {
        activeProvider = providerId
        if let selectedImage, !filteredImages.contains(selectedImage) {
            self.selectedImage = nil
        }
    }

    func loadImages() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await SiloAPI.shared.apiV2Client.adminItemImages(id: target.contentId)
            images = response.images
            current = response.current
            providerErrors = response.providerErrors
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
        }
        isLoading = false
    }

    func applyImage(_ image: AdminItemImage) async -> Bool {
        guard !isBusy, !isCurrent(image) else { return false }
        let slot = MetadataImageSlot(rawValue: image.type) ?? activeSlot
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }

        do {
            let request = AdminImageApplyRequest(
                originalUrl: image.originalUrl,
                type: image.type,
                providerId: image.providerId
            )
            _ = try await SiloAPI.shared.apiV2Client.applyAdminItemImage(
                id: target.contentId,
                request: request
            )
            appliedBySlot[slot] = image.originalUrl
            if selectedImage == image { selectedImage = nil }
            MetadataCurationCache.invalidateAfterMutation(
                contentId: target.contentId,
                seriesId: target.seriesId
            )
            await refreshSilently()
            return true
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
            return false
        }
    }

    func applySelected() async -> Bool {
        guard let image = selectedImage else { return false }
        return await applyImage(image)
    }

    #if !os(tvOS)
    /// Marks an upload active before an async Photos download starts so
    /// controls stay disabled while image bytes load.
    func setUploadBusy(_ busy: Bool) {
        isUploading = busy
    }

    func uploadRawData(_ rawData: Data, for slot: MetadataImageSlot) async -> Bool {
        guard !isApplying else { return false }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }

        do {
            let validated = try Self.validateOrTranscodeImage(rawData)
            _ = try await SiloAPI.shared.apiV2Client.uploadAdminItemImage(
                id: target.contentId,
                slot: slot,
                image: validated
            )
            appliedBySlot.removeValue(forKey: slot)
            selectedImage = nil
            MetadataCurationCache.invalidateAfterMutation(
                contentId: target.contentId,
                seriesId: target.seriesId
            )
            await refreshSilently()
            return true
        } catch {
            errorMessage = MetadataStrings.errorMessage(from: error)
            return false
        }
    }

    private static func validateOrTranscodeImage(_ data: Data) throws -> ValidatedUploadImage {
        do {
            return try ImageUploadValidator.validate(data)
        } catch ImageUploadValidationError.unsupportedFormat {
            if let jpegData = transcodeToJPEG(data) {
                return try ImageUploadValidator.validate(jpegData)
            }
            throw ImageUploadValidationError.unsupportedFormat
        }
    }

    private static func transcodeToJPEG(_ data: Data) -> Data? {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.92)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        #else
        return nil
        #endif
    }
    #endif

    private func refreshSilently() async {
        if let response = try? await SiloAPI.shared.apiV2Client.adminItemImages(id: target.contentId) {
            images = response.images
            current = response.current
            providerErrors = response.providerErrors
        }
    }
}
