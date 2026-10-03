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

    func testBrandingAssetsTreatTheDefaultPortAsSameOrigin() {
        XCTAssertNotNil(ServerBranding.resolve("https://silo.example.com:443/mark.png", base: "https://silo.example.com"))
        XCTAssertNotNil(ServerBranding.resolve("http://SILO.example.com/mark.png", base: "http://silo.example.com:80"))
        XCTAssertNil(ServerBranding.resolve("https://silo.example.com:8443/mark.png", base: "https://silo.example.com"))
        XCTAssertNil(ServerBranding.resolve("http://silo.example.com/mark.png", base: "https://silo.example.com"))
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

    /// A protocol and port chosen for a manual attempt must not redirect a
    /// saved server picked from Recent.
    func testRecentServerIgnoresEarlierProtocolAndPortOverrides() throws {
        let viewModel = ServerSetupViewModel(checkServer: { _ in APIv2SetupStatus(needsSetup: false) })
        viewModel.selectedScheme = .http
        viewModel.port = "8090"
        viewModel.useRecent("https://media.example.com")
        XCTAssertEqual(try viewModel.buildCandidateURLs().first, "https://media.example.com")
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
