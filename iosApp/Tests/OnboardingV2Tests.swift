import Foundation
import XCTest
@testable import Silo

/// The onboarding tour on the v2 wire: the state read's strong `ETag` is the
/// only `If-Match` a progress write sends, the write is a single-dispatch
/// `PUT`, and a refused or unanswered write is never re-sent.
final class OnboardingV2Tests: XCTestCase {
    private var server = OnboardingServerStub()

    override func setUp() {
        super.setUp()
        server = OnboardingServerStub()
    }

    private func client(isUpdateRequired: Bool = false) async throws -> (APIv2Client, TokenStore) {
        let tokens = try await OnboardingServerStub.tokenStore(testCase: self)
        let http = HTTPClient(session: server.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { isUpdateRequired }), tokens)
    }

    private func progress(_ lastStep: String?, completed: Bool = false, skipped: Bool = false) -> OnboardingProgressRequest {
        OnboardingProgressRequest(tourId: server.tourId, lastStep: lastStep, completed: completed, skipped: skipped)
    }

    func testReadSendsStateThenFlowForTheSelectedProfile() async throws {
        server.setState(lastStep: "features", done: false)
        let (api, _) = try await client()

        let session = try await api.onboardingRead(surface: "phone")

        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state", "GET /api/v2/onboarding/flow"])
        XCTAssertEqual(server.requests.map { $0.header("x-profile-id") }, ["profile-1", "profile-1"])
        XCTAssertEqual(server.requests.last?.query, ["surface": "phone"])
        XCTAssertEqual(session.tag, #""r1""#)
        XCTAssertEqual(session.state.lastStep, "features")
        XCTAssertEqual(session.flow?.tourId, server.tourId)
        XCTAssertEqual(session.auth.profileId, "profile-1")
    }

    func testReadRefusesAWeakTag() async throws {
        server.sendWeakTags()
        let (api, _) = try await client()

        do {
            _ = try await api.onboardingRead()
            XCTFail("a weak tag cannot guard a write")
        } catch APIv2Error.missingEntityTag { }
    }

    func testWriteIsAPutWithTheReadTagAndReturnsTheReceiptTag() async throws {
        let (api, _) = try await client()
        let session = try await api.onboardingRead()

        let receipt = try await api.onboardingWrite(progress("features"), session: session)

        let put = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.path, "/api/v2/onboarding/progress")
        XCTAssertEqual(put.header("if-match"), #""r1""#)
        XCTAssertEqual(put.header("x-profile-id"), "profile-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(put.body)) as? [String: AnyHashable])
        XCTAssertEqual(body, ["tour_id": "tour", "last_step": "features", "completed": false, "skipped": false])
        XCTAssertEqual(receipt.tag, #""r2""#)
        XCTAssertEqual(receipt.state.lastStep, "features")

        _ = try await api.onboardingWrite(progress(nil, skipped: true), session: receipt)
        let skip = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(skip.header("if-match"), #""r2""#)
        let skipBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(skip.body)) as? [String: AnyHashable])
        XCTAssertNil(skipBody["last_step"], "an absent step is omitted, not sent as null")
    }

    func testStaleTagFailsOnceAndIsNotResent() async throws {
        let (api, _) = try await client()
        let session = try await api.onboardingRead()
        server.finishElsewhere()

        do {
            _ = try await api.onboardingWrite(progress("features"), session: session)
            XCTFail("a stale tag is a definite failure")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 412)
        }
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1)
        XCTAssertEqual(server.events, [])
    }

    func testUnansweredWriteIsNotResent() async throws {
        let (api, _) = try await client()
        let session = try await api.onboardingRead()
        server.dropNextWriteReply()

        do {
            _ = try await api.onboardingWrite(progress("features"), session: session)
            XCTFail("a lost reply is an uncertain outcome")
        } catch {}
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1, "non_retryable: one dispatch")
        XCTAssertEqual(server.events, ["progress:features:progress"])
    }

    func testFinishingReceiptThatIsNotDoneIsRefused() async throws {
        let (api, _) = try await client()
        let session = try await api.onboardingRead()
        // Answer the finishing write with a state that is still open, which
        // does not prove the tour was finished.
        server.handler.reset()
        server.handler.expect(StubURLProtocol.any) { _ in
            .json(#"{"tour_id":"tour","done":false}"#, headers: ["ETag": #""r2""#])
        }

        do {
            _ = try await api.onboardingWrite(progress(nil, completed: true), session: session)
            XCTFail("an unfinished receipt for a finishing write is refused")
        } catch let error as OnboardingProgressError {
            XCTAssertEqual(error, .unexpectedReceipt)
        }
    }

    func testWriteUnderAReplacedProfileSendsNothing() async throws {
        let (api, tokens) = try await client()
        let session = try await api.onboardingRead()
        await tokens.setProfileId("profile-2")

        do {
            _ = try await api.onboardingWrite(progress("features"), session: session)
            XCTFail("the read's owner is no longer active")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state"])
    }

    func testUpdateRequiredServerSendsNothing() async throws {
        let (api, _) = try await client(isUpdateRequired: true)

        do {
            _ = try await api.onboardingRead(surface: "phone")
            XCTFail("a v1-only server is refused before dispatch")
        } catch APIv2Error.serverUpdateRequired { }
        XCTAssertEqual(server.requests.count, 0)
    }
}
