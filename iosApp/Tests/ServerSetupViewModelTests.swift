import XCTest
@testable import Silo

/// The port the setup screen suggests must reach the same Silo server that the
/// Auto fallback probe finds on a stock silo-server deployment.
final class ServerSetupViewModelTests: XCTestCase {
    private func makeViewModel(host: String) -> ServerSetupViewModel {
        let viewModel = ServerSetupViewModel(checkServer: { _ in throw URLError(.cannotConnectToHost) })
        viewModel.host = host
        return viewModel
    }

    func testAutoModeWithoutPortFallsBackToNativeServerPort() throws {
        let viewModel = makeViewModel(host: "silo.example")

        // Written as a literal: the stock compose file publishes the native API
        // on 8090, so the fallback must keep probing it whatever the constant says.
        XCTAssertEqual(
            try viewModel.buildCandidateURLs(),
            ["https://silo.example", "http://silo.example", "http://silo.example:8090"]
        )
    }

    func testTypingTheSuggestedPortReachesTheFallbackAddress() throws {
        let fallback = try makeViewModel(host: "silo.example").buildCandidateURLs().last
        let viewModel = makeViewModel(host: "silo.example")
        viewModel.port = ServerSetupViewModel.nativeServerPort

        let candidates = try viewModel.buildCandidateURLs()

        XCTAssertEqual(candidates, ["https://silo.example:8090", "http://silo.example:8090"])
        XCTAssertTrue(
            candidates.contains(try XCTUnwrap(fallback)),
            "typing the suggested port must reach the server the Auto fallback finds"
        )
    }
}
