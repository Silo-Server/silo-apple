import Foundation
import XCTest
@testable import Silo

final class MetadataCurationTests: XCTestCase {

    // MARK: - Permissions Policy

    func testPermissionsMirrorServerActingAdminRules() {
        let admin = makeAccount(id: "1", username: "admin", role: .admin, permissions: nil)
        let adminWithExplicit = makeAccount(
            id: "1",
            username: "admin",
            role: .admin,
            permissions: ["metadata_curation"]
        )
        let curator = makeAccount(
            id: "2",
            username: "curator",
            role: .user,
            permissions: ["metadata_curation"]
        )
        let viewer = makeAccount(id: "3", username: "viewer", role: .user, permissions: [])

        let primaryProfile = makeProfile(id: "p1", isPrimary: true, isChild: false)
        let kidProfile = makeProfile(id: "p2", isPrimary: false, isChild: true)

        // Admin on primary profile or before profile selection has full powers.
        XCTAssertTrue(MetadataCurationPolicy.isActingAdmin(account: admin, profile: primaryProfile))
        XCTAssertTrue(MetadataCurationPolicy.canCurateMetadata(account: admin, profile: primaryProfile))
        XCTAssertTrue(MetadataCurationPolicy.canEditArtwork(account: admin, profile: primaryProfile))
        XCTAssertTrue(MetadataCurationPolicy.isActingAdmin(account: admin, profile: nil))
        XCTAssertTrue(MetadataCurationPolicy.canEditArtwork(account: admin, profile: nil))

        // Admin on a non-primary/kid profile drops implicit admin bypass.
        XCTAssertFalse(MetadataCurationPolicy.isActingAdmin(account: admin, profile: kidProfile))
        XCTAssertFalse(MetadataCurationPolicy.canEditArtwork(account: admin, profile: kidProfile))
        XCTAssertFalse(MetadataCurationPolicy.canCurateMetadata(account: admin, profile: kidProfile))

        // Explicit permissions still hold on non-primary profiles, while artwork stays admin-only.
        XCTAssertFalse(MetadataCurationPolicy.canEditArtwork(account: adminWithExplicit, profile: kidProfile))
        XCTAssertTrue(MetadataCurationPolicy.canCurateMetadata(account: adminWithExplicit, profile: kidProfile))

        // Delegated non-admin curator can edit/match/refresh metadata, never artwork.
        XCTAssertFalse(MetadataCurationPolicy.isActingAdmin(account: curator, profile: primaryProfile))
        XCTAssertTrue(MetadataCurationPolicy.canCurateMetadata(account: curator, profile: primaryProfile))
        XCTAssertFalse(MetadataCurationPolicy.canEditArtwork(account: curator, profile: primaryProfile))

        // Regular viewer or signed-out state gets nothing.
        XCTAssertFalse(MetadataCurationPolicy.canCurateMetadata(account: viewer, profile: primaryProfile))
        XCTAssertFalse(MetadataCurationPolicy.canEditArtwork(account: viewer, profile: primaryProfile))
        XCTAssertFalse(MetadataCurationPolicy.canCurateMetadata(account: nil, profile: primaryProfile))

        // Fail closed when a profile ID is selected but the profile record has not loaded yet or mismatches.
        XCTAssertFalse(MetadataCurationPolicy.isActingAdmin(account: admin, profile: nil, activeProfileId: "p2"))
        XCTAssertFalse(MetadataCurationPolicy.canCurateMetadata(account: admin, profile: nil, activeProfileId: "p2"))
        XCTAssertFalse(MetadataCurationPolicy.canEditArtwork(account: admin, profile: nil, activeProfileId: "p2"))
        XCTAssertFalse(MetadataCurationPolicy.isActingAdmin(account: admin, profile: primaryProfile, activeProfileId: "p2"))
        XCTAssertTrue(MetadataCurationPolicy.isActingAdmin(account: admin, profile: primaryProfile, activeProfileId: "p1"))
        XCTAssertTrue(MetadataCurationPolicy.canCurateMetadata(account: adminWithExplicit, profile: nil, activeProfileId: "p2"))
        XCTAssertFalse(MetadataCurationPolicy.canEditArtwork(account: adminWithExplicit, profile: nil, activeProfileId: "p2"))
    }

    // MARK: - Diff-Only Nullable Metadata Patch Encoding

    func testMetadataPatchOmitsUnchangedAndEncodesExplicitNullOnClear() throws {
        var patch = AdminItemMetadataPatch()
        XCTAssertTrue(patch.isEmpty)

        patch.title = "Dune: Part Two"
        patch.releaseDate = .clear
        patch.ratingImdb = .set(8.6)
        patch.ratingTmdb = .clear
        patch.lockedFields = [0, 6, 13]
        XCTAssertFalse(patch.isEmpty)

        let data = try JSONEncoder().encode(patch)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["title"] as? String, "Dune: Part Two")
        XCTAssertTrue(json.keys.contains("release_date"))
        XCTAssertTrue(json["release_date"] is NSNull)
        XCTAssertEqual(json["rating_imdb"] as? Double, 8.6)
        XCTAssertTrue(json.keys.contains("rating_tmdb"))
        XCTAssertTrue(json["rating_tmdb"] is NSNull)
        XCTAssertEqual(json["locked_fields"] as? [Int], [0, 6, 13])

        // Untouched fields must be absent so PATCH stays diff-only.
        XCTAssertFalse(json.keys.contains("overview"))
        XCTAssertFalse(json.keys.contains("first_air_date"))
        XCTAssertFalse(json.keys.contains("air_time"))
        XCTAssertFalse(json.keys.contains("genres"))
    }

    // MARK: - Field Lock Mapping

    func testFieldLockMappingMatchesServerContract() {
        XCTAssertEqual(
            MetadataFieldLock.supportedLocks(for: "movie"),
            [.name, .overview, .contentRating, .runtime, .releaseDates, .rating, .genres, .studios, .tags, .images]
        )
        XCTAssertEqual(
            MetadataFieldLock.supportedLocks(for: "series"),
            [.name, .overview, .contentRating, .releaseDates, .airSchedule, .rating, .genres, .studios, .tags, .images]
        )
        XCTAssertEqual(MetadataFieldLock.supportedLocks(for: "season"), [.name, .overview, .releaseDates])
        XCTAssertEqual(MetadataFieldLock.supportedLocks(for: "episode"), [.name, .overview, .runtime, .releaseDates])

        XCTAssertEqual(MetadataFieldLock.lock(forFieldKey: "sort_title", mediaType: "movie"), .name)
        XCTAssertEqual(MetadataFieldLock.lock(forFieldKey: "tagline", mediaType: "movie"), .overview)
        XCTAssertEqual(MetadataFieldLock.lock(forFieldKey: "air_timezone", mediaType: "series"), .airSchedule)
        XCTAssertEqual(MetadataFieldLock.lock(forFieldKey: "countries", mediaType: "movie"), .tags)
        XCTAssertNil(MetadataFieldLock.lock(forFieldKey: "runtime", mediaType: "season"))
        XCTAssertEqual(MetadataFieldLock.lock(forFieldKey: "runtime", mediaType: "episode"), .runtime)
    }

    // MARK: - Smart Query Detection

    func testDetectedMatchQueryParsesIdsAndProviderURLs() {
        XCTAssertEqual(
            DetectedMatchQuery.parse("Dune: Part Two"),
            DetectedMatchQuery(title: "Dune: Part Two")
        )
        XCTAssertEqual(
            DetectedMatchQuery.parse("TT15239678"),
            DetectedMatchQuery(imdbId: "tt15239678")
        )
        XCTAssertEqual(
            DetectedMatchQuery.parse("https://www.imdb.com/title/tt15239678/?ref_=nv_sr_srsg_0"),
            DetectedMatchQuery(imdbId: "tt15239678")
        )
        XCTAssertEqual(
            DetectedMatchQuery.parse("https://www.themoviedb.org/movie/693134-dune-part-two"),
            DetectedMatchQuery(tmdbId: "693134")
        )
        XCTAssertEqual(
            DetectedMatchQuery.parse("https://www.themoviedb.org/tv/95396-severance"),
            DetectedMatchQuery(tmdbId: "95396")
        )
        XCTAssertEqual(
            DetectedMatchQuery.parse("https://thetvdb.com/dereferrer/series/371980"),
            DetectedMatchQuery(tvdbId: "371980")
        )
    }

    // MARK: - Artwork Slots & Upload Validation

    func testArtworkSlotsExcludeLogosForSeasons() {
        XCTAssertEqual(MetadataImageSlot.slots(forMediaType: "movie"), [.poster, .backdrop, .logo])
        XCTAssertEqual(MetadataImageSlot.slots(forMediaType: "series"), [.poster, .backdrop, .logo])
        XCTAssertEqual(MetadataImageSlot.slots(forMediaType: "season"), [.poster, .backdrop])
        XCTAssertEqual(MetadataImageSlot.slots(forMediaType: "episode"), [])
    }

    func testImageUploadValidatorChecksMagicBytesAndSizeCap() throws {
        XCTAssertThrowsError(try ImageUploadValidator.validate(Data())) { error in
            XCTAssertEqual(error as? ImageUploadValidationError, .empty)
        }

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let validatedJpeg = try ImageUploadValidator.validate(jpeg)
        XCTAssertEqual(validatedJpeg.mimeType, "image/jpeg")
        XCTAssertEqual(validatedJpeg.fileExtension, "jpg")

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let validatedPng = try ImageUploadValidator.validate(png)
        XCTAssertEqual(validatedPng.mimeType, "image/png")
        XCTAssertEqual(validatedPng.fileExtension, "png")

        let webp = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
        let validatedWebp = try ImageUploadValidator.validate(webp)
        XCTAssertEqual(validatedWebp.mimeType, "image/webp")
        XCTAssertEqual(validatedWebp.fileExtension, "webp")

        let bogus = Data("not-an-image".utf8)
        XCTAssertThrowsError(try ImageUploadValidator.validate(bogus)) { error in
            XCTAssertEqual(error as? ImageUploadValidationError, .unsupportedFormat)
        }

        var oversized = Data(repeating: 0, count: ImageUploadValidator.maxBytes + 1)
        oversized[0] = 0xFF
        oversized[1] = 0xD8
        oversized[2] = 0xFF
        XCTAssertThrowsError(try ImageUploadValidator.validate(oversized)) { error in
            XCTAssertEqual(error as? ImageUploadValidationError, .tooLarge(maxBytes: ImageUploadValidator.maxBytes))
        }
    }

    func testMultipartArtworkUploadBodyFormat() throws {
        let png = ValidatedUploadImage(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            mimeType: "image/png",
            fileExtension: "png"
        )
        let body = APIv2Client.artworkUploadMultipartBody(slot: "poster", image: png, boundary: "BOUNDARY123")
        let utf8Prefix = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(utf8Prefix.contains("--BOUNDARY123\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\nposter\r\n"))
        XCTAssertTrue(utf8Prefix.contains("Content-Disposition: form-data; name=\"image\"; filename=\"artwork.png\"\r\n"))
        XCTAssertTrue(utf8Prefix.contains("Content-Type: image/png\r\n\r\n"))
        XCTAssertTrue(utf8Prefix.hasSuffix("\r\n--BOUNDARY123--\r\n"))
    }

    // MARK: - Retry Safety & Card Targets

    func testAdminCurationMutationsAreRegisteredNonRetryable() {
        let paths: [(String, String)] = [
            ("POST", "/api/v2/admin/items/movie:42/match/search"),
            ("POST", "/api/v2/admin/items/movie:42/match/apply"),
            ("POST", "/api/v2/admin/items/movie:42/images/apply"),
            ("POST", "/api/v2/admin/items/movie:42/images/upload"),
            ("PATCH", "/api/v2/admin/items/movie:42/metadata"),
            ("POST", "/api/v2/admin/items/movie:42/refresh-metadata"),
            ("POST", "/api/v2/admin/items/movie:42/metadata-translation"),
        ]
        for (method, path) in paths {
            XCTAssertEqual(
                APIv2MutationCatalog.operation(method: method, path: path)?.retrySafety,
                .nonRetryable,
                "\(method) \(path) must be classified non-retryable"
            )
        }
    }

    func testCardCurationTargetFiltersToMoviesAndSeries() {
        XCTAssertNotNil(MetadataCurationTarget.fromCard(
            contentId: "movie:10",
            mediaType: "movie",
            title: "Dune",
            year: 2021,
            libraryId: 1,
            posterUrl: nil
        ))
        XCTAssertNotNil(MetadataCurationTarget.fromCard(
            contentId: "series:20",
            mediaType: nil,
            title: "Severance",
            year: 2022,
            libraryId: 2,
            posterUrl: nil
        ))
        XCTAssertNil(MetadataCurationTarget.fromCard(
            contentId: "episode:30",
            mediaType: "episode",
            title: "Pilot",
            year: nil,
            libraryId: 2,
            posterUrl: nil
        ))
        XCTAssertNil(MetadataCurationTarget.fromCard(
            contentId: "person:40",
            mediaType: "person",
            title: "Denis Villeneuve",
            year: nil,
            libraryId: nil,
            posterUrl: nil
        ))
    }

    func testAdminTaskJobDecodesV2StateAndFailure() throws {
        let succeededJSON = Data("""
        {
          "id": "job_123",
          "kind": "refresh_item_metadata",
          "state": "succeeded",
          "terminal": true,
          "item_result": {
            "requested_content_id": "movie:10",
            "refresh_content_id": "movie:10",
            "detail_content_id": "movie:99",
            "matched_files": 1,
            "new_files": 0,
            "artwork_cache_incomplete": false
          }
        }
        """.utf8)
        let decoder = HTTPClient.makeJSONDecoder()
        let succeeded = try decoder.decode(AdminTaskJob.self, from: succeededJSON)
        XCTAssertTrue(succeeded.isTerminal)
        XCTAssertTrue(succeeded.isSuccess)
        XCTAssertEqual(succeeded.itemResult?.detailContentId, "movie:99")

        let failedJSON = Data("""
        {
          "id": "job_456",
          "kind": "refresh_item_metadata",
          "state": "failed",
          "terminal": true,
          "failure": {
            "type": "https://silo.example/problems/provider_failed",
            "title": "Provider unavailable",
            "detail": "TMDB timed out",
            "retryable": true
          }
        }
        """.utf8)
        let failed = try decoder.decode(AdminTaskJob.self, from: failedJSON)
        XCTAssertTrue(failed.isTerminal)
        XCTAssertFalse(failed.isSuccess)
        XCTAssertEqual(failed.failure?.displayMessage, "TMDB timed out")
    }

    // MARK: - Edit Metadata Locks, Precision & Validation

    #if !os(tvOS)
    @MainActor
    func testEditMetadataPreservesUnknownLocksAndLosslessRatings() throws {
        let detailJSON = Data("""
        {
          "content_id": "movie:10",
          "type": "movie",
          "title": "Dune",
          "year": 2021,
          "runtime": 155,
          "rating_imdb": 8.24,
          "rating_tmdb": 8.175,
          "locked_fields": [4, 5, 12]
        }
        """.utf8)
        let detail = try HTTPClient.makeJSONDecoder().decode(ItemDetail.self, from: detailJSON)
        let target = MetadataCurationTarget.from(detail: detail, libraryId: 1)
        let vm = EditMetadataViewModel(target: target, preloadedDetail: detail)

        // Opening the sheet must not dirty high-precision ratings or drop unknown server locks.
        XCTAssertEqual(vm.ratingImdb, "8.24")
        XCTAssertEqual(vm.ratingTmdb, "8.175")
        XCTAssertFalse(vm.hasUnsavedChanges)
        XCTAssertTrue(vm.buildPatch().isEmpty)

        // Editing title auto-locks .name (0) while preserving cast (4), crew (5), and videos (12).
        vm.title = "Dune: Part One"
        XCTAssertTrue(vm.hasUnsavedChanges)
        let titlePatch = vm.buildPatch()
        XCTAssertEqual(titlePatch.title, "Dune: Part One")
        XCTAssertEqual(titlePatch.ratingImdb, .unchanged)
        XCTAssertEqual(titlePatch.ratingTmdb, .unchanged)
        XCTAssertEqual(titlePatch.lockedFields, [0, 4, 5, 12])

        // Deliberate small precision rating edits are preserved (no rounding tolerance drop).
        vm.ratingImdb = "8.24001"
        XCTAssertEqual(vm.buildPatch().ratingImdb, .set(8.24001))
        vm.ratingImdb = "8.24"

        // Clearing year/runtime encodes 0 (matching server non-nullable int semantics),
        // while clearable ratings encode explicit JSON null.
        vm.yearText = ""
        vm.runtimeText = ""
        vm.ratingImdb = ""
        let clearPatch = vm.buildPatch()
        let encoded = try JSONEncoder().encode(clearPatch)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["year"] as? Int, 0)
        XCTAssertEqual(json["runtime"] as? Int, 0)
        XCTAssertTrue(json.keys.contains("rating_imdb"))
        XCTAssertTrue(json["rating_imdb"] is NSNull)

        // Non-numeric input surfaces a validation error instead of silently dropping the edit.
        vm.runtimeText = "abc"
        XCTAssertNotNil(vm.validationError)

        // Non-clearable structural numbers (season_number / episode_number) reject blank clears.
        let episodeJSON = Data("""
        {
          "content_id": "episode:42",
          "type": "episode",
          "title": "Pilot",
          "season_number": 1,
          "episode_number": 1
        }
        """.utf8)
        let episodeDetail = try HTTPClient.makeJSONDecoder().decode(ItemDetail.self, from: episodeJSON)
        let epVM = EditMetadataViewModel(
            target: MetadataCurationTarget.from(detail: episodeDetail, libraryId: 1),
            preloadedDetail: episodeDetail
        )
        epVM.episodeNumberText = ""
        XCTAssertNotNil(epVM.validationError)
        XCTAssertNil(epVM.buildPatch().episodeNumber)
    }
    #endif

    // MARK: - Fix Match Scope Isolation & Target Allow-Lists

    @MainActor
    func testFixMatchSwitchLibraryClearsStaleSelectionAndDisablesApply() throws {
        let target = MetadataCurationTarget(
            contentId: "movie:10",
            mediaType: "movie",
            title: "Dune",
            year: 2021,
            libraryId: 1,
            seriesId: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            status: "matched",
            posterUrl: nil,
            backdropUrl: nil,
            logoUrl: nil,
            folderPaths: [],
            fileNames: []
        )
        let vm = FixMatchViewModel(target: target)
        let candidateJSON = Data("""
        {
          "title": "Dune",
          "year": 2021,
          "content_type": "movie",
          "match_score": 84.4,
          "match_reasons": ["provider_sources", "exact_title", "imdb_id"],
          "sources": ["tmdb"],
          "provider_ids": { "tmdb": "438631" }
        }
        """.utf8)
        let candidate = try HTTPClient.makeJSONDecoder().decode(AdminMatchCandidate.self, from: candidateJSON)
        XCTAssertEqual(candidate.formattedMatchScore, "84%")
        XCTAssertEqual(candidate.formattedMatchReasons, ["Provider Sources", "Exact Title", "IMDb ID"])
        vm.selectedCandidate = candidate
        XCTAssertFalse(vm.canApply)

        vm.switchLibrary(to: 2)
        XCTAssertEqual(vm.selectedLibraryId, 2)
        XCTAssertNil(vm.selectedCandidate)
        XCTAssertTrue(vm.candidates.isEmpty)
        XCTAssertFalse(vm.canApply)

        // Manual tvOS Edit Search clears stale filename-hint provider IDs.
        vm.imdbIdText = "tt1160419"
        vm.tmdbIdText = "438631"
        vm.tvdbIdText = "999"
        vm.customProviders = [.init(key: "anilist", value: "123")]
        vm.triggerSearch(clearExternalIds: true)
        XCTAssertEqual(vm.imdbIdText, "")
        XCTAssertEqual(vm.tmdbIdText, "")
        XCTAssertEqual(vm.tvdbIdText, "")
        XCTAssertTrue(vm.customProviders.isEmpty)
        vm.cancelPendingWork()
    }

    func testCurationTargetCapabilitiesRejectNonVideoTypes() {
        let audiobook = MetadataCurationTarget(
            contentId: "audiobook:7",
            mediaType: "audiobook",
            title: "Project Hail Mary",
            year: 2021,
            libraryId: 3,
            seriesId: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            status: "matched",
            posterUrl: nil,
            backdropUrl: nil,
            logoUrl: nil,
            folderPaths: [],
            fileNames: []
        )
        XCTAssertFalse(audiobook.supportsFixMatch)
        XCTAssertFalse(audiobook.supportsArtwork)
        XCTAssertFalse(audiobook.supportsEditMetadata)
        XCTAssertFalse(audiobook.supportsRefresh)
    }

    // MARK: - Helpers

    private func makeAccount(
        id: String,
        username: String,
        role: APIv2AccountRole,
        permissions: [String]?
    ) -> APIv2Account {
        APIv2Account(
            id: id,
            username: username,
            email: nil,
            role: role,
            permissions: permissions,
            downloadAllowed: true,
            impersonation: nil
        )
    }

    private func makeProfile(id: String, isPrimary: Bool, isChild: Bool) -> UserProfile {
        UserProfile(
            id: id,
            name: isPrimary ? "Main" : "Kids",
            avatarEmoji: nil,
            hasPin: false,
            isChild: isChild,
            isPrimary: isPrimary
        )
    }
}
