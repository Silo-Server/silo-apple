import XCTest
@testable import Silo

/// The create-profile PIN rule: no PIN, or exactly the four ASCII digits the
/// `PINEntryView` keypad can type. Anything else would create a profile no
/// Apple or Android client can unlock.
final class ProfilePINTests: XCTestCase {
    func testEmptyPINIsAcceptedAsNoPIN() {
        XCTAssertTrue(ProfilePIN.isAcceptableForCreate(""))
    }

    func testFourDigitPINIsAccepted() {
        XCTAssertTrue(ProfilePIN.isAcceptableForCreate("0000"))
        XCTAssertTrue(ProfilePIN.isAcceptableForCreate("1234"))
    }

    func testShortPINsAreRejected() {
        for pin in ["1", "12", "123"] {
            XCTAssertFalse(ProfilePIN.isAcceptableForCreate(pin), pin)
        }
    }

    func testLongerPINsAreRejected() {
        XCTAssertFalse(ProfilePIN.isAcceptableForCreate("12345"))
    }

    func testNonASCIINumeralsAreRejected() {
        // Arabic-Indic three, vulgar half, and "1" + combining acute accent
        // (one Character): all count as numbers, none is on the keypad.
        for pin in ["12\u{0663}4", "12\u{00BD}4", "1\u{0301}234"] {
            XCTAssertFalse(ProfilePIN.isAcceptableForCreate(pin), pin.debugDescription)
        }
    }

    func testSanitizerFiltersBeforeTruncating() {
        XCTAssertEqual(ProfilePIN.sanitized("12a34"), "1234")
    }

    func testSanitizerDropsNonASCIINumeralsAndCapsLength() {
        XCTAssertEqual(ProfilePIN.sanitized("1\u{0663}2\u{00BD}345"), "1234")
        XCTAssertEqual(ProfilePIN.sanitized("1\u{0301}2345"), "2345")
    }
}
