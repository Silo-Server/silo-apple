import SwiftUI

/// Monochrome palette tokens shared across metadata management sheets on
/// iOS, iPadOS, macOS, and tvOS so every sheet matches Silo's native chrome.
enum MetadataPalette {
    static var sheetCanvas: Color { Color.siloPageCanvas }

    static var sidebarCanvas: Color {
        #if os(macOS)
        Color.siloSidebarCanvas
        #else
        Color(hex: "#121214")
        #endif
    }

    static var cellSurface: Color { Color.siloGroupedCell }
    static var elevatedSurface: Color { Color.siloSurfaceElevated }
    static var primaryText: Color { Color.siloOnSurface }
    static var secondaryText: Color { Color.siloSecondaryText }
    static var hairline: Color { Color.siloDivider }
    static var lockedAmber: Color { Color.siloStatusWarning }
    static var destructiveRed: Color { Color.siloErrorInk }
}

/// Centralized copy and label helpers for metadata management surfaces.
enum MetadataStrings {
    // MARK: - Menu & Actions

    static let manageMenuTitle = "Manage"
    static let editMetadata = "Edit Metadata…"
    static let chooseArtwork = "Choose Artwork…"
    static let fixMatch = "Fix Match…"
    static let refreshMetadata = "Refresh Metadata…"
    static let refreshMetadataTitle = "Refresh Metadata"
    static let quickRefresh = "Quick Refresh"
    static let quickRefreshDescription = "Keeps locked fields and custom artwork."
    static let completeRefresh = "Complete Refresh"
    static let completeRefreshDescription = "Re-fetches all metadata and artwork."

    static func editSeason(_ seasonLabel: String) -> String { "Edit \(seasonLabel)…" }
    static func seasonArtwork(_ seasonLabel: String) -> String { "\(seasonLabel) Artwork…" }
    static func refreshSeason(_ seasonLabel: String) -> String { "Refresh \(seasonLabel)…" }
    static func refreshSeasonMenuTitle(_ seasonLabel: String) -> String { "Refresh \(seasonLabel)" }
    static func editEpisode(_ episodeCode: String) -> String { "Edit \(episodeCode)…" }
    static func refreshEpisode(_ episodeCode: String) -> String { "Refresh \(episodeCode)…" }
    static func refreshEpisodeMenuTitle(_ episodeCode: String) -> String { "Refresh \(episodeCode)" }
    static let tvSelectToApplyHint = "Select to apply · Menu to close"

    static func refreshMessage(for target: MetadataCurationTarget) -> String {
        if target.mediaType == "series" {
            return "Choose how Silo should refresh \"\(target.displayTitle)\" and its episodes."
        }
        return "Choose how Silo should refresh \"\(target.displayTitle)\"."
    }

    // MARK: - Refresh Toast Status

    static func refreshingToast(title: String, mode: MetadataRefreshMode) -> String {
        switch mode {
        case .quick: return "Refreshing \"\(title)\"…"
        case .complete: return "Complete refresh running for \"\(title)\"…"
        }
    }

    static func refreshedToast(title: String) -> String {
        "Metadata refreshed for \"\(title)\""
    }

    static func refreshStillRunningToast(title: String) -> String {
        "Refresh for \"\(title)\" is still running in the background."
    }

    static func refreshFailedToast(_ reason: String?) -> String {
        if let reason, !reason.isEmpty { return "Refresh failed: \(reason)" }
        return "Metadata refresh failed."
    }

    static let artworkUpdatedToast = "Artwork updated and locked"
    static let metadataSavedToast = "Metadata saved"
    static let matchAppliedToast = "Match updated"

    // MARK: - Fix Match

    static let fixMatchTitle = "Fix Match"
    static let currentlyMatchedHeader = "Currently Matched"
    static let unmatchedLabel = "Unmatched"
    static let localFilesHeader = "Local Files"
    static let localFoldersHeader = "Local Folders"
    static let copyPathLabel = "Copy"
    static let copiedPathLabel = "Copied"
    static let searchTitlePlaceholder = "Title, IMDb ID (tt…), or URL"
    static let yearPlaceholder = "Year"
    static let searchButton = "Search"
    static let externalIdsDisclosure = "Search by External ID"
    static let libraryScopeLabel = "Library"
    static func libraryFallbackName(_ id: Int) -> String { "Library \(id)" }
    static let fileReadFailedError = "Could not read the selected image file."
    static let addProviderIdButton = "Add Provider ID"
    static let providerKeyPlaceholder = "Provider (e.g. anilist)"
    static let providerValuePlaceholder = "ID"
    static let searchingMatches = "Searching providers…"
    static let loadingHints = "Loading match hints…"
    static let noMatchesTitle = "No Matches Found"
    static let noMatchesMessage = "Try a shorter title, clear the year, or paste an IMDb, TMDB, or TVDB ID."
    static let truncatedResultsNotice = "Showing top results — narrow your title or enter an ID for exact matches."
    static let matchReasonsTitle = "Match Signals"
    static let applyMatchDefault = "Apply Match"
    static let applyingMatch = "Applying Match…"
    static let replaceMatchAlertTitle = "Replace Current Match?"
    static let replaceMatchConfirm = "Replace Match"
    static let editSearchButton = "Edit Search"

    static func applyMatchButton(candidate: AdminMatchCandidate) -> String {
        if candidate.year > 0 {
            return "Apply Match: \(candidate.displayTitle) (\(candidate.year))"
        }
        return "Apply Match: \(candidate.displayTitle)"
    }

    static func replaceMatchMessage(currentTitle: String, candidate: AdminMatchCandidate) -> String {
        let target = candidate.year > 0
            ? "\(candidate.displayTitle) (\(candidate.year))"
            : candidate.displayTitle
        return "Replace \"\(currentTitle)\" with \"\(target)\"? Silo will re-link this item and refresh its metadata from providers."
    }

    // MARK: - Choose Artwork

    static let chooseArtworkTitle = "Choose Artwork"
    static let immediateArtworkNotice = "Artwork changes apply right away and lock the images field against future refreshes."
    static let seasonArtworkNotice = "Season artwork locks images on the parent series."
    static let textlessOnlyLabel = "Textless Only"
    static let allProvidersLabel = "All Providers"
    static let filterMenuLabel = "Filter"
    static let uploadMenuLabel = "Upload"
    static let uploadFromPhotos = "Choose from Photos"
    static let uploadFromFiles = "Choose File…"
    static let dropArtworkHint = "Drop JPEG, PNG, or WebP here to upload"
    static let currentBadge = "Current"
    static let uploadedBadge = "Uploaded"
    static let previewingBadge = "Previewing"
    static let uploadingArtwork = "Uploading…"
    static let applyingArtwork = "Applying…"
    static let loadingArtwork = "Loading artwork from providers…"
    static let noArtworkTitle = "No Artwork Available"
    static let noTextlessArtworkMessage = "No textless artwork matched for this slot. Turn off Textless Only or upload your own."
    static let noArtworkMessage = "No provider artwork was returned for this slot. Upload a JPEG, PNG, or WebP file instead."

    static func slotTitle(_ slot: MetadataImageSlot) -> String {
        switch slot {
        case .poster: return "Posters"
        case .backdrop: return "Backdrops"
        case .logo: return "Logos"
        }
    }

    static func slotSingular(_ slot: MetadataImageSlot) -> String {
        switch slot {
        case .poster: return "Poster"
        case .backdrop: return "Backdrop"
        case .logo: return "Logo"
        }
    }

    static func applySlotButton(_ slot: MetadataImageSlot) -> String {
        "Apply \(slotSingular(slot))"
    }

    static func providerErrorsBanner(_ providers: [String]) -> String {
        let joined = providers.map { $0.uppercased() }.sorted().joined(separator: ", ")
        return "Some providers could not be reached: \(joined)"
    }

    // MARK: - Edit Metadata

    static let editMetadataTitle = "Edit Metadata"
    static let saveButton = "Save"
    static let savingButton = "Saving…"
    static let cancelButton = "Cancel"
    static let doneButton = "Done"
    static let retryButton = "Retry"
    static let discardChangesTitle = "Discard Changes?"
    static let discardChangesButton = "Discard Changes"
    static let keepEditingButton = "Keep Editing"
    static let discardChangesMessage = "Your unsaved metadata edits will be lost."

    static let sectionGeneral = "General"
    static let sectionDatesRatings = "Dates & Ratings"
    static let sectionTags = "Tags"
    static let sectionExternalIds = "External IDs"
    static let sectionFieldLocks = "Field Locks"
    static let sectionTranslate = "AI Translation"

    static let fieldTitle = "Title"
    static let fieldSortTitle = "Sort Title"
    static let fieldOriginalTitle = "Original Title"
    static let fieldTagline = "Tagline"
    static let fieldOverview = "Overview"
    static let fieldContentRating = "Content Rating"
    static let fieldSeasonNumber = "Season Number"
    static let fieldEpisodeNumber = "Episode Number"
    static let fieldYear = "Year"
    static let fieldRuntime = "Runtime (min)"
    static let fieldReleaseDate = "Release Date"
    static let fieldFirstAirDate = "First Air Date"
    static let fieldLastAirDate = "Last Air Date"
    static let fieldAirDate = "Air Date"
    static let fieldAirTime = "Air Time (HH:MM)"
    static let fieldAirTimezone = "Air Timezone"
    static let fieldRatingImdb = "IMDb (0–10)"
    static let fieldRatingTmdb = "TMDB (0–10)"
    static let fieldRatingRtCritic = "RT Critic (0–100)"
    static let fieldRatingRtAudience = "RT Audience (0–100)"
    static let fieldGenres = "Genres"
    static let fieldStudios = "Studios"
    static let fieldNetworks = "Networks"
    static let fieldCountries = "Countries"
    static let fieldImdbId = "IMDb ID"
    static let fieldTmdbId = "TMDB ID"
    static let fieldTvdbId = "TVDB ID"

    static let datePlaceholder = "YYYY-MM-DD"
    static let timePlaceholder = "21:00"
    static let timezonePlaceholder = "America/New_York"
    static let addTagPlaceholder = "Add value…"

    static let lockAction = "Lock Field"
    static let unlockAction = "Unlock Field"
    static let lockAllAction = "Lock All"
    static let unlockAllAction = "Unlock All"
    static let autoLockFooter = "Editing a field automatically locks it so future provider refreshes keep your changes. Tap any amber lock pill to unlock it."
    static let locksManagerFooter = "Locked fields are preserved when Silo refreshes metadata from providers."

    static let resetToProviderButton = "Reset to Provider…"
    static let resetAlertTitle = "Reset Metadata to Provider?"
    static let resetAlertConfirm = "Reset & Refresh"
    static let resetAlertMessage = "This unlocks every field on this item and runs a Quick Refresh from providers."

    static let translateHeading = "Translate Metadata with AI"
    static let translateLanguageLabel = "Target Language"
    static let translateForceLabel = "Overwrite Existing Translations"
    static let translateStartButton = "Translate"
    static let translatingButton = "Translating…"
    static let translateBodyMovie = "Translate this movie's overview and tagline into the selected language."
    static let translateBodySeries = "Translate this series' overview, tagline, and all season and episode overviews."
    static let translateBodyOther = "Translate this item's overview into the selected language."

    static func lockedFieldsSummary(count: Int) -> String {
        switch count {
        case 0: return "No fields locked"
        case 1: return "1 field locked"
        default: return "\(count) fields locked"
        }
    }

    static func lockTitle(_ lock: MetadataFieldLock) -> String {
        switch lock {
        case .name: return "Titles"
        case .overview: return "Overview & Tagline"
        case .genres: return "Genres"
        case .studios: return "Studios & Networks"
        case .rating: return "Ratings"
        case .runtime: return "Runtime"
        case .tags: return "Countries & Tags"
        case .contentRating: return "Content Rating"
        case .images: return "Artwork & Images"
        case .airSchedule: return "Air Schedule"
        case .releaseDates: return "Year & Dates"
        }
    }

    static func lockSubtitle(_ lock: MetadataFieldLock, mediaType: String) -> String {
        switch lock {
        case .name:
            return mediaType == "season" || mediaType == "episode"
                ? "Title"
                : "Title, sort title, original title"
        case .overview:
            return mediaType == "season" || mediaType == "episode"
                ? "Overview"
                : "Overview and tagline"
        case .genres: return "Genre tags"
        case .studios:
            return mediaType == "series" ? "Studios and networks" : "Production studios"
        case .rating: return "IMDb, TMDB, Rotten Tomatoes scores"
        case .runtime: return "Duration in minutes"
        case .tags: return "Countries"
        case .contentRating: return "Maturity certification"
        case .images: return "Posters, backdrops, and logos"
        case .airSchedule: return "Air time and timezone"
        case .releaseDates:
            switch mediaType {
            case "series": return "Year, first air date, last air date"
            case "season", "episode": return "Air date"
            default: return "Year and release date"
            }
        }
    }

    static func invalidNumberError(_ field: String) -> String {
        "Enter a valid number for \(field), or leave it blank to clear."
    }

    /// Extracts a readable error message from APIv2 / HTTP / validation errors.
    static func errorMessage(from error: Error) -> String {
        if let apiError = error as? APIv2Error {
            switch apiError {
            case .problem(let problem):
                if !problem.detail.isEmpty { return problem.detail }
                if !problem.title.isEmpty { return problem.title }
                return "Server error (\(problem.status))."
            case .httpStatus(let code):
                if code == 403 { return "You don't have permission to perform this action." }
                if code == 404 { return "This item is no longer available on the server." }
                return "Request failed (HTTP \(code))."
            case .serverUpdateRequired:
                return "Update your Silo server to use this feature."
            case .incompleteCatalogRead:
                return "Incomplete response from server."
            default:
                return apiError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
