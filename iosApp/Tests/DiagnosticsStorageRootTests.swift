import Foundation
import XCTest
@testable import Silo

// SiloTests currently runs on iOS. The tvOS branch documents its expected
// storage policy but only becomes executable coverage in a tvOS test bundle.
final class DiagnosticsStorageRootTests: XCTestCase {
    func testBaseDirectoryMatchesPlatformStorageDirectory() {
        let fileManager = FileManager.default
#if os(tvOS)
        let platformDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        XCTAssertEqual(AppleStorageRoot.category, .caches)
        XCTAssertEqual(AppleStorageRoot.category.rawValue, "caches")
#else
        let platformDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        XCTAssertEqual(AppleStorageRoot.category, .applicationSupport)
        XCTAssertEqual(AppleStorageRoot.category.rawValue, "applicationSupport")
#endif
        let expected = platformDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        XCTAssertEqual(AppleStorageRoot.baseDirectory(fileManager: fileManager), expected)
        // The diagnostics writers still call the historical name.
        XCTAssertEqual(DiagnosticsStorageRoot.baseDirectory(fileManager: fileManager), expected)
    }

    /// The defect this helper exists to prevent: `PlaybackMutationStore` wrote to
    /// a root tvOS rejects, so a playback journal record could not be persisted
    /// at all. Exercise register, reload from a fresh store, read back, remove —
    /// under the real selected root, in a unique subdirectory.
    func testPlaybackMutationRecordPersistsAndReloadsUnderSelectedRoot() async throws {
        let name = "AppleStorageRootTests.\(UUID().uuidString)"
        let root = AppleStorageRoot.baseDirectory().appendingPathComponent(name, isDirectory: true)
        let url = root.appendingPathComponent("playback-mutations.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: name)
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                                defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try PlaybackMutationAuthority(auth: XCTUnwrap(captured), installationID: "installation")

        let sessionID = UUID().uuidString.lowercased()
        let registered = try await PlaybackMutationStore(url: url)
            .register(sessionID: sessionID, authority: authority, attemptID: "attempt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reloaded = try await PlaybackMutationStore(url: url).session(registered.id, authority: authority)
        XCTAssertEqual(reloaded.id, registered.id)
        XCTAssertEqual(reloaded.sessionID, sessionID)
        XCTAssertEqual(reloaded.attemptID, "attempt")
        XCTAssertEqual(reloaded.authority, authority)

        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
