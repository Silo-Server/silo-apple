import Foundation
import XCTest
@testable import Silo

/// A small v2 onboarding server on the shared `StubURLProtocol.Handler`: one
/// profile's tour state with a revision, the `ETag` rule (`"r<revision>"`),
/// If-Match checks (428 missing, 412 stale), and switches for a failed
/// state read, a write that never arrives, and a write whose reply is lost
/// after the server applied it. Applied writes are recorded in `events`.
final class OnboardingServerStub: @unchecked Sendable {
    let handler = StubURLProtocol.Handler()
    private let lock = NSLock()
    private var revision = 1
    private var lastStep: String?
    private var done = false
    private var flowSteps = "[]"
    private var stateFailure: StubURLProtocol.Response?
    private var writeFailure: URLError.Code?
    private var dropNextReply = false
    private var weakTag = false
    private var recorded: [String] = []

    let tourId = "tour"

    init() {
        handler.route(StubURLProtocol.method("GET", path: "/api/v2/onboarding/state")) { [self] _ in
            try lock.withLock {
                if let stateFailure { return stateFailure }
                return try stateResponse()
            }
        }
        handler.route(StubURLProtocol.method("GET", path: "/api/v2/onboarding/flow")) { [self] _ in
            lock.withLock {
                .json(#"{"version":1,"tour_id":"\#(tourId)","steps":\#(flowSteps)}"#)
            }
        }
        handler.route(StubURLProtocol.method("PUT", path: "/api/v2/onboarding/progress")) { [self] request in
            try lock.withLock { try write(request) }
        }
    }

    // MARK: Scenario

    func setFlow(steps json: String) { lock.withLock { flowSteps = json } }
    func setState(lastStep: String?, done: Bool) {
        lock.withLock {
            self.lastStep = lastStep
            self.done = done
        }
    }
    /// Another device finishes the tour: the stored tag moves on.
    func finishElsewhere() {
        lock.withLock {
            done = true
            revision += 1
        }
    }
    func failStateReads(with response: StubURLProtocol.Response?) { lock.withLock { stateFailure = response } }
    func failNextWrite(_ code: URLError.Code = .notConnectedToInternet) { lock.withLock { writeFailure = code } }
    func dropNextWriteReply() { lock.withLock { dropNextReply = true } }
    func sendWeakTags() { lock.withLock { weakTag = true } }

    // MARK: Observation

    var events: [String] { lock.withLock { recorded } }
    var requests: [StubURLProtocol.Request] { handler.requests }
    var requestLines: [String] { handler.requests.map { "\($0.method) \($0.path)" } }
    func makeSession() -> URLSession { handler.makeSession() }

    /// Records a non-network event in the same order as applied writes.
    func record(_ event: String) { lock.withLock { recorded.append(event) } }

    // MARK: Wire

    private var tag: String { weakTag ? #"W/"r\#(revision)""# : #""r\#(revision)""# }

    private func stateResponse() throws -> StubURLProtocol.Response {
        var body: [String: Any] = ["tour_id": tourId, "done": done]
        if let lastStep { body["last_step"] = lastStep }
        let data = try JSONSerialization.data(withJSONObject: body)
        return StubURLProtocol.Response(
            status: 200,
            headers: ["Content-Type": "application/json", "ETag": tag],
            body: data
        )
    }

    private func write(_ request: StubURLProtocol.Request) throws -> StubURLProtocol.Response {
        if let code = writeFailure {
            writeFailure = nil
            throw URLError(code)
        }
        guard let ifMatch = request.header("if-match") else {
            return Self.problem(428, "precondition_required")
        }
        guard ifMatch == tag else {
            return Self.problem(412, "precondition_failed", headers: ["ETag": tag])
        }
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
        )
        let completed = body["completed"] as? Bool ?? false
        let skipped = body["skipped"] as? Bool ?? false
        let step = body["last_step"] as? String
        revision += 1
        lastStep = step
        done = done || completed || skipped
        let disposition = skipped ? "skipped" : completed ? "completed" : "progress"
        recorded.append("progress:\(step ?? "none"):\(disposition)")
        if dropNextReply {
            dropNextReply = false
            throw URLError(.networkConnectionLost)
        }
        return try stateResponse()
    }

    static func problem(_ status: Int, _ type: String, headers: [String: String] = [:]) -> StubURLProtocol.Response {
        let body = #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"\#(type)","status":\#(status),"detail":"\#(type)","instance":"urn:test"}"#
        var merged = ["Content-Type": "application/problem+json"]
        merged.merge(headers) { _, new in new }
        return StubURLProtocol.Response(status: status, headers: merged, body: Data(body.utf8))
    }

    /// A token store signed in to this stub's server with `profileId` selected.
    static func tokenStore(profileId: String = "profile-1", testCase: XCTestCase) async throws -> TokenStore {
        let name = "OnboardingServerStub.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        testCase.addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "onboarding-server")
        await tokens.setServerUrl("https://onboarding.example")
        await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        await tokens.setProfileId(profileId)
        return tokens
    }
}
