import Foundation
import XCTest
@testable import Silo

/// A 403 `profile_verification_required` from any request sends the user back
/// to profile selection, not only the Home prefetch. `HTTPClient` posts
/// `.siloProfileVerificationRequired` once per rejected proof, and only when
/// the request carried the active profile and its current proof.
final class ProfileVerificationSignalTests: XCTestCase {
    private static let resourcePath = "/api/v2/home/sections"
    private static let verificationProblem = """
    {"type":"https://siloserver.org/docs/api/v2/problems/profile_verification_required",
     "title":"Profile verification required","status":403,"detail":"Verify the profile."}
    """
    private static let permissionProblem = """
    {"type":"https://siloserver.org/docs/api/v2/problems/permission_denied",
     "title":"Permission denied","status":403,"detail":"Not allowed."}
    """

    private struct Harness {
        let serverId: String
        let serverURL: String
        let defaults: SharedDefaults
        let tokens: TokenStore
        let http: HTTPClient
        let stub: StubURLProtocol.Handler

        var identity: HTTPRequestIdentity {
            HTTPRequestIdentity(serverId: serverId, serverURL: serverURL,
                profileId: "profile", clientFamily: "mobile")
        }
    }

    private func harness(
        reply: StubURLProtocol.Response? = nil,
        responseReceivedBarrier: (@Sendable () async -> Void)? = nil
    ) async throws -> Harness {
        let name = "ProfileVerificationSignalTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: defaults)
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        let serverId = "server-\(UUID().uuidString)"
        let serverURL = "https://profile-verification.example"
        await tokens.switchActiveServer(serverId: serverId)
        await tokens.setServerUrl(serverURL)
        await tokens.setProfileId("profile")
        let savedProof = await tokens.setProfileToken("proof")
        XCTAssertTrue(savedProof)
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)

        let stub = StubURLProtocol.Handler()
        let response = reply ?? .json(Self.verificationProblem, status: 403,
            headers: ["Content-Type": "application/problem+json"])
        stub.route(StubURLProtocol.path(Self.resourcePath)) { _ in response }
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens,
            responseReceivedBarrier: responseReceivedBarrier)
        return Harness(serverId: serverId, serverURL: serverURL, defaults: defaults,
            tokens: tokens, http: http, stub: stub)
    }

    /// Counts signals for one harness's server, so traffic from other tests
    /// in the process cannot be miscounted.
    private func observeSignals(for serverId: String) -> (SignalLog, NSObjectProtocol) {
        let log = SignalLog()
        let token = NotificationCenter.default.addObserver(
            forName: .siloProfileVerificationRequired, object: nil, queue: nil
        ) { notification in
            guard let event = notification.object as? ProfileVerificationRequiredEvent,
                  event.account.serverId == serverId else { return }
            log.append(event)
        }
        return (log, token)
    }

    private func expectForbidden(
        _ body: () async throws -> HTTPRawResponse,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected the 403 to surface \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 403, message, file: file, line: line)
        }
    }

    func testBurstOfRejectedRequestsSignalsOnceForTheActiveProfile() async throws {
        let h = try await harness()
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    // The caller still sees the 403; recovery is a side effect.
                    _ = try? await h.http.requestData(method: "GET", path: Self.resourcePath)
                }
            }
        }
        await expectForbidden({ try await h.http.requestData(
            method: "GET", path: Self.resourcePath, requestIdentity: h.identity) }, "scoped")

        XCTAssertEqual(h.stub.requests.count, 7)
        XCTAssertEqual(signals.events.map(\.profileID), ["profile"])
        let account = await h.tokens.refreshAccountIdentity()
        XCTAssertEqual(signals.events.first?.account, account)
        // The signal is a request, not the recovery: credentials are untouched.
        let profileID = await h.tokens.getProfileId()
        let proof = await h.tokens.getProfileToken()
        XCTAssertEqual(profileID, "profile")
        XCTAssertEqual(proof, "proof")
    }

    func testScopedRequestSignals() async throws {
        let h = try await harness()
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }

        await expectForbidden { try await h.http.requestData(
            method: "GET", path: Self.resourcePath, requestIdentity: h.identity) }

        XCTAssertEqual(signals.events.map(\.profileID), ["profile"])
    }

    /// After the user verifies again the new proof is a different identity, so
    /// a later rejection of it is not swallowed by the earlier signal.
    func testNewProofSignalsAgain() async throws {
        let h = try await harness()
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }

        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }
        let saved = await h.tokens.setProfileToken("proof-2")
        XCTAssertTrue(saved)
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }

        XCTAssertEqual(signals.events.count, 2)
    }

    /// Recovery sends the user to Who's Watching. Picking the same profile
    /// again from a stale list that says it has no PIN installs the same
    /// (absent) proof; its rejection must still post, or the user is left on
    /// failing screens.
    func testReselectingTheSameProofSignalsAgain() async throws {
        let h = try await harness()
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }
        let current = await h.tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(current)

        let first = await h.tokens.activateProfile(profileID: "profile", profileToken: nil,
            expectedAccount: account)
        XCTAssertTrue(first)
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }
        XCTAssertEqual(signals.events.count, 1, "one selection posts once")

        let deactivated = await h.tokens.deactivateProfile(expectedAccount: account,
            expectedProfileID: "profile")
        XCTAssertTrue(deactivated)
        let again = await h.tokens.activateProfile(profileID: "profile", profileToken: nil,
            expectedAccount: account)
        XCTAssertTrue(again)
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }

        XCTAssertEqual(signals.events.count, 2)
    }

    /// A response that arrives after the user already re-verified (or picked
    /// another profile) belongs to the replaced proof and must not send the
    /// user back to profile selection.
    func testRejectionOfAReplacedProofDoesNotSignal() async throws {
        let reverify = ReverifyOnce()
        let h = try await harness(responseReceivedBarrier: { await reverify.run() })
        reverify.tokens = h.tokens
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }

        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }

        XCTAssertTrue(signals.events.isEmpty)
    }

    /// Recovery that runs while the rejected selection is still installed
    /// returns the user to profile selection.
    func testRecoveryClearsTheRejectedSelection() async throws {
        let h = try await harness()
        let event = try await rejectedEvent(h)

        await recoveryService(h).recoverFromProfileVerificationRequired(event)

        let profileID = await h.tokens.getProfileId()
        let proof = await h.tokens.getProfileToken()
        XCTAssertNil(profileID)
        XCTAssertNil(proof)
    }

    /// The event is delivered asynchronously and recovery can queue behind a
    /// profile activation. If the user selected the same profile again with a
    /// new proof meanwhile, recovery must leave that selection in place.
    func testRecoveryKeepsAReplacementSelectionOfTheSameProfile() async throws {
        let h = try await harness()
        let event = try await rejectedEvent(h)
        let reactivated = await h.tokens.activateProfile(profileID: "profile", profileToken: "proof-2",
            expectedAccount: event.account)
        XCTAssertTrue(reactivated)

        await recoveryService(h).recoverFromProfileVerificationRequired(event)

        let profileID = await h.tokens.getProfileId()
        let proof = await h.tokens.getProfileToken()
        XCTAssertEqual(profileID, "profile")
        XCTAssertEqual(proof, "proof-2")
    }

    private func rejectedEvent(_ h: Harness) async throws -> ProfileVerificationRequiredEvent {
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }
        return try XCTUnwrap(signals.events.first)
    }

    private func recoveryService(_ h: Harness) -> AuthService {
        AuthService(launchPreferences: ProfileLaunchPreferences(defaults: h.defaults),
            httpClient: h.http, tokenStore: h.tokens, defaults: h.defaults)
    }

    func testOtherRejectionsDoNotSignal() async throws {
        // A different 403 problem type is a permission answer, not a stale proof.
        let denied = try await harness(reply: .json(Self.permissionProblem, status: 403,
            headers: ["Content-Type": "application/problem+json"]))
        // A 403 whose body is not a problem document.
        let plain = try await harness(reply: .status(403))
        // The same problem type with another status is not this contract.
        let conflict = try await harness(reply: .json(Self.verificationProblem, status: 409,
            headers: ["Content-Type": "application/problem+json"]))
        var observers: [NSObjectProtocol] = []
        var logs: [SignalLog] = []
        for h in [denied, plain, conflict] {
            let (log, observer) = observeSignals(for: h.serverId)
            logs.append(log)
            observers.append(observer)
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        await expectForbidden { try await denied.http.requestData(method: "GET", path: Self.resourcePath) }
        await expectForbidden { try await plain.http.requestData(method: "GET", path: Self.resourcePath) }
        do {
            _ = try await conflict.http.requestData(method: "GET", path: Self.resourcePath)
            XCTFail("expected the 409 to surface")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 409)
        }

        XCTAssertTrue(logs.allSatisfy { $0.events.isEmpty })
    }

    /// Requests that did not act as the active profile with its stored proof
    /// carry no verdict about it.
    func testRequestsNotCarryingTheActiveProofDoNotSignal() async throws {
        let h = try await harness()
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }

        // Another profile addressed through per-request headers.
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath,
            headers: ["X-Profile-Id": "other", "X-Profile-Token": "other-proof"]) }
        // The active profile with a proof other than the stored one.
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath,
            headers: ["X-Profile-Token": "entered-pin-proof"]) }
        // An account-only request.
        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath,
            sendsProfile: false) }

        XCTAssertTrue(signals.events.isEmpty)
    }

    /// A temporary remote-playback handoff (tvOS) borrows another device's
    /// profile; its rejection must not deactivate this device's profile.
    func testTemporaryHandoffDoesNotSignal() async throws {
        let h = try await harness()
        let (signals, observer) = observeSignals(for: h.serverId)
        defer { NotificationCenter.default.removeObserver(observer) }
        await h.tokens.beginTemporaryScope(TemporaryAuthScope(
            serverId: h.serverId,
            serverURL: h.serverURL,
            accessToken: "temporary",
            refreshToken: "temporary-refresh",
            profileId: "profile",
            profileToken: "proof",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        ))

        await expectForbidden { try await h.http.requestData(method: "GET", path: Self.resourcePath) }

        XCTAssertTrue(signals.events.isEmpty)
    }

    func testProblemIdentifierReadsTheTypeSuffix() {
        XCTAssertEqual(HTTPClient.problemIdentifier(in: Data(Self.verificationProblem.utf8)),
            HTTPClient.profileVerificationRequiredProblem)
        XCTAssertNil(HTTPClient.problemIdentifier(in: Data(#"{"error":"profile_unverified"}"#.utf8)))
        XCTAssertNil(HTTPClient.problemIdentifier(in: Data("forbidden".utf8)))
    }
}

private final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProfileVerificationRequiredEvent] = []

    var events: [ProfileVerificationRequiredEvent] { lock.withLock { stored } }

    func append(_ event: ProfileVerificationRequiredEvent) { lock.withLock { stored.append(event) } }
}

/// Stores a new proof while the first response is in flight, as a PIN entry
/// completing at that moment would.
private final class ReverifyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var store: TokenStore?
    private var ran = false

    var tokens: TokenStore? {
        get { lock.withLock { store } }
        set { lock.withLock { store = newValue } }
    }

    func run() async {
        let tokens: TokenStore? = lock.withLock {
            defer { ran = true }
            return ran ? nil : store
        }
        _ = await tokens?.setProfileToken("proof-after-pin")
    }
}
