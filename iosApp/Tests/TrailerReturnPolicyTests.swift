import XCTest
import Foundation
@testable import Silo

final class TrailerReturnPolicyTests: XCTestCase {

    private func record(
        savedAt: Date,
        serverId: String = "server-1",
        profileId: String = "profile-1"
    ) -> TrailerReturnRecord {
        TrailerReturnRecord(
            contentId: "movie-42",
            serverId: serverId,
            profileId: profileId,
            savedAt: savedAt
        )
    }

    func testFreshMatchingRecordRestores() {
        let now = Date()
        XCTAssertTrue(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now.addingTimeInterval(-120)),
            now: now,
            activeServerId: "server-1",
            activeProfileId: "profile-1"
        ))
    }

    func testRecordAtExactWindowBoundaryRestores() {
        let now = Date()
        XCTAssertTrue(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now.addingTimeInterval(-TrailerReturnPolicy.maxRecordAge)),
            now: now,
            activeServerId: "server-1",
            activeProfileId: "profile-1"
        ))
    }

    func testExpiredRecordDoesNotRestore() {
        let now = Date()
        XCTAssertFalse(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now.addingTimeInterval(-TrailerReturnPolicy.maxRecordAge - 1)),
            now: now,
            activeServerId: "server-1",
            activeProfileId: "profile-1"
        ))
    }

    func testFutureSavedAtDoesNotRestore() {
        // A clock that went backwards must invalidate, not extend, the record.
        let now = Date()
        XCTAssertFalse(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now.addingTimeInterval(60)),
            now: now,
            activeServerId: "server-1",
            activeProfileId: "profile-1"
        ))
    }

    func testServerMismatchDoesNotRestore() {
        let now = Date()
        XCTAssertFalse(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now),
            now: now,
            activeServerId: "server-2",
            activeProfileId: "profile-1"
        ))
    }

    func testProfileMismatchDoesNotRestore() {
        let now = Date()
        XCTAssertFalse(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now),
            now: now,
            activeServerId: "server-1",
            activeProfileId: "profile-2"
        ))
    }

    func testMissingIdentityDoesNotRestore() {
        let now = Date()
        XCTAssertFalse(TrailerReturnPolicy.shouldRestore(
            record: record(savedAt: now),
            now: now,
            activeServerId: nil,
            activeProfileId: nil
        ))
    }
}
