import Foundation
import XCTest
@testable import Silo

/// What Settings shows about the open account: its header, and the account
/// line under Paired Silo Profile.
final class SettingsAccountHeaderTests: XCTestCase {
    private typealias D = SiloAccountDirectoryFixture

    private let alex = D.Account(serverID: D.home, accountID: "12", username: "alex", email: "alex@example.com")
    private let sam = D.Account(serverID: D.friend, accountID: "40", username: "sam")

    func testHeaderShowsTheOpenAccountNotTheProfile() {
        let directory = D.directory([alex, sam], current: alex.ref)
        let header = SettingsViewModel.accountHeader(directory: directory, username: "ignored", serverName: "Ignored")
        XCTAssertEqual(header, SettingsAccountHeader(name: "alex", detailLines: ["alex@example.com", "Home Silo"]))
    }

    /// Before accounts are readable, the signed-in username and the server.
    func testHeaderFallsBackToTheSignedInUsernameAndServer() {
        XCTAssertEqual(SettingsViewModel.accountHeader(directory: .empty, username: "alex", serverName: "Home Silo"),
                       SettingsAccountHeader(name: "alex", detailLines: ["Home Silo"]))
        XCTAssertEqual(SettingsViewModel.accountHeader(directory: .empty, username: nil, serverName: "Home Silo"),
                       SettingsAccountHeader(name: "Home Silo", detailLines: []))
    }

    /// One account: Paired Silo Profile shows only the profile.
    func testPairedProfileNamesItsAccountOnlyWithSeveralAccounts() {
        XCTAssertNil(SettingsViewModel.pairedAccountLine(directory: D.directory([alex], current: alex.ref)))
        XCTAssertEqual(SettingsViewModel.pairedAccountLine(directory: D.directory([alex, sam], current: alex.ref)),
                       "alex · alex@example.com · Home Silo")
    }
}
