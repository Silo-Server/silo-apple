import XCTest
@testable import Silo

final class DiagnosticsPromptPolicyTests: XCTestCase {
    private let current = DiagnosticsBinding(serverInstanceID: "server-a", accountUserID: "account-a")

    func testEligibleForMatchingAvailableAskAdultReport() {
        XCTAssertTrue(isEligible())
    }

    func testDifferentBindingIsIneligible() {
        let other = DiagnosticsBinding(serverInstanceID: "server-b", accountUserID: "account-a")
        XCTAssertFalse(isEligible(reportBinding: other))
    }

    func testUnavailableStatusIsIneligible() {
        XCTAssertFalse(isEligible(status: .disabled))
        XCTAssertFalse(isEligible(status: .storageUnavailable))
    }

    func testAlwaysAndNeverModesAreIneligible() {
        XCTAssertFalse(isEligible(mode: .always))
        XCTAssertFalse(isEligible(mode: .never))
    }

    func testSuppressedFingerprintIsIneligible() {
        XCTAssertFalse(isEligible(isSuppressed: true))
    }

    func testChildProfileIsIneligible() {
        XCTAssertFalse(isEligible(isChildProfile: true))
    }

    private func isEligible(
        reportBinding: DiagnosticsBinding? = nil,
        status: DiagnosticsAvailabilityStatus = .available,
        mode: DiagnosticsConsentChoice = .ask,
        isSuppressed: Bool = false,
        isChildProfile: Bool = false
    ) -> Bool {
        DiagnosticsPromptPolicy.isEligible(
            reportBinding: reportBinding ?? current,
            currentBinding: current,
            status: status,
            mode: mode,
            isSuppressed: isSuppressed,
            isChildProfile: isChildProfile
        )
    }
}
