import XCTest
import SwiftUI
import Nuke
@testable import Silo

/// The retry schedule as a visible `AsyncImageView` runs it, against artwork
/// that keeps answering 503. `ArtworkRetryPolicyTests` covers the policy.
@MainActor
final class AsyncImageViewRetryTests: XCTestCase {
    private let stub = StubURLProtocol.Handler()
    private var previousPipeline: ImagePipeline?
    private var window: UIWindow?

    override func setUp() async throws {
        stub.route(StubURLProtocol.any) { _ in .status(503) }
        let configuration = URLSessionConfiguration.ephemeral
        stub.install(into: configuration)
        var pipelineConfiguration = ImagePipeline.Configuration()
        pipelineConfiguration.dataLoader = DataLoader(configuration: configuration)
        pipelineConfiguration.imageCache = ImageCache()
        previousPipeline = ImagePipeline.shared
        ImagePipeline.shared = ImagePipeline(configuration: pipelineConfiguration)
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        if let previousPipeline { ImagePipeline.shared = previousPipeline }
    }

    func testFailingLoadRetriesAfterTwoThenFiveSeconds() async throws {
        show(AsyncImageView(url: posterURL(), targetSize: CGSize(width: 60, height: 90)))
        try await waitForRequests(1)

        // Times from the first request; each load fails within milliseconds.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(stub.requests.count, 1)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(stub.requests.count, 2, "the first retry comes 2 s after the failure")
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(stub.requests.count, 2, "the second retry waits 5 s, not 2 s again")
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertEqual(stub.requests.count, 3)
    }

    #if os(tvOS)
    /// A Skyline row that scrolls out of view stays mounted with loading off.
    /// When it comes back, a poster that still fails starts its retries over
    /// instead of carrying on with the backoff its last visit spent.
    func testRowBackInViewStartsTheRetryScheduleOver() async throws {
        let row = RowVisibility()
        show(VisibilityGatedArtwork(row: row, url: posterURL()))
        try await waitForRequests(1)

        // First visit: the load and its 2 s retry fail; the next retry would
        // wait 5 s.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(stub.requests.count, 2)
        row.isVisible = false
        try await Task.sleep(for: .milliseconds(500))
        let beforeReturn = stub.requests.count
        row.isVisible = true

        // Back in view: a load at once, then a retry 2 s later rather than 15 s.
        try await waitForRequests(beforeReturn + 1)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(stub.requests.count - beforeReturn, 2)
    }

    private final class RowVisibility: ObservableObject {
        @Published var isVisible = true
    }

    private struct VisibilityGatedArtwork: View {
        @ObservedObject var row: RowVisibility
        let url: String

        var body: some View {
            AsyncImageView(url: url, targetSize: CGSize(width: 60, height: 90))
                .environment(\.tvArtworkLoadingEnabled, row.isVisible)
        }
    }
    #endif

    private func posterURL() -> String {
        "https://artwork.example/poster-\(UUID().uuidString).jpg"
    }

    private func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while stub.requests.count < count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("expected \(count) requests, saw \(stub.requests.count)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func show(_ view: some View) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 120, height: 180))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: view.frame(width: 60, height: 90))
        window.isHidden = false
        window.layoutIfNeeded()
        self.window = window
    }
}
