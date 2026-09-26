import XCTest
@testable import Silo

/// `MediaCardPersonalState` is the one optimistic favorite / watchlist /
/// watched model behind `MediaCard`, `TVMediaCard`, `EpisodeThumbCard` and
/// Home's card menu (F126). A requested value shows at once, stays after the
/// server applies it until the card's own state changes, and rolls back to
/// what the card showed at the tap on any other outcome.
final class MediaCardPersonalStateTests: XCTestCase {
    /// Stands in for the server writes: records every call, returns a
    /// scripted outcome, and can hold a write open until the test releases it.
    @MainActor
    private final class WriteScript {
        struct Call: Equatable {
            let target: PersonalStateTarget
            let contentId: String
            let value: Bool
            /// The sibling list flag sent with a favorite or watchlist write,
            /// or the series ID sent with a watched write.
            let context: String?
        }

        var calls: [Call] = []
        var outcome: PersonalStateOutcome = .applied
        var holdsWrites = false
        private var pending: [CheckedContinuation<Void, Never>] = []

        var writes: MediaCardPersonalState.Writes {
            MediaCardPersonalState.Writes(
                watched: { contentId, played, seriesId in
                    await self.record(Call(target: .watched, contentId: contentId, value: played, context: seriesId))
                },
                favorite: { contentId, isFavorite, inWatchlist in
                    await self.record(Call(target: .favorite, contentId: contentId, value: isFavorite,
                                           context: "inWatchlist=\(inWatchlist)"))
                },
                watchlist: { contentId, isFavorite, inWatchlist in
                    await self.record(Call(target: .watchlist, contentId: contentId, value: inWatchlist,
                                           context: "isFavorite=\(isFavorite)"))
                }
            )
        }

        func release() {
            let waiting = pending
            pending.removeAll()
            waiting.forEach { $0.resume() }
        }

        private func record(_ call: Call) async -> PersonalStateOutcome {
            calls.append(call)
            if holdsWrites {
                await withCheckedContinuation { pending.append($0) }
            }
            return outcome
        }
    }

    private let unwatched = MediaItemUserState(played: false, isFavorite: false, inWatchlist: false)

    private let heldChange = PersonalStateHeldChange(
        id: UUID(),
        owner: CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(serverId: "server", serverURL: "https://personal.example",
                                            credentialGenerationID: UUID()),
            credentialOwner: .persistentServer(serverId: "server"),
            accessToken: "access", profileId: "profile-one", profileToken: nil
        ),
        target: .watchlist, contentId: "movie:1", included: true
    )

    @MainActor
    private func waitUntilIdle(_ state: MediaCardPersonalState, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date.now.addingTimeInterval(5)
        while state.feedback.isUpdating, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(state.feedback.isUpdating, "the change never finished", file: file, line: line)
    }

    @MainActor
    private func waitForCalls(_ count: Int, in script: WriteScript, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date.now.addingTimeInterval(5)
        while script.calls.count < count, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(script.calls.count, count, "the write never started", file: file, line: line)
    }

    @MainActor
    func testAppliedChangeStaysUntilTheCardStateChanges() async {
        let script = WriteScript()
        let state = MediaCardPersonalState(writes: script.writes)

        state.toggleFavorite(contentId: "movie:1", from: unwatched)
        await waitUntilIdle(state)

        // The parent list still says "not a favorite"; the card keeps the
        // applied value rather than flashing back until that list reloads.
        XCTAssertTrue(state.isFavorite(unwatched))
        XCTAssertNil(state.feedback.notice)

        state.reset()
        XCTAssertFalse(state.isFavorite(unwatched))
        XCTAssertTrue(state.isFavorite(MediaItemUserState(isFavorite: true)))
    }

    @MainActor
    func testRequestedValueShowsWhileTheWriteRuns() async {
        let script = WriteScript()
        script.holdsWrites = true
        let state = MediaCardPersonalState(writes: script.writes)

        state.toggleWatched(from: unwatched, via: .catalog(contentId: "movie:1"))
        await waitForCalls(1, in: script)

        XCTAssertTrue(state.isPlayed(unwatched))
        XCTAssertTrue(state.feedback.isUpdating)

        script.release()
        await waitUntilIdle(state)
        XCTAssertTrue(state.isPlayed(unwatched))
    }

    @MainActor
    func testUnappliedOutcomesRestoreTheOverrideFromTheTap() async {
        for outcome in [PersonalStateOutcome.failed(nil), .skipped, .held(heldChange)] {
            let script = WriteScript()
            let state = MediaCardPersonalState(writes: script.writes)
            state.toggleWatchlist(contentId: "movie:1", from: unwatched)
            await waitUntilIdle(state)
            XCTAssertTrue(state.inWatchlist(unwatched))

            script.outcome = outcome
            state.toggleWatchlist(contentId: "movie:1", from: unwatched)
            await waitUntilIdle(state)

            // Back to the applied add from the first tap, not to the stale
            // base the parent list still holds.
            XCTAssertTrue(state.inWatchlist(unwatched), "\(outcome)")
            XCTAssertEqual(script.calls.map(\.value), [true, false], "\(outcome)")
        }
    }

    @MainActor
    func testFailureNoticeFollowsTheWriteOwner() async {
        let script = WriteScript()
        script.outcome = .failed(nil)
        let catalog = MediaCardPersonalState(writes: script.writes)
        catalog.toggleWatched(from: unwatched, via: .catalog(contentId: "movie:1"))
        await waitUntilIdle(catalog)
        XCTAssertFalse(catalog.isPlayed(unwatched))
        XCTAssertEqual(catalog.feedback.notice, .failed(nil))

        // Home's handler shows its own alert, so the card stays quiet.
        let hosted = MediaCardPersonalState(writes: script.writes)
        var hostCalls: [Bool] = []
        hosted.toggleWatched(from: unwatched, via: .host { played in
            hostCalls.append(played)
            return false
        })
        await waitUntilIdle(hosted)
        XCTAssertEqual(hostCalls, [true])
        XCTAssertFalse(hosted.isPlayed(unwatched))
        XCTAssertNil(hosted.feedback.notice)
        XCTAssertEqual(script.calls.count, 1, "a host write must not also send the catalog write")

        script.outcome = .skipped
        let skipped = MediaCardPersonalState(writes: script.writes)
        skipped.toggleFavorite(contentId: "movie:1", from: unwatched)
        await waitUntilIdle(skipped)
        XCTAssertNil(skipped.feedback.notice)

        script.outcome = .held(heldChange)
        let unconfirmed = MediaCardPersonalState(writes: script.writes)
        unconfirmed.toggleWatchlist(contentId: "movie:1", from: unwatched)
        await waitUntilIdle(unconfirmed)
        XCTAssertFalse(unconfirmed.inWatchlist(unwatched))
        XCTAssertEqual(unconfirmed.feedback.notice, .held(heldChange))
    }

    @MainActor
    func testWritesCarryTheSiblingFlagAndSeries() async {
        let script = WriteScript()
        let state = MediaCardPersonalState(writes: script.writes)
        let base = MediaItemUserState(played: true, isFavorite: false, inWatchlist: true)
        var reported: [MediaItemUserState] = []

        state.toggleFavorite(contentId: "episode:1", from: base) { reported.append($0) }
        await waitUntilIdle(state)
        // The watchlist write sends the favorite just applied, not the base.
        state.toggleWatchlist(contentId: "episode:1", from: base) { reported.append($0) }
        await waitUntilIdle(state)
        state.toggleWatched(from: base, via: .catalog(contentId: "episode:1", seriesId: "series:1")) {
            reported.append($0)
        }
        await waitUntilIdle(state)

        XCTAssertEqual(script.calls, [
            .init(target: .favorite, contentId: "episode:1", value: true, context: "inWatchlist=true"),
            .init(target: .watchlist, contentId: "episode:1", value: false, context: "isFavorite=true"),
            .init(target: .watched, contentId: "episode:1", value: false, context: "series:1"),
        ])
        XCTAssertEqual(reported, [
            MediaItemUserState(played: true, isFavorite: true, inWatchlist: true),
            MediaItemUserState(played: true, isFavorite: true, inWatchlist: false),
            MediaItemUserState(played: false, isFavorite: true, inWatchlist: false),
        ])
    }

    @MainActor
    func testOneChangeAtATime() async {
        let script = WriteScript()
        script.holdsWrites = true
        let state = MediaCardPersonalState(writes: script.writes)

        state.toggleFavorite(contentId: "movie:1", from: unwatched)
        await waitForCalls(1, in: script)
        state.toggleWatchlist(contentId: "movie:1", from: unwatched)
        state.toggleWatched(from: unwatched, via: .catalog(contentId: "movie:1"))

        script.release()
        await waitUntilIdle(state)
        XCTAssertEqual(script.calls.map(\.target), [.favorite])
        XCTAssertFalse(state.inWatchlist(unwatched))
        XCTAssertFalse(state.isPlayed(unwatched))
    }
}
