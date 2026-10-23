#if os(iOS)
import Foundation
import XCTest
@testable import Silo

/// A push names its server and profile, not its account, and profile IDs
/// repeat across accounts on one server. The display target the push was
/// shown with records the account that registered it, so a tap opens only
/// under that account.
final class PushAccountAttributionTests: XCTestCase {
    private var keychain: SharedKeychain!
    private var targets: ApplePushDisplayTargetStore!

    private let server = ServerEntry(id: "registry-a", url: "https://a.example", fetchedName: nil, lastUsedAt: Date(),
                                     verifiedServerId: "deployment-a")

    override func setUpWithError() throws {
        keychain = SharedKeychain(service: "PushAccountAttributionTests.\(UUID().uuidString)", accessGroup: nil)
        targets = ApplePushDisplayTargetStore(keychain: keychain)
    }

    override func tearDownWithError() throws {
        keychain.delete(SharedStorage.applePushDisplayTargetsAccount)
    }

    private func pushLink() throws -> URL {
        try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "/item/movie-1", "silo_server_id": "deployment-a", "silo_profile_id": "default",
        ]))
    }

    private func saveTarget(accountID: String?) {
        XCTAssertTrue(targets.save(ApplePushDisplayTarget(
            serverID: "deployment-a", profileID: "default", registryServerID: server.id, serverURL: server.url,
            displayToken: "display-a", expiresAt: nil, accountID: accountID
        )))
    }

    private func opens(_ link: URL, as accountID: String?,
                       legacyOwner: @escaping AccountScopedKeyAdoption.LegacyOwner = { _ in nil }) -> Bool {
        ApplePushDeepLinkCoordinator.opensUnderActiveIdentity(
            link, activeServer: server, activeProfileID: "default", activeAccountID: accountID,
            targets: targets, legacyOwner: legacyOwner
        )
    }

    func testAPushForOneAccountsDefaultProfileNeverOpensUnderAnothers() throws {
        saveTarget(accountID: "12")
        let link = try pushLink()

        XCTAssertTrue(opens(link, as: "12"))
        XCTAssertFalse(opens(link, as: "13"))
        XCTAssertEqual(ApplePushDeepLinkCoordinator.admission(
            for: link, profileInUse: true, activeServer: server, activeProfileID: "default",
            activeAccountID: "13", targets: targets, legacyOwner: { _ in nil }
        ), .drop)
        XCTAssertEqual(ApplePushDeepLinkCoordinator.admission(
            for: link, profileInUse: false, activeServer: server, activeProfileID: nil,
            activeAccountID: "13", targets: targets, legacyOwner: { _ in nil }
        ), .wait)
    }

    func testATargetSavedBeforeAccountsBelongsToTheServersLegacyOwner() throws {
        saveTarget(accountID: nil)
        let link = try pushLink()
        let alexOwnsIt: AccountScopedKeyAdoption.LegacyOwner = { $0 == "registry-a" ? "12" : nil }

        XCTAssertTrue(opens(link, as: "12", legacyOwner: alexOwnsIt))
        XCTAssertFalse(opens(link, as: "13", legacyOwner: alexOwnsIt))
        XCTAssertFalse(opens(link, as: "12"), "no owner: the target names no known account")
        XCTAssertEqual(targets.targets().first?.attributedAccountID(legacyOwner: alexOwnsIt), "12")
    }

    /// A server's own session from before saved sign-ins has no known
    /// account; its pushes open as they did before accounts.
    func testAnUnknownActiveAccountKeepsTheServerAndProfileRules() throws {
        saveTarget(accountID: "12")
        let link = try pushLink()

        XCTAssertTrue(opens(link, as: nil))
        XCTAssertFalse(ApplePushDeepLinkCoordinator.opensUnderActiveIdentity(
            link, activeServer: server, activeProfileID: "kids", activeAccountID: nil, targets: targets
        ))
    }

    func testATargetSavedByAnEarlierBuildStillDecodes() throws {
        let earlier = #"[{"serverID":"deployment-a","profileID":"default","registryServerID":"registry-a","serverURL":"https://a.example","displayToken":"display-a"}]"#
        XCTAssertTrue(keychain.set(earlier, for: SharedStorage.applePushDisplayTargetsAccount))

        let target = try XCTUnwrap(targets.targets().first)
        XCTAssertNil(target.accountID)
        XCTAssertEqual(target.displayToken, "display-a")
    }
}
#endif
