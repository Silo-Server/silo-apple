import Foundation
import XCTest
@testable import Silo

final class TVSavedAccountPersistenceTests: XCTestCase {
    private let server = "server"

    func testSeparateSelectionsRetainFamilyDefaultAcrossRelaunch() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        let accountB = session("B")
        try memory.persistence("first").save(accountA, serverID: server)
        try memory.persistence("second").save(accountB, serverID: server)

        func restored(_ persona: String) throws -> CanonicalAccountSession? {
            guard case .session(let value) = try memory.persistence(persona).load(server) else { return nil }
            return value
        }
        XCTAssertEqual(try restored("second"), accountB)
        XCTAssertEqual(try restored("first"), accountA)
        XCTAssertEqual(try restored("unconfigured"), accountA)
    }

    func testDeselectOnlyChangesThisPersonasSelection() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B")
        try memory.persistence("first").save(accountA, serverID: server)
        try memory.persistence("second").save(accountB, serverID: server)
        let before = memory.sharedValues

        XCTAssertTrue(memory.persistence("second").deselectAccount(serverID: server))

        XCTAssertEqual(memory.sharedValues, before)
        XCTAssertEqual(try memory.persistence("second").load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("first").load(server), .session(accountA))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
    }

    func testLoggingOutBPreservesAAndNeverFallsBackForB() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B")
        try memory.persistence("first").save(accountA, serverID: server)
        try memory.persistence("second").save(accountB, serverID: server)

        XCTAssertTrue(memory.persistence("second").invalidateSession(accountB, serverID: server))

        XCTAssertEqual(try memory.persistence("second").load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("first").load(server), .session(accountA))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
    }

    func testLoggingOutDefaultDoesNotPromoteAnotherSavedAccount() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B")
        try memory.persistence("first").save(accountA, serverID: server)
        try memory.persistence("second").save(accountB, serverID: server)

        XCTAssertTrue(memory.persistence("first").invalidate(server))

        XCTAssertEqual(try memory.persistence("new").load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("second").load(server), .session(accountB))
        let rotated = session("B", access: "rotated-B", epoch: try XCTUnwrap(accountB.epoch))
        XCTAssertTrue(memory.persistence("second").replaceSession(rotated, replacing: accountB, serverID: server))
        XCTAssertEqual(try memory.persistence("new").load(server), .signedOut)
    }

    func testFailedSelectorWriteRollsBackOnlyDestination() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B")
        try memory.persistence("first").save(accountA, serverID: server)
        try memory.persistence("second").save(accountB, serverID: server)
        memory.rejectSelectorWrites("third", true)

        XCTAssertThrowsError(try memory.persistence("third").installAccountSession(session("C"), serverID: server))

        XCTAssertEqual(try memory.persistence("first").load(server), .session(accountA))
        XCTAssertEqual(try memory.persistence("second").load(server), .session(accountB))
        XCTAssertEqual(try memory.persistence("third").load(server), .session(accountA))
        let envelope = try XCTUnwrap(memory.sharedValue(TVAccountSessionStorage.recordKey(server)))
        XCTAssertFalse(envelope.contains("access-C"))
    }

    func testFailedSelectorInstallMatchesExactMigratedRawLegacySnapshot() throws {
        for epoch in [String?.none, UUID().uuidString] {
            let memory = TVSavedAccountMemory()
            memory.setShared("raw-A", for: SharedStorage.accessTokenAccount(for: server))
            memory.setShared("refresh-A", for: SharedStorage.refreshTokenAccount(for: server))
            memory.setShared(epoch, for: SharedStorage.accountEpochAccount(for: server))
            let persistence = memory.persistence("first")
            let before = try XCTUnwrap(persistence.accountSelectionSnapshot(for: server))
            memory.rejectSelectorWrites("first", true)

            XCTAssertThrowsError(try persistence.installAccountSession(session("B"), serverID: server))

            XCTAssertTrue(persistence.matchesAccountSelection(before, serverID: server))
            guard case .session(let migrated) = try persistence.load(server) else { return XCTFail("Raw A was lost") }
            XCTAssertEqual(migrated.accessToken, "raw-A")
            XCTAssertNil(migrated.accountID)
            memory.setShared("changed-raw", for: SharedStorage.accessTokenAccount(for: server))
            XCTAssertFalse(persistence.matchesAccountSelection(before, serverID: server))
        }
    }

    func testInvalidationSelectorFailuresPreserveAllSharedAccounts() throws {
        for allAccounts in [false, true] {
            let memory = TVSavedAccountMemory()
            let accountA = session("A"), accountB = session("B")
            try memory.persistence("first").save(accountA, serverID: server)
            try memory.persistence("second").save(accountB, serverID: server)
            let before = memory.sharedValues
            memory.rejectSelectorWrites("first", true)

            let removed = allAccounts ? memory.persistence("first").invalidateAllAccounts(serverID: server)
                : memory.persistence("first").invalidateSession(accountA, serverID: server)

            XCTAssertFalse(removed)
            XCTAssertEqual(memory.sharedValues, before)
            XCTAssertEqual(try memory.persistence("first").load(server), .session(accountA))
            XCTAssertEqual(try memory.persistence("second").load(server), .session(accountB))
        }
    }

    func testInvalidationEnvelopeFailureRestoresLocalSelection() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.persistence("first").save(accountA, serverID: server)
        memory.rejectSharedWrites(TVAccountSessionStorage.recordKey(server), true)

        XCTAssertFalse(memory.persistence("first").invalidateSession(accountA, serverID: server))

        XCTAssertEqual(try memory.persistence("first").load(server), .session(accountA))
    }

    func testFirstInvalidationMarkerFailureRestoresLegacyAuthorityAndSelection() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.seedLegacy(accountA, serverID: server)
        memory.rejectSharedWrites(TVAccountSessionStorage.markerKey(server), true)

        XCTAssertFalse(memory.persistence("first").invalidateAllAccounts(serverID: server))

        XCTAssertEqual(try memory.persistence("first").load(server), .session(accountA))
        XCTAssertNil(memory.sharedValue(TVAccountSessionStorage.recordKey(server)))
        XCTAssertNil(memory.selectionValue("first", TVAccountSessionStorage.selectionKey(server)))
    }

    func testRollbackRestoresExistingDestinationAndPreservesLaterUnrelatedInstall() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), oldB = session("B"), newB = session("B", access: "replacement-B")
        let accountC = session("C")
        try memory.persistence("first").save(accountA, serverID: server)
        try memory.persistence("second").save(oldB, serverID: server)
        let persistence = memory.persistence("first")
        let before = try XCTUnwrap(persistence.accountSelectionSnapshot(for: server))
        let receipt = try XCTUnwrap(persistence.installAccountSession(newB, serverID: server))
        XCTAssertEqual(receipt.previousSelection, before)
        try memory.persistence("third").save(accountC, serverID: server)

        XCTAssertTrue(persistence.rollbackAccountInstallation(receipt, serverID: server))

        XCTAssertTrue(persistence.matchesAccountSelection(before, serverID: server))
        XCTAssertEqual(try persistence.load(server), .session(accountA))
        XCTAssertEqual(try memory.persistence("second").load(server), .session(oldB))
        XCTAssertEqual(try memory.persistence("third").load(server), .session(accountC))
    }

    func testRollbackRefusesLaterOwnerOfDestination() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B"), newerB = session("B", access: "newer-B")
        let persistence = memory.persistence("first")
        try persistence.save(accountA, serverID: server)
        let receipt = try XCTUnwrap(persistence.installAccountSession(accountB, serverID: server))
        try memory.persistence("second").save(newerB, serverID: server)

        XCTAssertFalse(persistence.rollbackAccountInstallation(receipt, serverID: server))
        XCTAssertEqual(try persistence.load(server), .session(newerB))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
    }

    func testRollbackRefusesChangedLocalSelection() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B")
        let persistence = memory.persistence("first")
        try persistence.save(accountA, serverID: server)
        let receipt = try XCTUnwrap(persistence.installAccountSession(accountB, serverID: server))
        XCTAssertTrue(persistence.deselectAccount(serverID: server))

        XCTAssertFalse(persistence.rollbackAccountInstallation(receipt, serverID: server))
        XCTAssertEqual(try persistence.load(server), .signedOut)
    }

    func testLegacyCanonicalMigrationPreservesFamilyDefaultAndEpoch() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A"), accountB = session("B")
        try memory.seedLegacy(accountA, serverID: server)
        let before = memory.sharedValues
        XCTAssertEqual(try memory.persistence("reader").load(server), .session(accountA))
        XCTAssertEqual(memory.sharedValues, before, "Top Shelf loads must not adopt a new schema")

        try memory.persistence("second").save(accountB, serverID: server)

        XCTAssertEqual(try memory.persistence("second").load(server), .session(accountB))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
        XCTAssertNotNil(memory.sharedValue(TVAccountSessionStorage.markerKey(server)))
    }

    func testUnverifiedDefaultDoesNotCreateSelectorAndBindsWithoutChangingEpoch() throws {
        let memory = TVSavedAccountMemory()
        let legacy = session(nil)
        let persistence = memory.persistence("first")
        try persistence.save(legacy, serverID: server)
        XCTAssertNil(memory.selectionValue("first", TVAccountSessionStorage.selectionKey(server)))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(legacy))
        let bound = session("A", access: legacy.accessToken, epoch: try XCTUnwrap(legacy.epoch))

        XCTAssertTrue(persistence.replaceSession(bound, replacing: legacy, serverID: server))

        XCTAssertNil(memory.selectionValue("first", TVAccountSessionStorage.selectionKey(server)))
        XCTAssertEqual(try persistence.load(server), .session(bound))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(bound))
    }

    func testAddingVerifiedBRetainsUnverifiedLegacyFamilyDefault() throws {
        let memory = TVSavedAccountMemory()
        let legacy = session(nil), accountB = session("B")
        try memory.seedLegacy(legacy, serverID: server)

        try memory.persistence("second").save(accountB, serverID: server)

        XCTAssertEqual(try memory.persistence("second").load(server), .session(accountB))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(legacy))
        XCTAssertNil(memory.selectionValue("new", TVAccountSessionStorage.selectionKey(server)))
    }

    func testRawLegacyMigrationRetainsUnknownAccountAndEpoch() throws {
        let memory = TVSavedAccountMemory()
        let epoch = UUID()
        memory.setShared("raw-access", for: SharedStorage.accessTokenAccount(for: server))
        memory.setShared("raw-refresh", for: SharedStorage.refreshTokenAccount(for: server))
        memory.setShared(epoch.uuidString, for: SharedStorage.accountEpochAccount(for: server))
        XCTAssertEqual(try memory.persistence("new").load(server), .legacy)
        XCTAssertTrue(memory.persistence("new").hasSession(serverID: server, origin: "https://accounts.example"))

        try memory.persistence("second").save(session("B"), serverID: server)

        guard case .session(let migrated) = try memory.persistence("new").load(server) else {
            return XCTFail("Expected the raw family credentials to survive migration")
        }
        XCTAssertNil(migrated.accountID)
        XCTAssertEqual(migrated.epoch, epoch)
        XCTAssertEqual(migrated.accessToken, "raw-access")
        XCTAssertNil(memory.selectionValue("new", TVAccountSessionStorage.selectionKey(server)))
    }

    func testRawLegacyBindingPromotesSingleDefaultAndLogoutClearsIt() throws {
        let memory = TVSavedAccountMemory()
        let verified = session("A")
        memory.setShared(verified.accessToken, for: SharedStorage.accessTokenAccount(for: server))
        memory.setShared(verified.refreshToken, for: SharedStorage.refreshTokenAccount(for: server))
        memory.setShared(verified.epoch?.uuidString, for: SharedStorage.accountEpochAccount(for: server))
        let persistence = memory.persistence("first")

        XCTAssertTrue(persistence.bindLegacySession(verified, serverID: server))

        XCTAssertEqual(try persistence.load(server), .session(verified))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(verified))
        XCTAssertNil(memory.selectionValue("first", TVAccountSessionStorage.selectionKey(server)))
        let raw = try XCTUnwrap(memory.sharedValue(TVAccountSessionStorage.recordKey(server)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual((envelope["sessions"] as? [String: Any])?.count, 1)
        XCTAssertTrue(persistence.invalidateSession(verified, serverID: server))
        XCTAssertEqual(try persistence.load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("new").load(server), .signedOut)
    }

    func testRawLegacyBindingRejectsChangedCredentialsAndEpoch() throws {
        for changedKey in [SharedStorage.accessTokenAccount(for: server),
                           SharedStorage.refreshTokenAccount(for: server),
                           SharedStorage.accountEpochAccount(for: server)] {
            let memory = TVSavedAccountMemory()
            let verified = session("A")
            memory.setShared(verified.accessToken, for: SharedStorage.accessTokenAccount(for: server))
            memory.setShared(verified.refreshToken, for: SharedStorage.refreshTokenAccount(for: server))
            memory.setShared(verified.epoch?.uuidString, for: SharedStorage.accountEpochAccount(for: server))
            memory.setShared("changed", for: changedKey)

            XCTAssertFalse(memory.persistence("first").bindLegacySession(verified, serverID: server))
            XCTAssertNil(memory.sharedValue(TVAccountSessionStorage.recordKey(server)))
        }
    }

    func testUnknownAccountCannotOverwriteVerifiedDefault() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.persistence("first").save(accountA, serverID: server)

        XCTAssertThrowsError(try memory.persistence("new").save(session(nil), serverID: server))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
    }

    func testAdoptedMissingEnvelopeNeverResurrectsLegacyCanonicalOrRawTokens() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.seedLegacy(accountA, serverID: server)
        memory.setShared("old-raw", for: SharedStorage.accessTokenAccount(for: server))
        try memory.persistence("first").save(session("B"), serverID: server)
        memory.setShared(nil, for: TVAccountSessionStorage.recordKey(server))

        XCTAssertEqual(try memory.persistence("new").load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("first").load(server), .signedOut)
        XCTAssertFalse(memory.persistence("new").hasSession(serverID: server, origin: "https://accounts.example"))
    }

    func testCorruptEnvelopeAndSelectorFailClosedWithoutWrites() throws {
        for corruptEnvelope in [true, false] {
            let memory = TVSavedAccountMemory()
            try memory.persistence("first").save(session("A"), serverID: server)
            if corruptEnvelope {
                memory.setShared("broken", for: TVAccountSessionStorage.recordKey(server))
            } else {
                memory.setSelection("broken", persona: "first", key: TVAccountSessionStorage.selectionKey(server))
            }
            let count = memory.writeCount

            XCTAssertThrowsError(try memory.persistence("first").load(server))
            XCTAssertFalse(memory.persistence("first").hasSession(serverID: server, origin: "https://accounts.example"))
            XCTAssertEqual(memory.writeCount, count)
        }
    }

    func testSelectorForMissingAccountNeverInheritsDefaultAndAllowsFreshLogin() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.persistence("first").save(accountA, serverID: server)
        memory.setSelection(#"{"version":1,"signedOut":false,"accountID":"missing"}"#,
            persona: "second", key: TVAccountSessionStorage.selectionKey(server))

        XCTAssertEqual(try memory.persistence("second").load(server), .signedOut)
        XCTAssertFalse(memory.persistence("second").hasSession(serverID: server, origin: "https://accounts.example"))
        let replacement = session("B")
        try memory.persistence("second").save(replacement, serverID: server)
        XCTAssertEqual(try memory.persistence("second").load(server), .session(replacement))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
    }

    func testStrictReadErrorsNeverUseLegacyFallback() throws {
        let memory = TVSavedAccountMemory()
        try memory.seedLegacy(session("A"), serverID: server)
        memory.rejectRead(TVAccountSessionStorage.markerKey(server), true)

        XCTAssertThrowsError(try memory.persistence("first").load(server))
        XCTAssertThrowsError(try memory.persistence("first").save(session("B"), serverID: server))
    }

    func testFirstEnvelopeWriteFailurePreservesLegacyAcrossRestart() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.seedLegacy(accountA, serverID: server)
        memory.rejectSharedWrites(TVAccountSessionStorage.recordKey(server), true)

        XCTAssertThrowsError(try memory.persistence("second").save(session("B"), serverID: server))

        XCTAssertNil(memory.sharedValue(TVAccountSessionStorage.markerKey(server)))
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
        XCTAssertNil(memory.selectionValue("second", TVAccountSessionStorage.selectionKey(server)))
    }

    func testFirstMarkerFailureUndoesPublishedDestinationAndRetainsLegacyDefault() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("A")
        try memory.seedLegacy(accountA, serverID: server)
        memory.rejectSharedWrites(TVAccountSessionStorage.markerKey(server), true)

        XCTAssertThrowsError(try memory.persistence("second").save(session("B"), serverID: server))

        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
        XCTAssertNil(memory.selectionValue("second", TVAccountSessionStorage.selectionKey(server)))
        let raw = try XCTUnwrap(memory.sharedValue(TVAccountSessionStorage.recordKey(server)))
        XCTAssertFalse(raw.contains("access-B"))
    }

    func testInvalidateAllAccountsClearsEverySlotAndBlocksLegacyResurrection() throws {
        let memory = TVSavedAccountMemory()
        try memory.seedLegacy(session("legacy"), serverID: server)
        try memory.persistence("first").save(session("A"), serverID: server)
        try memory.persistence("second").save(session("B"), serverID: server)

        XCTAssertTrue(memory.persistence("first").invalidateAllAccounts(serverID: server))

        XCTAssertEqual(try memory.persistence("first").load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("new").load(server), .signedOut)
        XCTAssertEqual(try memory.persistence("second").load(server), .signedOut)
        let raw = try XCTUnwrap(memory.sharedValue(TVAccountSessionStorage.recordKey(server)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual((json["sessions"] as? [String: Any])?.count, 0)
    }

    func testStaleReplaceAndRejectionCannotChangeReplacement() throws {
        let memory = TVSavedAccountMemory()
        let original = session("A"), replacement = session("A", access: "replacement")
        let persistence = memory.persistence("first")
        try persistence.save(original, serverID: server)
        let snapshot = try XCTUnwrap(persistence.accountSelectionSnapshot(for: server))
        try persistence.save(replacement, serverID: server)
        let staleRefresh = session("A", access: "stale-refresh", epoch: try XCTUnwrap(original.epoch))

        XCTAssertFalse(persistence.replaceSession(staleRefresh, replacing: original, serverID: server))
        XCTAssertFalse(persistence.invalidateSession(original, serverID: server))
        XCTAssertFalse(persistence.matchesAccountSelection(snapshot, serverID: server))
        XCTAssertEqual(try persistence.load(server), .session(replacement))
    }

    func testFreshFailedSelectorWriteLeavesNoDefaultAndCanRetry() throws {
        let memory = TVSavedAccountMemory()
        memory.rejectSelectorWrites("first", true)
        XCTAssertThrowsError(try memory.persistence("first").save(session("A"), serverID: server))
        XCTAssertEqual(try memory.persistence("new").load(server), .signedOut)

        memory.rejectSelectorWrites("first", false)
        let accountB = session("B")
        try memory.persistence("second").save(accountB, serverID: server)

        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountB))
    }

    func testLegacyClosureInitializerKeepsItsOriginalContract() throws {
        let memory = TVSavedAccountMemory()
        let persistence = memory.legacyPersistence
        let accountA = session("A"), accountB = session("B")
        XCTAssertFalse(persistence.supportsAccountSelection)
        XCTAssertNil(try persistence.accountSelectionSnapshot(for: server))
        XCTAssertEqual(try persistence.load(server), .legacy)
        XCTAssertNil(try persistence.installAccountSession(accountA, serverID: server))
        XCTAssertEqual(try persistence.load(server), .session(accountA))
        XCTAssertTrue(persistence.replaceSession(accountB, replacing: accountA, serverID: server))
        XCTAssertFalse(persistence.invalidateSession(accountA, serverID: server))
        XCTAssertTrue(persistence.invalidateAllAccounts(serverID: server))
        XCTAssertEqual(try persistence.load(server), .signedOut)
        XCTAssertTrue(persistence.forget(server))
        XCTAssertEqual(try persistence.load(server), .legacy)
    }

    func testConcurrentInstallationsAcrossStorageInstancesRetainEveryAccount() throws {
        let memory = TVSavedAccountMemory()
        let accountA = session("family")
        try memory.persistence("family").save(accountA, serverID: server)
        let accounts = (0..<20).map { session("account-\($0)") }
        DispatchQueue.concurrentPerform(iterations: accounts.count) { index in
            do {
                try memory.persistence("persona-\(index)").save(accounts[index], serverID: self.server)
            } catch { XCTFail("Concurrent install failed: \(error)") }
        }
        for index in accounts.indices {
            XCTAssertEqual(try memory.persistence("persona-\(index)").load(server), .session(accounts[index]))
        }
        XCTAssertEqual(try memory.persistence("new").load(server), .session(accountA))
    }

    func testSavedAccountIDsIncludesAllVerifiedSlotsWithoutSelectionOrSchemaWrites() throws {
        let memory = TVSavedAccountMemory()
        let persistence = memory.persistence("new")
        try memory.seedLegacy(session("A"), serverID: server)
        let before = memory.sharedValues
        XCTAssertEqual(try persistence.savedAccountIDs(for: server), ["A"])
        XCTAssertEqual(memory.sharedValues, before)
        try memory.persistence("second").save(session("B"), serverID: server)
        XCTAssertEqual(try persistence.savedAccountIDs(for: server), ["A", "B"])
        XCTAssertTrue(persistence.invalidateAllAccounts(serverID: server))
        XCTAssertEqual(try persistence.savedAccountIDs(for: server), [])
    }

    private func session(_ account: String?, access: String? = nil, epoch: UUID = UUID()) -> CanonicalAccountSession {
        CanonicalAccountSession(version: 1, signedOut: false, origin: "https://accounts.example",
            accountID: account, epoch: epoch, accessToken: access ?? "access-\(account ?? "legacy")",
            refreshToken: "refresh-\(account ?? "legacy")")
    }
}

private final class TVSavedAccountMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var shared: [String: String] = [:]
    private var selections: [String: [String: String]] = [:]
    private var rejectedSelectors: Set<String> = []
    private var rejectedWrites: Set<String> = []
    private var rejectedReads: Set<String> = []
    private var writes = 0

    var sharedValues: [String: String] { lock.withLock { shared } }
    var writeCount: Int { lock.withLock { writes } }

    func persistence(_ persona: String) -> AccountSessionPersistence {
        AccountSessionPersistence(tvStorage: TVAccountSessionStorage(
            sharedRead: { try self.readShared($0) },
            sharedWrite: { self.writeShared($0, key: $1) }, sharedRemove: { self.removeShared($0) },
            selectionRead: { key in self.lock.withLock { self.selections[persona]?[key] } },
            selectionWrite: { value, key in
                self.lock.withLock {
                    self.writes += 1
                    guard !self.rejectedSelectors.contains(persona) else { return false }
                    self.selections[persona, default: [:]][key] = value
                    return true
                }
            }, selectionRemove: { key in
                self.lock.withLock {
                    self.writes += 1
                    guard !self.rejectedSelectors.contains(persona) else { return false }
                    self.selections[persona]?[key] = nil
                    return true
                }
            }))
    }

    var legacyPersistence: AccountSessionPersistence {
        AccountSessionPersistence(read: { try self.readShared($0) },
            write: { self.writeShared($0, key: $1) }, remove: { self.removeShared($0) })
    }

    func seedLegacy(_ value: CanonicalAccountSession, serverID: String) throws {
        try legacyPersistence.save(value, serverID: serverID)
    }

    func sharedValue(_ key: String) -> String? { lock.withLock { shared[key] } }
    func setShared(_ value: String?, for key: String) { lock.withLock { shared[key] = value } }
    func selectionValue(_ persona: String, _ key: String) -> String? {
        lock.withLock { selections[persona]?[key] }
    }
    func setSelection(_ value: String, persona: String, key: String) {
        lock.withLock { selections[persona, default: [:]][key] = value }
    }
    func rejectSelectorWrites(_ persona: String, _ reject: Bool) {
        lock.withLock { if reject { rejectedSelectors.insert(persona) } else { rejectedSelectors.remove(persona) } }
    }
    func rejectSharedWrites(_ key: String, _ reject: Bool) {
        lock.withLock { if reject { rejectedWrites.insert(key) } else { rejectedWrites.remove(key) } }
    }
    func rejectRead(_ key: String, _ reject: Bool) {
        lock.withLock { if reject { rejectedReads.insert(key) } else { rejectedReads.remove(key) } }
    }
    private func readShared(_ key: String) throws -> String? {
        try lock.withLock {
            guard !rejectedReads.contains(key) else { throw AccountSessionPersistenceError.unavailable }
            return shared[key]
        }
    }
    private func writeShared(_ value: String, key: String) -> Bool {
        lock.withLock {
            writes += 1
            guard !rejectedWrites.contains(key) else { return false }
            shared[key] = value
            return true
        }
    }
    private func removeShared(_ key: String) -> Bool {
        lock.withLock { writes += 1; shared[key] = nil; return true }
    }
}
