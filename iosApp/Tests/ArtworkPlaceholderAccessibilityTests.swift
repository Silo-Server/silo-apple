#if os(iOS)
import Darwin
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// What a missing image shows is decoration: neither VoiceOver nor UI
/// automation (XCUITest, Maestro) may see it as an element, such as a glyph
/// labelled "Movie", next to the card's title.
@MainActor
final class ArtworkPlaceholderAccessibilityTests: XCTestCase {
    func testMissingImagePlaceholdersAreNotAccessibilityElements() async throws {
        let view = VStack {
            Text("Marker")
            AsyncImageView(
                url: "",
                targetSize: CGSize(width: 120, height: 180),
                placeholderStyle: .artwork,
                placeholderSymbol: ArtworkPlaceholderSymbol.television
            )
                .frame(width: 120, height: 180)
            AsyncImageView(url: "", targetSize: CGSize(width: 120, height: 180))
                .frame(width: 120, height: 180)
        }
        let labels = try await accessibilityLabels(of: view, waitingFor: "Marker")
        XCTAssertTrue(labels.allSatisfy { $0 == "Marker" }, "\(labels)")
    }

    func testLibraryCardExposesOnlyItsOwnLabel() async throws {
        let card = MediaCard(
            title: "Placeholder Show",
            posterUrl: "",
            mediaType: "series",
            year: 2008,
            action: {}
        )
        .environment(AppRouter())
        .environmentObject(OverlayPrefsStore())
        let labels = try await accessibilityLabels(of: card, waitingFor: "Placeholder Show")
        let glyphLabels = ["tv", "film", "movie"]
        XCTAssertFalse(labels.contains { label in
            glyphLabels.contains { label.caseInsensitiveCompare($0) == .orderedSame }
        }, "\(labels)")
    }

    // MARK: - Helpers

    /// SwiftUI only builds its accessibility tree once the app's
    /// accessibility runtime is on, which a plain unit-test host may not have
    /// done yet. This is the switch the AccessibilitySnapshot library flips.
    private static let setAccessibilityRuntimeEnabled: (@convention(c) (Bool) -> Void)? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled") else { return nil }
        typealias SetEnabled = @convention(c) (Bool) -> Void
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()

    override func setUp() async throws {
        try await super.setUp()
        Self.setAccessibilityRuntimeEnabled?(true)
    }

    /// Switched off again so later tests in the bundle do not run with
    /// SwiftUI accessibility trees active.
    override func tearDown() async throws {
        Self.setAccessibilityRuntimeEnabled?(false)
        try await super.tearDown()
    }

    private func accessibilityLabels(of view: some View, waitingFor marker: String) async throws -> [String] {
        XCTAssertNotNil(Self.setAccessibilityRuntimeEnabled, "Could not enable the accessibility runtime")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        var labels: [String] = []
        // Give the render a few passes after the marker shows up.
        var passesAfterMarker = 0
        for _ in 0..<40 {
            window.layoutIfNeeded()
            labels = collectLabels(window)
            if labels.contains(where: { $0.contains(marker) }) {
                passesAfterMarker += 1
                if passesAfterMarker >= 5 { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(labels.contains { $0.contains(marker) }, "Accessibility tree not exposed: \(labels)")
        return labels
    }

    /// Labels across both trees: VoiceOver's elements and the automation
    /// elements UI tests read, which also include non-accessible children.
    private func collectLabels(_ root: NSObject) -> [String] {
        var labels: [String] = []
        var stack: [NSObject] = [root]
        var visited = Set<ObjectIdentifier>()
        while let node = stack.popLast() {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            // Asking for the count first makes a SwiftUI host build its tree;
            // reading `accessibilityElements` alone can come back empty.
            let count = node.accessibilityElementCount()
            if let label = node.accessibilityLabel, !label.isEmpty {
                labels.append(label)
            }
            if let elements = node.automationElements as? [NSObject] {
                stack.append(contentsOf: elements)
            }
            if let elements = node.accessibilityElements as? [NSObject] {
                stack.append(contentsOf: elements)
            } else if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = node.accessibilityElement(at: index) as? NSObject {
                        stack.append(element)
                    }
                }
            }
            if let view = node as? UIView {
                stack.append(contentsOf: view.subviews)
            }
        }
        return labels
    }
}
#endif
