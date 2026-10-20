import Foundation
import XCTest
@testable import Silo

/// Spec §5.6 copy. These check the choices each confirmation offers and
/// that its text names what it acts on, not its wording.
final class SignOutConfirmationCopyTests: XCTestCase {
    private let tv = SignOutConfirmationCopy.Device.appleTV
    private let phone = SignOutConfirmationCopy.Device(noun: "device", titleNoun: "Device")

    private func text(_ copy: ConfirmationCopy) -> String {
        [copy.title, copy.message, copy.confirmTitle, copy.additionalDestructiveTitle ?? ""].joined(separator: "\n")
    }

    private func assertNames(_ copy: ConfirmationCopy, _ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        let all = text(copy)
        for input in inputs {
            XCTAssertTrue(all.contains(input), "\(input) missing from \(all)", file: file, line: line)
        }
    }

    /// Signing out keeps the card; only the current account's sign-out
    /// also offers Remove Account (`SiloAccountCoordinator.confirmation`).
    func testSignOutNamesTheAccountServerAndDeviceAndOffersRemoveOnlyWhenAsked() {
        let copy = SignOutConfirmationCopy.signOut(accountName: "alex", serverName: "Home Silo", device: tv)
        assertNames(copy, ["alex", "Home Silo", "Apple TV"])
        XCTAssertTrue(copy.title.contains("alex"))
        XCTAssertTrue(copy.confirmIsDestructive)
        XCTAssertEqual(copy.confirmTitle, SignOutConfirmationCopy.signOutTitle)
        XCTAssertNil(copy.additionalDestructiveTitle)

        let current = SignOutConfirmationCopy.signOut(accountName: "alex", serverName: "Home Silo", device: tv,
                                                      offersRemove: true)
        XCTAssertEqual(current.confirmTitle, SignOutConfirmationCopy.signOutTitle)
        XCTAssertEqual(current.additionalDestructiveTitle, SignOutConfirmationCopy.removeAccountTitle)
    }

    func testRemoveAccountNamesTheAccountServerAndDevice() {
        let copy = SignOutConfirmationCopy.removeAccount(accountName: "alex", serverName: "Home Silo", device: tv)
        assertNames(copy, ["alex", "Home Silo", "Apple TV"])
        XCTAssertTrue(copy.title.contains("alex"))
        XCTAssertEqual(copy.confirmTitle, SignOutConfirmationCopy.removeTitle)
        XCTAssertTrue(copy.confirmIsDestructive)
        XCTAssertNil(copy.additionalDestructiveTitle)
    }

    func testDeviceWordingComesFromTheCaller() {
        let signOut = SignOutConfirmationCopy.signOut(accountName: "alex", serverName: "Home Silo", device: phone)
        XCTAssertFalse(text(signOut).contains("Apple TV"))
        let remove = SignOutConfirmationCopy.removeAccount(accountName: "alex", serverName: "Home Silo", device: phone)
        XCTAssertFalse(text(remove).contains("Apple TV"))
        assertNames(remove, ["device"])

        XCTAssertTrue(SignOutConfirmationCopy.removeFromDeviceTitle(device: tv).contains("Apple TV"))
        XCTAssertTrue(SignOutConfirmationCopy.removeFromDeviceTitle(device: phone).contains("Device"))
        XCTAssertEqual(SignOutConfirmationCopy.Device(noun: "iPhone").titleNoun, "iPhone")
    }

    /// Only a shared device's copy speaks for other people: one person uses
    /// an iPhone, so its sign-out doesn't mention "everyone".
    func testOnlySharedDevicesSayEveryoneIsAffected() {
        for copy in [SignOutConfirmationCopy.signOut(accountName: "alex", serverName: "Home Silo", device: phone),
                     SignOutConfirmationCopy.removeAccount(accountName: "alex", serverName: "Home Silo", device: phone)] {
            XCTAssertFalse(text(copy).localizedCaseInsensitiveContains("everyone"), text(copy))
        }
        for copy in [SignOutConfirmationCopy.signOut(accountName: "alex", serverName: "Home Silo", device: tv),
                     SignOutConfirmationCopy.removeAccount(accountName: "alex", serverName: "Home Silo", device: tv)] {
            XCTAssertTrue(text(copy).localizedCaseInsensitiveContains("everyone"), text(copy))
        }
    }
}
