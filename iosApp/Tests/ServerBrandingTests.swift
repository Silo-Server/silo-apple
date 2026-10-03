import XCTest
@testable import Silo

/// Server branding read before sign-in.
final class ServerBrandingTests: XCTestCase {
    func testBrandingAssetsResolveSameOriginOnly() {
        let base = "https://silo.example.com/prefix"
        XCTAssertEqual(ServerBranding.resolve("/api/v2/theme/mark.png", base: base)?.absoluteString,
                       "https://silo.example.com/prefix/api/v2/theme/mark.png")
        XCTAssertNil(ServerBranding.resolve("https://elsewhere.example.com/mark.png", base: base))
        XCTAssertNil(ServerBranding.resolve("  ", base: base))
    }
}

/// Where a successful connect leads.
@MainActor
final class ServerSetupRoutingTests: XCTestCase {
    func testSavedSignedInServerGoesToProfilesNotSignIn() async {
        let router = AppRouter()
        let viewModel = ServerSetupViewModel(
            checkServer: { _ in APIv2SetupStatus(needsSetup: false) },
            hasSession: { true }
        )
        viewModel.host = "https://silo.example.com"
        await viewModel.connect(router: router)
        XCTAssertEqual(router.authState, .needsProfile)
    }

    func testServerWithoutSessionOpensSignIn() async {
        let router = AppRouter()
        let viewModel = ServerSetupViewModel(
            checkServer: { _ in APIv2SetupStatus(needsSetup: false) },
            hasSession: { false }
        )
        viewModel.host = "https://silo.example.com"
        await viewModel.connect(router: router)
        XCTAssertEqual(router.authState, .needsLogin)
        XCTAssertTrue(router.path.isEmpty)
    }

    func testServerNeedingSetupOpensSetupEvenWithASession() async {
        let router = AppRouter()
        let viewModel = ServerSetupViewModel(
            checkServer: { _ in APIv2SetupStatus(needsSetup: true) },
            hasSession: { true }
        )
        viewModel.host = "https://silo.example.com"
        await viewModel.connect(router: router)
        XCTAssertEqual(router.authState, .needsLogin)
        XCTAssertEqual(router.path.count, 1)
    }

    /// SwiftUI clears the alert's binding before the Connect action's task
    /// runs; connecting must still use the prompt the alert showed.
    func testConnectingOverHTTPWorksAfterTheAlertIsDismissed() async throws {
        let router = AppRouter()
        let viewModel = ServerSetupViewModel(
            checkServer: { url in
                guard url.hasPrefix("http://") else { throw URLError(.cannotConnectToHost) }
                return APIv2SetupStatus(needsSetup: false)
            },
            hasSession: { false }
        )
        viewModel.host = "media.lan"
        await viewModel.connect(router: router)
        let prompt = try XCTUnwrap(viewModel.insecurePrompt)

        viewModel.dismissInsecurePrompt()
        await viewModel.confirmInsecure(prompt, router: router)

        XCTAssertEqual(router.authState, .needsLogin)
        XCTAssertNil(viewModel.error)
    }
}
