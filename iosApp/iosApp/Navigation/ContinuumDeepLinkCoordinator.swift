import Foundation

/// Durable app-level inbox for external URLs.
///
/// SwiftUI may deliver `.onOpenURL` before `ContentView` has installed its
/// lifecycle handlers during a cold launch. Holding the URL in observable
/// state lets the root view consume it regardless of which side becomes ready
/// first. Authentication and route validation remain owned by `ContentView`.
@MainActor
@Observable
final class ContinuumDeepLinkCoordinator {
    static let shared = ContinuumDeepLinkCoordinator()

    private(set) var pendingURL: URL?

    private init() {}

    func receive(_ url: URL) {
        pendingURL = url
    }

    func consumePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}
