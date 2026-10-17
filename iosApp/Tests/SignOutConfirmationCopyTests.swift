import Foundation
import XCTest
@testable import Silo

/// Spec §5.6 and §5.4.1 copy. These check the choices each confirmation
/// offers and that its text names what it acts on, not its wording.
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

    func testSignOutNamesTheUserServerAndDeviceAndOffersRemovingTheServer() {
        let copy = SignOutConfirmationCopy.signOut(userName: "alex", serverName: "Home Silo", device: tv)
        assertNames(copy, ["alex", "Home Silo", "Apple TV"])
        XCTAssertTrue(copy.title.contains("Home Silo"))
        XCTAssertTrue(copy.confirmIsDestructive)
        XCTAssertEqual(copy.confirmTitle, SignOutConfirmationCopy.signOutTitle)
        XCTAssertEqual(copy.additionalDestructiveTitle, SignOutConfirmationCopy.signOutAndRemoveServerTitle)
    }

    func testRemoveUserNamesTheUserEveryServerAndTheDevice() {
        let copy = SignOutConfirmationCopy.removeUser(userName: "alex", serverNames: ["Home Silo", "Friend's Silo", "Cabin"], device: tv)
        assertNames(copy, ["alex", "Home Silo", "Friend's Silo", "Cabin", "Apple TV"])
        XCTAssertTrue(copy.title.contains("alex"))
        XCTAssertTrue(copy.confirmIsDestructive)
        XCTAssertNil(copy.additionalDestructiveTitle)

        let noServers = SignOutConfirmationCopy.removeUser(userName: "alex", serverNames: [], device: tv)
        assertNames(noServers, ["alex", "Apple TV"])
    }

    func testRemovingAServerNamesItsUsers() {
        let copy = SignOutConfirmationCopy.signOutAndRemoveServer(serverName: "Home Silo", userNames: ["alex", "sam", "jo"], device: tv)
        assertNames(copy, ["Home Silo", "alex", "sam", "jo", "Apple TV"])
        XCTAssertTrue(copy.title.contains("Home Silo"))
        XCTAssertTrue(copy.confirmIsDestructive)
        XCTAssertNil(copy.additionalDestructiveTitle)

        let nobody = SignOutConfirmationCopy.signOutAndRemoveServer(serverName: "Home Silo", userNames: [], device: tv)
        assertNames(nobody, ["Home Silo", "Apple TV"])
    }

    func testSeparateUserPromptNamesTheExistingUserServerAndNewAccount() {
        let copy = SignOutConfirmationCopy.separateUser(existingUserName: "alex", serverName: "Home Silo", newUsername: "sam")
        assertNames(copy, ["alex", "Home Silo", "sam"])
        XCTAssertTrue(copy.title.contains("alex"))
        XCTAssertTrue(copy.title.contains("Home Silo"))
        XCTAssertTrue(copy.confirmTitle.contains("sam"))
        XCTAssertFalse(copy.confirmIsDestructive)

        let unknown = SignOutConfirmationCopy.separateUser(existingUserName: "alex", serverName: "Home Silo", newUsername: nil)
        assertNames(unknown, ["alex", "Home Silo"])
        XCTAssertFalse(text(unknown).contains("nil"))
    }

    func testSwitchToUserPromptNamesTheOtherUser() {
        let copy = SignOutConfirmationCopy.switchToUser(otherUserName: "sam", serverName: "Friend's Silo")
        assertNames(copy, ["sam", "Friend's Silo"])
        XCTAssertTrue(copy.confirmTitle.contains("sam"))
        XCTAssertFalse(copy.confirmIsDestructive)
    }

    func testDeviceWordingComesFromTheCaller() {
        let signOut = SignOutConfirmationCopy.signOut(userName: "alex", serverName: "Home Silo", device: phone)
        XCTAssertFalse(text(signOut).contains("Apple TV"))
        assertNames(signOut, ["device"])

        XCTAssertTrue(SignOutConfirmationCopy.removeFromDeviceTitle(device: tv).contains("Apple TV"))
        XCTAssertTrue(SignOutConfirmationCopy.removeFromDeviceTitle(device: phone).contains("Device"))
        XCTAssertEqual(SignOutConfirmationCopy.Device(noun: "iPhone").titleNoun, "iPhone")
    }

    func testServerRowActionNamesTheServer() {
        XCTAssertTrue(SignOutConfirmationCopy.signOutOfServerTitle(serverName: "Home Silo").contains("Home Silo"))
    }
}
