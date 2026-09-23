import Foundation
import XCTest
@testable import Silo

/// The control socket connects with a single-use v2 ticket, so every connect
/// and reconnect mints its own under the session's owner and installation.
final class PlaybackRealtimeClientTests: XCTestCase {
    private actor Recorder {
        private(set) var mints: [(sessionId: String, installationID: String)] = []
        func record(_ sessionId: String, _ authority: PlaybackV2SessionAuthority) {
            mints.append((sessionId, authority.installationID))
        }
    }

    private static let sessionId = "4f6c1b8e-2d7a-4c3e-9b1f-0a5d6e7f8a9b"
    private static let authority = PlaybackV2SessionAuthority(
        owner: CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(serverId: "server", serverURL: "http://192.168.1.20:8096",
                                            credentialGenerationID: UUID()),
            credentialOwner: .persistentServer(serverId: "server"),
            accessToken: "access", profileId: "profile-one", profileToken: nil),
        installationID: "0c9e7a52-5b1d-4f0e-8a3c-2e6f9d4b7a10")

    private func makeClient(
        recorder: Recorder,
        ownerIsCurrent: Bool = true,
        failure: Error
    ) -> PlaybackRealtimeClient {
        PlaybackRealtimeClient(
            handshake: { sessionId, authority in
                await recorder.record(sessionId, authority)
                throw failure
            },
            ownerIsCurrent: { _ in ownerIsCurrent },
            reconnectDelaysNanos: [1_000_000],
            commandHandler: { _ in }
        )
    }

    private func waitUntilUnavailable(_ client: PlaybackRealtimeClient) async {
        let unavailable = expectation(description: "realtime control unavailable")
        unavailable.assertForOverFulfill = false
        await client.observeUnavailability { value in
            if value { unavailable.fulfill() }
        }
        await fulfillment(of: [unavailable], timeout: 5)
    }

    func testEveryReconnectMintsAFreshTicketUntilTheCircuitBreakerTrips() async {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, failure: URLError(.networkConnectionLost))
        await client.bind(sessionId: Self.sessionId, authority: Self.authority)
        await waitUntilUnavailable(client)

        let mints = await recorder.mints
        XCTAssertEqual(mints.count, 8, "one ticket per connect attempt, none reused")
        XCTAssertTrue(mints.allSatisfy { $0.sessionId == Self.sessionId
            && $0.installationID == Self.authority.installationID })
        await client.unbind()
    }

    func testAServerThatDoesNotServeControlStopsWithoutRetrying() async {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, failure: PlaybackSequencedError.controlUnavailable)
        await client.bind(sessionId: Self.sessionId, authority: Self.authority)
        await waitUntilUnavailable(client)

        let mints = await recorder.mints
        XCTAssertEqual(mints.count, 1)
        await client.unbind()
    }

    /// The HTTP client refuses requests while any identity transition holds
    /// its dispatch gate, even one that keeps this owner. That refusal must
    /// not end remote control for the session.
    func testARefusedDispatchUnderAnUnchangedOwnerRetriesWithANewTicket() async {
        let recorder = Recorder()
        let retried = expectation(description: "second ticket minted")
        let client = PlaybackRealtimeClient(
            handshake: { sessionId, authority in
                await recorder.record(sessionId, authority)
                if await recorder.mints.count == 1 { throw HTTPError.requestIdentityChanged }
                retried.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw CancellationError()
            },
            ownerIsCurrent: { _ in true },
            reconnectDelaysNanos: [1_000_000],
            commandHandler: { _ in }
        )
        await client.bind(sessionId: Self.sessionId, authority: Self.authority)
        await fulfillment(of: [retried], timeout: 5)

        let mints = await recorder.mints
        XCTAssertEqual(mints.count, 2)
        let unavailable = await client.isRealtimeUnavailable
        XCTAssertFalse(unavailable)
        await client.unbind()
    }

    func testNoTicketIsMintedOnceTheSessionOwnerIsNoLongerCurrent() async {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, ownerIsCurrent: false, failure: URLError(.badServerResponse))
        await client.bind(sessionId: Self.sessionId, authority: Self.authority)
        await waitUntilUnavailable(client)

        let mints = await recorder.mints
        XCTAssertTrue(mints.isEmpty)
        await client.unbind()
    }
}
