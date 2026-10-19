import Foundation
import XCTest
@testable import Silo

/// `ProfileLaunchState.load` resets to a fresh state when decoding fails, and
/// a fresh TV state is Every Time. State saved by the build before Silo
/// accounts, and by the first multi-account build, must keep decoding with
/// its behavior intact.
final class ProfileLaunchStateCompatibilityTests: XCTestCase {
    private let server = "aG9tZQ"
    private let epoch = "8C2F0D7E-3B7A-4E54-9A51-5E0B9C5F1A10"

    /// Output of 9f8f7caf's `JSONEncoder().encode(_:)` with every field set.
    private let savedBeforeAccounts = #"{"rememberedByServerID":{"aG9tZQ":{"profileID":"default","accountEpoch":"8C2F0D7E-3B7A-4E54-9A51-5E0B9C5F1A10","requiredPINAtSelection":true}},"backgroundedAt":782000000.5,"selectionRequiredServerIDs":["b3RoZXI"],"rememberOfferPending":false,"behavior":"afterOneHour"}"#
    /// 9f8f7caf's `ProfileLaunchState.fresh(isTV: true)`, as a fresh Apple TV saves it.
    private let freshTVBeforeAccounts = #"{"rememberedByServerID":{},"behavior":"askEveryLaunch","selectionRequiredServerIDs":[],"rememberOfferPending":true}"#
    /// The first multi-account build linked a Silo user and kept each
    /// user's last server.
    private let savedByFirstMultiAccountBuild = #"{"rememberedByServerID":{},"behavior":"askEveryLaunch","selectionRequiredServerIDs":[],"askFor":"userAndProfile","linkedUserID":"6F1C2B9A-0D4E-4C1B-8E2F-3A5B7C9D1E2F","lastServerByUserID":{"6F1C2B9A-0D4E-4C1B-8E2F-3A5B7C9D1E2F":"aG9tZQ"},"rememberedBySignIn":{"aG9tZQ/12":{"profileID":"kids","accountEpoch":"8C2F0D7E-3B7A-4E54-9A51-5E0B9C5F1A10","requiredPINAtSelection":false}},"selectionRequiredSignIns":["aG9tZQ/13"]}"#

    private func key(_ accountID: String, server: String? = nil) -> SignInKey {
        SignInKey(serverID: server ?? self.server, accountID: accountID)!
    }

    func testStateSavedBeforeAccountsDecodesWithUnchangedBehavior() throws {
        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(savedBeforeAccounts.utf8))
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
        XCTAssertNil(decoded.linkedAccount)
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

        let fresh = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(freshTVBeforeAccounts.utf8))
        XCTAssertEqual(fresh, .fresh(isTV: true))
    }

    /// The reset hazard itself: `load` must return the saved state, not a fresh one.
    func testLoadKeepsStateSavedBeforeAccounts() throws {
        let name = "ProfileLaunchStateCompatibilityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(Data(savedBeforeAccounts.utf8), forKey: SharedStorage.profileLaunchStateKey)

        let loaded = ProfileLaunchState.load(from: defaults)

        XCTAssertEqual(loaded.behavior, .afterOneHour)
        XCTAssertEqual(loaded.rememberedByServerID[server]?.profileID, "default")
        XCTAssertNotEqual(loaded, .freshForCurrentDevice)
    }

    /// Its user link is dropped, so this Apple TV user chooses an account
    /// once; everything kept per sign-in, and Ask For, carry over.
    func testStateSavedByTheFirstMultiAccountBuildDecodesWithoutALink() throws {
        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(savedByFirstMultiAccountBuild.utf8))

        XCTAssertNil(decoded.linkedAccount)
        XCTAssertNil(decoded.linkedAccountRef)
        XCTAssertEqual(decoded.behavior, .askEveryLaunch)
        XCTAssertEqual(decoded.askFor, .accountAndProfile)
        XCTAssertEqual(decoded.rememberedBySignIn?[key("12").storageKey]?.profileID, "kids")
        XCTAssertEqual(decoded.selectionRequiredSignIns, [key("13").storageKey])
    }

    func testNewFieldsRoundTrip() throws {
        var state = ProfileLaunchState.fresh(isTV: true)
        state.askFor = .accountAndProfile
        state.linkedAccount = SiloAccountRef.signIn(key("12")).storageKey
        state.rememberedBySignIn = [key("12").storageKey: RememberedProfile(
            profileID: "kids", requiredPINAtSelection: false, accountEpoch: epoch)]
        state.selectionRequiredSignIns = [key("13").storageKey]

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: encoded)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.effectiveAskFor, .accountAndProfile)
        XCTAssertEqual(decoded.linkedAccountRef, .signIn(key("12")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["askFor"] as? String, "userAndProfile", "stored under the first build's name")

        state.linkedAccount = SiloAccountRef.pendingLegacy(serverID: server).storageKey
        XCTAssertEqual(state.linkedAccountRef, .pendingLegacy(serverID: server))
        state.linkedAccount = "6F1C2B9A-0D4E-4C1B-8E2F-3A5B7C9D1E2F"
        XCTAssertNil(state.linkedAccountRef, "anything else names no account")
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
