import Foundation
import XCTest
@testable import Silo

final class PlaybackMutationStoreTests: XCTestCase {
    private func fixture(installation: String? = nil) async throws -> (PlaybackMutationStore, PlaybackMutationAuthority, URL, TokenStore) {
        let name = "PlaybackMutationStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try PlaybackMutationAuthority(auth: XCTUnwrap(captured), installationID: installation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let url = root.appendingPathComponent("sessions.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: name) }
        return (PlaybackMutationStore(url: url), authority, url, tokens)
    }

    func testOwnerLossBoundLastSurvivesJournalReloadWithoutApplyingQueuedFinalSample() async throws {
        let (store, authority, url, _) = try await fixture(installation: "installation")
        let sessionID = UUID().uuidString.lowercased()
        let binding = APIv2ProgressTimeline(timelineId: String(repeating: "a", count: 64), mediaItemId: "book",
            fileId: "42", partOffsetSeconds: 60, partDurationSeconds: 30, durationSeconds: 90)
        let session = try await store.register(sessionID: sessionID, authority: authority, progressTimeline: binding, attemptID: "original")
        let pendingProgress = try await store.prepareProgress(session.id, authority: authority, position: 20, isPaused: false)
        let stopProposal = try await store.proposedStop(session.id, authority: authority, position: 29, isPaused: true)
        let stop = try await store.persistStop(session.id, authority: authority, stop: stopProposal)
        let recoveryID = UUID().uuidString.lowercased()
        func recovery(_ accepted: PlaybackSequencedSample?, state: PlaybackOwnerLossRecovery.State = .aborted) -> PlaybackOwnerLossRecovery {
            PlaybackOwnerLossRecovery(recoveryID: recoveryID, attemptID: "original", sessionID: sessionID,
                state: state, reason: "owner_lost", accepted: accepted)
        }
        let draining = recovery(nil, state: .draining)
        try await store.observeStopOwnerLoss(session.id, authority: authority, sent: stop, recovery: draining)
        let restored = PlaybackMutationStore(url: url)
        let before = try Data(contentsOf: url)
        for sample in [
            try PlaybackSequencedSample(sequence: 1, position: 5, isPaused: false),
            try PlaybackSequencedSample(sequence: 1, position: 5, isPaused: false, timelineId: binding.timelineId, itemPosition: 5),
            try PlaybackSequencedSample(sequence: 1, position: 31, isPaused: false, timelineId: binding.timelineId, itemPosition: 91),
            try PlaybackSequencedSample(sequence: 1, position: 5, isPaused: false, timelineId: String(repeating: "b", count: 64), itemPosition: 65)
        ] {
            do { try await restored.observeStopOwnerLoss(session.id, authority: authority, sent: stop,
                recovery: recovery(sample)); XCTFail() } catch {}
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        let last = try PlaybackSequencedSample(sequence: 1, position: 5, isPaused: false, timelineId: binding.timelineId, itemPosition: 65)
        let terminal = recovery(last)
        try await restored.observeStopOwnerLoss(session.id, authority: authority, sent: stop, recovery: terminal)
        try await restored.acknowledgeProgress(session.id, authority: authority, sent: pendingProgress,
            receipt: PlaybackSequencedProgressReceipt(outcome: .applied,
                accepted: try PlaybackSequencedSample(sequence: 3, position: 29, isPaused: true,
                    timelineId: binding.timelineId, itemPosition: 89)))
        let reloaded = PlaybackMutationStore(url: url)
        let saved = try await reloaded.session(session.id, authority: authority)
        XCTAssertEqual(saved.stopState, .abandoned)
        XCTAssertEqual(saved.stop, stop)
        XCTAssertEqual(saved.pendingProgress, pendingProgress)
        XCTAssertEqual(saved.accepted, last)
        XCTAssertEqual(saved.ownerLoss, terminal)
        XCTAssertNil(saved.historyID)
        try await reloaded.requireTerminalBoundSessions(authority: authority)
        let pending = try await reloaded.pendingStops(authority: authority, afterRestart: true)
        XCTAssertTrue(pending.isEmpty)
    }

    func testOwnerLossWithoutLastClearsAcceptedProjectionAndLegacyAttemptCannotBind() async throws {
        let (store, authority, url, _) = try await fixture(installation: "installation")
        let sessionID = UUID().uuidString.lowercased()
        let session = try await store.register(sessionID: sessionID, authority: authority, attemptID: "original")
        let sample = try await store.prepareProgress(session.id, authority: authority, position: 9, isPaused: false)
        try await store.acknowledgeProgress(session.id, authority: authority, sent: sample,
            receipt: PlaybackSequencedProgressReceipt(outcome: .applied, accepted: sample))
        let stopProposal = try await store.proposedStop(session.id, authority: authority, position: 99, isPaused: true)
        let stop = try await store.persistStop(session.id, authority: authority, stop: stopProposal)
        let recovery = PlaybackOwnerLossRecovery(recoveryID: UUID().uuidString, attemptID: "original", sessionID: sessionID,
            state: .aborted, reason: "owner_lost", accepted: nil)
        try await store.observeStopOwnerLoss(session.id, authority: authority, sent: stop, recovery: recovery)
        let saved = try await PlaybackMutationStore(url: url).session(session.id, authority: authority)
        XCTAssertNil(saved.accepted)
        XCTAssertEqual(saved.stop, stop)
        do {
        try await store.acknowledgeStop(session.id, authority: authority, sent: stop,
            receipt: PlaybackSequencedStopReceipt(outcome: .draining, stopId: stop.stopID, accepted: nil, historyId: nil))
            XCTFail("Abandoned AbortID rejects ordinary StopID")
        } catch {}

        let stillAbandoned = try await store.session(session.id, authority: authority)
        XCTAssertEqual(stillAbandoned.stopState, .abandoned)
        let legacyID = UUID().uuidString.lowercased()
        let legacy = try await store.register(sessionID: legacyID, authority: authority)
        let legacyStopProposal = try await store.proposedStop(legacy.id, authority: authority, position: nil, isPaused: true)
        let legacyStop = try await store.persistStop(legacy.id, authority: authority, stop: legacyStopProposal)
        let before = try Data(contentsOf: url)
        do {
            try await store.observeStopOwnerLoss(legacy.id, authority: authority, sent: legacyStop,
                recovery: PlaybackOwnerLossRecovery(recoveryID: UUID().uuidString, attemptID: "guessed", sessionID: legacyID,
                    state: .aborted, reason: "owner_lost", accepted: nil))
            XCTFail("A record without a journaled attempt cannot bind a recovery")
        } catch PlaybackSequencedError.authorityChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), before)
        try await store.acknowledgeStop(legacy.id, authority: authority, sent: legacyStop,
            receipt: PlaybackSequencedStopReceipt(outcome: .stopped, stopId: legacyStop.stopID, accepted: nil, historyId: nil))
    }

    func testOrdinaryStopCannotReplaceObservedAbortIDAcrossReloadOrAfterAbandonment() async throws {
        let (store, authority, url, _) = try await fixture(installation: "installation")
        let id = UUID().uuidString.lowercased()
        let session = try await store.register(sessionID: id, authority: authority, attemptID: "original")
        let stopProposal = try await store.proposedStop(session.id, authority: authority, position: 99, isPaused: true)
        let stop = try await store.persistStop(session.id, authority: authority, stop: stopProposal)
        let recoveryID = UUID().uuidString.lowercased()
        for state in [PlaybackOwnerLossRecovery.State.draining, .aborted] {
            let last = state == .aborted ? try PlaybackSequencedSample(sequence: 1, position: 12, isPaused: false) : nil
            let recovery = PlaybackOwnerLossRecovery(recoveryID: recoveryID, attemptID: "original", sessionID: id,
                state: state, reason: "owner_lost", accepted: last)
            try await store.observeStopOwnerLoss(session.id, authority: authority, sent: stop, recovery: recovery)
            let before = try Data(contentsOf: url)
            let reloaded = PlaybackMutationStore(url: url)
            for outcome in [PlaybackSequencedStopReceipt.Outcome.draining, .stopped, .replayed] {
                do {
                    try await reloaded.acknowledgeStop(session.id, authority: authority, sent: stop,
                        receipt: PlaybackSequencedStopReceipt(outcome: outcome, stopId: stop.stopID,
                            accepted: stop.sample, historyId: "not-an-abort-receipt"))
                    XCTFail("Late ordinary receipt must not replace AbortID")
                } catch {}
                XCTAssertEqual(try Data(contentsOf: url), before)
            }
        }
    }

    func testBoundReceiptKeepsUncertaintyUntilExactTimelineMappingMatches() async throws {
        let (store, authority, url, _) = try await fixture(installation: "installation")
        let binding = APIv2ProgressTimeline(timelineId: String(repeating: "a", count: 64),
            mediaItemId: "book", fileId: "42", partOffsetSeconds: 60, partDurationSeconds: 30, durationSeconds: 90)
        let session = try await store.register(sessionID: "bound", authority: authority, progressTimeline: binding)
        let sent = try await store.prepareProgress(session.id, authority: authority, position: 0, isPaused: true)
        XCTAssertEqual(sent.timelineId, binding.timelineId)
        XCTAssertNil(sent.itemPosition)
        let restarted = PlaybackMutationStore(url: url)
        for (digest, global) in [(String(repeating: "b", count: 64), 60.0), (binding.timelineId, 0.0)] {
            let accepted = try PlaybackSequencedSample(sequence: sent.sequence, position: 0, isPaused: true,
                timelineId: digest, itemPosition: global)
            do {
                try await restarted.acknowledgeProgress(session.id, authority: authority, sent: sent,
                    receipt: PlaybackSequencedProgressReceipt(outcome: .applied, accepted: accepted))
                XCTFail("Foreign receipt must not clear pending progress")
            } catch {}
            let saved = try await restarted.session(session.id, authority: authority)
            XCTAssertEqual(saved.pendingProgress, sent)
        }
        let accepted = try PlaybackSequencedSample(sequence: sent.sequence, position: 0, isPaused: true,
            timelineId: binding.timelineId, itemPosition: 60)
        try await restarted.acknowledgeProgress(session.id, authority: authority, sent: sent,
            receipt: PlaybackSequencedProgressReceipt(outcome: .applied, accepted: accepted))
        let saved = try await restarted.session(session.id, authority: authority)
        XCTAssertNil(saved.pendingProgress)
        XCTAssertEqual(saved.accepted?.itemPosition, 60)
    }

    func testBoundStopWithoutSampleRetainsDigestAndBlocksSuccessorUntilTerminalAcrossRestart() async throws {
        let (store, authority, url, _) = try await fixture(installation: "installation")
        let binding = APIv2ProgressTimeline(timelineId: String(repeating: "a", count: 64),
            mediaItemId: "book", fileId: "42", partOffsetSeconds: 0, partDurationSeconds: 30, durationSeconds: 90)
        let session = try await store.register(sessionID: "bound", authority: authority, progressTimeline: binding)
        let stopProposal = try await store.proposedStop(session.id, authority: authority, position: nil, isPaused: true)
        let stop = try await store.persistStop(session.id, authority: authority, stop: stopProposal)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SiloAPI.playbackMutationBody(stop)) as? [String: Any])
        XCTAssertEqual(body["timeline_id"] as? String, binding.timelineId)
        XCTAssertNil(body["position"])
        let restarted = PlaybackMutationStore(url: url)
        do { try await restarted.requireTerminalBoundSessions(authority: authority); XCTFail() } catch {}
        let retryProposal = try await restarted.proposedStop(session.id, authority: authority, position: 29, isPaused: false)
        let retry = try await restarted.persistStop(session.id, authority: authority, stop: retryProposal)
        XCTAssertEqual(try SiloAPI.playbackMutationBody(stop), try SiloAPI.playbackMutationBody(retry))
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop,
            receipt: PlaybackSequencedStopReceipt(outcome: .draining, stopId: stop.stopID, accepted: nil, historyId: nil))
        do { try await restarted.requireTerminalBoundSessions(authority: authority); XCTFail() } catch {}
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop,
            receipt: PlaybackSequencedStopReceipt(outcome: .stopped, stopId: stop.stopID, accepted: nil, historyId: nil))
        try await restarted.requireTerminalBoundSessions(authority: authority)
    }

    func testBoundMappingCannotBeAttachedToLegacySession() async throws {
        let (store, authority, url, _) = try await fixture(installation: "installation")
        _ = try await store.register(sessionID: "legacy", authority: authority)
        let original = try Data(contentsOf: url)
        let binding = APIv2ProgressTimeline(timelineId: String(repeating: "a", count: 64),
            mediaItemId: "book", fileId: "42", partOffsetSeconds: 0, partDurationSeconds: 30, durationSeconds: 30)
        do {
            _ = try await store.register(sessionID: "legacy", authority: authority, progressTimeline: binding)
            XCTFail("Existing authority cannot acquire an inferred timeline")
        } catch {}
        XCTAssertEqual(original, try Data(contentsOf: url))
    }

    func testBackwardSampleAndUncertainRetryPreserveExactSequenceAndBody() async throws {
        let (store, authority, _, _) = try await fixture()
        let session = try await store.register(sessionID: "session", authority: authority)
        let first = try await store.prepareProgress(session.id, authority: authority, position: 120, isPaused: false)
        let retry = try await store.prepareProgress(session.id, authority: authority, position: 30, isPaused: true)
        XCTAssertEqual(first, retry)
        let receipt = try JSONDecoder().decode(PlaybackSequencedProgressReceipt.self,
            from: Data(#"{"outcome":"replayed","accepted":{"sequence":1,"position":120,"is_paused":false}}"#.utf8))
        try await store.acknowledgeProgress(session.id, authority: authority, sent: first, receipt: receipt)
        let backward = try await store.prepareProgress(session.id, authority: authority, position: 30, isPaused: true)
        XCTAssertEqual(backward.sequence, 2)
        XCTAssertEqual(backward.position, 30)
    }

    func testStopSurvivesRestartAndLateDrainingCannotReopenTerminal() async throws {
        let (store, authority, url, _) = try await fixture(installation: "verified-installation")
        let session = try await store.register(sessionID: "session", authority: authority)
        let stopProposal = try await store.proposedStop(session.id, authority: authority, position: 3, isPaused: true)
        let stop = try await store.persistStop(session.id, authority: authority, stop: stopProposal)
        let restarted = PlaybackMutationStore(url: url)
        let retriedProposal = try await restarted.proposedStop(session.id, authority: authority, position: 99, isPaused: false)
        let retried = try await restarted.persistStop(session.id, authority: authority, stop: retriedProposal)
        XCTAssertEqual(stop, retried)
        let pending = try await restarted.pendingStops(authority: authority, afterRestart: true)
        XCTAssertEqual(pending.first?.stop, stop)
        func receipt(_ outcome: String) throws -> PlaybackSequencedStopReceipt {
            try JSONDecoder().decode(PlaybackSequencedStopReceipt.self,
                from: Data("{\"outcome\":\"\(outcome)\",\"stop_id\":\"\(stop.stopID.uuidString.lowercased())\"}".utf8))
        }
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop, receipt: receipt("draining"))
        let draining = try await restarted.session(session.id, authority: authority)
        XCTAssertEqual(draining.stopState, .draining)
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop, receipt: receipt("stopped"))
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop, receipt: receipt("draining"))
        let terminal = try await restarted.session(session.id, authority: authority)
        XCTAssertEqual(terminal.stopState, .terminal)
    }

    func testUnknownInstallationAndReloginNeverPromotePendingIntent() async throws {
        let (store, authority, _, tokens) = try await fixture()
        let session = try await store.register(sessionID: "session", authority: authority)
        let pendingProposal = try await store.proposedStop(session.id, authority: authority, position: nil, isPaused: true)
        _ = try await store.persistStop(session.id, authority: authority, stop: pendingProposal)
        let restarted = try await store.pendingStops(authority: authority, afterRestart: true)
        XCTAssertTrue(restarted.isEmpty)
        try await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let relogin = try PlaybackMutationAuthority(auth: XCTUnwrap(captured), installationID: nil)
        do { _ = try await store.session(session.id, authority: relogin); XCTFail() } catch {}
    }

    func testStopOmissionAndStrictAcceptedSampleWire() throws {
        let stop = PlaybackSequencedStop(stopID: UUID(), sample: nil)
        let data = try JSONEncoder().encode(stop)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["stop_id"])
        XCTAssertEqual(body["stop_id"] as? String, stop.stopID.uuidString.lowercased())
        for wire in [#"{"sequence":0,"position":0,"is_paused":false}"#,
                     #"{"sequence":1,"position":-1,"is_paused":false}"#,
                     #"{"sequence":1,"position":0}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(PlaybackSequencedSample.self, from: Data(wire.utf8)))
        }
    }

    func testWriteFailureDoesNotAllocateOrConsumeIntent() async throws {
        let (store, authority, url, _) = try await fixture()
        let session = try await store.register(sessionID: "session", authority: authority)
        let failed = PlaybackMutationStore(url: url) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        do { _ = try await failed.prepareProgress(session.id, authority: authority, position: 1, isPaused: false); XCTFail() } catch {}
        let proposed = try await failed.proposedStop(session.id, authority: authority, position: 2, isPaused: true)
        do { _ = try await failed.persistStop(session.id, authority: authority, stop: proposed); XCTFail() } catch {}
        let unchanged = try await store.session(session.id, authority: authority)
        XCTAssertEqual(unchanged.allocatedSequence, 0)
        XCTAssertNil(unchanged.pendingProgress)
        XCTAssertNil(unchanged.stop)
    }
}
