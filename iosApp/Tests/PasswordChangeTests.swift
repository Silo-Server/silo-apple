import Foundation
import XCTest
@testable import Silo

/// #872: an account holding a temporary password signed in, then got a
/// generic "Not allowed" with no way forward. The app now replaces the
/// password (`POST /api/v2/account/password`), refreshes the session so the
/// server lifts its restriction, and only then continues to profiles.
@MainActor
final class PasswordChangeTests: XCTestCase {
    private static let serverURL = "https://password.example"
    nonisolated private static let rotatedTokens =
        #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
    private let stub = StubURLProtocol.Handler()

    private func makeModel() async throws -> (PasswordChangeModel, TokenStore) {
        let name = "PasswordChangeTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl(Self.serverURL)
        try await tokens.installAccountSession(accessToken: "temporary-access", refreshToken: "refresh", accountID: "1")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: SharedDefaults(suite: suite, standard: suite)),
            apiV2Client: api, httpClient: http, tokenStore: tokens)
        return (PasswordChangeModel(auth: auth), tokens)
    }

    private func routerOnPasswordChange() -> AppRouter {
        let router = AppRouter()
        router.showPasswordChange()
        return router
    }

    private func fill(_ model: PasswordChangeModel, new: String = "a-new-password", confirmation: String? = nil) {
        model.currentPassword = "temporary"
        model.newPassword = new
        model.confirmation = confirmation ?? new
    }

    nonisolated private static func problem(_ identifier: String, status: Int, location: String? = nil,
                                            detail: String = "") -> StubURLProtocol.Response {
        let errors = location.map { #","errors":[{"location":"\#($0)","code":"invalid","detail":"\#(detail)"}]"# } ?? ""
        return .json(#"{"type":"https://siloserver.org/docs/api/v2/problems/\#(identifier)","title":"t","status":\#(status),"detail":"d"\#(errors)}"#,
            status: status, headers: ["Content-Type": "application/problem+json"])
    }

    // MARK: Saving

    func testSavingChangesThePasswordThenRefreshesBeforeShowingProfiles() async throws {
        stub.route(StubURLProtocol.method("POST", path: APIv2Client.accountPasswordPath)) { _ in .status(204) }
        stub.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in .json(Self.rotatedTokens) }
        let (model, tokens) = try await makeModel()
        await tokens.setProfileId("stale-profile")
        let router = routerOnPasswordChange()
        fill(model)

        let saved = await model.save(router: router)

        XCTAssertTrue(saved)
        XCTAssertEqual(stub.requests.map(\.path), [APIv2Client.accountPasswordPath, HTTPClient.refreshPath])
        let change = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(change.header("Authorization"), "Bearer temporary-access")
        XCTAssertNil(change.header("X-Profile-Id"), "the change is account-scoped; a declared profile would be refused")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(change.body)) as? [String: String])
        XCTAssertEqual(body, ["current_password": "temporary", "new_password": "a-new-password"])
        let access = await tokens.getAccessToken()
        XCTAssertEqual(access, "new-access", "the restricted token must be replaced")
        XCTAssertEqual(router.authState, .needsProfile)
        XCTAssertEqual([model.currentPassword, model.newPassword, model.confirmation], ["", "", ""])
    }

    /// The new password is saved even when the refresh fails, so the form
    /// stays closed (the temporary password no longer works) and "Try again"
    /// only refreshes.
    func testFailedRefreshOffersARetryThatDoesNotResendThePassword() async throws {
        let refreshes = Attempts()
        stub.route(StubURLProtocol.method("POST", path: APIv2Client.accountPasswordPath)) { _ in .status(204) }
        stub.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in
            refreshes.next() == 1 ? .status(500) : .json(Self.rotatedTokens)
        }
        let (model, _) = try await makeModel()
        let router = routerOnPasswordChange()
        fill(model)

        let saved = await model.save(router: router)

        XCTAssertTrue(saved)
        XCTAssertEqual(model.phase, .refreshFailed(retrying: false))
        XCTAssertEqual(router.authState, .needsPasswordChange)

        await model.retryRefresh(router: router)

        XCTAssertEqual(stub.requests.map(\.path),
            [APIv2Client.accountPasswordPath, HTTPClient.refreshPath, HTTPClient.refreshPath])
        XCTAssertEqual(router.authState, .needsProfile)
    }

    /// The password changed but the refresh never finished, and the app
    /// relaunched. The old token is still restricted, so the picker hands
    /// over again, yet the temporary password no longer works. The account
    /// says the change is done, so the screen only refreshes the session.
    func testAlreadyChangedPasswordOnlyRefreshesTheSession() async throws {
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/account/me")) { _ in
            .json(#"{"id":"1","username":"member","role":"user","download_allowed":true,"password_change_required":false}"#)
        }
        stub.route(StubURLProtocol.method("GET", path: APIv2Client.accountPasswordCapabilityPath)) { _ in
            .json(#"{"state":"available","allowed":true,"minimum_password_length":10,"maximum_password_bytes":72}"#)
        }
        stub.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in .json(Self.rotatedTokens) }
        let (model, _) = try await makeModel()
        let router = routerOnPasswordChange()

        await model.load(router: router)

        XCTAssertFalse(stub.requests.contains { $0.path == APIv2Client.accountPasswordPath })
        XCTAssertTrue(stub.requests.contains { $0.path == HTTPClient.refreshPath })
        XCTAssertEqual(router.authState, .needsProfile)
    }

    func testLoadKeepsTheFormWhileThePasswordIsTemporary() async throws {
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/account/me")) { _ in
            .json(#"{"id":"1","username":"member","role":"user","download_allowed":true,"password_change_required":true}"#)
        }
        stub.route(StubURLProtocol.method("GET", path: APIv2Client.accountPasswordCapabilityPath)) { _ in
            .json(#"{"state":"available","allowed":true,"minimum_password_length":10,"maximum_password_bytes":72}"#)
        }
        let (model, _) = try await makeModel()
        let router = routerOnPasswordChange()

        await model.load(router: router)

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.accountName, "member")
        XCTAssertEqual(model.requirements, PasswordRequirements(minimumLength: 10, maximumBytes: 72))
        XCTAssertEqual(router.authState, .needsPasswordChange)
        XCTAssertFalse(stub.requests.contains { $0.path == HTTPClient.refreshPath })
    }

    func testWrongTemporaryPasswordStaysOnTheFormWithoutRefreshing() async throws {
        stub.route(StubURLProtocol.method("POST", path: APIv2Client.accountPasswordPath)) { _ in
            Self.problem("validation_failed", status: 422, location: "body.current_password",
                detail: "The current password is incorrect.")
        }
        let (model, _) = try await makeModel()
        let router = routerOnPasswordChange()
        fill(model)

        let saved = await model.save(router: router)

        XCTAssertFalse(saved)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.error?.message, "That temporary password is incorrect.")
        XCTAssertEqual(stub.requests.map(\.path), [APIv2Client.accountPasswordPath])
        XCTAssertEqual(router.authState, .needsPasswordChange)
    }

    func testFormChecksTheNewPasswordBeforeSendingIt() async throws {
        let (model, _) = try await makeModel()
        let router = routerOnPasswordChange()
        let cases: [(String, (PasswordChangeModel) -> Void, String)] = [
            ("no temporary password", { $0.newPassword = "a-new-password"; $0.confirmation = "a-new-password" },
             "Enter the temporary password."),
            ("mismatch", { self.fill($0, confirmation: "something-else") }, "The new passwords don't match."),
            ("too short", { self.fill($0, new: "short") }, "Use at least 8 characters."),
            ("too many bytes", { self.fill($0, new: String(repeating: "é", count: 40)) },
             "That password is too long. Use a shorter one."),
        ]
        for (label, stage, expected) in cases {
            model.currentPassword = ""
            stage(model)
            let saved = await model.save(router: router)
            XCTAssertFalse(saved, label)
            XCTAssertEqual(model.error?.message, expected, label)
        }
        XCTAssertTrue(stub.requests.isEmpty, "nothing reaches the server's password-change budget")
    }

    // MARK: Copy and detection

    func testRejectedNewPasswordShowsTheServersReason() {
        let error = APIv2Error.problem(APIv2Problem(
            type: "https://siloserver.org/docs/api/v2/problems/validation_failed", title: "Validation failed",
            status: 422, detail: "The request did not pass validation; see errors.", instance: nil,
            errors: [APIv2ProblemError(location: "body.new_password", code: "invalid",
                detail: "The new password must differ from the current one.")]))
        XCTAssertEqual(PasswordChangeModel.message(for: error), "The new password must differ from the current one.")
    }

    func testOnlyATemporaryPasswordRefusalAsksForTheChange() {
        func problem(_ identifier: String, _ status: Int) -> APIv2Error {
            .problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(identifier)",
                title: identifier, status: status, detail: "", instance: nil, errors: nil))
        }
        XCTAssertTrue(PasswordChangeModel.isRequired(by: problem("password_change_required", 403)))
        XCTAssertFalse(PasswordChangeModel.isRequired(by: problem("permission_denied", 403)))
        XCTAssertFalse(PasswordChangeModel.isRequired(by: problem("profile_verification_required", 403)))
        XCTAssertFalse(PasswordChangeModel.isRequired(by: APIv2Error.httpStatus(403)))
    }

    func testRequirementsComeFromTheCapabilityWithServerDefaultsAsFallback() {
        let stated = APIv2PasswordCapability(state: "available", allowed: true,
            minimumPasswordLength: 12, maximumPasswordBytes: 64)
        XCTAssertEqual(PasswordRequirements(stated), PasswordRequirements(minimumLength: 12, maximumBytes: 64))
        let unstated = APIv2PasswordCapability(state: "not_configured", allowed: nil,
            minimumPasswordLength: 0, maximumPasswordBytes: nil)
        XCTAssertEqual(PasswordRequirements(unstated), .serverDefault)
    }
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
