import Foundation
import XCTest
@testable import Silo

/// `ServerSetupViewModel.connect` error handling. A v1-only candidate is not
/// the active server, so no verdict is recorded and no Home pill appears; the
/// setup screen itself has to say the server needs an update instead of
/// claiming it could not be reached.
@MainActor
final class ServerSetupViewModelTests: XCTestCase {
    private static let unreachable = "Could not reach a Silo server at that address."

    func testUpdateRequiredCandidateShowsUpdateMessage() async {
        let viewModel = ServerSetupViewModel(checkServer: { _ in
            throw APIv2Error.serverUpdateRequired
        })
        viewModel.host = "silo.example"
        viewModel.selectedScheme = .https
        let router = AppRouter()

        await viewModel.connect(router: router)

        XCTAssertEqual(viewModel.error, APIv2Error.serverUpdateRequiredMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotEqual(router.authState, .needsLogin, "a v1-only candidate is never committed")
    }

    func testUpdateRequiredWinsOverUnreachableCandidates() async throws {
        // Auto scheme tries https, http, and http:8090. Only the first answers
        // (as v1-only); the rest fail to connect. The verdict from the candidate
        // that answered must be what the user sees.
        let viewModel = ServerSetupViewModel(checkServer: { url in
            if url.hasPrefix("https://") {
                throw APIv2Error.serverUpdateRequired
            }
            throw URLError(.cannotConnectToHost)
        })
        viewModel.host = "silo.example"
        viewModel.selectedScheme = .auto
        XCTAssertGreaterThan(try viewModel.buildCandidateURLs().count, 1)

        await viewModel.connect(router: AppRouter())

        XCTAssertEqual(viewModel.error, APIv2Error.serverUpdateRequiredMessage)
    }

    func testUnreachableServerKeepsGenericMessage() async {
        let viewModel = ServerSetupViewModel(checkServer: { _ in
            throw URLError(.cannotConnectToHost)
        })
        viewModel.host = "silo.example"
        viewModel.selectedScheme = .https

        await viewModel.connect(router: AppRouter())

        XCTAssertEqual(viewModel.error, Self.unreachable)
    }
}
