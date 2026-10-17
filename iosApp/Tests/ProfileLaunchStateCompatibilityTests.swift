import Foundation
import XCTest
@testable import Silo

/// `ProfileLaunchState.load` resets to a fresh state when decoding fails, and
/// a fresh TV state is Every Time. State saved by the build before Silo users
/// must keep decoding with its behavior intact.
final class ProfileLaunchStateCompatibilityTests: XCTestCase {
    private let server = "aG9tZQ"
    private let epoch = "8C2F0D7E-3B7A-4E54-9A51-5E0B9C5F1A10"

    /// Output of 9f8f7caf's `JSONEncoder().encode(_:)` with every field set.
    private let savedBeforeUsers = #"{"rememberedByServerID":{"aG9tZQ":{"profileID":"default","accountEpoch":"8C2F0D7E-3B7A-4E54-9A51-5E0B9C5F1A10","requiredPINAtSelection":true}},"backgroundedAt":782000000.5,"selectionRequiredServerIDs":["b3RoZXI"],"rememberOfferPending":false,"behavior":"afterOneHour"}"#
    /// 9f8f7caf's `ProfileLaunchState.fresh(isTV: true)`, as a fresh Apple TV saves it.
    private let freshTVBeforeUsers = #"{"rememberedByServerID":{},"behavior":"askEveryLaunch","selectionRequiredServerIDs":[],"rememberOfferPending":true}"#

    private func key(_ accountID: String, server: String? = nil) -> SignInKey {
        SignInKey(serverID: server ?? self.server, accountID: accountID)!
    }

    func testStateSavedBeforeUsersDecodesWithUnchangedBehavior() throws {
        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(savedBeforeUsers.utf8))
        let remembered = RememberedProfile(profileID: "default", requiredPINAtSelection: true, accountEpoch: epoch)
        let backgroundedAt = Date(timeIntervalSinceReferenceDate: 782_000_000.5)
        XCTAssertEqual(decoded, ProfileLaunchState(
            behavior: .afterOneHour,
            rememberedByServerID: [server: remembered],
            selectionRequiredServerIDs: ["b3RoZXI"],
            backgroundedAt: backgroundedAt,
            rememberOfferPending: false
        ))
        XCTAssertNil(decoded.askFor)
        XCTAssertNil(decoded.linkedUserID)
        XCTAssertNil(decoded.lastServerByUserID)
        XCTAssertNil(decoded.rememberedBySignIn)
        XCTAssertNil(decoded.selectionRequiredSignIns)
        XCTAssertEqual(decoded.effectiveAskFor, .profileOnly)

        let beforeTimeout = backgroundedAt.addingTimeInterval(60)
        XCTAssertEqual(
            decoded.resolution(for: server, accountEpoch: epoch, hasStoredProfileToken: true, now: beforeTimeout),
            .restore(remembered)
        )
        XCTAssertEqual(
            decoded.resolution(for: "b3RoZXI", accountEpoch: epoch, hasStoredProfileToken: true, now: beforeTimeout),
            .needsSelection
        )
        XCTAssertTrue(decoded.requiresSelectionAfterBackground(at: backgroundedAt.addingTimeInterval(3600)))

        let fresh = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(freshTVBeforeUsers.utf8))
        XCTAssertEqual(fresh, .fresh(isTV: true))
    }

    /// The reset hazard itself: `load` must return the saved state, not a fresh one.
    func testLoadKeepsStateSavedBeforeUsers() throws {
        let name = "ProfileLaunchStateCompatibilityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(Data(savedBeforeUsers.utf8), forKey: SharedStorage.profileLaunchStateKey)

        let loaded = ProfileLaunchState.load(from: defaults)

        XCTAssertEqual(loaded.behavior, .afterOneHour)
        XCTAssertEqual(loaded.rememberedByServerID[server]?.profileID, "default")
        XCTAssertNotEqual(loaded, .freshForCurrentDevice)
    }

    func testNewFieldsRoundTrip() throws {
        var state = ProfileLaunchState.fresh(isTV: true)
        state.askFor = .userAndProfile
        state.linkedUserID = "user-a"
        state.lastServerByUserID = ["user-a": server]
        state.rememberedBySignIn = [key("12").storageKey: RememberedProfile(
            profileID: "kids", requiredPINAtSelection: false, accountEpoch: epoch)]
        state.selectionRequiredSignIns = [key("13").storageKey]

        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.effectiveAskFor, .userAndProfile)
        XCTAssertEqual(decoded.lastServer(for: "user-a"), server)
        XCTAssertNil(decoded.lastServer(for: "user-b"))
    }

    func testLegacyRememberedProfileCountsOnlyWithAMatchingEpoch() {
        let legacy = RememberedProfile(profileID: "default", requiredPINAtSelection: false, accountEpoch: epoch)
        var state = ProfileLaunchState(rememberedByServerID: [server: legacy])
        let alex = key("12")

        XCTAssertEqual(state.rememberedProfile(for: alex, accountEpoch: epoch), legacy)
        XCTAssertNil(state.rememberedProfile(for: alex, accountEpoch: "another-epoch"),
            "another sign-in on the server has its own epoch")
        XCTAssertNil(state.rememberedProfile(for: alex, accountEpoch: nil))
        XCTAssertNil(state.rememberedProfile(for: key("12", server: "b3RoZXI"), accountEpoch: epoch))
        XCTAssertEqual(state.resolution(for: alex, accountEpoch: epoch, hasStoredProfileToken: false,
            legacyOwnerAccountID: "12"), .restore(legacy))
        XCTAssertEqual(state.resolution(for: key("13"), accountEpoch: "another-epoch", hasStoredProfileToken: false,
            legacyOwnerAccountID: "12"), .needsSelection)

        let current = RememberedProfile(profileID: "kids", requiredPINAtSelection: false, accountEpoch: "new-epoch")
        state.rememberedBySignIn = [alex.storageKey: current]
        XCTAssertEqual(state.rememberedProfile(for: alex, accountEpoch: epoch), current,
            "the sign-in's own entry wins over the server's")
        XCTAssertEqual(state.resolution(for: alex, accountEpoch: "new-epoch", hasStoredProfileToken: false,
            legacyOwnerAccountID: "12"), .restore(current))
        XCTAssertEqual(state.resolution(for: alex, accountEpoch: epoch, hasStoredProfileToken: false,
            legacyOwnerAccountID: "12"), .needsSelection, "an entry from an older session of this sign-in is stale")
    }

    func testLegacyPendingSwitchAppliesOnlyToTheLegacyOwner() {
        let remembered = RememberedProfile(profileID: "default", requiredPINAtSelection: false, accountEpoch: epoch)
        var state = ProfileLaunchState(rememberedByServerID: [server: remembered], selectionRequiredServerIDs: [server])
        let alex = key("12")
        let sam = key("13")

        XCTAssertTrue(state.isSelectionRequired(for: alex, legacyOwnerAccountID: "12"))
        XCTAssertFalse(state.isSelectionRequired(for: sam, legacyOwnerAccountID: "12"))
        XCTAssertFalse(state.isSelectionRequired(for: alex, legacyOwnerAccountID: nil))
        XCTAssertEqual(state.resolution(for: alex, accountEpoch: epoch, hasStoredProfileToken: false,
            legacyOwnerAccountID: "12"), .needsSelection)

        state.selectionRequiredServerIDs = []
        state.selectionRequiredSignIns = [sam.storageKey]
        XCTAssertTrue(state.isSelectionRequired(for: sam, legacyOwnerAccountID: "12"))
        XCTAssertFalse(state.isSelectionRequired(for: alex, legacyOwnerAccountID: "12"))
        XCTAssertEqual(state.resolution(for: alex, accountEpoch: epoch, hasStoredProfileToken: false,
            legacyOwnerAccountID: "12"), .restore(remembered))
    }
}
