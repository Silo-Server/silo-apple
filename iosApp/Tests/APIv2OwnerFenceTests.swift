import Foundation
import XCTest
@testable import Silo

/// The owner fence of every owner-bound v2 call, one row per call: the v1
/// gate runs before anything else, a replaced owner is refused before any
/// byte leaves the device, and an owner replaced while the request is in
/// flight never gets the answer. Each row names the error its call reports
/// for those cases, so a call that skips its owner check, loses the fence or
/// changes how it reports an owner change fails here.
final class APIv2OwnerFenceTests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client(profile: String? = "profile-one", updateRequired: Bool = false,
                        captureBarrier: (@Sendable (TokenStore) async -> Void)? = nil) async throws -> (APIv2Client, TokenStore) {
        let name = "APIv2OwnerFenceTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://fence.example")
        if let profile { await tokens.setProfileId(profile) }
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens,
            requestCaptureBarrier: { await captureBarrier?(tokens) })
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { updateRequired }), tokens)
    }

    private func owner(_ tokens: TokenStore) async throws -> CapturedOrdinaryRequestAuth {
        let auth = await tokens.captureOrdinaryRequestAuth()
        return try XCTUnwrap(auth)
    }

    /// How a call ended.
    private enum Outcome: Equatable, Sendable {
        case returned
        case identityChanged
        case authorityChanged
        case ownerChangedBeforeDispatch
        case serverUpdateRequired
        case requestOutcomeUnknown
        case subtitleCreationUnknown
        case subtitleDownloadUnknown
        case other(String)

        init(_ error: Error) {
            switch error {
            case HTTPError.requestIdentityChanged: self = .identityChanged
            case HTTPError.authorityChanged: self = .authorityChanged
            case is APIv2OwnerChangedBeforeDispatch: self = .ownerChangedBeforeDispatch
            case APIv2Error.serverUpdateRequired: self = .serverUpdateRequired
            case APIv2RequestsError.outcomeUnknownOwnerChanged: self = .requestOutcomeUnknown
            case SubtitleCreationError.outcomeUnknown: self = .subtitleCreationUnknown
            case APIv2SubtitleRequestError.outcomeUnknownOwnerChanged: self = .subtitleDownloadUnknown
            default: self = .other(String(describing: error))
            }
        }
    }

    private static func outcome(_ call: @Sendable () async throws -> Void) async -> Outcome {
        do {
            try await call()
            return .returned
        } catch {
            return Outcome(error)
        }
    }

    // MARK: Calls under a caller-supplied owner

    private struct Row: Sendable {
        let name: String
        /// The owner was replaced after the caller captured it.
        let beforeCall: Outcome
        /// The owner was replaced while the request was at the server.
        let inFlight: Outcome
        let call: @Sendable (APIv2Client, CapturedOrdinaryRequestAuth) async throws -> Void

        init(_ name: String, before beforeCall: Outcome = .identityChanged, inFlight: Outcome = .authorityChanged,
             _ call: @escaping @Sendable (APIv2Client, CapturedOrdinaryRequestAuth) async throws -> Void) {
            self.name = name
            self.beforeCall = beforeCall
            self.inFlight = inFlight
            self.call = call
        }
    }

    private var ownerRows: [Row] {
        var rows: [Row] = [
            // Profile-scoped catalog, home and membership calls.
            Row("catalogFilters") { _ = try await $0.catalogFilters(libraryId: "7", includeTechnical: false, auth: $1) },
            Row("libraryCollectionTab") { _ = try await $0.libraryCollectionTab(libraryId: "7", auth: $1) },
            Row("setWatchedState") { try await $0.setWatchedState(id: "movie:one", included: true, auth: $1) },
            Row("setFavoriteMembership") { try await $0.setFavoriteMembership(id: "movie:one", included: false, auth: $1) },
            Row("setWatchlistMembership") { try await $0.setWatchlistMembership(id: "movie:one", included: true, auth: $1) },
            Row("personalMembership") { _ = try await $0.personalMembership(id: "movie:one", watchlist: true, auth: $1) },
            Row("discover") { _ = try await $0.discover(auth: $1) },
            Row("dismissHomeItem") {
                try await $0.dismissHomeItem(id: "movie:one", progressUpdatedAt: "2026-09-01T00:00:00Z",
                                             seriesId: nil, auth: $1)
            },
            Row("librarySections") { _ = try await $0.librarySections(id: 7, imageSize: nil, auth: $1) },
            Row("homeSections") { _ = try await $0.homeSections(imageSize: nil, auth: $1) },
            Row("calendar") {
                _ = try await $0.calendar(start: "2026-09-21", end: "2026-09-27", filter: "following",
                                          timezone: "UTC", auth: $1)
            },
            Row("similarCards") { _ = try await $0.similarCards(id: "movie:one", limit: 10, auth: $1) },
            Row("refreshTrailers") { _ = try await $0.refreshTrailers(id: "movie:one", auth: $1) },
            Row("catalogItem") { _ = try await $0.catalogItem(id: "movie:one", imageSize: nil, auth: $1) },
            Row("catalogSeasons") { _ = try await $0.catalogSeasons(seriesId: "series", imageSize: nil, auth: $1) },
            Row("catalogEpisodes") {
                _ = try await $0.catalogEpisodes(seriesId: "series", seasonNumber: 1, imageSize: nil, auth: $1)
            },
            Row("catalogPerson") { _ = try await $0.catalogPerson(id: "7", auth: $1) },
            Row("refreshPerson") { try await $0.refreshPerson(id: "7", auth: $1) },
            Row("watchDetail") { _ = try await $0.watchDetail(id: "movie:one", imageSize: nil, auth: $1) },
            Row("writeTrackPreference") {
                try await $0.writeTrackPreference(kind: .audio, seriesId: "series", body: ["language": "en"], auth: $1)
            },
            Row("deleteTrackPreference") { try await $0.deleteTrackPreference(kind: .subtitle, seriesId: "series", auth: $1) },
            Row("updateProfile") { _ = try await $0.updateProfile(id: "profile-one", patch: APIv2ProfilePatch(), auth: $1) },
            Row("onboardingWrite") {
                let state = OnboardingState(tourId: "tour", lastStep: nil, completedAt: nil, skippedAt: nil, done: false)
                let session = APIv2OnboardingSession(auth: $1, tag: "\"v1\"", state: state, flow: nil)
                _ = try await $0.onboardingWrite(
                    OnboardingProgressRequest(tourId: "tour", lastStep: "features", completed: false, skipped: false),
                    session: session)
            },

            // Pages: the owner is checked before every page.
            Row("catalogPage") { _ = try await $0.catalogPage(query: APIv2CatalogQuery(), auth: $1) },
            Row("personalList") { _ = try await $0.personalList(kind: .favorites, auth: $1) },
            Row("listAllProgress") { _ = try await $0.listAllProgress(auth: $1) },

            // No owner check of their own: the fence's entry check refuses.
            Row("catalogSearchCapabilities", before: .authorityChanged) { _ = try await $0.catalogSearchCapabilities(auth: $1) },
            Row("playbackCapabilities", before: .authorityChanged) { _ = try await $0.playbackCapabilities(auth: $1) },

            // Personal collections tell a refusal before dispatch apart.
            Row("collectionCapabilities", before: .ownerChangedBeforeDispatch) { _ = try await $0.collectionCapabilities(auth: $1) },
            Row("createCollection", before: .ownerChangedBeforeDispatch) { _ = try await $0.createCollection(name: "New", auth: $1) },
            Row("deleteCollection", before: .ownerChangedBeforeDispatch) {
                try await $0.deleteCollection(CollectionEditVersion(path: "/api/v2/collections/c1", etag: "\"v1\"", auth: $1))
            },

            // Downloads and series monitors.
            Row("downloadCapability") { _ = try await $0.downloadCapability(auth: $1) },
            Row("deleteDownload") { try await $0.deleteDownload(id: "d1", auth: $1) },
            Row("listDownloadSubscriptions") { _ = try await $0.listDownloadSubscriptions(auth: $1) },

            // Watch Party.
            Row("watchPartyCapabilities") { _ = try await $0.watchPartyCapabilities(auth: $1) },
            Row("closeWatchPartyRoom") { try await $0.closeWatchPartyRoom(roomId: "room", token: "token", auth: $1) },

            // Metadata and subtitle AI, subtitle downloads.
            Row("translateDescription") {
                _ = try await $0.translateDescription(contentID: "movie:one", language: "fr", auth: $1)
            },
            Row("storedSubtitles") { _ = try await $0.storedSubtitles(mediaFileID: 42, auth: $1) },
            Row("subtitleJob") { _ = try await $0.subtitleJob(id: "job", auth: $1) },
            Row("cancelSubtitleJob") { try await $0.cancelSubtitleJob(id: "job", auth: $1) },
            Row("createSubtitle", inFlight: .subtitleCreationUnknown) {
                let body = try APIv2SubtitleCreateBody(TranslateSubtitleBody(mediaFileId: 42, kind: .translate,
                    sourceIndex: 0, sourceLanguage: "en", targetLanguage: "fr", sessionId: nil, startPosition: 0))
                _ = try await $0.createSubtitle(body, auth: $1)
            },
            Row("downloadSubtitle", inFlight: .subtitleDownloadUnknown) {
                let body = SubtitleDownloadBody(
                    from: SubtitleSearchResult(id: "os-123", provider: "opensubtitles", language: "en",
                                               releaseName: "Some.Movie", format: "srt", score: 87.5,
                                               hearingImpaired: false),
                    mediaFileId: 42)
                _ = try await $0.downloadSubtitle(body, auth: $1)
            },
        ]
        #if os(iOS) || os(tvOS)
        rows.append(Row("abortDiagnosticsUpload", before: .ownerChangedBeforeDispatch) {
            try await $0.abortDiagnosticsUpload(uploadID: "upload", auth: $1)
        })
        #endif
        #if os(iOS)
        rows.append(Row("notificationSync") { _ = try await $0.notificationSync(cursor: nil, auth: $1) })
        rows.append(Row("applePushRegistrationCapability", before: .authorityChanged) {
            _ = try await $0.applePushRegistrationCapability(auth: $1)
        })
        #endif
        return rows
    }

    func testOwnerBoundCallsRefuseAReplacedOwnerBeforeDispatchAndDropALateAnswer() async throws {
        for row in ownerRows {
            // The v1 gate refuses first, even for an owner that has changed.
            stub.reset()
            let (gated, gatedTokens) = try await client(updateRequired: true)
            let gatedOwner = try await owner(gatedTokens)
            await gatedTokens.setProfileToken("replacement")
            let gatedOutcome = await Self.outcome { try await row.call(gated, gatedOwner) }
            XCTAssertEqual(gatedOutcome, .serverUpdateRequired, "\(row.name): the v1 gate runs first")
            XCTAssertTrue(stub.requests.isEmpty, "\(row.name): nothing leaves a v1-only session")

            // Owner replaced after the caller captured it.
            stub.reset()
            let (api, tokens) = try await client()
            let stale = try await owner(tokens)
            await tokens.setProfileToken("replacement")
            let refused = await Self.outcome { try await row.call(api, stale) }
            XCTAssertEqual(refused, row.beforeCall, "\(row.name): a replaced owner is refused")
            XCTAssertTrue(stub.requests.isEmpty, "\(row.name): nothing leaves the device for a replaced owner")

            // Owner replaced while the request is at the server.
            stub.reset()
            let (live, liveTokens) = try await client()
            let current = try await owner(liveTokens)
            stub.reply(200, "{}")
            stub.hold()
            let pending = Task { await Self.outcome { try await row.call(live, current) } }
            await stub.waitUntilHeld()
            await liveTokens.setProfileToken("another")
            stub.release()
            let late = await pending.value
            XCTAssertEqual(late, row.inFlight, "\(row.name): an answer for a replaced owner is dropped")
            XCTAssertEqual(stub.requests.count, 1, "\(row.name): sent once")
            XCTAssertEqual(stub.requests.first?.header("x-profile-id"), "profile-one", "\(row.name): sent for the owner")
        }
    }

    // MARK: Calls that capture the current owner themselves

    private struct AmbientRow: Sendable {
        let name: String
        /// The owner changed just before `HTTPClient` captured credentials;
        /// nil for a call that does not go through the scoped request path.
        let atCapture: Outcome?
        let inFlight: Outcome
        /// The held answer. A call that decodes inside its fence needs one it
        /// can decode, so the fence's exit check is what rejects it.
        let answer: String
        let call: @Sendable (APIv2Client) async throws -> Void

        init(_ name: String, atCapture: Outcome? = .identityChanged, inFlight: Outcome = .authorityChanged,
             answer: String = "{}", _ call: @escaping @Sendable (APIv2Client) async throws -> Void) {
            self.name = name
            self.atCapture = atCapture
            self.inFlight = inFlight
            self.answer = answer
            self.call = call
        }
    }

    private var ambientRows: [AmbientRow] {
        [
            AmbientRow("listProgress") { _ = try await $0.listProgress(limit: 5) },
            AmbientRow("userLibraries") { _ = try await $0.userLibraries() },
            AmbientRow("householdProfiles") { _ = try await $0.householdProfiles() },
            AmbientRow("catalogItem (ambient)") { _ = try await $0.catalogItem(id: "movie:one") },
            AmbientRow("overlayConfig") { _ = try await $0.overlayConfig() },
            AmbientRow("metadataAIStatus") { _ = try await $0.metadataAIStatus() },
            AmbientRow("deleteSettingValue") {
                try await $0.deleteSettingValue(key: .navShortcuts, scope: .profile, profileID: "profile-one")
            },
            AmbientRow("onboardingRead") { _ = try await $0.onboardingRead() },
            AmbientRow("requestsStatus") { _ = try await $0.requestsStatus() },
            AmbientRow("myRequests") { _ = try await $0.myRequests() },
            AmbientRow("createRequest", atCapture: .requestOutcomeUnknown, inFlight: .requestOutcomeUnknown) {
                _ = try await $0.createRequest(CreateRequestInput(mediaType: .movie, tmdbId: 1, tvdbId: nil, imdbId: nil,
                    title: "Movie", year: nil, overview: nil, posterPath: nil, backdropPath: nil))
            },
            AmbientRow("subtitleAIStatus") { _ = try await $0.subtitleAIStatus() },
            AmbientRow("currentUser", atCapture: nil,
                       answer: #"{"id":"1","username":"u","email":"u@example.com","role":"user","permissions":[],"download_allowed":true}"#) {
                _ = try await $0.currentUser()
            },
        ]
    }

    func testAmbientOwnerCallsRefuseAnOwnerReplacedAtCaptureAndDropALateAnswer() async throws {
        for row in ambientRows {
            stub.reset()
            let (gated, _) = try await client(updateRequired: true)
            let gatedOutcome = await Self.outcome { try await row.call(gated) }
            XCTAssertEqual(gatedOutcome, .serverUpdateRequired, "\(row.name): the v1 gate runs first")
            XCTAssertTrue(stub.requests.isEmpty, "\(row.name): nothing leaves a v1-only session")

            if let atCapture = row.atCapture {
                stub.reset()
                let (blocked, _) = try await client(captureBarrier: { await $0.setProfileId("profile-two") })
                let refused = await Self.outcome { try await row.call(blocked) }
                XCTAssertEqual(refused, atCapture, "\(row.name): an owner replaced at capture is refused")
                XCTAssertTrue(stub.requests.isEmpty, "\(row.name): nothing leaves the device for a replaced owner")
            }

            stub.reset()
            let (live, liveTokens) = try await client()
            stub.reply(200, row.answer)
            stub.hold()
            let pending = Task { await Self.outcome { try await row.call(live) } }
            await stub.waitUntilHeld()
            await liveTokens.setProfileToken("another")
            stub.release()
            let late = await pending.value
            XCTAssertEqual(late, row.inFlight, "\(row.name): an answer for a replaced owner is dropped")
            XCTAssertEqual(stub.requests.count, 1, "\(row.name): sent once")
        }
    }

    // MARK: Profile header

    /// A request made before any profile is selected says so with an empty
    /// `X-Profile-Id` rather than leaving the server to pick one; once a
    /// profile is selected the same calls name it.
    func testCallsWithoutAProfileSendAnEmptyProfileHeader() async throws {
        for (profile, expected) in [(nil, ""), ("profile-one", "profile-one")] as [(String?, String)] {
            stub.reset()
            let (api, tokens) = try await client(profile: profile)
            let auth = try await owner(tokens)
            stub.reply(200, #"{"items":[],"page":{"has_more":false}}"#)
            _ = try await api.listProgress(limit: 5)
            stub.reply(204, "")
            _ = try await api.ownedRequest(method: "DELETE", path: "/api/v2/diagnostics/reports/uploads/upload",
                                           auth: auth)
            _ = try await api.subtitlesRequest("POST", path: "/api/v2/subtitles/ai/jobs/job/cancel", auth: auth)
            XCTAssertEqual(stub.requests.map { $0.header("x-profile-id") }, [expected, expected, expected],
                           "profile \(profile ?? "none")")
        }
    }
}
