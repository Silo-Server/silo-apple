import XCTest
@testable import Silo

/// Behaviour tests for the player's settings sync: the debounce window, the
/// retry-with-the-same-mutation-id rule, and the typed defaults that replaced
/// the legacy empty-string guard.
///
/// Everything runs against a fake transport — no network, no singleton — so the
/// failure modes that matter (a write dropped on a 500, a retry that mints a
/// fresh id, a default-ON toggle flipping off on refresh) are reproducible
/// rather than dependent on a server being reachable.
///
/// Main-actor isolated because `PlayerSettings` is: its setters and its refresh
/// run where the UI calls them. The flusher itself is not, which is the point —
/// its queue is lock-guarded so a setter never has to hop actors to enqueue.
@MainActor
final class PlayerSettingsFlushTests: XCTestCase {

    // MARK: - Debounce

    func testRapidEditsToOneKeyCollapseToASingleWrite() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .milliseconds(40))

        // A slider drag: one value per frame, only the last one matters.
        for speed in [1.25, 1.5, 1.75, 2.0] {
            flusher.enqueue(.playerPlaybackSpeed, value: .double(speed))
        }
        await flusher.flushNow()

        let writes = transport.writes()
        XCTAssertEqual(writes.count, 1, "the debounce window must coalesce a drag into one write")
        XCTAssertEqual(writes.first?.value, .double(2.0), "the value the user stopped on must win")
    }

    func testDebounceDelaysTheWriteUntilTheWindowElapses() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .milliseconds(150))

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        // Well inside the window: nothing may have been sent yet.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(transport.writes().isEmpty, "a write must not leave before the debounce elapses")

        try await waitUntil("the debounced write lands") { transport.writes().count == 1 }
        XCTAssertEqual(transport.writes().first?.key, .playerHdrEnabled)
    }

    func testEditsToDifferentKeysInOneWindowAllSend() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .milliseconds(40))

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        flusher.enqueue(.playbackAutoSkipIntro, value: .bool(true))
        flusher.enqueue(.playerVideoGravity, value: .string("fill"))
        await flusher.flushNow()

        XCTAssertEqual(Set(transport.writes().map(\.key)),
                       [.playerHdrEnabled, .playbackAutoSkipIntro, .playerVideoGravity],
                       "coalescing is per key, not across the whole queue")
    }

    func testAQueuedKeyOutsideThePreferredPlayerOrderStillDrains() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .seconds(30))

        // The queue is generic over SettingKey. The fixed player list controls
        // preferred ordering, but must not become an accidental allowlist.
        flusher.enqueue(.playbackSubtitleLanguage, value: .string("ja"))
        await flusher.flushNow()

        XCTAssertEqual(transport.writes().map(\.key), [.playbackSubtitleLanguage])
        XCTAssertFalse(flusher.hasPendingWrites)
    }

    func testFlushNowBypassesTheDebounceWindow() async throws {
        let transport = FakeSettingsTransport()
        // A window far longer than this test would wait for.
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .seconds(30))

        flusher.enqueue(.playerSeekCacheEnabled, value: .bool(false))
        await flusher.flushNow()

        XCTAssertEqual(transport.writes().count, 1, "an explicit flush must not wait out the window")
    }

    /// The debounced write must not run inside a task it has cancelled.
    ///
    /// The timer used to call `flushNow()` directly, and `flushNow()` opens by
    /// cancelling `debounceTask` — which on that path *is* the executing task.
    /// Everything after ran with `Task.isCancelled == true`, and `URLSession`
    /// reports its enclosing task's cancellation as `NSURLErrorCancelled`, so
    /// every debounced write burned an attempt the request never survived and
    /// only landed on the first backoff retry a second later. The fake fails a
    /// cancelled send for exactly this reason.
    func testTheDebouncedWriteDoesNotRunUnderACancelledTask() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(40),
            // A retry window long enough that a first-attempt failure could not
            // be papered over by a retry landing inside the wait below.
            retryPolicy: .init(maximumAutomaticRetries: 3, base: .seconds(10), maximum: .seconds(10))
        )

        // Only the timer fires this: no explicit flushNow anywhere.
        flusher.enqueue(.playerHdrEnabled, value: .bool(false))

        try await waitUntil("the debounced write lands") { transport.writes().count == 1 }
        XCTAssertEqual(transport.cancelledAttemptCount(), 0,
                       "the debounce timer cancelled the task its own writes run in")
        XCTAssertFalse(flusher.hasPendingWrites,
                       "the first attempt must succeed, not be rescued by a backoff retry")
    }

    /// The same guarantee for a clear, which takes the other branch of `send`.
    func testTheDebouncedDeleteDoesNotRunUnderACancelledTask() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(40),
            retryPolicy: .init(maximumAutomaticRetries: 3, base: .seconds(10), maximum: .seconds(10))
        )

        flusher.enqueueDelete(.playbackSubtitleAppearance)

        try await waitUntil("the debounced delete lands") { transport.deletes().count == 1 }
        XCTAssertEqual(transport.cancelledAttemptCount(), 0)
        XCTAssertFalse(flusher.hasPendingWrites)
    }

    /// A newer edit inside the window replaces the timer, and only one flush
    /// runs — the fix must not turn a re-armed window into two drains.
    func testReArmingTheWindowStillCollapsesToOneWrite() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .milliseconds(60))

        flusher.enqueue(.playerAudioSyncMs, value: .int(100))
        try await Task.sleep(for: .milliseconds(20))
        flusher.enqueue(.playerAudioSyncMs, value: .int(200))

        try await waitUntil("the debounced write lands") { transport.writes().count == 1 }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(transport.writes().map(\.value), [.int(200)],
                       "the superseded timer must not fire a second drain")
        XCTAssertEqual(transport.cancelledAttemptCount(), 0)
    }

    func testAnExplicitFlushDoesNotCancelARetryThatAlreadyStartedDraining() async throws {
        let transport = FakeSettingsTransport()
        transport.writeDelay = .milliseconds(80)
        transport.failNextWrites(1, with: .server(status: 503, code: nil, message: nil))
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            retryPolicy: .init(
                maximumAutomaticRetries: 2,
                base: .milliseconds(30),
                maximum: .milliseconds(30)
            )
        )

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        await flusher.flushNow()
        XCTAssertTrue(flusher.hasPendingWrites, "precondition: the first attempt failed")

        transport.onAttemptStart = {
            Task { await flusher.flushNow() }
        }

        try await waitUntil("the retry lands without cancellation") {
            !flusher.hasPendingWrites && transport.writes().count == 2
        }
        XCTAssertEqual(
            transport.cancelledAttemptCount(),
            0,
            "flushNow must not cancel the retry task after that task has entered drain()"
        )
    }

    // MARK: - Durability

    /// An edit still inside the debounce window when the process dies must
    /// survive it. The window is 750 ms of in-memory-only queue, and neither
    /// lifecycle notification closes the hole: macOS terminates on Cmd-Q
    /// without waiting on the flush `willResignActive` starts, and a suspended
    /// iOS app killed from the switcher is never told at all.
    func testAnEditInsideTheWindowSurvivesProcessDeath() async throws {
        let journal = InMemoryWriteJournal()
        let dying = PlayerSettingsFlusher(
            transport: FakeSettingsTransport(),
            debounce: .seconds(30),
            journal: journal
        )
        dying.enqueue(.playerPlaybackSpeed, value: .double(1.5))
        let queuedId = try XCTUnwrap(dying.mutationId(for: .playerPlaybackSpeed))

        // Relaunch: a fresh flusher over the same journal, nothing shared in
        // memory.
        let transport = FakeSettingsTransport()
        let relaunched = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(10),
            journal: journal
        )
        XCTAssertTrue(relaunched.hasPendingWrites, "the queue must outlive the process")
        await relaunched.flushNow()

        let writes = transport.writes()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.value, .double(1.5))
        XCTAssertEqual(writes.first?.mutationId, queuedId,
                       "a restored write is the same logical write: replaying its id is what stops a double apply")
    }

    /// A write killed between the request leaving and its response arriving is
    /// in neither `pending` nor the drain's snapshot, so the journal has to
    /// describe it too.
    func testAWriteInterruptedMidRequestIsStillOwed() async throws {
        let journal = InMemoryWriteJournal()
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        var journalledMidFlight: [SettingKey: PendingSettingWrite] = [:]
        transport.onWrite = { _ in
            journalledMidFlight = journal.load()
        }
        flusher.enqueue(.playerVideoGravity, value: .string("fill"))
        await flusher.flushNow()

        XCTAssertEqual(journalledMidFlight[.playerVideoGravity]?.operation, .set(.string("fill")),
                       "an in-flight op must stay on disk until it is acknowledged")
        XCTAssertTrue(journal.load().isEmpty, "a settled op must be cleared from the journal")
    }

    /// A restored op is superseded by a newer edit to the same key rather than
    /// resurrecting the value the user has already replaced.
    func testARestoredOpIsSupersededByANewerEditToTheSameKey() async throws {
        let journal = InMemoryWriteJournal()
        journal.stored = [
            .playerAudioSyncMs: PendingSettingWrite(operation: .set(.int(-500)), mutationId: "stale"),
        ]
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )
        XCTAssertEqual(flusher.mutationId(for: .playerAudioSyncMs), "stale",
                       "precondition: the previous run's op was restored")

        flusher.enqueue(.playerAudioSyncMs, value: .int(250))
        await flusher.flushNow()

        XCTAssertEqual(transport.writes().map(\.value), [.int(250)],
                       "the newer edit must replace the restored one, not queue behind it")
        XCTAssertNotEqual(transport.writes().first?.mutationId, "stale",
                          "different content must not reuse the restored id — that is the 409 case")
    }

    /// The journal is partitioned by (server, profile, device), and the app-wide
    /// flusher is constructed long before any of those are known — so `init`'s
    /// restore can come up empty for a queue that is nonetheless owed. The
    /// refresh that runs after sign-in has to look again.
    func testARestoreAfterTheScopeBecomesKnownPicksUpTheQueue() async throws {
        let journal = InMemoryWriteJournal()
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )
        XCTAssertFalse(flusher.hasPendingWrites, "precondition: nothing was readable at construction")

        // The scope resolved, and the journal now answers with what it holds.
        journal.stored = [
            .playerHdrEnabled: PendingSettingWrite(operation: .set(.bool(false)), mutationId: "owed"),
        ]
        flusher.restorePendingWrites()
        await flusher.flushNow()

        XCTAssertEqual(transport.writes().count, 1)
        XCTAssertEqual(transport.writes().first?.mutationId, "owed",
                       "a restored write keeps its id so a replay cannot double-apply")
    }

    /// The queue is addressed to one (server, profile, device) triple. Replaying
    /// it under a different one would write the previous profile's choice onto
    /// the current profile.
    func testAQueuePersistedUnderAnotherScopeIsNotReplayed() async throws {
        let suiteName = "settings-journal-scope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let scope = LockedScopeValue("server-a|profile-1|device")
        let journal = UserDefaultsSettingsWriteJournal(
            defaults: defaults,
            scopeProvider: { scope.value }
        )

        journal.save([.playerHdrEnabled: PendingSettingWrite(operation: .set(.bool(false)), mutationId: "id")])
        XCTAssertFalse(journal.load().isEmpty, "precondition: it is readable in its own scope")

        scope.value = "server-a|profile-2|device"
        XCTAssertTrue(journal.load().isEmpty, "another profile's queue must not be adopted")
    }

    func testAnInMemoryFailureDoesNotCrossAProfileSwitch() async throws {
        let suiteName = "settings-journal-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let scope = LockedScopeValue("server-a|profile-1|device")
        let journal = UserDefaultsSettingsWriteJournal(
            defaults: defaults,
            scopeProvider: { scope.value }
        )
        let transport = FakeSettingsTransport()
        transport.failNextWrites(1, with: .profileRequired)
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        await flusher.flushNow()
        XCTAssertTrue(flusher.hasPendingWrites, "precondition: profile 1 still owes the write")

        scope.value = "server-a|profile-2|device"
        flusher.restorePendingWrites()
        transport.succeedFromNowOn()
        await flusher.flushNow()
        XCTAssertEqual(
            transport.writes().count,
            1,
            "profile 1's in-memory operation must not be sent with profile 2's headers"
        )

        scope.value = "server-a|profile-1|device"
        flusher.restorePendingWrites()
        await flusher.flushNow()
        XCTAssertEqual(transport.writes().count, 2, "the original scope must still be able to replay its journal")
    }

    func testAProfileSwitchDuringDrainPreservesTheNewScopesSameKeyWrite() async throws {
        let suiteName = "settings-journal-inflight-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let firstScope = "server-a|profile-1|device"
        let secondScope = "server-a|profile-2|device"
        let scope = LockedScopeValue(firstScope)
        let journal = UserDefaultsSettingsWriteJournal(
            defaults: defaults,
            scopeProvider: { scope.value }
        )
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        transport.onAttemptStart = {
            guard scope.value == firstScope else { return }
            scope.value = secondScope
            journal.save([
                .playerHdrEnabled: PendingSettingWrite(
                    operation: .set(.bool(true)),
                    mutationId: "profile-2-write",
                    scopeIdentifier: secondScope
                ),
            ])
            flusher.restorePendingWrites()
        }

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        await flusher.flushNow()

        XCTAssertEqual(
            transport.writes().map(\.value),
            [.bool(false), .bool(true)],
            "an old scope's in-flight key must not erase the new scope's journal entry for that key"
        )
        XCTAssertTrue(journal.load().isEmpty, "the new scope's write should be retired after it lands")
    }

    func testASettledDeleteIsRetiredFromItsOriginalScopeAfterAProfileSwitch() async throws {
        let suiteName = "settings-journal-delete-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let firstScope = "server-a|profile-1|device"
        let secondScope = "server-a|profile-2|device"
        let scope = LockedScopeValue(firstScope)
        let profile = LockedScopeValue("profile-1")
        let journal = UserDefaultsSettingsWriteJournal(
            defaults: defaults,
            profileProvider: { profile.value },
            scopeProvider: { scope.value }
        )
        let transport = FakeSettingsTransport()
        await transport.writeGate.block()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        flusher.enqueueDelete(.playerHdrEnabled)
        let flush = Task { await flusher.flushNow() }
        await transport.writeGate.waitUntilEntered()

        // The DELETE passed the flusher's scope check and is now inside the
        // transport. Switch profiles and keep a same-key write in profile 2;
        // retiring profile 1 must neither erase nor replace it.
        scope.value = secondScope
        profile.value = "profile-2"
        journal.save([
            .playerHdrEnabled: PendingSettingWrite(
                operation: .set(.bool(true)),
                mutationId: "profile-2-write",
                scopeIdentifier: secondScope,
                profileId: "profile-2"
            ),
        ])
        flusher.restorePendingWrites()

        await transport.writeGate.release()
        await flush.value

        XCTAssertEqual(transport.deletes(), [.playerHdrEnabled])
        XCTAssertEqual(transport.writes().map(\.mutationId), ["profile-2-write"])

        scope.value = firstScope
        profile.value = "profile-1"
        XCTAssertTrue(
            journal.load().isEmpty,
            "the acknowledged DELETE must be removed from profile 1's partition"
        )
        flusher.restorePendingWrites()
        await flusher.flushNow()
        XCTAssertEqual(
            transport.deletes(),
            [.playerHdrEnabled],
            "returning to profile 1 must not replay the settled DELETE"
        )
    }

    func testAScopeMismatchBeforeSendLeavesTheOperationInItsOriginalJournal() async throws {
        let suiteName = "settings-journal-unsent-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let firstScope = "server-a|profile-1|device"
        let scope = LockedScopeValue(firstScope)
        let journal = UserDefaultsSettingsWriteJournal(
            defaults: defaults,
            scopeProvider: { scope.value }
        )
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        flusher.enqueueDelete(.playerHdrEnabled)
        scope.value = "server-a|profile-2|device"
        await flusher.flushNow()
        XCTAssertTrue(transport.deletes().isEmpty, "the mismatched operation must not be sent")

        scope.value = firstScope
        XCTAssertEqual(journal.load()[.playerHdrEnabled]?.operation, .delete)
        flusher.restorePendingWrites()
        await flusher.flushNow()
        XCTAssertEqual(
            transport.deletes(),
            [.playerHdrEnabled],
            "an unattempted operation must remain available in its captured partition"
        )
    }

    func testAWriteKeepsTheProfileCapturedBeforeItsTransportSuspends() async throws {
        let suiteName = "settings-journal-profile-binding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let firstScope = "server-a|profile-1|device"
        let secondScope = "server-a|profile-2|device"
        let scope = LockedScopeValue(firstScope)
        let profile = LockedScopeValue("profile-1")
        let journal = UserDefaultsSettingsWriteJournal(
            defaults: defaults,
            profileProvider: { profile.value },
            scopeProvider: { scope.value }
        )
        let transport = FakeSettingsTransport()
        transport.currentProfileId = { profile.value }
        transport.onAttemptStart = {
            // The flusher's pre-send scope check has already passed. Model the
            // profile picker changing the session while the API call is
            // suspended before it resolves X-Profile-Id.
            scope.value = secondScope
            profile.value = "profile-2"
        }
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        await flusher.flushNow()

        XCTAssertEqual(
            transport.writes().first?.profileId,
            "profile-1",
            "a queued operation must not resolve its profile from a newer session after suspension"
        )
    }

    // MARK: - Mutation ids

    func testEachLogicalWriteGetsItsOwnMutationId() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .milliseconds(20))

        flusher.enqueue(.playerAudioSyncMs, value: .int(100))
        await flusher.flushNow()
        flusher.enqueue(.playerAudioSyncMs, value: .int(200))
        await flusher.flushNow()

        let ids = transport.writes().map(\.mutationId)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1], "two different writes must not share an idempotency key")
    }

    func testReplacingAPendingValueMintsAFreshId() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .seconds(30))

        flusher.enqueue(.playerAudioSyncMs, value: .int(100))
        let first = flusher.mutationId(for: .playerAudioSyncMs)
        flusher.enqueue(.playerAudioSyncMs, value: .int(200))
        let second = flusher.mutationId(for: .playerAudioSyncMs)

        XCTAssertNotNil(first)
        // Different content under a reused id is a 409 by design, so the queue
        // has to re-mint when the value changes.
        XCTAssertNotEqual(first, second, "new content must not reuse the previous write's id")
    }

    func testReEnqueueingTheIdenticalValueKeepsTheSameId() async throws {
        let transport = FakeSettingsTransport()
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .seconds(30))

        flusher.enqueue(.playerAudioSyncMs, value: .int(100))
        let first = flusher.mutationId(for: .playerAudioSyncMs)
        // A UI that re-emits its current value (a Binding round-trip, a
        // re-render) is the same logical write, not a new one.
        flusher.enqueue(.playerAudioSyncMs, value: .int(100))

        XCTAssertEqual(flusher.mutationId(for: .playerAudioSyncMs), first)
    }

    // MARK: - Retry

    func testATransientFailureStaysQueuedAndRetriesWithTheSameId() async throws {
        let transport = FakeSettingsTransport()
        // One 500, then success.
        transport.failNextWrites(1, with: .server(status: 503, code: "unavailable", message: nil))
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(20),
            retryPolicy: .init(maximumAutomaticRetries: 3, base: .milliseconds(30), maximum: .milliseconds(60))
        )

        flusher.enqueue(.playerDolbyVisionEnabled, value: .bool(false))
        await flusher.flushNow()

        // The op survived its failure rather than being dropped.
        XCTAssertTrue(flusher.hasPendingWrites, "a 5xx must not discard the user's setting")
        let attemptedId = try XCTUnwrap(transport.writes().first?.mutationId)

        try await waitUntil("the automatic retry lands") { transport.writes().count == 2 }
        let writes = transport.writes()
        XCTAssertEqual(writes[1].mutationId, attemptedId,
                       "a retry must replay the same id so the server can deduplicate it")
        XCTAssertEqual(writes[1].value, .bool(false))
        XCTAssertFalse(flusher.hasPendingWrites, "a successful retry clears the queue")
    }

    func testAContractRejectionDropsTheWriteInsteadOfRetryingForever() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextWrites(10, with: .invalidValue(message: "not in enum"))
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(20),
            retryPolicy: .init(maximumAutomaticRetries: 3, base: .milliseconds(20), maximum: .milliseconds(40))
        )

        flusher.enqueue(.playerVideoGravity, value: .string("nonsense"))
        await flusher.flushNow()

        XCTAssertFalse(flusher.hasPendingWrites,
                       "a value the contract refuses would fail identically forever")
        // And no timer was armed to keep hammering it.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(transport.writes().count, 1)
    }

    func testAMissingProfileHoldsTheWriteWithoutSpinning() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextWrites(10, with: .profileRequired)
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(20),
            retryPolicy: .init(maximumAutomaticRetries: 3, base: .milliseconds(20), maximum: .milliseconds(40))
        )

        flusher.enqueue(.playbackAutoPlayNext, value: .bool(false))
        await flusher.flushNow()

        // Held: only picking a profile fixes this, and dropping it would lose a
        // choice the user already made.
        XCTAssertTrue(flusher.hasPendingWrites)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(transport.writes().count, 1,
                       "a precondition failure must not arm a backoff timer")
    }

    func testExhaustingAutomaticRetriesKeepsTheWriteForTheNextTrigger() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextWrites(100, with: .transport(description: "offline"))
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .milliseconds(10),
            retryPolicy: .init(maximumAutomaticRetries: 2, base: .milliseconds(20), maximum: .milliseconds(20))
        )

        flusher.enqueue(.playerSubtitleSyncMs, value: .int(-250))
        await flusher.flushNow()
        try await waitUntil("both automatic retries run") { transport.writes().count == 3 }

        // Budget spent: the op is still queued, and no further attempts happen
        // on their own.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(transport.writes().count, 3, "the automatic retry budget must be bounded")
        XCTAssertTrue(flusher.hasPendingWrites, "an exhausted budget must not drop the write")

        // A later trigger — app foreground, player exit — picks it up again.
        transport.succeedFromNowOn()
        await flusher.flushNow()
        XCTAssertEqual(transport.writes().count, 4)
        XCTAssertFalse(flusher.hasPendingWrites)
    }

    func testANewerValueDuringADrainIsNotOverwrittenByTheFailedOne() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextWrites(1, with: .server(status: 500, code: nil, message: nil))
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            retryPolicy: .init(maximumAutomaticRetries: 2, base: .milliseconds(20), maximum: .milliseconds(20))
        )

        // First value fails; a second is enqueued and succeeds in the same
        // drain, because the drain loops until the queue comes back empty.
        flusher.enqueue(.playerAudioSyncMs, value: .int(100))
        transport.onWrite = { [weak flusher] write in
            guard write.value == .int(100) else { return }
            flusher?.enqueue(.playerAudioSyncMs, value: .int(300))
        }
        await flusher.flushNow()

        XCTAssertEqual(transport.writes().map(\.value), [.int(100), .int(300)])
        XCTAssertFalse(
            flusher.hasPendingWrites,
            "the settled newer op must evict the older failed one, not be replaced by it"
        )
    }

    func testConcurrentFlushesCoalesceInsteadOfDoubleSending() async throws {
        let transport = FakeSettingsTransport()
        transport.writeDelay = .milliseconds(40)
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .seconds(30))

        flusher.enqueue(.playbackAutoSkipCredits, value: .bool(true))
        async let first: Void = flusher.flushNow()
        async let second: Void = flusher.flushNow()
        _ = await (first, second)

        XCTAssertEqual(transport.writes().count, 1, "a second flush must wait, not re-send")
    }

    func testAWriteAlreadyBeingDrainedStillCountsAsOutstanding() async throws {
        let transport = FakeSettingsTransport()
        await transport.writeGate.block()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30)
        )

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        let flush = Task { await flusher.flushNow() }
        await transport.writeGate.waitUntilEntered()

        XCTAssertTrue(
            flusher.hasPendingWrites,
            "lifecycle handling must keep the process alive after pending moves to inFlight"
        )

        await transport.writeGate.release()
        await flush.value
        XCTAssertFalse(flusher.hasPendingWrites)
    }

    // MARK: - Deletes

    func testClearingAScopeWithNothingStoredIsTreatedAsAlreadyDone() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextDeletes(1, with: .noValueAtScope)
        let flusher = PlayerSettingsFlusher(transport: transport, debounce: .milliseconds(20))

        flusher.enqueueDelete(.playbackSubtitleAppearance)
        await flusher.flushNow()

        XCTAssertFalse(flusher.hasPendingWrites,
                       "a 404 on delete means the reset already happened")
    }

    func testAnOldServerSettlesADeleteInsteadOfReplayingItAfterUpgrade() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextDeletes(1, with: .serverUpgradeRequired)
        let journal = InMemoryWriteJournal()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        flusher.enqueueDelete(.playerHdrEnabled)
        await flusher.flushNow()

        XCTAssertFalse(flusher.hasPendingWrites)
        XCTAssertTrue(journal.load().isEmpty)
        transport.succeedFromNowOn()
        await flusher.flushNow()
        XCTAssertEqual(transport.deletes(), [.playerHdrEnabled])
    }

    func testAnOldServerKeepsASetQueuedForALaterUpgrade() async throws {
        let transport = FakeSettingsTransport()
        transport.failNextWrites(1, with: .serverUpgradeRequired)
        let journal = InMemoryWriteJournal()
        let flusher = PlayerSettingsFlusher(
            transport: transport,
            debounce: .seconds(30),
            journal: journal
        )

        flusher.enqueue(.playerHdrEnabled, value: .bool(false))
        await flusher.flushNow()

        XCTAssertTrue(flusher.hasPendingWrites)
        XCTAssertEqual(journal.load()[.playerHdrEnabled]?.operation, .set(.bool(false)))
    }

    // MARK: - PlayerSettings integration

    func testLegacyCompoundQualityMigrationPreservesBothAxes() throws {
        let harness = try PlayerSettingsHarness()
        harness.defaults.set("720p-medium", forKey: "preferredQuality")
        harness.defaults.removeObject(forKey: "playback.maxBitrateKbps")

        let snapshot = harness.settings.legacySnapshot()

        XCTAssertEqual(snapshot[.playbackPreferredQuality], .string("720p"))
        XCTAssertEqual(snapshot[.playbackMaxBitrateKbps], .int(3_000))
    }

    func testLegacy328pAliasesMigrateTo480pWithTheir700KbpsCap() throws {
        for legacyId in ["328p", "420p"] {
            let harness = try PlayerSettingsHarness()
            harness.defaults.set(legacyId, forKey: "preferredQuality")
            harness.defaults.removeObject(forKey: "playback.maxBitrateKbps")

            let snapshot = harness.settings.legacySnapshot()

            XCTAssertEqual(
                snapshot[.playbackPreferredQuality],
                .string("480p"),
                legacyId
            )
            XCTAssertEqual(
                snapshot[.playbackMaxBitrateKbps],
                .int(700),
                legacyId
            )
        }
    }

    func testMigrationDoesNotWriteAnEquivalentNumericDefault() async throws {
        let harness = try PlayerSettingsHarness()
        let effective = EffectiveSettingValue(
            key: SettingKey.playerPlaybackSpeed.rawValue,
            value: .int(1),
            source: .contractDefault
        )

        let imported = await harness.settings.importLegacySettingsIfNeeded(
            scopeID: "numeric-equivalence-test",
            legacySnapshot: [.playerPlaybackSpeed: .double(1.0)],
            effectiveByKey: [.playerPlaybackSpeed: effective]
        )

        XCTAssertFalse(imported)
        XCTAssertTrue(harness.transport.writes().isEmpty)
    }

    func testMigrationImmediatelyRestoresEveryImportedValueLocally() async throws {
        let harness = try PlayerSettingsHarness()
        let effectiveByKey: [SettingKey: EffectiveSettingValue] = [
            .playbackPreferredQuality: .init(
                key: SettingKey.playbackPreferredQuality.rawValue,
                value: .string("auto"),
                source: .contractDefault
            ),
            .playbackMaxBitrateKbps: .init(
                key: SettingKey.playbackMaxBitrateKbps.rawValue,
                value: .null,
                source: .contractDefault
            ),
            .playbackAutoSkipIntro: .init(
                key: SettingKey.playbackAutoSkipIntro.rawValue,
                value: .bool(false),
                source: .contractDefault
            ),
        ]

        let imported = await harness.settings.importLegacySettingsIfNeeded(
            scopeID: "local-import-overlay-test",
            legacySnapshot: [
                .playbackPreferredQuality: .string("720p"),
                .playbackMaxBitrateKbps: .int(3_000),
                .playbackAutoSkipIntro: .bool(true),
            ],
            effectiveByKey: effectiveByKey
        )

        XCTAssertTrue(imported)
        XCTAssertEqual(harness.settings.preferredQualityResolution, "720p")
        XCTAssertEqual(harness.settings.maxBitrateKbps, 3_000)
        XCTAssertEqual(harness.settings.preferredQuality, "720p-medium")
        XCTAssertTrue(harness.settings.autoSkipIntro)
    }

    func testMigrationPreservesAudioLanguageSuggestions() async throws {
        let harness = try PlayerSettingsHarness()
        let suggestions = ["en", "ja", "pt-BR"]
        let effective = EffectiveSettingValue(
            key: SettingKey.playbackAudioLanguage.rawValue,
            value: .null,
            source: .contractDefault,
            suggestedValues: suggestions
        )

        let imported = await harness.settings.importLegacySettingsIfNeeded(
            scopeID: "audio-suggestions-import-test",
            legacySnapshot: [.playbackAudioLanguage: .string("fr")],
            effectiveByKey: [.playbackAudioLanguage: effective]
        )

        XCTAssertTrue(imported)
        XCTAssertEqual(harness.settings.audioLanguage, "fr")
        XCTAssertEqual(harness.settings.audioLanguageSuggestions, suggestions)
    }

    func testMigrationKeepsAPolicyConstrainedEffectiveValueLocally() async throws {
        let harness = try PlayerSettingsHarness()
        let constrained = EffectiveSettingValue(
            key: SettingKey.playbackPreferredQuality.rawValue,
            value: .string("720p"),
            source: .contractDefault,
            storedValue: .string("original"),
            constrained: true,
            constraintKind: .ceiling
        )

        let imported = await harness.settings.importLegacySettingsIfNeeded(
            scopeID: "constrained-import-overlay-test",
            legacySnapshot: [.playbackPreferredQuality: .string("original")],
            effectiveByKey: [.playbackPreferredQuality: constrained]
        )

        XCTAssertTrue(imported)
        XCTAssertEqual(
            harness.transport.writesByKey()[.playbackPreferredQuality]?.value,
            .string("original")
        )
        XCTAssertEqual(
            harness.settings.preferredQualityResolution,
            "720p",
            "migration must not bypass the policy-limited effective value locally"
        )
    }

    func testLegacySnapshotCoversEverySyncedDeviceSetting() throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setDolbyVisionEnabled(false)
        harness.settings.setSeekCacheEnabled(false)

        let snapshot = harness.settings.legacySnapshot()

        XCTAssertEqual(Set(snapshot.keys), Set(SettingKey.playerDeviceSettings))
        XCTAssertEqual(snapshot[.playerDolbyVisionEnabled], .bool(false))
        XCTAssertEqual(snapshot[.playerSeekCacheEnabled], .bool(false))
        XCTAssertNotNil(
            snapshot[.playbackSubtitleAppearance],
            "Apple's shipped subtitle appearance must be present in the migration input"
        )
    }

    func testLegacyAppleSubtitleDefaultIsMigratedWithoutACustomOverride() async throws {
        let harness = try PlayerSettingsHarness()
        let snapshot = harness.settings.legacySnapshot()
        var effectiveByKey = Dictionary(uniqueKeysWithValues: snapshot.map { key, value in
            (
                key,
                EffectiveSettingValue(
                    key: key.rawValue,
                    value: value,
                    source: .contractDefault
                )
            )
        })
        effectiveByKey[.playbackSubtitleAppearance] = .init(
            key: SettingKey.playbackSubtitleAppearance.rawValue,
            value: .null,
            source: .contractDefault
        )

        let imported = await harness.settings.importLegacySettingsIfNeeded(
            scopeID: "subtitle-default-test",
            legacySnapshot: snapshot,
            effectiveByKey: effectiveByKey
        )

        XCTAssertTrue(imported)
        XCTAssertEqual(
            harness.transport.writesByKey()[.playbackSubtitleAppearance]?.value,
            snapshot[.playbackSubtitleAppearance]
        )
    }

    func testSettersEncodeEachKeyAsItsContractType() async throws {
        let harness = try PlayerSettingsHarness()

        harness.settings.setPreferredQuality("1080p-medium")
        harness.settings.setAudioLanguage("ja")
        harness.settings.setAutoSkipIntro(true)
        harness.settings.setAutoSkipCredits(true)
        harness.settings.setAutoPlayNextEpisode(false)
        harness.settings.setNextUpPromptSeconds(45)
        harness.settings.setHDREnabled(false)
        harness.settings.setDolbyVisionEnabled(false)
        harness.settings.setSeekCacheEnabled(false)
        harness.settings.setPlaybackSpeed(1.5)
        harness.settings.setSubtitleSyncMs(-350)
        harness.settings.setVideoGravity(.fill)
        harness.settings.setPlayerOrientationMode(.rotateFreely)
        var appearance = SubtitleAppearance.default
        appearance.fontSize = .xlarge
        appearance.backgroundOpacity = 40
        await harness.settings.setSubtitleAppearance(appearance)

        let byKey = harness.transport.writesByKey()
        XCTAssertEqual(Set(byKey.keys), Set(SettingKey.playerDeviceSettings))
        // Not strings: the legacy registry took "true"/"45"/"1.5" because it
        // validated nothing. The contract types these, and a string here fails
        // the schema.
        XCTAssertEqual(byKey[.playbackPreferredQuality]?.value, .string("1080p"))
        XCTAssertEqual(byKey[.playbackMaxBitrateKbps]?.value, .int(12_000))
        XCTAssertEqual(byKey[.playbackAudioLanguage]?.value, .string("ja"))
        XCTAssertEqual(byKey[.playbackAutoSkipIntro]?.value, .bool(true))
        XCTAssertEqual(byKey[.playbackAutoSkipCredits]?.value, .bool(true))
        XCTAssertEqual(byKey[.playbackAutoPlayNext]?.value, .bool(false))
        XCTAssertEqual(byKey[.playbackNextUpPromptSeconds]?.value, .int(45))
        XCTAssertEqual(
            byKey[.playbackSubtitleAppearance]?.value,
            try SettingJSONValue.encoding(appearance)
        )
        XCTAssertEqual(byKey[.playerHdrEnabled]?.value, .bool(false))
        XCTAssertEqual(byKey[.playerDolbyVisionEnabled]?.value, .bool(false))
        XCTAssertEqual(byKey[.playerSeekCacheEnabled]?.value, .bool(false))
        XCTAssertEqual(byKey[.playerPlaybackSpeed]?.value, .double(1.5))
        XCTAssertEqual(byKey[.playerSubtitleSyncMs]?.value, .int(-350))
        XCTAssertEqual(byKey[.playerVideoGravity]?.value, .string("fill"))
        XCTAssertEqual(byKey[.playerOrientationMode]?.value, .string("rotateFreely"))
    }

    func testNoAudioLanguagePreferenceIsSentAsJSONNull() async throws {
        let harness = try PlayerSettingsHarness()

        harness.settings.setAudioLanguage("")
        await harness.settings.flushPendingDeviceSettings()

        // The contract's language_tag validator rejects "": the absence of a
        // preference is null, and sending the empty string would be a permanent
        // invalid_value.
        XCTAssertEqual(harness.transport.writesByKey()[.playbackAudioLanguage]?.value, .null)

        harness.transport.reset()
        harness.settings.setAudioLanguage("ja")
        await harness.settings.flushPendingDeviceSettings()
        XCTAssertEqual(harness.transport.writesByKey()[.playbackAudioLanguage]?.value, .string("ja"))
    }

    func testCompoundQualityIsStoredAsTheContractsTwoAxes() async throws {
        let harness = try PlayerSettingsHarness()

        harness.settings.setPreferredQuality("1080p-medium")
        await harness.settings.flushPendingDeviceSettings()

        let byKey = harness.transport.writesByKey()
        // "1080p-medium" is not a member of the contract's enum; sending it
        // verbatim is a permanent invalid_value, which is why the tier splits.
        XCTAssertEqual(byKey[.playbackPreferredQuality]?.value, .string("1080p"))
        XCTAssertEqual(byKey[.playbackMaxBitrateKbps]?.value, .int(12_000))
        // The stored pair is what the client holds; the in-player ladder id
        // is derived from it, so playback's call sites are unaffected.
        XCTAssertEqual(harness.settings.preferredQualityResolution, "1080p")
        XCTAssertEqual(harness.settings.maxBitrateKbps, 12_000)
        XCTAssertEqual(harness.settings.preferredQuality, "1080p-medium")
    }

    func testWideningTheQualityTierClearsTheOldBitrateCap() async throws {
        let harness = try PlayerSettingsHarness()

        harness.settings.setPreferredQuality("720p")
        await harness.settings.flushPendingDeviceSettings()
        harness.transport.reset()

        harness.settings.setPreferredQuality("auto")
        await harness.settings.flushPendingDeviceSettings()

        let byKey = harness.transport.writesByKey()
        XCTAssertEqual(byKey[.playbackPreferredQuality]?.value, .string("auto"))
        // Null, not omitted: leaving the 2 Mbps cap in place would keep
        // throttling a preference the user just widened to Auto.
        XCTAssertEqual(byKey[.playbackMaxBitrateKbps]?.value, .null)
    }

    func testSubtitleAppearanceIsSentAsAnObjectWithItsCamelCaseKeys() async throws {
        let harness = try PlayerSettingsHarness()

        var appearance = SubtitleAppearance.default
        appearance.fontSize = .xlarge
        appearance.backgroundOpacity = 40
        await harness.settings.setSubtitleAppearance(appearance)

        let value = try XCTUnwrap(harness.transport.writesByKey()[.playbackSubtitleAppearance]?.value)
        let object = try XCTUnwrap(value.objectValue, "the contract types this key as an object")
        // Not a stringified JSON document the way the legacy registry stored
        // it, and the value's own keys stay camelCase per the contract schema.
        XCTAssertEqual(object["fontSize"], .string("xlarge"))
        XCTAssertEqual(object["backgroundOpacity"], .int(40))
        XCTAssertNil(object["font_size"])
    }

    // MARK: - Typed defaults on refresh

    func testAbsentKeysFallBackToTheContractsTypedDefaults() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setHDREnabled(false)
        harness.settings.setAutoPlayNextEpisode(false)
        await harness.settings.flushPendingDeviceSettings()

        // A server whose contract predates these keys sends no row for them.
        harness.transport.effective = [
            .init(key: SettingKey.playerVideoGravity.rawValue, value: .string("fill"), source: .contractDefault)
        ]
        await harness.settings.refreshFromServer()

        // The generated contract declares both of these true by default, and
        // "the server did not answer" must resolve to that rather than to the
        // zero value of the type.
        XCTAssertTrue(harness.settings.hdrEnabled)
        XCTAssertTrue(harness.settings.autoPlayNextEpisode)
        XCTAssertEqual(harness.settings.videoGravity, .fill)
    }

    func testAServerAuthoredFalseIsHonouredRatherThanTreatedAsUnset() async throws {
        let harness = try PlayerSettingsHarness()
        XCTAssertTrue(harness.settings.hdrEnabled, "precondition: the contract default is on")

        harness.transport.effective = [
            .init(
                key: SettingKey.playerHdrEnabled.rawValue,
                value: .bool(false),
                source: .scope(.profileDevice),
                scope: .profileDevice
            )
        ]
        await harness.settings.refreshFromServer()

        // This is what the deleted empty-string guard would have swallowed. The
        // legacy endpoint could not distinguish "unset" from "false" — it sent
        // "" for both — so the guard had to treat anything unparseable as
        // absent. The canonical endpoint types the value, so a stored false is
        // unambiguous and must win over the default.
        XCTAssertFalse(harness.settings.hdrEnabled)
    }

    func testDefaultSourcedValuesAreAdoptedLikeAnyOtherResolution() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setAutoSkipIntro(true)
        await harness.settings.flushPendingDeviceSettings()
        XCTAssertTrue(harness.settings.autoSkipIntro)

        // Nobody has stored this key anywhere, so the server resolves it to the
        // contract default and says so.
        harness.transport.effective = [
            .init(key: SettingKey.playbackAutoSkipIntro.rawValue, value: .bool(false), source: .contractDefault)
        ]
        await harness.settings.refreshFromServer()

        XCTAssertFalse(harness.settings.autoSkipIntro,
                       "a resolved default is an answer, not a missing one")
    }

    func testRefreshResolvesTheQualityTierFromBothAxes() async throws {
        let harness = try PlayerSettingsHarness()

        harness.transport.effective = [
            .init(
                key: SettingKey.playbackPreferredQuality.rawValue,
                value: .string("720p"),
                source: .scope(.profile),
                scope: .profile
            ),
            .init(
                key: SettingKey.playbackMaxBitrateKbps.rawValue,
                value: .int(3000),
                source: .scope(.profile),
                scope: .profile
            ),
        ]
        await harness.settings.refreshFromServer()

        // The pair is adopted verbatim — not quantized onto this client's
        // ladder — so a web-authored choice is not silently rewritten the next
        // time this client touches a quality control.
        XCTAssertEqual(harness.settings.preferredQualityResolution, "720p")
        XCTAssertEqual(harness.settings.maxBitrateKbps, 3000)
        // The derived in-player tier still resolves for playback.
        XCTAssertEqual(harness.settings.preferredQuality, "720p-medium")
    }

    func testRefreshUsesOneBatchedCallForEveryKey() async throws {
        let harness = try PlayerSettingsHarness()

        await harness.settings.refreshFromServer()

        let calls = harness.transport.effectiveCalls()
        XCTAssertEqual(calls.count, 1, "a refresh must be one round trip, not one per key")
        XCTAssertEqual(Set(calls[0]), Set(SettingKey.playerDeviceSettings))
    }

    func testRefreshAdoptsEverySyncedPlayerSetting() async throws {
        let harness = try PlayerSettingsHarness()
        var appearance = SubtitleAppearance.default
        appearance.fontSize = .xxlarge
        appearance.fontColor = "#facc15"
        appearance.backgroundOpacity = 35
        appearance.position = .top

        let values: [SettingKey: SettingJSONValue] = [
            .playbackPreferredQuality: .string("1080p"),
            .playbackMaxBitrateKbps: .int(6_500),
            .playbackAudioLanguage: .string("fr-CA"),
            .playbackAutoSkipIntro: .bool(true),
            .playbackAutoSkipCredits: .bool(true),
            .playbackAutoPlayNext: .bool(false),
            .playbackNextUpPromptSeconds: .int(75),
            .playbackSubtitleAppearance: try SettingJSONValue.encoding(appearance),
            .playerHdrEnabled: .bool(false),
            .playerDolbyVisionEnabled: .bool(false),
            .playerSeekCacheEnabled: .bool(false),
            .playerPlaybackSpeed: .double(1.75),
            .playerSubtitleSyncMs: .int(-250),
            .playerVideoGravity: .string("stretch"),
            .playerOrientationMode: .string("rotateFreely"),
        ]
        XCTAssertEqual(Set(values.keys), Set(SettingKey.playerDeviceSettings))
        harness.transport.effective = SettingKey.playerDeviceSettings.compactMap { key in
            guard let value = values[key] else { return nil }
            return EffectiveSettingValue(
                key: key.rawValue,
                value: value,
                source: .scope(.profileDevice),
                scope: .profileDevice
            )
        }

        await harness.settings.refreshFromServer()

        XCTAssertEqual(harness.settings.preferredQualityResolution, "1080p")
        XCTAssertEqual(harness.settings.maxBitrateKbps, 6_500)
        XCTAssertEqual(harness.settings.audioLanguage, "fr-CA")
        XCTAssertTrue(harness.settings.autoSkipIntro)
        XCTAssertTrue(harness.settings.autoSkipCredits)
        XCTAssertFalse(harness.settings.autoPlayNextEpisode)
        XCTAssertEqual(harness.settings.nextUpPromptSeconds, 75)
        XCTAssertEqual(harness.settings.subtitleAppearance, appearance.sanitized())
        XCTAssertTrue(harness.settings.subtitleUsesDeviceAppearanceOverride)
        XCTAssertFalse(harness.settings.hdrEnabled)
        XCTAssertFalse(harness.settings.dolbyVisionEnabled)
        XCTAssertFalse(harness.settings.seekCacheEnabled)
        XCTAssertEqual(harness.settings.playbackSpeed, 1.75)
        XCTAssertEqual(harness.settings.subtitleSyncMs, -250)
        XCTAssertEqual(harness.settings.videoGravity, .stretch)
        XCTAssertEqual(harness.settings.playerOrientationMode, .rotateFreely)
    }

    func testASubtitleAppearanceResolvedAtTheProfileIsNotADeviceOverride() async throws {
        let harness = try PlayerSettingsHarness()

        harness.transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleAppearance.rawValue,
                value: ["fontSize": "xxlarge"],
                source: .scope(.profile),
                scope: .profile
            )
        ]
        await harness.settings.refreshFromServer()

        // Inherited, not adopted as this device's own override: the scope the
        // value resolved at is what distinguishes them.
        XCTAssertFalse(harness.settings.subtitleUsesDeviceAppearanceOverride)
        XCTAssertEqual(harness.settings.effectiveSubtitleAppearance.fontSize, .xxlarge)

        harness.transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleAppearance.rawValue,
                value: ["fontSize": "small"],
                source: .scope(.profileDevice),
                scope: .profileDevice
            )
        ]
        await harness.settings.refreshFromServer()

        XCTAssertTrue(harness.settings.subtitleUsesDeviceAppearanceOverride)
        XCTAssertEqual(harness.settings.subtitleAppearance.fontSize, .small)
    }

    func testAPartialStoredAppearanceKeepsTheDefaultsForOmittedProperties() async throws {
        let harness = try PlayerSettingsHarness()

        // The schema calls a stored appearance a sparse override, so a document
        // naming one property must not blank the other eight.
        harness.transport.effective = [
            .init(
                key: SettingKey.playbackSubtitleAppearance.rawValue,
                value: ["position": "top"],
                source: .scope(.profileDevice),
                scope: .profileDevice
            )
        ]
        await harness.settings.refreshFromServer()

        XCTAssertEqual(harness.settings.subtitleAppearance.position, .top)
        XCTAssertEqual(harness.settings.subtitleAppearance.fontColor, SubtitleAppearance.default.fontColor)
        XCTAssertEqual(harness.settings.subtitleAppearance.fontSize, SubtitleAppearance.default.fontSize)
    }

    func testResetClearsEverySyncedKeyAtTheDeviceScope() async throws {
        let harness = try PlayerSettingsHarness()

        await harness.settings.resetAllDeviceSettings()

        XCTAssertEqual(Set(harness.transport.deletes()), Set(SettingKey.playerDeviceSettings))
    }

    func testAnOldServerResetAppliesContractDefaultsAndDoesNotQueueDeletes() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setPreferredQuality("720p-medium")
        harness.settings.setAutoSkipIntro(true)
        harness.settings.setHDREnabled(false)
        var appearance = SubtitleAppearance.default
        appearance.fontSize = .xlarge
        await harness.settings.setSubtitleAppearance(appearance)
        harness.transport.reset()
        harness.transport.failNextDeletes(
            SettingKey.playerDeviceSettings.count,
            with: .serverUpgradeRequired
        )
        harness.transport.effectiveError = .serverUpgradeRequired

        await harness.settings.resetAllDeviceSettings()

        XCTAssertEqual(harness.settings.preferredQualityResolution, "auto")
        XCTAssertNil(harness.settings.maxBitrateKbps)
        XCTAssertFalse(harness.settings.autoSkipIntro)
        XCTAssertTrue(harness.settings.hdrEnabled)
        XCTAssertEqual(harness.settings.subtitleAppearance, .default)
        XCTAssertFalse(harness.settings.subtitleUsesDeviceAppearanceOverride)

        let attemptedDeletes = harness.transport.deletes().count
        harness.transport.succeedFromNowOn()
        await harness.settings.flushPendingDeviceSettings()
        XCTAssertEqual(
            harness.transport.deletes().count,
            attemptedDeletes,
            "old-server reset deletes must not replay after the server is upgraded"
        )
    }

    func testAnUnavailableRefreshKeepsCachedValues() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setPreferredQuality("720p-medium")
        harness.settings.setAutoSkipIntro(true)
        harness.transport.effectiveError = .transport(description: "offline")

        let result = await harness.settings.refreshFromServer()

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(harness.settings.preferredQualityResolution, "720p")
        XCTAssertEqual(harness.settings.maxBitrateKbps, 3_000)
        XCTAssertTrue(harness.settings.autoSkipIntro)
    }

    // MARK: - Playback speed alignment

    func testPlaybackSpeedIsSnappedToTheContractsStepGrid() async throws {
        let harness = try PlayerSettingsHarness()

        // The contract declares step 0.05 from a 0.25 minimum, and the server
        // rejects anything off that grid — including a value that arrived at
        // 1.7500000000000002 through ordinary double arithmetic.
        harness.settings.setPlaybackSpeed(1.33)
        await harness.settings.flushPendingDeviceSettings()

        let value = try XCTUnwrap(harness.transport.writesByKey()[.playerPlaybackSpeed]?.value)
        let speed = try XCTUnwrap(value.doubleValue)
        let steps = (speed - 0.25) / 0.05
        XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9,
                       "\(speed) is not on the contract's 0.05 grid")
        XCTAssertEqual(speed, 1.35, accuracy: 1e-9)
    }

    func testPlaybackSpeedIsClampedToTheContractsRange() async throws {
        let harness = try PlayerSettingsHarness()

        harness.settings.setPlaybackSpeed(9.0)
        XCTAssertEqual(harness.settings.playbackSpeed, 3.0)
        harness.settings.setPlaybackSpeed(0.01)
        XCTAssertEqual(harness.settings.playbackSpeed, 0.25)
    }

    // MARK: - Quality axes

    func testEveryQualityTierRoundTripsThroughTheTwoAxes() throws {
        // Splitting and rejoining must be the identity for every id this
        // client's picker can produce, or a user's tier would silently drift a
        // rung on the first refresh after they set it.
        for option in ApplePlaybackQuality.settingsOptions {
            let axes = AppleQualityAxes.split(option.id)
            XCTAssertEqual(
                AppleQualityAxes.join(resolution: axes.resolution, bitrateKbps: axes.bitrateKbps),
                option.id,
                "\(option.id) did not survive the round trip"
            )
        }
    }

    func testSplitProducesOnlyContractEnumMembers() throws {
        // The whole reason for the split: the server validates this key against
        // its enum, so anything else is a permanent invalid_value.
        for option in ApplePlaybackQuality.settingsOptions {
            let resolution = AppleQualityAxes.split(option.id).resolution
            XCTAssertTrue(
                AppleQualityAxes.resolutionMembers.contains(resolution),
                "\(option.id) split to \(resolution), which the contract's enum does not allow"
            )
        }
    }

    func testTheTightestTierKeepsItsCapRatherThanWidening() throws {
        // 328p predates the contract's ladder and has no member of its own. It
        // maps up to 480p but keeps its 700 kbps cap, because dropping the cap
        // would uncap the connection of the user who asked for the least.
        let axes = AppleQualityAxes.split("328p")
        XCTAssertEqual(axes.resolution, "480p")
        XCTAssertEqual(axes.bitrateKbps, 700)
    }

    /// The stored resolution is what the join answers with, on every client.
    ///
    /// This is the cross-client contract: the V3 start request carries only a
    /// bare resolution, so a join that traded a resolution tier away to stay
    /// under the cap would send `720p` from a pair the web and Android send
    /// `1080p` from. Apple's ladder having no 1080p rung below 8 Mbps is a fact
    /// about its rung table, not about the user's choice.
    func testASharedPresetResolvesToItsOwnResolutionNotALowerOne() throws {
        for (resolution, bitrateKbps) in [("1080p", 10_000), ("1080p", 6_000), ("1080p", 3_000),
                                          ("720p", 4_000), ("720p", 2_000), ("480p", 1_500)] {
            let id = AppleQualityAxes.join(resolution: resolution, bitrateKbps: bitrateKbps)
            XCTAssertEqual(
                AppleQualityAxes.split(id).resolution, resolution,
                "\(resolution) at \(bitrateKbps) kbps joined to \(id), a different resolution"
            )
        }
    }

    /// The specific regression: the two most common shared presets used to
    /// resolve to 720p rungs here while the other clients kept 1080p.
    func testTheWebs1080pPresetsStay1080p() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 6_000), "1080p-8")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 3_000), "1080p-8")
    }

    /// The bitrate axis still chooses *which* rung of the stored resolution.
    func testTheCapChoosesTheRungWithinTheStoredResolution() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 12_000), "1080p-medium")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 20_000), "1080p-high")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "720p", bitrateKbps: 3_000), "720p-medium")
    }

    func testACapBelowEveryRungKeepsTheResolutionAndTakesTheSmallestRung() throws {
        // The resolution is what the request carries, so it is kept; the cap is
        // enforced at request time instead of by shrinking the picture.
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 300), "1080p-8")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "480p", bitrateKbps: 300), "328p")
    }

    /// What the join gave up, the transcode request has to honour: the stored
    /// cap clamps the encode target rather than being lost.
    func testTheStoredCapClampsTheLegacyTranscodeTarget() throws {
        let id = AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 6_000)
        let option = try XCTUnwrap(ApplePlaybackQuality.settingsOptions.first { $0.id == id })
        XCTAssertEqual(option.bitrateKbps, 8_000, "precondition: the chosen rung is above the cap")

        let source = Self.version(fileId: 1, resolution: "1080p", bitrateKbps: 30_000)
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(for: option, selectedVersion: source, capKbps: 6_000),
            6_000,
            "the cap must bound the encode target, not the rung"
        )
        // And a source inside the rung but over the cap still has to be
        // re-encoded, or the cap would be silently uncapped.
        let modest = Self.version(fileId: 2, resolution: "1080p", bitrateKbps: 7_000)
        XCTAssertTrue(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: id, selectedVersion: modest, capKbps: 6_000
            ),
            "a source above the cap must transcode even when it is under the rung"
        )
        XCTAssertFalse(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: id, selectedVersion: modest, capKbps: nil
            ),
            "without a cap the rung alone decides"
        )
    }

    func testAutoResolutionStillEnforcesANumericBitrateCap() throws {
        let qualityId = AppleQualityAxes.join(resolution: "auto", bitrateKbps: 6_000)
        XCTAssertEqual(qualityId, ApplePlaybackQuality.autoId)
        let option = try XCTUnwrap(
            ApplePlaybackQuality.settingsOptions.first { $0.id == qualityId }
        )
        let source = Self.version(fileId: 3, resolution: "1080p", bitrateKbps: 7_000)

        XCTAssertTrue(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: qualityId,
                selectedVersion: source,
                capKbps: 6_000
            ),
            "Auto removes the resolution ceiling, not the independent bandwidth ceiling"
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: source,
                capKbps: 6_000
            ),
            6_000
        )
    }

    func testOriginalResolutionStillEnforcesANumericBitrateCapOnLegacyPlayback() throws {
        let qualityId = AppleQualityAxes.join(resolution: "original", bitrateKbps: 6_000)
        XCTAssertEqual(qualityId, ApplePlaybackQuality.originalId)
        let option = try XCTUnwrap(
            ApplePlaybackQuality.settingsOptions.first { $0.id == qualityId }
        )
        let source = Self.version(fileId: 4, resolution: "2160p", bitrateKbps: 30_000)

        let forcedByQuality = ApplePlaybackQuality.shouldForceTranscode(
            preferredQualityId: qualityId,
            selectedVersion: source,
            capKbps: 6_000
        )
        XCTAssertTrue(
            forcedByQuality,
            "Original removes the resolution ceiling, not the independent bandwidth ceiling"
        )
        for delivery in [PlaybackDeliveryStrategy.direct, .remux, .transcode] {
            XCTAssertFalse(
                ApplePlaybackQuality.shouldUseLegacyCopyVideo(
                    delivery: delivery,
                    option: option,
                    forcedByQuality: forcedByQuality
                ),
                "legacy playback must encode rather than copy video above the cap"
            )
        }
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: source,
                capKbps: 6_000
            ),
            6_000
        )
    }

    func testWideningToOriginalOr4KReselectsAHigherResolutionSource() throws {
        let sevenTwenty = Self.version(fileId: 1, resolution: "720p", bitrateKbps: 4_000)
        let tenEighty = Self.version(fileId: 2, resolution: "1080p", bitrateKbps: 10_000)
        let fourK = Self.version(fileId: 3, resolution: "2160p", bitrateKbps: 30_000)
        let versions = [sevenTwenty, tenEighty, fourK]

        XCTAssertTrue(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "original",
                selectedVersion: sevenTwenty,
                availableVersions: versions
            )
        )
        XCTAssertTrue(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "2160p",
                selectedVersion: sevenTwenty,
                availableVersions: versions
            )
        )
        XCTAssertFalse(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "720p-high",
                selectedVersion: sevenTwenty,
                availableVersions: versions
            ),
            "a higher file above the requested ceiling is not eligible"
        )
        XCTAssertFalse(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "2160p",
                selectedVersion: fourK,
                availableVersions: versions
            ),
            "the selected file already satisfies the highest eligible resolution"
        )
    }

    func testInitialOriginalSelectionIgnoresARememberedLowerResolutionSource() throws {
        let sevenTwenty = Self.version(fileId: 1, resolution: "720p", bitrateKbps: 4_000)
        let fourK = Self.version(fileId: 2, resolution: "2160p", bitrateKbps: 30_000)
        let versions = [sevenTwenty, fourK]

        XCTAssertEqual(
            PlaybackSessionBridge.selectVersion(
                from: versions,
                lastFileId: sevenTwenty.fileId,
                preferredQuality: "original"
            ).fileId,
            fourK.fileId
        )
        XCTAssertEqual(
            PlaybackSessionBridge.selectVersion(
                from: versions,
                lastFileId: sevenTwenty.fileId,
                preferredQuality: nil
            ).fileId,
            sevenTwenty.fileId,
            "Auto must retain the remembered-version fallback"
        )
    }

    func testOriginalCopyFailureCannotFallBackToATranscode() throws {
        XCTAssertFalse(
            ApplePlaybackQuality.allowsLegacyCopyFallbackToTranscode(
                preferredQualityId: "original"
            )
        )
        XCTAssertTrue(
            ApplePlaybackQuality.allowsLegacyCopyFallbackToTranscode(
                preferredQualityId: nil
            ),
            "Auto retains the older-server compatibility fallback"
        )
    }

    func testLegacyCopyRejectionFallbackRetainsTheBandwidthCap() throws {
        XCTAssertEqual(ApplePlaybackQuality.legacyCopyFallbackBitrateKbps(capKbps: nil), 6_000)
        XCTAssertEqual(ApplePlaybackQuality.legacyCopyFallbackBitrateKbps(capKbps: 12_000), 6_000)
        XCTAssertEqual(ApplePlaybackQuality.legacyCopyFallbackBitrateKbps(capKbps: 3_000), 3_000)
    }

    func testAnUncappedResolutionPicksThatResolutionsBestTier() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: nil), "1080p-high")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "720p", bitrateKbps: nil), "720p-high")
    }

    func testTheContracts4KResolutionRemainsDistinctFromAuto() throws {
        let option = try XCTUnwrap(
            ApplePlaybackQuality.settingsOptions.first(where: { $0.id == "2160p" })
        )
        XCTAssertEqual(option.labelWithBitrate, "4K")
        XCTAssertNil(option.subtitle)
        XCTAssertEqual(ApplePlaybackQuality.normalizeStoredId("2160p"), "2160p")
        XCTAssertEqual(ApplePlaybackQuality.normalizeStoredId("4K"), "2160p")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "2160p", bitrateKbps: nil), "2160p")
        XCTAssertEqual(
            AppleQualityAxes.split("2160p"),
            .init(resolution: "2160p", bitrateKbps: nil)
        )
        XCTAssertEqual(
            ApplePlaybackQuality.activeQualityId(
                requestedQualityId: "2160p",
                selectedVersion: Self.version(
                    fileId: 4,
                    resolution: "2160p",
                    bitrateKbps: 30_000
                ),
                delivery: .direct
            ),
            "2160p"
        )

        let fourKSource = Self.version(fileId: 5, resolution: "2160p", bitrateKbps: 60_000)
        XCTAssertFalse(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: "2160p",
                selectedVersion: fourKSource
            )
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetResolution(for: option, selectedVersion: fourKSource),
            ""
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: fourKSource
            ),
            0,
            "the resolution-only option must not invent a bitrate ceiling"
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: fourKSource,
                capKbps: 15_000
            ),
            15_000,
            "an independent bandwidth cap still applies to 4K"
        )
        XCTAssertTrue(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: "2160p",
                selectedVersion: fourKSource,
                capKbps: 15_000
            )
        )
    }

    func testAnInPlayerQualityChoiceReplacesBothStoredAxes() throws {
        XCTAssertEqual(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: nil,
                fallbackBitrateKbps: 6_000
            ),
            6_000,
            "a foreign stored cap must survive exactly when there is no session override"
        )
        XCTAssertNil(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: "auto",
                fallbackBitrateKbps: 3_000
            ),
            "explicit Auto must clear a persisted cap"
        )
        XCTAssertNil(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: "original",
                fallbackBitrateKbps: 3_000
            ),
            "explicit Original must clear a persisted cap"
        )
        XCTAssertEqual(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: "1080p-high",
                fallbackBitrateKbps: 3_000
            ),
            20_000,
            "a higher in-player rung must replace, not retain, the lower persisted cap"
        )
    }

    func testUnknownResolutionsStillResolveToAuto() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: nil, bitrateKbps: 4000), "auto")
        // A member added by a newer server that this build has never seen.
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1440p", bitrateKbps: nil), "auto")
    }

    func testOriginalRemainsDistinctFromAuto() throws {
        XCTAssertEqual(ApplePlaybackQuality.normalizeStoredId("original"), "original")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "original", bitrateKbps: nil), "original")
        XCTAssertEqual(AppleQualityAxes.split("original"), .init(resolution: "original", bitrateKbps: nil))
    }

    func testRecoveryLoadRequestsKeepTheSessionQualityOverride() throws {
        let original = PlayerViewModel.LoadRequest(
            contentId: "movie-1",
            preferredFileId: 10,
            preferredAudioTrackIndex: 2,
            preferredSubtitleTrackIndex: 3,
            preferredSidecarSubtitleTrackId: 4,
            startFromBeginning: true,
            offlineDownloadId: "download-1",
            preferredQualityOverride: "720p-high"
        )

        let recovery = original.copyForRecovery(
            preferredFileId: 11,
            preferredAudioTrackIndex: 5,
            preferredSubtitleTrackIndex: 6,
            preferredSidecarSubtitleTrackId: 7,
            offlineDownloadId: nil
        )

        XCTAssertEqual(recovery.contentId, "movie-1")
        XCTAssertEqual(recovery.preferredFileId, 11)
        XCTAssertEqual(recovery.preferredAudioTrackIndex, 5)
        XCTAssertEqual(recovery.preferredSubtitleTrackIndex, 6)
        XCTAssertEqual(recovery.preferredSidecarSubtitleTrackId, 7)
        XCTAssertFalse(recovery.startFromBeginning)
        XCTAssertNil(recovery.offlineDownloadId)
        XCTAssertEqual(recovery.preferredQualityOverride, "720p-high")
    }

    // MARK: - Helpers

    /// A source file with only the two fields the quality policy reads.
    private static func version(fileId: Int, resolution: String, bitrateKbps: Int) -> FileVersion {
        FileVersion(
            fileId: fileId,
            fileName: nil,
            resolution: resolution,
            codecVideo: "h264",
            codecAudio: "aac",
            hdr: false,
            container: "mp4",
            fileSize: nil,
            duration: nil,
            bitrate: bitrateKbps,
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil
        )
    }

    /// Poll until `condition` holds, so a test never depends on a fixed sleep
    /// being long enough on a loaded machine.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }
}

// MARK: - Fakes

/// A ``PlayerSettingsTransport`` that records what it was asked to do and can
/// be told to fail in the ways the real API fails.
final class FakeSettingsTransport: PlayerSettingsTransport, @unchecked Sendable {
    struct Write: Equatable {
        let key: SettingKey
        let value: SettingJSONValue
        let mutationId: String
        let profileId: String?
    }

    /// What the next `effectiveValues` call answers with.
    var effective: [EffectiveSettingValue] = []
    var effectiveError: SettingsAPIError?
    /// Artificial latency, so a test can overlap two flushes.
    var writeDelay: Duration?
    /// Models the production transport resolving the active profile after an
    /// asynchronous suspension rather than receiving the queued profile.
    var currentProfileId: (@Sendable () -> String?)?
    /// Invoked as an attempt enters the transport, before artificial latency.
    var onAttemptStart: (() -> Void)?
    /// Invoked as each write is attempted, before its outcome is decided —
    /// the seam a test uses to enqueue a newer value mid-drain.
    var onWrite: ((Write) -> Void)?
    let writeGate = SettingsWriteGate()

    private let lock = NSLock()
    private var recordedWrites: [Write] = []
    private var recordedDeletes: [SettingKey] = []
    private var recordedEffectiveCalls: [[SettingKey]] = []
    private var writeFailures = 0
    private var writeError: SettingsAPIError = .transport(description: "stub")
    private var deleteFailures = 0
    private var deleteError: SettingsAPIError = .transport(description: "stub")
    private var cancelledAttempts = 0

    func failNextWrites(_ count: Int, with error: SettingsAPIError) {
        lock.lock()
        writeFailures = count
        writeError = error
        lock.unlock()
    }

    func failNextDeletes(_ count: Int, with error: SettingsAPIError) {
        lock.lock()
        deleteFailures = count
        deleteError = error
        lock.unlock()
    }

    func succeedFromNowOn() {
        lock.lock()
        writeFailures = 0
        deleteFailures = 0
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recordedWrites.removeAll()
        recordedDeletes.removeAll()
        recordedEffectiveCalls.removeAll()
        lock.unlock()
    }

    func writes() -> [Write] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites
    }

    /// The last write per key, which is what a caller asserting "what did this
    /// setter send" wants.
    func writesByKey() -> [SettingKey: Write] {
        var byKey: [SettingKey: Write] = [:]
        for write in writes() {
            byKey[write.key] = write
        }
        return byKey
    }

    func deletes() -> [SettingKey] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDeletes
    }

    func effectiveCalls() -> [[SettingKey]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEffectiveCalls
    }

    // MARK: PlayerSettingsTransport

    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        lock.lock()
        recordedEffectiveCalls.append(keys)
        let settings = effective
        let error = effectiveError
        lock.unlock()
        if let error { throw error }
        return EffectiveSettingValuesResponse(settings: settings, revision: SettingKey.revision)
    }

    func putValue(
        key: SettingKey,
        value: SettingJSONValue,
        mutationId: String,
        profileId: String?
    ) async throws {
        try failIfCancelled()
        onAttemptStart?()
        await writeGate.waitIfBlocked()
        if let writeDelay {
            try? await Task.sleep(for: writeDelay)
        }
        try failIfCancelled()
        let write = Write(
            key: key,
            value: value,
            mutationId: mutationId,
            profileId: profileId ?? currentProfileId?()
        )
        lock.lock()
        recordedWrites.append(write)
        let shouldFail = writeFailures > 0
        if shouldFail { writeFailures -= 1 }
        let error = writeError
        lock.unlock()

        onWrite?(write)
        if shouldFail { throw error }
    }

    func deleteValue(key: SettingKey, profileId: String?) async throws {
        try failIfCancelled()
        await writeGate.waitIfBlocked()
        try failIfCancelled()
        lock.lock()
        recordedDeletes.append(key)
        let shouldFail = deleteFailures > 0
        if shouldFail { deleteFailures -= 1 }
        let error = deleteError
        lock.unlock()
        if shouldFail { throw error }
    }

    /// Behave the way `URLSession` does when the enclosing task is cancelled.
    ///
    /// Without this the fake is *more forgiving than the network*: it is pure
    /// in-process work whose only suspension is a `try?`-swallowed sleep, so a
    /// drain running under a cancelled task succeeds here and fails against a
    /// real server with `NSURLErrorCancelled`. That is precisely the shape of
    /// the debounce bug this suite has to be able to see — the request never
    /// leaves the device, `HTTPClient` reports it as `.network`,
    /// `SettingsAPIError.from` maps it to `.transport`, and the write only
    /// lands on the first backoff retry.
    private func failIfCancelled() throws {
        guard !Task.isCancelled else {
            recordCancellation()
            throw SettingsAPIError.transport(description: "cancelled")
        }
    }

    private func recordCancellation() {
        lock.lock()
        cancelledAttempts += 1
        lock.unlock()
    }

    /// How many sends were attempted under a cancelled task.
    func cancelledAttemptCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelledAttempts
    }
}

actor SettingsWriteGate {
    private var isBlocked = false
    private var hasEntered = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func block() {
        isBlocked = true
    }

    func waitIfBlocked() async {
        hasEntered = true
        let observers = entryWaiters
        entryWaiters.removeAll()
        for observer in observers {
            observer.resume()
        }
        guard isBlocked else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        isBlocked = false
        let resumptions = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in resumptions {
            continuation.resume()
        }
    }
}

/// A ``PlayerSettingsWriteJournal`` in memory, so a test can hand the same
/// "disk" to a second flusher and model a relaunch without touching
/// `UserDefaults`.
final class InMemoryWriteJournal: PlayerSettingsWriteJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [SettingKey: PendingSettingWrite] = [:]

    var stored: [SettingKey: PendingSettingWrite] {
        get { load() }
        set { save(newValue) }
    }

    func load() -> [SettingKey: PendingSettingWrite] {
        lock.lock()
        defer { lock.unlock() }
        return contents
    }

    func save(_ pending: [SettingKey: PendingSettingWrite]) {
        lock.lock()
        contents = pending
        lock.unlock()
    }

    func retire(_ key: SettingKey, matching write: PendingSettingWrite) {
        lock.lock()
        if let persisted = contents[key],
           persisted.operation == write.operation,
           persisted.mutationId == write.mutationId {
            contents.removeValue(forKey: key)
        }
        lock.unlock()
    }
}

/// Lock-backed mutable scope for @Sendable journal-provider closures.
final class LockedScopeValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ value: String) {
        stored = value
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// A ``PlayerSettings`` wired to a fake transport and an isolated
/// `UserDefaults`, so a test never touches the singleton, the network, or the
/// simulator's shared preferences.
@MainActor
final class PlayerSettingsHarness {
    let settings: PlayerSettings
    let transport: FakeSettingsTransport
    let defaults: UserDefaults

    private let suiteName: String

    init(debounce: Duration = .milliseconds(10)) throws {
        let suiteName = "player-settings-flush-tests-\(UUID().uuidString)"
        self.suiteName = suiteName
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        self.transport = FakeSettingsTransport()
        self.settings = PlayerSettings(
            defaults: defaults,
            flusher: PlayerSettingsFlusher(transport: transport, debounce: debounce)
        )
    }

    deinit {
        // The suite is uniquely named per test, so nothing leaks between them;
        // this only keeps the simulator's preferences directory from growing a
        // plist per test run.
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}
