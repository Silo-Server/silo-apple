import Foundation
import XCTest
@testable import Silo

/// Favorite, watchlist and watched writes through `PersonalStateSync`: one
/// dispatch under a captured owner, and the §9 outcome for each way a
/// `non_retryable` mutation can end. The wire shapes themselves are covered
/// by `CatalogV2Tests`.
final class PersonalStateSyncTests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, TokenStore) {
        let name = "PersonalStateSyncTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://personal.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    @MainActor
    private func set(_ target: PersonalStateTarget, _ contentId: String = "movie:one", to included: Bool = true,
                     api: APIv2Client, tokens: TokenStore, holds: PersonalStateHolds,
                     owner: CapturedOrdinaryRequestAuth? = nil) async -> PersonalStateOutcome {
        await PersonalStateSync.outcome {
            try await PersonalStateSync.set(target, contentId: contentId, to: included, owner: owner,
                                            api: api, tokens: tokens, holds: holds)
        }
    }

    private let notFound = #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"No item"}"#

    @MainActor
    func testAppliedChangeSendsOnceUnderTheCapturedProfile() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        stub.reply(204, "")

        let favorite = await set(.favorite, api: api, tokens: tokens, holds: holds)
        let watched = await set(.watched, to: false, api: api, tokens: tokens, holds: holds)

        XCTAssertEqual(favorite, .applied)
        XCTAssertEqual(watched, .applied)
        XCTAssertEqual(stub.methods, ["PUT", "DELETE"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/favorites/movie:one", "/api/v2/watched/movie:one"])
        XCTAssertEqual(stub.requests.map { $0.header("x-profile-id") }, ["profile-one", "profile-one"])
    }

    @MainActor
    func testDefiniteFailuresReleaseTheFlagWithoutAHold() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()

        stub.reply(404, notFound)
        let rejected = await set(.watchlist, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(rejected, .failed, "a server answer is a definite failure")

        stub.fail(.cannotConnectToHost)
        let unsent = await set(.watchlist, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(unsent, .failed, "a request that never connected is a definite failure")

        stub.reply(204, "")
        let retried = await set(.watchlist, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(retried, .applied, "a released flag accepts the viewer's next change")
        XCTAssertEqual(stub.requests.count, 3)
    }

    @MainActor
    func testUnansweredWatchedChangeIsHeldAndNeverReplayed() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        stub.fail(.networkConnectionLost)

        let first = await set(.watched, api: api, tokens: tokens, holds: holds)
        guard case .held(let change) = first else { return XCTFail("expected a hold, got \(first)") }
        XCTAssertEqual(change.target, .watched)
        XCTAssertEqual(change.contentId, "movie:one")
        XCTAssertTrue(change.included)
        XCTAssertEqual(stub.requests.count, 1)

        // markWatched is non_retryable: a later tap reports the same hold and
        // sends nothing, in either direction.
        stub.reply(204, "")
        let again = await set(.watched, api: api, tokens: tokens, holds: holds)
        let reverse = await set(.watched, to: false, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(again, .held(change))
        XCTAssertEqual(reverse, .held(change))
        XCTAssertEqual(stub.requests.count, 1)

        // The hold covers one flag of one item only.
        let otherFlag = await set(.favorite, api: api, tokens: tokens, holds: holds)
        let otherItem = await set(.watched, "movie:two", api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(otherFlag, .applied)
        XCTAssertEqual(otherItem, .applied)
        XCTAssertEqual(stub.requests.count, 3)

        // Discarding is the only way to release it.
        holds.discard(change)
        let afterDiscard = await set(.watched, to: false, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(afterDiscard, .applied)
        XCTAssertEqual(stub.methods.last, "DELETE")
        XCTAssertEqual(stub.requests.count, 4)
    }

    @MainActor
    func testHoldBelongsToItsOwnerAndResetClearsIt() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        stub.fail(.timedOut)
        let held = await set(.favorite, api: api, tokens: tokens, holds: holds)
        guard case .held = held else { return XCTFail("expected a hold, got \(held)") }

        await tokens.setProfileId("profile-two")
        stub.reply(204, "")
        let otherProfile = await set(.favorite, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(otherProfile, .applied, "another profile's hold does not block this one")

        await tokens.setProfileId("profile-one")
        let original = await set(.favorite, api: api, tokens: tokens, holds: holds)
        guard case .held = original else { return XCTFail("the original owner is still held, got \(original)") }

        holds.reset()
        let afterReset = await set(.favorite, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(afterReset, .applied)
        XCTAssertEqual(stub.requests.count, 3)
    }

    @MainActor
    func testReplacedOwnerIsSkippedBeforeDispatch() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        await tokens.setProfileId("profile-two")
        stub.reply(204, "")

        let outcome = await set(.watchlist, api: api, tokens: tokens, holds: holds, owner: owner)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(stub.requests.isEmpty, "nothing is sent for a replaced owner")
        XCTAssertNil(holds.change(for: .watchlist, contentId: "movie:one", owner: owner))
    }

    @MainActor
    func testOwnerChangeWhileInFlightAppliesNothingLocally() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        stub.reply(204, "")
        stub.hold()
        let pending = Task { @MainActor in
            await self.set(.favorite, api: api, tokens: tokens, holds: holds)
        }
        await stub.waitUntilHeld()
        await tokens.setProfileId("profile-two")
        stub.release()

        let outcome = await pending.value
        XCTAssertEqual(outcome, .skipped, "a receipt for a replaced owner is not applied to the new one")
        XCTAssertEqual(stub.requests.count, 1)
    }

    @MainActor
    func testSecondChangeToTheSameFlagWaitsForTheFirst() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        stub.reply(204, "")
        stub.hold()
        let first = Task { @MainActor in
            await self.set(.watchlist, api: api, tokens: tokens, holds: holds)
        }
        await stub.waitUntilHeld()

        let second = await set(.watchlist, to: false, api: api, tokens: tokens, holds: holds)
        XCTAssertEqual(second, .skipped)
        stub.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .applied)
        XCTAssertEqual(stub.requests.count, 1)
    }

    // MARK: Home

    @MainActor
    func testHomeOffersAHeldWatchedChangeForDiscardInsteadOfAnError() async throws {
        let (_, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let change = PersonalStateHeldChange(
            id: UUID(), owner: try XCTUnwrap(captured), target: .watched, contentId: "target", included: true
        )
        let item = try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"target","type":"movie","title":"Synthetic"}"#.utf8
        ))
        let viewModel = HomeViewModel(setWatched: { _, _ in throw PersonalStateMutationError.held(change) })

        let succeeded = await viewModel.setWatched(item, played: true)

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.actionError, "an unconfirmed change is not reported as a failure")
        XCTAssertEqual(viewModel.personalStateNotice, .held(change))
    }

    // MARK: Detail read (F28)

    @MainActor
    func testDetailProjectionCarriesTheViewersFlags() throws {
        let body = #"{"content_id":"movie:one","type":"movie","title":"One","status":"available","genres":[],"keywords":[],"cast":[],"crew":[],"versions":[],"subtitles":[],"user_state":{"played":true,"is_favorite":true,"in_watchlist":false}}"#
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: Data(body.utf8))
        let detail = try ItemDetail(catalog: wire)
        XCTAssertEqual(detail.userState, MediaItemUserState(played: true, isFavorite: true, inWatchlist: false))

        let withoutProfile = body.replacingOccurrences(
            of: #","user_state":{"played":true,"is_favorite":true,"in_watchlist":false}"#, with: "")
        let anonymous = try ItemDetail(catalog: HTTPClient.makeJSONDecoder().decode(
            APIv2CatalogRead.CatalogItemDetail.self, from: Data(withoutProfile.utf8)))
        XCTAssertNil(anonymous.userState, "absent user_state is not read as all-false")
    }
}
