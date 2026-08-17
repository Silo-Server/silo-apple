#if os(iOS)
import Foundation

@MainActor
final class ApplePushDeepLinkCoordinator {
    static let shared = ApplePushDeepLinkCoordinator()

    private var pendingDeepLink: URL?

    private init() {}

    func postDeepLink(from userInfo: [AnyHashable: Any]) {
        guard let url = Self.deepLinkURL(from: userInfo) else { return }
        pendingDeepLink = url
        NotificationCenter.default.post(
            name: .siloDeepLink,
            object: nil,
            userInfo: ["url": url]
        )
    }

    func consumePendingDeepLink() -> URL? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    func clearPendingDeepLink(matching url: URL) {
        guard pendingDeepLink?.absoluteString == url.absoluteString else { return }
        pendingDeepLink = nil
    }

    nonisolated static func deepLinkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[ApplePushDisplayWire.urlUserInfoKey] as? String else { return nil }
        return deepLinkURL(fromDisplayURL: raw)
    }

    nonisolated static func deepLinkURL(fromDisplayURL rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme == "continuum" {
            return url
        }

        let parsedURL = URL(string: trimmed)
        let path = parsedURL?.path.isEmpty == false ? parsedURL?.path : trimmed
        let components = path?
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        guard components.count >= 2 else { return nil }

        // The route is forwarded as-is: ContentView.handleDeepLink owns
        // route validity and safely ignores unknown hosts, so new push
        // destinations work without a second allowlist to keep in sync.
        let route = components[0]
        let contentID = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contentID.isEmpty else { return nil }

        var deepLink = URLComponents()
        deepLink.scheme = "continuum"
        deepLink.host = route
        deepLink.path = "/" + contentID
        return deepLink.url
    }
}
#endif
