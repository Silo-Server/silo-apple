#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class PhoneDetailSplitPageLayoutTests: XCTestCase {
    /// On a 2× 11-inch iPad Pro in landscape (1210 × 802 sheet),
    /// `artworkHeight * 0.66` is 449.2125pt (non-pixel-aligned). When a
    /// series lead section pulls `contentTop` up between `paneTop` and
    /// `fadeTop`, subpixel disagreement between the top padding and the
    /// named coordinate space must not trap SwiftUI in a preference cycle.
    func testSplitPageLeadEndSettlesOnNonPixelAlignedFadeTop() async throws {
        let counter = RenderCounter()
        let scrollState = PhoneDetailScrollState()
        let layout = PhoneDetailPageLayout(
            scrollState: scrollState,
            column: { EmptyView() },
            paneArtwork: { Color.clear },
            paneSidebar: { Color.clear.frame(height: 100) },
            paneContent: {
                let count = MainActor.assumeIsolated { () -> Int in
                    counter.evaluations += 1
                    return counter.evaluations
                }
                SplitPaneLeadEndProbe(
                    counter: counter,
                    attachesPreference: count <= RenderCounter.loopBreakerLimit
                )
            }
        )
        .frame(width: 1210, height: 802)
        .coordinateSpace(name: SplitPaneLeadEndProbe.pageSpace)
        .ignoresSafeArea()
        .environment(\.verticalSizeClass, .regular)
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.detailPageTopSafeArea, 0)

        let host = UIHostingController(rootView: layout)
        // Pin a 2× display scale so the test exercises the 0.5pt pixel grid
        // even when the test host runs on a 3× iPhone simulator.
        host.traitOverrides.displayScale = 2
        host.traitOverrides.verticalSizeClass = .regular
        host.traitOverrides.horizontalSizeClass = .regular

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 802))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        window.traitOverrides.displayScale = 2
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // Drive several layout passes as UISheetPresentationController does
        // during presentation.
        for _ in 0..<5 {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertGreaterThan(
            counter.evaluations,
            0,
            "Test must enter PhoneDetailSplitPage so paneContent is evaluated."
        )
        XCTAssertLessThanOrEqual(
            counter.evaluations,
            20,
            "Split page re-evaluated paneContent \(counter.evaluations) times; preference cycle did not settle."
        )
        // Confirm the lead section actually pulled the content pane up from
        // fadeTop (~449pt) to ~364pt so the full 417.5pt lead fits above the
        // 20pt bottom inset.
        let leadMaxY = try XCTUnwrap(counter.lastPageMaxY)
        XCTAssertLessThanOrEqual(leadMaxY, 802 - 19, "Lead section should sit above the 20pt bottom inset")
        XCTAssertGreaterThan(leadMaxY, 700, "Lead section should stay near the lower edge of the window")
    }
}

@MainActor
private final class RenderCounter {
    static let loopBreakerLimit = 40
    var evaluations = 0
    var lastPageMaxY: CGFloat?
}

private struct SplitPaneLeadEndProbe: View {
    static let pageSpace = "testSplitPage"
    let counter: RenderCounter
    let attachesPreference: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 190.5)
            leadSection(attachesPreference: attachesPreference)
            Color.clear.frame(height: 600)
        }
    }

    @ViewBuilder
    private func leadSection(attachesPreference: Bool) -> some View {
        let box = Color.clear
            .frame(height: 227)
            .background {
                GeometryReader { proxy in
                    let maxY = proxy.frame(in: .named(Self.pageSpace)).maxY
                    Color.clear.onAppear {
                        counter.lastPageMaxY = maxY
                    }
                    .onChange(of: maxY) { _, newValue in
                        counter.lastPageMaxY = newValue
                    }
                }
            }
        if attachesPreference {
            box.splitPaneLeadEnd()
        } else {
            box
        }
    }
}
#endif
