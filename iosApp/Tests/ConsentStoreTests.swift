import XCTest
@testable import Silo

final class ConsentStoreTests: XCTestCase {
    func testNoticeBumpInvalidatesAlwaysBackToAsk() {
        let store = makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")

        store.setMode(.always, for: binding, noticeVersion: 1, now: Date(timeIntervalSince1970: 10))

        let record = store.record(for: binding, currentNoticeVersion: 2, now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(record.mode, .ask)
        XCTAssertEqual(record.noticeVersion, 2)
    }

    func testNeverPurgesPendingReportsAndDisablesPersistentCapture() {
        var purged: [DiagnosticsBinding] = []
        let store = makeStore { binding in purged.append(binding) }
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")

        store.setMode(.never, for: binding, noticeVersion: 1)

        XCTAssertEqual(purged, [binding])
        XCTAssertFalse(store.persistentCaptureEnabled(for: binding, currentNoticeVersion: 1))
    }

    func testPersistentCaptureConsentIsIndependentOfDebugLogging() {
        let store = makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")

        store.debugLoggingEnabled = false

        XCTAssertTrue(store.persistentCaptureEnabled(for: binding, currentNoticeVersion: 1))
        store.setMode(.never, for: binding, noticeVersion: 1)
        XCTAssertFalse(store.persistentCaptureEnabled(for: binding, currentNoticeVersion: 1))
    }

    func testConsentRecordsAreBindingScoped() {
        let store = makeStore()
        let first = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let second = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "43")

        store.setMode(.always, for: first, noticeVersion: 1)

        XCTAssertEqual(store.record(for: first, currentNoticeVersion: 1).mode, .always)
        XCTAssertEqual(store.record(for: second, currentNoticeVersion: 1).mode, .ask)
    }

    func testRemoveServerInstanceDeletesAllConsentRecordsForThatServer() {
        let store = makeStore()
        let first = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let second = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "43")
        let otherServer = DiagnosticsBinding(serverInstanceID: "srv-b", accountUserID: "42")

        store.setMode(.always, for: first, noticeVersion: 1)
        store.setMode(.never, for: second, noticeVersion: 1)
        store.setMode(.always, for: otherServer, noticeVersion: 1)

        store.remove(serverInstanceID: "srv-a")

        XCTAssertEqual(store.record(for: first, currentNoticeVersion: 1).mode, .ask)
        XCTAssertEqual(store.record(for: second, currentNoticeVersion: 1).mode, .ask)
        XCTAssertEqual(store.record(for: otherServer, currentNoticeVersion: 1).mode, .always)
    }

    func testRemoveBindingDeletesOnlyThatConsentRecord() {
        let store = makeStore()
        let first = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let second = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "43")

        store.setMode(.always, for: first, noticeVersion: 1)
        store.setMode(.always, for: second, noticeVersion: 1)

        store.remove(binding: first)

        XCTAssertEqual(store.record(for: first, currentNoticeVersion: 1).mode, .ask)
        XCTAssertEqual(store.record(for: second, currentNoticeVersion: 1).mode, .always)
    }

    func testChildProfilesCannotManageDiagnostics() {
        let adult = UserProfile(
            id: "adult",
            name: "Adult",
            avatarEmoji: nil,
            hasPin: false,
            isChild: false
        )
        let child = UserProfile(
            id: "child",
            name: "Child",
            avatarEmoji: nil,
            hasPin: false,
            isChild: true
        )

        XCTAssertTrue(DiagnosticsConsentStore.canManageDiagnostics(profile: adult))
        XCTAssertFalse(DiagnosticsConsentStore.canManageDiagnostics(profile: child))
        XCTAssertFalse(DiagnosticsConsentStore.canManageDiagnostics(profile: nil))
    }

    private func makeStore(
        onNeverSelected: @escaping (DiagnosticsBinding) -> Void = { _ in }
    ) -> DiagnosticsConsentStore {
        let name = "ConsentStoreTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let standard = UserDefaults(suiteName: "\(name).standard")!
        addTeardownBlock {
            suite.removePersistentDomain(forName: name)
            standard.removePersistentDomain(forName: "\(name).standard")
        }
        return DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: standard),
            onNeverSelected: onNeverSelected
        )
    }
}
